// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! diff.zig — `zephem diff <old> <new>`: what changed in std between two frozen maps
//! (`data/versions/<zig-version>/`, see snapshot.zig; `live` names `data/std/`).
//!
//! The comparison is over the datasets alone, so it needs no compiler and no oracle. The
//! items it reports are the rows of docs/release-diff.md:
//!
//! - **extracted** facts: a declaration **added** (path only in the new map), **removed** (only
//!   in the old), **changed** (both, with a different kind, visibility or signature);
//!   **deprecated** states (the doc gains or loses the `Deprecated` marker lookup.zig uses, or a
//!   deprecated declaration is gone); **enum tag sets** summarised per enum instead of as one
//!   removal and one addition per tag; **builtins** added, removed or re-signed
//!   (`builtins.tsv`); **resolved values** that changed (`resolved.tsv`: a const_int or
//!   const_bool with a different value).
//! - one **inferred** item, always labelled: **moved** — a removed and an added declaration
//!   with the same name, kind and signature, when that match is unique on both sides.
//!
//! Public declarations only by default: a private rename is nobody's break. The report is
//! for a reader porting code (removed first, then what moved where); `--tsv` is one row per
//! change with a provenance column, for tools.
const std = @import("std");
const argv = @import("args.zig");
const Ctx = @import("ctx.zig").Ctx;
const rel = @import("relation.zig");
const snapshot = @import("snapshot.zig");
const util = @import("util.zig");

pub const Decl = struct {
    name: []const u8,
    kind: []const u8,
    vis: []const u8,
    sig: ?[]const u8 = null,
    doc: ?[]const u8 = null,

    /// The marker the lookup table uses (lookup.zig): a doc that starts with `Deprecated`.
    pub fn deprecated(d: Decl) bool {
        return if (d.doc) |doc| std.mem.startsWith(u8, doc, "Deprecated") else false;
    }
};

pub const Builtin = struct { sig: []const u8, doc: []const u8 };
pub const Resolved = struct { kind: []const u8, detail: []const u8 };

/// One side of the comparison: every declaration by path, plus the paths in sorted order so
/// the output never depends on hash order. Builtins and resolved values are optional (a map
/// without a depth sweep has no resolved.tsv).
pub const Side = struct {
    decls: std.StringHashMapUnmanaged(Decl) = .empty,
    paths: []const []const u8 = &.{},
    builtins: std.StringHashMapUnmanaged(Builtin) = .empty,
    builtin_names: []const []const u8 = &.{},
    resolved: std.StringHashMapUnmanaged(Resolved) = .empty,
    resolved_paths: []const []const u8 = &.{},
};

pub const What = enum { added, removed, changed };

pub const Change = struct {
    what: What,
    path: []const u8,
    old: ?Decl,
    new: ?Decl,
};

pub const Move = struct { from: []const u8, to: []const u8, decl: Decl };

pub const Deprecation = struct {
    pub const State = enum { newly, lifted, removed };
    path: []const u8,
    state: State,
    /// The doc text in the version that carries the marker (it usually names the replacement).
    doc: []const u8,
};

pub const TagSet = struct {
    @"enum": []const u8,
    removed: []const []const u8,
    added: []const []const u8,
};

pub const BuiltinChange = struct {
    pub const State = enum { added, removed, changed };
    name: []const u8,
    state: State,
    old: ?Builtin,
    new: ?Builtin,
};

pub const ValueChange = struct { path: []const u8, kind: []const u8, old: []const u8, new: []const u8 };

/// Everything the diff found, in one place, so the report and the TSV draw from the same facts.
pub const Result = struct {
    changes: []const Change,
    moves: []const Move,
    deprecations: []const Deprecation,
    tag_sets: []const TagSet,
    builtins: []const BuiltinChange,
    values: []const ValueChange,
    /// Paths that are part of a move (either end), so the lists can skip them.
    moved: std.StringHashMapUnmanaged(void),
};

// ---------------------------------------------------------------- loading ----------

