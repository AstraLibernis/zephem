//! build.zig — the combined extractor: parse std ONCE, emit nodes.tsv + decls.tsv.
//!
//! A single walk (walk.zig) drives a `Tee` of two visitors — the structure map and the
//! doc/sig overlay — so both datasets fall out of one parse of std (the old setup parsed
//! the whole tree twice, once per program, and the two walks had to be kept byte-identical
//! by hand). Because they ride the same traversal, every overlay `path` is guaranteed to
//! line up with a map `path`.
//!
//! Run: zig run src/build.zig -- <root.zig> <max_depth> <nodes_out> <decls_out>
//!   e.g. zig run src/build.zig -- /usr/local/zig/lib/std/std.zig 24 nodes.tsv decls.tsv

const std = @import("std");
const Ast = std.zig.Ast;
const walk = @import("walk.zig");
const fs = @import("common/fs.zig");
const astu = @import("common/ast.zig");
const MapVisitor = @import("visit/map.zig").Visitor;
const EnrichVisitor = @import("visit/enrich.zig").Visitor;

const DEFAULT_ROOT = "/usr/local/zig/lib/std/std.zig";
const DEFAULT_MAX_DEPTH: u32 = 8;

/// One walk, two overlays.
const Tee = struct {
    map: MapVisitor,
    enrich: EnrichVisitor,
    pub fn emit(self: Tee, n: walk.Node) !void {
        try self.map.emit(n);
        try self.enrich.emit(n);
    }
};

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
    const decls_out: []const u8 = if (args.len > 4) args[4] else "decls.tsv";

    const nodes_file = try std.Io.Dir.cwd().createFile(io, nodes_out, .{});
    defer nodes_file.close(io);
    const decls_file = try std.Io.Dir.cwd().createFile(io, decls_out, .{});
    defer decls_file.close(io);

    var nbuf: [1 << 16]u8 = undefined;
    var dbuf: [1 << 16]u8 = undefined;
    var nfw = nodes_file.writer(io, &nbuf);
    var dfw = decls_file.writer(io, &dbuf);
    const nw = &nfw.interface;
    const dw = &dfw.interface;

    var visited = std.StringHashMap(void).init(arena);
    try visited.put(root_path, {});

    const root_dir = fs.dirname(root_path);
    var w = walk.Walker{ .arena = arena, .io = io, .visited = &visited, .max_depth = max_depth, .root_dir = root_dir };
    const tee = Tee{ .map = .{ .w = nw }, .enrich = .{ .w = dw } };

    try nw.print("path\tdepth\tkind\tname\tn_children\tdetail\n", .{});
    try dw.print("path\tdoc\tsig\n", .{});

    const root_logical = std.fs.path.stem(root_path); // "std"
    if (try fs.parseFile(io, arena, root_path)) |root_ast_v| {
        const root_ast = try arena.create(Ast);
        root_ast.* = root_ast_v;
        const cnt = astu.countPub(root_ast, root_ast.rootDecls());
        // root row: map prints the ns row; enrich emits nothing (ds_tok = null → no doc source).
        try tee.emit(.{ .path = root_logical, .name = root_logical, .depth = 0, .kind = .ns, .n_children = cnt, .detail = fs.relPath(root_dir, root_path), .ds_ast = root_ast, .ds_tok = null });
        try walk.walkMembers(&w, tee, root_ast, root_ast.rootDecls(), root_dir, root_logical, 1);
    } else {
        // root unreadable → a single nserr row in the map only (ds_ast unused: ds_tok = null).
        try tee.map.emit(.{ .path = root_logical, .name = root_logical, .depth = 0, .kind = .nserr, .detail = fs.relPath(root_dir, root_path), .ds_ast = undefined, .ds_tok = null });
    }

    try nw.flush();
    try dw.flush();
}
