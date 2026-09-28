// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! zmap.zig — the `map` subcommand: read the zephem map directly (port of `query/zmap.nu`).
//! Deterministic browse/discovery over the extracted TSVs — no baked table, no build step.
//!
//!   map find <terms...>   keyword search over path/name/sig/doc (ranked, private tagged [priv])
//!   map show <path>       list a module/namespace subtree, public/private sectioned
//!   map doc  <path>       signature + doc for one exact path
const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const vars = @import("vars.zig");
const argv = @import("args.zig");
const sigfmt = @import("sig.zig");
const Outcome = @import("query.zig").Outcome;
const toolchain = @import("toolchain.zig");
const rel = @import("relation.zig");
const redirect = @import("redirect.zig");

const Node = struct { path: []const u8, kind: []const u8, name: []const u8, vis: []const u8, sig: []const u8, doc: []const u8, mod: []const u8, errmembers: []const u8 };
const Map = struct { nodes: []const Node, redirects: redirect.Redirects };

pub fn run(c: Ctx, args: []const []const u8, out: *std.Io.Writer) !Outcome {
    const usage =
        \\zephem map — read the complete zephem std map (deterministic, no AI/DB)
        \\
        \\  map find <terms...>   keyword search over the whole map (path/name/sig/doc)
        \\  map show <path>       list a module/namespace subtree
        \\  map doc  <path>       signature + doc for one exact path
        \\
        \\  --limit N             cap `find` results (default 12)
        \\
        \\  exit: 0 found · 1 nothing matched · 2 usage · 3 map unavailable
        \\
    ;
    if (try argv.helpRequested(c, args, usage)) return .hit;

    // parse: <cmd> <positional...> [--limit N | -l N]
    var limit: usize = 12;
    var cmd: ?[]const u8 = null;
    var pos: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-l")) {
            limit = argv.intValue(c, usize, args, &i, arg, usage);
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            argv.reject(c, arg, usage);
        } else if (cmd == null) {
            cmd = arg;
        } else try pos.append(c.a, arg);
    }

    if (cmd == null) {
        try out.writeAll(usage);
        try out.flush();
        return .usage;
    }
    const command = cmd.?;
    // Validate the subcommand BEFORE loading the map: `map bogus` used to parse 63,494 nodes
    // and 111,480 attrs, run the staleness probe, and only then decide the command was wrong —
    // and returned 1 instead of 2 when the map was also broken.
    if (!std.mem.eql(u8, command, "find") and !std.mem.eql(u8, command, "show") and !std.mem.eql(u8, command, "doc")) {
        try argv.diag(c, "unknown map command: {s}\n\n{s}", .{ command, usage });
        return .usage;
    }
    // A missing or unreadable map is NOT a miss. It used to escape as an unhandled Zig error,
    // printing a stack trace and exiting 1 — the code that means "ran fine, nothing matched".
    const map = loadMap(c) catch |e| switch (e) {
        error.FileNotFound, error.AccessDenied, error.NotDir => {
            try argv.diag(c, "zephem: the map is unavailable ({s}) — regenerate it: `zephem std`\n", .{@errorName(e)});
            return .unavailable;
        },
        else => return e,
    };
    var outcome: Outcome = .hit;
    if (std.mem.eql(u8, command, "find")) {
        outcome = try cmdFind(c, out, map, pos.items, limit);
    } else if (std.mem.eql(u8, command, "show")) {
        outcome = try cmdShow(c, out, map, if (pos.items.len > 0) pos.items[0] else "");
    } else if (std.mem.eql(u8, command, "doc")) {
        outcome = try cmdDoc(c, out, map, if (pos.items.len > 0) pos.items[0] else "");
    }
    try out.flush();
    return outcome;
}

