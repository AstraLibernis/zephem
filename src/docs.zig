// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! docs.zig — regenerate the markdown docs from templates + live data (port of
//! `scripts/build_arch.nu`). Nothing is hand-authored: prose lives in `templates/*.tmpl.md`, every
//! number is an `@@TOKEN@@` injected from the datasets, and each output leads with a generated
//! banner. `--check` proves each doc rebuilds byte-identical.
const std = @import("std");
const argv = @import("args.zig");
const Ctx = @import("ctx.zig").Ctx;
const vars = @import("vars.zig");
const rel = @import("relation.zig");
const util = @import("util.zig");

const Page = struct { tmpl: []const u8, out: []const u8 };
const pages = [_]Page{
    .{ .tmpl = "templates/root.tmpl.md", .out = "README.md" },
    .{ .tmpl = "templates/plan.tmpl.md", .out = "PLAN.md" },
    .{ .tmpl = "templates/parse.tmpl.md", .out = "parse/README.md" },
    .{ .tmpl = "templates/reflect.tmpl.md", .out = "reflect/README.md" },
    .{ .tmpl = "templates/data.tmpl.md", .out = "data/README.md" },
    .{ .tmpl = "templates/extracted.tmpl.md", .out = "data/std/extracted/README.md" },
    .{ .tmpl = "templates/derived.tmpl.md", .out = "data/std/derived/README.md" },
};

const Sub = struct { key: []const u8, val: []const u8 };

pub fn run(c: Ctx, args: []const []const u8) !void {
    const usage =
        \\usage: zephem docs [--check]
        \\
        \\  regenerate the markdown docs from templates/
        \\
        \\  --check      prove they regenerate unchanged; do not overwrite
        \\
    ;
    if (try argv.helpRequested(c, args, usage)) return;

    var check = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) check = true else argv.reject(c, arg, usage);
    }
    const a = c.a;
    var ow = std.Io.File.stdout().writer(c.io, try a.alloc(u8, 4096));
    const w = &ow.interface;
    defer w.flush() catch {};

    const subs = try computeSubs(c);

    var ok = true;
    for (pages) |p| {
        const tmpl = try std.Io.Dir.cwd().readFileAlloc(c.io, try vars.repoFile(c, p.tmpl), a, .unlimited);
        var md: []const u8 = tmpl;
        for (subs) |s| md = try replaceAll(a, md, s.key, s.val);
        const banner = try std.fmt.allocPrint(a, "<!-- GENERATED from {s} by `zephem docs` — edit the template, not this file. -->\n", .{p.tmpl});
        const content = try std.mem.concat(a, u8, &.{ banner, md });

        if (std.mem.indexOf(u8, content, "@@") != null) {
            try w.print("arch: ✗ unfilled @@TOKEN@@ remains in {s} — template/generator out of sync\n", .{p.out});
            try w.flush();
            std.process.exit(1);
        }

        const out_path = try vars.repoFile(c, p.out);
        if (check) {
            const existing = std.Io.Dir.cwd().readFileAlloc(c.io, out_path, a, .unlimited) catch {
                try w.print("arch: ✗ {s} missing — run without --check\n", .{p.out});
                try w.flush();
                std.process.exit(1);
            };
            if (std.mem.eql(u8, content, existing)) {
                try w.print("  ✓ {s}\n", .{p.out});
            } else {
                try w.print("  ✗ DRIFT {s}\n", .{p.out});
                ok = false;
            }
        } else {
            try writeBytes(c, out_path, content);
            try w.print("  ✓ {s}\n", .{p.out});
        }
    }
    if (!ok) {
        try w.writeAll("arch: ✗ DRIFT — a doc no longer matches the data; rerun `zephem docs`\n");
        try w.flush();
        std.process.exit(1);
    }
    if (check) try w.writeAll("arch: ✓ every doc regenerates byte-identical from data/std + engine source\n") else try w.writeAll("arch: ✓ regenerated the markdown docs from data/std + engine source\n");
}

