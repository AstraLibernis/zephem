//! index.zig — the "table of contents" for data/std/extracted/nodes.tsv.
//!
//! nodes.tsv (path · kind · name · vis) is emitted in pre-order DFS, so EVERY node's subtree is a
//! single contiguous run of rows. This reads it and, for each container (a node that has children),
//! records where that block lives:
//!
//!   path · line · span · depth · kind · n_children
//!
//!   line = 1-based file line in nodes.tsv (header is line 1) — a consumer reads exactly the block
//!          with `Read(offset=line, limit=span)` / `sed`.
//!   span = rows in this node's subtree, including the node itself → block is [line, line + span).
//!
//! depth is NOT a column — it's derived from the path (count of top-level `.`, ignoring dots inside
//! `@"…"`). span then falls out of a monotonic-stack scan on depth; n_children is the count of
//! direct children found while reconciling each span.
//!
//! Self-checking: the root's span must equal the whole file, and every container's span must equal
//! 1 + Σ its direct children's spans — asserted before a row is written.
//!
//! Run: zig run derive/index.zig -- [nodes.tsv]   (default data/std/extracted/nodes.tsv)

const std = @import("std");

/// Logical depth from the path: each top-level `.` is one level, and each `()` factory marker is
/// ALSO one level — `std.ArrayList()` is a child of the fn `std.ArrayList`, not its sibling. A `.`
/// or `(` inside `@"…"` is part of a name and doesn't count.
fn depthOf(path: []const u8) u32 {
    var d: u32 = 0;
    var in_quote = false;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        const c = path[i];
        if (c == '"') {
            in_quote = !in_quote;
        } else if (in_quote) {
            continue;
        } else if (c == '.') {
            d += 1;
        } else if (c == '(' and i + 1 < path.len and path[i + 1] == ')') {
            d += 1;
            i += 1;
        }
    }
    return d;
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const in_path: []const u8 = if (args.len > 1) args[1] else "data/std/extracted/nodes.tsv";

    const content = try std.Io.Dir.cwd().readFileAllocOptions(init.io, in_path, arena, .unlimited, .of(u8), 0);

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

    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next(); // header
    var idx: usize = 0;
    while (lines.next()) |ln| {
        if (ln.len == 0) continue;
        var f = std.mem.splitScalar(u8, ln, '\t');
        const path = f.next() orelse continue;
        const kind = f.next() orelse continue; // parser column order: path · kind · name · vis
        paths[idx] = path;
        depths[idx] = depthOf(path);
        kinds[idx] = kind;
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

    // self-check + direct-child counts. A container is any node with descendants (span > 1).
    if (n == 0 or span[0] != n) std.debug.panic("root span {d} != {d} rows", .{ if (n > 0) span[0] else 0, n });
    const nch = try arena.alloc(u32, n);
    var containers: usize = 0;
    i = 0;
    while (i < n) : (i += 1) {
        nch[i] = 0;
        if (span[i] <= 1) continue;
        containers += 1;
        var s: usize = 1;
        var j: usize = i + 1;
        while (j < i + span[i]) : (j += span[j]) {
            s += span[j];
            nch[i] += 1;
        }
        if (s != span[i]) std.debug.panic("span mismatch at {s}: {d} vs Σchildren {d}", .{ paths[i], span[i], s });
    }

    var wbuf: [1 << 16]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &wbuf);
    const w = &fw.interface;
    try w.print("path\tline\tspan\tdepth\tkind\tn_children\n", .{});
    i = 0;
    while (i < n) : (i += 1) {
        if (span[i] <= 1) continue;
        try w.print("{s}\t{d}\t{d}\t{d}\t{s}\t{d}\n", .{ paths[i], i + 2, span[i], depths[i], kinds[i], nch[i] });
    }
    try w.flush();

    var ebuf: [256]u8 = undefined;
    var ew = std.Io.File.stderr().writer(init.io, &ebuf);
    const e = &ew.interface;
    try e.print("index: {d} containers · root span {d} == {d} rows · recurrence ✓\n", .{ containers, span[0], n });
    try e.flush();
}
