// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! toolchain.zig — the external dependency on the Zig compiler itself. Locates the active std
//! and the compiler version by parsing `zig env` (ZON). This is the one place that may fail
//! loudly with NO fake default: if `zig env` can't run or lacks `.std_dir`, that is a hard
//! error, not a guessed `/usr/lib/zig` fallback.
const std = @import("std");
const builtin = @import("builtin");
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
    return probeWith(c, zigExe(c));
}

/// `probe` for one named executable.
pub fn probeWith(c: Ctx, exe: []const u8) !Env {
    const out = try proc.capture(c.a, c.io, &.{ exe, "env" });
    if (out.exit_code != 0) return Error.ZigEnvFailed;
    return .{
        .zig_exe = try scanField(c.a, out.stdout, "zig_exe") orelse exe,
        .std_dir = try scanField(c.a, out.stdout, "std_dir") orelse return Error.StdDirMissing,
        .version = try scanField(c.a, out.stdout, "version") orelse return Error.VersionMissing,
        .target = try scanField(c.a, out.stdout, "target") orelse "",
    };
}

/// The active toolchain's std root file — `<std_dir>/std.zig`. Fails loudly (no fake default).
pub fn stdRoot(c: Ctx) ![]const u8 {
    const env = try probe(c);
    return std.Io.Dir.path.join(c.a, &.{ env.std_dir, "std.zig" });
}

/// The installed Zig version string (e.g. "0.16.0").
pub fn version(c: Ctx) ![]const u8 {
    return (try probe(c)).version;
}

/// A human warning if the datasets' `PINNED` zig differs from the installed zig (or is missing),
/// else null. The map is the sole source of truth — a mismatch means "regenerate", never "guess".
pub fn staleness(c: Ctx, data_dir: []const u8) !?[]const u8 {
    return pinnedWarning(c, data_dir, .fresh);
}

/// `staleness` for read-only queries (`map`, `look`): the `zig env` answer it needs (version and
/// target) is cached beside the lookup table, keyed by the zig binary's identity and the host
/// (see `Live.cached`), so a query does not pay a process spawn. Regeneration paths keep
/// calling `staleness`, which always probes.
pub fn stalenessCached(c: Ctx, data_dir: []const u8, cache_path: []const u8) !?[]const u8 {
    return pinnedWarning(c, data_dir, .{ .cached = cache_path });
}

const LiveFrom = union(enum) { fresh, cached: []const u8 };

fn pinnedWarning(c: Ctx, data_dir: []const u8, from: LiveFrom) !?[]const u8 {
    const pinned_path = try std.Io.Dir.path.join(c.a, &.{ data_dir, "PINNED" });
    const raw = std.Io.Dir.cwd().readFileAlloc(c.io, pinned_path, c.a, .unlimited) catch {
        return try c.a.print("⚠ zephem map at {s} has no PINNED stamp — regenerate with `zephem std`.", .{data_dir});
    };
    // PINNED holds two lines: `zig <ver>` then `target <triple>` (older stamps have only the first).
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, raw, "\n"), '\n');
    const l0 = std.mem.trim(u8, lines.next() orelse "", " \t\r");
    const l1 = std.mem.trim(u8, lines.next() orelse "", " \t\r");
    const pinned_ver = if (std.mem.startsWith(u8, l0, "zig ")) l0[4..] else l0;
    const pinned_target = if (std.mem.startsWith(u8, l1, "target ")) l1[7..] else "";
    const live: Live = switch (from) {
        .fresh => Live.of(probe(c) catch return null), // can't probe → stay silent
        .cached => |p| Live.cached(c, p) orelse return null,
    };
    if (!std.mem.eql(u8, pinned_ver, live.version)) {
        return try c.a.print("⚠ zephem map is pinned to zig {s} but you're on {s} — regenerate: `zephem std && zephem lookup`.", .{ pinned_ver, live.version });
    }
    if (pinned_target.len != 0 and !std.mem.eql(u8, pinned_target, live.target)) {
        return try c.a.print("⚠ zephem map was reflected for target {s} but you're on {s} — resolved/poison rows are target-scoped; regenerate: `zephem std && zephem depth --commit`.", .{ pinned_target, live.target });
    }
    return null;
}

