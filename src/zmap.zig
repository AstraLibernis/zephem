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
const Outcome = @import("query.zig").Outcome;
const toolchain = @import("toolchain.zig");
const rel = @import("relation.zig");

const Node = struct { path: []const u8, kind: []const u8, name: []const u8, vis: []const u8, sig: []const u8, doc: []const u8, mod: []const u8, errmembers: []const u8 };

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
        try out.print("unknown map command: {s}\n\n", .{command});
        try out.writeAll(usage);
        try out.flush();
        return .usage;
    }
    // A missing or unreadable map is NOT a miss. It used to escape as an unhandled Zig error,
    // printing a stack trace and exiting 1 — the code that means "ran fine, nothing matched".
    const nodes = loadMap(c) catch |e| switch (e) {
        error.FileNotFound, error.AccessDenied, error.NotDir => {
            try out.print("zephem: the map is unavailable ({s}) — regenerate it: `zephem std`\n", .{@errorName(e)});
            try out.flush();
            return .unavailable;
        },
        else => return e,
    };
    var outcome: Outcome = .hit;
    if (std.mem.eql(u8, command, "find")) {
        outcome = try cmdFind(c, out, nodes, pos.items, limit);
    } else if (std.mem.eql(u8, command, "show")) {
        outcome = try cmdShow(out, nodes, if (pos.items.len > 0) pos.items[0] else "");
    } else if (std.mem.eql(u8, command, "doc")) {
        outcome = try cmdDoc(out, nodes, if (pos.items.len > 0) pos.items[0] else "");
    }
    try out.flush();
    return outcome;
}

fn loadMap(c: Ctx) ![]Node {
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
    return out;
}

const Scored = struct { node: Node, rank: u8, priv: bool, plen: usize };

fn cmdFind(c: Ctx, out: *std.Io.Writer, nodes: []const Node, terms_raw: []const []const u8, limit: usize) !Outcome {
    if (terms_raw.len == 0) {
        try out.writeAll("usage: zephem map find <terms...>\n");
        return .usage;
    }
    const a = c.a;
    const terms = try a.alloc([]const u8, terms_raw.len);
    for (terms_raw, 0..) |t, i| terms[i] = try lower(a, t);

    var hits: std.ArrayList(Scored) = .empty;
    var npriv: usize = 0;
    for (nodes) |n| {
        if (!allIn(terms, &.{ n.path, n.name, n.sig, n.doc })) continue;
        const rank: u8 = if (allIn(terms, &.{n.name})) 0 else if (allIn(terms, &.{n.path})) 1 else 2;
        const priv = std.mem.eql(u8, n.vis, "priv");
        if (priv) npriv += 1;
        try hits.append(a, .{ .node = n, .rank = rank, .priv = priv, .plen = n.path.len });
    }
    if (hits.items.len == 0) {
        try out.print("no map entry matches: {s}\n", .{try std.mem.join(a, " ", terms_raw)});
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
        if (h.node.sig.len > 0) try out.print("      {s}\n", .{h.node.sig});
        if (h.node.doc.len > 0) try out.print("      ⌁ {s}\n", .{trunc(c.a, h.node.doc, 120)});
    }
    return .hit;
}

fn cmdShow(out: *std.Io.Writer, nodes: []const Node, prefix: []const u8) !Outcome {
    if (prefix.len == 0) {
        try out.writeAll("usage: zephem map show <path>\n");
        return .usage;
    }
    var pub_n: usize = 0;
    var priv_n: usize = 0;
    for (nodes) |n| {
        if (underPrefix(n.path, prefix)) {
            if (std.mem.eql(u8, n.vis, "pub")) pub_n += 1 else priv_n += 1;
        }
    }
    if (pub_n + priv_n == 0) {
        try out.print("nothing under {s}\n", .{prefix});
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
    return .hit;
}

fn cmdDoc(out: *std.Io.Writer, nodes: []const Node, path: []const u8) !Outcome {
    if (path.len == 0) {
        try out.writeAll("usage: zephem map doc <path>\n");
        return .usage;
    }
    for (nodes) |n| {
        if (!std.mem.eql(u8, n.path, path)) continue;
        const tag: []const u8 = if (std.mem.eql(u8, n.vis, "priv")) "  [priv]" else "";
        try out.print("{s}  ({s}){s}\n", .{ n.path, n.kind, tag });
        if (n.mod.len > 0) try out.print("  ⟨{s}⟩\n", .{n.mod});
        if (n.sig.len > 0) try out.print("  {s}\n", .{n.sig});
        if (n.errmembers.len > 0) try out.print("  errors: {s}\n", .{n.errmembers});
        if (n.doc.len > 0) try out.print("\n  {s}\n", .{n.doc});
        if (std.mem.eql(u8, n.vis, "priv")) try out.writeAll("\n  ⚠ private decl — not accessible as this path from outside its source file.\n");
        try out.writeAll("\n(from the zephem map — the source of truth; if it's stale, regenerate the map)\n");
        return .hit;
    }
    try out.print("{s} not in the map\n", .{path});
    return .miss;
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn lessThan(_: void, a: Scored, b: Scored) bool {
    if (a.rank != b.rank) return a.rank < b.rank;
    if (a.priv != b.priv) return !a.priv;
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