fn computeSubs(c: Ctx) ![]const Sub {
    const a = c.a;
    const dir = try vars.dataDir(c);
    const nodes = try load(c, dir, "extracted/nodes.tsv");
    const attrs = try load(c, dir, "extracted/attrs.tsv");
    const edges = try load(c, dir, "extracted/edges.tsv");
    const index = try load(c, dir, "derived/index.tsv");
    const canon = try load(c, dir, "derived/canon.tsv");
    const consensus = try load(c, dir, "derived/consensus.tsv");
    const status = try load(c, dir, "extracted/status.tsv");
    const poison = try load(c, dir, "extracted/poison.tsv");
    const doccov = try load(c, dir, "derived/doccov.tsv");
    const sigshape = try load(c, dir, "derived/sigshape.tsv");
    const callcard = try load(c, dir, "derived/callcard.tsv");
    const resolved = try load(c, dir, "extracted/resolved.tsv");

    const n = nodes.rows.len;
    const priv = eqCount(nodes, "vis", "priv");
    const files = eqCount(nodes, "kind", "ns");
    const fields = eqCount(nodes, "kind", "field") + eqCount(nodes, "kind", "tag");
    const maxdepth = maxInt(index, "depth");

    const a_doc = eqCount(attrs, "attr", "doc");
    const a_sig = eqCount(attrs, "attr", "sig");
    const a_val = eqCount(attrs, "attr", "value");
    const a_loc = eqCount(attrs, "attr", "loc");
    const a_ex = eqCount(attrs, "attr", "example");

    const e_local = eqCount(edges, "scope", "local");
    const e_cross = eqCount(edges, "scope", "cross");
    const e_prim = eqCount(edges, "scope", "primitive");
    const e_gen = eqCount(edges, "scope", "generic");
    const e_mod = eqCount(edges, "scope", "module");
    const e_inl = eqCount(edges, "scope", "inline");
    const e_unres = eqCount(edges, "scope", "unresolved");
    const e_res = e_local + e_cross + e_prim + e_gen;

    const dc_total = doccov.rows.len;
    const dc_doc = eqCount(doccov, "documented", "yes");
    const dc_pct = pct(dc_doc, dc_total);

    const cc_both = eqCount(callcard, "witness", "both");
    const cc_parser = eqCount(callcard, "witness", "parser-only");
    const cc_reflect = eqCount(callcard, "witness", "reflect-only");

    const con_ro = eqCount(consensus, "origin", "read-only");
    const con_run = eqCount(consensus, "origin", "run-only");
    const con_rr = eqCount(consensus, "origin", "read+run");

    const canon_families = try distinctCount(a, canon, "canon");
    // PINNED's first line is the version stamp (`zig X.Y.Z`); the second is the target triple.
    const pinned_raw = try load_raw(c, dir, "PINNED");
    const pinned = std.mem.trim(u8, std.mem.sliceTo(pinned_raw, '\n'), " \t\r");
    // PINNED's second line is `target <triple>`; @@TARGET@@ is its arch-os prefix (e.g. x86_64-linux).
    const pinned_target = blk: {
        const nl = std.mem.indexOfScalar(u8, pinned_raw, '\n') orelse break :blk "";
        const line2 = std.mem.trim(u8, std.mem.sliceTo(pinned_raw[nl + 1 ..], '\n'), " \t\r");
        const after = if (std.mem.startsWith(u8, line2, "target ")) line2["target ".len..] else line2;
        break :blk std.mem.sliceTo(after, '.');
    };

    var list: std.ArrayList(Sub) = .empty;
    const add = struct {
        fn f(l: *std.ArrayList(Sub), al: std.mem.Allocator, key: []const u8, val: []const u8) !void {
            try l.append(al, .{ .key = key, .val = val });
        }
    }.f;

    try add(&list, a, "@@ZIG@@", pinned);
    try add(&list, a, "@@TARGET@@", pinned_target);
    try add(&list, a, "@@N_NODES@@", try commafy(a, n));
    try add(&list, a, "@@N_PUB@@", try commafy(a, n - priv));
    try add(&list, a, "@@N_PRIV@@", try commafy(a, priv));
    try add(&list, a, "@@N_FILES@@", try commafy(a, files));
    try add(&list, a, "@@MAXDEPTH@@", try intStr(a, maxdepth));
    try add(&list, a, "@@N_RESOLVED@@", try commafy(a, resolved.rows.len));
    try add(&list, a, "@@N_RES_CONT@@", try commafy(a, eqCount(status, "status", "resolved")));
    try add(&list, a, "@@N_POISON@@", try commafy(a, poison.rows.len));
    try add(&list, a, "@@N_SKIPPED@@", try commafy(a, eqCount(status, "status", "skipped")));
    try add(&list, a, "@@N_INDEX@@", try commafy(a, index.rows.len));
    try add(&list, a, "@@N_ATTRS@@", try commafy(a, attrs.rows.len));
    try add(&list, a, "@@N_SIGS@@", try commafy(a, a_sig));
    try add(&list, a, "@@N_DOCS@@", try commafy(a, a_doc));
    try add(&list, a, "@@N_VALUES@@", try commafy(a, a_val));
    try add(&list, a, "@@N_LOC@@", try commafy(a, a_loc));
    try add(&list, a, "@@N_EXAMPLES@@", try commafy(a, a_ex));
    try add(&list, a, "@@N_MOD@@", try commafy(a, eqCount(attrs, "attr", "mod")));
    try add(&list, a, "@@N_ERRMEMBER@@", try commafy(a, eqCount(attrs, "attr", "errmember")));
    try add(&list, a, "@@N_FIELDS@@", try commafy(a, fields));
    try add(&list, a, "@@N_EDGES@@", try commafy(a, edges.rows.len));
    try add(&list, a, "@@N_HASTYPE@@", try commafy(a, eqCount(edges, "type", "has_type")));
    try add(&list, a, "@@N_ALIASEDGE@@", try commafy(a, eqCount(edges, "type", "alias")));
    try add(&list, a, "@@N_ERRSET@@", try commafy(a, eqCount(edges, "type", "error_set")));
    try add(&list, a, "@@N_IMPORTS@@", try commafy(a, eqCount(edges, "type", "imports")));
    try add(&list, a, "@@N_DELEGATES@@", try commafy(a, eqCount(edges, "type", "delegates")));
    try add(&list, a, "@@E_LOCAL@@", try commafy(a, e_local));
    try add(&list, a, "@@E_CROSS@@", try commafy(a, e_cross));
    try add(&list, a, "@@E_PRIM@@", try commafy(a, e_prim));
    try add(&list, a, "@@E_MODULE@@", try commafy(a, e_mod));
    try add(&list, a, "@@E_GENERIC@@", try commafy(a, e_gen));
    try add(&list, a, "@@E_INLINE@@", try commafy(a, e_inl));
    try add(&list, a, "@@E_UNRES@@", try commafy(a, e_unres));
    try add(&list, a, "@@E_RESOLVED@@", try commafy(a, e_res));
    try add(&list, a, "@@E_RESOLVED_PCT@@", try intStr(a, pct(e_res, e_res + e_unres)));
    try add(&list, a, "@@N_FN@@", try commafy(a, eqCount(nodes, "kind", "fn")));
    try add(&list, a, "@@N_NSREF@@", try commafy(a, eqCount(nodes, "kind", "nsref")));
    try add(&list, a, "@@N_NODES_RAW@@", try intStr(a, n));
    try add(&list, a, "@@N_PRIV_RAW@@", try intStr(a, priv));
    try add(&list, a, "@@N_INDEX_RAW@@", try intStr(a, index.rows.len));
    try add(&list, a, "@@N_ATTRS_RAW@@", try intStr(a, attrs.rows.len));
    try add(&list, a, "@@N_EDGES_RAW@@", try intStr(a, edges.rows.len));
    try add(&list, a, "@@E_RESOLVED_RAW@@", try intStr(a, e_res));
    try add(&list, a, "@@E_UNRES_RAW@@", try intStr(a, e_unres));
    try add(&list, a, "@@A_DOC_RAW@@", try intStr(a, a_doc));
    try add(&list, a, "@@A_SIG_RAW@@", try intStr(a, a_sig));
    try add(&list, a, "@@A_VAL_RAW@@", try intStr(a, a_val));
    try add(&list, a, "@@A_EX_RAW@@", try intStr(a, a_ex));
    try add(&list, a, "@@CRYPTO_LINE@@", try lookupCell(a, index, "path", "std.crypto", "line"));
    try add(&list, a, "@@CRYPTO_SPAN@@", try lookupCell(a, index, "path", "std.crypto", "span"));
    try add(&list, a, "@@N_CANON@@", try commafy(a, canon.rows.len));
    try add(&list, a, "@@CANON_FAMILIES@@", try commafy(a, canon_families));
    try add(&list, a, "@@N_CONSENSUS@@", try commafy(a, consensus.rows.len));
    try add(&list, a, "@@CON_RR@@", try commafy(a, con_rr));
    try add(&list, a, "@@CON_RUNONLY@@", try commafy(a, con_run));
    try add(&list, a, "@@CON_READONLY@@", try commafy(a, con_ro));
    try add(&list, a, "@@DOC_DOCUMENTED@@", try commafy(a, dc_doc));
    try add(&list, a, "@@DOC_UNDOC@@", try commafy(a, dc_total - dc_doc));
    try add(&list, a, "@@DOC_PCT@@", try intStr(a, dc_pct));
    try add(&list, a, "@@DOC_UNDOC_PCT@@", try intStr(a, 100 - dc_pct));
    try add(&list, a, "@@N_SIGSHAPE@@", try commafy(a, sigshape.rows.len));
    try add(&list, a, "@@SIG_METHODS@@", try commafy(a, eqCount(sigshape, "first_param", "self")));
    try add(&list, a, "@@SIG_IO@@", try commafy(a, eqCount(sigshape, "io", "yes")));
    try add(&list, a, "@@SIG_GENERIC@@", try commafy(a, eqCount(sigshape, "generic", "yes")));
    try add(&list, a, "@@N_CALLCARD@@", try commafy(a, callcard.rows.len));
    try add(&list, a, "@@CC_BOTH@@", try commafy(a, cc_both));
    try add(&list, a, "@@CC_PARSER@@", try commafy(a, cc_parser));
    try add(&list, a, "@@CC_REFLECT@@", try commafy(a, cc_reflect));
    return list.toOwnedSlice(a);
}

