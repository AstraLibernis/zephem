// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! lookup.zig — bake the denormalized "lookup" table that `zephem look` searches (port of
//! `query/build_lookup.nu`). One row per map node, joining nodes + attrs + edges + the resolved
//! and derived overlays into the fixed 20-column contract zlook reads by index:
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
//!            (`std.array_list.Aligned().append` ← `std.ArrayList().append`)
//!   17 redirect — this node's own first alias/delegates hop, `alias:<target>` /
//!            `delegates:<target>` (what `map show`/`map doc` follow)
//!   18 errmembers — a named error set's members, `, `-joined
//!   19 arity — a builtin's argument count from the compiler's table (`var` if variadic)
//! Columns are only ever APPENDED, so readers that take a fixed number of leading columns
//! (zcanon) are unaffected.
//!
//! Baked beside it: `examples.tsv` (`path · body`, every std `test` body by the path it is
//! anchored to, plus each builtin's langref example) and `lookup.stamp`, which records which
//! datasets the bake came from. `look` and `map` call `ensure` and rebuild all three when the
//! stamp no longer matches, so a query never answers from an index older than the map.
//!
//! A pure left-join over the node set — same symbol universe as nodes.tsv, enriched — plus one
//! row per builtin from builtins.tsv (kind `builtin`), so `look` finds `@intCast` too. Assembled
//! directly with hash maps (build each right side once, probe per node) rather than chained table
//! joins — one O(n) pass instead of ten table rebuilds.
const std = @import("std");
const argv = @import("args.zig");
const Ctx = @import("ctx.zig").Ctx;
const vars = @import("vars.zig");
const toolchain = @import("toolchain.zig");
const rel = @import("relation.zig");
const redirect = @import("redirect.zig");
const util = @import("util.zig");

const ncols = 20;

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
    defer w.flush() catch {}; // zsnag:ok — progress report only (datasets are written with `try`); a defer cannot return the error

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

    const out_path = out_override orelse try vars.lookupPath(c);
    const rows = try bake(c, dir, out_path);
    try w.print("lookup: {d} rows -> {s} (+ examples.tsv, lookup.stamp)\n", .{ rows, out_path });

    // The table used to be baked outside the repo. Point out a leftover copy; never delete it
    // ourselves, it is the user's file system.
    if (vars.legacyLookupPath(c)) |old| {
        if (std.Io.Dir.cwd().access(c.io, old, .{})) |_| {
            try w.print("note: an old lookup table is still at {s}; zephem no longer uses it and it can be deleted.\n", .{old});
        } else |_| {}
    }
}

/// The lookup table's format. Bump it when a column is added, so every older bake is rebuilt.
const format = "zephem-lookup 2";

/// What a bake from `dir` must be stamped with: the format plus every dataset manifest. A
/// regenerated map changes a manifest, so the stamp stops matching.
fn expectedStamp(c: Ctx, dir: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(c.a, format ++ "\n");
    const manifests = [_][]const u8{ "SHA256SUMS", "SHA256SUMS.depth", "SHA256SUMS.canon", "SHA256SUMS.consensus", "SHA256SUMS.doccov", "SHA256SUMS.sigshape", "SHA256SUMS.callcard" };
    for (manifests) |m| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(c.io, try std.fs.path.join(c.a, &.{ dir, m }), c.a, .unlimited) catch "";
        try out.print(c.a, "## {s}\n{s}", .{ m, bytes });
    }
    return out.items;
}

