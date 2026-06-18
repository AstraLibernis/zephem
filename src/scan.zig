//! scan.zig — the generalized zephem extractor.
//!
//! Builds the logical namespace tree of a Zig module by PARSING source with
//! `std.zig.Ast` and following `@import` edges + descending inline container
//! literals (struct/enum/union/opaque). Pure parsing — nothing is comptime-
//! evaluated — so platform-gated and "poison" decls (e.g. std.c.darwin's
//! `assert(isDarwin())`) are harmless text. This is what lets it map ALL of std,
//! which a reflection walk cannot (it dies on the first un-evaluatable decl).
//!
//! Output: one TSV row per public decl (the "labels"); container/namespace rows
//! carry their PUBLIC-CHILD COUNT so the "levels" tree falls out of the `path`
//! column AND the data self-verifies (see the conservation law below).
//!
//!   path · depth · kind · name · n_children · detail
//!
//! kind ∈ ns (an @import'd sub-namespace) · struct/enum/union/opaque (inline
//! container) · fn · const · alias (a re-export like `pub const X = Y.Z`) ·
//! modref (import of a module like std/builtin, not a file we own).
//! n_children = number of public decls this container emits as direct children
//!   (0 for leaves and for @ref/read-error namespaces, which are not expanded).
//! detail = target file (ns) · param count (fn) · module name (modref) · "".
//!
//! Self-verifying — the conservation law: every node except the root is exactly
//! one node's child, so  Σ n_children == (total rows − 1).  Per node, the rows
//! whose parent-path equals an expanded container's path must number exactly its
//! n_children. A dropped, double-counted, or truncated decl breaks both. The
//! count is recorded by `countPub` and checked by re-reading the data by parent.
//!
//! Deterministic: members are emitted in source order; a file is expanded once at
//! its first encounter (later references are emitted as `ns` leaves, info=@ref) so
//! shared imports like `std` don't recurse forever. Same Zig version → same bytes.
//!
//! Run: zig run src/scan.zig -- [root.zig] [max_depth]
//!      defaults: $(zig env lib_dir)/std/std.zig is NOT auto-found; pass the path.
//!      e.g. zig run src/scan.zig -- /usr/local/zig/lib/std/std.zig 8

const std = @import("std");
const Ast = std.zig.Ast;

const DEFAULT_ROOT = "/usr/local/zig/lib/std/std.zig";
const DEFAULT_MAX_DEPTH: u32 = 8;

const Ctx = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    visited: *std.StringHashMap(void),
    max_depth: u32,
    /// The module root dir (e.g. .../lib/std) — used to emit deterministic,
    /// machine-independent file paths relative to it.
    root_dir: []const u8,
};

fn dirname(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[0..i];
    return ".";
}

/// An absolute file path rendered relative to the module root, so the dataset is
/// identical regardless of where the toolchain lives on disk.
fn relPath(ctx: *Ctx, abs: []const u8) []const u8 {
    if (abs.len > ctx.root_dir.len and std.mem.startsWith(u8, abs, ctx.root_dir) and abs[ctx.root_dir.len] == '/')
        return abs[ctx.root_dir.len + 1 ..];
    return abs;
}

/// Extract the quoted target of an `@import("...")` init expression from its
/// source text, or null if this init is not a bare @import.
fn importTarget(src: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, src, " \t\r\n");
    const prefix = "@import(\"";
    if (!std.mem.startsWith(u8, t, prefix)) return null;
    const rest = t[prefix.len..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

/// Parse a file's source into an Ast (caller keeps it alive for the walk).
/// Silent on read failure (returns null) — the caller emits the right leaf row,
/// so a missing file never injects an off-schema row into the dataset.
fn parseFile(ctx: *Ctx, path: []const u8) !?Ast {
    const src = std.Io.Dir.cwd().readFileAllocOptions(ctx.io, path, ctx.arena, .unlimited, .of(u8), 0) catch {
        return null;
    };
    return try Ast.parse(ctx.arena, src, .zig);
}

/// Count the public decls a container emits as direct children — the SAME
/// predicate `walkMembers` uses to emit, so recorded count == emitted rows.
fn countPub(ast: *const Ast, members: []const Ast.Node.Index) usize {
    var n: usize = 0;
    for (members) |m| {
        if (ast.nodeTag(m) == .fn_decl) {
            var b: [1]Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&b, m) orelse continue;
            if (proto.visib_token != null and proto.name_token != null) n += 1;
            continue;
        }
        const vd = ast.fullVarDecl(m) orelse continue;
        if (vd.visib_token != null) n += 1;
    }
    return n;
}

const ContainerKind = enum { @"struct", @"enum", @"union", @"opaque", none };

fn containerKindOf(ast: *const Ast, node: Ast.Node.Index) ContainerKind {
    var buf: [2]Ast.Node.Index = undefined;
    const cd = ast.fullContainerDecl(&buf, node) orelse return .none;
    return switch (ast.tokenTag(cd.ast.main_token)) {
        .keyword_struct => .@"struct",
        .keyword_enum => .@"enum",
        .keyword_union => .@"union",
        .keyword_opaque => .@"opaque",
        else => .@"struct",
    };
}

