//! verify/std.zig — the backward check: read the three streams a SECOND way and prove they
//! reconcile (port of `scripts/verify_std.nu`). No external oracle — the data checks itself; a
//! regeneration this rejects is rejected.
//!
//!   CONNECTED  every non-root node hangs off a real parent
//!   PARTITION  every row is a known kind
//!   INDEX      every index entry is a real node; root span == total rows
//!   ATTRS      every attr keys onto a real node; known attr kinds only
//!   EDGES      every edge starts at a real node; every local/cross edge resolves to a real node
//!
//! Membership is a hash-set lookup (not a per-row scan) — the same discipline the Nushell used.
const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const rel = @import("../relation.zig");
const parse = @import("parse");

const known_kinds = [_][]const u8{ "ns", "nsref", "nserr", "modref", "struct", "enum", "union", "opaque", "fn", "const", "alias", "field", "tag" };
const known_attrs = [_][]const u8{ "doc", "sig", "value", "loc", "example" };

fn isKnown(set: []const []const u8, v: []const u8) bool {
    for (set) |k| if (std.mem.eql(u8, k, v)) return true;
    return false;
}

/// Run the five integrity checks against the datasets in `data_dir`. Returns true iff all pass;
/// prints a per-check report to stderr.
pub fn run(c: Ctx, data_dir: []const u8) !bool {
    const a = c.a;
    var er = std.Io.File.stderr().writer(c.io, try a.alloc(u8, 4096));
    const w = &er.interface;
    defer w.flush() catch {};

    const nodes = try rel.load(a, c.io, try join(a, data_dir, "extracted/nodes.tsv"));
    const n = nodes.rows.len;
    if (n == 0) {
        try w.writeAll("verify: ✗ empty node set\n");
        return false;
    }
    const p_i = nodes.col("path");
    const k_i = nodes.col("kind");
    const root = nodes.rows[0][p_i];

    // node set — the resolution target for every membership check.
    var node_set = std.StringHashMap(void).init(a);
    for (nodes.rows) |r| try node_set.put(r[p_i], {});

    var ok = true;

    // 1. CONNECTED
    var orphans: usize = 0;
    for (nodes.rows) |r| {
        const path = r[p_i];
        if (std.mem.eql(u8, path, root)) continue;
        const par = parse.parent(path);
        if (par.len == 0) continue;
        if (!node_set.contains(par)) orphans += 1;
    }
    try w.print("connected:  {d} nodes\n", .{n});
    if (orphans > 0) {
        try w.print("  ✗ {d} orphan(s) — parent path missing\n", .{orphans});
        ok = false;
    } else try w.writeAll("  ✓ every node hangs off a real parent\n");

    // 2. PARTITION — every row a known kind (+ by-kind census).
    var bad_kind: usize = 0;
    for (nodes.rows) |r| {
        if (!isKnown(&known_kinds, r[k_i])) bad_kind += 1;
    }
    const by_kind = try rel.groupBy(a, nodes, "kind");
    try w.print("partition:  {d} distinct kinds\n", .{by_kind.len});
    if (bad_kind > 0) {
        try w.print("  ✗ {d} row(s) with an unknown kind\n", .{bad_kind});
        ok = false;
    } else try w.writeAll("  ✓ every row a known kind\n");

    // 3. INDEX — every entry a real node; root span == total rows.
    const ix = try rel.load(a, c.io, try join(a, data_dir, "derived/index.tsv"));
    {
        const ip = ix.col("path");
        const is = ix.col("span");
        var notreal: usize = 0;
        var max_span: usize = 0;
        for (ix.rows) |r| {
            if (!node_set.contains(r[ip])) notreal += 1;
            const s = std.fmt.parseInt(usize, r[is], 10) catch 0;
            if (s > max_span) max_span = s;
        }
        try w.print("index:      {d} containers\n", .{ix.rows.len});
        if (notreal > 0) {
            try w.print("  ✗ {d} index row(s) point at a non-node\n", .{notreal});
            ok = false;
        } else try w.writeAll("  ✓ every index entry is a real node\n");
        if (max_span != n) {
            try w.print("  ✗ root span {d} != {d} rows\n", .{ max_span, n });
            ok = false;
        } else try w.writeAll("  ✓ root span == total rows\n");
    }

    // 4. ATTRS — every attr keys onto a real node; known attr kinds only.
    const attrs = try rel.load(a, c.io, try join(a, data_dir, "extracted/attrs.tsv"));
    {
        const ap = attrs.col("path");
        const at = attrs.col("attr");
        var orphan: usize = 0;
        var badk: usize = 0;
        for (attrs.rows) |r| {
            if (!node_set.contains(r[ap])) orphan += 1;
            if (!isKnown(&known_attrs, r[at])) badk += 1;
        }
        try w.print("attrs:      {d} rows\n", .{attrs.rows.len});
        if (orphan > 0) {
            try w.print("  ✗ {d} attr(s) key onto a missing node\n", .{orphan});
            ok = false;
        } else try w.writeAll("  ✓ every attr keys onto a real node\n");
        if (badk > 0) {
            try w.print("  ✗ {d} attr(s) of an unknown kind\n", .{badk});
            ok = false;
        } else try w.writeAll("  ✓ every attr a known kind (doc/sig/value/loc/example)\n");
    }

    // 5. EDGES — start at a real node; every resolved (local/cross) edge points at a real node.
    const edges = try rel.load(a, c.io, try join(a, data_dir, "extracted/edges.tsv"));
    {
        const es = edges.col("src");
        const et = edges.col("target");
        const esc = edges.col("scope");
        var orphan: usize = 0;
        var bad_link: usize = 0;
        for (edges.rows) |r| {
            if (!node_set.contains(r[es])) orphan += 1;
            const sc = r[esc];
            if (std.mem.eql(u8, sc, "local") or std.mem.eql(u8, sc, "cross")) {
                if (!node_set.contains(r[et])) bad_link += 1;
            }
        }
        try w.print("edges:      {d} rows\n", .{edges.rows.len});
        if (orphan > 0) {
            try w.print("  ✗ {d} edge(s) start at a missing node\n", .{orphan});
            ok = false;
        } else try w.writeAll("  ✓ every edge starts at a real node\n");
        if (bad_link > 0) {
            try w.print("  ✗ {d} resolved edge(s) point at a MISSING node — a link lies\n", .{bad_link});
            ok = false;
        } else try w.writeAll("  ✓ every local/cross edge resolves to a real node — links are valid\n");
    }

    if (ok) try w.writeAll("VERDICT: ✓ all integrity checks pass\n") else try w.writeAll("VERDICT: ✗ integrity FAILED\n");
    return ok;
}

fn join(a: std.mem.Allocator, dir: []const u8, rel_path: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ dir, rel_path });
}