/// Bake lookup.tsv at `out_path`, with examples.tsv and lookup.stamp beside it. Returns the
/// row count.
pub fn bake(c: Ctx, dir: []const u8, out_path: []const u8) !usize {
    const b = try build(c, dir);
    const out_dir = std.fs.path.dirname(out_path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(c.io, out_dir);
    try rel.writeFile(b.table, c.io, out_path);
    try util.writeFile(c.io, try std.fs.path.join(c.a, &.{ out_dir, "examples.tsv" }), b.examples);
    // the stamp last: a bake interrupted before this point is not trusted next time
    try util.writeFile(c.io, try std.fs.path.join(c.a, &.{ out_dir, "lookup.stamp" }), try expectedStamp(c, dir));
    return b.table.rows.len;
}

pub const Ensured = enum { fresh, rebuilt, unverified };

/// Make sure the baked table matches the datasets, rebuilding it (about 80 ms) if it is
/// missing or its stamp is out of date. `unverified`: there are no datasets to check against
/// (a `$ZEPHEM_LOOKUP` table used on its own), so the table is used as it is. Fails only when
/// there is neither a usable table nor the datasets to bake one.
pub fn ensure(c: Ctx) !Ensured {
    const path = try vars.lookupPath(c);
    const dir = vars.dataDir(c) catch return if (exists(c, path)) .unverified else error.FileNotFound;
    if (!exists(c, try std.fs.path.join(c.a, &.{ dir, "extracted/nodes.tsv" }))) {
        return if (exists(c, path)) .unverified else error.FileNotFound;
    }
    const want = try expectedStamp(c, dir);
    const have = std.Io.Dir.cwd().readFileAlloc(c.io, try vars.besideLookup(c, "lookup.stamp"), c.a, .unlimited) catch "";
    if (std.mem.eql(u8, have, want) and exists(c, path) and exists(c, try vars.besideLookup(c, "examples.tsv"))) return .fresh;
    _ = try bake(c, dir, path);
    return .rebuilt;
}

fn exists(c: Ctx, path: []const u8) bool {
    std.Io.Dir.cwd().access(c.io, path, .{}) catch return false;
    return true;
}

const Built = struct { table: rel.Table, examples: []const u8 };

/// Build the denormalized lookup table (and the examples file) for the datasets in `dir`.
fn build(c: Ctx, dir: []const u8) !Built {
    const a = c.a;
    const nodes = try load(c, dir, "extracted/nodes.tsv");
    const attrs = try load(c, dir, "extracted/attrs.tsv");
    const edges = try load(c, dir, "extracted/edges.tsv");
    const resolved = try load(c, dir, "extracted/resolved.tsv");
    const index = try load(c, dir, "derived/index.tsv");
    const canon = try load(c, dir, "derived/canon.tsv");
    const builtins = try load(c, dir, "extracted/builtins.tsv");

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
    // error-set members, `, `-joined per path, and every example body by anchor path
    var errm = std.StringHashMap([]const u8).init(a);
    var examples: std.ArrayList(u8) = .empty;
    try examples.appendSlice(a, "path\tbody\n");
    {
        const ap = attrs.col("path");
        const aa = attrs.col("attr");
        const av = attrs.col("value");
        for (attrs.rows) |r| {
            if (std.mem.eql(u8, r[aa], "errmember")) {
                const g = try errm.getOrPut(r[ap]);
                g.value_ptr.* = if (!g.found_existing) r[av] else try std.fmt.allocPrint(a, "{s}, {s}", .{ g.value_ptr.*, r[av] });
            } else if (std.mem.eql(u8, r[aa], "example")) {
                try examples.print(a, "{s}\t{s}\n", .{ r[ap], r[av] });
            }
        }
    }
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
    const rows = try a.alloc(rel.Row, nodes.rows.len + builtins.rows.len);
    for (nodes.rows, 0..) |r, k| {
        const path = r[np];
        const kind = r[nk];
        const is_fieldish = std.mem.eql(u8, kind, "field") or std.mem.eql(u8, kind, "tag");
        const row = try a.alloc([]const u8, ncols);
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
        row[17] = if (redirects.hop_of.get(path)) |h| try std.fmt.allocPrint(a, "{s}:{s}", .{ h.kind, h.target }) else "";
        row[18] = errm.get(path) orelse "";
        row[19] = "";
        rows[k] = row;
    }
    // Builtins (`@intCast`, …) follow the node rows: kind `builtin`, path = name, depth 0.
    const bn = builtins.col("name");
    const bs = builtins.col("sig");
    const bd = builtins.col("doc");
    const bp = builtins.col("params");
    const be = builtins.col("example");
    for (builtins.rows, nodes.rows.len..) |r, k| {
        if (r[be].len > 0) try examples.print(a, "{s}\t{s}\n", .{ r[bn], r[be] });
        const row = try a.alloc([]const u8, ncols);
        @memset(row, "");
        row[0] = r[bn];
        row[1] = "0";
        row[2] = "builtin";
        row[3] = r[bn];
        row[6] = r[bs];
        row[7] = r[bd];
        row[14] = "pub";
        row[19] = r[bp];
        rows[k] = row;
    }
    return .{ .table = rel.Table{
        .columns = &.{ "path", "depth", "kind", "name", "n_children", "detail", "sig", "doc", "rkind", "rdetail", "canon", "ftype", "fval", "delegate", "vis", "mod", "aka", "redirect", "errmembers", "arity" },
        .rows = rows,
        .a = a,
    }, .examples = examples.items };
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
