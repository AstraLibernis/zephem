// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! lookup.zig — bake the denormalized "lookup" table that `zephem look` searches (port of
//! `query/build_lookup.nu`). One row per map node, joining nodes + attrs + edges + the resolved
//! and derived overlays into the fixed 17-column contract zlook reads by index:
//!
//!   0 path · 1 depth · 2 kind · 3 name · 4 n_children · 5 detail(loc) · 6 sig · 7 doc
//!
//! CONSUMER CONTRACT — column 6 (`sig`) may contain `///` prose.
//! The signature is recorded as written, and Zig permits a doc comment INSIDE a parameter
//! list, so 68 of 11,273 signatures carry documentation in the middle of them. Every one of
//! those 68 contains a comma inside that prose — and a signature's commas are how a consumer
//! counts parameters. `std.Io.Threaded.init` takes two arguments; counting commas straight
//! through its doc text yields three. That is not hypothetical: it produced a false positive
//! in a downstream linter.
//!
//! Anything parsing `sig` structurally MUST strip `///` runs first. The prose is deliberately
//! left in place rather than moved: for 39 of the 68 the `doc` column is empty, so this is the
//! only copy of that text. Splitting it out correctly needs a real parse — the prose contains
//! its own colons and the parameter name sits between the prose and its `:` — and a
//! half-working splitter mangles signatures, which is worse than leaving them intact.
//!   8 rkind · 9 rdetail · 10 canon · 11 ftype · 12 fval · 13 delegate · 14 vis · 15 mod
//!   16 aka — other public names that reach this node through alias/delegates edges
//!            (`std.array_list.Aligned().append` ← `std.ArrayList().append`); appended last so
//!            readers that take a fixed number of leading columns are unaffected
//!
//! A pure left-join over the node set — same symbol universe as nodes.tsv, enriched. Assembled
//! directly with hash maps (build each right side once, probe per node) rather than chained table
//! joins — one O(n) pass instead of ten table rebuilds.
const std = @import("std");
const argv = @import("args.zig");
const Ctx = @import("ctx.zig").Ctx;
const vars = @import("vars.zig");
const toolchain = @import("toolchain.zig");
const rel = @import("relation.zig");
const redirect = @import("redirect.zig");

pub fn run(c: Ctx, args: []const []const u8) !void {
    const usage =
        \\usage: zephem lookup [--force] [--out PATH]
        \\
        \\  bake the denormalized lookup table that `zephem look` searches
        \\
        \\  --force      bake even if the map's PINNED zig differs from yours
        \\  --out PATH   write somewhere other than $ZEPHEM_LOOKUP
        \\
    ;
    if (try argv.helpRequested(c, args, usage)) return;

    var force = false;
    var out_override: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--force")) force = true else if (std.mem.eql(u8, args[i], "--out")) {
            out_override = argv.value(c, args, &i, "--out", usage);
        } else argv.reject(c, args[i], usage);
    }

    const a = c.a;
    const dir = try vars.dataDir(c);
    var ow = std.Io.File.stdout().writer(c.io, try a.alloc(u8, 1024));
    const w = &ow.interface;
    defer w.flush() catch {};

    // A baked lookup is read later WITHOUT the datasets present, so a stale one can't be caught at
    // read time — refuse to bake from a map whose pinned zig differs from the installed zig.
    if (try toolchain.staleness(c, dir)) |warn| {
        if (force) {
            try w.print("{s}\n", .{warn});
        } else {
            try w.print("{s}\nrefusing to build a possibly-stale lookup.tsv — pass --force to override.\n", .{warn});
            try w.flush();
            std.process.exit(1);
        }
    }

    const table = try build(c, dir);
    const out_path = out_override orelse try vars.lookupPath(c);
    if (std.fs.path.dirname(out_path)) |d| try std.Io.Dir.cwd().createDirPath(c.io, d);
    try rel.writeFile(table, c.io, out_path);
    try w.print("lookup: {d} rows -> {s}\n", .{ table.rows.len, out_path });

    // The table used to be baked outside the repo. Point out a leftover copy; never delete it
    // ourselves, it is the user's file system.
    if (vars.legacyLookupPath(c)) |old| {
        if (std.Io.Dir.cwd().access(c.io, old, .{})) |_| {
            try w.print("note: an old lookup table is still at {s}; zephem no longer uses it and it can be deleted.\n", .{old});
        } else |_| {}
    }
}

