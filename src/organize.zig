//! organize.zig — a Stage-2 organizer: RE-CLUSTER the map by shape.
//!
//! Reads nodes.tsv (the map of everything) and re-emits every row with each container's
//! DIRECT CHILDREN reordered into shape groups — namespace · type · member · boundary —
//! source order preserved within a group. Pure derivation: it reads the map, never source,
//! so the map stays the single source of truth and this view is fully reproducible from it.
//!
//! Reordering moves each child's WHOLE subtree as a unit, so the output is still a valid
//! pre-order DFS (every subtree contiguous). The `group` is appended as a trailing column,
//! so index.zig (which reads only the leading columns) runs on this view unchanged.
//!
//!   path · depth · kind · name · n_children · detail · group
//!
//! Run: zig run src/organize.zig -- [nodes.tsv]   (default data/std/nodes.tsv)

const std = @import("std");
const tsv = @import("common/tsv.zig");
const grp = @import("group.zig");

/// Cluster order: where you can go deeper → what types exist → what you can call → edges.
fn groupRank(g: grp.Group) u8 {
    return switch (g) {
        .namespace => 0,
        .type => 1,
        .member => 2,
        .boundary => 3,
    };
}

const Sorter = struct {
    groups: []const grp.Group,
    /// Total order (rank, then original index) — deterministic regardless of sort stability;
    /// the index tiebreak keeps source order inside a group.
    fn lt(self: Sorter, a: usize, b: usize) bool {
        const ra = groupRank(self.groups[a]);
        const rb = groupRank(self.groups[b]);
        if (ra != rb) return ra < rb;
        return a < b;
    }
};

/// Everything from the n-th tab-separated column of `line` to end of line ("" if absent).
fn fromCol(line: []const u8, ncol: usize) []const u8 {
    var i: usize = 0;
    var rest = line;
    while (i < ncol) : (i += 1) {
        const t = std.mem.indexOfScalar(u8, rest, '\t') orelse return "";
        rest = rest[t + 1 ..];
    }
    return rest;
}

const View = struct {
    lines: [][]const u8,
    groups: []grp.Group,
    span: []usize,
};

fn emit(w: *std.Io.Writer, v: View, arena: std.mem.Allocator, i: usize) !void {
    const line = v.lines[i];
    // re-emit row i with the group appended as a trailing column.
    try w.print("{s}\t{s}\n", .{ line, grp.groupStr(v.groups[i]) });

    // gather direct children (each owns a contiguous subtree of length span[j]).
    var kids: std.ArrayList(usize) = .empty;
    var j = i + 1;
    while (j < i + v.span[i]) : (j += v.span[j]) try kids.append(arena, j);

    std.sort.pdq(usize, kids.items, Sorter{ .groups = v.groups }, Sorter.lt);
    for (kids.items) |c| try emit(w, v, arena, c);
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const in_path: []const u8 = if (args.len > 1) args[1] else "data/std/nodes.tsv";
    const content = try std.Io.Dir.cwd().readFileAllocOptions(init.io, in_path, arena, .unlimited, .of(u8), 0);

    // count data rows (skip header)
    var n: usize = 0;
    {
        var it = std.mem.splitScalar(u8, content, '\n');
        _ = it.next();
        while (it.next()) |ln| if (ln.len > 0) {
            n += 1;
        };
    }

    const lines = try arena.alloc([]const u8, n);
    const depths = try arena.alloc(u32, n);
    const groups = try arena.alloc(grp.Group, n);
    {
        var it = std.mem.splitScalar(u8, content, '\n');
        _ = it.next();
        var i: usize = 0;
        while (it.next()) |ln| {
            if (ln.len == 0) continue;
            lines[i] = ln;
            depths[i] = std.fmt.parseInt(u32, tsv.col(ln, 1), 10) catch 0;
            // an unrecognized kind shouldn't happen (the map is our own); fall back to boundary.
            groups[i] = grp.groupOfName(tsv.col(ln, 2)) orelse .boundary;
            i += 1;
        }
    }

    // subtree span via monotonic stack: end[i] = first j>i with depth[j] <= depth[i] (same as index.zig).
    const span = try arena.alloc(usize, n);
    {
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
    }

    var wbuf: [1 << 16]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &wbuf);
    const w = &fw.interface;
    try w.print("path\tdepth\tkind\tname\tn_children\tdetail\tgroup\n", .{});
    if (n > 0) try emit(w, .{ .lines = lines, .groups = groups, .span = span }, arena, 0);
    try w.flush();
}
