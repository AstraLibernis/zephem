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
//!   const_bool with a different value); **signature changes classified by how they fail**
//!   (arity, parameter order with the same types, types, return type, error set, names only);
//!   **doc-only changes** (same declaration, different prose), flagged when the new text says
//!   "no longer" or "now" — the one signal for a semantics change.
//! - a **curated** note per version (`data/versions/<v>/LANGUAGE.md`, from the release notes,
//!   hand-written): language changes the map cannot see. Appended to the report, labelled.
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
const sigmod = @import("sig.zig");

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
    /// For a `changed` declaration whose signature differs: how the change fails.
    sig_change: ?SigChange = null,
};

/// How a signature change fails for code written against the old one.
pub const SigChange = enum {
    /// parameter count differs — the call does not compile
    arity,
    /// same parameter types in a different order — the call COMPILES and is wrong
    order,
    /// a parameter type differs
    types,
    /// the return payload differs
    return_type,
    /// only the error set differs
    error_set,
    /// only parameter names differ — cosmetic
    names,
    /// whitespace or a trailing comma only — cosmetic (normally folded away before classifying)
    format,
    /// the new side has no signature at all (a fn became an alias or a const)
    sig_dropped,
    /// the old side had no signature and the new one has (an alias or const became a fn)
    sig_gained,
    /// one side could not be parsed as `fn name(params) ret`
    other,
};

/// A signature with runs of whitespace collapsed to one space and a trailing comma before
/// `)` removed — the two ways `zig fmt` rewrites a signature without changing it.
pub fn normalizeSig(a: std.mem.Allocator, sig: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending_space = false;
    for (sig) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n') {
            pending_space = out.items.len > 0;
            continue;
        }
        if (pending_space) {
            // No space before a closer or a comma, nor after an opener; otherwise one space.
            const last = out.items[out.items.len - 1];
            const after_opener = last == '(' or last == '[' or last == '{';
            if (!after_opener and ch != ')' and ch != ']' and ch != '}' and ch != ',') try out.append(a, ' ');
            pending_space = false;
        }
        if (ch == ')' and out.items.len > 0 and out.items[out.items.len - 1] == ',') _ = out.pop();
        try out.append(a, ch);
    }
    return out.items;
}

fn sigEqlNormalized(a: std.mem.Allocator, x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null and y == null) return true;
    if (x == null or y == null) return false;
    const nx = normalizeSig(a, x.?) catch return false;
    const ny = normalizeSig(a, y.?) catch return false;
    return std.mem.eql(u8, nx, ny);
}

/// A parsed signature: parameter names, parameter types and the return type, as written.
pub const SigShape = struct {
    names: []const []const u8,
    types: []const []const u8,
    ret: []const u8,
};

/// Parse `fn name(a: T, comptime b: U) R` into its parts (prose inside the parameter list is
/// removed first, see sig.zig). Returns null when the text is not shaped like a fn signature.
pub fn parseSig(a: std.mem.Allocator, raw: []const u8) ?SigShape {
    const text = sigmod.split(a, raw).sig;
    const open = std.mem.find(u8, text, "(") orelse return null;
    // The matching close paren at depth 0.
    var depth: usize = 0;
    var close: ?usize = null;
    for (text[open..], open..) |ch, i| {
        switch (ch) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -|= 1;
                if (depth == 0) {
                    close = i;
                    break;
                }
            },
            else => {},
        }
    }
    const end = close orelse return null;
    var names: std.ArrayList([]const u8) = .empty;
    var types: std.ArrayList([]const u8) = .empty;
    var seg_start = open + 1;
    depth = 0;
    var i = open + 1;
    while (i <= end) : (i += 1) {
        const ch = text[i];
        if (i < end) switch (ch) {
            '(', '[', '{' => {
                depth += 1;
                continue;
            },
            ')', ']', '}' => {
                depth -|= 1;
                continue;
            },
            else => {},
        };
        if (i == end or (ch == ',' and depth == 0)) {
            const seg = std.mem.trim(u8, text[seg_start..i], " \t\n");
            seg_start = i + 1;
            if (seg.len == 0) continue; // trailing comma
            // `name: Type`, with `comptime`/`noalias` qualifiers before the name; `...` is varargs.
            if (findColonAtDepth0(seg)) |colon| {
                var name = std.mem.trim(u8, seg[0..colon], " ");
                while (std.mem.findScalarLast(u8, name, ' ')) |sp| name = std.mem.trim(u8, name[sp + 1 ..], " ");
                names.append(a, name) catch return null;
                types.append(a, std.mem.trim(u8, seg[colon + 1 ..], " ")) catch return null;
            } else {
                names.append(a, "") catch return null;
                types.append(a, seg) catch return null;
            }
        }
    }
    return .{ .names = names.items, .types = types.items, .ret = std.mem.trim(u8, text[end + 1 ..], " ") };
}

