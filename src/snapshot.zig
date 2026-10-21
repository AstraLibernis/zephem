// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! snapshot.zig — `zephem snapshot`: freeze the live map (`data/std/`) into
//! `data/versions/<zig-version>/`, one complete, committed folder per Zig version.
//!
//! `data/std/` is always the map of the Zig on PATH and is overwritten by every regeneration,
//! so on its own it answers "what is std now" but never "what changed". The version folders
//! keep every snapshot side by side, each made by the current extractor with that Zig
//! (`ZIG=<that zig>`; see docs/release-diff.md for regenerating them all after an extractor
//! change), so two versions can be compared directly (`diff -r`, or `zephem diff`).
//!
//! A snapshot is only taken from a map that proves itself: every manifest in `data/std/`
//! (SHA256SUMS for the core, SHA256SUMS.depth for the reflection sweep, SHA256SUMS.<overlay>
//! for each overlay) must match the files on disk, otherwise the folder would mix a fresh core
//! with stale derivatives. `--check` compares the frozen folder for the current version against
//! the live map and fails on drift, so `zig build check` keeps the committed snapshot honest.
const std = @import("std");
const argv = @import("args.zig");
const Ctx = @import("ctx.zig").Ctx;
const vars = @import("vars.zig");
const manifest = @import("manifest.zig");
const util = @import("util.zig");

pub const Error = error{ NoPinned, ManifestMismatch, SnapshotMissing, SnapshotDrift };

/// A file that belongs to a snapshot: its path relative to the data dir (`extracted/nodes.tsv`).
pub const File = struct { rel: []const u8 };

/// `zig 0.17.0` (the first line of PINNED) → `0.17.0`.
pub fn versionFromPinned(pinned: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, pinned, '\n');
    const first = std.mem.trim(u8, lines.first(), " \r\t");
    if (!std.mem.startsWith(u8, first, "zig ")) return null;
    const v = std.mem.trim(u8, first["zig ".len..], " ");
    return if (v.len == 0) null else v;
}

/// Every manifest file in `dir`: `SHA256SUMS` and `SHA256SUMS.<name>`, sorted by name.
pub fn manifestNames(c: Ctx, dir: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var d = try std.Io.Dir.cwd().openDir(c.io, dir, .{ .iterate = true });
    defer d.close(c.io);
    var it = d.iterate();
    while (try it.next(c.io)) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.startsWith(u8, e.name, "SHA256SUMS")) continue;
        try out.append(c.a, try c.a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return out.items;
}

/// The files a snapshot of `dir` consists of: PINNED, every manifest, and every file a
/// manifest lists — after proving each listed file's digest matches its manifest. The map's
/// own `--check` modes prove the files REBUILD identically; this proves the folder is
/// internally consistent right now, which is what a frozen copy must be.
pub fn verifiedFiles(c: Ctx, dir: []const u8, report: *std.Io.Writer) ![]const File {
    var files: std.ArrayList(File) = .empty;
    try files.append(c.a, .{ .rel = "PINNED" });
    std.Io.Dir.cwd().access(c.io, try util.join(c.a, dir, "PINNED"), .{}) catch return error.NoPinned;

    var ok = true;
    const mans = try manifestNames(c, dir);
    for (mans) |man| try files.append(c.a, .{ .rel = man });
    for (mans) |man| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(c.io, try util.join(c.a, dir, man), c.a, .unlimited);
        for (try manifest.parse(c.a, bytes)) |rec| {
            const got = manifest.sha256File(c.io, c.a, try util.join(c.a, dir, rec.path)) catch {
                try report.print("  ✗ {s}: {s} listed but unreadable\n", .{ man, rec.path });
                ok = false;
                continue;
            };
            if (!std.mem.eql(u8, &got, rec.hex)) {
                try report.print("  ✗ {s}: {s} on disk differs from its manifest — regenerate that stage first\n", .{ man, rec.path });
                ok = false;
                continue;
            }
            // A later stage's manifest also lists the manifests it was derived from; those are
            // already in the list.
            const seen = for (files.items) |f| {
                if (std.mem.eql(u8, f.rel, rec.path)) break true;
            } else false;
            if (!seen) try files.append(c.a, .{ .rel = try c.a.dupe(u8, rec.path) });
        }
    }
    if (!ok) return error.ManifestMismatch;
    return files.items;
}

/// `<repo>/data/versions`.
pub fn versionsDir(c: Ctx) ![]const u8 {
    return std.fs.path.join(c.a, &.{ try vars.repoRoot(c), "data", "versions" });
}

