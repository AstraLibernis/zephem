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
//! detail = target file (ns/nsref) · param count (fn) · module name (modref) ·
//!   raw RHS reference (alias, e.g. `mem.Allocator` — the L3 tunnel target) · "".
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

/// An `@import` init, split into the imported file and any selector that follows.
///   `@import("f.zig")`        → { file: "f.zig", selector: "" }   (whole-file namespace)
///   `@import("f.zig").Foo`    → { file: "f.zig", selector: "Foo" } (re-export of one decl)
/// Returns null when the init is not a clean @import-or-@import-selection (e.g. a generic
/// call `@import("f").Foo(args)` — that's a value, handled as an alias/const leaf).
const ImportRef = struct { file: []const u8, selector: []const u8 };

fn parseImport(src: []const u8) ?ImportRef {
    const t = std.mem.trim(u8, src, " \t\r\n");
    const prefix = "@import(\"";
    if (!std.mem.startsWith(u8, t, prefix)) return null;
    const after_q = t[prefix.len..];
    const qend = std.mem.indexOfScalar(u8, after_q, '"') orelse return null;
    const file = after_q[0..qend];
    var rest = std.mem.trim(u8, after_q[qend + 1 ..], " \t\r\n");
    if (!std.mem.startsWith(u8, rest, ")")) return null; // malformed / not a plain @import
    rest = std.mem.trim(u8, rest[1..], " \t\r\n");
    if (rest.len == 0) return .{ .file = file, .selector = "" }; // whole-file import
    if (rest[0] != '.') return null; // a call or operator on the import → a value, not a re-export
    const sel = std.mem.trim(u8, rest[1..], " \t\r\n");
    if (sel.len == 0) return null;
    // a re-export selector is a clean dotted identifier chain; anything else is an expression.
    for (sel) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) return null;
    return .{ .file = file, .selector = sel };
}

/// True iff `s` is a pure dotted identifier chain — `Foo`, `mem.Allocator`,
/// `crypto.hash.sha2.Sha256` — and nothing else. This is exactly a re-export alias: a name
/// that points at another decl. Anything with an operator, call, `@builtin`, or whitespace
/// (an error-set merge `E1 || E2`, a bool `Os != void`, a generic call) is a computed value,
/// not an alias — so it stays a `const`. Being whitespace-free, an accepted chain is always
/// TSV-safe as the alias `detail`.
fn isAliasChain(s: []const u8) bool {
    if (s.len == 0) return false;
    var expect_start = true; // at the first char of an identifier segment
    for (s) |c| {
        if (expect_start) {
            if (!(std.ascii.isAlphabetic(c) or c == '_')) return false;
            expect_start = false;
        } else if (c == '.') {
            expect_start = true;
        } else if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
            return false;
        }
    }
    return !expect_start; // must not end on a trailing '.'
}

/// The public decl named `name` among `members`, or null.
fn findDecl(ast: *const Ast, members: []const Ast.Node.Index, name: []const u8) ?Ast.Node.Index {
    for (members) |m| {
        if (ast.nodeTag(m) == .fn_decl) {
            var b: [1]Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&b, m) orelse continue;
            if (proto.visib_token == null) continue;
            const nt = proto.name_token orelse continue;
            if (std.mem.eql(u8, ast.tokenSlice(nt), name)) return m;
            continue;
        }
        const vd = ast.fullVarDecl(m) orelse continue;
        if (vd.visib_token == null) continue;
        if (std.mem.eql(u8, ast.tokenSlice(vd.ast.mut_token + 1), name)) return m;
    }
    return null;
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