/// Build the denormalized lookup table for the datasets in `dir`.
pub fn build(c: Ctx, dir: []const u8) !rel.Table {
    const a = c.a;
    const nodes = try load(c, dir, "extracted/nodes.tsv");
    const attrs = try load(c, dir, "extracted/attrs.tsv");
    const edges = try load(c, dir, "extracted/edges.tsv");
    const resolved = try load(c, dir, "extracted/resolved.tsv");
    const index = try load(c, dir, "derived/index.tsv");
    const canon = try load(c, dir, "derived/canon.tsv");

    // right-hand maps (first occurrence wins — Nushell uniq-by path)
    var nchild = try mapCol(a, index, "path", "n_children");
    var detail = try attrCol(a, attrs, "loc");
    var sig = try attrCol(a, attrs, "sig");
    var doc = try attrCol(a, attrs, "doc");
    var fval = try attrCol(a, attrs, "value");
    var canon_m = try mapCol(a, canon, "path", "canon");
    var htype = try edgeCol(a, edges, "has_type");
    var deleg = try edgeCol(a, edges, "delegates");
    var modm = try attrCol(a, attrs, "mod");
    const redirects = try redirect.Redirects.build(a, nodes, edges);
    var aka = try redirect.Aka.init(&redirects);

    // resolved → (rkind, rdetail), first occurrence per path
    var rkind = std.StringHashMap([]const u8).init(a);
    var rdetail = std.StringHashMap([]const u8).init(a);
    {
        const rp = resolved.col("path");
        const rk = resolved.col("kind");
        const rd = resolved.col("detail");
        for (resolved.rows) |r| {
            const gop = try rkind.getOrPut(r[rp]);
            if (!gop.found_existing) {
                gop.value_ptr.* = r[rk];
                try rdetail.put(r[rp], r[rd]);
            }
        }
    }

    const np = nodes.col("path");
    const nk = nodes.col("kind");
    const nn = nodes.col("name");
    const nv = nodes.col("vis");
    const rows = try a.alloc(rel.Row, nodes.rows.len);
    for (nodes.rows, 0..) |r, k| {
        const path = r[np];
        const kind = r[nk];
        const is_fieldish = std.mem.eql(u8, kind, "field") or std.mem.eql(u8, kind, "tag");
        const row = try a.alloc([]const u8, 17);
        row[0] = path;
        row[1] = try depthStr(a, path);
        row[2] = kind;
        row[3] = r[nn];
        row[4] = nchild.get(path) orelse "";
        row[5] = detail.get(path) orelse "";
        row[6] = sig.get(path) orelse "";
        row[7] = doc.get(path) orelse "";
        row[8] = rkind.get(path) orelse "";
        row[9] = rdetail.get(path) orelse "";
        row[10] = canon_m.get(path) orelse "";
        row[11] = if (is_fieldish) (htype.get(path) orelse "") else ""; // ftype: field/tag only
        row[12] = fval.get(path) orelse "";
        row[13] = deleg.get(path) orelse "";
        row[14] = r[nv];
        row[15] = modm.get(path) orelse ""; // extern/export/inline/threadlocal/comptime/var
        row[16] = try aka.of(path);
        rows[k] = row;
    }
    // A left-join over nodes must preserve exactly the node rows (1:1) — assert it, fail loud.
    std.debug.assert(rows.len == nodes.rows.len);
    return rel.Table{
        .columns = &.{ "path", "depth", "kind", "name", "n_children", "detail", "sig", "doc", "rkind", "rdetail", "canon", "ftype", "fval", "delegate", "vis", "mod", "aka" },
        .rows = rows,
        .a = a,
    };
}

/// path-depth: dotted levels + factory-call levels — count('.') + count("()"), matching
/// build_lookup.nu's `(split '.' len -1) + (split '()' len -1)`.
fn depthStr(a: std.mem.Allocator, p: []const u8) ![]const u8 {
    var dots: usize = 0;
    for (p) |ch| {
        if (ch == '.') dots += 1;
    }
    const calls = std.mem.count(u8, p, "()");
    return std.fmt.allocPrint(a, "{d}", .{dots + calls});
}

/// A `path → value` map from a table's two columns (first occurrence wins).
fn mapCol(a: std.mem.Allocator, t: rel.Table, key: []const u8, val: []const u8) !std.StringHashMap([]const u8) {
    var m = std.StringHashMap([]const u8).init(a);
    const ki = t.col(key);
    const vi = t.col(val);
    for (t.rows) |r| {
        const gop = try m.getOrPut(r[ki]);
        if (!gop.found_existing) gop.value_ptr.* = r[vi];
    }
    return m;
}

/// attrs `path → value` for one attr name (first occurrence).
fn attrCol(a: std.mem.Allocator, attrs: rel.Table, name: []const u8) !std.StringHashMap([]const u8) {
    var m = std.StringHashMap([]const u8).init(a);
    const ap = attrs.col("path");
    const aa = attrs.col("attr");
    const av = attrs.col("value");
    for (attrs.rows) |r| {
        if (!std.mem.eql(u8, r[aa], name)) continue;
        const gop = try m.getOrPut(r[ap]);
        if (!gop.found_existing) gop.value_ptr.* = r[av];
    }
    return m;
}

/// edges `src → target` for one edge type (first occurrence).
fn edgeCol(a: std.mem.Allocator, edges: rel.Table, etype: []const u8) !std.StringHashMap([]const u8) {
    var m = std.StringHashMap([]const u8).init(a);
    const es = edges.col("src");
    const et = edges.col("type");
    const eg = edges.col("target");
    for (edges.rows) |r| {
        if (!std.mem.eql(u8, r[et], etype)) continue;
        const gop = try m.getOrPut(r[es]);
        if (!gop.found_existing) gop.value_ptr.* = r[eg];
    }
    return m;
}

fn load(c: Ctx, dir: []const u8, rel_path: []const u8) !rel.Table {
    return rel.load(c.a, c.io, try std.fs.path.join(c.a, &.{ dir, rel_path }));
}
