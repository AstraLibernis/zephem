// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! diff.zig — `zephem diff <old> <new>`: what changed in std between two frozen maps
//! (`data/versions/<zig-version>/`, see snapshot.zig; `live` names `data/std/`).
//!
//! The comparison is over the parser's shape model, so it needs no compiler and no oracle:
//! `extracted/nodes.tsv` gives every declaration's path, kind and visibility, and the `sig`
//! rows of `extracted/attrs.tsv` give the signature as written. A declaration is **added**
//! when its path exists only in the new map, **removed** when only in the old, **changed** when
//! it exists in both with a different kind, visibility or signature. Public declarations only
//! by default: a private rename is nobody's break.
//!
//! The report is for a reader porting code: removed paths first (those break builds), then
//! signature changes (old → new), then what arrived, each grouped under its module
//! (`std.mem`, `std.Io.Dir`, …). `--tsv` emits one row per change for tools.
const std = @import("std");
const argv = @import("args.zig");
const Ctx = @import("ctx.zig").Ctx;
const rel = @import("relation.zig");
const snapshot = @import("snapshot.zig");
const util = @import("util.zig");

pub const Decl = struct {
    kind: []const u8,
    vis: []const u8,
    sig: ?[]const u8 = null,
};

/// One side of the comparison: every declaration by path, plus the paths in sorted order so
/// the output never depends on hash order.
pub const Side = struct {
    decls: std.StringHashMapUnmanaged(Decl) = .empty,
    paths: []const []const u8 = &.{},
};

pub const What = enum { added, removed, changed };

pub const Change = struct {
    what: What,
    path: []const u8,
    old: ?Decl,
    new: ?Decl,
};

/// Build a side from the two TSV texts (the shape used by the tests).
pub fn loadSideBytes(a: std.mem.Allocator, nodes_tsv: []const u8, attrs_tsv: []const u8) !Side {
    const nodes = try rel.loadBytes(a, nodes_tsv);
    const attrs = try rel.loadBytes(a, attrs_tsv);
    var side: Side = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    for (nodes.rows) |row| {
        const path = nodes.cell(row, "path");
        try side.decls.put(a, path, .{ .kind = nodes.cell(row, "kind"), .vis = nodes.cell(row, "vis") });
        try paths.append(a, path);
    }
    for (attrs.rows) |row| {
        if (!std.mem.eql(u8, attrs.cell(row, "attr"), "sig")) continue;
        if (side.decls.getPtr(attrs.cell(row, "path"))) |d| d.sig = attrs.cell(row, "value");
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    side.paths = paths.items;
    return side;
}

/// Build a side from a map folder (`extracted/nodes.tsv` + `extracted/attrs.tsv`).
pub fn loadSide(c: Ctx, dir: []const u8) !Side {
    const nodes = try std.Io.Dir.cwd().readFileAlloc(c.io, try util.join(c.a, dir, "extracted/nodes.tsv"), c.a, .unlimited);
    const attrs = try std.Io.Dir.cwd().readFileAlloc(c.io, try util.join(c.a, dir, "extracted/attrs.tsv"), c.a, .unlimited);
    return loadSideBytes(c.a, nodes, attrs);
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn optEql(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null and y == null) return true;
    if (x == null or y == null) return false;
    return std.mem.eql(u8, x.?, y.?);
}

fn isPub(d: Decl) bool {
    return std.mem.eql(u8, d.vis, "pub");
}

/// Every difference between the two sides, sorted by path. With `include_private` false a
/// declaration counts only while it is public on the side(s) it exists on.
pub fn compute(a: std.mem.Allocator, old: Side, new: Side, include_private: bool) ![]const Change {
    var out: std.ArrayList(Change) = .empty;
    for (old.paths) |p| {
        const o = old.decls.get(p).?;
        if (new.decls.get(p)) |n| {
            if (!include_private and !isPub(o) and !isPub(n)) continue;
            const same = std.mem.eql(u8, o.kind, n.kind) and std.mem.eql(u8, o.vis, n.vis) and optEql(o.sig, n.sig);
            if (!same) try out.append(a, .{ .what = .changed, .path = p, .old = o, .new = n });
        } else {
            if (!include_private and !isPub(o)) continue;
            try out.append(a, .{ .what = .removed, .path = p, .old = o, .new = null });
        }
    }
    for (new.paths) |p| {
        if (old.decls.contains(p)) continue;
        const n = new.decls.get(p).?;
        if (!include_private and !isPub(n)) continue;
        try out.append(a, .{ .what = .added, .path = p, .old = null, .new = n });
    }
    std.mem.sort(Change, out.items, {}, struct {
        fn lt(_: void, x: Change, y: Change) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.lt);
    return out.items;
}

/// The module a path belongs to for grouping: its first two segments (`std.mem.eql` →
/// `std.mem`), or the path itself when it has fewer.
pub fn module(path: []const u8) []const u8 {
    var dots: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '.') {
            dots += 1;
            if (dots == 2) return path[0..i];
        }
    }
    return path;
}

