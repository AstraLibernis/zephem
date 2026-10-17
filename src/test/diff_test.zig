// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const diff = @import("zephem").diff;
const snapshot = @import("zephem").snapshot;

const old_nodes =
    "path\tkind\tname\tvis\n" ++
    "std\tns\tstd\tpub\n" ++
    "std.mem\tns\tmem\tpub\n" ++
    "std.mem.eql\tfn\teql\tpub\n" ++
    "std.mem.gone\tfn\tgone\tpub\n" ++
    "std.mem.resized\tfn\tresized\tpub\n" ++
    "std.mem.hidden\tfn\thidden\tpriv\n" ++
    "std.mem.Kind\tconst\tKind\tpub\n";
const old_attrs =
    "path\tattr\tvalue\n" ++
    "std.mem.eql\tsig\tfn eql(comptime T: type, a: []const T, b: []const T) bool\n" ++
    "std.mem.gone\tsig\tfn gone() void\n" ++
    "std.mem.resized\tsig\tfn resized(a: u32) void\n" ++
    "std.mem.eql\tdoc\tCompares two slices\n";
const new_nodes =
    "path\tkind\tname\tvis\n" ++
    "std\tns\tstd\tpub\n" ++
    "std.mem\tns\tmem\tpub\n" ++
    "std.mem.eql\tfn\teql\tpub\n" ++
    "std.mem.resized\tfn\tresized\tpub\n" ++
    "std.mem.hidden\tfn\thidden\tpriv\n" ++
    "std.mem.Kind\tenum\tKind\tpub\n" ++
    "std.mem.fresh\tfn\tfresh\tpub\n" ++
    "std.mem.secret\tfn\tsecret\tpriv\n";
const new_attrs =
    "path\tattr\tvalue\n" ++
    "std.mem.eql\tsig\tfn eql(comptime T: type, a: []const T, b: []const T) bool\n" ++
    "std.mem.resized\tsig\tfn resized(a: u64) void\n" ++
    "std.mem.fresh\tsig\tfn fresh() void\n";

fn sides(a: std.mem.Allocator) !struct { diff.Side, diff.Side } {
    return .{ try diff.loadSideBytes(a, old_nodes, old_attrs), try diff.loadSideBytes(a, new_nodes, new_attrs) };
}

test "compute: added, removed, kind and signature changes; private declarations skipped by default" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sides(a);
    const changes = try diff.compute(a, s[0], s[1], false);

    // Sorted by path; the private `secret` is not reported.
    try std.testing.expectEqual(@as(usize, 4), changes.len);
    try std.testing.expectEqualStrings("std.mem.Kind", changes[0].path);
    try std.testing.expectEqual(diff.What.changed, changes[0].what);
    try std.testing.expectEqualStrings("const", changes[0].old.?.kind);
    try std.testing.expectEqualStrings("enum", changes[0].new.?.kind);

    try std.testing.expectEqualStrings("std.mem.fresh", changes[1].path);
    try std.testing.expectEqual(diff.What.added, changes[1].what);
    try std.testing.expectEqualStrings("fn fresh() void", changes[1].new.?.sig.?);

    try std.testing.expectEqualStrings("std.mem.gone", changes[2].path);
    try std.testing.expectEqual(diff.What.removed, changes[2].what);

    try std.testing.expectEqualStrings("std.mem.resized", changes[3].path);
    try std.testing.expectEqual(diff.What.changed, changes[3].what);
    try std.testing.expectEqualStrings("fn resized(a: u32) void", changes[3].old.?.sig.?);
    try std.testing.expectEqualStrings("fn resized(a: u64) void", changes[3].new.?.sig.?);
}

test "compute: --private includes private additions" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sides(a);
    const changes = try diff.compute(a, s[0], s[1], true);
    try std.testing.expectEqual(@as(usize, 5), changes.len);
    var found = false;
    for (changes) |ch| if (std.mem.eql(u8, ch.path, "std.mem.secret")) {
        found = true;
        try std.testing.expectEqual(diff.What.added, ch.what);
    };
    try std.testing.expect(found);
}

test "module and under" {
    try std.testing.expectEqualStrings("std.mem", diff.module("std.mem.eql"));
    try std.testing.expectEqualStrings("std.mem", diff.module("std.mem"));
    try std.testing.expectEqualStrings("std", diff.module("std"));
    try std.testing.expectEqualStrings("std.Io", diff.module("std.Io.Dir.openDir"));
    try std.testing.expect(diff.under("std.mem.eql", "std.mem"));
    try std.testing.expect(diff.under("std.mem", "std.mem"));
    try std.testing.expect(!diff.under("std.memory", "std.mem"));
}

test "tallies: per module, largest first" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sides(a);
    const ts = try diff.tallies(a, try diff.compute(a, s[0], s[1], false));
    try std.testing.expectEqual(@as(usize, 1), ts.len);
    try std.testing.expectEqualStrings("std.mem", ts[0].module);
    try std.testing.expectEqual(@as(usize, 1), ts[0].added);
    try std.testing.expectEqual(@as(usize, 1), ts[0].removed);
    try std.testing.expectEqual(@as(usize, 2), ts[0].changed);
}

test "report: human form names the removed path and both signatures; tsv has one row per change" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sides(a);
    const changes = try diff.compute(a, s[0], s[1], false);

    var aw: std.Io.Writer.Allocating = .init(a);
    try diff.report(a, &aw.writer, "0.16.0", "0.17.0", changes, .{});
    const text = aw.writer.buffered();
    try std.testing.expect(std.mem.find(u8, text, "1 removed · 2 changed · 1 added") != null);
    try std.testing.expect(std.mem.find(u8, text, "`std.mem.gone`") != null);
    try std.testing.expect(std.mem.find(u8, text, "was: fn resized(a: u32) void") != null);
    try std.testing.expect(std.mem.find(u8, text, "now: fn resized(a: u64) void") != null);
    try std.testing.expect(std.mem.find(u8, text, "kind const → enum") != null);

    var tw: std.Io.Writer.Allocating = .init(a);
    try diff.report(a, &tw.writer, "0.16.0", "0.17.0", changes, .{ .tsv = true });
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, tw.writer.buffered(), "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 5), n); // header + 4 changes

    // Filters: one kind, one prefix.
    var fw: std.Io.Writer.Allocating = .init(a);
    try diff.report(a, &fw.writer, "a", "b", changes, .{ .only = .removed, .prefix = "std.mem" });
    try std.testing.expect(std.mem.find(u8, fw.writer.buffered(), "1 removed · 0 changed · 0 added") != null);
}

test "versionFromPinned reads the first line" {
    try std.testing.expectEqualStrings("0.17.0", snapshot.versionFromPinned("zig 0.17.0\ntarget x86_64-linux\n").?);
    try std.testing.expectEqual(@as(?[]const u8, null), snapshot.versionFromPinned("target only\n"));
    try std.testing.expectEqual(@as(?[]const u8, null), snapshot.versionFromPinned("zig \n"));
}