fn loadMap(c: Ctx) !Map {
    const a = c.a;
    const dir = try vars.dataDir(c);
    // staleness warning → stderr (keeps the result writer clean)
    if (toolchain.staleness(c, dir) catch null) |warn| {
        var eb: [512]u8 = undefined;
        var ew = std.Io.File.stderr().writer(c.io, &eb);
        ew.interface.print("{s}\n", .{warn}) catch {};
        ew.interface.flush() catch {};
    }
    const nodes = try rel.load(a, c.io, try std.fs.path.join(a, &.{ dir, "extracted/nodes.tsv" }));
    const attrs = try rel.load(a, c.io, try std.fs.path.join(a, &.{ dir, "extracted/attrs.tsv" }));
    const edges = try redirect.loadEdges(a, c.io, try std.fs.path.join(a, &.{ dir, "extracted/edges.tsv" }));
    var sig = std.StringHashMap([]const u8).init(a);
    var doc = std.StringHashMap([]const u8).init(a);
    var mod = std.StringHashMap([]const u8).init(a);
    var errm = std.StringHashMap([]const u8).init(a); // error-set members, comma-joined per path
    const ap = attrs.col("path");
    const aa = attrs.col("attr");
    const av = attrs.col("value");
    for (attrs.rows) |r| {
        if (std.mem.eql(u8, r[aa], "sig")) {
            const g = try sig.getOrPut(r[ap]);
            if (!g.found_existing) g.value_ptr.* = r[av];
        } else if (std.mem.eql(u8, r[aa], "doc")) {
            const g = try doc.getOrPut(r[ap]);
            if (!g.found_existing) g.value_ptr.* = r[av];
        } else if (std.mem.eql(u8, r[aa], "mod")) {
            const g = try mod.getOrPut(r[ap]);
            if (!g.found_existing) g.value_ptr.* = r[av];
        } else if (std.mem.eql(u8, r[aa], "errmember")) {
            const g = try errm.getOrPut(r[ap]);
            g.value_ptr.* = if (!g.found_existing) r[av] else try std.fmt.allocPrint(a, "{s}, {s}", .{ g.value_ptr.*, r[av] });
        }
    }
    const np = nodes.col("path");
    const nk = nodes.col("kind");
    const nn = nodes.col("name");
    const nv = nodes.col("vis");
    const out = try a.alloc(Node, nodes.rows.len);
    for (nodes.rows, 0..) |r, k| out[k] = .{
        .path = r[np],
        .kind = r[nk],
        .name = r[nn],
        .vis = r[nv],
        .sig = sig.get(r[np]) orelse "",
        .doc = doc.get(r[np]) orelse "",
        .mod = mod.get(r[np]) orelse "",
        .errmembers = errm.get(r[np]) orelse "",
    };
    return .{ .nodes = out, .redirects = try redirect.Redirects.build(a, nodes, edges) };
}

const Scored = struct { node: Node, rank: u8, priv: bool, plen: usize };

fn cmdFind(c: Ctx, out: *std.Io.Writer, map: Map, terms_raw: []const []const u8, limit: usize) !Outcome {
    if (terms_raw.len == 0) {
        try out.writeAll("usage: zephem map find <terms...>\n");
        return .usage;
    }
    const a = c.a;
    const terms = try a.alloc([]const u8, terms_raw.len);
    for (terms_raw, 0..) |t, i| terms[i] = try lower(a, t);

    var aka = try redirect.Aka.init(&map.redirects);
    var hits: std.ArrayList(Scored) = .empty;
    var npriv: usize = 0;
    for (map.nodes) |n| {
        // The alternative names are only worth computing for a node the direct fields missed.
        const direct = allIn(terms, &.{ n.path, n.name, n.sig, n.doc });
        const alt: []const u8 = if (direct) "" else try aka.of(n.path);
        if (!direct and !allIn(terms, &.{ n.path, n.name, n.sig, n.doc, alt })) continue;
        const rank: u8 = if (allIn(terms, &.{n.name})) 0 else if (allIn(terms, &.{n.path}) or allIn(terms, &.{alt})) 1 else 2;
        const priv = std.mem.eql(u8, n.vis, "priv");
        if (priv) npriv += 1;
        try hits.append(a, .{ .node = n, .rank = rank, .priv = priv, .plen = n.path.len });
    }
    if (hits.items.len == 0) {
        try argv.diag(c, "no map entry matches: {s}\n", .{try std.mem.join(a, " ", terms_raw)});
        return .miss;
    }
    std.mem.sort(Scored, hits.items, {}, lessThan);
    const shown = @min(limit, hits.items.len);
    const query = try std.mem.join(a, " ", terms_raw);
    if (npriv > 0) {
        try out.print("# map find: {s}  (top {d} of {d} hits · {d} private, tagged [priv])\n\n", .{ query, shown, hits.items.len, npriv });
    } else {
        try out.print("# map find: {s}  (top {d} of {d} hits)\n\n", .{ query, shown, hits.items.len });
    }
    for (hits.items[0..shown]) |h| {
        const tag: []const u8 = if (h.priv) "  [priv]" else "";
        try out.print("  {s}  ({s}){s}\n", .{ h.node.path, h.node.kind, tag });
        const alt = try aka.of(h.node.path);
        if (alt.len > 0) try out.print("      ≡ {s}\n", .{trunc(c.a, alt, 160)});
        if (h.node.sig.len > 0) {
            const parts = sigfmt.split(c.a, h.node.sig);
            try out.print("      {s}\n", .{parts.sig});
            if (parts.doc.len > 0) try out.print("      ⌁ (params) {s}\n", .{trunc(c.a, parts.doc, 120)});
        }
        if (h.node.doc.len > 0) try out.print("      ⌁ {s}\n", .{trunc(c.a, h.node.doc, 120)});
    }
    return .hit;
}

