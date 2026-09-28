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
const query = @import("query.zig");
const Outcome = query.Outcome;
const toolchain = @import("toolchain.zig");
const rel = @import("relation.zig");
const redirect = @import("redirect.zig");

const Node = struct { path: []const u8, kind: []const u8, name: []const u8, vis: []const u8, sig: []const u8, doc: []const u8, mod: []const u8, errmembers: []const u8, example: []const u8 = "", arity: []const u8 = "" };
const Map = struct {
    nodes: []const Node,
    redirects: redirect.Redirects,
    /// `test` bodies (TSV-escaped) by the path they are anchored to: a doctest (`test parseInt`)
    /// on its decl, a `test "…"` on its enclosing namespace.
    examples: std.StringHashMap(std.ArrayList([]const u8)),
};

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
        ew.interface.print("{s}\n", .{warn}) catch {}; // zsnag:ok — advisory warning on stderr; failing to print it must not block the query
        ew.interface.flush() catch {}; // zsnag:ok — advisory warning on stderr; failing to print it must not block the query
    }
    const nodes = try rel.load(a, c.io, try std.fs.path.join(a, &.{ dir, "extracted/nodes.tsv" }));
    const attrs = try rel.load(a, c.io, try std.fs.path.join(a, &.{ dir, "extracted/attrs.tsv" }));
    const edges = try redirect.loadEdges(a, c.io, try std.fs.path.join(a, &.{ dir, "extracted/edges.tsv" }));
    var sig = std.StringHashMap([]const u8).init(a);
    var doc = std.StringHashMap([]const u8).init(a);
    var mod = std.StringHashMap([]const u8).init(a);
    var errm = std.StringHashMap([]const u8).init(a); // error-set members, comma-joined per path
    var examples = std.StringHashMap(std.ArrayList([]const u8)).init(a);
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
        } else if (std.mem.eql(u8, r[aa], "example")) {
            const g = try examples.getOrPut(r[ap]);
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(a, r[av]);
        } else if (std.mem.eql(u8, r[aa], "errmember")) {
            const g = try errm.getOrPut(r[ap]);
            g.value_ptr.* = if (!g.found_existing) r[av] else try std.fmt.allocPrint(a, "{s}, {s}", .{ g.value_ptr.*, r[av] });
        }
    }
    const np = nodes.col("path");
    const nk = nodes.col("kind");
    const nn = nodes.col("name");
    const nv = nodes.col("vis");
    const builtins = try rel.load(a, c.io, try std.fs.path.join(a, &.{ dir, "extracted/builtins.tsv" }));
    const out = try a.alloc(Node, nodes.rows.len + builtins.rows.len);
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
    // Builtins join the map as `@name` rows of kind `builtin`, with langref's first example.
    const bn = builtins.col("name");
    const bs = builtins.col("sig");
    const bd = builtins.col("doc");
    const be = builtins.col("example");
    const bp = builtins.col("params");
    for (builtins.rows, nodes.rows.len..) |r, k| out[k] = .{
        .path = r[bn],
        .kind = "builtin",
        .name = r[bn],
        .vis = "pub",
        .sig = r[bs],
        .doc = r[bd],
        .mod = "",
        .errmembers = "",
        .example = r[be],
        .arity = r[bp],
    };
    return .{ .nodes = out, .redirects = try redirect.Redirects.build(a, nodes, edges), .examples = examples };
}

