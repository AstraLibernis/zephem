// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! toolchain.zig — the external dependency on the Zig compiler itself. Locates the active std
//! and the compiler version by parsing `zig env` (ZON). This is the one place that may fail
//! loudly with NO fake default: if `zig env` can't run or lacks `.std_dir`, that is a hard
//! error, not a guessed `/usr/lib/zig` fallback.
const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const proc = @import("proc.zig");

pub const Error = error{ ZigEnvFailed, StdDirMissing, VersionMissing };

pub const Env = struct {
    zig_exe: []const u8,
    std_dir: []const u8,
    version: []const u8,
    target: []const u8, // the resolved host triple (e.g. x86_64-linux…gnu.2.43) — the reflect layer is target-scoped
};

/// The zig executable to invoke (`$ZIG` override, else `zig` off PATH).
pub fn zigExe(c: Ctx) []const u8 {
    return c.getEnv("ZIG") orelse "zig";
}

/// Run `zig env` and pull `.zig_exe` / `.std_dir` / `.version` out of its ZON.
pub fn probe(c: Ctx) !Env {
    const out = try proc.capture(c.a, c.io, &.{ zigExe(c), "env" });
    if (out.exit_code != 0) return Error.ZigEnvFailed;
    return .{
        .zig_exe = scanField(out.stdout, "zig_exe") orelse zigExe(c),
        .std_dir = scanField(out.stdout, "std_dir") orelse return Error.StdDirMissing,
        .version = scanField(out.stdout, "version") orelse return Error.VersionMissing,
        .target = scanField(out.stdout, "target") orelse "",
    };
}

/// The active toolchain's std root file — `<std_dir>/std.zig`. Fails loudly (no fake default).
pub fn stdRoot(c: Ctx) ![]const u8 {
    const env = try probe(c);
    return std.fs.path.join(c.a, &.{ env.std_dir, "std.zig" });
}

/// The installed Zig version string (e.g. "0.16.0").
pub fn version(c: Ctx) ![]const u8 {
    return (try probe(c)).version;
}

/// A human warning if the datasets' `PINNED` zig differs from the installed zig (or is missing),
/// else null. The map is the sole source of truth — a mismatch means "regenerate", never "guess".
pub fn staleness(c: Ctx, data_dir: []const u8) !?[]const u8 {
    const pinned_path = try std.fs.path.join(c.a, &.{ data_dir, "PINNED" });
    const raw = std.Io.Dir.cwd().readFileAlloc(c.io, pinned_path, c.a, .unlimited) catch {
        return try std.fmt.allocPrint(c.a, "⚠ zephem map at {s} has no PINNED stamp — regenerate with `zephem std`.", .{data_dir});
    };
    // PINNED holds two lines: `zig <ver>` then `target <triple>` (older stamps have only the first).
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, raw, "\n"), '\n');
    const l0 = std.mem.trim(u8, lines.next() orelse "", " \t\r");
    const l1 = std.mem.trim(u8, lines.next() orelse "", " \t\r");
    const pinned_ver = if (std.mem.startsWith(u8, l0, "zig ")) l0[4..] else l0;
    const pinned_target = if (std.mem.startsWith(u8, l1, "target ")) l1[7..] else "";
    const live = probe(c) catch return null; // can't probe → stay silent
    if (!std.mem.eql(u8, pinned_ver, live.version)) {
        return try std.fmt.allocPrint(c.a, "⚠ zephem map is pinned to zig {s} but you're on {s} — regenerate: `zephem std && zephem lookup`.", .{ pinned_ver, live.version });
    }
    if (pinned_target.len != 0 and !std.mem.eql(u8, pinned_target, live.target)) {
        return try std.fmt.allocPrint(c.a, "⚠ zephem map was reflected for target {s} but you're on {s} — resolved/poison rows are target-scoped; regenerate: `zephem std && zephem depth --commit`.", .{ pinned_target, live.target });
    }
    return null;
}

/// Read the value of a `.<key> = "<value>"` field out of ZON text; null if absent.
fn scanField(text: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, ".{s} = \"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    const start = at + needle.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return null;
    return text[start..end];
}
