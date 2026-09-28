// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! pkg.zig — find a project's dependencies and the modules they export, by READING their
//! manifests as source. Nothing here runs a build script or touches the network: a dependency
//! must already be fetched (`zig build --fetch`, which in Zig 0.16 unpacks every package,
//! transitive ones included, into the project's `zig-pkg/<hash>/`).
//!
//!   depsOf      build.zig.zon → `.dependencies`: name + hash (fetched) or path (local)
//!   modulesOf   build.zig     → every `b.addModule("name", .{ .root_source_file = b.path("f") })`
//!
//! Only literal forms are recognised. A module whose name or root is computed at build time is
//! reported as not found rather than guessed.
const std = @import("std");
const Ast = std.zig.Ast;

pub const Dep = struct {
    name: []const u8,
    /// set for a fetched package: its directory is `<project>/zig-pkg/<hash>`
    hash: ?[]const u8 = null,
    /// set for a local package: relative to the manifest's directory
    path: ?[]const u8 = null,
};

pub const Module = struct { name: []const u8, root: []const u8 };

/// The `.dependencies` of a build.zig.zon.
pub fn depsOf(a: std.mem.Allocator, zon: [:0]const u8) ![]Dep {
    var ast = try Ast.parse(a, zon, .zon);
    if (ast.errors.len != 0) return error.ManifestUnparsable;
    var out: std.ArrayList(Dep) = .empty;
    var buf: [2]Ast.Node.Index = undefined;
    const root = ast.nodeData(.root).node;
    const top = ast.fullStructInit(&buf, root) orelse return out.items;
    for (top.ast.fields) |f| {
        if (!std.mem.eql(u8, fieldName(&ast, f), "dependencies")) continue;
        var dbuf: [2]Ast.Node.Index = undefined;
        const deps = ast.fullStructInit(&dbuf, f) orelse continue;
        for (deps.ast.fields) |d| {
            var ebuf: [2]Ast.Node.Index = undefined;
            const entry = ast.fullStructInit(&ebuf, d) orelse continue;
            var dep: Dep = .{ .name = try unquoteName(a, fieldName(&ast, d)) };
            for (entry.ast.fields) |e| {
                const key = fieldName(&ast, e);
                if (std.mem.eql(u8, key, "hash")) dep.hash = try stringLit(a, &ast, e);
                if (std.mem.eql(u8, key, "path")) dep.path = try stringLit(a, &ast, e);
            }
            if (dep.hash != null or dep.path != null) try out.append(a, dep);
        }
    }
    return out.items;
}

/// Every `<x>.addModule("name", .{ ... .root_source_file = <y>.path("file") ... })` in a build.zig.
pub fn modulesOf(a: std.mem.Allocator, src: [:0]const u8) ![]Module {
    var ast = try Ast.parse(a, src, .zig);
    if (ast.errors.len != 0) return error.BuildScriptUnparsable;
    var out: std.ArrayList(Module) = .empty;
    var i: u32 = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);
        var cbuf: [1]Ast.Node.Index = undefined;
        const call = ast.fullCall(&cbuf, node) orelse continue;
        if (!calls(&ast, call, "addModule") or call.ast.params.len != 2) continue;
        const name = (try stringLitOrNull(a, &ast, call.ast.params[0])) orelse continue;
        var sbuf: [2]Ast.Node.Index = undefined;
        const opts = ast.fullStructInit(&sbuf, call.ast.params[1]) orelse continue;
        for (opts.ast.fields) |f| {
            if (!std.mem.eql(u8, fieldName(&ast, f), "root_source_file")) continue;
            var pbuf: [1]Ast.Node.Index = undefined;
            const pc = ast.fullCall(&pbuf, f) orelse continue;
            if (!calls(&ast, pc, "path") or pc.ast.params.len != 1) continue;
            const root = (try stringLitOrNull(a, &ast, pc.ast.params[0])) orelse continue;
            try out.append(a, .{ .name = name, .root = root });
        }
    }
    return out.items;
}

/// `call` is `<anything>.<method>(...)`.
fn calls(ast: *const Ast, call: Ast.full.Call, method: []const u8) bool {
    if (ast.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const name_tok = ast.nodeData(call.ast.fn_expr).node_and_token[1];
    return std.mem.eql(u8, ast.tokenSlice(name_tok), method);
}

/// The name of a struct-init field: the identifier two tokens before its value (`.name = value`).
fn fieldName(ast: *const Ast, value: Ast.Node.Index) []const u8 {
    return ast.tokenSlice(ast.firstToken(value) - 2);
}

/// `@"zig-clap"` → `zig-clap`; a plain identifier unchanged.
fn unquoteName(a: std.mem.Allocator, tok: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, tok, "@\"")) return std.zig.string_literal.parseAlloc(a, tok[1..]);
    return tok;
}

fn stringLit(a: std.mem.Allocator, ast: *const Ast, node: Ast.Node.Index) ![]const u8 {
    return (try stringLitOrNull(a, ast, node)) orelse error.NotAStringLiteral;
}

fn stringLitOrNull(a: std.mem.Allocator, ast: *const Ast, node: Ast.Node.Index) !?[]const u8 {
    if (ast.nodeTag(node) != .string_literal) return null;
    return try std.zig.string_literal.parseAlloc(a, ast.tokenSlice(ast.nodeMainToken(node)));
}
