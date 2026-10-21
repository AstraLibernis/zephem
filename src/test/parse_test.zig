// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The extractor (parse/walk.zig) on a small fixture std, one case per line of each file:
//! what each declaration must produce in nodes / edges / attrs.

const std = @import("std");
const parse = @import("parse");

const root_zig =
    \\//! The fixture std.
    \\const std = @import("std");
    \\const builtin = @import("builtin");
    \\pub const mem = @import("mem.zig");
    \\pub const Tbl = @import("tbl.zig");
    \\pub const Other = @import("other.zig");
    \\pub const is_debug = @import("builtin").mode == .Debug;
    \\pub const os_tag = builtin.os.tag;
    \\
;

const mem_zig =
    \\//! Memory things.
    \\const std = @import("std");
    \\pub const Allocator = struct {
    \\    const Self = @This();
    \\    pub const Error = error{OutOfMemory};
    \\    pub fn alloc(self: Self, comptime T: type, n: usize) Error![]T {
    \\        _ = self;
    \\        _ = n;
    \\        return &.{};
    \\    }
    \\};
    \\pub const Short = std.mem.Allocator;
    \\pub const AllocErr = std.mem.Allocator.Error;
    \\pub const Buf = struct {
    \\    data: [len]u8,
    \\    next: ?*Buf = null,
    \\};
    \\const len = 4;
    \\pub const pi = 3.14;
    \\pub const Both = Allocator.Error || error{Extra};
    \\pub fn Box(comptime T: type) type {
    \\    return struct { v: T };
    \\}
    \\pub const IntBox = Box(u32);
    \\pub fn first(comptime T: type, xs: []const T) T {
    \\    return xs[0];
    \\}
    \\pub fn commented(
    \\    a: u32, // the first
    \\    b: u32,
    \\) u32 {
    \\    return a + b;
    \\}
    \\extern "kernel32" fn GetTick() u32;
    \\
;

// `uefi` here is std.mem through an import with a selector ...
const other_zig =
    \\const uefi = @import("std").mem;
    \\pub const UseA = uefi.Allocator;
    \\
;

// ... and here a local struct: one file's import must not redefine the name in another.
const tbl_zig =
    \\const uefi = struct {
    \\    pub const Allocator = u8;
    \\};
    \\pub const UseB = uefi.Allocator;
    \\
;

const Out = struct { nodes: []const u8, edges: []const u8, attrs: []const u8 };

fn extract(a: std.mem.Allocator, io: std.Io, tmp: std.testing.TmpDir) !Out {
    const files = [_][2][]const u8{ .{ "std.zig", root_zig }, .{ "mem.zig", mem_zig }, .{ "other.zig", other_zig }, .{ "tbl.zig", tbl_zig } };
    for (files) |f| try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const p = struct {
        fn at(al: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
            return std.fs.path.join(al, &.{ dir, name });
        }
    }.at;
    _ = try parse.runNamed(a, io, try p(a, base, "std.zig"), "std", try p(a, base, "nodes.tsv"), try p(a, base, "edges.tsv"), try p(a, base, "attrs.tsv"), false);
    return .{
        .nodes = try tmp.dir.readFileAlloc(io, "nodes.tsv", a, .unlimited),
        .edges = try tmp.dir.readFileAlloc(io, "edges.tsv", a, .unlimited),
        .attrs = try tmp.dir.readFileAlloc(io, "attrs.tsv", a, .unlimited),
    };
}

fn expectRow(table: []const u8, row: []const u8) !void {
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |ln| if (std.mem.eql(u8, ln, row)) return;
    std.debug.print("missing row: {s}\n", .{row});
    return error.TestExpectedRow;
}

fn expectNoRow(table: []const u8, row: []const u8) !void {
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |ln| if (std.mem.eql(u8, ln, row)) {
        std.debug.print("unexpected row: {s}\n", .{row});
        return error.TestUnexpectedRow;
    };
}

test "extractor: every fixed case produces its row" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const o = try extract(a, io, tmp);

    // A path through the walked root resolves to its node, through an alias where needed; a
    // path through a module outside the tree keeps its whole text.
    try expectRow(o.edges, "std.mem.Short\talias\tstd.mem.Allocator\tlocal");
    try expectRow(o.edges, "std.mem.AllocErr\talias\tstd.mem.Allocator.Error\tlocal");
    try expectRow(o.edges, "std.os_tag\talias\tbuiltin.os.tag\tmodule");
    // An array type points at its element, not its length.
    try expectRow(o.edges, "std.mem.Buf.data\thas_type\tu8\tprimitive");
    try expectNoRow(o.edges, "std.mem.Buf.data\thas_type\tstd.mem.len\tlocal");
    // Written types and const values are kept.
    try expectRow(o.attrs, "std.mem.Buf.next\ttype\t?*Buf");
    try expectRow(o.attrs, "std.mem.pi\tvalue\t3.14");
    // Each operand of `A || B` is its own error set.
    try expectRow(o.edges, "std.mem.Both\terror_set\tstd.mem.Allocator.Error\tlocal");
    try expectRow(o.edges, "std.mem.Both\terror_set\terror{Extra}\tinline");
    // A const built by a call names the factory; `@This()` names its container.
    try expectRow(o.edges, "std.mem.IntBox\tinstantiates\tstd.mem.Box\tlocal");
    try expectRow(o.edges, "std.mem.Allocator.Self\talias\tstd.mem.Allocator\tlocal");
    // An ordinary fn's own `comptime T: type` is a generic param.
    try expectRow(o.edges, "std.mem.first\thas_type\tT\tgeneric");
    // A comment inside a signature does not swallow the rest of it.
    try expectRow(o.attrs, "std.mem.commented\tsig\tfn commented( a: u32, b: u32, ) u32");
    // An extern keeps its library.
    try expectRow(o.attrs, "std.mem.GetTick\tmod\textern \"kernel32\"");
    // `//!` file docs reach the namespace (and the root).
    try expectRow(o.attrs, "std.mem\tdoc\tMemory things.");
    try expectRow(o.attrs, "std\tdoc\tThe fixture std.");
    // An expression on a module is a const with its value, not a module reference.
    try expectRow(o.nodes, "std.is_debug\tconst\tis_debug\tpub");
    try expectRow(o.attrs, "std.is_debug\tvalue\t@import(\"builtin\").mode == .Debug");
    // Imports are per file: `uefi` is std.mem in one file and a local struct in the other.
    try expectRow(o.edges, "std.Other.UseA\talias\tstd.mem.Allocator\tcross");
    try expectRow(o.edges, "std.Tbl.UseB\talias\tstd.Tbl.uefi.Allocator\tlocal");
}
