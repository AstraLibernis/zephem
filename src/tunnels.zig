//! tunnels.zig — the L3 (reference graph) entry point.
//!
//! Where the map (build.zig) records WHERE every public decl is, this records WHAT LINKS TO
//! WHAT — resolving a referenced name to the canonical logical `path` it points at, so the
//! link is followable (one O(1) jump via the index), not just a name. Three edge kinds:
//!
//!   alias   a re-export `pub const X = a.b.C`         (from the map's `alias` detail)
//!   import  a whole-file / selective import binding   (nsref + import-bearing aliases)
//!   usage   a type referenced in a fn signature        (param / return type chains)
//!
//! Output (one tagged stream; build_tunnels.nu splits + attaches to_line + verifies):
//!
//!   from_path · kind · status · to_or_raw · reason
//!
//! Resolution + symbol tables live in tunnels/resolve.zig; edge emission in tunnels/edges.zig.
//! This file is the orchestrator: load the map, run the alias/import tunnels, then usage.
//!
//! Run: zig run src/tunnels.zig -- <root.zig> <nodes.tsv>

const std = @import("std");
const tsv = @import("common/tsv.zig");
const fs = @import("common/fs.zig");
const rsv = @import("tunnels/resolve.zig");
const edges = @import("tunnels/edges.zig");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return error.Usage;
    const root_path = args[1];
    const nodes_path = args[2];
    const root_dir = fs.dirname(root_path);

    var wbuf: [1 << 16]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &wbuf);
    const w = &fw.interface;

    var paths = std.StringHashMap(void).init(arena);
    var file2path = std.StringHashMap([]const u8).init(arena);
    var nspath2file = std.StringHashMap([]const u8).init(arena);
    var files = std.StringHashMap(*std.StringHashMap(rsv.Target)).init(arena);
    var ctx = rsv.Ctx{ .arena = arena, .io = init.io, .root_dir = root_dir, .paths = &paths, .file2path = &file2path, .nspath2file = &nspath2file, .files = &files };

    // ── load the map ──
    const nodes_src = try std.Io.Dir.cwd().readFileAllocOptions(init.io, nodes_path, arena, .unlimited, .of(u8), 0);
    var aliases: std.ArrayList(struct { path: []const u8, detail: []const u8 }) = .empty;
    var lines = std.mem.splitScalar(u8, nodes_src, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const path = tsv.col(line, 0);
        const kind = tsv.col(line, 2);
        const detail = tsv.col(line, 5);
        try paths.put(path, {});
        if (std.mem.eql(u8, kind, "ns")) {
            try file2path.put(detail, path);
            try nspath2file.put(path, detail);
        }
        if (std.mem.eql(u8, kind, "alias")) {
            try aliases.append(arena, .{ .path = path, .detail = detail });
        }
        if (std.mem.eql(u8, kind, "nsref")) {
            // import tunnel: → the canonical ns expanded for this file (resolved in pass 2)
            try aliases.append(arena, .{ .path = path, .detail = try std.fmt.allocPrint(arena, "\x00nsref\x00{s}", .{detail}) });
        }
    }

    try w.print("from_path\tkind\tstatus\tto_or_raw\treason\n", .{});

    // ── alias + import tunnels (from the map) ──
    for (aliases.items) |al| {
        // nsref import tunnel: resolve the file to its canonical ns path directly.
        if (std.mem.startsWith(u8, al.detail, "\x00nsref\x00")) {
            const f = al.detail["\x00nsref\x00".len..];
            const r: rsv.Res = if (file2path.get(f)) |p| .{ .resolved = p } else .{ .unresolved = "nsref target file not expanded" };
            try edges.emitEdge(w, al.path, "import", r, f);
            continue;
        }
        // an alias whose detail is a FILE path (reexport leftover) → import; else a name chain.
        const file = rsv.fileOf(&ctx, al.path) orelse {
            try edges.emitEdge(w, al.path, "alias", .{ .unresolved = "no enclosing file" }, al.detail);
            continue;
        };
        if (std.mem.endsWith(u8, al.detail, ".zig") or std.mem.indexOfScalar(u8, al.detail, '/') != null) {
            // reexport leftover: target = <ns of that file>.<own name>
            const lastdot = std.mem.lastIndexOfScalar(u8, al.path, '.') orelse 0;
            const name = al.path[lastdot + 1 ..];
            const r: rsv.Res = if (file2path.get(al.detail)) |p| blk: {
                const cand = try std.fmt.allocPrint(arena, "{s}.{s}", .{ p, name });
                break :blk if (rsv.has(&ctx, cand)) .{ .resolved = cand } else .{ .unresolved = "selector not a member of target file" };
            } else .{ .internal = try std.fmt.allocPrint(arena, "private import '{s}'", .{al.detail}) };
            try edges.emitEdge(w, al.path, "import", r, al.detail);
            continue;
        }
        const r = try rsv.resolve(&ctx, file, al.detail, 0);
        try edges.emitEdge(w, al.path, "alias", r, al.detail);
    }

    // ── usage edges (from fn signatures, per file) ──
    var fit = file2path.keyIterator();
    while (fit.next()) |f| try edges.walkUsage(&ctx, w, f.*);

    try w.flush();
}
