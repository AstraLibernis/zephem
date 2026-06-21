//! walk.zig — the ONE parse-walk of a Zig module, shared by every overlay.
//!
//! Builds the logical namespace tree by PARSING source with `std.zig.Ast`, following
//! `@import` edges and descending inline container literals (struct/enum/union/opaque).
//! It decides STRUCTURE — which decls exist, which get descended, the visited/depth gates,
//! the selective-re-export collapse — and reports each decl as a `Node` to a comptime
//! `visitor`. The visitor decides what (if anything) to EMIT. So the map and the doc/sig
//! overlay are two visitors over a single traversal; they can no longer drift apart (the
//! old scan.zig/enrich.zig had to mirror each other byte-for-byte by hand).
//!
//! A visitor is any value with `pub fn emit(self, Node) !void`. Pass several at once with a
//! tee (see tools/build.zig) to produce multiple datasets from one parse of std.
//!
//! Pure parsing — no comptime, no poison-decl death. Deterministic: source-order emission,
//! a file expanded once at first encounter (later refs are `nsref` leaves), identical bytes
//! for a fixed Zig version.

const std = @import("std");
const Ast = std.zig.Ast;
const astu = @import("common/ast.zig");
const fs = @import("common/fs.zig");

/// What a node is. Mirrors the map's `kind` column; see `kindStr` for the wire spelling.
pub const Kind = enum {
    ns, // an @import'd sub-namespace that was expanded
    nsref, // a re-encountered / depth-capped namespace (not expanded)
    nserr, // a namespace whose file could not be read
    modref, // an import of a module we don't own (std/builtin/root)
    @"struct",
    @"enum",
    @"union",
    @"opaque",
    fn_decl,
    const_decl, // a computed value
    alias, // a re-export `pub const X = a.b.C`
};

pub fn kindStr(k: Kind) []const u8 {
    return switch (k) {
        .ns => "ns",
        .nsref => "nsref",
        .nserr => "nserr",
        .modref => "modref",
        .@"struct" => "struct",
        .@"enum" => "enum",
        .@"union" => "union",
        .@"opaque" => "opaque",
        .fn_decl => "fn",
        .const_decl => "const",
        .alias => "alias",
    };
}

/// One public decl, with everything any overlay needs:
///   structure  — path · depth · kind · name · n_children · detail
///   doc/sig    — `ds_ast` + `ds_tok` locate the `///` doc source; `proto` the fn signature.
/// `detail` is the map's pre-formatted detail field (target file · fn param count · module
/// name · alias RHS · ""), so a structure visitor prints it verbatim.
pub const Node = struct {
    path: []const u8,
    name: []const u8,
    depth: u32,
    kind: Kind,
    n_children: usize = 0,
    detail: []const u8 = "",
    /// AST that owns `ds_tok` / `proto` (the doc & signature source).
    ds_ast: *const Ast,
    /// Visibility/start token to look doc-comments back from; null = no doc source.
    ds_tok: ?Ast.TokenIndex = null,
    /// fn signature source (set only for `fn_decl`).
    proto: ?*const Ast.full.FnProto = null,
};

/// Traversal state threaded through the walk (the visitor carries its own output).
pub const Walker = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    visited: *std.StringHashMap(void),
    max_depth: u32,
    /// Module root dir — used to emit deterministic, machine-independent file paths.
    root_dir: []const u8,
};

fn ckToKind(ck: astu.ContainerKind) Kind {
    return switch (ck) {
        .@"struct" => .@"struct",
        .@"enum" => .@"enum",
        .@"union" => .@"union",
        .@"opaque" => .@"opaque",
        .none => unreachable,
    };
}

/// The map's `detail` for a fn — its parameter count, as a string.
fn fnDetail(w: *Walker, ast: *const Ast, proto: *const Ast.full.FnProto) ![]const u8 {
    var n: usize = 0;
    var it = proto.iterate(ast);
    while (it.next()) |_| n += 1;
    return std.fmt.allocPrint(w.arena, "{d}", .{n});
}

/// Parse a child file and stash its Ast in the arena (so it outlives this frame for the
/// recursive walk and for any `Node.ds_ast` that points into it).
fn parseChild(w: *Walker, path: []const u8) !?*const Ast {
    const v = (try fs.parseFile(w.io, w.arena, path)) orelse return null;
    const a = try w.arena.create(Ast);
    a.* = v;
    return a;
}

