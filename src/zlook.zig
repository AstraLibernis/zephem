// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! zlook.zig — the `look` subcommand: fast structured lookup over the denormalized zephem "lookup"
//! table. In-process now (folded from the standalone `query/zlook.zig`); the SIMD search is
//! unchanged, only the entry moved to `run(c, args, out)` writing to a caller-supplied writer.
//!
//! The discovery half of zephem's query layer: keyword search over the WHOLE mapped std
//! in one shot — name · path · as-written signature · `///` doc · resolved type/error-set
//! · canonical alias — all pre-joined into one row per decl by `query/build_lookup.nu`.
//! Every term must appear (case-insensitive, AND) somewhere in the row; matches are
//! ranked name-first and the parsed columns are printed, not the raw line.
//!
//!   zlook parse int                decls whose row contains BOTH "parse" and "int"
//!   zlook "constant time"          a multi-word term is just two terms here
//!   zlook OutOfMemory              finds fns by RESOLVED behavior (error set), not just name
//!   zlook parse int --limit 20     cap the printed hits (default 12)
//!
//! The first-byte scan is SIMD (`@Vector(32, u8)` → AVX2 `vpcmpeqb`), so it greps the
//! ~2 MB table in single-digit ms. Reads `$ZEPHEM_LOOKUP` (default
//! data/lookup.tsv). The map is the sole source of std truth; if its PINNED
//! zig differs from yours, regenerate zephem then `query/build_lookup.nu` — never guess.
const std = @import("std");
const Io = std.Io;
const Ctx = @import("ctx.zig").Ctx;
const vars = @import("vars.zig");
const argv = @import("args.zig");
const sigfmt = @import("sig.zig");
const Outcome = @import("query.zig").Outcome;
const V = @Vector(32, u8);

// lookup.tsv columns (built by `zephem lookup`, src/lookup.zig), tab-separated:
//   0 path · 1 depth · 2 kind · 3 name · 4 n_children · 5 detail
//   6 sig  · 7 doc   · 8 rkind · 9 rdetail · 10 canon
//   11 ftype · 12 fval · 13 delegate · 14 vis · 15 mod · 16 aka
const COL_PATH = 0;
const COL_KIND = 2;
const COL_NAME = 3;
const COL_SIG = 6;
const COL_DOC = 7;
const COL_RDETAIL = 9;
const COL_FTYPE = 11; // a field/tag's resolved type (edges[has_type])
const COL_FVAL = 12; // a field default / enum tag value (attrs[value])
const COL_DELEGATE = 13; // a delegating factory's target (edges[delegates])
const COL_VIS = 14; // "pub" | "priv" — a private decl isn't callable at its path from outside its file
const COL_MOD = 15; // extern/export/inline/threadlocal/comptime/var qualifiers (sparse)
const COL_AKA = 16; // other public names reaching this node via alias/delegates (sparse)

inline fn lo(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
inline fn matchAt(hay: []const u8, pos: usize, needle: []const u8) bool {
    var j: usize = 1;
    while (j < needle.len and lo(hay[pos + j]) == needle[j]) j += 1;
    return j == needle.len;
}

/// Case-insensitive substring (needle pre-lowercased). SIMD first-byte scan: load
/// 32 bytes, compare to both cases of needle[0] (vpcmpeqb), verify each hit.
fn ciContains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    const f = needle[0];
    const fu: u8 = if (f >= 'a' and f <= 'z') f - 32 else f;
    const last = hay.len - needle.len;
    const sl: V = @splat(f);
    const su: V = @splat(fu);
    var i: usize = 0;
    while (i + 32 <= hay.len) : (i += 32) {
        const chunk: V = hay[i..][0..32].*;
        const ml: u32 = @bitCast(chunk == sl);
        const mu: u32 = @bitCast(chunk == su);
        var mask: u32 = ml | mu;
        while (mask != 0) {
            const pos = i + @ctz(mask);
            if (pos <= last and matchAt(hay, pos, needle)) return true;
            mask &= mask - 1;
        }
    }
    while (i <= last) : (i += 1) {
        if (lo(hay[i]) == f and matchAt(hay, i, needle)) return true;
    }
    return false;
}

/// Case-insensitive whole-name equality (term pre-lowercased), ignoring a builtin's `@`.
fn exactName(name: []const u8, term: []const u8) bool {
    const n = if (name.len > 0 and name[0] == '@' and (term.len == 0 or term[0] != '@')) name[1..] else name;
    return n.len == term.len and ciContains(n, term);
}

