//! tunnels.zig — the L3 (reference graph) resolver.
//!
//! Where the map (scan.zig) records WHERE every public decl is, tunnels records WHAT LINKS TO
//! WHAT — resolving a referenced name to the canonical logical `path` it points at, so the link
//! is followable (one O(1) jump via the index), not just a name. Three edge kinds:
//!
//!   alias   a re-export `pub const X = a.b.C`         (from the map's `alias` detail)
//!   import  a whole-file / selective import binding   (nsref + import-bearing aliases)
//!   usage   a type referenced in a fn signature        (param / return type chains)
//!
//! Output (one tagged stream; build_tunnels.nu splits + attaches to_line + verifies):
//!
//!   from_path · kind · status · to_or_raw · reason
//!     status=resolved   to_or_raw = the canonical to_path (guaranteed present in the map)
//!     status=primitive  to_or_raw = the primitive name (u8, void, …) — resolvable-by-design to nothing
//!     status=unresolved to_or_raw = the raw reference, reason = why it could not be resolved
//!
//! SOUND, not complete: an edge is emitted resolved ONLY when the target path actually exists in
//! nodes.tsv; everything else is recorded explicitly (never silently dropped), so resolved +
//! unresolved partition every reference attempted. Completeness can grow later without ever
//! emitting a dangling edge.
//!
//! The map is PUBLIC-ONLY, but Zig name resolution leans on private file-level import bindings
//! (`const Allocator = std.mem.Allocator;`). So we parse each file's root for ALL bindings (pub
//! and private) into a per-file symbol table, and resolve names against that + the map.
//!
//! Run: zig run src/tunnels.zig -- <root.zig> <nodes.tsv>

const std = @import("std");
const Ast = std.zig.Ast;

const MAX_FOLLOW = 16; // alias/name_ref recursion guard

// ── what a file-root binding points at (the per-file symbol table value) ──
const Target = union(enum) {
    defined, // a definition (fn / container / value) lives at <this file>.<name>
    self, // `const Ast = @This();` — names the file's own root type, not a child
    import_whole: []const u8, // `@import("f.zig")` — std-relative target file
    import_sel: struct { file: []const u8, sel: []const u8 }, // `@import("f.zig").sel`
    import_mod: []const u8, // `@import("builtin")` etc. — a module we don't own
    name_ref: []const u8, // `= a.b.c` — another dotted chain to resolve in this file's scope
};

const Ctx = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    paths: *std.StringHashMap(void), // every logical path in the map (existence oracle)
    file2path: *std.StringHashMap([]const u8), // std-relative file → its canonical logical path
    nspath2file: *std.StringHashMap([]const u8), // ns logical path → its std-relative file
    files: *std.StringHashMap(*std.StringHashMap(Target)), // std-rel file → symbol table (lazy)
};

fn dirname(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[0..i];
    return ".";
}

fn relPath(ctx: *Ctx, abs: []const u8) []const u8 {
    if (abs.len > ctx.root_dir.len and std.mem.startsWith(u8, abs, ctx.root_dir) and abs[ctx.root_dir.len] == '/')
        return abs[ctx.root_dir.len + 1 ..];
    return abs;
}

/// Built-in scalar types resolve to nothing in the map — record them as `primitive`, not failure.
fn isPrimitive(s: []const u8) bool {
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

fn isAliasChain(s: []const u8) bool {
    if (s.len == 0) return false;
    var expect_start = true;
    for (s) |c| {
        if (expect_start) {
            if (!(std.ascii.isAlphabetic(c) or c == '_')) return false;
            expect_start = false;
        } else if (c == '.') {
            expect_start = true;
        } else if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
            return false;
        }
    }
    return !expect_start;
}

const ImportRef = struct { file: []const u8, selector: []const u8 };

fn parseImport(src: []const u8) ?ImportRef {
    const t = std.mem.trim(u8, src, " \t\r\n");
    const prefix = "@import(\"";
    if (!std.mem.startsWith(u8, t, prefix)) return null;
    const after_q = t[prefix.len..];
    const qend = std.mem.indexOfScalar(u8, after_q, '"') orelse return null;
    const file = after_q[0..qend];
    var rest = std.mem.trim(u8, after_q[qend + 1 ..], " \t\r\n");
    if (!std.mem.startsWith(u8, rest, ")")) return null;
    rest = std.mem.trim(u8, rest[1..], " \t\r\n");
    if (rest.len == 0) return .{ .file = file, .selector = "" };
    if (rest[0] != '.') return null;
    const sel = std.mem.trim(u8, rest[1..], " \t\r\n");
    if (sel.len == 0 or !isAliasChain(sel)) return null;
    return .{ .file = file, .selector = sel };
}

fn parseFile(ctx: *Ctx, abs: []const u8) !?Ast {
    const src = std.Io.Dir.cwd().readFileAllocOptions(ctx.io, abs, ctx.arena, .unlimited, .of(u8), 0) catch return null;
    return try Ast.parse(ctx.arena, src, .zig);
}

