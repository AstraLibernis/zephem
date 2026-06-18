//! enrich.zig — the L1 (signatures) + L2 (doc-comments) overlay for the std map.
//!
//! Walks the SAME logical tree as `scan.zig` (parse source, follow `@import`, descend
//! inline containers) so every `path` it emits lines up exactly with a row in
//! `nodes.tsv`. It does not re-describe structure; it attaches, per public decl, two
//! more facts read straight off the AST:
//!
//!   path · doc · sig
//!
//!   doc = the decl's `///` doc-comment lines (L2), joined with a literal `\n`, with
//!         backslash/tab escaped — the std authors' own words, verbatim. Empty if none.
//!   sig = for a `fn`, its as-written signature `fn name(params) ret` (L1), whitespace
//!         collapsed to single spaces. Empty for non-functions.
//!
//! This is a SPARSE overlay: a row exists only where there's something to say — every
//! `fn` (it has a sig), plus any decl that carries a doc-comment. Non-fn, undocumented
//! decls produce no row (they're already fully covered by nodes.tsv). Joined back to the
//! map by `path`; `verify_std.nu` checks the registration (every path exists in the map,
//! every map `fn` has a sig here, and vice-versa).
//!
//! Pure parsing — same robustness as scan.zig (no comptime, no poison-decl death).
//! Deterministic: source-order emission, identical bytes for a fixed Zig.
//!
//! Run: zig run src/enrich.zig -- [root.zig] [max_depth]

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
};

fn dirname(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[0..i];
    return ".";
}