// ── stat helpers ─────────────────────────────────────────────────────────────

fn eqCount(t: rel.Table, col: []const u8, val: []const u8) usize {
    const ci = t.col(col);
    var n: usize = 0;
    for (t.rows) |r| {
        if (std.mem.eql(u8, r[ci], val)) n += 1;
    }
    return n;
}

fn maxInt(t: rel.Table, col: []const u8) usize {
    const ci = t.col(col);
    var m: usize = 0;
    for (t.rows) |r| {
        const v = std.fmt.parseInt(usize, r[ci], 10) catch 0;
        if (v > m) m = v;
    }
    return m;
}

fn distinctCount(a: std.mem.Allocator, t: rel.Table, col: []const u8) !usize {
    const ci = t.col(col);
    var set = std.StringHashMap(void).init(a);
    defer set.deinit();
    for (t.rows) |r| try set.put(r[ci], {});
    return set.count();
}

fn lookupCell(a: std.mem.Allocator, t: rel.Table, key_col: []const u8, key: []const u8, want_col: []const u8) ![]const u8 {
    const ki = t.col(key_col);
    const wi = t.col(want_col);
    for (t.rows) |r| {
        if (std.mem.eql(u8, r[ki], key)) return try a.dupe(u8, r[wi]);
    }
    return "";
}