/// Emit node `a_logical` (= `a_name`) for a selective re-export `@import(file).selector`,
/// COLLAPSED: A becomes whatever `selector` resolves to inside `file` — a container (its
/// members hang directly under A), a fn (a leaf), or, when the chain can't be followed
/// cleanly, an `alias` leaf. This is what removes the phantom `X25519.X25519` doubling and
/// the duplicate `acos` reads: the map records the re-export as the one thing it actually is.
fn emitReexport(ctx: *Ctx, file_abs: []const u8, selector: []const u8, a_logical: []const u8, a_name: []const u8, depth: u32, chain: u8) anyerror!void {
    const rel = relPath(ctx, file_abs);
    // multi-segment selector or a too-deep alias chain → safe `alias` leaf (no false structure,
    // no risk of a cyclic-alias loop). Single-segment is the dominant, fully-handled case.
    if (chain > 16 or std.mem.indexOfScalar(u8, selector, '.') != null) {
        try ctx.w.print("{s}\t{d}\talias\t{s}\t0\t{s}\n", .{ a_logical, depth, a_name, rel });
        return;
    }
    const fast = (try parseFile(ctx, file_abs)) orelse {
        try ctx.w.print("{s}\t{d}\tnserr\t{s}\t0\t{s}\n", .{ a_logical, depth, a_name, rel });
        return;
    };
    const found = findDecl(&fast, fast.rootDecls(), selector) orelse {
        try ctx.w.print("{s}\t{d}\talias\t{s}\t0\t{s}\n", .{ a_logical, depth, a_name, rel });
        return;
    };
    // re-exported function → A is that fn (leaf, detail = param count).
    if (fast.nodeTag(found) == .fn_decl) {
        var b: [1]Ast.Node.Index = undefined;
        const proto = fast.fullFnProto(&b, found).?;
        var nparams: usize = 0;
        var it = proto.iterate(&fast);
        while (it.next()) |_| nparams += 1;
        try ctx.w.print("{s}\t{d}\tfn\t{s}\t0\t{d}\n", .{ a_logical, depth, a_name, nparams });
        return;
    }
    const vd = fast.fullVarDecl(found) orelse {
        try ctx.w.print("{s}\t{d}\talias\t{s}\t0\t{s}\n", .{ a_logical, depth, a_name, rel });
        return;
    };
    const binit = vd.ast.init_node.unwrap() orelse {
        try ctx.w.print("{s}\t{d}\tconst\t{s}\t0\t\n", .{ a_logical, depth, a_name });
        return;
    };
    // re-exported inline container → A IS it; hang its members directly under A (collapse).
    const ck = containerKindOf(&fast, binit);
    if (ck != .none) {
        var b2: [2]Ast.Node.Index = undefined;
        const cd = fast.fullContainerDecl(&b2, binit).?;
        const cnt = if (depth < ctx.max_depth) countPub(&fast, cd.ast.members) else 0;
        try ctx.w.print("{s}\t{d}\t{s}\t{s}\t{d}\t\n", .{ a_logical, depth, @tagName(ck), a_name, cnt });
        if (depth < ctx.max_depth) {
            try walkMembers(ctx, &fast, cd.ast.members, dirname(file_abs), a_logical, depth + 1);
        }
        return;
    }
    // re-exported decl is itself an @import → A re-exports that (whole file → ns; selective → chain).
    if (parseImport(fast.getNodeSource(binit))) |imp2| {
        if (std.mem.endsWith(u8, imp2.file, ".zig")) {
            const gpath = try std.fs.path.resolve(ctx.arena, &.{ dirname(file_abs), imp2.file });
            if (imp2.selector.len == 0) {
                const grel = relPath(ctx, gpath);
                if (ctx.visited.contains(gpath) or depth >= ctx.max_depth) {
                    try ctx.w.print("{s}\t{d}\tnsref\t{s}\t0\t{s}\n", .{ a_logical, depth, a_name, grel });
                } else if (try parseFile(ctx, gpath)) |gast| {
                    try ctx.visited.put(gpath, {});
                    const cnt = countPub(&gast, gast.rootDecls());
                    try ctx.w.print("{s}\t{d}\tns\t{s}\t{d}\t{s}\n", .{ a_logical, depth, a_name, cnt, grel });
                    try walkMembers(ctx, &gast, gast.rootDecls(), dirname(gpath), a_logical, depth + 1);
                } else {
                    try ctx.w.print("{s}\t{d}\tnserr\t{s}\t0\t{s}\n", .{ a_logical, depth, a_name, grel });
                }
            } else {
                try emitReexport(ctx, gpath, imp2.selector, a_logical, a_name, depth, chain + 1);
            }
            return;
        }
    }
    // generic instantiation, local alias, or plain value → alias leaf.
    try ctx.w.print("{s}\t{d}\talias\t{s}\t0\t{s}\n", .{ a_logical, depth, a_name, rel });
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

        // @import(...) — a whole-file namespace, a re-export of one decl, or a module ref.
        if (parseImport(init_src)) |imp| {
            const child_logical = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ logical_path, name });
            if (!std.mem.endsWith(u8, imp.file, ".zig")) {
                // module import (std/builtin/root) — a reference, not a file we own.
                try ctx.w.print("{s}\t{d}\tmodref\t{s}\t0\t{s}\n", .{ child_logical, depth, name, imp.file });
            } else {
                const child_path = try std.fs.path.resolve(ctx.arena, &.{ base_dir, imp.file });
                if (imp.selector.len == 0) {
                    // BARE whole-file import → a sub-namespace; follow it.
                    const rel = relPath(ctx, child_path);
                    if (ctx.visited.contains(child_path) or depth >= ctx.max_depth) {
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
                    // SELECTIVE re-export `@import("f").Sel` → collapse: A *is* the decl Sel
                    // resolves to (its members hang directly under A — no phantom doubling).
                    try emitReexport(ctx, child_path, imp.selector, child_logical, name, depth, 0);
                }
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

        // an alias / plain const. A pure dotted chain (`X.Y` / `Y`) is a re-export; record its
        // raw RHS in `detail` — the unresolved target an L3 tunnel resolves to a canonical path.
        // Anything else (an expression, error-set merge, generic call) is a computed `const`.
        const trimmed = std.mem.trim(u8, init_src, " \t\r\n");
        const is_alias = isAliasChain(trimmed);
        const kind: []const u8 = if (is_alias) "alias" else "const";
        const detail_field: []const u8 = if (is_alias) trimmed else "";
        try ctx.w.print("{s}.{s}\t{d}\t{s}\t{s}\t0\t{s}\n", .{ logical_path, name, depth, kind, name, detail_field });
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
