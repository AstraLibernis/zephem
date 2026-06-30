//! index.zig — the "table of contents" for data/std/nodes.tsv.
//!
//! nodes.tsv is emitted in pre-order DFS, so EVERY node's subtree is a single
//! contiguous run of rows. This reads nodes.tsv and, for each container (a row
//! with n_children > 0), records where that block lives:
//!
//!   path · line · span · depth · kind · n_children
//!
//!   line = 1-based file line in nodes.tsv (header is line 1) — so a consumer can
//!          read exactly the block with `Read(offset=line, limit=span)` / `sed`.
//!   span = number of rows in this node's subtree, including the node itself.
//!          The block is lines [line, line + span).
//!
//! A node's span is computed from the `depth` column alone: a node owns every
//! following row whose depth is greater, up to the first row whose depth drops
//! back to its own or less (a monotonic-stack "next depth ≤ mine" scan).
//!
//! Self-checking (the same conservation idea as the tree): the root's span must
//! equal the whole file, and every container's span must equal 1 + Σ its direct
//! children's spans. Both are asserted here before a single row is written, so a
//! bad index never reaches disk.
//!
//! Run: zig run derive/index.zig -- [nodes.tsv]   (default data/std/nodes.tsv)

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const in_path: []const u8 = if (args.len > 1) args[1] else "data/std/nodes.tsv";

    const content = try std.Io.Dir.cwd().readFileAllocOptions(init.io, in_path, arena, .unlimited, .of(u8), 0);

    // count data lines (skip header)
    var n: usize = 0;
    {
        var it = std.mem.splitScalar(u8, content, '\n');
        _ = it.next(); // header
        while (it.next()) |ln| if (ln.len > 0) {
            n += 1;
        };
    }

    const paths = try arena.alloc([]const u8, n);
    const depths = try arena.alloc(u32, n);
    const kinds = try arena.alloc([]const u8, n);
    const nch = try arena.alloc(u32, n);

    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next(); // header
    var idx: usize = 0;
    while (lines.next()) |ln| {
        if (ln.len == 0) continue;
        var f = std.mem.splitScalar(u8, ln, '\t');
        const path = f.next() orelse continue;
        const depth_s = f.next() orelse continue;
        const kind = f.next() orelse continue;
        _ = f.next(); // name
        const nch_s = f.next() orelse continue;
        paths[idx] = path;
        depths[idx] = std.fmt.parseInt(u32, depth_s, 10) catch 0;
        kinds[idx] = kind;
        nch[idx] = std.fmt.parseInt(u32, nch_s, 10) catch 0;
        idx += 1;
    }

    // span via monotonic stack: end[i] = first j>i with depth[j] <= depth[i].
    const span = try arena.alloc(usize, n);
    const endi = try arena.alloc(usize, n);
    const stack = try arena.alloc(usize, n);
    var sp: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        while (sp > 0 and depths[i] <= depths[stack[sp - 1]]) : (sp -= 1) endi[stack[sp - 1]] = i;
        stack[sp] = i;
        sp += 1;
    }
    while (sp > 0) : (sp -= 1) endi[stack[sp - 1]] = n;
    i = 0;
    while (i < n) : (i += 1) span[i] = endi[i] - i;

    // self-check: root owns everything, and every container span reconciles.
    if (n == 0 or span[0] != n) std.debug.panic("root span {d} != {d} rows", .{ if (n > 0) span[0] else 0, n });
    var containers: usize = 0;
    i = 0;
    while (i < n) : (i += 1) {
        if (nch[i] == 0) continue;
        containers += 1;
        var s: usize = 1;
        var j: usize = i + 1;
        while (j < i + span[i]) : (j += span[j]) s += span[j];
        if (s != span[i]) std.debug.panic("span mismatch at {s}: {d} vs Σchildren {d}", .{ paths[i], span[i], s });
    }

    // emit the index (containers only — leaves live inside their parent's block)
    var wbuf: [1 << 16]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &wbuf);
    const w = &fw.interface;
    try w.print("path\tline\tspan\tdepth\tkind\tn_children\n", .{});
    i = 0;
    while (i < n) : (i += 1) {
        if (nch[i] == 0) continue;
        try w.print("{s}\t{d}\t{d}\t{d}\t{s}\t{d}\n", .{ paths[i], i + 2, span[i], depths[i], kinds[i], nch[i] });
    }
    try w.flush();

    var ebuf: [256]u8 = undefined;
    var ew = std.Io.File.stderr().writer(init.io, &ebuf);
    const e = &ew.interface;
    try e.print("index: {d} containers · root span {d} == {d} rows · recurrence ✓\n", .{ containers, span[0], n });
    try e.flush();
}
