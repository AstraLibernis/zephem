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
    // PINNED holds e.g. "zig 0.16.0\n"; keep just the version token.
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const pinned = if (std.mem.startsWith(u8, trimmed, "zig ")) trimmed[4..] else trimmed;
    const live = version(c) catch return null; // can't probe → stay silent
    if (!std.mem.eql(u8, pinned, live)) {
        return try std.fmt.allocPrint(c.a, "⚠ zephem map is pinned to zig {s} but you're on {s} — regenerate: `zephem std && zephem lookup`.", .{ pinned, live });
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