fn findColonAtDepth0(seg: []const u8) ?usize {
    var depth: usize = 0;
    for (seg, 0..) |ch, i| switch (ch) {
        '(', '[', '{' => depth += 1,
        ')', ']', '}' => depth -|= 1,
        ':' => if (depth == 0) return i,
        else => {},
    };
    return null;
}

/// The error-set part and the payload of a return type (`Allocator.Error!void` → both;
/// `!void` → inferred set + payload; `void` → none + payload).
fn splitReturn(ret: []const u8) struct { err: []const u8, payload: []const u8 } {
    var depth: usize = 0;
    for (ret, 0..) |ch, i| switch (ch) {
        '(', '[', '{' => depth += 1,
        ')', ']', '}' => depth -|= 1,
        '!' => if (depth == 0) return .{ .err = ret[0..i], .payload = ret[i + 1 ..] },
        else => {},
    };
    return .{ .err = "", .payload = ret };
}

/// Classify how `new_sig` differs from `old_sig` for a caller of the old one.
pub fn classify(a: std.mem.Allocator, old_sig: []const u8, new_sig: []const u8) SigChange {
    const o = parseSig(a, old_sig) orelse return .other;
    const n = parseSig(a, new_sig) orelse return .other;
    if (o.types.len != n.types.len) return .arity;
    var same_types = true;
    for (o.types, n.types) |x, y| if (!std.mem.eql(u8, x, y)) {
        same_types = false;
    };
    if (same_types) {
        if (std.mem.eql(u8, o.ret, n.ret)) {
            for (o.names, n.names) |x, y| if (!std.mem.eql(u8, x, y)) return .names;
            return .format;
        }
        const ro = splitReturn(o.ret);
        const rn = splitReturn(n.ret);
        return if (std.mem.eql(u8, ro.payload, rn.payload)) .error_set else .return_type;
    }
    // Same multiset of types in a different order?
    const used = a.alloc(bool, n.types.len) catch return .types;
    @memset(used, false);
    var all_found = true;
    outer: for (o.types) |x| {
        for (n.types, 0..) |y, j| {
            if (!used[j] and std.mem.eql(u8, x, y)) {
                used[j] = true;
                continue :outer;
            }
        }
        all_found = false;
        break;
    }
    return if (all_found) .order else .types;
}

/// A declaration whose prose changed while kind, visibility and signature stayed the same.
pub const DocChange = struct {
    path: []const u8,
    old: []const u8,
    new: []const u8,
    /// The new text says "no longer" or "now" where the old did not — read it.
    hint: bool,
};