fn allContain(hay: []const u8, terms: []const []const u8) bool {
    for (terms) |t| if (!ciContains(hay, t)) return false;
    return true;
}

/// The Nth tab-separated field of a row (or "" if absent).
fn field(line: []const u8, n: usize) []const u8 {
    var it = std.mem.splitScalar(u8, line, '\t');
    var i: usize = 0;
    while (it.next()) |f| : (i += 1) if (i == n) return f;
    return "";
}

const Hit = struct { line: []const u8, rank: u8, priv: bool, plen: usize };

fn lessThan(_: void, a: Hit, b: Hit) bool {
    // Public before private at EVERY tier: a private helper whose name happens to contain the
    // terms is not callable from outside its file, so it must not outrank real API.
    if (a.priv != b.priv) return !a.priv;
    if (a.rank != b.rank) return a.rank < b.rank;
    return a.plen < b.plen;
}

/// Cut `s` to at most `max` bytes on a CODEPOINT boundary, marking the cut with `…`.
///
/// The old form was `if (s.len > max) s[0..max] else s` — an unmarked raw byte slice. Two
/// problems, one live and one latent. Live: 797 entries have a resolved type past the 140-byte
/// cut, and the reader had no way to know. `std.Build.RunError` displayed 10 of its 41 error
/// members, ending mid-identifier with no closing brace, looking for all the world like a
/// complete error set. For a map whose whole claim is to be the source of std truth with no
/// live-lookup fallback, showing a third of an error set unmarked is the worst failure it has.
/// Latent: a raw byte slice can split a multibyte character in half.
///
/// Prefer `truncBalanced` for anything brace-delimited — see below.
fn truncField(a: std.mem.Allocator, s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1; // back off continuation bytes
    return std.fmt.allocPrint(a, "{s}…", .{s[0..end]}) catch s[0..end];
}

/// The first BALANCED brace group in `s`, or null. Returns the span including the braces.
///
/// The earlier version only checked that a `{` appeared before the cut, which was wrong twice
/// over: it fired on 75 groups that closed well inside the limit and were never at risk, and it
/// MISSED 53 error sets whose `{` happened to sit past byte 140 behind a long parameter list.
/// Two identical error sets got opposite treatment based only on how long the prefix was.
fn braceGroup(s: []const u8) ?struct { start: usize, end: usize } {
    const open = std.mem.findScalar(u8, s, '{') orelse return null;
    var depth: usize = 0;
    var i = open;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '{', '(', '[' => depth += 1,
            '}', ')', ']' => {
                depth -= 1;
                if (depth == 0) return .{ .start = open, .end = i + 1 };
            },
            else => {},
        }
    }
    return null; // unbalanced
}

/// Members of a balanced group: TOP-LEVEL commas only, and an empty group has none.
///
/// The earlier version counted every comma in the WHOLE string, so it swept up the function's
/// own parameter commas and any nested group's — wrong on 293 of the 445 rows it annotated.
/// `std.crypto.tls.Client.init` and `std.crypto.tls.Client.InitError` are the SAME error set,
/// and it printed them on adjacent lines as "49 members" and "47 members". Stating a confident
/// wrong number under the words "shown in full" is worse than the unmarked cut it replaced.
fn countMembers(group: []const u8) usize {
    const inner = std.mem.trim(u8, group[1 .. group.len - 1], " ");
    if (inner.len == 0) return 0;
    var depth: usize = 0;
    var n: usize = 1;
    var trailing = true;
    for (inner) |ch| {
        switch (ch) {
            '{', '(', '[' => depth += 1,
            '}', ')', ']' => depth -|= 1,
            ',' => if (depth == 0) {
                n += 1;
                trailing = true;
            },
            ' ', '\t' => {},
            else => trailing = false,
        }
    }
    return if (trailing) n - 1 else n; // a trailing comma is not a member
}

