// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const testing = std.testing;
const pkg = @import("zephem").pkg;

test "dependencies: fetched (hash) and local (path), quoted names unquoted" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const zon =
        \\.{
        \\    .name = .demo,
        \\    .version = "0.0.0",
        \\    .dependencies = .{
        \\        .clap = .{
        \\            .url = "git+https://github.com/Hejsil/zig-clap#05faf39",
        \\            .hash = "clap-0.12.0-oBajB4Xp",
        \\        },
        \\        .@"zig-local" = .{ .path = "../local" },
        \\        .broken = .{ .url = "https://x" },
        \\    },
        \\}
    ;
    const deps = try pkg.depsOf(a.allocator(), zon);
    try testing.expectEqual(2, deps.len); // `broken` has neither hash nor path
    try testing.expectEqualStrings("clap", deps[0].name);
    try testing.expectEqualStrings("clap-0.12.0-oBajB4Xp", deps[0].hash.?);
    try testing.expectEqualStrings("zig-local", deps[1].name);
    try testing.expectEqualStrings("../local", deps[1].path.?);
}

test "a manifest with no dependencies has none" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectEqual(0, (try pkg.depsOf(a.allocator(), ".{ .name = .x, .dependencies = .{} }")).len);
}

test "modules: literal addModule calls only" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const build =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const m = b.addModule("clap", .{
        \\        .root_source_file = b.path("clap.zig"),
        \\        .target = target,
        \\    });
        \\    _ = b.addModule("two", .{ .target = target, .root_source_file = b.path("src/two.zig") });
        \\    _ = b.createModule(.{ .root_source_file = b.path("internal.zig") }); // not exported
        \\    _ = b.addModule(name_from_somewhere, .{ .root_source_file = b.path("x.zig") }); // computed
        \\    _ = m;
        \\}
    ;
    const mods = try pkg.modulesOf(a.allocator(), build);
    try testing.expectEqual(2, mods.len);
    try testing.expectEqualStrings("clap", mods[0].name);
    try testing.expectEqualStrings("clap.zig", mods[0].root);
    try testing.expectEqualStrings("two", mods[1].name);
    try testing.expectEqualStrings("src/two.zig", mods[1].root);
}
