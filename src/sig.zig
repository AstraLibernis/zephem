//! Separate `///` parameter-doc prose from a signature, at display time.
//!
//! Zig permits a doc comment INSIDE a parameter list, and the map records signatures as
//! written — so 68 of 11,273 signatures carry prose mid-signature, every one containing a
//! comma, and commas are how a consumer counts parameters (`std.Io.Threaded.init` takes two;
//! counting through its prose gives three — a real downstream false positive, zcanon B16).
//!
//! A first splitter shipped and was REVERTED for mangling signatures. This one implements the
//! rule an adversarial audit derived and validated at 68/68 against ground truth taken from
//! the compiler's own source (and proved a no-op on the 11,205 unaffected signatures):
//!
//!   On `///` at depth d, advance to the first `:` at depth d that (a) is not followed by
//!   `//` — a URL scheme — and (b) has no further `///` before its segment ends (next `,` at
//!   depth d, or the close of depth d). From that `:`, back over whitespace, the identifier,
//!   and any `comptime`/`noalias` qualifiers. Everything from the `///` to that point is
//!   prose; the identifier onward is the parameter.
//!
//! Each clause answers one failure of the reverted version: (a) kills the
//! `https://learn.microsoft.com` case, (b) skips colons inside the prose itself
//! ("...the following functions:"), and the qualifier walk-back rescues
//! `comptime asking_build_zig: type`, which the naive rule truncated to `asking_build_zig`.
//!
//! The prose is RETURNED, not dropped: for 39 of the 68 rows the `doc` column is empty and
//! this is the only copy. The TSV itself is untouched — the on-disk contract still says `sig`
//! may carry `///` (see lookup.zig); this module is how a renderer honours it.
const std = @import("std");

pub const Split = struct {
    sig: []const u8,
    /// The extracted parameter prose, space-joined; empty when the signature was clean.
    doc: []const u8,
};

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn isQualifier(word: []const u8) bool {
    return std.mem.eql(u8, word, "comptime") or std.mem.eql(u8, word, "noalias");
}

/// Walk back from the accepted `:` over whitespace, the parameter name, then any qualifiers.
fn paramStart(s: []const u8, colon: usize) ?usize {
    var e = colon;
    while (e > 0 and s[e - 1] == ' ') e -= 1;
    var st = e;
    while (st > 0 and isIdent(s[st - 1])) st -= 1;
    if (st == e) return null; // no identifier before the colon — not a parameter
    while (true) {
        var p = st;
        while (p > 0 and s[p - 1] == ' ') p -= 1;
        var q = p;
        while (q > 0 and isIdent(s[q - 1])) q -= 1;
        if (q < p and isQualifier(s[q..p])) st = q else break;
    }
    return st;
}

/// From the `///` at `doc_start` (bracket depth `d`), find where the documented parameter
/// begins. Null when no qualifying colon exists — the caller then leaves the text alone.
fn findParamStart(s: []const u8, doc_start: usize, d: usize) ?usize {
    var dep = d;
    var k = doc_start + 3;
    while (k < s.len) : (k += 1) {
        const ch = s[k];
        if (ch == ':' and dep == d and !(k + 2 < s.len and s[k + 1] == '/' and s[k + 2] == '/')) {
            // Segment end: the next `,` at depth d, or the close that drops below d.
            var dep2 = dep;
            var m = k + 1;
            var end = s.len;
            while (m < s.len) : (m += 1) {
                switch (s[m]) {
                    '(', '[', '{' => dep2 += 1,
                    ')', ']', '}' => {
                        if (dep2 == d) {
                            end = m;
                            break;
                        }
                        dep2 -= 1;
                    },
                    ',' => if (dep2 == d) {
                        end = m;
                        break;
                    },
                    else => {},
                }
            }
            if (std.mem.find(u8, s[k..end], "///") == null) return paramStart(s, k);
        }
        switch (ch) {
            '(', '[', '{' => dep += 1,
            ')', ']', '}' => dep -|= 1,
            else => {},
        }
    }
    return null;
}

/// Collapse whitespace runs to single spaces (map signatures are already single-line; the
/// deletions can leave doubled spaces behind).
fn collapse(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_ws = false;
    for (std.mem.trim(u8, s, " \t")) |ch| {
        if (ch == ' ' or ch == '\t') {
            in_ws = true;
            continue;
        }
        if (in_ws and out.items.len > 0) try out.append(a, ' ');
        in_ws = false;
        try out.append(a, ch);
    }
    return out.items;
}

/// Fast path: a signature with no `///` is returned untouched — by construction, the other
/// 11,205 signatures cannot be altered.
pub fn split(a: std.mem.Allocator, sig: []const u8) Split {
    if (std.mem.find(u8, sig, "///") == null) return .{ .sig = sig, .doc = "" };
    return splitSlow(a, sig) catch .{ .sig = sig, .doc = "" };
}

fn splitSlow(a: std.mem.Allocator, sig: []const u8) !Split {
    var out: std.ArrayList(u8) = .empty;
    var prose: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < sig.len) {
        if (i + 2 < sig.len and sig[i] == '/' and sig[i + 1] == '/' and sig[i + 2] == '/') {
            if (findParamStart(sig, i, depth)) |ps| {
                if (prose.items.len > 0) try prose.append(a, ' ');
                // The deleted span may hold several `///` runs; keep the words, drop the markers.
                var run = std.mem.tokenizeAny(u8, sig[i..ps], " \t");
                while (run.next()) |w| {
                    if (std.mem.eql(u8, w, "///")) continue;
                    if (prose.items.len > 0) try prose.append(a, ' ');
                    try prose.appendSlice(a, std.mem.trimStart(u8, w, "/"));
                }
                i = ps;
                continue;
            }
        }
        switch (sig[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            else => {},
        }
        try out.append(a, sig[i]);
        i += 1;
    }
    return .{
        .sig = try collapse(a, out.items),
        .doc = try collapse(a, prose.items),
    };
}
