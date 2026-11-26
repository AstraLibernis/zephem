// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The field-type self-check: printed (as written) vs resolved (`@typeName`), compared by shape.
const std = @import("std");
const ft = @import("zephem").fieldtype;

fn expectShape(text: []const u8, want: []const u8, base: []const u8) !void {
    const s = ft.shapeOf(text);
    var got: [ft.max_depth]u8 = undefined;
    for (s.slice(), 0..) |c, i| got[i] = @backingInt(c);
    try std.testing.expectEqualStrings(want, got[0..s.len]);
    try std.testing.expectEqualStrings(base, s.base);
}

test "shapeOf reads every constructor and skips qualifiers" {
    try expectShape("u8", "", "u8");
    try expectShape("[]const []const u8", "SS", "u8");
    try expectShape("?*const process.Environ.Map", "?*", "process.Environ.Map");
    try expectShape("[*:0]const u8", "M", "u8");
    try expectShape("[*c]u8", "M", "u8");
    try expectShape("[:0]u8", "S", "u8");
    try expectShape("[4]u8", "A", "u8");
    try expectShape("[@sizeOf(usize) * 2]u8", "A", "u8");
    try expectShape("[]align(std.heap.page_size_min) u8", "S", "u8");
    try expectShape("*allowzero volatile u32", "*", "u32");
    try expectShape("?*const fn (*anyopaque) void", "?*", "fn (*anyopaque) void");
    try expectShape("constant", "", "constant"); // a name starting `const` is not the qualifier
}

test "judge: the reported bug is wrong, the true answers are not" {
    // what zephem printed (the `has_type` edge) against what the compiler resolves
    try std.testing.expectEqual(ft.Verdict.wrong, ft.judge("u8", "[]const []const u8")); // RunOptions.argv
    try std.testing.expectEqual(ft.Verdict.wrong, ft.judge("u8", "[]u8")); // RunResult.stdout
    try std.testing.expectEqual(ft.Verdict.wrong, ft.judge("Map", "?*const process.Environ.Map"));
    // the type as written
    try std.testing.expectEqual(ft.Verdict.agrees, ft.judge("[]const []const u8", "[]const []const u8"));
    try std.testing.expectEqual(ft.Verdict.agrees, ft.judge("?*const Environ.Map", "?*const process.Environ.Map"));
    try std.testing.expectEqual(ft.Verdict.agrees, ft.judge("[N]T", "[4]u8"));
    // a name standing for more constructors is shorter, not false; a primitive cannot stand for any
    try std.testing.expectEqual(ft.Verdict.hidden, ft.judge("Slice", "[]u8"));
    try std.testing.expectEqual(ft.Verdict.hidden, ft.judge("?Slice", "?[]u8"));
    try std.testing.expectEqual(ft.Verdict.wrong, ft.judge("?u8", "?[]u8"));
    // a constructor the compiler does not have
    try std.testing.expectEqual(ft.Verdict.wrong, ft.judge("[]u8", "u8"));
    try std.testing.expectEqual(ft.Verdict.wrong, ft.judge("*u8", "[]u8"));
}