const Scored = struct { node: Node, rank: u8, priv: bool, plen: usize, plat: bool = false };

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
    var nplat: usize = 0;
    for (map.nodes) |n| {
        // The alternative names are only worth computing for a node the direct fields missed.
        const direct = allIn(terms, &.{ n.path, n.name, n.sig, n.doc });
        const alt: []const u8 = if (direct) "" else try aka.of(n.path);
        if (!direct and !allIn(terms, &.{ n.path, n.name, n.sig, n.doc, alt })) continue;
        // exact name · name contains every term · path/alternative name · elsewhere (as `look`)
        const rank: u8 = if (terms.len == 1 and n.name.len == terms[0].len and ciContains(n.name, terms[0])) 0 else if (allIn(terms, &.{n.name})) 1 else if (allIn(terms, &.{n.path}) or allIn(terms, &.{alt})) 2 else 3;
        const priv = std.mem.eql(u8, n.vis, "priv");
        if (priv) npriv += 1;
        const plat = query.platformDemoted(n.path, terms);
        if (plat) nplat += 1;
        try hits.append(a, .{ .node = n, .rank = rank, .priv = priv, .plen = n.path.len, .plat = plat });
    }
    if (hits.items.len == 0) {
        try argv.diag(c, "no map entry matches: {s}\n", .{try std.mem.join(a, " ", terms_raw)});
        return .miss;
    }
    std.mem.sort(Scored, hits.items, {}, lessThan);
    const shown = @min(limit, hits.items.len);
    const q = try std.mem.join(a, " ", terms_raw);
    try out.print("# map find: {s}  (top {d} of {d} hits{s}{s})\n\n", .{
        q, shown, hits.items.len,
        if (npriv > 0) try std.fmt.allocPrint(a, " · {d} private, tagged [priv]", .{npriv}) else "",
        if (nplat > 0) try std.fmt.allocPrint(a, " · {d} in std.c/std.os, ranked after the portable API", .{nplat}) else "",
    });
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
        // The compiler-resolved type, in full — the one place a whole inferred error set shows
        // (`look` folds it to a count).
        if (try resolvedOf(c, n.path)) |res| try out.print("  → {s}\n", .{res});
        if (n.doc.len > 0) try out.print("\n  {s}\n", .{n.doc});
        if (n.example.len > 0) try out.print("\n  example (from the language reference):\n{s}\n", .{try unescapeIndented(a, n.example)});
        if (try exampleFor(a, map, n)) |ex| {
            try out.print("\n  {s}:\n{s}\n", .{ ex.label, try clipLines(a, try unescapeIndented(a, ex.body), 25) });
        }
        if (std.mem.eql(u8, n.kind, "builtin") and n.sig.len == 0) {
            const args = if (std.mem.eql(u8, n.arity, "var")) "a variable number of" else n.arity;
            try out.print("  takes {s} argument(s), per the compiler's builtin table\n\n  (the language reference does not document this builtin)\n", .{args});
        }
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
        const px = query.platformDemoted(x, &.{});
        if (px != query.platformDemoted(y, &.{})) return !px;
        const ex = self.exact(x);
        if (ex != self.exact(y)) return ex;
        if (x.len != y.len) return x.len < y.len;
        return std.mem.order(u8, x, y) == .lt;
    }
};

// ── helpers ──────────────────────────────────────────────────────────────────

