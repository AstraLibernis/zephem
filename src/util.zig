// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! util.zig — small shared helpers that were duplicated across the src/ layer: path joins, raw
//! file writes, substring replace, and the naive dotted-path parent/leaf.
const std = @import("std");

/// Join a directory and a relative subpath (the one-line wrapper reimplemented ~7×).
pub fn join(a: std.mem.Allocator, dir: []const u8, sub: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ dir, sub });
}

/// Write raw bytes to `path`, creating/truncating it.
pub fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [1 << 16]u8 = undefined;
    var fw = f.writer(io, &buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}

/// Replace every occurrence of `needle` with `with` (returns `hay` unchanged when absent).
pub fn replaceAll(a: std.mem.Allocator, hay: []const u8, needle: []const u8, with: []const u8) ![]const u8 {
    if (needle.len == 0) return hay;
    const count = std.mem.count(u8, hay, needle);
    if (count == 0) return hay;
    const out = try a.alloc(u8, hay.len - needle.len * count + with.len * count);
    _ = std.mem.replace(u8, hay, needle, with, out);
    return out;
}

/// The NAIVE dotted parent — everything before the last `.`. Intentionally DISTINCT from
/// `parse.parent` (which is quote-aware and drops a `()` factory suffix): this one matches the
/// grouping the derived overlays and the depth kids-map were built on. They agree on all real std
/// paths (no index container has a `.` inside `@"…"`), but don't "fix" one into the other — they
/// answer different questions (Nushell-parity grouping vs the tree's true parent).
pub fn dottedParent(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '.')) |k| path[0..k] else "";
}

/// The last dotted segment (the leaf name), paired with `dottedParent`.
pub fn lastSeg(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '.')) |k| path[k + 1 ..] else path;
}

/// A ✓ / ✗ marker for the reproducibility `--check` reports.
pub fn mark(ok: bool) []const u8 {
    return if (ok) "✓" else "✗ DRIFT";
}
