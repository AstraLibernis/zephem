// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Host-OS independence: the same Zig must produce the same map rows whether zephem runs on
//! Linux or Windows. Each fix is tested with a Linux-shaped input (must stay unchanged) and the
//! Windows-shaped one (must normalize to the Linux result).
const std = @import("std");
const tc = @import("zephem").toolchain;
const depth = @import("zephem").depth;

test "normReason: Linux error lines normalize as before" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const sd = "/home/dev/.local/zig-0.17.1/lib/std";
    const rf = ".zig-cache/zephem-depth/scratch/r-8.zig";
    try std.testing.expectEqualStrings(
        "std/lang.zig:1165:29: error: disabled due to miscompilations",
        depth.normReason(a, "/home/dev/.local/zig-0.17.1/lib/std/lang.zig:1165:29: error: disabled due to miscompilations", sd, rf),
    );
    try std.testing.expectEqualStrings(
        "<gen>: error: 'State' is not marked 'pub'",
        depth.normReason(a, ".zig-cache/zephem-depth/scratch/r-8.zig:37:55: error: 'State' is not marked 'pub'", sd, rf),
    );
}

test "normReason: Windows error lines give the Linux rows; the message is untouched" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const sd = "C:\\Users\\me\\.local\\zig-0.17.1\\lib\\std";
    const rf = ".zig-cache\\zephem-depth\\scratch/r-8.zig"; // joined native, then `/r-N.zig` appended
    try std.testing.expectEqualStrings(
        "std/Build/Cache.zig:12:3: error: expected '\\n'",
        depth.normReason(a, "C:\\Users\\me\\.local\\zig-0.17.1\\lib\\std\\Build\\Cache.zig:12:3: error: expected '\\n'", sd, rf),
    );
    try std.testing.expectEqualStrings(
        "<gen>: error: 'State' is not marked 'pub'",
        depth.normReason(a, ".zig-cache\\zephem-depth\\scratch\\r-8.zig:37:55: error: 'State' is not marked 'pub'", sd, rf),
    );
}

test "scanField reads plain `zig env` fields (Linux-style paths, no escapes)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const zon =
        \\.{
        \\    .zig_exe = "/home/dev/.local/zig-0.17.1/zig",
        \\    .std_dir = "/home/dev/.local/zig-0.17.1/lib/std",
        \\    .version = "0.17.1",
        \\    .target = "x86_64-linux.6.12...6.12-gnu.2.41",
        \\}
    ;
    try std.testing.expectEqualStrings("/home/dev/.local/zig-0.17.1/lib/std", (try tc.scanField(a, zon, "std_dir")).?);
    try std.testing.expectEqualStrings("0.17.1", (try tc.scanField(a, zon, "version")).?);
    try std.testing.expectEqualStrings("x86_64-linux.6.12...6.12-gnu.2.41", (try tc.scanField(a, zon, "target")).?);
    try std.testing.expect((try tc.scanField(a, zon, "missing")) == null);
}

test "scanField decodes ZON escapes (Windows `zig env` paths)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // A multiline literal is raw: the ZON below holds `\\` and `\"` exactly as `zig env` prints them.
    const zon =
        \\.{
        \\    .std_dir = "C:\\Users\\me\\zig\\lib\\std",
        \\    .odd = "say \"hi\"",
        \\}
    ;
    try std.testing.expectEqualStrings("C:\\Users\\me\\zig\\lib\\std", (try tc.scanField(a, zon, "std_dir")).?);
    try std.testing.expectEqualStrings("say \"hi\"", (try tc.scanField(a, zon, "odd")).?);
}

test "scanField: an unterminated value is absent, not a crash" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expect((try tc.scanField(ar.allocator(), ".{ .std_dir = \"C:\\\\x", "std_dir")) == null);
}
