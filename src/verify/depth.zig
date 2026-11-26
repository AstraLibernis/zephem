// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! verify/depth.zig — prove the L5 overlay reconciles with the map, read a SECOND way (port of
//! `scripts/verify_depth.nu`). Never trusts status.tsv on its own: re-reads the buckets + the map
//! and checks they reconcile.
//!
//!   PARTITION     each attempted container once: resolved, partial (rescued: some decls failed
//!                 alone), poison, private (reached only through a private decl) or skipped;
//!                 poison file == the poison containers + the failing decls of the partial ones
//!   CONSERVATION  Σ status.n_rows (resolved + partial) == rows in resolved.tsv
//!   REGISTRATION  every attempted container is a real container in index.tsv
//!   HONEST POISON every reason is a compiler `error:` line or a `timeout after` tag
//!   PRISTINE      no path resolves to two conflicting (kind, detail)
//!   FIELD TYPES   every field type the map prints (lookup.fieldTypes) has the shape of the
//!                 compiler's resolved type: no dropped slice, pointer, optional or array
//!   COVERAGE      (--full) every index container was attempted
const std = @import("std");
const stdio = @import("../stdio.zig");
const Ctx = @import("../ctx.zig").Ctx;
const rel = @import("../relation.zig");
const util = @import("../util.zig");
const parse = @import("parse"); // `parent`: the quote-aware one the map is built with