pub const Move = struct {
    from: []const u8,
    to: []const u8,
    decl: Decl,
    /// What backs the pairing beyond the unique name + kind: the signature, or the parents
    /// (the declaration's parent moved to the new parent too, or two or more declarations
    /// moved between the same two parents).
    support: enum { signature, parents },
};

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
    pub const State = enum { added, removed, changed, doc };
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
    docs: []const DocChange,
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
            const gop = try side.resolved.getOrPut(a, path);
            if (gop.found_existing) continue; // resolved.tsv repeats some fn/type paths
            gop.value_ptr.* = .{ .kind = t.cell(row, "kind"), .detail = t.cell(row, "detail") };
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
            const same_sig = sigEqlNormalized(a, o.sig, n.sig);
            const same = std.mem.eql(u8, o.kind, n.kind) and std.mem.eql(u8, o.vis, n.vis) and same_sig;
            if (!same) {
                const sc: ?SigChange = if (same_sig) null else if (o.sig != null and n.sig != null) classify(a, o.sig.?, n.sig.?) else if (o.sig != null) .sig_dropped else .sig_gained;
                try out.append(a, .{ .what = .changed, .path = p, .old = o, .new = n, .sig_change = sc });
            }
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
/// Enum tags are excluded (they are summarised per enum).
///
/// A declaration without a signature (a field, a container, a const) has only its name and
/// kind to pair on, and a unique name is not enough: an audit of the 0.16 → 0.17 run found
/// ~3% coincidences (`Fuzz.CoverageMap.mapped_memory` → `MachOFile.DsymFile.mapped_memory`).
/// So a sig-less candidate is accepted only with **support**, any of:
/// - its parent is itself an accepted move to the new parent (downward);
/// - at least two of its own children are accepted moves into the new path (upward);
/// - at least two candidates move between the same two parents;
/// - the two parents share at least two members by (name, kind) among what one lost and the
///   other gained — members whose names are too common to be candidates themselves still
///   count here (a `Struct` whose `layout`, `fields`, `decls` all reappear under the new parent);
///   the candidate itself is not counted.
/// Two coincidences between the same pair of containers are unlikely; one is not. Computed to a
/// fixpoint so a moved container vouches for its members and vice versa. The second audit of
/// 0.16 → 0.17 found 12 true moves lost to the parent-only rule; the last two clauses recover them.
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
    // Candidates: unique on both sides.
    var cands: std.ArrayList(Move) = .empty;
    for (changes) |ch| {
        if (ch.what != .removed) continue;
        const d = ch.old.?;
        if (isTag(d)) continue;
        const key = try Key.of(a, d);
        const ri = removed.get(key).?;
        if (ri == ambiguous) continue;
        const ai = added.get(key) orelse continue;
        if (ai == ambiguous) continue;
        try cands.append(a, .{ .from = ch.path, .to = changes[ai].path, .decl = d, .support = if (d.sig != null) .signature else .parents });
    }
    // Signature-backed candidates stand on their own. Sig-less ones need support.
    const accepted = try a.alloc(bool, cands.items.len);
    @memset(accepted, false);
    var pair_count: std.StringHashMapUnmanaged(usize) = .empty; // "fromParent\x00toParent" → candidates
    for (cands.items) |m| {
        const gop = try pair_count.getOrPut(a, try parentPair(a, m));
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    // Members each container lost / gained, by (name, kind), for the shared-members clause.
    var lost: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty; // parent → ["name\x00kind"]
    var gained: std.StringHashMapUnmanaged(void) = .empty; // "parent\x00name\x00kind"
    for (changes) |ch| {
        const d = (if (ch.what == .removed) ch.old else if (ch.what == .added) ch.new else null) orelse continue;
        if (isTag(d)) continue;
        const parent = util.dottedParent(ch.path);
        if (ch.what == .removed) {
            const gop = try lost.getOrPut(a, parent);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, try a.print("{s}\x00{s}", .{ d.name, d.kind }));
        } else {
            try gained.put(a, try a.print("{s}\x00{s}\x00{s}", .{ parent, d.name, d.kind }), {});
        }
    }
    var accepted_pairs: std.StringHashMapUnmanaged(void) = .empty; // "from\x00to" of accepted moves
    var child_count: std.StringHashMapUnmanaged(usize) = .empty; // "fromParent\x00toParent" → accepted children
    for (cands.items, 0..) |m, i| if (m.support == .signature) {
        accepted[i] = true;
        try accepted_pairs.put(a, try a.print("{s}\x00{s}", .{ m.from, m.to }), {});
        const gop = try child_count.getOrPut(a, try parentPair(a, m));
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    };
    var progress = true;
    while (progress) {
        progress = false;
        for (cands.items, 0..) |m, i| {
            if (accepted[i]) continue;
            const pp = try parentPair(a, m);
            const own = try a.print("{s}\x00{s}", .{ m.from, m.to });
            const ok = (pair_count.get(pp) orelse 0) >= 2 or // two candidates between the same parents
                accepted_pairs.contains(pp) or // the parent itself moved there (downward)
                (child_count.get(own) orelse 0) >= 2 or // two of its children already moved there (upward)
                try sharedMembers(a, lost, gained, m, util.dottedParent(m.from), util.dottedParent(m.to)) >= 2;
            if (!ok) continue;
            accepted[i] = true;
            try accepted_pairs.put(a, own, {});
            const gop = try child_count.getOrPut(a, pp);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            progress = true;
        }
    }
    var out: std.ArrayList(Move) = .empty;
    for (cands.items, 0..) |m, i| if (accepted[i]) try out.append(a, m);
    return out.items;
}

