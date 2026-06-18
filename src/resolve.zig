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

// ── rewritten per-container by scripts/build_depth.nu (matched by `const TARGET` prefix) ──
const TARGET_PATH = "std.crypto.hash.sha2";
const TARGET = @import("std").crypto.hash.sha2;
// ──────────────────────────────────────────────────────────────────────────────────────

/// How many levels of nested *type* decls to descend. 1 = the container's own decls plus,
/// for each type it declares, that type's scalar decls (so a hash namespace yields not just
/// `Sha256` but `Sha256.digest_length = 32`). Kept shallow on purpose: deeper descent both
/// explodes output and widens the poison surface of a single container.
const DESCEND: u8 = 1;

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

/// Reflect one container, emitting a row per public decl, recursing `descend` levels into
/// nested type decls. `path` is the logical map path of `T`.
fn emit(w: *std.Io.Writer, comptime path: []const u8, comptime T: type, comptime descend: u8) !void {
    const decls = comptime declsOf(T) orelse return;
    inline for (decls) |d| {
        const field = @field(T, d.name);
        const FT = @TypeOf(field);
        const child = path ++ "." ++ d.name;

        if (FT == type) {
            try w.print("{s}\ttype\t{s}\n", .{ child, @typeName(field) });
            if (descend > 0 and comptime isContainer(field)) {
                try emit(w, child, field, descend - 1);
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

pub fn main(init: std.process.Init) !void {
    var wbuf: [1 << 16]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &wbuf);
    const w = &fw.interface;

    try w.print("path\tkind\tdetail\n", .{});
    try emit(w, TARGET_PATH, TARGET, DESCEND);
    try w.flush();
}
