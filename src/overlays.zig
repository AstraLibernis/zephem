// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! overlays.zig — the derived overlays (ports of `scripts/build_{canon,consensus,callcard,doccov,
//! sigshape}.nu`). Each is a pure relational transform over the committed extracted streams,
//! producing one derived table. No Zig is read here — only the datasets.
const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const rel = @import("relation.zig");
const util = @import("util.zig");

// ── shared helpers ───────────────────────────────────────────────────────────

/// Strip Zig keyword-quoting: `@"type"` → `type` (so the parser's quoted path and the compiler's
/// bare name compare equal). Fast path: only rewrite when a `@"` actually appears.
pub fn normPath(a: std.mem.Allocator, p: []const u8) []const u8 {
    if (std.mem.indexOf(u8, p, "@\"") == null) return p;
    var out = a.alloc(u8, p.len) catch return p;
    var n: usize = 0;
    var i: usize = 0;
    while (i < p.len) {
        if (i + 1 < p.len and p[i] == '@' and p[i + 1] == '"') {
            i += 2;
            while (i < p.len and p[i] != '"') : (i += 1) {
                out[n] = p[i];
                n += 1;
            }
            if (i < p.len) i += 1; // skip closing quote
        } else {
            out[n] = p[i];
            n += 1;
            i += 1;
        }
    }
    return out[0..n];
}

// ── canon: dedup/dealias families ────────────────────────────────────────────

/// A nominal/relocatable identity worth deduping — excludes bare primitives, error sets, anon markers.
fn nominal(id: []const u8) bool {
    if (std.mem.startsWith(u8, id, "error{")) return false;
    inline for (.{ "__struct", "__enum", "__union", "__opaque" }) |m| {
        if (std.mem.indexOf(u8, id, m) != null) return false;
    }
    return !isPrimitiveId(id);
}

fn isPrimitiveId(id: []const u8) bool {
    const fixed = [_][]const u8{ "void", "anyopaque", "anyerror", "anyframe", "bool", "type", "noreturn", "comptime_int", "comptime_float", "isize", "usize" };
    for (fixed) |k| if (std.mem.eql(u8, k, id)) return true;
    // [uif][0-9]+  (i32, u8, f64 …)
    if (id.len >= 2 and (id[0] == 'u' or id[0] == 'i' or id[0] == 'f')) {
        var all_digits = true;
        for (id[1..]) |ch| if (ch < '0' or ch > '9') {
            all_digits = false;
            break;
        };
        if (all_digits) return true;
    }
    // c_[a-z]+  (c_int, c_uint …)
    if (std.mem.startsWith(u8, id, "c_") and id.len > 2) {
        var all_lower = true;
        for (id[2..]) |ch| if (ch < 'a' or ch > 'z') {
            all_lower = false;
            break;
        };
        if (all_lower) return true;
    }
    return false;
}