/// How many members `from_parent` lost that `to_parent` gained, matched by (name, kind) — not
/// counting the candidate itself, which would otherwise vouch for its own move (a `State` enum
/// beside a `state` field, an `in` beside an `out`: one shared neighbour is still one coincidence).
fn sharedMembers(a: std.mem.Allocator, lost: std.StringHashMapUnmanaged(std.ArrayList([]const u8)), gained: std.StringHashMapUnmanaged(void), self: Move, from_parent: []const u8, to_parent: []const u8) !usize {
    const members = lost.get(from_parent) orelse return 0;
    const own = try a.print("{s}\x00{s}", .{ self.decl.name, self.decl.kind });
    var n: usize = 0;
    for (members.items) |nk| {
        if (std.mem.eql(u8, nk, own)) continue;
        if (gained.contains(try a.print("{s}\x00{s}", .{ to_parent, nk }))) n += 1;
    }
    return n;
}

fn parentPair(a: std.mem.Allocator, m: Move) ![]const u8 {
    return a.print("{s}\x00{s}", .{ util.dottedParent(m.from), util.dottedParent(m.to) });
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

/// Builtins added, removed, with a different signature, or with the same signature and
/// different langref prose (`doc`: the only signal for a semantics change, e.g. `@bitCast`).
pub fn builtinChanges(a: std.mem.Allocator, old: Side, new: Side) ![]const BuiltinChange {
    var out: std.ArrayList(BuiltinChange) = .empty;
    for (old.builtin_names) |n| {
        const o = old.builtins.get(n).?;
        if (new.builtins.get(n)) |nw| {
            if (!std.mem.eql(u8, o.sig, nw.sig)) {
                try out.append(a, .{ .name = n, .state = .changed, .old = o, .new = nw });
            } else if (!std.mem.eql(u8, o.doc, nw.doc)) {
                try out.append(a, .{ .name = n, .state = .doc, .old = o, .new = nw });
            }
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

fn semanticHint(old_doc: []const u8, new_doc: []const u8) bool {
    const phrases = [_][]const u8{ "no longer", "now " };
    for (phrases) |ph| {
        if (std.ascii.findIgnoreCase(new_doc, ph) != null and std.ascii.findIgnoreCase(old_doc, ph) == null) return true;
    }
    return false;
}

/// Declarations present on both sides, otherwise unchanged, whose doc text differs.
pub fn docChanges(a: std.mem.Allocator, old: Side, new: Side, include_private: bool) ![]const DocChange {
    var out: std.ArrayList(DocChange) = .empty;
    for (old.paths) |p| {
        const o = old.decls.get(p).?;
        const n = new.decls.get(p) orelse continue;
        if (!include_private and !isPub(o) and !isPub(n)) continue;
        const same_decl = std.mem.eql(u8, o.kind, n.kind) and std.mem.eql(u8, o.vis, n.vis) and sigEqlNormalized(a, o.sig, n.sig);
        if (!same_decl) continue;
        if (optEql(o.doc, n.doc)) continue;
        // Gaining or losing the Deprecated marker is reported as a deprecation, not a doc change.
        if (o.deprecated() != n.deprecated()) continue;
        const od = o.doc orelse "";
        const nd = n.doc orelse "";
        try out.append(a, .{ .path = p, .old = od, .new = nd, .hint = semanticHint(od, nd) });
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
        .docs = try docChanges(a, old, new, include_private),
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
    var n_hidden: usize = 0;
    for (kept.items) |ch| {
        switch (ch.what) {
            .added => n_added += 1,
            .removed => n_removed += 1,
            .changed => {
                n_changed += 1;
                if (isPub(ch.old.?) and !isPub(ch.new.?)) n_hidden += 1;
            },
        }
        const d = (ch.old orelse ch.new).?;
        if (ch.what != .changed and isTag(d)) n_tags += 1;
    }
    var n_moves: usize = 0;
    for (r.moves) |m| if (inScope(m.from, o) or inScope(m.to, o)) {
        n_moves += 1;
    };
    try w.print("# zephem diff {s} → {s}", .{ old_name, new_name });
    if (o.prefix) |p| try w.print("  (under {s})", .{p});
    try w.print("\n\n{d} removed · {d} changed · {d} added  (public declarations", .{ n_removed, n_changed, n_added });
    if (n_tags > 0) try w.print("; {d} of them enum tags, summarised per enum", .{n_tags});
    if (n_moves > 0) try w.print("; {d} moves inferred", .{n_moves});
    if (n_hidden > 0) try w.print("; {d} went private — a removal in practice", .{n_hidden});
    try w.writeAll(")\n");
    {
        var by_class: [@typeInfo(SigChange).@"enum".field_names.len]usize = @splat(0);
        var any = false;
        for (kept.items) |ch| if (ch.sig_change) |sc| {
            by_class[@backingInt(sc)] += 1;
            any = true;
        };
        if (any) {
            try w.writeAll("signature changes by failure mode:");
            inline for (@typeInfo(SigChange).@"enum".field_names, 0..) |name, idx| {
                if (by_class[idx] > 0) try w.print(" {d} {s} ·", .{ by_class[idx], name });
            }
            try w.writeAll("  (order = compiles and is wrong)\n");
        }
    }
    if (kept.items.len == 0 and r.builtins.len == 0 and r.values.len == 0 and r.docs.len == 0) return;

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
            try w.print("\n## moved — INFERRED: unique name + kind, backed by the signature or by the parents moving together ({d})\n\n", .{count});
            var shown: usize = 0;
            for (r.moves) |m| {
                if (!(inScope(m.from, o) or inScope(m.to, o))) continue;
                if (o.limit != 0 and shown == o.limit) {
                    try w.print("… {d} more\n", .{count - shown});
                    break;
                }
                shown += 1;
                try w.print("- `{s}` → `{s}`  ({s}; by {t})\n", .{ m.from, m.to, m.decl.kind, m.support });
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
            .doc => try w.print("- `{s}`  same signature, langref text changed — read it\n", .{b.name}),
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

    {
        var count: usize = 0;
        var hints: usize = 0;
        for (r.docs) |d| if (inScope(d.path, o)) {
            count += 1;
            if (d.hint) hints += 1;
        };
        if (count > 0) {
            try w.print("\n## docs changed, declaration unchanged ({d}; {d} say \"no longer\" / \"now\" — read those)\n\n", .{ count, hints });
            var shown: usize = 0;
            for (r.docs) |d| {
                if (!inScope(d.path, o) or !d.hint) continue;
                if (o.limit != 0 and shown == o.limit) {
                    try w.print("… {d} more flagged\n", .{hints - shown});
                    break;
                }
                shown += 1;
                try w.print("- `{s}`\n    - was: {s}\n    - now: {s}\n", .{ d.path, firstLine(d.old), firstLine(d.new) });
            }
            if (count > hints) try w.print("- … and {d} with reworded docs and no such phrase (listed in --tsv as doc_changed)\n", .{count - hints});
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
                    if (ch.sig_change) |sc| try w.print("    - signature: {t}{s}\n", .{ sc, if (sc == .order) " — same types, different order: compiles and is wrong" else "" });
                    try w.print("    - was: {s}\n    - now: {s}\n", .{ sigOr(ch.old), sigOr(ch.new) });
                }
            },
        }
    }
}

/// One row per finding. Columns are stable and only ever appended to:
/// change · provenance · path · kind_old · kind_new · old · new · detail
/// (`detail` = the signature failure mode for changed rows, `hint` for flagged doc rows)
fn tsv(w: *std.Io.Writer, r: Result, kept: []const Change, o: Options) !void {
    try w.writeAll("change\tprovenance\tpath\tkind_old\tkind_new\told\tnew\tdetail\n");
    for (kept) |ch| {
        try w.print("{t}\textracted\t{s}\t{s}\t{s}\t{s}\t{s}\t", .{ ch.what, ch.path, kindOr(ch.old), kindOr(ch.new), sigOr(ch.old), sigOr(ch.new) });
        if (ch.sig_change) |sc| try w.print("{t}", .{sc});
        try w.writeAll("\n");
    }
    for (r.docs) |d| {
        if (!inScope(d.path, o)) continue;
        try w.print("doc_changed\textracted\t{s}\t\t\t{s}\t{s}\t{s}\n", .{ d.path, firstLine(d.old), firstLine(d.new), if (d.hint) "hint" else "" });
    }
    for (r.moves) |m| {
        if (!(inScope(m.from, o) or inScope(m.to, o))) continue;
        try w.print("moved\tinferred\t{s}\t{s}\t{s}\t{s}\t{s}\t{t}\n", .{ m.from, m.decl.kind, m.decl.kind, m.from, m.to, m.support });
    }
    for (r.deprecations) |d| {
        if (!inScope(d.path, o)) continue;
        const tag: []const u8 = switch (d.state) {
            .newly => "deprecated",
            .lifted => "undeprecated",
            .removed => "deprecated_removed",
        };
        try w.print("{s}\textracted\t{s}\t\t\t\t{s}\t\n", .{ tag, d.path, firstLine(d.doc) });
    }
    if (o.prefix == null) for (r.builtins) |b| {
        const tag: []const u8 = switch (b.state) {
            .added => "builtin_added",
            .removed => "builtin_removed",
            .changed => "builtin_changed",
            .doc => "builtin_doc_changed",
        };
        try w.print("{s}\textracted\t{s}\tbuiltin\tbuiltin\t{s}\t{s}\t\n", .{ tag, b.name, if (b.old) |x| x.sig else "", if (b.new) |x| x.sig else "" });
    };
    for (r.values) |v| {
        if (!inScope(v.path, o)) continue;
        try w.print("value_changed\textracted\t{s}\t{s}\t{s}\t{s}\t{s}\t\n", .{ v.path, v.kind, v.kind, v.old, v.new });
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
        \\  --tsv        one row per finding: change · provenance · path · kind_old · kind_new · old · new · detail
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

    // Curated, not extracted: language changes the map cannot see, written by hand from the
    // release notes and kept beside the version folder. Labelled so in the report; never in TSV.
    if (!o.tsv) {
        const note_path = try util.join(c.a, new_dir, "LANGUAGE.md");
        if (std.Io.Dir.cwd().readFileAlloc(c.io, note_path, c.a, .unlimited)) |note| {
            try w.print("\n## language changes — CURATED from the release notes, not extracted ({s})\n\n", .{note_path});
            try w.writeAll(note);
            if (note.len > 0 and note[note.len - 1] != '\n') try w.writeAll("\n");
        } else |_| {}
    }
}
