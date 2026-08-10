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
//! ~/.config/zephem/lookup.tsv). The map is the sole source of std truth; if its PINNED
//! zig differs from yours, regenerate zephem then `query/build_lookup.nu` — never guess.
const std = @import("std");
const Io = std.Io;
const Ctx = @import("ctx.zig").Ctx;
const vars = @import("vars.zig");
const Outcome = @import("query.zig").Outcome;
const V = @Vector(32, u8);

// lookup.tsv columns (built by query/build_lookup.nu), tab-separated:
//   0 path · 1 depth · 2 kind · 3 name · 4 n_children · 5 detail
//   6 sig  · 7 doc   · 8 rkind · 9 rdetail · 10 canon
//   11 ftype · 12 fval · 13 delegate · 14 vis
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
    if (a.rank != b.rank) return a.rank < b.rank;
    if (a.priv != b.priv) return !a.priv; // public before private, at the same match tier
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

/// True when `s` opens a brace group that `max` bytes would cut into — an error set or a
/// struct/enum body, where a truncated rendering is not merely shorter but WRONG: it reads as
/// a complete, smaller set.
fn wouldCutGroup(s: []const u8, max: usize) bool {
    if (s.len <= max) return false;
    const open = std.mem.findScalar(u8, s, '{') orelse return false;
    return open < max;
}

/// Render a resolved type. A brace group is emitted WHOLE — its completeness is the entire
/// point of recording it — with the member count stated so a long one is still readable at a
/// glance. Anything else truncates normally.
fn renderResolved(a: std.mem.Allocator, s: []const u8) []const u8 {
    if (!wouldCutGroup(s, 140)) return truncField(a, s, 140);
    var members: usize = 1;
    for (s) |ch| {
        if (ch == ',') members += 1;
    }
    return std.fmt.allocPrint(a, "{s}   [{d} members, shown in full]", .{ s, members }) catch s;
}

pub fn run(c: Ctx, args: []const []const u8, out: *Io.Writer) !Outcome {
    const a = c.a;
    const io = c.io;

    // ---- args: terms + --limit N ----
    var terms_raw: std.ArrayList([]const u8) = .empty;
    var limit: usize = 12;
    var ai: usize = 0;
    while (ai < args.len) : (ai += 1) {
        const arg = args[ai];
        if ((std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-l")) and ai + 1 < args.len) {
            ai += 1;
            limit = std.fmt.parseInt(usize, args[ai], 10) catch limit;
        } else {
            try terms_raw.append(a, arg);
        }
    }
    if (terms_raw.items.len == 0) {
        try out.print("usage: zlook <term...> [--limit N]   keyword search over the zephem lookup table\n", .{});
        try out.flush();
        return .usage;
    }
    // lowercase the terms once (the haystack is matched case-insensitively in place).
    const terms = try a.alloc([]const u8, terms_raw.items.len);
    for (terms_raw.items, 0..) |t, i| {
        const d = try a.alloc(u8, t.len);
        for (t, 0..) |ch, k| d[k] = lo(ch);
        terms[i] = d;
    }

    // ---- locate lookup.tsv: $ZEPHEM_LOOKUP, else ~/.config/zephem/lookup.tsv ----
    const path = try vars.lookupPath(c);

    const buf = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch {
        try out.print("zlook: no lookup table at {s}\n  build it: run `zephem lookup` from the zephem repo (needs zephem's data/std)\n", .{path});
        try out.flush();
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
        const rank: u8 = if (allContain(name, terms)) 0 else if (allContain(p, terms)) 1 else 2;
        const priv = std.mem.eql(u8, field(line, COL_VIS), "priv");
        if (priv) npriv += 1;
        try hits.append(a, .{ .line = line, .rank = rank, .priv = priv, .plen = p.len });
    }
    if (total == 0) {
        try out.print("no lookup entry matches: {s}\n", .{try std.mem.join(a, " ", terms_raw.items)});
        try out.flush();
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
        const mod = field(h.line, COL_MOD);
        if (mod.len > 0) try out.print("      ⟨{s}⟩\n", .{mod});
        const sig = field(h.line, COL_SIG);
        const res = field(h.line, COL_RDETAIL);
        const doc = field(h.line, COL_DOC);
        const ftype = field(h.line, COL_FTYPE);
        const fval = field(h.line, COL_FVAL);
        const del = field(h.line, COL_DELEGATE);
        if (sig.len > 0) try out.print("      {s}\n", .{sig});
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
    try out.print("\n(from the zephem map — the source of truth; if stale, regenerate zephem)\n", .{});
    try out.flush();
    return .hit;
}
