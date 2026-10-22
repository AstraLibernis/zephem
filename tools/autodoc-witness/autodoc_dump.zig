// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The autodoc witness (run by run.sh): a port of docs/comparison/autodoc_dump.zig to Zig 0.17.0.
//! Drives autodoc's own Walk.zig + Decl.zig (copied from the 0.17 install, allocator
//! patched to page_allocator) over lib/std and writes two TSVs:
//!   argv[2] all.tsv   : every decl the walker created (pub and priv)
//!     idx  parent  is_pub  name  fqn  cat  chased_cat  file  name_line  first_line
//!   argv[3] reach.tsv : the UI-reachable pub surface (BFS like the browser: namespace /
//!     container -> namespace_members, type_function -> type_fn_members, aliases chased)
//!     navpath  idx  fqn  cat  chased_cat  file:line  via(alias target idx or -)
//! argv[1] = std root directory.
const std = @import("std");
const Walk = @import("Walk.zig");
const Decl = Walk.Decl;
const Ast = std.zig.Ast;

const gpa = std.heap.page_allocator; // one-shot dump; everything lives until exit

/// Per-file newline offsets so token -> line is a binary search, not a rescan.
var line_starts: std.ArrayList([]u32) = .empty;

fn lineOf(file: Walk.File.Index, token: Ast.TokenIndex) u32 {
    const ast = file.get_ast();
    const off: u32 = ast.tokenStart(token);
    const starts = line_starts.items[@backingInt(file)];
    // number of line starts <= off
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (starts[mid] <= off) lo = mid + 1 else hi = mid;
    }
    return @intCast(lo); // 1-based line
}

fn nameToken(d: *const Decl) ?Ast.TokenIndex {
    const ast = d.file.get_ast();
    return switch (ast.nodeTag(d.ast_node)) {
        .root => null,
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => ast.fullVarDecl(d.ast_node).?.ast.mut_token + 1,
        .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple, .fn_decl => blk: {
            var buf: [1]Ast.Node.Index = undefined;
            break :blk ast.fullFnProto(&buf, d.ast_node).?.name_token;
        },
        else => null,
    };
}

fn chase(idx: u32) struct { cat: Walk.Category, tgt: u32 } {
    var tgt = idx;
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        const c = @as(Decl.Index, @fromBackingInt(tgt)).get().categorize();
        switch (c) {
            .alias => |a| {
                if (a == .none) return .{ .cat = c, .tgt = tgt };
                tgt = @backingInt(a);
            },
            else => return .{ .cat = c, .tgt = tgt },
        }
    }
    return .{ .cat = @as(Decl.Index, @fromBackingInt(tgt)).get().categorize(), .tgt = tgt };
}

