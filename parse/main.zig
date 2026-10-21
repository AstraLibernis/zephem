// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! parse/main.zig — the extractor as its own program, built by the Zig whose std it maps:
//!
//!   walk <root std.zig> <nodes.tsv> <edges.tsv> <attrs.tsv>
//!
//! `zephem std` compiles this with the target toolchain (`$ZIG build-exe`) and runs it, so the
//! std is parsed by its own release's parser. Everything it imports must compile on every
//! supported Zig; version differences live in compat.zig.

const std = @import("std");
const walk = @import("walk.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) {
        std.log.err("usage: walk <root std.zig> <nodes.tsv> <edges.tsv> <attrs.tsv>", .{});
        std.process.exit(2);
    }
    _ = try walk.run(arena, init.io, args[1], args[2], args[3], args[4]);
}