/// `<repo>/data/versions/<version>`; `live` names the live map instead.
pub fn versionDir(c: Ctx, version: []const u8) ![]const u8 {
    if (std.mem.eql(u8, version, "live")) return vars.dataDir(c);
    return std.fs.path.join(c.a, &.{ try versionsDir(c), version });
}

/// Copy the verified files of `src_dir` into `dst_dir`, creating folders as needed.
pub fn freeze(c: Ctx, src_dir: []const u8, dst_dir: []const u8, files: []const File) !void {
    for (files) |f| {
        const from = try util.join(c.a, src_dir, f.rel);
        const to = try util.join(c.a, dst_dir, f.rel);
        if (std.fs.path.dirname(to)) |parent| try std.Io.Dir.cwd().createDirPath(c.io, parent);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(c.io, from, c.a, .unlimited);
        try util.writeFile(c.io, to, bytes);
    }
}

/// Does the frozen folder hold exactly the live files? Reports every difference; returns the
/// count of files that differ or are missing.
pub fn compare(c: Ctx, live_dir: []const u8, frozen_dir: []const u8, files: []const File, report: *std.Io.Writer) !usize {
    var bad: usize = 0;
    for (files) |f| {
        const want = manifest.sha256File(c.io, c.a, try util.join(c.a, live_dir, f.rel)) catch {
            try report.print("  ✗ {s}: unreadable in the live map\n", .{f.rel});
            bad += 1;
            continue;
        };
        const got = manifest.sha256File(c.io, c.a, try util.join(c.a, frozen_dir, f.rel)) catch {
            try report.print("  ✗ {s}: missing from the snapshot\n", .{f.rel});
            bad += 1;
            continue;
        };
        if (!std.mem.eql(u8, &want, &got)) {
            try report.print("  ✗ {s}: snapshot differs from the live map\n", .{f.rel});
            bad += 1;
        }
    }
    return bad;
}

pub fn run(c: Ctx, args: []const []const u8) !void {
    const usage =
        \\usage: zephem snapshot [--check]
        \\
        \\  freeze the live map (data/std/) into data/versions/<zig-version>/, after proving every
        \\  manifest in it matches the files on disk. The version is read from data/std/PINNED.
        \\  --check   compare the frozen folder for that version with the live map; exit 1 on drift
        \\
    ;
    if (try argv.helpRequested(c, args, usage)) return;
    var check = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) check = true else argv.reject(c, arg, usage);
    }

    var ow = std.Io.File.stdout().writerStreaming(c.io, try c.a.alloc(u8, 4096));
    const w = &ow.interface;
    defer w.flush() catch {}; // zsnag:ok — progress report only; a defer cannot return the error

    const live = try vars.dataDir(c);
    const pinned = std.Io.Dir.cwd().readFileAlloc(c.io, try util.join(c.a, live, "PINNED"), c.a, .unlimited) catch {
        try w.print("[snapshot] no PINNED in {s} — run `zephem std` first\n", .{live});
        try w.flush();
        std.process.exit(1);
    };
    const version = versionFromPinned(pinned) orelse {
        try w.print("[snapshot] PINNED in {s} does not start with `zig <version>`\n", .{live});
        try w.flush();
        std.process.exit(1);
    };
    const frozen = try versionDir(c, version);

    const files = verifiedFiles(c, live, w) catch |e| switch (e) {
        error.ManifestMismatch => {
            try w.print("[snapshot] ✗ the live map is not internally consistent; nothing frozen\n", .{});
            try w.flush();
            std.process.exit(1);
        },
        else => return e,
    };

    if (check) {
        std.Io.Dir.cwd().access(c.io, frozen, .{}) catch {
            try w.print("[snapshot check] ✗ no snapshot for zig {s} at {s} — run `zephem snapshot`\n", .{ version, frozen });
            try w.flush();
            std.process.exit(1);
        };
        const bad = try compare(c, live, frozen, files, w);
        if (bad == 0) {
            try w.print("[snapshot check] ✓ data/versions/{s} matches the live map ({d} files)\n", .{ version, files.len });
        } else {
            try w.print("[snapshot check] ✗ data/versions/{s}: {d} file(s) differ — run `zephem snapshot`\n", .{ version, bad });
            try w.flush();
            std.process.exit(1);
        }
        return;
    }

    try freeze(c, live, frozen, files);
    try w.print("[snapshot] zig {s}: {d} files → data/versions/{s}/  (all manifests verified)\n", .{ version, files.len, version });
}
