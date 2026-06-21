//! build.zig — the parser: parse a Zig source root ONCE, emit the structural map (nodes.tsv).
//!
//! One walk (walk.zig) drives the structure visitor. The parser reads source as text — it
//! never runs it — and emits one row per public declaration, in Zig's source order: the
//! faithful map of paths, names, kinds, child-counts, and files. Nothing resolved, nothing
//! grouped, no relationships. Parse all → output all; everything else (signatures, docs,
//! references, grouping) is a separate "organize later" layer, never the parser's job.
//!
//! Run: zig run parse/build.zig -- <root.zig> <max_depth> <nodes_out>
//!   e.g. zig run parse/build.zig -- /usr/local/zig/lib/std/std.zig 24 nodes.tsv

const std = @import("std");
const Ast = std.zig.Ast;
const walk = @import("walk.zig");
const fs = @import("common/fs.zig");
const astu = @import("common/ast.zig");
const MapVisitor = @import("visit/map.zig").Visitor;

const DEFAULT_ROOT = "/usr/local/zig/lib/std/std.zig";
const DEFAULT_MAX_DEPTH: u32 = 8;

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const root_path: []const u8 = if (args.len > 1) args[1] else DEFAULT_ROOT;
    const max_depth: u32 = if (args.len > 2)
        std.fmt.parseInt(u32, args[2], 10) catch DEFAULT_MAX_DEPTH
    else
        DEFAULT_MAX_DEPTH;
    const nodes_out: []const u8 = if (args.len > 3) args[3] else "nodes.tsv";

    const nodes_file = try std.Io.Dir.cwd().createFile(io, nodes_out, .{});
    defer nodes_file.close(io);

    var nbuf: [1 << 16]u8 = undefined;
    var nfw = nodes_file.writer(io, &nbuf);
    const nw = &nfw.interface;

    var visited = std.StringHashMap(void).init(arena);
    try visited.put(root_path, {});

    const root_dir = fs.dirname(root_path);
    var w = walk.Walker{ .arena = arena, .io = io, .visited = &visited, .max_depth = max_depth, .root_dir = root_dir };
    const map = MapVisitor{ .w = nw };

    try nw.print("path\tdepth\tkind\tname\tn_children\tdetail\n", .{});

    const root_logical = std.fs.path.stem(root_path); // "std"
    if (try fs.parseFile(io, arena, root_path)) |root_ast_v| {
        const root_ast = try arena.create(Ast);
        root_ast.* = root_ast_v;
        const cnt = astu.countPub(root_ast, root_ast.rootDecls());
        try map.emit(.{ .path = root_logical, .name = root_logical, .depth = 0, .kind = .ns, .n_children = cnt, .detail = fs.relPath(root_dir, root_path), .ds_ast = root_ast, .ds_tok = null });
        try walk.walkMembers(&w, map, root_ast, root_ast.rootDecls(), root_dir, root_logical, 1);
    } else {
        // root unreadable → a single nserr row.
        try map.emit(.{ .path = root_logical, .name = root_logical, .depth = 0, .kind = .nserr, .detail = fs.relPath(root_dir, root_path), .ds_ast = undefined, .ds_tok = null });
    }

    try nw.flush();
}
