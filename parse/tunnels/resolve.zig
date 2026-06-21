//! tunnels/resolve.zig — the L3 resolver core: per-file symbol tables + chain resolution.
//!
//! The map is PUBLIC-ONLY, but Zig name resolution leans on private file-level import
//! bindings (`const Allocator = std.mem.Allocator;`). So `symsOf` parses each file's root
//! for ALL bindings (pub and private) into a per-file symbol table, and `resolve` traces a
//! dotted chain used inside a file against that table + the public map.
//!
//! SOUND, not complete: `resolve` returns `resolved` ONLY when the target path actually
//! exists in the map; a traced-but-private target is `internal`, a built-in is `primitive`,
//! and anything untraceable is `unresolved` (with a reason). Nothing is silently dropped.

const std = @import("std");
const Ast = std.zig.Ast;
const astu = @import("../common/ast.zig");
const fs = @import("../common/fs.zig");

const MAX_FOLLOW = 16; // alias/name_ref recursion guard

/// What a file-root binding points at (the per-file symbol table value).
pub const Target = union(enum) {
    defined, // a definition (fn / container / value) lives at <this file>.<name>
    self, // `const Ast = @This();` — names the file's own root type, not a child
    import_whole: []const u8, // `@import("f.zig")` — std-relative target file
    import_sel: struct { file: []const u8, sel: []const u8 }, // `@import("f.zig").sel`
    import_mod: []const u8, // `@import("builtin")` etc. — a module we don't own
    name_ref: []const u8, // `= a.b.c` — another dotted chain to resolve in this file's scope
};

pub const Ctx = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    paths: *std.StringHashMap(void), // every logical path in the map (existence oracle)
    file2path: *std.StringHashMap([]const u8), // std-relative file → its canonical logical path
    nspath2file: *std.StringHashMap([]const u8), // ns logical path → its std-relative file
    files: *std.StringHashMap(*std.StringHashMap(Target)), // std-rel file → symbol table (lazy)
};

/// Built-in scalar types resolve to nothing in the map — record them as `primitive`.
pub fn isPrimitive(s: []const u8) bool {
    const named = [_][]const u8{
        "void", "bool", "type", "anytype", "anyerror", "anyopaque", "noreturn",
        "comptime_int", "comptime_float", "f16", "f32", "f64", "f80", "f128",
        "isize", "usize", "c_char", "c_short", "c_ushort", "c_int", "c_uint",
        "c_long", "c_ulong", "c_longlong", "c_ulonglong", "c_longdouble",
    };
    for (named) |n| if (std.mem.eql(u8, s, n)) return true;
    // uN / iN integer types
    if (s.len >= 2 and (s[0] == 'u' or s[0] == 'i')) {
        for (s[1..]) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }
    return false;
}

pub fn has(ctx: *Ctx, path: []const u8) bool {
    return ctx.paths.contains(path);
}

/// Parse `file`'s root decls into a symbol table (name → Target), capturing pub AND private
/// bindings. Cached; returns null if the file can't be read/parsed.
pub fn symsOf(ctx: *Ctx, file: []const u8) !?*std.StringHashMap(Target) {
    if (ctx.files.get(file)) |s| return s;
    const abs = try std.fs.path.resolve(ctx.arena, &.{ ctx.root_dir, file });
    const ast = (try fs.parseFile(ctx.io, ctx.arena, abs)) orelse return null;
    const a = try ctx.arena.create(Ast);
    a.* = ast;
    const dir = fs.dirname(abs);

    const tbl = try ctx.arena.create(std.StringHashMap(Target));
    tbl.* = std.StringHashMap(Target).init(ctx.arena);
    try ctx.files.put(try ctx.arena.dupe(u8, file), tbl);

    for (a.rootDecls()) |m| {
        if (a.nodeTag(m) == .fn_decl) {
            var b: [1]Ast.Node.Index = undefined;
            const proto = a.fullFnProto(&b, m) orelse continue;
            const nt = proto.name_token orelse continue;
            try tbl.put(a.tokenSlice(nt), .defined);
            continue;
        }
        const vd = a.fullVarDecl(m) orelse continue;
        const name = a.tokenSlice(vd.ast.mut_token + 1);
        const init = vd.ast.init_node.unwrap() orelse {
            try tbl.put(name, .defined);
            continue;
        };
        const src = a.getNodeSource(init);
        if (astu.parseImport(src)) |imp| {
            if (!std.mem.endsWith(u8, imp.file, ".zig")) {
                try tbl.put(name, .{ .import_mod = try ctx.arena.dupe(u8, imp.file) });
            } else {
                const tabs = try std.fs.path.resolve(ctx.arena, &.{ dir, imp.file });
                const trel = try ctx.arena.dupe(u8, fs.relPath(ctx.root_dir, tabs));
                if (imp.selector.len == 0) {
                    try tbl.put(name, .{ .import_whole = trel });
                } else {
                    try tbl.put(name, .{ .import_sel = .{ .file = trel, .sel = try ctx.arena.dupe(u8, imp.selector) } });
                }
            }
            continue;
        }
        const trimmed = std.mem.trim(u8, src, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "@This")) {
            try tbl.put(name, .self); // self-alias: names this file's own root type
        } else if (astu.isAliasChain(trimmed)) {
            try tbl.put(name, .{ .name_ref = try ctx.arena.dupe(u8, trimmed) });
        } else {
            try tbl.put(name, .defined); // a value defined here
        }
    }
    return tbl;
}