/// Render a resolved type for a SEARCH result: compact, because an agent reads every line.
///
/// An error set longer than the cut is FOLDED to its true member count — `error{…30 members}`
/// — with the text around it kept, so the shape of the type stays readable. Folding is marked
/// and counted, never silent, and `zephem map doc <path>` prints the set in full. (It used to be
/// emitted whole here: the top hit for `look read file` alone was a 30-member line, and twelve
/// hits ran to ~5 KB.) Anything else over the cut truncates, marked.
fn renderResolved(a: std.mem.Allocator, s: []const u8) []const u8 {
    if (s.len <= 140) return s;
    const g = braceGroup(s) orelse return truncField(a, s, 140);
    // Only an error set folds to a member count. A comptime struct literal of hash constants is
    // not a set of "members" and must not be annotated as one.
    const is_error_set = g.start >= 5 and std.mem.eql(u8, s[g.start - 5 .. g.start], "error");
    if (!is_error_set) return truncField(a, s, 140);
    const folded = std.fmt.allocPrint(a, "{s}{{…{d} members}}{s}", .{ s[0..g.start], countMembers(s[g.start..g.end]), s[g.end..] }) catch return s;
    return truncField(a, folded, 160);
}

/// A task-shaped query (`print stdout`) often names things no SINGLE declaration mentions
/// together: `Writer.print` and `File.stdout` are two decls. When the AND of all terms finds
/// nothing, name the best public hits for each term alone — to stderr, so stdout stays empty
/// and the exit code still says "miss". Still exact matching; nothing is guessed.
fn perTerm(c: Ctx, buf: []const u8, terms: []const []const u8, raw: []const []const u8) !void {
    const a = c.a;
    try argv.diag(c, "  no single declaration mentions every term; the closest for each term alone:\n", .{});
    for (terms, raw) |t, shown| {
        var best: std.ArrayList(Hit) = .empty;
        var it = std.mem.splitScalar(u8, buf, '\n');
        _ = it.next(); // header
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const name = field(line, COL_NAME);
            if (!ciContains(name, t)) continue; // name hits only: a doc mention is too weak here
            if (std.mem.eql(u8, field(line, COL_VIS), "priv")) continue;
            const rank: u8 = if (name.len == t.len) 0 else 1; // exact name first
            try best.append(a, .{ .line = line, .rank = rank, .priv = false, .plen = field(line, COL_PATH).len });
        }
        std.mem.sort(Hit, best.items, {}, lessThan);
        var names: std.ArrayList(u8) = .empty;
        for (best.items[0..@min(4, best.items.len)], 0..) |h, i| {
            if (i > 0) try names.appendSlice(a, ", ");
            try names.appendSlice(a, field(h.line, COL_PATH));
        }
        try argv.diag(c, "    {s:<10} → {s}\n", .{ shown, if (names.items.len > 0) names.items else "(no declaration is named with it)" });
    }
}