/// What staleness needs from `zig env`.
pub const Live = struct {
    version: []const u8,
    target: []const u8,

    fn of(e: Env) Live {
        return .{ .version = e.version, .target = e.target };
    }

    /// Version and target of the zig a query would run, from the cache at `path` when its key
    /// matches, else from `zig env` (then stored). The key is the binary (resolved path, size,
    /// mtime; see `resolveZig`) plus the host triple std detects in-process, so a new zig, a
    /// retargeted junction or symlink, an OS or libc upgrade all miss. Null when `zig env`
    /// cannot run.
    pub fn cached(c: Ctx, path: []const u8) ?Live {
        const exe = resolveZig(c) orelse return of(probe(c) catch return null);
        const host = hostTriple(c) orelse return of(probe(c) catch return null);
        if (std.Io.Dir.cwd().readFileAlloc(c.io, path, c.a, .limited(16 * 1024))) |text| {
            if (matchCache(text, exe, host)) |hit| return hit;
        } else |_| {}
        const live = of(probeWith(c, exe.path) catch return null);
        storeCache(c, path, exe, host, live);
        return live;
    }
};

/// The host triple as std detects it in-process: part of the cache key only, never the answer
/// (that stays `zig env`'s).
fn hostTriple(c: Ctx) ?[]const u8 {
    const t = std.zig.system.resolveTargetQuery(c.io, .{}) catch return null;
    return t.zigTriple(c.a) catch null;
}

pub const Exe = struct { path: []const u8, size: u64, mtime: i96 };