fn lessThan(_: void, a: Scored, b: Scored) bool {
    if (a.priv != b.priv) return !a.priv; // public before private at every tier (see zlook)
    if (a.plat != b.plat) return !a.plat; // then portable before std.c/std.os (see query.zig)
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

const Example = struct { label: []const u8, body: []const u8 };

/// Usage harvested from std's own tests — never written by zephem. In order:
///   1. a doctest of this exact decl (`test parseInt {…}` → `std.fmt.parseInt`);
///   2. for a fn, the nearest enclosing namespace's `test` that CALLS it (`name(` after a
///      non-identifier character) — labelled with where it came from, since it is a test that
///      uses the function, not one written for it.
/// The shortest candidate is shown (the most focused), with a count of the rest.
fn exampleFor(a: std.mem.Allocator, map: Map, n: Node) !?Example {
    if (map.examples.get(n.path)) |own| {
        const best = shortest(own.items);
        const more = own.items.len - 1;
        const label = if (more > 0) try std.fmt.allocPrint(a, "example (a std test of this declaration; {d} more in the map)", .{more}) else "example (a std test of this declaration)";
        return .{ .label = label, .body = best };
    }
    if (!std.mem.eql(u8, n.kind, "fn")) return null;
    const call = try std.fmt.allocPrint(a, "{s}(", .{n.name});
    // A same-named call is only this function if its argument count fits the signature: all the
    // parameters, or all but `self` for a method call. `Managed(u32).append(2)` is a different
    // `append` from `Aligned(T).append(gpa, item)` and must not be shown as its usage.
    const params = paramCount(sigfmt.split(a, n.sig).sig) orelse return null;
    var anc = n.path;
    while (std.mem.findScalarLast(u8, anc, '.')) |d| {
        anc = anc[0..d];
        const list = map.examples.get(anc) orelse continue;
        // Prefer tests where EVERY same-named call fits: a test that also calls a different
        // `append` (another type's) shows the reader both and teaches the wrong one first.
        var hits: std.ArrayList([]const u8) = .empty;
        var clean: std.ArrayList([]const u8) = .empty;
        for (list.items) |body| {
            const t = tally(body, call, params);
            if (t.fit == 0) continue;
            try hits.append(a, body);
            if (t.misfit == 0) try clean.append(a, body);
        }
        if (hits.items.len == 0) continue;
        const more = hits.items.len - 1;
        const label = try std.fmt.allocPrint(a, "usage (a std test in {s} that calls {s}{s})", .{
            anc, call, if (more > 0) try std.fmt.allocPrint(a, "; {d} more", .{more}) else "",
        });
        return .{ .label = label, .body = shortest(if (clean.items.len > 0) clean.items else hits.items) };
    }
    return null;
}

/// Calls of `call` (`name(`) in `body` as a whole identifier (`list.append(`, ` append(`, not
/// `prepend(`), split by whether the argument count fits: `params`, or `params - 1` for a
/// method call.
fn tally(body: []const u8, call: []const u8, params: usize) struct { fit: usize, misfit: usize } {
    var fit: usize = 0;
    var misfit: usize = 0;
    var pos: usize = 0;
    while (std.mem.findPos(u8, body, pos, call)) |i| {
        pos = i + 1;
        if (i > 0) {
            const prev = body[i - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '@') continue;
        }
        const args = argCount(body[i + call.len - 1 ..]) orelse continue;
        if (args == params or args + 1 == params) fit += 1 else misfit += 1;
    }
    return .{ .fit = fit, .misfit = misfit };
}

/// Top-level arguments of the call whose `(` starts `s`, skipping string and character
/// literals (a `","` must not count). Null if the parenthesis never closes.
fn argCount(s: []const u8) ?usize {
    var depth: usize = 0;
    var n: usize = 0;
    var seg = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        switch (ch) {
            '"', '\'' => {
                i += 1;
                while (i < s.len and s[i] != ch) : (i += 1) {
                    if (s[i] == '\\') i += 1; // the TSV cell's own escapes pair up the same way
                }
                seg = true;
            },
            '(', '[', '{' => {
                depth += 1;
                if (depth > 1) seg = true;
            },
            ')', ']', '}' => {
                depth -= 1;
                if (depth == 0) return n + @intFromBool(seg);
            },
            ',' => if (depth == 1) {
                if (seg) n += 1;
                seg = false;
            },
            ' ' => {},
            '\\' => i += 1, // an escaped newline/tab inside the TSV cell is whitespace
            else => if (depth == 1) {
                seg = true;
            },
        }
    }
    return null;
}

/// Parameters of a written signature `fn name(a: A, b: B) R` — the same counting, on the sig.
fn paramCount(sig: []const u8) ?usize {
    const open = std.mem.findScalar(u8, sig, '(') orelse return null;
    return argCount(sig[open..]);
}

fn shortest(xs: []const []const u8) []const u8 {
    var best = xs[0];
    for (xs[1..]) |x| if (x.len < best.len) {
        best = x;
    };
    return best;
}

/// At most `max` lines, the cut marked with how much was left out.
fn clipLines(a: std.mem.Allocator, s: []const u8, max: usize) ![]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\n') continue;
        n += 1;
        if (n == max) {
            const rest = std.mem.count(u8, s[i + 1 ..], "\n") + 1;
            return std.fmt.allocPrint(a, "{s}\n    … ({d} more lines)", .{ s[0..i], rest });
        }
    }
    return s;
}

/// The resolved type of `path` from resolved.tsv (the reflection layer), or null. Read on
/// demand: only `map doc` needs it, for one path.
fn resolvedOf(c: Ctx, path: []const u8) !?[]const u8 {
    const dir = try vars.dataDir(c);
    const bytes = std.Io.Dir.cwd().readFileAlloc(c.io, try std.fs.path.join(c.a, &.{ dir, "extracted/resolved.tsv" }), c.a, .unlimited) catch return null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, path) or line.len <= path.len or line[path.len] != '\t') continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        _ = f.next(); // path
        _ = f.next(); // kind
        const detail = f.next() orelse return null;
        return if (detail.len > 0) detail else null;
    }
    return null;
}

/// A TSV-escaped code cell (`\n`, `\t`, `\\`) back to lines, each indented four spaces.
fn unescapeIndented(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "    ");
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                'n' => try out.appendSlice(a, "\n    "),
                't' => try out.append(a, '\t'),
                'r' => {},
                else => try out.append(a, s[i]),
            }
        } else try out.append(a, s[i]);
    }
    return out.items;
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
