//! build.zig — the parser entry: parse a Zig source root ONCE, emit the structural map.
//!
//! Reads source as text (never runs it) and writes one row per public declaration, in Zig's
//! source order — the faithful map of paths, names, kinds, child-counts, and files. Parse all
//! → output all; nothing resolved, nothing grouped, no relationships. Everything else
//! (signatures, docs, references, grouping) is a separate "organize later" layer.
//!
//! Run: zig run parse/build.zig -- <root.zig> <max_depth> <nodes_out>
//!   e.g. zig run parse/build.zig -- /usr/local/zig/lib/std/std.zig 24 nodes.tsv

const std = @import("std");
const Ast = std.zig.Ast;
const walk = @import("walk.zig");
const az = @import("ast.zig");

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
    const sigs_out: []const u8 = if (args.len > 4) args[4] else "sigs.tsv";
    const docs_out: []const u8 = if (args.len > 5) args[5] else "docs.tsv";
    const fields_out: []const u8 = if (args.len > 6) args[6] else "fields.tsv";
    const delegates_out: []const u8 = if (args.len > 7) args[7] else "delegates.tsv";
    const examples_out: []const u8 = if (args.len > 8) args[8] else "examples.tsv";

    const nodes_file = try std.Io.Dir.cwd().createFile(io, nodes_out, .{});
    defer nodes_file.close(io);
    const sigs_file = try std.Io.Dir.cwd().createFile(io, sigs_out, .{});
    defer sigs_file.close(io);
    const docs_file = try std.Io.Dir.cwd().createFile(io, docs_out, .{});
    defer docs_file.close(io);
    const fields_file = try std.Io.Dir.cwd().createFile(io, fields_out, .{});
    defer fields_file.close(io);
    const delegates_file = try std.Io.Dir.cwd().createFile(io, delegates_out, .{});
    defer delegates_file.close(io);
    const examples_file = try std.Io.Dir.cwd().createFile(io, examples_out, .{});
    defer examples_file.close(io);

    var nbuf: [1 << 16]u8 = undefined;
    var nfw = nodes_file.writer(io, &nbuf);
    const nw = &nfw.interface;
    var sbuf: [1 << 16]u8 = undefined;
    var sfw = sigs_file.writer(io, &sbuf);
    const sw = &sfw.interface;
    var dbuf: [1 << 16]u8 = undefined;
    var dfw = docs_file.writer(io, &dbuf);
    const dw = &dfw.interface;
    var fbuf: [1 << 16]u8 = undefined;
    var ffw = fields_file.writer(io, &fbuf);
    const fw = &ffw.interface;
    var gbuf: [1 << 16]u8 = undefined;
    var gfw = delegates_file.writer(io, &gbuf);
    const gw = &gfw.interface;
    var xbuf: [1 << 16]u8 = undefined;
    var xfw = examples_file.writer(io, &xbuf);
    const xw = &xfw.interface;

    var visited = std.StringHashMap(void).init(arena);
    try visited.put(root_path, {});

    const root_dir = az.dirname(root_path);
    var w = walk.Walker{
        .arena = arena,
        .io = io,
        .visited = &visited,
        .max_depth = max_depth,
        .root_dir = root_dir,
        .out = nw,
        .sigs = sw,
        .docs = dw,
        .fields = fw,
        .delegates = gw,
        .examples = xw,
    };

    try nw.print("path\tdepth\tkind\tname\tn_children\tdetail\n", .{});
    try sw.print("path\tsig\n", .{});
    try dw.print("path\tdoc\n", .{});
    try fw.print("path\ttype\tvalue\n", .{});
    try gw.print("path\ttarget\n", .{});
    try xw.print("path\tkind\tname\tcode\n", .{});

    const root_logical = std.fs.path.stem(root_path); // "std"
    if (try az.parseFile(io, arena, root_path)) |root_ast_v| {
        const root_ast = try arena.create(Ast);
        root_ast.* = root_ast_v;
        const cnt = az.countPub(root_ast, root_ast.rootDecls());
        try w.emit(.{ .path = root_logical, .name = root_logical, .depth = 0, .kind = .ns, .n_children = cnt, .detail = az.relPath(root_dir, root_path) });
        try walk.walkMembers(&w, root_ast, root_ast.rootDecls(), root_dir, root_logical, 1, .ns);
    } else {
        // root unreadable → a single nserr row.
        try w.emit(.{ .path = root_logical, .name = root_logical, .depth = 0, .kind = .nserr, .detail = az.relPath(root_dir, root_path) });
    }

    try nw.flush();
    try sw.flush();
    try dw.flush();
    try fw.flush();
    try gw.flush();
    try xw.flush();
}
