// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Outcome of a read-only query, so the dispatcher can set a meaningful exit code.
//!
//! Every query path used to exit 0 — a hit, a miss, a garbage path, and "the lookup table does
//! not exist at all" were indistinguishable to any caller. A consumer could not tell "no
//! results" from "this tool is not working", which for a map that claims to be the sole source
//! of std truth is the difference between an answer and a silent absence of one.
const std = @import("std");

pub const Outcome = enum(u8) {
    /// Found what was asked for.
    hit = 0,
    /// Ran correctly; nothing matched.
    miss = 1,
    /// Bad invocation — unknown subcommand, missing argument.
    usage = 2,
    /// The map or lookup table is absent or unreadable. NOT the same as a miss.
    unavailable = 3,

    pub fn code(o: Outcome) u8 {
        return @intFromEnum(o);
    }
};

/// Is `path` platform-specific binding code the caller did not ask for?
///
/// `std.c.*` (libc and per-OS C bindings) and `std.os.*` (linux, windows, uefi, wasi, …) hold
/// thousands of decls — syscall numbers, ioctl constants, per-OS struct fields — that match
/// ordinary words (`args`, `sleep`, `copy`) and crowd out the portable API. Such hits are
/// ranked after it and counted in the header, never hidden. A query that names the platform
/// (`linux mmap`, `darwin`, `wasi args`) opts back in: a term EQUAL to the segment after
/// `std.os`/`std.c` (`linux` in `std.os.linux.mmap`) keeps its normal rank. Equal, not
/// contained: in `std.c.COPYFILE` that segment is the decl itself, and `copy` must not opt in.
///
/// `terms` are pre-lowercased.
pub fn platformDemoted(path: []const u8, terms: []const []const u8) bool {
    const is_c = std.mem.startsWith(u8, path, "std.c.") or std.mem.eql(u8, path, "std.c");
    const is_os = std.mem.startsWith(u8, path, "std.os.") or std.mem.eql(u8, path, "std.os");
    if (!is_c and !is_os) return false;
    // the platform part: `std.os.linux` / `std.c.darwin` — the first segment after the prefix
    const head_len = if (is_c) "std.c".len else "std.os".len;
    const seg_end = if (path.len > head_len + 1) std.mem.findScalarPos(u8, path, head_len + 1, '.') orelse path.len else path.len;
    const platform = path[0..seg_end];
    const segment = platform[head_len + @intFromBool(platform.len > head_len) ..];
    for (terms) |t| if (std.ascii.eqlIgnoreCase(segment, t)) return false;
    return true;
}

// ── case-insensitive search, shared by `look` and `map` ─────────────────────────

const V = @Vector(32, u8);

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
pub fn ciContains(hay: []const u8, needle: []const u8) bool {
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
pub fn exactName(name: []const u8, term: []const u8) bool {
    const n = if (name.len > 0 and name[0] == '@' and (term.len == 0 or term[0] != '@')) name[1..] else name;
    return n.len == term.len and ciContains(n, term);
}

pub fn allContain(hay: []const u8, terms: []const []const u8) bool {
    for (terms) |t| if (!ciContains(hay, t)) return false;
    return true;
}
