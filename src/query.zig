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
