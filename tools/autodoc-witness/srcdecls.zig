// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Independent source-level lister (does not share code with zephem or autodoc).
//! For every .zig file under argv[1], parses with std.zig.Ast and prints every member
//! declaration of every container (file root and every struct/enum/union/opaque literal
//! anywhere in the file):
//!   file  line  name  pub(0/1)  kind(const|var|fn)  ctx  inner_path
//! ctx = chain of how each enclosing container is reached, root first, e.g.
//!   "root", "root/direct", "root/fn_body", "root/field_type", "root/test", "root/in_init".
//! inner_path = dotted member names from the file root (enclosing decl/field names).
const std = @import("std");
const Ast = std.zig.Ast;

const gpa = std.heap.page_allocator; // one-shot tool, freed at exit

const Member = struct {
    node: Ast.Node.Index,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    container: u32, // index into containers
};

const Container = struct {
    node: Ast.Node.Index,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    parent_member: ?u32 = null, // index into members
    label: []const u8 = "root",
};

fn isContainerTag(t: Ast.Node.Tag) bool {
    return switch (t) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        => true,
        else => false,
    };
}

fn memberName(ast: *const Ast, m: Ast.Node.Index) []const u8 {
    switch (ast.nodeTag(m)) {
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
            return ast.tokenSlice(ast.fullVarDecl(m).?.ast.mut_token + 1);
        },
        .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple, .fn_decl => {
            var buf: [1]Ast.Node.Index = undefined;
            const p = ast.fullFnProto(&buf, m).?;
            return if (p.name_token) |t| ast.tokenSlice(t) else "<anon>";
        },
        .container_field_init, .container_field_align, .container_field => {
            return ast.tokenSlice(ast.fullContainerField(m).?.ast.main_token);
        },
        .test_decl => return "<test>",
        .@"comptime" => return "<comptime>",
        else => return "<?>",
    }
}

fn innerPath(ast: *const Ast, cs: []const Container, ms: []const Member, ci: u32, out: *std.ArrayList(u8)) !void {
    const c = cs[ci];
    if (c.parent_member) |pm| {
        try innerPath(ast, cs, ms, ms[pm].container, out);
        if (out.items.len != 0) try out.append(gpa, '.');
        try out.appendSlice(gpa, memberName(ast, ms[pm].node));
    }
}

fn ctxChain(cs: []const Container, ms: []const Member, ci: u32, out: *std.ArrayList(u8)) !void {
    const c = cs[ci];
    if (c.parent_member) |pm| {
        try ctxChain(cs, ms, ms[pm].container, out);
        try out.append(gpa, '/');
    }
    try out.appendSlice(gpa, c.label);
}

fn processFile(w: *std.Io.Writer, rel: []const u8, src: [:0]const u8) !void {
    var ast = try Ast.parse(gpa, src, .{});
    defer ast.deinit(gpa);
    if (ast.errors.len != 0) {
        std.debug.print("parse error: {s}\n", .{rel});
        return;
    }
    var cs: std.ArrayList(Container) = .empty;
    var ms: std.ArrayList(Member) = .empty;
    // root container
    try cs.append(gpa, .{ .node = .root, .first = 0, .last = @intCast(ast.tokens.len - 1) });
    var i: u32 = 1;
    while (i < ast.nodes.len) : (i += 1) {
        const n: Ast.Node.Index = @enumFromInt(i);
        if (!isContainerTag(ast.nodeTag(n))) continue;
        try cs.append(gpa, .{ .node = n, .first = ast.firstToken(n), .last = ast.lastToken(n) });
    }
    // members of every container
    for (cs.items, 0..) |c, ci| {
        var buf: [2]Ast.Node.Index = undefined;
        const members = if (c.node == .root) ast.rootDecls() else ast.fullContainerDecl(&buf, c.node).?.ast.members;
        for (members) |m| {
            try ms.append(gpa, .{ .node = m, .first = ast.firstToken(m), .last = ast.lastToken(m), .container = @intCast(ci) });
        }
    }
    // innermost enclosing member for each non-root container
    for (cs.items[1..]) |*c| {
        var best: ?u32 = null;
        var best_span: u32 = std.math.maxInt(u32);
        for (ms.items, 0..) |m, mi| {
            if (m.first <= c.first and m.last >= c.last) {
                const span = m.last - m.first;
                if (span < best_span) {
                    best_span = span;
                    best = @intCast(mi);
                }
            }
        }
        c.parent_member = best;
        const pm = best orelse {
            c.label = "orphan";
            continue;
        };
        const m = ms.items[pm].node;
        c.label = switch (ast.nodeTag(m)) {
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => blk: {
                const vd = ast.fullVarDecl(m).?;
                if (vd.ast.init_node.unwrap()) |init_n| {
                    if (init_n == c.node) break :blk "direct";
                }
                break :blk "in_init";
            },
            .fn_decl => "fn_body",
            .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => "fn_proto",
            .container_field_init, .container_field_align, .container_field => "field_type",
            .test_decl => "test",
            .@"comptime" => "comptime",
            else => "other",
        };
    }
    var ctx: std.ArrayList(u8) = .empty;
    defer ctx.deinit(gpa);
    var ip: std.ArrayList(u8) = .empty;
    defer ip.deinit(gpa);
    for (ms.items) |m| {
        const tag = ast.nodeTag(m.node);
        const kind: []const u8, const is_pub: bool, const name_tok: Ast.TokenIndex = switch (tag) {
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => blk: {
                const vd = ast.fullVarDecl(m.node).?;
                const k: []const u8 = if (ast.tokenTag(vd.ast.mut_token) == .keyword_var) "var" else "const";
                break :blk .{ k, vd.visib_token != null, vd.ast.mut_token + 1 };
            },
            .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple, .fn_decl => blk: {
                var buf: [1]Ast.Node.Index = undefined;
                const p = ast.fullFnProto(&buf, m.node).?;
                break :blk .{ "fn", p.visib_token != null, p.name_token orelse continue };
            },
            else => continue,
        };
        ctx.clearRetainingCapacity();
        ip.clearRetainingCapacity();
        try ctxChain(cs.items, ms.items, m.container, &ctx);
        try innerPath(&ast, cs.items, ms.items, m.container, &ip);
        const line = ast.tokenLocation(0, name_tok).line + 1;
        try w.print("{s}\t{d}\t{s}\t{d}\t{s}\t{s}\t{s}\n", .{ rel, line, ast.tokenSlice(name_tok), @intFromBool(is_pub), kind, ctx.items, ip.items });
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    var dir = try std.Io.Dir.openDirAbsolute(io, args[1], .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var obuf: [1 << 16]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &obuf);
    const w = &fw.interface;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const src = try dir.readFileAllocOptions(io, entry.path, gpa, .unlimited, .of(u8), 0);
        defer gpa.free(src);
        try processFile(w, entry.path, src);
    }
    try w.flush();
}