fn cmdShow(c: Ctx, out: *std.Io.Writer, map: Map, prefix_in: []const u8) !Outcome {
    if (prefix_in.len == 0) {
        try out.writeAll("usage: zephem map show <path>\n");
        return .usage;
    }
    // `std.ArrayList.foo`-style input: reroute through the redirecting prefix.
    const prefix = if (map.redirects.exists.contains(prefix_in)) prefix_in else (try map.redirects.rewrite(prefix_in)) orelse prefix_in;
    if (prefix.ptr != prefix_in.ptr) try out.print("# {s} is {s}\n", .{ prefix_in, prefix });
    const nodes = map.nodes;
    var pub_n: usize = 0;
    var priv_n: usize = 0;
    for (nodes) |n| {
        if (underPrefix(n.path, prefix)) {
            if (std.mem.eql(u8, n.vis, "pub")) pub_n += 1 else priv_n += 1;
        }
    }
    if (pub_n + priv_n == 0) {
        try argv.diag(c, "nothing under {s}\n", .{prefix});
        try suggest(c, map, prefix);
        return .miss;
    }
    try out.print("# map show {s}  ({d} decls: {d} pub · {d} priv)\n\n", .{ prefix, pub_n + priv_n, pub_n, priv_n });
    if (pub_n > 0) {
        try out.print("## public ({d})\n", .{pub_n});
        for (nodes) |n| {
            if (underPrefix(n.path, prefix) and std.mem.eql(u8, n.vis, "pub")) try out.print("  {s}  {s}\n", .{ n.path, n.kind });
        }
    }
    if (priv_n > 0) {
        try out.print("\n## private ({d}) — not callable at these paths from outside their source file\n", .{priv_n});
        for (nodes) |n| {
            if (underPrefix(n.path, prefix) and !std.mem.eql(u8, n.vis, "pub")) try out.print("  {s}  {s}\n", .{ n.path, n.kind });
        }
    }
    // A name with nothing under it that aliases or delegates to something else (`std.ArrayList`
    // → `std.array_list.Aligned()`): its members live at the target, so list them there.
    if (pub_n + priv_n == 1) {
        if (try map.redirects.resolve(prefix)) |res| {
            try out.print("\n", .{});
            try printHops(out, prefix, res.hops);
            if (!std.mem.eql(u8, res.members, prefix)) return cmdShow(c, out, map, res.members);
        }
    }
    return .hit;
}

fn printHops(out: *std.Io.Writer, from: []const u8, hops: []const redirect.Hop) !void {
    try out.print("  {s}", .{from});
    for (hops) |h| try out.print(" ─{s}→ {s}", .{ if (std.mem.eql(u8, h.kind, "alias")) "alias" else "delegates", h.target });
    try out.writeAll("\n\n");
}

fn cmdDoc(c: Ctx, out: *std.Io.Writer, map: Map, path_in: []const u8) !Outcome {
    const a = c.a;
    if (path_in.len == 0) {
        try out.writeAll("usage: zephem map doc <path>\n");
        return .usage;
    }
    // `std.ArrayList.append` is how people write it; the member lives at
    // `std.array_list.Aligned().append`. Follow the recorded edges and say so.
    const path = if (map.redirects.exists.contains(path_in)) path_in else (try map.redirects.rewrite(path_in)) orelse path_in;
    if (path.ptr != path_in.ptr) try out.print("# {s} is {s}\n\n", .{ path_in, path });
    for (map.nodes) |n| {
        if (!std.mem.eql(u8, n.path, path)) continue;
        const tag: []const u8 = if (std.mem.eql(u8, n.vis, "priv")) "  [priv]" else "";
        try out.print("{s}  ({s}){s}\n", .{ n.path, n.kind, tag });
        if (n.mod.len > 0) try out.print("  ⟨{s}⟩\n", .{n.mod});
        if (n.sig.len > 0) {
            const parts = sigfmt.split(a, n.sig);
            try out.print("  {s}\n", .{parts.sig});
            if (parts.doc.len > 0) try out.print("  ⌁ (params) {s}\n", .{parts.doc});
        }
        if (n.errmembers.len > 0) try out.print("  errors: {s}\n", .{n.errmembers});
        if (n.doc.len > 0) try out.print("\n  {s}\n", .{n.doc});
        if (try map.redirects.resolve(n.path)) |res| {
            try out.writeAll("\n");
            try printHops(out, n.path, res.hops);
            try out.print("  members: zephem map show {s}\n", .{n.path});
        }
        if (std.mem.eql(u8, n.vis, "priv")) try out.writeAll("\n  ⚠ private decl — not accessible as this path from outside its source file.\n");
        try out.writeAll("\n(from the zephem map — the source of truth; if it's stale, regenerate the map)\n");
        return .hit;
    }
    try argv.diag(c, "{s} not in the map\n", .{path});
    try suggest(c, map, path);
    return .miss;
}

