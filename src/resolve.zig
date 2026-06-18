//! resolve.zig — the L5 (resolved depth) reflector for ONE container.
//!
//! Where scan.zig/enrich.zig *parse* source (total coverage, never dies), this program
//! asks the *compiler*: it reflects a single container the map points at and emits the
//! resolved truth that parsing cannot compute — constant VALUES (the real
//! `digest_length = 32`), expanded aliases/generics, and fully-typed function signatures
//! WITH error sets. Output is keyed by the same logical `path` as nodes.tsv:
//!
//!   path · kind · detail
//!
//!   kind=type       detail = the resolved @typeName (alias/generic already expanded)
//!   kind=const_int  detail = the integer value           (e.g. 32)
//!   kind=const_bool detail = true|false
//!   kind=fn         detail = the resolved fn type signature, error set included
//!   kind=const_other detail = the value's @typeName
//!
//! Reflecting evaluates decls, so a platform-gated / @compileError ("poison") decl makes
//! THIS process fail to compile. That is the design: one container per process, so a
//! poison kills only this subprocess. The orchestrator (scripts/build_depth.nu) records
//! the failure as `path · reason` and moves on — depth on demand, poison contained.
//!
//! The two TARGET lines below are rewritten per-container by the orchestrator. Left at
//! their defaults this file is a runnable self-test:  `zig run src/resolve.zig`.

const std = @import("std");

// ── rewritten per-container by scripts/build_depth.nu (matched by line prefix) ──
const TARGET_PATH = "std.crypto.hash.sha2";
const TARGET = @import("std").crypto.hash.sha2;
// SKIP = this container's DIRECT child decls that are themselves map containers. We don't
// descend into them — they get reflected on their own turn, and descending here would emit
// their decls a second time (with a divergent @typeName), the dup/conflict the verifier rejects.
const SKIP = [_][]const u8{};
// ────────────────────────────────────────────────────────────────────────────────────────

/// How many levels of nested *type* decls to descend. 1 = the container's own decls plus,
/// for each NON-container type it declares (a generic/alias the map left as a leaf), that
/// type's scalar decls — so `sha2` yields not just `Sha256` but `Sha256.digest_length = 32`,
/// the resolved value the map cannot compute. Kept shallow on purpose.
const DESCEND: u8 = 1;

/// True if `name` is one of this container's direct child containers (don't descend into it).
fn inSkip(comptime name: []const u8) bool {
    inline for (SKIP) |s| {
        if (comptime std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

/// The public decls of a container type, or null if `T` is not a decl-bearing container.
fn declsOf(comptime T: type) ?[]const std.builtin.Type.Declaration {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.decls,
        .@"enum" => |e| e.decls,
        .@"union" => |u| u.decls,
        .@"opaque" => |o| o.decls,
        else => null,
    };
}

fn isContainer(comptime T: type) bool {
    return declsOf(T) != null;
}

/// Reflect one container, emitting a row per public decl. For a type decl, descend `descend`
/// levels — but only into types that are NOT themselves map containers: at the top level a
/// child container is in SKIP (it reflects itself); deeper, generic/alias internals are never
/// map containers, so they descend freely. `top` gates the SKIP check to direct children.
fn emit(w: *std.Io.Writer, comptime path: []const u8, comptime T: type, comptime descend: u8, comptime top: bool) !void {
    @setEvalBranchQuota(2_000_000); // big namespaces (std, os.linux) blow past the 1000 default
    const decls = comptime declsOf(T) orelse return;
    inline for (decls) |d| {
        const field = @field(T, d.name);
        const FT = @TypeOf(field);
        const child = path ++ "." ++ d.name;

        if (FT == type) {
            try w.print("{s}\ttype\t{s}\n", .{ child, @typeName(field) });
            const skip = top and comptime inSkip(d.name);
            if (descend > 0 and comptime isContainer(field) and !skip) {
                try emit(w, child, field, descend - 1, false);
            }
            continue;
        }
        switch (@typeInfo(FT)) {
            .int, .comptime_int => try w.print("{s}\tconst_int\t{d}\n", .{ child, field }),
            .bool => try w.print("{s}\tconst_bool\t{}\n", .{ child, field }),
            .@"fn" => try w.print("{s}\tfn\t{s}\n", .{ child, @typeName(FT) }),
            else => try w.print("{s}\tconst_other\t{s}\n", .{ child, @typeName(FT) }),
        }
    }
}

/// The target resolved to a VALUE, not a type — the map indexed an `@import`-realiased decl
/// (`pub const asin = @import("asin.zig").asin`, a fn) as a container, but the public access
/// lands on the value. Emit its one resolved fact (usually a fully-typed fn signature) rather
/// than treating a perfectly resolvable function as poison.
fn emitValue(w: *std.Io.Writer, comptime path: []const u8, val: anytype) !void {
    const VT = @TypeOf(val);
    switch (@typeInfo(VT)) {
        .int, .comptime_int => try w.print("{s}\tconst_int\t{d}\n", .{ path, val }),
        .bool => try w.print("{s}\tconst_bool\t{}\n", .{ path, val }),
        .@"fn" => try w.print("{s}\tfn\t{s}\n", .{ path, @typeName(VT) }),
        else => try w.print("{s}\tconst_other\t{s}\n", .{ path, @typeName(VT) }),
    }
}

pub fn main(init: std.process.Init) !void {
    var wbuf: [1 << 16]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &wbuf);
    const w = &fw.interface;

    try w.print("path\tkind\tdetail\n", .{});
    // comptime branch: a type reflects as a container; a value emits its single resolved fact.
    if (comptime @TypeOf(TARGET) == type) {
        try emit(w, TARGET_PATH, TARGET, DESCEND, true);
    } else {
        try emitValue(w, TARGET_PATH, TARGET);
    }
    try w.flush();
}