/// Is `path` under `prefix` (equal, or a dotted child of it)?
pub fn under(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '.';
}

pub const Tally = struct { module: []const u8, added: usize = 0, removed: usize = 0, changed: usize = 0 };

/// Per-module counts, largest total first (ties by name) — the table that says where a Zig
/// release moved.
pub fn tallies(a: std.mem.Allocator, changes: []const Change) ![]const Tally {
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    var list: std.ArrayList(Tally) = .empty;
    for (changes) |ch| {
        const m = module(ch.path);
        const gop = try index.getOrPut(a, m);
        if (!gop.found_existing) {
            gop.value_ptr.* = list.items.len;
            try list.append(a, .{ .module = m });
        }
        const t = &list.items[gop.value_ptr.*];
        switch (ch.what) {
            .added => t.added += 1,
            .removed => t.removed += 1,
            .changed => t.changed += 1,
        }
    }
    std.mem.sort(Tally, list.items, {}, struct {
        fn lt(_: void, x: Tally, y: Tally) bool {
            const tx = x.added + x.removed + x.changed;
            const ty = y.added + y.removed + y.changed;
            if (tx != ty) return tx > ty;
            return std.mem.order(u8, x.module, y.module) == .lt;
        }
    }.lt);
    return list.items;
}

pub const Options = struct {
    /// Restrict to paths under this prefix (`std.mem`).
    prefix: ?[]const u8 = null,
    /// Show only this kind of change.
    only: ?What = null,
    /// Rows per section before the list is cut with a "… N more" line (0 = no cut).
    limit: usize = 40,
    /// One TSV row per change instead of the report.
    tsv: bool = false,
};

fn keep(ch: Change, o: Options) bool {
    if (o.only) |w| if (ch.what != w) return false;
    if (o.prefix) |p| if (!under(ch.path, p)) return false;
    return true;
}

fn sigOr(d: ?Decl) []const u8 {
    if (d) |x| return x.sig orelse "";
    return "";
}

fn kindOr(d: ?Decl) []const u8 {
    return if (d) |x| x.kind else "";
}