/// On a miss, name the paths the caller most likely meant — to stderr, so stdout stays empty
/// and the exit code still says "miss". Two sources, both exact facts about the map: the same
/// path in a different case (`std.fmt.parseint`), and decls whose last segment matches
/// case-insensitively (`std.parseInt` → `std.fmt.parseInt`). Public decls only.
fn suggest(c: Ctx, map: Map, path: []const u8) !void {
    const a = c.a;
    const want = try lower(a, path);
    const last = want[if (std.mem.findScalarLast(u8, want, '.')) |d| d + 1 else 0..];
    var same_case: std.ArrayList([]const u8) = .empty;
    var same_name: std.ArrayList([]const u8) = .empty;
    for (map.nodes) |n| {
        if (!std.mem.eql(u8, n.vis, "pub")) continue;
        if (n.path.len == want.len and ciContains(n.path, want)) {
            try same_case.append(a, n.path);
        } else if (n.name.len == last.len and ciContains(n.name, last)) {
            try same_name.append(a, n.path);
        }
    }
    const picks = if (same_case.items.len > 0) same_case.items else same_name.items;
    if (picks.len == 0) return;
    // Closest first: most leading segments shared with what was typed, then the exact spelling
    // of the last segment (`copy` before `COPY`), then the shorter path.
    const ctx: Near = .{ .query = path, .last = path[path.len - last.len ..] };
    std.mem.sort([]const u8, picks, ctx, Near.lessThan);
    const shown = @min(picks.len, 5);
    try argv.diag(c, "  did you mean: {s}{s}\n", .{
        try std.mem.join(a, ", ", picks[0..shown]),
        if (picks.len > shown) try std.fmt.allocPrint(a, " (+{d} more — `zephem map find {s}`)", .{ picks.len - shown, last }) else "",
    });
}

const Near = struct {
    query: []const u8,
    last: []const u8,

    fn shared(q: []const u8, p: []const u8) usize {
        var n: usize = 0;
        var qi = std.mem.splitScalar(u8, q, '.');
        var pi = std.mem.splitScalar(u8, p, '.');
        while (qi.next()) |x| {
            const y = pi.next() orelse break;
            if (!std.mem.eql(u8, x, y)) break;
            n += 1;
        }
        return n;
    }

    fn exact(self: Near, p: []const u8) bool {
        return std.mem.endsWith(u8, p, self.last);
    }

    fn lessThan(self: Near, x: []const u8, y: []const u8) bool {
        const sx = shared(self.query, x);
        const sy = shared(self.query, y);
        if (sx != sy) return sx > sy;
        const ex = self.exact(x);
        if (ex != self.exact(y)) return ex;
        if (x.len != y.len) return x.len < y.len;
        return std.mem.order(u8, x, y) == .lt;
    }
};

// ── helpers ──────────────────────────────────────────────────────────────────

fn lessThan(_: void, a: Scored, b: Scored) bool {
    if (a.priv != b.priv) return !a.priv; // public before private at every tier (see zlook)
    if (a.rank != b.rank) return a.rank < b.rank;
    return a.plen < b.plen;
}

fn underPrefix(path: []const u8, prefix: []const u8) bool {
    if (std.mem.eql(u8, path, prefix)) return true;
    return path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '.';
}

/// Every term appears (case-insensitive) in at least one of `fields`.
fn allIn(terms: []const []const u8, fields: []const []const u8) bool {
    for (terms) |t| {
        var found = false;
        for (fields) |f| {
            if (ciContains(f, t)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Case-insensitive substring (needle pre-lowercased).
fn ciContains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and lo(hay[i + j]) == needle[j]) j += 1;
        if (j == needle.len) return true;
    }
    return false;
}

fn lo(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
fn lower(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const d = try a.alloc(u8, s.len);
    for (s, 0..) |c, i| d[i] = lo(c);
    return d;
}
/// Cut on a CODEPOINT boundary and MARK the cut. An unmarked raw byte slice let a partial
/// value read as a complete one, and could split a multibyte character. See zlook.truncField.
fn trunc(a: std.mem.Allocator, s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(a, "{s}…", .{s[0..end]}) catch s[0..end];
}
