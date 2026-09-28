// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! redirect.zig — follow `alias` and `delegates` edges from a name to where its members live.
//!
//! The most-used std types are thin names over something else. `std.ArrayList` is
//! `fn ArrayList(T) type { return array_list.Aligned(T, null); }`, so its members sit under
//! `std.array_list.Aligned().…`; `std.StringHashMap` is an alias of `hash_map.StringHashMap`,
//! which delegates to `hash_map.HashMap`, whose members sit under `HashMap().…`. The edges
//! recording this were already in `edges.tsv`, but the queries never followed them, so
//! `map show std.ArrayList` listed one row and `look ArrayList append` found nothing.
//!
//! Only edges whose target resolved to a node (`local`/`cross`) are followed. Nothing here is
//! invented: every hop is an edge the parser recorded from the source.
const std = @import("std");
const rel = @import("relation.zig");

/// Longest chain followed. The longest real chain in 0.16 std is 3 hops; the cap only exists
/// so a cycle cannot loop forever.
const max_hops = 8;

pub const Hop = struct { kind: []const u8, target: []const u8 };

pub const Redirects = struct {
    a: std.mem.Allocator,
    /// src → its one redirect (first `alias`/`delegates` edge that resolved to a node)
    next: std.StringHashMap(Hop),
    /// paths that exist in nodes.tsv
    exists: std.StringHashMap(void),
    /// vis per path, to keep private redirects out of `aka`
    vis: std.StringHashMap([]const u8),

    /// Build from nodes.tsv + edges.tsv.
    pub fn build(a: std.mem.Allocator, nodes: rel.Table, edges: rel.Table) !Redirects {
        var r: Redirects = .{
            .a = a,
            .next = .init(a),
            .exists = .init(a),
            .vis = .init(a),
        };
        const np = nodes.col("path");
        const nv = nodes.col("vis");
        for (nodes.rows) |row| {
            try r.exists.put(row[np], {});
            try r.vis.put(row[np], row[nv]);
        }
        const es = edges.col("src");
        const et = edges.col("type");
        const eg = edges.col("target");
        const esc = edges.col("scope");
        for (edges.rows) |row| {
            const t = row[et];
            if (!std.mem.eql(u8, t, "alias") and !std.mem.eql(u8, t, "delegates")) continue;
            const scope = row[esc];
            if (!std.mem.eql(u8, scope, "local") and !std.mem.eql(u8, scope, "cross")) continue;
            if (!r.exists.contains(row[eg])) continue;
            const gop = try r.next.getOrPut(row[es]);
            if (!gop.found_existing) gop.value_ptr.* = .{ .kind = t, .target = row[eg] };
        }
        return r;
    }

    /// Where `path`'s members live, and the hops taken to get there. Null when `path` has no
    /// redirect. The members prefix is `T()` when the final target is a factory whose members
    /// the parser descended, otherwise `T` itself.
    pub fn resolve(r: *const Redirects, path: []const u8) !?struct { members: []const u8, hops: []const Hop } {
        var hops: std.ArrayList(Hop) = .empty;
        var cur = path;
        while (hops.items.len < max_hops) {
            const h = r.next.get(cur) orelse break;
            try hops.append(r.a, h);
            cur = h.target;
        }
        if (hops.items.len == 0) return null;
        const call = try std.fmt.allocPrint(r.a, "{s}()", .{cur});
        const members = if (r.exists.contains(call)) call else cur;
        return .{ .members = members, .hops = hops.items };
    }

    /// Rewrite a path a user would type through its redirects: `std.ArrayList.append` or
    /// `std.ArrayList().append` → `std.array_list.Aligned().append`. Tries the longest
    /// redirecting prefix first. Null when no prefix redirects or the rewrite is not a node.
    pub fn rewrite(r: *const Redirects, path: []const u8) !?[]const u8 {
        var end = path.len;
        while (end > 0) {
            const dot = std.mem.findScalarLast(u8, path[0..end], '.') orelse break;
            end = dot;
            var head = path[0..end];
            if (std.mem.endsWith(u8, head, "()")) head = head[0 .. head.len - 2];
            const res = (try r.resolve(head)) orelse continue;
            const candidate = try std.fmt.allocPrint(r.a, "{s}{s}", .{ res.members, path[dot..] });
            if (r.exists.contains(candidate)) return candidate;
        }
        return null;
    }

    /// Every public name that reaches `target` through redirects, transitively
    /// (`std.hash_map.HashMap` ← `hash_map.StringHashMap` ← `std.StringHashMap`).
    pub fn sourcesOf(r: *const Redirects, rev: *const std.StringHashMap(std.ArrayList([]const u8)), target: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var frontier: std.ArrayList([]const u8) = .empty;
        try frontier.append(r.a, target);
        var depth: usize = 0;
        while (frontier.items.len > 0 and depth < max_hops) : (depth += 1) {
            var nextf: std.ArrayList([]const u8) = .empty;
            for (frontier.items) |t| {
                const srcs = rev.get(t) orelse continue;
                for (srcs.items) |s| {
                    if (contains(out.items, s)) continue;
                    try nextf.append(r.a, s);
                    if (std.mem.eql(u8, r.vis.get(s) orelse "", "pub")) try out.append(r.a, s);
                }
            }
            frontier = nextf;
        }
        std.mem.sort([]const u8, out.items, {}, lessStr);
        return out.items;
    }

    /// target → the names that redirect straight to it.
    pub fn reverseMap(r: *const Redirects) !std.StringHashMap(std.ArrayList([]const u8)) {
        var m = std.StringHashMap(std.ArrayList([]const u8)).init(r.a);
        var it = r.next.iterator();
        while (it.next()) |e| {
            const gop = try m.getOrPut(e.value_ptr.target);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(r.a, e.key_ptr.*);
        }
        return m;
    }
};