fn importTarget(src: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, src, " \t\r\n");
    const prefix = "@import(\"";
    if (!std.mem.startsWith(u8, t, prefix)) return null;
    const rest = t[prefix.len..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

fn parseFile(ctx: *Ctx, path: []const u8) !?Ast {
    const src = std.Io.Dir.cwd().readFileAllocOptions(ctx.io, path, ctx.arena, .unlimited, .of(u8), 0) catch {
        return null;
    };
    return try Ast.parse(ctx.arena, src, .zig);
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

/// First doc-comment token preceding `start_tok` (the decl's visibility token), or null.
fn docFirst(ast: *const Ast, start_tok: Ast.TokenIndex) ?Ast.TokenIndex {
    if (start_tok == 0) return null;
    var first = start_tok;
    while (first > 0 and ast.tokenTag(first - 1) == .doc_comment) first -= 1;
    if (first == start_tok) return null;
    return first;
}

/// Stream doc-comment lines [first, end) as one escaped field (lines joined with `\n`).
fn writeDoc(w: *std.Io.Writer, ast: *const Ast, first: Ast.TokenIndex, end: Ast.TokenIndex) !void {
    var t = first;
    var line_started = false;
    while (t < end) : (t += 1) {
        if (ast.tokenTag(t) != .doc_comment) continue;
        const slice = ast.tokenSlice(t);
        var i: usize = 0;
        while (i < slice.len and slice[i] == '/') i += 1; // strip leading '///'
        if (i < slice.len and slice[i] == ' ') i += 1; // and one space
        if (line_started) try w.writeAll("\\n");
        line_started = true;
        for (slice[i..]) |c| switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '\t' => try w.writeAll("\\t"),
            '\r' => {},
            else => try w.writeByte(c),
        };
    }
}

/// The as-written signature `fn name(params) ret`, whitespace collapsed to single spaces.
fn fnSigSource(ast: *const Ast, proto: *const Ast.full.FnProto) []const u8 {
    const start = ast.tokenStart(proto.ast.fn_token);
    const end_tok = if (proto.ast.return_type.unwrap()) |rt|
        ast.lastToken(rt)
    else
        ast.lastToken(proto.ast.proto_node);
    const end = ast.tokenStart(end_tok) + ast.tokenSlice(end_tok).len;
    return ast.source[start..end];
}

fn writeSig(w: *std.Io.Writer, src: []const u8) !void {
    var pending_space = false;
    var started = false;
    for (src) |c| {
        const ws = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (ws) {
            if (started) pending_space = true;
            continue;
        }
        if (pending_space) {
            try w.writeByte(' ');
            pending_space = false;
        }
        if (c == '\\') try w.writeAll("\\\\") else try w.writeByte(c);
        started = true;
    }
}

/// Emit a doc-only row (empty sig) for a non-fn decl, iff it carries a doc-comment.
fn emitDocRow(ctx: *Ctx, ast: *const Ast, path: []const u8, start_tok: Ast.TokenIndex) !void {
    const df = docFirst(ast, start_tok) orelse return;
    try ctx.w.print("{s}\t", .{path});
    try writeDoc(ctx.w, ast, df, start_tok);
    try ctx.w.writeAll("\t\n");
}

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
        // functions — always a row (signature), doc optional.
        if (tag == .fn_decl) {
            var b: [1]Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&b, m) orelse continue;
            if (proto.visib_token == null) continue;
            const name_tok = proto.name_token orelse continue;
            const name = ast.tokenSlice(name_tok);
            try ctx.w.print("{s}.{s}\t", .{ logical_path, name });
            if (docFirst(ast, proto.visib_token.?)) |df| try writeDoc(ctx.w, ast, df, proto.visib_token.?);
            try ctx.w.writeAll("\t");
            try writeSig(ctx.w, fnSigSource(ast, &proto));
            try ctx.w.writeAll("\n");
            continue;
        }
        const vd = ast.fullVarDecl(m) orelse continue;
        if (vd.visib_token == null) continue;
        const start_tok = vd.visib_token.?;
        const name = ast.tokenSlice(vd.ast.mut_token + 1);
        const init = vd.ast.init_node.unwrap() orelse {
            try emitDocRow(ctx, ast, try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ logical_path, name }), start_tok);
            continue;
        };
        const init_src = ast.getNodeSource(init);

        if (importTarget(init_src)) |target| {
            if (std.mem.endsWith(u8, target, ".zig")) {
                const child_path = try std.fs.path.resolve(ctx.arena, &.{ base_dir, target });
                const child_logical = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ logical_path, name });
                try emitDocRow(ctx, ast, child_logical, start_tok);
                if (ctx.visited.contains(child_path) or depth >= ctx.max_depth) {
                    // nsref leaf — doc (if any) already emitted; don't recurse.
                } else if (try parseFile(ctx, child_path)) |child_ast| {
                    try ctx.visited.put(child_path, {});
                    try walkMembers(ctx, &child_ast, child_ast.rootDecls(), dirname(child_path), child_logical, depth + 1);
                }
            } else {
                try emitDocRow(ctx, ast, try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ logical_path, name }), start_tok);
            }
            continue;
        }

        const ck = containerKindOf(ast, init);
        if (ck != .none) {
            const child_logical = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ logical_path, name });
            try emitDocRow(ctx, ast, child_logical, start_tok);
            if (depth < ctx.max_depth) {
                var b: [2]Ast.Node.Index = undefined;
                const cd = ast.fullContainerDecl(&b, init).?;
                try walkMembers(ctx, ast, cd.ast.members, base_dir, child_logical, depth + 1);
            }
            continue;
        }

        // alias / plain const
        try emitDocRow(ctx, ast, try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ logical_path, name }), start_tok);
    }
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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

    var ctx = Ctx{ .arena = arena, .io = init.io, .w = w, .visited = &visited, .max_depth = max_depth };

    try w.print("path\tdoc\tsig\n", .{});
    const root_logical = std.fs.path.stem(root_path);
    if (try parseFile(&ctx, root_path)) |root_ast| {
        try walkMembers(&ctx, &root_ast, root_ast.rootDecls(), dirname(root_path), root_logical, 1);
    }
    try w.flush();
}