/// The executable `probe` would run, found the way `std.process.spawn` finds it: `$ZIG` as a
/// path when it has a separator, else the name (`$ZIG` or `zig`) searched on Windows in the
/// working directory and then PATH with PATHEXT, on POSIX along PATH skipping entries it cannot
/// execute. Links and junctions resolved. Null when nothing is found or the match is ambiguous
/// (a `.bat`/`.cmd` that the spawn could pick instead): the caller then probes uncached.
pub fn resolveZig(c: Ctx) ?Exe {
    const name = zigExe(c);
    if (std.mem.findAny(u8, name, if (builtin.os.tag == .windows) "/\\" else "/") != null)
        return identify(c, name);
    if (builtin.os.tag == .windows) {
        if (!std.mem.eql(u8, name, "zig")) return null; // only the default name is searched here
        if (inDir(c, ".")) |hit| return hit.exe;
    }
    const path_var = c.getEnv("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path_var, std.Io.Dir.path.delimiter);
    while (it.next()) |dir| {
        if (builtin.os.tag == .windows) {
            if (inDir(c, dir)) |hit| return hit.exe;
        } else {
            const p = std.Io.Dir.path.join(c.a, &.{ dir, name }) catch return null;
            std.Io.Dir.cwd().access(c.io, p, .{ .execute = true }) catch continue;
            return identify(c, p);
        }
    }
    return null;
}

/// A directory's answer: none (keep searching), or final (null = do not cache).
const Hit = struct { exe: ?Exe };

fn inDir(c: Ctx, dir: []const u8) ?Hit {
    const names = [_][]const u8{ "zig", "zig.com", "zig.exe", "zig.bat", "zig.cmd" };
    var found_exe = false;
    var found_other = false;
    for (names) |n| {
        const p = std.Io.Dir.path.join(c.a, &.{ dir, n }) catch return .{ .exe = null };
        const st = std.Io.Dir.cwd().statFile(c.io, p, .{}) catch continue;
        if (st.kind != .file) continue;
        if (std.mem.eql(u8, n, "zig.exe")) found_exe = true else found_other = true;
    }
    if (!found_exe and !found_other) return null;
    if (found_other) return .{ .exe = null };
    return .{ .exe = identify(c, std.Io.Dir.path.join(c.a, &.{ dir, "zig.exe" }) catch return .{ .exe = null }) };
}

fn identify(c: Ctx, p: []const u8) ?Exe {
    const real = std.Io.Dir.cwd().realPathFileAlloc(c.io, p, c.a) catch return null;
    const st = std.Io.Dir.cwd().statFile(c.io, real, .{}) catch return null;
    if (st.kind != .file) return null;
    return .{ .path = real, .size = st.size, .mtime = st.mtime.nanoseconds };
}

/// One line: `<exe path>\t<size>\t<mtime ns>\t<host triple>\t<version>\t<target>`.
pub fn renderCache(a: std.mem.Allocator, exe: Exe, host: []const u8, live: Live) ![]u8 {
    return a.print("{s}\t{d}\t{d}\t{s}\t{s}\t{s}\n", .{ exe.path, exe.size, exe.mtime, host, live.version, live.target });
}

/// The cached answer when the line's key is exactly (`exe`, `host`); null otherwise.
pub fn matchCache(text: []const u8, exe: Exe, host: []const u8) ?Live {
    const line = std.mem.trimEnd(u8, text, "\r\n");
    var f = std.mem.splitScalar(u8, line, '\t');
    const path = f.next() orelse return null;
    const size = std.fmt.parseInt(u64, f.next() orelse return null, 10) catch return null;
    const mtime = std.fmt.parseInt(i96, f.next() orelse return null, 10) catch return null;
    const h = f.next() orelse return null;
    const ver = f.next() orelse return null;
    const target = f.next() orelse return null;
    if (f.next() != null or !cacheable(ver) or !cacheable(target) or ver.len == 0) return null;
    if (!std.mem.eql(u8, path, exe.path) or size != exe.size or mtime != exe.mtime) return null;
    if (!std.mem.eql(u8, h, host)) return null;
    return .{ .version = ver, .target = target };
}

/// No tab, newline or other control byte: the value round-trips through one cache line.
fn cacheable(s: []const u8) bool {
    for (s) |ch| if (ch < ' ' or ch == 0x7f) return false;
    return true;
}

/// Best effort: a failed write only costs the next query a spawn. Temp file + rename, so
/// concurrent queries never interleave into one file.
fn storeCache(c: Ctx, path: []const u8, exe: Exe, host: []const u8, live: Live) void {
    if (live.version.len == 0 or !cacheable(live.version) or !cacheable(live.target) or !cacheable(host)) return;
    if (std.mem.findScalar(u8, exe.path, '\t') != null) return;
    const text = renderCache(c.a, exe, host, live) catch return;
    const now = std.Io.Timestamp.now(c.io, .awake).nanoseconds;
    const tmp = c.a.print("{s}.{d}.tmp", .{ path, now }) catch return;
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(c.io, .{ .sub_path = tmp, .data = text }) catch return;
    cwd.rename(tmp, cwd, path, c.io) catch {
        cwd.deleteFile(c.io, tmp) catch {}; // zsnag:ok — best-effort cleanup of our own temp file
    };
}

/// Read the value of a `.<key> = "<value>"` field out of ZON text, with its string escapes
/// decoded (Windows paths arrive as `C:\\Users\\…`); null if absent. Caller frees (arena).
pub fn scanField(a: std.mem.Allocator, text: []const u8, key: []const u8) error{ OutOfMemory, ZigEnvFailed }!?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.mem.print(&needle_buf, ".{s} = \"", .{key}) catch return null;
    const at = std.mem.find(u8, text, needle) orelse return null;
    const start = at + needle.len - 1; // keep the opening quote: parseAlloc takes the literal
    var i = start + 1;
    while (i < text.len and text[i] != '"') : (i += 1) {
        if (text[i] == '\\') i += 1; // skip the escaped char, so `\"` doesn't end the literal
    }
    if (i >= text.len) return null;
    return std.zig.string_literal.parseAlloc(a, text[start .. i + 1]) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidLiteral => error.ZigEnvFailed,
    };
}