/// Build a side from the two core TSV texts (the shape used by the tests).
pub fn loadSideBytes(a: std.mem.Allocator, nodes_tsv: []const u8, attrs_tsv: []const u8) !Side {
    const nodes = try rel.loadBytes(a, nodes_tsv);
    const attrs = try rel.loadBytes(a, attrs_tsv);
    var side: Side = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    for (nodes.rows) |row| {
        const path = nodes.cell(row, "path");
        try side.decls.put(a, path, .{ .name = nodes.cell(row, "name"), .kind = nodes.cell(row, "kind"), .vis = nodes.cell(row, "vis") });
        try paths.append(a, path);
    }
    for (attrs.rows) |row| {
        const attr = attrs.cell(row, "attr");
        const is_sig = std.mem.eql(u8, attr, "sig");
        const is_doc = std.mem.eql(u8, attr, "doc");
        if (!is_sig and !is_doc) continue;
        if (side.decls.getPtr(attrs.cell(row, "path"))) |d| {
            if (is_sig) d.sig = attrs.cell(row, "value") else d.doc = attrs.cell(row, "value");
        }
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    side.paths = paths.items;
    return side;
}

/// Add the optional datasets to a side (either text may be empty = absent).
pub fn loadExtrasBytes(a: std.mem.Allocator, side: *Side, builtins_tsv: []const u8, resolved_tsv: []const u8) !void {
    if (builtins_tsv.len > 0) {
        const t = try rel.loadBytes(a, builtins_tsv);
        var names: std.ArrayList([]const u8) = .empty;
        for (t.rows) |row| {
            const name = t.cell(row, "name");
            try side.builtins.put(a, name, .{ .sig = t.cell(row, "sig"), .doc = t.cell(row, "doc") });
            try names.append(a, name);
        }
        std.mem.sort([]const u8, names.items, {}, lessThan);
        side.builtin_names = names.items;
    }
    if (resolved_tsv.len > 0) {
        const t = try rel.loadBytes(a, resolved_tsv);
        var paths: std.ArrayList([]const u8) = .empty;
        for (t.rows) |row| {
            const path = t.cell(row, "path");
            try side.resolved.put(a, path, .{ .kind = t.cell(row, "kind"), .detail = t.cell(row, "detail") });
            try paths.append(a, path);
        }
        std.mem.sort([]const u8, paths.items, {}, lessThan);
        side.resolved_paths = paths.items;
    }
}

fn readOptional(c: Ctx, dir: []const u8, rel_path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(c.io, try util.join(c.a, dir, rel_path), c.a, .unlimited) catch |e| switch (e) {
        error.FileNotFound => "",
        else => e,
    };
}

/// Build a side from a map folder.
pub fn loadSide(c: Ctx, dir: []const u8) !Side {
    const nodes = try std.Io.Dir.cwd().readFileAlloc(c.io, try util.join(c.a, dir, "extracted/nodes.tsv"), c.a, .unlimited);
    const attrs = try std.Io.Dir.cwd().readFileAlloc(c.io, try util.join(c.a, dir, "extracted/attrs.tsv"), c.a, .unlimited);
    var side = try loadSideBytes(c.a, nodes, attrs);
    try loadExtrasBytes(c.a, &side, try readOptional(c, dir, "extracted/builtins.tsv"), try readOptional(c, dir, "extracted/resolved.tsv"));
    return side;
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

fn isTag(d: Decl) bool {
    return std.mem.eql(u8, d.kind, "tag");
}

// ---------------------------------------------------------------- analyses ---------

/// Every added / removed / changed declaration, sorted by path. With `include_private` false
/// a declaration counts only while it is public on the side(s) it exists on.
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

/// Moves (INFERRED): a removed and an added declaration with the same name, kind and
/// signature, where that key matches exactly one removed and exactly one added declaration.
/// Enum tags are excluded (they are summarised per enum). A declaration without a signature
/// (a container, a const) pairs on name + kind alone, so for those the uniqueness requirement
/// is what keeps `Options` from being "moved" to a random other `Options`.
pub fn moves(a: std.mem.Allocator, changes: []const Change) ![]const Move {
    const Key = struct {
        fn of(al: std.mem.Allocator, d: Decl) ![]const u8 {
            return al.print("{s}\x00{s}\x00{s}", .{ d.name, d.kind, d.sig orelse "" });
        }
    };
    // key → index of the one change with it, or `ambiguous`.
    const ambiguous = std.math.maxInt(usize);
    var removed: std.StringHashMapUnmanaged(usize) = .empty;
    var added: std.StringHashMapUnmanaged(usize) = .empty;
    for (changes, 0..) |ch, i| {
        const d = (if (ch.what == .removed) ch.old else if (ch.what == .added) ch.new else null) orelse continue;
        if (isTag(d)) continue;
        const map = if (ch.what == .removed) &removed else &added;
        const gop = try map.getOrPut(a, try Key.of(a, d));
        gop.value_ptr.* = if (gop.found_existing) ambiguous else i;
    }
    var out: std.ArrayList(Move) = .empty;
    for (changes) |ch| {
        if (ch.what != .removed) continue;
        const d = ch.old.?;
        if (isTag(d)) continue;
        const key = try Key.of(a, d);
        const ri = removed.get(key).?;
        if (ri == ambiguous) continue;
        const ai = added.get(key) orelse continue;
        if (ai == ambiguous) continue;
        try out.append(a, .{ .from = ch.path, .to = changes[ai].path, .decl = d });
    }
    return out.items;
}

/// Deprecation state changes among the (public-filtered) declarations.
pub fn deprecations(a: std.mem.Allocator, old: Side, new: Side, changes: []const Change) ![]const Deprecation {
    var out: std.ArrayList(Deprecation) = .empty;
    // Both sides: the marker appeared or disappeared (independent of other changes).
    for (old.paths) |p| {
        const o = old.decls.get(p).?;
        const n = new.decls.get(p) orelse continue;
        if (!isPub(o) and !isPub(n)) continue;
        if (!o.deprecated() and n.deprecated()) try out.append(a, .{ .path = p, .state = .newly, .doc = n.doc.? });
        if (o.deprecated() and !n.deprecated()) try out.append(a, .{ .path = p, .state = .lifted, .doc = o.doc.? });
    }
    // Removed while deprecated: the deprecation ran its course.
    for (changes) |ch| {
        if (ch.what != .removed) continue;
        if (ch.old.?.deprecated()) try out.append(a, .{ .path = ch.path, .state = .removed, .doc = ch.old.?.doc.? });
    }
    std.mem.sort(Deprecation, out.items, {}, struct {
        fn lt(_: void, x: Deprecation, y: Deprecation) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.lt);
    return out.items;
}

/// Enum tag sets: removed and added tags grouped under their enum, in path order.
pub fn tagSets(a: std.mem.Allocator, changes: []const Change) ![]const TagSet {
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    var removed_lists: std.ArrayList(std.ArrayList([]const u8)) = .empty;
    var added_lists: std.ArrayList(std.ArrayList([]const u8)) = .empty;
    var enums: std.ArrayList([]const u8) = .empty;
    for (changes) |ch| {
        const d = (if (ch.what == .removed) ch.old else if (ch.what == .added) ch.new else null) orelse continue;
        if (!isTag(d)) continue;
        const parent = util.dottedParent(ch.path);
        const gop = try index.getOrPut(a, parent);
        if (!gop.found_existing) {
            gop.value_ptr.* = enums.items.len;
            try enums.append(a, parent);
            try removed_lists.append(a, .empty);
            try added_lists.append(a, .empty);
        }
        const i = gop.value_ptr.*;
        if (ch.what == .removed) try removed_lists.items[i].append(a, d.name) else try added_lists.items[i].append(a, d.name);
    }
    var out: std.ArrayList(TagSet) = .empty;
    for (enums.items, 0..) |e, i| {
        try out.append(a, .{ .@"enum" = e, .removed = removed_lists.items[i].items, .added = added_lists.items[i].items });
    }
    std.mem.sort(TagSet, out.items, {}, struct {
        fn lt(_: void, x: TagSet, y: TagSet) bool {
            return std.mem.order(u8, x.@"enum", y.@"enum") == .lt;
        }
    }.lt);
    return out.items;
}

/// Builtins added, removed, or with a different signature (a doc-only change is not reported:
/// builtin docs are prose from the langref).
pub fn builtinChanges(a: std.mem.Allocator, old: Side, new: Side) ![]const BuiltinChange {
    var out: std.ArrayList(BuiltinChange) = .empty;
    for (old.builtin_names) |n| {
        const o = old.builtins.get(n).?;
        if (new.builtins.get(n)) |nw| {
            if (!std.mem.eql(u8, o.sig, nw.sig)) try out.append(a, .{ .name = n, .state = .changed, .old = o, .new = nw });
        } else try out.append(a, .{ .name = n, .state = .removed, .old = o, .new = null });
    }
    for (new.builtin_names) |n| {
        if (old.builtins.contains(n)) continue;
        try out.append(a, .{ .name = n, .state = .added, .old = null, .new = new.builtins.get(n).? });
    }
    std.mem.sort(BuiltinChange, out.items, {}, struct {
        fn lt(_: void, x: BuiltinChange, y: BuiltinChange) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.lt);
    return out.items;
}

/// Resolved constants (const_int / const_bool) present in both sweeps with a different value.
pub fn valueChanges(a: std.mem.Allocator, old: Side, new: Side, include_private: bool) ![]const ValueChange {
    var out: std.ArrayList(ValueChange) = .empty;
    for (old.resolved_paths) |p| {
        const o = old.resolved.get(p).?;
        if (!std.mem.eql(u8, o.kind, "const_int") and !std.mem.eql(u8, o.kind, "const_bool")) continue;
        const n = new.resolved.get(p) orelse continue;
        if (!std.mem.eql(u8, o.kind, n.kind)) continue;
        if (std.mem.eql(u8, o.detail, n.detail)) continue;
        if (!include_private) {
            if (new.decls.get(p)) |d| if (!isPub(d)) continue;
        }
        try out.append(a, .{ .path = p, .kind = o.kind, .old = o.detail, .new = n.detail });
    }
    return out.items;
}

/// Run every analysis.
pub fn analyze(a: std.mem.Allocator, old: Side, new: Side, include_private: bool) !Result {
    const changes = try compute(a, old, new, include_private);
    const mv = try moves(a, changes);
    var moved: std.StringHashMapUnmanaged(void) = .empty;
    for (mv) |m| {
        try moved.put(a, m.from, {});
        try moved.put(a, m.to, {});
    }
    return .{
        .changes = changes,
        .moves = mv,
        .deprecations = try deprecations(a, old, new, changes),
        .tag_sets = try tagSets(a, changes),
        .builtins = try builtinChanges(a, old, new),
        .values = try valueChanges(a, old, new, include_private),
        .moved = moved,
    };
}

// ---------------------------------------------------------------- grouping ---------

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

// ---------------------------------------------------------------- reporting --------

pub const Options = struct {
    /// Restrict to paths under this prefix (`std.mem`).
    prefix: ?[]const u8 = null,
    /// Show only this kind of declaration change (the other sections are still printed).
    only: ?What = null,
    /// Rows per section before the list is cut with a "… N more" line (0 = no cut).
    limit: usize = 40,
    /// One TSV row per change instead of the report.
    tsv: bool = false,
};

fn inScope(path: []const u8, o: Options) bool {
    if (o.prefix) |p| return under(path, p);
    return true;
}

fn keep(ch: Change, o: Options) bool {
    if (o.only) |w| if (ch.what != w) return false;
    return inScope(ch.path, o);
}

fn sigOr(d: ?Decl) []const u8 {
    if (d) |x| return x.sig orelse "";
    return "";
}

fn kindOr(d: ?Decl) []const u8 {
    return if (d) |x| x.kind else "";
}

/// Write the report (or the TSV) for `r` filtered by `o`.
pub fn report(a: std.mem.Allocator, w: *std.Io.Writer, old_name: []const u8, new_name: []const u8, r: Result, o: Options) !void {
    var kept: std.ArrayList(Change) = .empty;
    for (r.changes) |ch| if (keep(ch, o)) try kept.append(a, ch);

    if (o.tsv) return tsv(w, r, kept.items, o);

    var n_added: usize = 0;
    var n_removed: usize = 0;
    var n_changed: usize = 0;
    var n_tags: usize = 0;
    var n_moved: usize = 0;
    for (kept.items) |ch| {
        switch (ch.what) {
            .added => n_added += 1,
            .removed => n_removed += 1,
            .changed => n_changed += 1,
        }
        const d = (ch.old orelse ch.new).?;
        if (ch.what != .changed and isTag(d)) n_tags += 1;
        if (r.moved.contains(ch.path)) n_moved += 1;
    }
    try w.print("# zephem diff {s} → {s}", .{ old_name, new_name });
    if (o.prefix) |p| try w.print("  (under {s})", .{p});
    try w.print("\n\n{d} removed · {d} changed · {d} added  (public declarations", .{ n_removed, n_changed, n_added });
    if (n_tags > 0) try w.print("; {d} of them enum tags, summarised per enum", .{n_tags});
    if (n_moved > 0) try w.print("; {d} paired as {d} moves, inferred", .{ n_moved, n_moved / 2 });
    try w.writeAll(")\n");
    if (kept.items.len == 0 and r.builtins.len == 0 and r.values.len == 0) return;

    // Where it moved.
    if (kept.items.len > 0) {
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
    }

    // Moves (inferred) come before the removed list, so the reader sees "went here" first.
    {
        var count: usize = 0;
        for (r.moves) |m| if (inScope(m.from, o) or inScope(m.to, o)) {
            count += 1;
        };
        if (count > 0) {
            try w.print("\n## moved — INFERRED: same name, kind and signature, unique on both sides ({d})\n\n", .{count});
            var shown: usize = 0;
            for (r.moves) |m| {
                if (!(inScope(m.from, o) or inScope(m.to, o))) continue;
                if (o.limit != 0 and shown == o.limit) {
                    try w.print("… {d} more\n", .{count - shown});
                    break;
                }
                shown += 1;
                try w.print("- `{s}` → `{s}`  ({s})\n", .{ m.from, m.to, m.decl.kind });
            }
        }
    }

    try section(w, kept.items, r.moved, .removed, "removed — these break code that used them (moves and enum tags listed in their own sections)", o.limit);

    if (r.tag_sets.len > 0) {
        var count: usize = 0;
        for (r.tag_sets) |t| if (inScope(t.@"enum", o)) {
            count += 1;
        };
        if (count > 0) {
            try w.print("\n## enum tag sets ({d} enums)\n\n", .{count});
            var shown: usize = 0;
            for (r.tag_sets) |t| {
                if (!inScope(t.@"enum", o)) continue;
                if (o.limit != 0 and shown == o.limit) {
                    try w.print("… {d} more enums\n", .{count - shown});
                    break;
                }
                shown += 1;
                try w.print("- `{s}`:", .{t.@"enum"});
                for (t.removed) |n| try w.print(" -{s}", .{n});
                for (t.added) |n| try w.print(" +{s}", .{n});
                try w.writeAll("\n");
            }
        }
    }

    try section(w, kept.items, r.moved, .changed, "changed — kind, visibility or signature", o.limit);

    {
        var count: usize = 0;
        for (r.deprecations) |d| if (inScope(d.path, o)) {
            count += 1;
        };
        if (count > 0) {
            try w.print("\n## deprecations ({d})\n\n", .{count});
            var shown: usize = 0;
            for (r.deprecations) |d| {
                if (!inScope(d.path, o)) continue;
                if (o.limit != 0 and shown == o.limit) {
                    try w.print("… {d} more\n", .{count - shown});
                    break;
                }
                shown += 1;
                const label: []const u8 = switch (d.state) {
                    .newly => "newly deprecated",
                    .lifted => "no longer deprecated",
                    .removed => "deprecated, now removed",
                };
                try w.print("- `{s}`  {s}: {s}\n", .{ d.path, label, firstLine(d.doc) });
            }
        }
    }

    if (r.builtins.len > 0 and o.prefix == null) {
        try w.print("\n## builtins ({d})\n\n", .{r.builtins.len});
        for (r.builtins) |b| switch (b.state) {
            .added => try w.print("- `{s}`  added  {s}\n", .{ b.name, b.new.?.sig }),
            .removed => try w.print("- `{s}`  removed  {s}\n", .{ b.name, b.old.?.sig }),
            .changed => try w.print("- `{s}`\n    - was: {s}\n    - now: {s}\n", .{ b.name, b.old.?.sig, b.new.?.sig }),
        };
    }

    {
        var count: usize = 0;
        for (r.values) |v| if (inScope(v.path, o)) {
            count += 1;
        };
        if (count > 0) {
            try w.print("\n## resolved values changed ({d})\n\n", .{count});
            var shown: usize = 0;
            for (r.values) |v| {
                if (!inScope(v.path, o)) continue;
                if (o.limit != 0 and shown == o.limit) {
                    try w.print("… {d} more\n", .{count - shown});
                    break;
                }
                shown += 1;
                try w.print("- `{s}`  {s} → {s}\n", .{ v.path, v.old, v.new });
            }
        }
    }

    try section(w, kept.items, r.moved, .added, "added (moves and enum tags listed in their own sections)", o.limit);
}

fn firstLine(s: []const u8) []const u8 {
    return if (std.mem.find(u8, s, "\n")) |i| s[0..i] else s;
}

fn listed(ch: Change, moved: std.StringHashMapUnmanaged(void)) bool {
    const d = (ch.old orelse ch.new).?;
    if (ch.what != .changed and isTag(d)) return false;
    if (moved.contains(ch.path)) return false;
    return true;
}

fn section(w: *std.Io.Writer, changes: []const Change, moved: std.StringHashMapUnmanaged(void), what: What, title: []const u8, limit: usize) !void {
    var total: usize = 0;
    for (changes) |ch| if (ch.what == what and listed(ch, moved)) {
        total += 1;
    };
    if (total == 0) return;
    try w.print("\n## {s} ({d})\n\n", .{ title, total });
    var shown: usize = 0;
    for (changes) |ch| {
        if (ch.what != what or !listed(ch, moved)) continue;
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

/// One row per finding. Columns are stable and only ever appended to:
/// change · provenance · path · kind_old · kind_new · old · new
fn tsv(w: *std.Io.Writer, r: Result, kept: []const Change, o: Options) !void {
    try w.writeAll("change\tprovenance\tpath\tkind_old\tkind_new\told\tnew\n");
    for (kept) |ch| {
        try w.print("{t}\textracted\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{ ch.what, ch.path, kindOr(ch.old), kindOr(ch.new), sigOr(ch.old), sigOr(ch.new) });
    }
    for (r.moves) |m| {
        if (!(inScope(m.from, o) or inScope(m.to, o))) continue;
        try w.print("moved\tinferred\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{ m.from, m.decl.kind, m.decl.kind, m.from, m.to });
    }
    for (r.deprecations) |d| {
        if (!inScope(d.path, o)) continue;
        const tag: []const u8 = switch (d.state) {
            .newly => "deprecated",
            .lifted => "undeprecated",
            .removed => "deprecated_removed",
        };
        try w.print("{s}\textracted\t{s}\t\t\t\t{s}\n", .{ tag, d.path, firstLine(d.doc) });
    }
    if (o.prefix == null) for (r.builtins) |b| {
        const tag: []const u8 = switch (b.state) {
            .added => "builtin_added",
            .removed => "builtin_removed",
            .changed => "builtin_changed",
        };
        try w.print("{s}\textracted\t{s}\tbuiltin\tbuiltin\t{s}\t{s}\n", .{ tag, b.name, if (b.old) |x| x.sig else "", if (b.new) |x| x.sig else "" });
    };
    for (r.values) |v| {
        if (!inScope(v.path, o)) continue;
        try w.print("value_changed\textracted\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{ v.path, v.kind, v.kind, v.old, v.new });
    }
}

// ---------------------------------------------------------------- command ----------

pub fn run(c: Ctx, args: []const []const u8) !void {
    const usage =
        \\usage: zephem diff <old> <new> [--module <prefix>] [--only added|removed|changed]
        \\                   [--private] [--limit N] [--tsv]
        \\
        \\  compare two frozen maps: a Zig version under data/versions/ (0.16.0), or `live`
        \\  for data/std/. Public declarations by default. Reports removed / changed / added
        \\  declarations, moves (inferred), enum tag sets, deprecations, builtins and resolved
        \\  values — see docs/release-diff.md.
        \\  --module P   only paths under P (std.mem, std.Io.Dir, …)
        \\  --only W     one kind of declaration change in the lists
        \\  --private    include private declarations
        \\  --limit N    rows per section (default 40; 0 = all)
        \\  --tsv        one row per finding: change · provenance · path · kind_old · kind_new · old · new
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
    const result = try analyze(c.a, old, new, include_private);
    try report(c.a, w, old_name, new_name, result, o);
}
