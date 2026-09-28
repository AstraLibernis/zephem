// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! zephem — one binary, many subcommands. Pointed at Zig's std, it regenerates and self-checks
//! the queryable map, and serves lookups over it. This dispatcher builds the ambient `Ctx`
//! (allocator · io · env) and hands off to the subcommand. Everything is built BY Zig: `build.zig`
//! exposes `zig build std/depth/overlays/docs/lookup/check/depth-check/test/smoke` over this binary.
const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const cmd_std = @import("cmd/std.zig");
const cmd_depth = @import("cmd/depth.zig");
const cmd_overlays = @import("cmd/overlays.zig");
const cmd_docs = @import("docs.zig");
const cmd_lookup = @import("lookup.zig");
const cmd_test = @import("cmd/test.zig");
const zlook = @import("zlook.zig");
const zmap = @import("zmap.zig");
const Outcome = @import("query.zig").Outcome;
const argv = @import("args.zig");

const usage =
    \\zephem <command> [args]
    \\
    \\  std        regenerate the core std map (parse + index + verify + manifest)
    \\  depth      run the L5 reflection sweep (slow)
    \\  overlays   rebuild the derived overlays
    \\  docs       regenerate the markdown docs from templates/
    \\  lookup     bake the denormalized lookup table zlook searches
    \\  look       keyword-search the map (SIMD)
    \\  map        browse the map: find / show / doc
    \\  test       run the query smoke battery
    \\
    \\  every command takes -h/--help
    \\
;

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const c = Ctx{ .a = arena, .io = init.io, .env = init.environ_map };
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) return fail(c, usage);
    const cmd = args[1];
    if (argv.isHelp(cmd) or std.mem.eql(u8, cmd, "help")) return help(c);
    const rest = args[2..];

    if (std.mem.eql(u8, cmd, "std")) return cmd_std.run(c, rest);
    if (std.mem.eql(u8, cmd, "depth")) return cmd_depth.run(c, rest);
    if (std.mem.eql(u8, cmd, "overlays")) return cmd_overlays.run(c, rest);
    if (std.mem.eql(u8, cmd, "docs")) return cmd_docs.run(c, rest);
    if (std.mem.eql(u8, cmd, "lookup")) return cmd_lookup.run(c, rest);
    if (std.mem.eql(u8, cmd, "look")) return runWithStdout(c, zlook.run, rest);
    if (std.mem.eql(u8, cmd, "map")) return runWithStdout(c, zmap.run, rest);
    if (std.mem.eql(u8, cmd, "test")) return cmd_test.run(c, rest);

    return fail(c, usage);
}

/// Run a query subcommand that writes to a caller-supplied writer, wiring it to stdout, and
/// turn its outcome into an EXIT CODE.
///
/// Every query used to exit 0 — a hit, a miss, a garbage path, and "the lookup table does not
/// exist at all" were indistinguishable to any caller. A consumer could not tell "no results"
/// from "this tool is not working", which for a map that claims to be the sole source of std
/// truth is the difference between an answer and a silent absence of one.
///   0 hit · 1 miss · 2 usage · 3 map/table unavailable
fn runWithStdout(c: Ctx, comptime f: fn (Ctx, []const []const u8, *std.Io.Writer) anyerror!Outcome, args: []const []const u8) !void {
    var buf: [1 << 16]u8 = undefined;
    var ow = std.Io.File.stdout().writer(c.io, &buf);
    const outcome = try f(c, args, &ow.interface);
    try ow.interface.flush();
    if (outcome != .hit) std.process.exit(outcome.code());
}

/// Asked-for help is a success: usage to stdout, exit 0. Only a missing or unknown command is
/// a usage error (stderr, exit 2).
fn help(c: Ctx) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(c.io, &buf);
    try w.interface.writeAll(usage);
    try w.interface.flush();
}

fn fail(c: Ctx, msg: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(c.io, &buf);
    try w.interface.writeAll(msg);
    try w.interface.flush();
    std.process.exit(2);
}