/// Write the report (or the TSV) for `changes` filtered by `o`.
pub fn report(a: std.mem.Allocator, w: *std.Io.Writer, old_name: []const u8, new_name: []const u8, changes: []const Change, o: Options) !void {
    var kept: std.ArrayList(Change) = .empty;
    for (changes) |ch| if (keep(ch, o)) try kept.append(a, ch);

    if (o.tsv) {
        try w.writeAll("change\tpath\tkind_old\tkind_new\tsig_old\tsig_new\n");
        for (kept.items) |ch| {
            try w.print("{t}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{ ch.what, ch.path, kindOr(ch.old), kindOr(ch.new), sigOr(ch.old), sigOr(ch.new) });
        }
        return;
    }

    var n_added: usize = 0;
    var n_removed: usize = 0;
    var n_changed: usize = 0;
    for (kept.items) |ch| switch (ch.what) {
        .added => n_added += 1,
        .removed => n_removed += 1,
        .changed => n_changed += 1,
    };
    try w.print("# zephem diff {s} → {s}", .{ old_name, new_name });
    if (o.prefix) |p| try w.print("  (under {s})", .{p});
    try w.print("\n\n{d} removed · {d} changed · {d} added  (public declarations)\n", .{ n_removed, n_changed, n_added });
    if (kept.items.len == 0) return;

    // Where it moved.
    const ts = try tallies(a, kept.items);
    try w.writeAll("\n## by module\n\n| module | removed | changed | added |\n|---|---:|---:|---:|\n");
    var shown: usize = 0;
    for (ts) |t| {
        if (o.limit != 0 and shown == o.limit) {
            try w.print("| … {d} more modules | | | |\n", .{ts.len - shown});
            break;
        }
        try w.print("| {s} | {d} | {d} | {d} |\n", .{ t.module, t.removed, t.changed, t.added });
        shown += 1;
    }

    try section(w, kept.items, .removed, "removed — these break code that used them", o.limit);
    try section(w, kept.items, .changed, "changed — kind, visibility or signature", o.limit);
    try section(w, kept.items, .added, "added", o.limit);
}

fn section(w: *std.Io.Writer, changes: []const Change, what: What, title: []const u8, limit: usize) !void {
    var total: usize = 0;
    for (changes) |ch| if (ch.what == what) {
        total += 1;
    };
    if (total == 0) return;
    try w.print("\n## {s} ({d})\n\n", .{ title, total });
    var shown: usize = 0;
    for (changes) |ch| {
        if (ch.what != what) continue;
        if (limit != 0 and shown == limit) {
            try w.print("… {d} more (raise --limit, narrow with --module, or use --tsv)\n", .{total - shown});
            return;
        }
        shown += 1;
        switch (what) {
            .removed => try w.print("- `{s}`  ({s}){s}{s}\n", .{ ch.path, ch.old.?.kind, if (ch.old.?.sig != null) "  " else "", sigOr(ch.old) }),
            .added => try w.print("- `{s}`  ({s}){s}{s}\n", .{ ch.path, ch.new.?.kind, if (ch.new.?.sig != null) "  " else "", sigOr(ch.new) }),
            .changed => {
                const o = ch.old.?;
                const n = ch.new.?;
                try w.print("- `{s}`", .{ch.path});
                if (!std.mem.eql(u8, o.kind, n.kind)) try w.print("  kind {s} → {s}", .{ o.kind, n.kind });
                if (!std.mem.eql(u8, o.vis, n.vis)) try w.print("  {s} → {s}", .{ o.vis, n.vis });
                try w.writeAll("\n");
                if (!optEql(o.sig, n.sig)) {
                    try w.print("    - was: {s}\n    - now: {s}\n", .{ sigOr(ch.old), sigOr(ch.new) });
                }
            },
        }
    }
}

pub fn run(c: Ctx, args: []const []const u8) !void {
    const usage =
        \\usage: zephem diff <old> <new> [--module <prefix>] [--only added|removed|changed]
        \\                   [--private] [--limit N] [--tsv]
        \\
        \\  compare two frozen maps: a Zig version under data/versions/ (0.16.0), or `live`
        \\  for data/std/. Public declarations by default.
        \\  --module P   only paths under P (std.mem, std.Io.Dir, …)
        \\  --only W     one kind of change
        \\  --private    include private declarations
        \\  --limit N    rows per section (default 40; 0 = all)
        \\  --tsv        one row per change: change · path · kind_old · kind_new · sig_old · sig_new
        \\
    ;
    if (try argv.helpRequested(c, args, usage)) return;

    var names: [2]?[]const u8 = .{ null, null };
    var o: Options = .{};
    var include_private = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--module")) {
            o.prefix = argv.value(c, args, &i, "--module", usage);
        } else if (std.mem.eql(u8, arg, "--only")) {
            const v = argv.value(c, args, &i, "--only", usage);
            o.only = std.meta.stringToEnum(What, v) orelse argv.reject(c, v, usage);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            o.limit = argv.intValue(c, usize, args, &i, "--limit", usage);
        } else if (std.mem.eql(u8, arg, "--private")) {
            include_private = true;
        } else if (std.mem.eql(u8, arg, "--tsv")) {
            o.tsv = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            argv.reject(c, arg, usage);
        } else if (names[0] == null) {
            names[0] = arg;
        } else if (names[1] == null) {
            names[1] = arg;
        } else argv.reject(c, arg, usage);
    }
    const old_name = names[0] orelse argv.reject(c, "<old>", usage);
    const new_name = names[1] orelse argv.reject(c, "<new>", usage);

    var ow = std.Io.File.stdout().writerStreaming(c.io, try c.a.alloc(u8, 1 << 16));
    const w = &ow.interface;
    defer w.flush() catch {}; // zsnag:ok — report only; a defer cannot return the error

    const old_dir = try snapshot.versionDir(c, old_name);
    const new_dir = try snapshot.versionDir(c, new_name);
    const old = loadSide(c, old_dir) catch {
        try argv.diag(c, "zephem diff: no map at {s} (versions: data/versions/<zig-version>, or `live`)\n", .{old_dir});
        std.process.exit(3);
    };
    const new = loadSide(c, new_dir) catch {
        try argv.diag(c, "zephem diff: no map at {s} (versions: data/versions/<zig-version>, or `live`)\n", .{new_dir});
        std.process.exit(3);
    };
    const changes = try compute(c.a, old, new, include_private);
    try report(c.a, w, old_name, new_name, changes, o);
}
