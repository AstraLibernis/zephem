//! verify/depth.zig — prove the L5 overlay reconciles with the map, read a SECOND way (port of
//! `scripts/verify_depth.nu`). Never trusts status.tsv on its own: re-reads the buckets + the map
//! and checks they reconcile.
//!
//!   PARTITION     each attempted container once, resolved OR poison; poison file == status slice
//!   CONSERVATION  Σ status.n_rows (resolved) == rows in resolved.tsv
//!   REGISTRATION  every attempted container is a real container in index.tsv
//!   HONEST POISON every reason is a compiler `error:` line or a `timeout after` tag
//!   PRISTINE      no path resolves to two conflicting (kind, detail)
//!   COVERAGE      (--full) every index container was attempted
const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const rel = @import("../relation.zig");
const util = @import("../util.zig");

pub fn run(c: Ctx, outdir: []const u8, index_path: []const u8, full: bool) !bool {
    const a = c.a;
    var er = std.Io.File.stderr().writer(c.io, try a.alloc(u8, 4096));
    const w = &er.interface;
    defer w.flush() catch {};

    const status = try rel.load(a, c.io, try join(a, outdir, "extracted/status.tsv"));
    const resolved = try rel.load(a, c.io, try join(a, outdir, "extracted/resolved.tsv"));
    const poison = try rel.load(a, c.io, try join(a, outdir, "extracted/poison.tsv"));
    const index = try rel.load(a, c.io, index_path);

    var ok = true;
    const sp = status.col("path");
    const sst = status.col("status");
    const sn = status.col("n_rows");

    // node/index sets
    var idx_set = std.StringHashMap(void).init(a);
    for (index.rows) |r| try idx_set.put(r[index.col("path")], {});

    // 1. PARTITION
    var seen = std.StringHashMap(void).init(a);
    var dups: usize = 0;
    var bad_status: usize = 0;
    var n_res: usize = 0;
    var n_skip: usize = 0;
    var status_poison = std.StringHashMap(void).init(a);
    for (status.rows) |r| {
        const gop = try seen.getOrPut(r[sp]);
        if (gop.found_existing) dups += 1;
        const st = r[sst];
        if (std.mem.eql(u8, st, "resolved")) {
            n_res += 1;
        } else if (std.mem.eql(u8, st, "poison")) {
            try status_poison.put(r[sp], {});
        } else if (std.mem.eql(u8, st, "skipped")) {
            n_skip += 1;
        } else bad_status += 1;
    }
    const n_poi = status_poison.count();
    // poison.tsv path set must equal the status poison slice
    var pfile_set = std.StringHashMap(void).init(a);
    const pp = poison.col("path");
    for (poison.rows) |r| try pfile_set.put(r[pp], {});
    var set_mismatch = pfile_set.count() != status_poison.count();
    if (!set_mismatch) {
        var it = status_poison.keyIterator();
        while (it.next()) |k| if (!pfile_set.contains(k.*)) {
            set_mismatch = true;
            break;
        };
    }
    try w.print("partition:    {d} attempted = {d} resolved + {d} poison + {d} skipped\n", .{ status.rows.len, n_res, n_poi, n_skip });
    if (dups > 0) {
        try w.print("  ✗ {d} container(s) appear twice in status\n", .{dups});
        ok = false;
    }
    if (bad_status > 0) {
        try w.print("  ✗ {d} row(s) with an unknown status\n", .{bad_status});
        ok = false;
    }
    if (set_mismatch) {
        try w.writeAll("  ✗ poison status set ≠ poison.tsv paths\n");
        ok = false;
    }
    if (n_res + n_poi + n_skip != status.rows.len) {
        try w.writeAll("  ✗ buckets don't sum to attempted\n");
        ok = false;
    }
    if (dups == 0 and bad_status == 0 and !set_mismatch and n_res + n_poi + n_skip == status.rows.len)
        try w.writeAll("  ✓ every container is resolved, poison, or skipped; the poison file agrees with the ledger\n");

    // 2. CONSERVATION
    var declared: usize = 0;
    for (status.rows) |r| {
        if (std.mem.eql(u8, r[sst], "resolved")) declared += std.fmt.parseInt(usize, r[sn], 10) catch 0;
    }
    const actual = resolved.rows.len;
    try w.print("conservation: Σ resolved n_rows = {d}   resolved.tsv rows = {d}\n", .{ declared, actual });
    if (declared != actual) {
        try w.writeAll("  ✗ row accounting disagrees\n");
        ok = false;
    } else try w.writeAll("  ✓ resolved rows fully accounted to their containers\n");

    // 3. REGISTRATION
    var phantom: usize = 0;
    for (status.rows) |r| {
        if (!idx_set.contains(r[sp])) phantom += 1;
    }
    try w.print("registration: {d} attempted containers vs {d} in index.tsv\n", .{ status.rows.len, index.rows.len });
    if (phantom > 0) {
        try w.print("  ✗ {d} attempted path(s) are not containers in the map\n", .{phantom});
        ok = false;
    } else try w.writeAll("  ✓ every attempted container exists in the map\n");

    // 4. HONEST POISON
    const pr = poison.col("reason");
    var dishonest: usize = 0;
    for (poison.rows) |r| {
        const reason = r[pr];
        if (std.mem.indexOf(u8, reason, "error:") == null and !std.mem.startsWith(u8, reason, "timeout after")) dishonest += 1;
    }
    try w.print("honest-poison: {d} poison reason(s)\n", .{poison.rows.len});
    if (dishonest > 0) {
        try w.print("  ✗ {d} reason(s) are neither a compiler error nor a timeout tag\n", .{dishonest});
        ok = false;
    } else try w.writeAll("  ✓ every poison reason is a compiler error or an explicit timeout\n");

    // 5. PRISTINE — no path resolves to two different (kind, detail).
    {
        const rp = resolved.col("path");
        const rk = resolved.col("kind");
        const rd = resolved.col("detail");
        var facts = std.StringHashMap([]const u8).init(a); // path → "kind\tdetail" (first seen)
        var distinct = std.StringHashMap(void).init(a);
        var conflicts: usize = 0;
        for (resolved.rows) |r| {
            try distinct.put(r[rp], {});
            const fact = try std.fmt.allocPrint(a, "{s}\t{s}", .{ r[rk], r[rd] });
            const gop = try facts.getOrPut(r[rp]);
            if (gop.found_existing) {
                if (!std.mem.eql(u8, gop.value_ptr.*, fact)) conflicts += 1;
            } else gop.value_ptr.* = fact;
        }
        try w.print("pristine:     {d} distinct resolved paths\n", .{distinct.count()});
        if (conflicts > 0) {
            try w.print("  ✗ {d} path(s) carry conflicting facts\n", .{conflicts});
            ok = false;
        } else try w.writeAll("  ✓ no path resolves to two different values\n");
    }

    // 6. COVERAGE (--full)
    if (full) {
        var missed: usize = 0;
        for (index.rows) |r| {
            if (!seen.contains(r[index.col("path")])) missed += 1;
        }
        try w.print("coverage:     {d} attempted / {d} map containers\n", .{ status.rows.len, index.rows.len });
        if (missed > 0) {
            try w.print("  ✗ {d} map container(s) never attempted\n", .{missed});
            ok = false;
        } else try w.writeAll("  ✓ every container in the map was attempted\n");
    }

    if (ok) try w.writeAll("DEPTH VERDICT: ✓ overlay reconciles with the map\n") else try w.writeAll("DEPTH VERDICT: ✗ reconciliation FAILED\n");
    return ok;
}

const join = util.join;