pub fn run(c: Ctx, args: []const []const u8, out: *Io.Writer) !Outcome {
    const a = c.a;
    const io = c.io;

    const usage =
        \\usage: zephem look <term...> [--limit N]
        \\
        \\  keyword search over the baked lookup table; every term must match (AND)
        \\
        \\  exit: 0 found · 1 nothing matched · 2 usage · 3 lookup table unavailable
        \\
    ;
    if (try argv.helpRequested(c, args, usage)) return .hit;

    // ---- args: terms + --limit N ----
    var terms_raw: std.ArrayList([]const u8) = .empty;
    var limit: usize = 12;
    var ai: usize = 0;
    while (ai < args.len) : (ai += 1) {
        const arg = args[ai];
        if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-l")) {
            limit = argv.intValue(c, usize, args, &ai, arg, usage);
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            // An unknown flag used to become a SEARCH TERM: `look -h` exited 0 having searched
            // for the literal "-h" and returned 47 unrelated decls.
            argv.reject(c, arg, usage);
        } else if (arg.len == 0) {
            // The empty string matches every row — 63,494 "hits" for a shell-expanded blank.
            argv.reject(c, "<empty term>", usage);
        } else {
            try terms_raw.append(a, arg);
        }
    }
    if (terms_raw.items.len == 0) {
        try argv.diag(c, "{s}", .{usage});
        return .usage;
    }
    // lowercase the terms once (the haystack is matched case-insensitively in place).
    const terms = try a.alloc([]const u8, terms_raw.items.len);
    for (terms_raw.items, 0..) |t, i| {
        const d = try a.alloc(u8, t.len);
        for (t, 0..) |ch, k| d[k] = lo(ch);
        terms[i] = d;
    }

    // ---- locate lookup.tsv: $ZEPHEM_LOOKUP, else <repo>/data/lookup.tsv ----
    const path = try vars.lookupPath(c);

    const buf = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch {
        try argv.diag(c, "zlook: no lookup table at {s}\n  build it: run `zephem lookup` from the zephem repo (needs zephem's data/std)\n", .{path});
        return .unavailable;
    };

    // ---- scan: every term must appear in the row; rank name-first ----
    var hits: std.ArrayList(Hit) = .empty;
    var total: usize = 0;
    var npriv: usize = 0;
    var it = std.mem.splitScalar(u8, buf, '\n');
    _ = it.next(); // header
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (!allContain(line, terms)) continue;
        total += 1;
        const name = field(line, COL_NAME);
        const p = field(line, COL_PATH);
        // A match through an alternative name (`ArrayList append` → `Aligned().append`) is as
        // good as a path match: it is the name the caller would actually write.
        // exact name (`args` → `Args`) · name contains every term · path/alternative name · elsewhere
        const rank: u8 = if (terms.len == 1 and exactName(name, terms[0])) 0 else if (allContain(name, terms)) 1 else if (allContain(p, terms) or allContain(field(line, COL_AKA), terms)) 2 else 3;
        const priv = std.mem.eql(u8, field(line, COL_VIS), "priv");
        if (priv) npriv += 1;
        try hits.append(a, .{ .line = line, .rank = rank, .priv = priv, .plen = p.len });
    }
    if (total == 0) {
        try argv.diag(c, "no lookup entry matches: {s}\n", .{try std.mem.join(a, " ", terms_raw.items)});
        if (terms.len > 1) try perTerm(c, buf, terms, terms_raw.items);
        return .miss;
    }
    std.mem.sort(Hit, hits.items, {}, lessThan);

    const shown = @min(limit, hits.items.len);
    const query = try std.mem.join(a, " ", terms_raw.items);
    if (npriv > 0) {
        // Private decls are demoted (shown last) and tagged, never hidden — they aren't
        // callable at their path from outside their file, so they shouldn't outrank real API.
        try out.print("# zlook: {s}  ({d} shown of {d} hits · {d} private, tagged [priv])\n\n", .{ query, shown, total, npriv });
    } else {
        try out.print("# zlook: {s}  ({d} shown of {d} hits)\n\n", .{ query, shown, total });
    }
    for (hits.items[0..shown]) |h| {
        const vis_tag: []const u8 = if (h.priv) "  [priv]" else "";
        try out.print("  {s}  ({s}){s}\n", .{ field(h.line, COL_PATH), field(h.line, COL_KIND), vis_tag });
        const aka = field(h.line, COL_AKA);
        if (aka.len > 0) try out.print("      ≡ {s}\n", .{truncField(a, aka, 160)});
        const mod = field(h.line, COL_MOD);
        if (mod.len > 0) try out.print("      ⟨{s}⟩\n", .{mod});
        const sig = field(h.line, COL_SIG);
        const res = field(h.line, COL_RDETAIL);
        const doc = field(h.line, COL_DOC);
        const ftype = field(h.line, COL_FTYPE);
        const fval = field(h.line, COL_FVAL);
        const del = field(h.line, COL_DELEGATE);
        if (sig.len > 0) {
            const parts = sigfmt.split(a, sig);
            try out.print("      {s}\n", .{parts.sig});
            if (parts.doc.len > 0) try out.print("      ⌁ (params) {s}\n", .{truncField(a, parts.doc, 120)});
        }
        // a field/tag's payload: `: type = value`, `: type`, or `= value` (bare tag → nothing).
        if (ftype.len > 0 and fval.len > 0) {
            try out.print("      : {s} = {s}\n", .{ ftype, fval });
        } else if (ftype.len > 0) {
            try out.print("      : {s}\n", .{ftype});
        } else if (fval.len > 0) {
            try out.print("      = {s}\n", .{fval});
        }
        if (del.len > 0) try out.print("      ⇒ {s}\n", .{del}); // delegates to
        if (res.len > 0) try out.print("      → {s}\n", .{renderResolved(a, res)});
        if (doc.len > 0) try out.print("      ⌁ {s}\n", .{truncField(a, doc, 120)});
    }
    try out.print("\n(from the zephem map — the source of truth; if stale, regenerate zephem. Full error sets: `zephem map doc <path>`)\n", .{});
    try out.flush();
    return .hit;
}