/// Walk the members of a container node (or the root) at `logical_path`.
fn walkMembers(
    ctx: *Ctx,
    ast: *const Ast,
    members: []const Ast.Node.Index,
    base_dir: []const u8,
    logical_path: []const u8,
    depth: u32,
) !void {
    for (members) |m| {
        const tag = ast.nodeTag(m);
        // functions — leaves (n_children = 0; detail = param count)
        if (tag == .fn_decl) {
            var b: [1]Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&b, m) orelse continue;
            if (proto.visib_token == null) continue;
            const name_tok = proto.name_token orelse continue;
            const name = ast.tokenSlice(name_tok);
            var nparams: usize = 0;
            var it = proto.iterate(ast);
            while (it.next()) |_| nparams += 1;
            try ctx.w.print("{s}.{s}\t{d}\tfn\t{s}\t0\t{d}\n", .{ logical_path, name, depth, name, nparams });
            continue;
        }
        // variable / const declarations
        const vd = ast.fullVarDecl(m) orelse continue;
        if (vd.visib_token == null) continue;
        const name = ast.tokenSlice(vd.ast.mut_token + 1);
        const init = vd.ast.init_node.unwrap() orelse {
            try ctx.w.print("{s}.{s}\t{d}\tconst\t{s}\t0\t\n", .{ logical_path, name, depth, name });
            continue;
        };
        const init_src = ast.getNodeSource(init);

        // @import("x.zig") → a sub-namespace; follow it.
        if (importTarget(init_src)) |target| {
            if (std.mem.endsWith(u8, target, ".zig")) {
                const child_path = try std.fs.path.resolve(ctx.arena, &.{ base_dir, target });
                const child_logical = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ logical_path, name });
                const rel = relPath(ctx, child_path);
                if (ctx.visited.contains(child_path) or depth >= ctx.max_depth) {
                    // already expanded at its canonical home, or depth-capped: a leaf ref
                    // to the file at `rel` (which IS expanded under some other path).
                    try ctx.w.print("{s}\t{d}\tnsref\t{s}\t0\t{s}\n", .{ child_logical, depth, name, rel });
                } else if (try parseFile(ctx, child_path)) |child_ast| {
                    try ctx.visited.put(child_path, {});
                    const cnt = countPub(&child_ast, child_ast.rootDecls());
                    try ctx.w.print("{s}\t{d}\tns\t{s}\t{d}\t{s}\n", .{ child_logical, depth, name, cnt, rel });
                    try walkMembers(ctx, &child_ast, child_ast.rootDecls(), dirname(child_path), child_logical, depth + 1);
                } else {
                    try ctx.w.print("{s}\t{d}\tnserr\t{s}\t0\t{s}\n", .{ child_logical, depth, name, rel });
                }
            } else {
                // module import (std/builtin/root) — a reference, not a file we own.
                try ctx.w.print("{s}.{s}\t{d}\tmodref\t{s}\t0\t{s}\n", .{ logical_path, name, depth, name, target });
            }
            continue;
        }

        // inline container literal → descend into the AST subtree.
        const ck = containerKindOf(ast, init);
        if (ck != .none) {
            const child_logical = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ logical_path, name });
            var b: [2]Ast.Node.Index = undefined;
            const cd = ast.fullContainerDecl(&b, init).?;
            const cnt = if (depth < ctx.max_depth) countPub(ast, cd.ast.members) else 0;
            try ctx.w.print("{s}\t{d}\t{s}\t{s}\t{d}\t\n", .{ child_logical, depth, @tagName(ck), name, cnt });
            if (depth < ctx.max_depth) {
                try walkMembers(ctx, ast, cd.ast.members, base_dir, child_logical, depth + 1);
            }
            continue;
        }

        // an alias / plain const. Distinguish a re-export (X.Y / Y) from a value.
        const trimmed = std.mem.trim(u8, init_src, " \t\r\n");
        const looks_alias = trimmed.len > 0 and
            (std.ascii.isAlphabetic(trimmed[0]) or trimmed[0] == '_' or trimmed[0] == '@') and
            std.mem.indexOfAny(u8, trimmed, "+-*/(){}\"") == null;
        const kind: []const u8 = if (looks_alias) "alias" else "const";
        try ctx.w.print("{s}.{s}\t{d}\t{s}\t{s}\t0\t\n", .{ logical_path, name, depth, kind, name });
    }
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // args
    const args = try init.minimal.args.toSlice(arena);
    const root_path: []const u8 = if (args.len > 1) args[1] else DEFAULT_ROOT;
    const max_depth: u32 = if (args.len > 2)
        std.fmt.parseInt(u32, args[2], 10) catch DEFAULT_MAX_DEPTH
    else
        DEFAULT_MAX_DEPTH;

    var wbuf: [1 << 16]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &wbuf);
    const w = &fw.interface;

    var visited = std.StringHashMap(void).init(arena);
    try visited.put(root_path, {});

    const root_dir = dirname(root_path);
    var ctx = Ctx{ .arena = arena, .io = init.io, .w = w, .visited = &visited, .max_depth = max_depth, .root_dir = root_dir };

    try w.print("path\tdepth\tkind\tname\tn_children\tdetail\n", .{});
    const root_logical = std.fs.path.stem(root_path); // "std"
    if (try parseFile(&ctx, root_path)) |root_ast| {
        const cnt = countPub(&root_ast, root_ast.rootDecls());
        try w.print("{s}\t0\tns\t{s}\t{d}\t{s}\n", .{ root_logical, root_logical, cnt, relPath(&ctx, root_path) });
        try walkMembers(&ctx, &root_ast, root_ast.rootDecls(), root_dir, root_logical, 1);
    } else {
        try w.print("{s}\t0\tnserr\t{s}\t0\t{s}\n", .{ root_logical, root_logical, relPath(&ctx, root_path) });
    }
    try w.flush();
}
