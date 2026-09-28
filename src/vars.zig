// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! vars.zig — the ONE per-repo config surface: where the repo, the datasets, and the baked
//! lookup live, with env overrides. No hardcoded install paths; the repo root self-locates by
//! walking up for the `build.zig.zon` marker (cwd stays fixed, so a relative root is enough).
//!
//! Precedence everywhere: explicit env override → derived-from-repo-root default.
//!   $ZEPHEM_HOME   → repo root                (else: walk up for build.zig.zon)
//!   $ZEPHEM_DATA   → the datasets dir         (else: <repo>/data/std)
//!   $ZEPHEM_LOOKUP → the baked lookup table    (else: <repo>/data/lookup.tsv, git-ignored)
//!
//! Nothing zephem generates lives outside the repo: delete the checkout and it is all gone.
const std = @import("std");
const builtin = @import("builtin");
const Ctx = @import("ctx.zig").Ctx;

pub const Error = error{RepoRootNotFound};

/// The repo root. `$ZEPHEM_HOME` wins. Otherwise walk up from cwd for `build.zig.zon`, but
/// only accept a directory that is actually a zephem checkout (it has `data/std/PINNED`):
/// every Zig project has a `build.zig.zon`, and running zephem from inside another project
/// used to adopt THAT project as the root. Failing that, use the checkout this binary was
/// built in (`<repo>/zig-out/bin/zephem`), so zephem works from any directory.
pub fn repoRoot(c: Ctx) ![]const u8 {
    if (c.getEnv("ZEPHEM_HOME")) |h| return h;
    var level: usize = 0;
    while (level < 12) : (level += 1) {
        const prefix = try repeatDotDot(c.a, level);
        const marker = try std.fs.path.join(c.a, &.{ prefix, "build.zig.zon" });
        if (std.Io.Dir.cwd().access(c.io, marker, .{})) |_| {
            const root = if (level == 0) "." else prefix;
            if (isCheckout(c, root)) return root;
        } else |_| {}
    }
    if (exeRoot(c)) |root| return root;
    return Error.RepoRootNotFound;
}

fn isCheckout(c: Ctx, root: []const u8) bool {
    const pinned = std.fs.path.join(c.a, &.{ root, "data", "std", "PINNED" }) catch return false;
    std.Io.Dir.cwd().access(c.io, pinned, .{}) catch return false;
    return true;
}

fn exeRoot(c: Ctx) ?[]const u8 {
    const self = std.process.executablePathAlloc(c.io, c.a) catch return null;
    const bin = std.fs.path.dirname(self) orelse return null;
    const out = std.fs.path.dirname(bin) orelse return null;
    const root = std.fs.path.dirname(out) orelse return null;
    return if (isCheckout(c, root)) root else null;
}

/// The datasets directory. `$ZEPHEM_DATA` wins; else `<repo>/data/std`.
pub fn dataDir(c: Ctx) ![]const u8 {
    if (c.getEnv("ZEPHEM_DATA")) |d| return d;
    return std.fs.path.join(c.a, &.{ try repoRoot(c), "data", "std" });
}

/// The baked lookup table zlook reads. `$ZEPHEM_LOOKUP` wins; else `<repo>/data/lookup.tsv`.
/// It is derived (about half a second to rebuild with `zephem lookup`), so it is git-ignored,
/// but it lives in the checkout: deleting zephem deletes it.
pub fn lookupPath(c: Ctx) ![]const u8 {
    if (c.getEnv("ZEPHEM_LOOKUP")) |p| return p;
    return std.fs.path.join(c.a, &.{ try repoRoot(c), "data", "lookup.tsv" });
}

/// A file baked next to the lookup table (`examples.tsv`, `lookup.stamp`): same directory,
/// so a `$ZEPHEM_LOOKUP` override moves them together.
pub fn besideLookup(c: Ctx, name: []const u8) ![]const u8 {
    const lp = try lookupPath(c);
    return std.fs.path.join(c.a, &.{ std.fs.path.dirname(lp) orelse ".", name });
}

/// Where the lookup table used to be baked (`~/.config/zephem/lookup.tsv`), before it moved
/// into the repo. Only used to tell the user the old copy can be deleted.
pub fn legacyLookupPath(c: Ctx) ?[]const u8 {
    const home = c.getEnv("HOME") orelse windowsHome(c) orelse return null;
    return std.fs.path.join(c.a, &.{ home, ".config", "zephem", "lookup.tsv" }) catch null;
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