pub fn run(c: Ctx, outdir: []const u8, data_dir: []const u8, index_path: []const u8, full: bool) !bool {
    const a = c.a;
    var er = stdio.stderr().writerStreaming(c.io, try a.alloc(u8, 4096));
    const w = &er.interface;
    defer w.flush() catch {}; // zsnag:ok — progress report only (datasets are written with `try`); a defer cannot return the error

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
    var n_part: usize = 0;
    var n_priv: usize = 0;
    var n_skip: usize = 0;
    var status_poison = std.StringHashMap(void).init(a);
    var status_partial = std.StringHashMap(void).init(a);
    for (status.rows) |r| {
        const gop = try seen.getOrPut(r[sp]);
        if (gop.found_existing) dups += 1;
        const st = r[sst];
        if (std.mem.eql(u8, st, "resolved")) {
            n_res += 1;
        } else if (std.mem.eql(u8, st, "partial")) {
            n_part += 1;
            try status_partial.put(r[sp], {});
        } else if (std.mem.eql(u8, st, "poison")) {
            try status_poison.put(r[sp], {});
        } else if (std.mem.eql(u8, st, "private")) {
            n_priv += 1;
        } else if (std.mem.eql(u8, st, "skipped")) {
            n_skip += 1;
        } else bad_status += 1;
    }
    const n_poi = status_poison.count();
    // Every poison.tsv row is a `poison` container, or one decl of a `partial` container (its
    // parent); every `poison` container has its row, and every `partial` one at least one decl.
    var set_mismatch = false;
    var pfile_set = std.StringHashMap(void).init(a);
    var partial_with_rows = std.StringHashMap(void).init(a);
    var n_decl_poison: usize = 0;
    const pp = poison.col("path");
    for (poison.rows) |r| {
        const p = r[pp];
        if (status_poison.contains(p)) {
            try pfile_set.put(p, {});
        } else if (status_partial.contains(parse.parent(p))) {
            try partial_with_rows.put(parse.parent(p), {});
            n_decl_poison += 1;
        } else set_mismatch = true;
    }
    if (pfile_set.count() != status_poison.count() or partial_with_rows.count() != status_partial.count()) set_mismatch = true;
    const n_attempted = n_res + n_part + n_poi + n_priv + n_skip;
    try w.print("partition:    {d} attempted = {d} resolved + {d} partial + {d} poison + {d} private + {d} skipped   ({d} decl poison rows)\n", .{ status.rows.len, n_res, n_part, n_poi, n_priv, n_skip, n_decl_poison });
    if (dups > 0) {
        try w.print("  ✗ {d} container(s) appear twice in status\n", .{dups});
        ok = false;
    }
    if (bad_status > 0) {
        try w.print("  ✗ {d} row(s) with an unknown status\n", .{bad_status});
        ok = false;
    }
    if (set_mismatch) {
        try w.writeAll("  ✗ poison.tsv ≠ the poison containers plus the failing decls of the partial ones\n");
        ok = false;
    }
    if (n_attempted != status.rows.len) {
        try w.writeAll("  ✗ buckets don't sum to attempted\n");
        ok = false;
    }
    if (dups == 0 and bad_status == 0 and !set_mismatch and n_attempted == status.rows.len)
        try w.writeAll("  ✓ every container is resolved, partial, poison, private, or skipped; the poison file agrees with the ledger\n");

    // 2. CONSERVATION
    var declared: usize = 0;
    for (status.rows) |r| {
        if (std.mem.eql(u8, r[sst], "resolved") or std.mem.eql(u8, r[sst], "partial")) declared += std.fmt.parseInt(usize, r[sn], 10) catch 0;
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
        if (std.mem.find(u8, reason, "error:") == null and !std.mem.startsWith(u8, reason, "timeout after")) dishonest += 1;
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
            const fact = try a.print("{s}\t{s}", .{ r[rk], r[rd] });
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

    // 6. FIELD TYPES — the type the map prints for each field, held against the compiler's.
    if (!try fieldTypesAgree(c, w, resolved, data_dir)) ok = false;

    // 7. COVERAGE (--full)
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

/// Every reflected field whose written type the map prints must agree with the compiler
/// (fieldtype.judge): `agrees`, or `hidden` behind a name. A `wrong` one fails the overlay, so a
/// printer that drops part of a type cannot ship. A reflected field the map prints no type for
/// (an arm of a per-platform const, a factory's instance) is counted, not judged.
fn fieldTypesAgree(c: Ctx, w: *std.Io.Writer, resolved: rel.Table, data_dir: []const u8) !bool {
    const a = c.a;
    const attrs = try rel.load(a, c.io, try join(a, data_dir, "extracted/attrs.tsv"));
    const printed = try lookup.fieldTypes(a, attrs);
    const rp = resolved.col("path");
    const rk = resolved.col("kind");
    const rd = resolved.col("detail");
    var n_field: usize = 0;
    var n_agree: usize = 0;
    var n_hidden: usize = 0;
    var n_unprinted: usize = 0;
    var wrong: std.ArrayList([]const u8) = .empty;
    for (resolved.rows) |r| {
        if (!std.mem.eql(u8, r[rk], "field")) continue;
        n_field += 1;
        const p = printed.get(r[rp]) orelse {
            n_unprinted += 1;
            continue;
        };
        switch (fieldtype.judge(p, r[rd])) {
            .agrees => n_agree += 1,
            .hidden => n_hidden += 1,
            .wrong => try wrong.append(a, try a.print("{s}: map prints `{s}`, compiler says `{s}`", .{ r[rp], p, r[rd] })),
        }
    }
    try w.print("field types:  {d} reflected fields = {d} agree + {d} behind a name + {d} wrong + {d} with no printed type\n", .{ n_field, n_agree, n_hidden, wrong.items.len, n_unprinted });
    if (n_field == 0) {
        try w.writeAll("  ✗ no field was reflected — the check would pass on nothing\n");
        return false;
    }
    if (wrong.items.len > 0) {
        for (wrong.items[0..@min(wrong.items.len, 10)]) |line| try w.print("  ✗ {s}\n", .{line});
        try w.print("  ✗ {d} printed field type(s) disagree with the compiler\n", .{wrong.items.len});
        return false;
    }
    try w.writeAll("  ✓ every printed field type has the compiler's shape\n");
    return true;
}

const join = util.join;
const lookup = @import("../lookup.zig");
const fieldtype = @import("../fieldtype.zig");