pub fn canon(c: Ctx, dir: []const u8) !rel.Table {
    const a = c.a;
    const resolved = try rel.load(a, c.io, try join(a, dir, "extracted/resolved.tsv"));
    const kp = resolved.col("kind");
    const dp = resolved.col("detail");
    const pp = resolved.col("path");

    // types with a nominal identity, and how many paths share each identity
    var counts = std.StringHashMap(usize).init(a);
    var types: std.ArrayList(rel.Row) = .empty;
    for (resolved.rows) |r| {
        if (!std.mem.eql(u8, r[kp], "type")) continue;
        if (!nominal(r[dp])) continue;
        try types.append(a, r);
        const gop = try counts.getOrPut(r[dp]);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    var rows: std.ArrayList(rel.Row) = .empty;
    for (types.items) |r| {
        if ((counts.get(r[dp]) orelse 0) > 1) {
            const nr = try a.alloc([]const u8, 2);
            nr[0] = r[pp];
            nr[1] = r[dp];
            try rows.append(a, nr);
        }
    }
    const t = rel.Table{ .columns = &.{ "path", "canon" }, .rows = try rows.toOwnedSlice(a), .a = a };
    return rel.sortBy(a, t, &.{ "canon", "path" });
}

// ── consensus: parse-vs-reflect census ───────────────────────────────────────

pub fn consensus(c: Ctx, dir: []const u8) !rel.Table {
    const a = c.a;
    const nodes_raw = try rel.load(a, c.io, try join(a, dir, "extracted/nodes.tsv"));
    const resolved_raw = try rel.load(a, c.io, try join(a, dir, "extracted/resolved.tsv"));

    // nodes: decls/containers only (drop field/tag and `()` factory members), keyed by norm-path.
    const nk = nodes_raw.col("kind");
    const np_ = nodes_raw.col("path");
    var left: std.ArrayList(rel.Row) = .empty;
    for (nodes_raw.rows) |r| {
        if (std.mem.eql(u8, r[nk], "field") or std.mem.eql(u8, r[nk], "tag")) continue;
        if (std.mem.indexOfScalar(u8, r[np_], '(') != null) continue;
        const row = try a.alloc([]const u8, 2);
        row[0] = r[np_]; // ppath
        row[1] = normPath(a, r[np_]); // np
        try left.append(a, row);
    }
    const nodes = rel.Table{ .columns = &.{ "ppath", "np" }, .rows = try left.toOwnedSlice(a), .a = a };

    const res_uniq = try rel.uniqBy(a, resolved_raw, "path");
    const rp = res_uniq.col("path");
    var right: std.ArrayList(rel.Row) = .empty;
    for (res_uniq.rows) |r| {
        const row = try a.alloc([]const u8, 2);
        row[0] = r[rp]; // cpath
        row[1] = normPath(a, r[rp]); // np
        try right.append(a, row);
    }
    const res = rel.Table{ .columns = &.{ "cpath", "np" }, .rows = try right.toOwnedSlice(a), .a = a };

    const joined = try rel.joinOuter(a, nodes, res, "np");
    const jpp = joined.col("ppath");
    const jcp = joined.col("cpath");
    var rows: std.ArrayList(rel.Row) = .empty;
    for (joined.rows) |r| {
        const has_p = r[jpp].len != 0;
        const has_c = r[jcp].len != 0;
        const path = if (has_p) r[jpp] else r[jcp];
        const origin = if (has_p and has_c) "read+run" else if (has_c) "run-only" else "read-only";
        const row = try a.alloc([]const u8, 3);
        row[0] = path;
        row[1] = origin;
        row[2] = util.dottedParent(path);
        try rows.append(a, row);
    }
    const t = rel.Table{ .columns = &.{ "path", "origin", "owner" }, .rows = try rows.toOwnedSlice(a), .a = a };
    return rel.sortBy(a, t, &.{"path"});
}

// ── callcard: sigs ⋈ resolved ────────────────────────────────────────────────

pub fn callcard(c: Ctx, dir: []const u8) !rel.Table {
    const a = c.a;
    const attrs = try rel.load(a, c.io, try join(a, dir, "extracted/attrs.tsv"));
    const resolved = try rel.load(a, c.io, try join(a, dir, "extracted/resolved.tsv"));

    // sigs: {spath, sig, np}
    const aa = attrs.col("attr");
    const ap = attrs.col("path");
    const av = attrs.col("value");
    var sigs_rows: std.ArrayList(rel.Row) = .empty;
    for (attrs.rows) |r| {
        if (!std.mem.eql(u8, r[aa], "sig")) continue;
        const row = try a.alloc([]const u8, 3);
        row[0] = r[ap]; // spath
        row[1] = r[av]; // sig
        row[2] = normPath(a, r[ap]); // np
        try sigs_rows.append(a, row);
    }
    const sigs = rel.Table{ .columns = &.{ "spath", "sig", "np" }, .rows = try sigs_rows.toOwnedSlice(a), .a = a };

    // res: fn rows, uniq by path → {rpath, resolved, np}
    const rk = resolved.col("kind");
    var fn_rows: std.ArrayList(rel.Row) = .empty;
    for (resolved.rows) |r| {
        if (std.mem.eql(u8, r[rk], "fn")) try fn_rows.append(a, r);
    }
    const res_fn = try rel.uniqBy(a, rel.Table{ .columns = resolved.columns, .rows = try fn_rows.toOwnedSlice(a), .a = a }, "path");
    const rp = res_fn.col("path");
    const rd = res_fn.col("detail");
    var res_rows: std.ArrayList(rel.Row) = .empty;
    for (res_fn.rows) |r| {
        const row = try a.alloc([]const u8, 3);
        row[0] = r[rp]; // rpath
        row[1] = r[rd]; // resolved
        row[2] = normPath(a, r[rp]); // np
        try res_rows.append(a, row);
    }
    const res = rel.Table{ .columns = &.{ "rpath", "resolved", "np" }, .rows = try res_rows.toOwnedSlice(a), .a = a };

    const joined = try rel.joinOuter(a, sigs, res, "np");
    const jsp = joined.col("spath");
    const jsig = joined.col("sig");
    const jrp = joined.col("rpath");
    const jres = joined.col("resolved");
    var rows: std.ArrayList(rel.Row) = .empty;
    for (joined.rows) |r| {
        const has_s = r[jsp].len != 0;
        const has_r = r[jrp].len != 0;
        const path = if (has_s) r[jsp] else r[jrp];
        const witness = if (has_s and has_r) "both" else if (has_s) "parser-only" else "reflect-only";
        const row = try a.alloc([]const u8, 4);
        row[0] = path;
        row[1] = witness;
        row[2] = r[jsig];
        row[3] = r[jres];
        try rows.append(a, row);
    }
    const t = rel.Table{ .columns = &.{ "path", "witness", "sig", "resolved" }, .rows = try rows.toOwnedSlice(a), .a = a };
    return rel.sortBy(a, t, &.{"path"});
}

// ── doccov: doc-coverage census ──────────────────────────────────────────────

pub fn doccov(c: Ctx, dir: []const u8) !rel.Table {
    const a = c.a;
    const nodes = try rel.load(a, c.io, try join(a, dir, "extracted/nodes.tsv"));
    const attrs = try rel.load(a, c.io, try join(a, dir, "extracted/attrs.tsv"));

    var documented = std.StringHashMap(void).init(a);
    const aa = attrs.col("attr");
    const ap = attrs.col("path");
    for (attrs.rows) |r| {
        if (std.mem.eql(u8, r[aa], "doc")) try documented.put(r[ap], {});
    }
    const np_ = nodes.col("path");
    const nk = nodes.col("kind");
    var rows: std.ArrayList(rel.Row) = .empty;
    for (nodes.rows) |r| {
        const row = try a.alloc([]const u8, 3);
        row[0] = r[np_];
        row[1] = r[nk];
        row[2] = if (documented.contains(r[np_])) "yes" else "no";
        try rows.append(a, row);
    }
    const t = rel.Table{ .columns = &.{ "path", "kind", "documented" }, .rows = try rows.toOwnedSlice(a), .a = a };
    return rel.sortBy(a, t, &.{"path"});
}

// ── sigshape: signature-shape classification ─────────────────────────────────

/// The substring inside the FIRST balanced `(...)` group — the parameter list.
fn paramList(sig: []const u8) []const u8 {
    var depth: i32 = 0;
    var started = false;
    var start: usize = 0;
    for (sig, 0..) |ch, i| {
        if (ch == '(') {
            if (!started) {
                started = true;
                depth = 1;
                start = i + 1;
                continue;
            }
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return sig[start..i];
        }
    }
    return if (started) sig[start..] else "";
}

/// The first top-level parameter (split the list on depth-0 commas, keep the first), trimmed.
fn firstOf(plist: []const u8) []const u8 {
    var depth: i32 = 0;
    for (plist, 0..) |ch, i| {
        switch (ch) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            ',' => if (depth == 0) return std.mem.trim(u8, plist[0..i], " \t"),
            else => {},
        }
    }
    return std.mem.trim(u8, plist, " \t");
}

