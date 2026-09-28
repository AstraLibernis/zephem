// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! manifest.zig — SHA256 + `sha256sum -c`-compatible manifests. The Zig replacement for
//! Nushell's `hash sha256` and the `check-manifest`/`write-manifest` dance (`scripts/lib.nu`).
//!
//! A manifest line is `<64-hex>  <path>\n` (TWO spaces — the coreutils format), so the files
//! stay verifiable with `sha256sum -c` outside zephem.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const hex_len = 64;

pub fn sha256Hex(bytes: []const u8) [hex_len]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn sha256File(io: std.Io, a: std.mem.Allocator, path: []const u8) ![hex_len]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    return sha256Hex(bytes);
}

pub const Entry = struct { path: []const u8, hex: [hex_len]u8 };

/// Write a manifest for `entries` to `out_path`.
pub fn writeManifest(io: std.Io, entries: []const Entry, out_path: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var fw = f.writer(io, &buf);
    const w = &fw.interface;
    for (entries) |e| try w.print("{s}  {s}\n", .{ e.hex, e.path });
    try w.flush();
}

/// One parsed manifest row.
pub const Record = struct { hex: []const u8, path: []const u8 };

/// Parse a manifest's bytes into `<hex, path>` records (splitting on the two-space separator;
/// tolerant of a single space too). Slices point into `bytes`.
pub fn parse(a: std.mem.Allocator, bytes: []const u8) ![]const Record {
    var out: std.ArrayList(Record) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const sp = std.mem.findScalar(u8, line, ' ') orelse continue;
        const hex = line[0..sp];
        var rest = line[sp..];
        rest = std.mem.trimStart(u8, rest, " ");
        try out.append(a, .{ .hex = hex, .path = rest });
    }
    return out.toOwnedSlice(a);
}

/// The hex recorded for `path` in a parsed manifest, or null.
pub fn hexFor(records: []const Record, path: []const u8) ?[]const u8 {
    for (records) |r| if (std.mem.eql(u8, r.path, path)) return r.hex;
    return null;
}
