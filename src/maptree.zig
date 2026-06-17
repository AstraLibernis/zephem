//! maptree.zig — a faithful structural map of std.crypto. No interpretation.
//!
//! Walks the public namespace tree and, at every container (struct/enum/union),
//! records WHAT KIND it is and EXACT COUNTS — total decls, and how many are
//! sub-types / functions / other consts, plus field count. It does NOT decide
//! whether anything is a "primitive" or "builder" or "math". That judgment comes
//! later, over the complete map. This is just the territory.
//!
//! Output: TSV  path · depth · typekind · n_decls · n_fields · n_types · n_fns · n_consts
//! One row per container; dotted path encodes the tree. Python nests it into JSON.
//!
//! Run: zig run src/maptree.zig -- <max_depth>   (default 6)

const std = @import("std");
const crypto = std.crypto;

const MAX_DEPTH = 6;

// Containers we record but do not DESCEND into: protocol/encoding plumbing whose
// decls cannot be evaluated by reflection (`@field` triggers real compile errors
// in the ASN.1/DER/TLS writer machinery). They are mapped as leaves, not expanded.
const no_descend = [_][]const u8{ "codecs", "tls", "Certificate", "der", "asn1" };

fn noDescend(comptime name: []const u8) bool {
    inline for (no_descend) |s| if (comptime std.mem.eql(u8, name, s)) return true;
    return false;
}

fn fieldCount(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.fields.len,
        .@"enum" => |e| e.fields.len,
        .@"union" => |u| u.fields.len,
        else => 0,
    };
}

fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
}

fn walk(w: anytype, comptime path: []const u8, comptime T: type, comptime depth: u8) !void {
    const ti = @typeInfo(T);
    const decls = switch (ti) {
        .@"struct" => |s| s.decls,
        .@"enum" => |e| e.decls,
        .@"union" => |u| u.decls,
        .@"opaque" => |o| o.decls,
        else => return,
    };

    comptime var n_types: usize = 0;
    comptime var n_fns: usize = 0;
    comptime var n_consts: usize = 0;
    inline for (decls) |d| {
        const VT = @TypeOf(@field(T, d.name));
        if (VT == type) {
            n_types += 1;
        } else switch (@typeInfo(VT)) {
            .@"fn" => n_fns += 1,
            else => n_consts += 1,
        }
    }

    try w.print("{s}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        path, depth, @tagName(ti), decls.len, fieldCount(T), n_types, n_fns, n_consts,
    });

    if (depth >= MAX_DEPTH) return;
    inline for (decls) |d| {
        if (comptime noDescend(d.name)) continue;
        const v = @field(T, d.name);
        if (@TypeOf(v) == type and comptime isContainer(v)) {
            // guard against a type re-declaring itself (direct self-reference)
            if (comptime !std.mem.eql(u8, @typeName(v), @typeName(T))) {
                try walk(w, path ++ "." ++ d.name, v, depth + 1);
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var wbuf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &wbuf);
    const w = &fw.interface;
    try w.print("path\tdepth\tkind\tn_decls\tn_fields\tn_types\tn_fns\tn_consts\n", .{});
    try walk(w, "crypto", crypto, 0);
    try w.flush();
}