/// Load only the `alias`/`delegates` rows of edges.tsv — all `Redirects.build` reads, and a
/// small fraction of the file, so the query commands skip splitting the other ~50k rows.
pub fn loadEdges(a: std.mem.Allocator, io: std.Io, path: []const u8) !rel.Table {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    var kept: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (lines.next()) |header| {
        try kept.appendSlice(a, header);
        try kept.append(a, '\n');
    }
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "\talias\t") == null and std.mem.find(u8, line, "\tdelegates\t") == null) continue;
        try kept.appendSlice(a, line);
        try kept.append(a, '\n');
    }
    return rel.loadBytes(a, kept.items);
}

/// The alternative names a node is reachable by, comma-joined, or "" — e.g. for
/// `std.array_list.Aligned().append` → `std.ArrayList().append`. Built once per lookup bake.
pub const Aka = struct {
    r: *const Redirects,
    rev: std.StringHashMap(std.ArrayList([]const u8)),
    memo: std.StringHashMap([]const []const u8),

    pub fn init(r: *const Redirects) !Aka {
        return .{ .r = r, .rev = try r.reverseMap(), .memo = .init(r.a) };
    }

    pub fn of(self: *Aka, path: []const u8) ![]const u8 {
        // Split at each `.`/`()` boundary; the longest prefix that someone redirects to wins.
        var end = path.len;
        while (end > 0) {
            const dot = std.mem.findScalarLast(u8, path[0..end], '.') orelse break;
            end = dot;
            var head = path[0..end];
            if (std.mem.endsWith(u8, head, "()")) head = head[0 .. head.len - 2];
            const srcs = try self.sources(head);
            if (srcs.len == 0) continue;
            var buf: std.ArrayList(u8) = .empty;
            for (srcs, 0..) |s, i| {
                if (i > 0) try buf.appendSlice(self.r.a, ", ");
                // keep the `()` when the member hangs off a factory call
                const call = if (std.mem.endsWith(u8, path[0..end], "()")) "()" else "";
                try buf.print(self.r.a, "{s}{s}{s}", .{ s, call, path[dot..] });
            }
            return buf.items;
        }
        return "";
    }

    fn sources(self: *Aka, target: []const u8) ![]const []const u8 {
        if (!self.rev.contains(target)) return &.{}; // the common case: nobody redirects here
        if (self.memo.get(target)) |s| return s;
        const s = try self.r.sourcesOf(&self.rev, target);
        try self.memo.put(target, s);
        return s;
    }
};

fn contains(xs: []const []const u8, x: []const u8) bool {
    for (xs) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