pub const Res = union(enum) {
    resolved: []const u8, // lands on a public node — a real edge
    primitive: []const u8, // a built-in (u8, void) — resolves to nothing by design
    internal: []const u8, // traced to a concrete target that lives behind the pub boundary
    unresolved: []const u8, // reason — couldn't trace it at all (a real gap)
};

/// Resolve a dotted chain used inside `file` to a canonical map path.
pub fn resolve(ctx: *Ctx, file: []const u8, chain: []const u8, depth: u8) anyerror!Res {
    if (depth > MAX_FOLLOW) return .{ .unresolved = "alias chain too deep" };
    const dot = std.mem.indexOfScalar(u8, chain, '.');
    const head = if (dot) |i| chain[0..i] else chain;
    const rest = if (dot) |i| chain[i + 1 ..] else "";

    if (rest.len == 0 and isPrimitive(head)) return .{ .primitive = head };

    // resolve the head to a base path. `traced` = base names a concrete source entity (a real
    // decl / file), so if it isn't in the public map it's private — an `internal` link, not a gap.
    var base: []const u8 = undefined;
    var traced = false;
    if (std.mem.eql(u8, head, "std")) {
        base = "std";
    } else if (try symsOf(ctx, file)) |tbl| {
        if (tbl.get(head)) |t| {
            switch (t) {
                .defined => {
                    const p = ctx.file2path.get(file) orelse return .{ .unresolved = "file not in map" };
                    base = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ p, head });
                    traced = true;
                },
                .self => {
                    base = ctx.file2path.get(file) orelse return .{ .unresolved = "file not in map" };
                    traced = true;
                },
                // a whole-file import whose target isn't mapped = a private per-OS/internal file.
                .import_whole => |f| base = ctx.file2path.get(f) orelse return .{ .internal = try std.fmt.allocPrint(ctx.arena, "private import '{s}'", .{f}) },
                .import_sel => |s| {
                    const p = ctx.file2path.get(s.file) orelse return .{ .internal = try std.fmt.allocPrint(ctx.arena, "private import '{s}'", .{s.file}) };
                    base = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ p, s.sel });
                    traced = true;
                },
                .import_mod => |m| return .{ .unresolved = try std.fmt.allocPrint(ctx.arena, "external module '{s}'", .{m}) },
                .name_ref => |c2| {
                    // resolve the binding's own chain, then continue with our rest below
                    const r = try resolve(ctx, file, c2, depth + 1);
                    switch (r) {
                        .resolved => |p| base = p,
                        else => return r, // internal / primitive / unresolved propagates
                    }
                },
            }
        } else {
            return .{ .unresolved = "name not in scope" };
        }
    } else {
        return .{ .unresolved = "file not parseable" };
    }

    if (!has(ctx, base)) {
        // traced to a real decl that isn't public → it lives behind the pub boundary.
        if (traced) return .{ .internal = base };
        return .{ .unresolved = try std.fmt.allocPrint(ctx.arena, "head path '{s}' not in map", .{base}) };
    }
    if (rest.len == 0) return .{ .resolved = base };

    // walk the remaining segments as direct children
    var cur = base;
    var it = std.mem.splitScalar(u8, rest, '.');
    while (it.next()) |seg| {
        const cand = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ cur, seg });
        if (!has(ctx, cand)) return .{ .unresolved = try std.fmt.allocPrint(ctx.arena, "'{s}' not a member of '{s}'", .{ seg, cur }) };
        cur = cand;
    }
    return .{ .resolved = cur };
}

/// The std-relative file a logical path physically lives in = its nearest ns ancestor's file.
pub fn fileOf(ctx: *Ctx, path: []const u8) ?[]const u8 {
    var p = path;
    while (true) {
        if (ctx.nspath2file.get(p)) |f| return f;
        const i = std.mem.lastIndexOfScalar(u8, p, '.') orelse return null;
        p = p[0..i];
    }
}
