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
    \\pub const DynLib = @import("dl.zig").DynLib;
    \\pub const Plat = @import("plat.zig");
    \\pub const AgainDyn = @import("dl.zig").DynLib;
    \\pub const Renamed = @import("home.zig").Curve;
    \\pub const Curve = @import("home.zig").Curve;
    \\const hidden = struct {
    \\    pub const Thing = @import("home.zig").Thing;
    \\};
    \\pub const Shown = @import("home.zig").Thing;
    \\pub const Deep = struct {
    \\    pub const Lib = @import("home.zig").Lib;
    \\};
    \\pub const Lib = @import("home.zig").Lib;
    \\pub const Gen = @import("gen.zig");
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
    \\    return struct {
    \\        v: T,
    \\        pub const Kind = u8;
    \\    };
    \\}
    \\pub const IntBox = Box(u32);
    \\pub const BoxKind = IntBox.Kind;
    \\pub const Q = struct {
    \\    pub const @"a-b" = 1;
    \\};
    \\pub const QA = Q.@"a-b";
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
    \\const native_os = @import("builtin").os.tag;
    \\const linux = struct {
    \\    pub const P = u8;
    \\};
    \\pub const Proto = switch (native_os) {
    \\    .linux, .emscripten => linux.P,
    \\    .macos => struct {
    \\        pub const TCP = 6;
    \\    },
    \\    else => void,
    \\};
    \\
;

// `uefi` here is std.mem through an import with a selector ...
const other_zig =
    \\const uefi = @import("std").mem;
    \\pub const UseA = uefi.Allocator;
    \\const m = @import("mem.zig");
    \\pub const UseC = m.Allocator;
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

// Reached only through `@import("dl.zig").DynLib`: its private helper and its test have no
// other home, and `ElfErr` inside DynLib is this file's name.
const dl_zig =
    \\const ElfErr = error{Elf};
    \\pub const DynLib = struct {
    \\    pub const Error = ElfErr || error{Other};
    \\};
    \\test DynLib {}
    \\
;


// Imports where no declaration names a file, and other shapes of const.
const plat_zig =
    \\const builtin = @import("builtin");
    \\const arch_bits = switch (builtin.cpu.arch) {
    \\    .x86_64 => @import("arch_x86_64.zig"),
    \\    else => @import("arch_other.zig"),
    \\};
    \\const impl = if (builtin.cpu.arch == .x86_64) impl: {
    \\    break :impl @import("impl_a.zig");
    \\} else impl: {
    \\    break :impl @import("impl_b.zig");
    \\};
    \\pub const Fe = Field(.{ .fiat = @import("fiat.zig") });
    \\fn Field(comptime p: anytype) type {
    \\    _ = p;
    \\    return struct {};
    \\}
    \\pub fn Indexer(comptime E: type) type {
    \\    if (E == void) {
    \\        return struct {
    \\            pub const Odd = u8;
    \\        };
    \\    }
    \\    return struct {
    \\        pub const Even = u8;
    \\    };
    \\}
    \\pub const Opts = struct {
    \\    relative: struct {
    \\        pub fn eql() void {}
    \\    },
    \\};
    \\const Options = struct {
    \\    pub const FilePermissions: ?type = null;
    \\};
    \\pub const Perm = Options.FilePermissions orelse enum { a, b };
    \\pub var instance: u8 = undefined;
    \\pub const nothing = null;
    \\pub const Alloc = struct {
    \\    pub fn init() Alloc {
    \\        return .{};
    \\    }
    \\};
    \\pub const made: Alloc = .init();
    \\
;
const arch_x86_64_zig = "pub fn syscall0() void {}\n";
const arch_other_zig = "pub fn syscall0() void {}\n";
const impl_a_zig = "pub const Block = u8;\n";
const impl_b_zig = "pub const Block = u16;\n";
const fiat_zig = "pub fn mul() void {}\n";
// Each selected twice from std.zig, the worse placement first (renamed · under a private
// parent · deeper): the home is the better one, not the first.
const home_zig =
    \\pub const Curve = struct {
    \\    pub fn add() void {}
    \\};
    \\pub const Thing = struct {};
    \\pub const Lib = struct {};
    \\
