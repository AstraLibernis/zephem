//! cmd/test.zig — the query-layer smoke battery (port of `query/test.nu`). Asserts real std facts
//! through the two lookup subcommands: `look` (SIMD over the baked table) and `map` (reads the
//! TSVs directly). Builds the lookup table first if it is missing.
const std = @import("std");
const argv = @import("../args.zig");
const Ctx = @import("../ctx.zig").Ctx;
const vars = @import("../vars.zig");
const lookup = @import("../lookup.zig");
const zlook = @import("../zlook.zig");
const zmap = @import("../zmap.zig");
const rel = @import("../relation.zig");

pub fn run(c: Ctx, args: []const []const u8) !void {
    const usage =
        \\usage: zephem test
        \\
        \\  run the query smoke battery (9 asserted std facts)
        \\
        \\  NOTE: bakes ~/.config/zephem/lookup.tsv if it is absent.
        \\
    ;
    if (try argv.helpRequested(c, args, usage)) return;
    for (args) |a| argv.reject(c, a, usage);

    const a = c.a;
    var ow = std.Io.File.stdout().writer(c.io, try a.alloc(u8, 4096));
    const w = &ow.interface;
    defer w.flush() catch {};

    // ensure the baked lookup table exists (zlook's input)
    const lpath = try vars.lookupPath(c);
    if (std.Io.Dir.cwd().access(c.io, lpath, .{})) |_| {} else |_| {
        try w.writeAll("building lookup.tsv ...\n");
        const table = try lookup.build(c, try vars.dataDir(c));
        if (std.fs.path.dirname(lpath)) |d| try std.Io.Dir.cwd().createDirPath(c.io, d);
        try rel.writeFile(table, c.io, lpath);
    }

    var fails: usize = 0;

    // ── look cases ────────────────────────────────────────────────────────────
    try expectLook(c, w, &fails, "factory member path", &.{ "HashMap", "get" }, &.{"HashMap().get"});
    try expectLook(c, w, &fails, "factory member signature", &.{ "HashMap", "get" }, &.{"fn get("});
    try expectLook(c, w, &fails, "resolved error-set search", &.{"OutOfMemory"}, &.{"OutOfMemory"});
    try expectLook(c, w, &fails, "delegation target shown", &.{"AutoHashMap"}, &.{"⇒"});
    try expectLook(c, w, &fails, "zlook demotes private + reports the count", &.{ "Alignment", "--limit", "3" }, &.{ "std.mem.Alignment", "private, tagged" });

    // ── map cases ─────────────────────────────────────────────────────────────
    try expectMap(c, w, &fails, "map find surfaces fmt.parseInt", &.{ "find", "parse", "int", "--limit", "5" }, &.{"std.fmt.parseInt"});
    try expectMap(c, w, &fails, "map find surfaces timing_safe", &.{ "find", "constant time", "--limit", "8" }, &.{"timing_safe"});
    try expectMap(c, w, &fails, "map doc flags a private decl", &.{ "doc", "std.heap.ArenaAllocator.Allocator" }, &.{ "[priv]", "private decl" });
    try expectMap(c, w, &fails, "map show sections public vs private", &.{ "show", "std.heap.ArenaAllocator" }, &.{ "## public", "## private" });

    if (fails == 0) {
        try w.writeAll("--- all passed ---\n");
    } else {
        try w.writeAll("--- failures present ---\n");
        try w.flush();
        std.process.exit(1);
    }
}

fn expectLook(c: Ctx, w: *std.Io.Writer, fails: *usize, label: []const u8, args: []const []const u8, wants: []const []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(c.a);
    _ = try zlook.run(c, args, &aw.writer);
    try check(w, fails, label, aw.writer.buffered(), wants);
}

fn expectMap(c: Ctx, w: *std.Io.Writer, fails: *usize, label: []const u8, args: []const []const u8, wants: []const []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(c.a);
    _ = try zmap.run(c, args, &aw.writer);
    try check(w, fails, label, aw.writer.buffered(), wants);
}

fn check(w: *std.Io.Writer, fails: *usize, label: []const u8, output: []const u8, wants: []const []const u8) !void {
    for (wants) |want| {
        if (std.mem.indexOf(u8, output, want) == null) {
            try w.print("FAIL: {s} (expected substring: {s})\n", .{ label, want });
            fails.* += 1;
            return;
        }
    }
    try w.print("PASS: {s}\n", .{label});
}