/// Parse `file`'s root decls into a symbol table (name → Target), capturing pub AND private
/// bindings. Cached; returns null if the file can't be read/parsed.
fn symsOf(ctx: *Ctx, file: []const u8) !?*std.StringHashMap(Target) {
    if (ctx.files.get(file)) |s| return s;
    const abs = try std.fs.path.resolve(ctx.arena, &.{ ctx.root_dir, file });
    const ast = (try parseFile(ctx, abs)) orelse return null;
    const a = try ctx.arena.create(Ast);
    a.* = ast;
    const dir = dirname(abs);

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
        if (parseImport(src)) |imp| {
            if (!std.mem.endsWith(u8, imp.file, ".zig")) {
                try tbl.put(name, .{ .import_mod = try ctx.arena.dupe(u8, imp.file) });
            } else {
                const tabs = try std.fs.path.resolve(ctx.arena, &.{ dir, imp.file });
                const trel = try ctx.arena.dupe(u8, relPath(ctx, tabs));
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
        } else if (isAliasChain(trimmed)) {
            try tbl.put(name, .{ .name_ref = try ctx.arena.dupe(u8, trimmed) });
        } else {
            try tbl.put(name, .defined); // a value defined here
        }
    }
    return tbl;
}

const Res = union(enum) {
    resolved: []const u8, // lands on a public node — a real edge
    primitive: []const u8, // a built-in (u8, void) — resolves to nothing by design
    internal: []const u8, // traced to a concrete target that lives behind the pub boundary
    unresolved: []const u8, // reason — couldn't trace it at all (a real gap)
};

fn has(ctx: *Ctx, path: []const u8) bool {
    return ctx.paths.contains(path);
}

/// Resolve a dotted chain used inside `file` to a canonical map path.
fn resolve(ctx: *Ctx, file: []const u8, chain: []const u8, depth: u8) anyerror!Res {
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
fn fileOf(ctx: *Ctx, path: []const u8) ?[]const u8 {
    var p = path;
    while (true) {
        if (ctx.nspath2file.get(p)) |f| return f;
        const i = std.mem.lastIndexOfScalar(u8, p, '.') orelse return null;
        p = p[0..i];
    }
}

fn emitEdge(w: *std.Io.Writer, from: []const u8, kind: []const u8, r: Res, raw: []const u8) !void {
    switch (r) {
        .resolved => |to| try w.print("{s}\t{s}\tresolved\t{s}\t\n", .{ from, kind, to }),
        .primitive => |p| try w.print("{s}\t{s}\tprimitive\t{s}\t\n", .{ from, kind, p }),
        .internal => |t| try w.print("{s}\t{s}\tinternal\t{s}\t{s}\n", .{ from, kind, raw, t }),
        .unresolved => |why| try w.print("{s}\t{s}\tunresolved\t{s}\t{s}\n", .{ from, kind, raw, why }),
    }
}

/// Extract dotted-identifier chains from a type-expression source slice, resolving + emitting
/// each as a `usage` edge. `@This()`/`@import(...)` and the like are skipped (handled elsewhere
/// or not references); a chain starting with `@` is a builtin call, not a type name.
fn emitTypeRefs(ctx: *Ctx, w: *std.Io.Writer, from: []const u8, file: []const u8, expr: []const u8) !void {
    var i: usize = 0;
    while (i < expr.len) {
        const c = expr[i];
        // a chain starts at an identifier-start not preceded by '.' or '@' or an ident char
        if ((std.ascii.isAlphabetic(c) or c == '_')) {
            const prev = if (i == 0) 0 else expr[i - 1];
            if (prev == '.' or prev == '@' or std.ascii.isAlphanumeric(prev) or prev == '_') {
                i += 1;
                continue;
            }
            var j = i;
            while (j < expr.len and (std.ascii.isAlphanumeric(expr[j]) or expr[j] == '_' or expr[j] == '.')) j += 1;
            var chain = expr[i..j];
            while (chain.len > 0 and chain[chain.len - 1] == '.') chain = chain[0 .. chain.len - 1];
            i = j;
            if (chain.len == 0) continue;
            // skip Zig keywords that can appear in type position
            if (std.mem.eql(u8, chain, "anytype") or std.mem.eql(u8, chain, "comptime") or
                std.mem.eql(u8, chain, "type")) {
                if (isPrimitive(chain)) try emitEdge(w, from, "usage", .{ .primitive = chain }, chain);
                continue;
            }
            const r = try resolve(ctx, file, chain, 0);
            try emitEdge(w, from, "usage", r, chain);
        } else i += 1;
    }
}

/// Walk a file's public fns and emit usage edges for their param + return type expressions.
fn walkUsage(ctx: *Ctx, w: *std.Io.Writer, file: []const u8) !void {
    const logical = ctx.file2path.get(file) orelse return;
    const tbl = (try symsOf(ctx, file)) orelse return; // ensures parsed
    _ = tbl;
    const abs = try std.fs.path.resolve(ctx.arena, &.{ ctx.root_dir, file });
    const ast = (try parseFile(ctx, abs)) orelse return;
    var a = ast;
    for (a.rootDecls()) |m| {
        if (a.nodeTag(m) != .fn_decl) continue;
        var b: [1]Ast.Node.Index = undefined;
        const proto = a.fullFnProto(&b, m) orelse continue;
        if (proto.visib_token == null) continue;
        const nt = proto.name_token orelse continue;
        const fname = a.tokenSlice(nt);
        const from = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ logical, fname });
        if (!has(ctx, from)) continue; // only emit from decls the map actually has
        var pit = proto.iterate(&a);
        while (pit.next()) |param| {
            if (param.type_expr) |te| try emitTypeRefs(ctx, w, from, file, a.getNodeSource(te));
        }
        if (proto.ast.return_type.unwrap()) |rt| try emitTypeRefs(ctx, w, from, file, a.getNodeSource(rt));
    }
}