/// round(num*100/den) as an integer percentage (half away from zero, matching Nushell math round).
fn pct(num: usize, den: usize) usize {
    if (den == 0) return 0;
    const v = @as(f64, @floatFromInt(num)) * 100.0 / @as(f64, @floatFromInt(den));
    return @intFromFloat(std.math.round(v));
}

/// 12345 → "12,345".
fn commafy(a: std.mem.Allocator, n: usize) ![]const u8 {
    var tmp: [32]u8 = undefined;
    const digits = try std.fmt.bufPrint(&tmp, "{d}", .{n});
    const ncommas = (digits.len - 1) / 3;
    const out = try a.alloc(u8, digits.len + ncommas);
    var oi: usize = 0;
    for (digits, 0..) |d, i| {
        const rem = digits.len - i; // digits remaining including this one
        out[oi] = d;
        oi += 1;
        if (rem > 1 and rem % 3 == 1) {
            out[oi] = ',';
            oi += 1;
        }
    }
    return out[0..oi];
}

fn intStr(a: std.mem.Allocator, n: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{n});
}

const replaceAll = util.replaceAll;

fn load(c: Ctx, dir: []const u8, rel_path: []const u8) !rel.Table {
    return rel.load(c.a, c.io, try std.fs.path.join(c.a, &.{ dir, rel_path }));
}
fn load_raw(c: Ctx, dir: []const u8, rel_path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(c.io, try std.fs.path.join(c.a, &.{ dir, rel_path }), c.a, .unlimited);
}
fn writeBytes(c: Ctx, path: []const u8, bytes: []const u8) !void {
    return util.writeFile(c.io, path, bytes);
}