/// Walk the members of a container (or the root) at `logical_path`, reporting each public
/// decl to `visitor`.
pub fn walkMembers(
    w: *Walker,
    visitor: anytype,
    ast: *const Ast,
    members: []const Ast.Node.Index,
    base_dir: []const u8,
    logical_path: []const u8,
    depth: u32,
) anyerror!void {
    for (members) |m| {
        const tag = ast.nodeTag(m);

        // functions — leaves (detail = param count)
        if (tag == .fn_decl) {
            var b: [1]Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&b, m) orelse continue;
            if (proto.visib_token == null) continue;
            const name_tok = proto.name_token orelse continue;
            const name = ast.tokenSlice(name_tok);
            const path = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ logical_path, name });
            try visitor.emit(.{
                .path = path,
                .name = name,
                .depth = depth,
                .kind = .fn_decl,
                .detail = try fnDetail(w, ast, &proto),
                .ds_ast = ast,
                .ds_tok = proto.visib_token,
                .proto = &proto,
            });
            continue;
        }

        const vd = ast.fullVarDecl(m) orelse continue;
        if (vd.visib_token == null) continue;
        const start_tok = vd.visib_token.?;
        const name = ast.tokenSlice(vd.ast.mut_token + 1);
        const init = vd.ast.init_node.unwrap() orelse {
            const path = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ logical_path, name });
            try visitor.emit(.{ .path = path, .name = name, .depth = depth, .kind = .const_decl, .ds_ast = ast, .ds_tok = start_tok });
            continue;
        };
        const init_src = ast.getNodeSource(init);

        // @import(...) — a whole-file namespace, a re-export of one decl, or a module ref.
        if (astu.parseImport(init_src)) |imp| {
            const child_logical = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ logical_path, name });
            if (!std.mem.endsWith(u8, imp.file, ".zig")) {
                // module import (std/builtin/root) — a reference, not a file we own.
                try visitor.emit(.{ .path = child_logical, .name = name, .depth = depth, .kind = .modref, .detail = imp.file, .ds_ast = ast, .ds_tok = start_tok });
            } else {
                const child_path = try std.fs.path.resolve(w.arena, &.{ base_dir, imp.file });
                if (imp.selector.len == 0) {
                    // BARE whole-file import → a sub-namespace; follow it.
                    const rel = fs.relPath(w.root_dir, child_path);
                    if (w.visited.contains(child_path) or depth >= w.max_depth) {
                        try visitor.emit(.{ .path = child_logical, .name = name, .depth = depth, .kind = .nsref, .detail = rel, .ds_ast = ast, .ds_tok = start_tok });
                    } else if (try parseChild(w, child_path)) |child_ast| {
                        try w.visited.put(child_path, {});
                        const cnt = astu.countPub(child_ast, child_ast.rootDecls());
                        try visitor.emit(.{ .path = child_logical, .name = name, .depth = depth, .kind = .ns, .n_children = cnt, .detail = rel, .ds_ast = ast, .ds_tok = start_tok });
                        try walkMembers(w, visitor, child_ast, child_ast.rootDecls(), fs.dirname(child_path), child_logical, depth + 1);
                    } else {
                        try visitor.emit(.{ .path = child_logical, .name = name, .depth = depth, .kind = .nserr, .detail = rel, .ds_ast = ast, .ds_tok = start_tok });
                    }
                } else {
                    // SELECTIVE re-export `@import("f").Sel` → collapse: A *is* the decl Sel
                    // resolves to (its members hang directly under A — no phantom doubling).
                    try emitReexport(w, visitor, child_path, imp.selector, child_logical, name, depth, ast, start_tok, 0);
                }
            }
            continue;
        }

        // inline container literal → descend into the AST subtree.
        const ck = astu.containerKindOf(ast, init);
        if (ck != .none) {
            const child_logical = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ logical_path, name });
            var b: [2]Ast.Node.Index = undefined;
            const cd = ast.fullContainerDecl(&b, init).?;
            const cnt = if (depth < w.max_depth) astu.countPub(ast, cd.ast.members) else 0;
            try visitor.emit(.{ .path = child_logical, .name = name, .depth = depth, .kind = ckToKind(ck), .n_children = cnt, .ds_ast = ast, .ds_tok = start_tok });
            if (depth < w.max_depth) {
                try walkMembers(w, visitor, ast, cd.ast.members, base_dir, child_logical, depth + 1);
            }
            continue;
        }

        // an alias / plain const. A pure dotted chain is a re-export; record its raw RHS in
        // `detail` (the unresolved target an L3 tunnel resolves to a canonical path).
        const trimmed = std.mem.trim(u8, init_src, " \t\r\n");
        const is_alias = astu.isAliasChain(trimmed);
        const path = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ logical_path, name });
        try visitor.emit(.{
            .path = path,
            .name = name,
            .depth = depth,
            .kind = if (is_alias) .alias else .const_decl,
            .detail = if (is_alias) trimmed else "",
            .ds_ast = ast,
            .ds_tok = start_tok,
        });
    }
}

