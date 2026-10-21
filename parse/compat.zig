// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! parse/compat.zig — the std calls whose shape differs between the Zig releases the extractor
//! is built with. The extractor is compiled by the Zig whose std it maps (`zephem std` builds
//! parse/main.zig with that toolchain), so it parses each std with that release's own parser;
//! this file is what lets one source compile on each of them.
//!
//! Chosen by feature (`@hasDecl`), not by version number, so a release that keeps a shape needs
//! no entry. Builtins cannot be feature-tested — a builtin name is checked before any comptime
//! branch is pruned — so the extractor avoids builtins that differ between releases instead
//! (`std.EnumArray`, not `@intFromEnum`/`@backingInt`). Likewise it keeps calling std names that
//! exist in every supported release even where the newest one deprecates them.
//!
//! Supported: 0.16.0, 0.17.0. A new release adds a branch here only where it fails to compile.

const std = @import("std");
const Ast = std.zig.Ast;

/// Parse Zig source. 0.16 takes a `Mode` enum; 0.17 takes `ParseOptions`.
pub fn parseZig(gpa: std.mem.Allocator, source: [:0]const u8) std.mem.Allocator.Error!Ast {
    if (comptime @hasDecl(Ast, "ParseOptions")) return Ast.parse(gpa, source, .{});
    return Ast.parse(gpa, source, .zig);
}