fn relFile(d: *const Decl) []const u8 {
    const p = d.file.path();
    return if (std.mem.startsWith(u8, p, "std/")) p[4..] else p;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4 and args.len != 6) return error.Usage;
    const std_root = args[1];

    var std_std_file: ?Walk.File.Index = null;
    var dir = try std.Io.Dir.openDirAbsolute(io, std_root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var file_count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const raw = try dir.readFileAlloc(io, entry.path, gpa, .unlimited);
        var bytes = raw;
        if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') {
            bytes = try gpa.realloc(raw, raw.len + 1);
            bytes[bytes.len - 1] = '\n';
        }
        var starts: std.ArrayList(u32) = .empty;
        try starts.append(gpa, 0);
        for (bytes, 0..) |b, i| if (b == '\n') try starts.append(gpa, @intCast(i + 1));
        const name = try gpa.print("std/{s}", .{entry.path});
        const fidx = try Walk.add_file(name, bytes);
        std.debug.assert(@backingInt(fidx) == line_starts.items.len);
        try line_starts.append(gpa, starts.items);
        if (std.mem.eql(u8, entry.path, "std.zig")) std_std_file = fidx;
        file_count += 1;
    }

    const root_file = std_std_file orelse return error.NoStdRoot;
    try Walk.modules.put(gpa, "std", root_file);
    const root_decl = root_file.findRootDecl();

    // ---- all.tsv
    {
        var f = try std.Io.Dir.cwd().createFile(io, args[2], .{});
        defer f.close(io);
        var buf: [1 << 16]u8 = undefined;
        var fw = f.writerStreaming(io, &buf);
        const w = &fw.interface;
        var fq = std.ArrayList(u8).empty;
        for (Walk.decls.items, 0..) |*d, i| {
            fq.clearRetainingCapacity();
            try d.fqn(&fq);
            const c = chase(@intCast(i));
            const nt = nameToken(d);
            const ast = d.file.get_ast();
            const first_line: u32 = if (nt == null) 1 else lineOf(d.file, ast.firstToken(d.ast_node));
            const name_line: u32 = if (nt) |t| lineOf(d.file, t) else 1;
            const parent: i64 = if (d.parent == .none) -1 else @backingInt(d.parent);
            try w.print("{d}\t{d}\t{d}\t{s}\t{s}\t{s}\t{s}\t{s}\t{d}\t{d}\n", .{
                i,                       parent,                @intFromBool(d.is_pub()),     d.extra_info().name,
                fq.items,                @tagName(d.categorize()), @tagName(c.cat), relFile(d),
                name_line,               first_line,
            });
        }
        try w.flush();
    }

    // ---- reach.tsv: BFS like the browser
    var f = try std.Io.Dir.cwd().createFile(io, args[3], .{});
    defer f.close(io);
    var obuf: [1 << 16]u8 = undefined;
    var fw = f.writerStreaming(io, &obuf);
    const w = &fw.interface;

    const Item = struct { decl: Decl.Index, nav: []const u8 };
    var visited = std.AutoHashMap(u32, void).init(gpa);
    var queue = std.ArrayList(Item).empty;
    try queue.append(gpa, .{ .decl = root_decl, .nav = "std" });
    try visited.put(@backingInt(root_decl), {});

    var printed: usize = 0;
    var fq = std.ArrayList(u8).empty;
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const item = queue.items[qi];
        // UI: type_function -> type_fn_members (hops to a returned type fn)
        var parent = item.decl;
        if (parent.get().categorize() == .type_function) {
            if (parent.get().get_type_fn_return_type_fn()) |fd| parent = fd;
        }
        for (Walk.decls.items, 0..) |*decl, i| {
            if (decl.parent != parent) continue;
            if (!decl.is_pub()) continue;
            const nav = try gpa.print("{s}.{s}", .{ item.nav, decl.extra_info().name });
            fq.clearRetainingCapacity();
            try decl.fqn(&fq);
            const c = chase(@intCast(i));
            const nt = nameToken(decl);
            const line: u32 = if (nt) |t| lineOf(decl.file, t) else 1;
            const via_s = if (c.tgt != i) try gpa.print("{d}", .{c.tgt}) else "-";
            try w.print("{s}\t{d}\t{s}\t{s}\t{s}\t{s}:{d}\t{s}\n", .{
                nav, i, fq.items, @tagName(decl.categorize()), @tagName(c.cat), relFile(decl), line, via_s,
            });
            printed += 1;
            const expandable = switch (c.cat) {
                .namespace, .container, .type_function => true,
                else => false,
            };
            if (expandable and !visited.contains(c.tgt)) {
                try visited.put(c.tgt, {});
                try queue.append(gpa, .{ .decl = @fromBackingInt(c.tgt), .nav = nav });
            }
        }
    }
    try w.flush();

    // ---- optional find mode: resolve each input path (one per line) with autodoc's lookup
    if (args.len == 6) {
        const input = try std.Io.Dir.cwd().readFileAlloc(io, args[4], gpa, .unlimited);
        var of = try std.Io.Dir.cwd().createFile(io, args[5], .{});
        defer of.close(io);
        var fbuf: [1 << 16]u8 = undefined;
        var ofw = of.writerStreaming(io, &fbuf);
        const ow = &ofw.interface;
        var lines = std.mem.splitScalar(u8, input, '\n');
        while (lines.next()) |p| {
            if (p.len == 0) continue;
            const r = findPath(p);
            if (r.idx == .none) {
                try ow.print("{s}\t-\t-\t-\t-\t-\t-\n", .{p});
                continue;
            }
            const d = r.idx.get();
            const nt = nameToken(d);
            const line: u32 = if (nt) |t| lineOf(d.file, t) else 1;
            const c = chase(@backingInt(r.idx));
            const cd = @as(Decl.Index, @fromBackingInt(c.tgt)).get();
            const cline: u32 = if (nameToken(cd)) |t| lineOf(cd.file, t) else 1;
            try ow.print("{s}\t{d}\t{s}:{d}\t{s}\t{d}\t{s}:{d}\t{s}\n", .{ p, @backingInt(r.idx), relFile(d), line, @tagName(d.categorize()), @intFromBool(r.all_pub), relFile(cd), cline, @tagName(c.cat) });
        }
        try ow.flush();
    }
    std.debug.print("# files={d} reach_rows={d} expanded={d} total_decls={d}\n", .{ file_count, printed, queue.items.len, Walk.decls.items.len });
}

/// Splits a dotted path, keeping `@"..."` segments (which may contain dots) whole.
fn nextComponent(s: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= s.len) return null;
    const start = pos.*;
    var i = start;
    var in_q = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_q) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') in_q = false;
        } else if (c == '"') {
            in_q = true;
        } else if (c == '.') break;
    }
    pos.* = i + 1;
    return s[start..i];
}

/// autodoc's Decl.find, plus the UI's type-fn hop and a pub check per step.
/// Returns the decl index and whether every step was a pub decl.
fn findPath(path: []const u8) struct { idx: Decl.Index, all_pub: bool } {
    var pos: usize = 0;
    const first = nextComponent(path, &pos) orelse return .{ .idx = .none, .all_pub = false };
    const file = Walk.modules.get(first) orelse return .{ .idx = .none, .all_pub = false };
    var cur = file.findRootDecl();
    var all_pub = true;
    while (nextComponent(path, &pos)) |comp_raw| {
        const comp = if (std.mem.endsWith(u8, comp_raw, "()")) comp_raw[0 .. comp_raw.len - 2] else comp_raw;
        while (true) switch (cur.get().categorize()) {
            .alias => |a| {
                if (a == .none) break;
                cur = a;
            },
            else => break,
        };
        var next = cur.get().get_child(comp);
        if (next == null and cur.get().categorize() == .type_function) {
            if (cur.get().get_type_fn_return_type_fn()) |fd| next = fd.get().get_child(comp);
        }
        cur = next orelse return .{ .idx = .none, .all_pub = false };
        if (!cur.get().is_pub()) all_pub = false;
    }
    return .{ .idx = cur, .all_pub = all_pub };
}