/// Emit node `a_logical` (= `a_name`) for a selective re-export `@import(file).selector`,
/// COLLAPSED: A becomes whatever `selector` resolves to inside `file` — a container (members
/// hang directly under A), a fn (a leaf), or, when the chain can't be followed cleanly, an
/// `alias` leaf. `p_ast`/`p_start` are the *parent* decl's doc source (the overlay uses them
/// for every case except a re-exported fn, which carries its own resolved doc + signature).
fn emitReexport(
    w: *Walker,
    visitor: anytype,
    file_abs: []const u8,
    selector: []const u8,
    a_logical: []const u8,
    a_name: []const u8,
    depth: u32,
    p_ast: *const Ast,
    p_start: Ast.TokenIndex,
    chain: u8,
) anyerror!void {
    const rel = fs.relPath(w.root_dir, file_abs);
    // multi-segment selector or a too-deep chain → safe `alias` leaf (no false structure).
    if (chain > 16 or std.mem.indexOfScalar(u8, selector, '.') != null) {
        try visitor.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .alias, .detail = rel, .ds_ast = p_ast, .ds_tok = p_start });
        return;
    }
    const fast = (try parseChild(w, file_abs)) orelse {
        try visitor.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .nserr, .detail = rel, .ds_ast = p_ast, .ds_tok = p_start });
        return;
    };
    const found = astu.findDecl(fast, fast.rootDecls(), selector) orelse {
        try visitor.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .alias, .detail = rel, .ds_ast = p_ast, .ds_tok = p_start });
        return;
    };
    // re-exported function → A is that fn (leaf; carries the resolved sig + the fn's own doc).
    if (fast.nodeTag(found) == .fn_decl) {
        var b: [1]Ast.Node.Index = undefined;
        const proto = fast.fullFnProto(&b, found).?;
        try visitor.emit(.{
            .path = a_logical,
            .name = a_name,
            .depth = depth,
            .kind = .fn_decl,
            .detail = try fnDetail(w, fast, &proto),
            .ds_ast = fast,
            .ds_tok = proto.visib_token,
            .proto = &proto,
        });
        return;
    }
    const vd = fast.fullVarDecl(found) orelse {
        try visitor.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .alias, .detail = rel, .ds_ast = p_ast, .ds_tok = p_start });
        return;
    };
    const binit = vd.ast.init_node.unwrap() orelse {
        try visitor.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .const_decl, .ds_ast = p_ast, .ds_tok = p_start });
        return;
    };
    // re-exported inline container → A IS it; hang its members directly under A (collapse).
    const ck = astu.containerKindOf(fast, binit);
    if (ck != .none) {
        var b2: [2]Ast.Node.Index = undefined;
        const cd = fast.fullContainerDecl(&b2, binit).?;
        const cnt = if (depth < w.max_depth) astu.countPub(fast, cd.ast.members) else 0;
        try visitor.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = ckToKind(ck), .n_children = cnt, .ds_ast = p_ast, .ds_tok = p_start });
        if (depth < w.max_depth) {
            try walkMembers(w, visitor, fast, cd.ast.members, fs.dirname(file_abs), a_logical, depth + 1);
        }
        return;
    }
    // re-exported decl is itself an @import → A re-exports that (whole file → ns; selective → chain).
    if (astu.parseImport(fast.getNodeSource(binit))) |imp2| {
        if (std.mem.endsWith(u8, imp2.file, ".zig")) {
            const gpath = try std.fs.path.resolve(w.arena, &.{ fs.dirname(file_abs), imp2.file });
            if (imp2.selector.len == 0) {
                const grel = fs.relPath(w.root_dir, gpath);
                if (w.visited.contains(gpath) or depth >= w.max_depth) {
                    try visitor.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .nsref, .detail = grel, .ds_ast = p_ast, .ds_tok = p_start });
                } else if (try parseChild(w, gpath)) |gast| {
                    try w.visited.put(gpath, {});
                    const cnt = astu.countPub(gast, gast.rootDecls());
                    try visitor.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .ns, .n_children = cnt, .detail = grel, .ds_ast = p_ast, .ds_tok = p_start });
                    try walkMembers(w, visitor, gast, gast.rootDecls(), fs.dirname(gpath), a_logical, depth + 1);
                } else {
                    try visitor.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .nserr, .detail = grel, .ds_ast = p_ast, .ds_tok = p_start });
                }
            } else {
                try emitReexport(w, visitor, gpath, imp2.selector, a_logical, a_name, depth, p_ast, p_start, chain + 1);
            }
            return;
        }
    }
    // generic instantiation, local alias, or plain value → alias leaf.
    try visitor.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .alias, .detail = rel, .ds_ast = p_ast, .ds_tok = p_start });
}