fn col(line: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var rest = line;
    while (i < n) : (i += 1) {
        const t = std.mem.indexOfScalar(u8, rest, '\t') orelse return "";
        rest = rest[t + 1 ..];
    }
    const end = std.mem.indexOfScalar(u8, rest, '\t') orelse rest.len;
    return rest[0..end];
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return error.Usage;
    const root_path = args[1];
    const nodes_path = args[2];
    const root_dir = dirname(root_path);

    var wbuf: [1 << 16]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &wbuf);
    const w = &fw.interface;

    var paths = std.StringHashMap(void).init(arena);
    var file2path = std.StringHashMap([]const u8).init(arena);
    var nspath2file = std.StringHashMap([]const u8).init(arena);
    var files = std.StringHashMap(*std.StringHashMap(Target)).init(arena);
    var ctx = Ctx{ .arena = arena, .io = init.io, .root_dir = root_dir, .paths = &paths, .file2path = &file2path, .nspath2file = &nspath2file, .files = &files };

    // ── load the map ──
    const nodes_src = try std.Io.Dir.cwd().readFileAllocOptions(init.io, nodes_path, arena, .unlimited, .of(u8), 0);
    var aliases: std.ArrayList(struct { path: []const u8, detail: []const u8 }) = .empty;
    var lines = std.mem.splitScalar(u8, nodes_src, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const path = col(line, 0);
        const kind = col(line, 2);
        const detail = col(line, 5);
        try paths.put(path, {});
        if (std.mem.eql(u8, kind, "ns")) {
            try file2path.put(detail, path);
            try nspath2file.put(path, detail);
        }
        if (std.mem.eql(u8, kind, "alias")) {
            try aliases.append(arena, .{ .path = path, .detail = detail });
        }
        if (std.mem.eql(u8, kind, "nsref")) {
            // import tunnel: → the canonical ns expanded for this file (resolved in pass 2)
            try aliases.append(arena, .{ .path = path, .detail = try std.fmt.allocPrint(arena, "\x00nsref\x00{s}", .{detail}) });
        }
    }

    try w.print("from_path\tkind\tstatus\tto_or_raw\treason\n", .{});

    // ── alias + import tunnels (from the map) ──
    for (aliases.items) |al| {
        // nsref import tunnel: resolve the file to its canonical ns path directly.
        if (std.mem.startsWith(u8, al.detail, "\x00nsref\x00")) {
            const f = al.detail["\x00nsref\x00".len..];
            const r: Res = if (file2path.get(f)) |p| .{ .resolved = p } else .{ .unresolved = "nsref target file not expanded" };
            try emitEdge(w, al.path, "import", r, f);
            continue;
        }
        // an alias whose detail is a FILE path (reexport leftover) → import; else a name chain.
        const file = fileOf(&ctx, al.path) orelse {
            try emitEdge(w, al.path, "alias", .{ .unresolved = "no enclosing file" }, al.detail);
            continue;
        };
        if (std.mem.endsWith(u8, al.detail, ".zig") or std.mem.indexOfScalar(u8, al.detail, '/') != null) {
            // reexport leftover: target = <ns of that file>.<own name>
            const lastdot = std.mem.lastIndexOfScalar(u8, al.path, '.') orelse 0;
            const name = al.path[lastdot + 1 ..];
            const r: Res = if (file2path.get(al.detail)) |p| blk: {
                const cand = try std.fmt.allocPrint(arena, "{s}.{s}", .{ p, name });
                break :blk if (has(&ctx, cand)) .{ .resolved = cand } else .{ .unresolved = "selector not a member of target file" };
            } else .{ .internal = try std.fmt.allocPrint(arena, "private import '{s}'", .{al.detail}) };
            try emitEdge(w, al.path, "import", r, al.detail);
            continue;
        }
        const r = try resolve(&ctx, file, al.detail, 0);
        try emitEdge(w, al.path, "alias", r, al.detail);
    }

    // ── usage edges (from fn signatures, per file) ──
    var fit = file2path.keyIterator();
    while (fit.next()) |f| try walkUsage(&ctx, w, f.*);

    try w.flush();
}
