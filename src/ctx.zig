// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! ctx.zig — the ambient handles every subcommand needs: an allocator (an arena, in practice),
//! the `std.Io` implementation, and the process environment (for `$ZEPHEM_*` overrides). Threaded
//! explicitly instead of reached for globally, so the data flow stays visible.
const std = @import("std");

pub const Ctx = struct {
    a: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,

    pub fn getEnv(c: Ctx, key: []const u8) ?[]const u8 {
        return c.env.get(key);
    }
};
