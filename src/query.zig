// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Outcome of a read-only query, so the dispatcher can set a meaningful exit code.
//!
//! Every query path used to exit 0 — a hit, a miss, a garbage path, and "the lookup table does
//! not exist at all" were indistinguishable to any caller. A consumer could not tell "no
//! results" from "this tool is not working", which for a map that claims to be the sole source
//! of std truth is the difference between an answer and a silent absence of one.
const std = @import("std");

pub const Outcome = enum(u8) {
    /// Found what was asked for.
    hit = 0,
    /// Ran correctly; nothing matched.
    miss = 1,
    /// Bad invocation — unknown subcommand, missing argument.
    usage = 2,
    /// The map or lookup table is absent or unreadable. NOT the same as a miss.
    unavailable = 3,

    pub fn code(o: Outcome) u8 {
        return @intFromEnum(o);
    }
};
