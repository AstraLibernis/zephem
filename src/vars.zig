//! vars.zig — the ONE per-repo config surface: where the repo, the datasets, and the baked
//! lookup live, with env overrides. No hardcoded install paths; the repo root self-locates by
//! walking up for the `build.zig.zon` marker (cwd stays fixed, so a relative root is enough).
//!
//! Precedence everywhere: explicit env override → derived-from-repo-root default.
//!   $ZEPHEM_HOME   → repo root                (else: walk up for build.zig.zon)
//!   $ZEPHEM_DATA   → the datasets dir         (else: <repo>/data/std)
//!   $ZEPHEM_LOOKUP → the baked lookup table    (else: $HOME/.config/zephem/lookup.tsv)
const std = @import("std");
const builtin = @import("builtin");
const Ctx = @import("ctx.zig").Ctx;

pub const Error = error{RepoRootNotFound};

/// The repo root, as a path usable from the current cwd. `$ZEPHEM_HOME` wins; otherwise walk up
/// from cwd looking for `build.zig.zon`, returning "." / ".." / "../.." as appropriate.
pub fn repoRoot(c: Ctx) ![]const u8 {
    if (c.getEnv("ZEPHEM_HOME")) |h| return h;
    var level: usize = 0;
    while (level < 12) : (level += 1) {
        const prefix = try repeatDotDot(c.a, level);
        const marker = try std.fs.path.join(c.a, &.{ prefix, "build.zig.zon" });
        if (std.Io.Dir.cwd().access(c.io, marker, .{})) |_| {
            return if (level == 0) "." else prefix;
        } else |_| {}
    }
    return Error.RepoRootNotFound;
}

/// The datasets directory. `$ZEPHEM_DATA` wins; else `<repo>/data/std`.
pub fn dataDir(c: Ctx) ![]const u8 {
    if (c.getEnv("ZEPHEM_DATA")) |d| return d;
    return std.fs.path.join(c.a, &.{ try repoRoot(c), "data", "std" });
}

/// The baked lookup table zlook reads. `$ZEPHEM_LOOKUP` wins; else `$HOME/.config/zephem/lookup.tsv`.
/// Windows only: `%USERPROFILE%` stands in for an unset `$HOME`, since Windows doesn't set it.
pub fn lookupPath(c: Ctx) ![]const u8 {
    if (c.getEnv("ZEPHEM_LOOKUP")) |p| return p;
    const home = c.getEnv("HOME") orelse windowsHome(c) orelse ".";
    return std.fs.path.join(c.a, &.{ home, ".config", "zephem", "lookup.tsv" });
}

fn windowsHome(c: Ctx) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    return c.getEnv("USERPROFILE");
}

/// A file under the datasets dir (e.g. `dataFile(c, "extracted/nodes.tsv")`).
pub fn dataFile(c: Ctx, rel: []const u8) ![]const u8 {
    return std.fs.path.join(c.a, &.{ try dataDir(c), rel });
}

/// A file under the repo root (e.g. `repoFile(c, "reflect/resolve.zig")`).
pub fn repoFile(c: Ctx, rel: []const u8) ![]const u8 {
    return std.fs.path.join(c.a, &.{ try repoRoot(c), rel });
}

fn repeatDotDot(a: std.mem.Allocator, level: usize) ![]const u8 {
    if (level == 0) return ".";
    const buf = try a.alloc(u8, level * 3 - 1); // "../" * level, minus the trailing slash
    var i: usize = 0;
    while (i < level) : (i += 1) {
        buf[i * 3] = '.';
        buf[i * 3 + 1] = '.';
        if (i != level - 1) buf[i * 3 + 2] = '/';
    }
    return buf;
}
