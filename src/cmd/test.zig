// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! cmd/test.zig — the query-layer smoke battery (port of `query/test.nu`). Asserts real std facts
//! through the two lookup subcommands: `look` (SIMD over the baked table) and `map` (reads the
//! TSVs directly). Builds the lookup table first if it is missing.
const std = @import("std");
const argv = @import("../args.zig");
const sigfmt = @import("../sig.zig");
const Outcome = @import("../query.zig").Outcome;
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
        \\  run the query smoke battery (asserted std facts)
        \\
        \\  NOTE: bakes data/lookup.tsv if it is absent.
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

    // ── redirects ── `std.ArrayList` is a thin fn over `array_list.Aligned`; `std.StringHashMap`
    // is an alias of `hash_map.StringHashMap`, which delegates to `hash_map.HashMap`. Before these
    // were followed, `map show std.ArrayList` listed one row and `look ArrayList append` never
    // reached the real `append`.
    try expectLook(c, w, &fails, "look reaches a member through a delegating name", &.{ "ArrayList", "append", "--limit", "2" }, &.{ "std.array_list.Aligned().append", "≡ std.ArrayList().append" });
    try expectMap(c, w, &fails, "map show follows delegates to the members", &.{ "show", "std.ArrayList" }, &.{ "─delegates→ std.array_list.Aligned", "std.array_list.Aligned().append" });
    try expectMap(c, w, &fails, "map doc rewrites the path people type", &.{ "doc", "std.ArrayList.append" }, &.{ "is std.array_list.Aligned().append", "fn append(" });
    try expectMap(c, w, &fails, "map doc follows alias then delegates", &.{ "doc", "std.StringHashMap().get" }, &.{"std.hash_map.HashMap().get"});
    try expectMap(c, w, &fails, "map find matches through the alternative name", &.{ "find", "StringHashMap", "getPtr" }, &.{"std.hash_map.HashMap().getPtr"});

    // ── outcomes ── the previous battery discarded these with `_ =`, which is how "map could
    // never return 3" shipped. A hit, a miss and their exit meanings are asserted facts now.
    try expectOutcome(c, w, &fails, "look hit returns .hit", true, &.{"parseInt"}, .hit);
    try expectOutcome(c, w, &fails, "look miss returns .miss", true, &.{"zzzznomatchzzz"}, .miss);
    try expectOutcome(c, w, &fails, "map doc miss returns .miss", false, &.{ "doc", "std.mem.copy" }, .miss);
    try expectOutcome(c, w, &fails, "map find hit returns .hit", false, &.{ "find", "ArrayList" }, .hit);
    try expectOutcome(c, w, &fails, "a wrong-case path is still a miss", false, &.{ "doc", "std.fmt.parseint" }, .miss);

    // ── the sig splitter ── pure function, deterministic. The raw string is the shape that
    // produced downstream false positive B16: two parameters, prose commas counted as three.
    {
        const raw = "fn init( /// Must be threadsafe. Only used for the following functions: " ++
            "/// * `Io.VTable.async` /// If these functions are avoided, then `Allocator.failing` " ++
            "may be passed /// here. gpa: Allocator, options: InitOptions, ) Threaded";
        const parts = sigfmt.split(c.a, raw);
        try checkOne(w, &fails, "splitter: prose stripped from sig", parts.sig, "fn init( gpa: Allocator, options: InitOptions, ) Threaded");
        try checkOne(w, &fails, "splitter: prose preserved", if (std.mem.find(u8, parts.doc, "Must be threadsafe") != null) "y" else "n", "y");
        const clean = sigfmt.split(c.a, "fn f(a: u8) void");
        try checkOne(w, &fails, "splitter: clean sig untouched", clean.sig, "fn f(a: u8) void");
    }

    // ── error-set member count ── the first version counted every comma in the string and was
    // wrong on 66% of annotated rows; these pin the corrected behaviour to map facts
    // (zig-0.16-pinned, like every other assertion in this battery).
    try expectLook(c, w, &fails, "error set emitted whole with TRUE count", &.{ "Client.InitError", "--limit", "2" }, &.{ "[47 members, shown in full]", "WriteFailed}" });

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

fn expectOutcome(c: Ctx, w: *std.Io.Writer, fails: *usize, label: []const u8, is_look: bool, args: []const []const u8, want: Outcome) !void {
    var aw: std.Io.Writer.Allocating = .init(c.a);
    const got = if (is_look) try zlook.run(c, args, &aw.writer) else try zmap.run(c, args, &aw.writer);
    if (got == want) {
        try w.print("PASS: {s}\n", .{label});
    } else {
        fails.* += 1;
        try w.print("FAIL: {s} — got .{s}, want .{s}\n", .{ label, @tagName(got), @tagName(want) });
    }
}

fn checkOne(w: *std.Io.Writer, fails: *usize, label: []const u8, got: []const u8, want: []const u8) !void {
    if (std.mem.eql(u8, got, want)) {
        try w.print("PASS: {s}\n", .{label});
    } else {
        fails.* += 1;
        try w.print("FAIL: {s}\n  got : {s}\n  want: {s}\n", .{ label, got, want });
    }
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