pub fn sigshape(c: Ctx, dir: []const u8) !rel.Table {
    const a = c.a;
    const attrs = try rel.load(a, c.io, try join(a, dir, "extracted/attrs.tsv"));
    const aa = attrs.col("attr");
    const ap = attrs.col("path");
    const av = attrs.col("value");
    var rows: std.ArrayList(rel.Row) = .empty;
    for (attrs.rows) |r| {
        if (!std.mem.eql(u8, r[aa], "sig")) continue;
        const sig = r[av];
        const plist = paramList(sig);
        const plist_trim = std.mem.trim(u8, plist, " \t");
        const first_param = if (plist_trim.len == 0) "none" else blk: {
            const fp = firstOf(plist);
            const name = std.mem.trim(u8, sliceUntil(fp, ':'), " \t");
            if (std.mem.eql(u8, name, "self") or std.mem.eql(u8, name, "this")) break :blk "self";
            if (std.mem.indexOf(u8, fp, "Allocator") != null) break :blk "allocator";
            break :blk "other";
        };
        const io = if (std.mem.indexOf(u8, sig, "Io") != null) "yes" else "no";
        const generic = if (std.mem.indexOf(u8, plist, "comptime ") != null or std.mem.indexOf(u8, plist, "anytype") != null) "yes" else "no";
        const row = try a.alloc([]const u8, 4);
        row[0] = r[ap];
        row[1] = first_param;
        row[2] = io;
        row[3] = generic;
        try rows.append(a, row);
    }
    const t = rel.Table{ .columns = &.{ "path", "first_param", "io", "generic" }, .rows = try rows.toOwnedSlice(a), .a = a };
    return rel.sortBy(a, t, &.{"path"});
}

fn sliceUntil(s: []const u8, ch: u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, ch)) |k| s[0..k] else s;
}

const join = util.join;