;
// Paths through a comptime param, and through an alias part-way along a path.
const gen_zig =
    \\pub fn Box(comptime T: type, comptime flag_arg: u8) type {
    \\    return struct {
    \\        pub const Curve = T;
    \\        pub const flag = flag_arg;
    \\        pub const n = Curve.len;
    \\        pub fn get() T.Index {}
    \\    };
    \\}
    \\pub const Cs = struct {
    \\    pub const Compressed = u8;
    \\};
    \\pub const Ew = struct {
    \\    pub const scalar = Cs;
    \\};
    \\pub const Ed = struct {
    \\    pub const Curve = Ew;
    \\};
    \\pub const Comp = Ed.Curve.scalar.Compressed;
    \\
;
const Out = struct { nodes: []const u8, edges: []const u8, attrs: []const u8, passes: usize };

fn extract(a: std.mem.Allocator, io: std.Io, tmp: std.testing.TmpDir) !Out {
    const files = [_][2][]const u8{ .{ "std.zig", root_zig }, .{ "mem.zig", mem_zig }, .{ "other.zig", other_zig }, .{ "tbl.zig", tbl_zig }, .{ "dl.zig", dl_zig }, .{ "plat.zig", plat_zig }, .{ "arch_x86_64.zig", arch_x86_64_zig }, .{ "arch_other.zig", arch_other_zig }, .{ "impl_a.zig", impl_a_zig }, .{ "impl_b.zig", impl_b_zig }, .{ "fiat.zig", fiat_zig }, .{ "home.zig", home_zig }, .{ "gen.zig", gen_zig } };
    for (files) |f| try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const p = struct {
        fn at(al: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
            return std.fs.path.join(al, &.{ dir, name });
        }
    }.at;
    const stats = try parse.runNamed(a, io, try p(a, base, "std.zig"), "std", try p(a, base, "nodes.tsv"), try p(a, base, "edges.tsv"), try p(a, base, "attrs.tsv"), false);
    return .{
        .nodes = try tmp.dir.readFileAlloc(io, "nodes.tsv", a, .unlimited),
        .edges = try tmp.dir.readFileAlloc(io, "edges.tsv", a, .unlimited),
        .attrs = try tmp.dir.readFileAlloc(io, "attrs.tsv", a, .unlimited),
        .passes = stats.passes,
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
    // Each arm of a platform switch is a variant node, with its condition.
    try expectRow(o.nodes, "std.mem.Proto.[linux,emscripten]\talias\t[linux,emscripten]\tpub");
    try expectRow(o.edges, "std.mem.Proto.[linux,emscripten]\talias\tstd.mem.linux.P\tcross");
    try expectRow(o.attrs, "std.mem.Proto.[linux,emscripten]\twhen\t.linux, .emscripten");
    try expectRow(o.nodes, "std.mem.Proto.[macos].TCP\tconst\tTCP\tpub");
    try expectRow(o.attrs, "std.mem.Proto.[macos].TCP\tvalue\t6");
    try expectRow(o.nodes, "std.mem.Proto.[else]\talias\t[else]\tpub");
    try expectRow(o.edges, "std.mem.Proto.[else]\talias\tvoid\tprimitive");
    // A file reached only through `@import("dl.zig").DynLib` keeps the rest of itself under a
    // private node, DynLib's names resolve in it, and its test lands on DynLib.
    try expectRow(o.nodes, "std.@\"dl.zig\"\tns\t@\"dl.zig\"\tpriv");
    try expectRow(o.nodes, "std.@\"dl.zig\".ElfErr\tconst\tElfErr\tpriv");
    try expectRow(o.edges, "std.DynLib.Error\terror_set\tstd.@\"dl.zig\".ElfErr\tcross");
    try expectRow(o.attrs, "std.DynLib\texample\ttest DynLib {}");
    try expectNoRow(o.nodes, "std.@\"dl.zig\".DynLib\tstruct\tDynLib\tpub");
    // A member reached through a const built by a factory call lands in what the factory returns.
    try expectRow(o.edges, "std.mem.BoxKind\talias\tstd.mem.Box().Kind\tlocal");
    // A quoted name is a name: `Q.@"a-b"` is an alias, not an opaque value.
    try expectRow(o.edges, "std.mem.QA\talias\tstd.mem.Q.@\"a-b\"\tlocal");
    // A file imported again where it was already walked links to that walk, and names go through.
    try expectRow(o.edges, "std.Other.m\talias\tstd.mem\tcross");
    try expectRow(o.edges, "std.Other.UseC\talias\tstd.mem.Allocator\tcross");

    // An @import in a switch arm, or in a labeled block an arm breaks with, maps its file.
    try expectRow(o.nodes, "std.Plat.arch_bits.[x86_64]\tns\t[x86_64]\tpub");
    try expectRow(o.nodes, "std.Plat.arch_bits.[x86_64].syscall0\tfn\tsyscall0\tpub");
    try expectRow(o.nodes, "std.Plat.impl.[then].Block\talias\tBlock\tpub");
    try expectRow(o.nodes, "std.Plat.impl.[else].Block\talias\tBlock\tpub");
    // A file imported only inside a call argument gets a private node under the importing file.
    try expectRow(o.nodes, "std.Plat.@\"fiat.zig\"\tns\t@\"fiat.zig\"\tpriv");
    try expectRow(o.nodes, "std.Plat.@\"fiat.zig\".mul\tfn\tmul\tpub");
    // A factory's earlier conditional return is a variant of what it returns.
    try expectRow(o.nodes, "std.Plat.Indexer().Even\talias\tEven\tpub");
    try expectRow(o.nodes, "std.Plat.Indexer().[return1].Odd\talias\tOdd\tpub");
    // A container written as a field's type has its members under the field.
    try expectRow(o.nodes, "std.Plat.Opts.relative.eql\tfn\teql\tpub");
    // `X orelse Default`: the option and the default are arms.
    try expectRow(o.nodes, "std.Plat.Perm.[given]\talias\t[given]\tpub");
    try expectRow(o.nodes, "std.Plat.Perm.[orelse]\tenum\t[orelse]\tpub");
    // A var, and a value keyword, are values, not aliases.
    try expectRow(o.nodes, "std.Plat.instance\tconst\tinstance\tpub");
    try expectRow(o.nodes, "std.Plat.nothing\tconst\tnothing\tpub");
    // A declaration selected twice has one home; the second selection is an alias of it.
    try expectRow(o.edges, "std.AgainDyn\talias\tstd.DynLib\tlocal");
    try expectNoRow(o.nodes, "std.AgainDyn\tstruct\tAgainDyn\tpub");
    // ... and the home is the best placement, met first or not: a public path over one under a
    // private node (even one keeping the name), the declaration's own name over a rename, the
    // shorter path over a deeper one. One pass places them first-met, the next settles: a home
    // seeded from the first pass must not be dropped as "selected elsewhere" (a third pass).
    try std.testing.expectEqual(@as(usize, 2), o.passes);
    // A path through a comptime param — a type, a non-type `comptime` one, or an alias of one —
    // is `generic` (fixed per instance), not unresolved.
    try expectRow(o.edges, "std.Gen.Box().get\thas_type\tT.Index\tgeneric");
    try expectRow(o.edges, "std.Gen.Box().flag\talias\tflag_arg\tgeneric");
    try expectRow(o.edges, "std.Gen.Box().n\talias\tCurve.len\tgeneric");
    // An alias part-way along a path is followed: Ed.Curve → Ew, Ew.scalar → Cs.
    try expectRow(o.edges, "std.Gen.Comp\talias\tstd.Gen.Cs.Compressed\tlocal");
    try expectRow(o.nodes, "std.Curve.add\tfn\tadd\tpub");
    try expectRow(o.edges, "std.Renamed\talias\tstd.Curve\tlocal");
    try expectRow(o.nodes, "std.Shown\tstruct\tShown\tpub");
    try expectRow(o.edges, "std.hidden.Thing\talias\tstd.Shown\tcross");
    try expectRow(o.nodes, "std.Lib\tstruct\tLib\tpub");
    try expectRow(o.edges, "std.Deep.Lib\talias\tstd.Lib\tcross");
    // A decl literal calls a member of the declared type.
    try expectRow(o.edges, "std.Plat.made\tinstantiates\tstd.Plat.Alloc.init\tlocal");
}
