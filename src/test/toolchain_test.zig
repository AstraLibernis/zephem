// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The cached `zig env` answer that `map` uses for its staleness warning: it may only ever
//! answer for the exact binary and host it was written for.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const tc = @import("zephem").toolchain;
const Ctx = @import("zephem").ctx.Ctx;

const exe: tc.Exe = .{ .path = "/opt/zig-0.17.1/zig", .size = 190087680, .mtime = 1_793_706_854_000_000_000 };
const host = "x86_64-linux.6.17...6.17-gnu.2.43";
const live: tc.Live = .{ .version = "0.17.1", .target = "x86_64-linux.5.10...7.2-gnu.2.43" };

test "a cache line answers only for the exact binary and host it was written for" {
    const a = testing.allocator;
    const line = try tc.renderCache(a, exe, host, live);
    defer a.free(line);
    const hit = tc.matchCache(line, exe, host).?;
    try testing.expectEqualStrings(live.version, hit.version);
    try testing.expectEqualStrings(live.target, hit.target);

    var other = exe;
    other.path = "/opt/zig-0.16.0/zig";
    try testing.expect(tc.matchCache(line, other, host) == null);
    other = exe;
    other.size -= 1;
    try testing.expect(tc.matchCache(line, other, host) == null);
    other = exe;
    other.mtime += 1;
    try testing.expect(tc.matchCache(line, other, host) == null);
    // an OS or libc upgrade changes the host triple std detects
    try testing.expect(tc.matchCache(line, exe, "x86_64-linux.6.18...6.18-gnu.2.43") == null);
}

test "a malformed cache line is a miss" {
    const p = "/opt/zig-0.17.1/zig\t190087680\t1793706854000000000\t" ++ host;
    const bad = [_][]const u8{
        "",
        p,
        p ++ "\t0.17.1",
        p ++ "\t\t" ++ "t",
        p ++ "\t0.17.1\tt\textra",
        "/opt/zig-0.17.1/zig\tsize\t1793706854000000000\t" ++ host ++ "\t0.17.1\tt",
    };
    for (bad) |b| try testing.expect(tc.matchCache(b, exe, host) == null);
    // an empty target is a valid answer (`zig env` from older zigs had none)
    try testing.expectEqualStrings("", tc.matchCache(p ++ "\t0.17.1\t\r\n", exe, host).?.target);
}

const zig_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";

fn putExe(dir: std.Io.Dir, sub: []const u8, data: []const u8) !void {
    try dir.writeFile(testing.io, .{ .sub_path = sub, .data = data, .flags = .{ .permissions = .executable_file } });
}

test "resolveZig follows PATH order, honours a $ZIG path, and refuses an ambiguous match" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    for ([_][]const u8{ "empty", "x", "y", "amb" }) |d| try tmp.dir.createDirPath(testing.io, d);
    try putExe(tmp.dir, "x/" ++ zig_name, "first");
    try putExe(tmp.dir, "y/" ++ zig_name, "second binary");
    const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const d: []const u8 = &.{std.fs.path.delimiter};
    const dir = struct {
        fn of(al: std.mem.Allocator, b: []const u8, n: []const u8) []const u8 {
            return std.fs.path.join(al, &.{ b, n }) catch unreachable; // zsnag:ok — test arena
        }
    }.of;

    var env = std.process.Environ.Map.init(a);
    try env.put("PATH", try std.mem.concat(a, u8, &.{ dir(a, base, "empty"), d, dir(a, base, "x"), d, dir(a, base, "y") }));
    const c: Ctx = .{ .a = a, .io = testing.io, .env = &env };
    const e = tc.resolveZig(c) orelse return error.NotResolved;
    try testing.expect(std.fs.path.isAbsolute(e.path));
    try testing.expectEqual(@as(u64, 5), e.size);

    // $ZIG as a path is used as given (resolved), PATH ignored
    try env.put("ZIG", dir(a, base, "y/" ++ zig_name));
    try testing.expectEqual(@as(u64, 13), (tc.resolveZig(c) orelse return error.NotResolved).size);
    _ = env.swapRemove("ZIG");

    // nothing on PATH
    try env.put("PATH", dir(a, base, "empty"));
    try testing.expect(tc.resolveZig(c) == null);

    if (builtin.os.tag == .windows) {
        // a zig.cmd next to zig.exe: the spawn could pick either, so nothing is cached
        try putExe(tmp.dir, "amb/zig.exe", "exe");
        try putExe(tmp.dir, "amb/zig.cmd", "@echo 1");
        try env.put("PATH", try std.mem.concat(a, u8, &.{ dir(a, base, "amb"), d, dir(a, base, "x") }));
        try testing.expect(tc.resolveZig(c) == null);
    } else {
        // a non-executable `zig` is skipped, as execvp skips it
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "amb/zig", .data = "not executable" });
        try env.put("PATH", try std.mem.concat(a, u8, &.{ dir(a, base, "amb"), d, dir(a, base, "x") }));
        try testing.expectEqual(@as(u64, 5), (tc.resolveZig(c) orelse return error.NotResolved).size);
    }
}
