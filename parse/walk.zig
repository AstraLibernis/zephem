//! walk.zig — the parse-walk of a Zig module, and the one thing it emits: the structural map.
//!
//! Builds the logical namespace tree by PARSING source with `std.zig.Ast`, following
//! `@import` edges and descending inline container literals (struct/enum/union/opaque). It
//! decides STRUCTURE — which decls exist, which get descended, the visited/depth gates, the
//! selective-re-export collapse — and writes one TSV row per public decl straight out:
//!
//!   path · depth · kind · name · n_children · detail
//!
//! Pure parsing — no comptime, no poison-decl death. Deterministic: source-order emission,
//! a file expanded once at first encounter (later refs are `nsref` leaves), identical bytes
//! for a fixed Zig version.

const std = @import("std");
const Ast = std.zig.Ast;
const az = @import("ast.zig");

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
    field, // a struct/union field (a typed slot) — payload in fields.tsv
    tag, // an enum member (a named value) — payload in fields.tsv
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
        .field => "field",
        .tag => "tag",
    };
}

/// One public decl: the six map columns. `detail` is pre-formatted by the walk (target file ·
/// fn param count · module name · alias RHS · ""), so `emit` is a single verbatim print.
pub const Node = struct {
    path: []const u8,
    name: []const u8,
    depth: u32,
    kind: Kind,
    n_children: usize = 0,
    detail: []const u8 = "",
};

/// Traversal state threaded through the walk, plus the output writer it emits rows to.
pub const Walker = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    visited: *std.StringHashMap(void),
    max_depth: u32,
    /// Module root dir — used to emit deterministic, machine-independent file paths.
    root_dir: []const u8,
    /// The map sink: one TSV row per node.
    out: *std.Io.Writer,
    /// Side sink: `path · sig` — the as-written fn signature, one row per fn.
    sigs: *std.Io.Writer,
    /// Side sink: `path · doc` — the `///` doc text, one row per documented decl.
    docs: *std.Io.Writer,
    /// Side sink: `path · type · value` — one row per field/tag node (the field payload).
    fields: *std.Io.Writer,
    /// Side sink: `path · target` — a delegating factory and the raw call it forwards to.
    delegates: *std.Io.Writer,
    /// Side sink: `path · kind · name · code` — a `test`/doctest and its source (an example).
    examples: *std.Io.Writer,

    /// Write one node as a map row. The single point of output.
    pub fn emit(w: *Walker, n: Node) !void {
        try w.out.print("{s}\t{d}\t{s}\t{s}\t{d}\t{s}\n", .{
            n.path, n.depth, kindStr(n.kind), n.name, n.n_children, n.detail,
        });
    }

    /// Record a fn's as-written signature (keyed by the same `path` as the map).
    pub fn emitSig(w: *Walker, path: []const u8, sig: []const u8) !void {
        try w.sigs.print("{s}\t{s}\n", .{ path, sig });
    }

    /// Record a decl's `///` doc (skipped when there is none, so docs.tsv holds only documented decls).
    pub fn emitDoc(w: *Walker, path: []const u8, doc: []const u8) !void {
        if (doc.len == 0) return;
        try w.docs.print("{s}\t{s}\n", .{ path, doc });
    }

    /// Record a field/tag's payload — its written `type` and `value` (either may be empty:
    /// enum tags have no type, plain fields no value). One row per field/tag node, so the
    /// sidecar is 1:1 with the `field`/`tag` rows in the map.
    pub fn emitField(w: *Walker, path: []const u8, ty: []const u8, value: []const u8) !void {
        try w.fields.print("{s}\t{s}\t{s}\n", .{ path, ty, value });
    }

    /// Record a delegating factory — the raw call it forwards to (unresolved source text).
    pub fn emitDelegate(w: *Walker, path: []const u8, target: []const u8) !void {
        try w.delegates.print("{s}\t{s}\n", .{ path, target });
    }

    /// Record a usage example. `path` is the decl a doctest documents (`test <ident>`) or the
    /// enclosing namespace for a free-standing `test`. `code` is the whole `test … {}` source,
    /// TSV-escaped so the multi-line snippet stays on one row.
    pub fn emitExample(w: *Walker, path: []const u8, kind: []const u8, name: []const u8, code: []const u8) !void {
        try w.examples.print("{s}\t{s}\t{s}\t{s}\n", .{ path, kind, name, code });
    }
};

/// Escape a snippet for a single TSV field: `\` `\t` `\r` `\n` → `\\` `\t` `\r` `\n` (two chars
/// each), so code with tabs and newlines round-trips through one TSV cell. The inverse is a
/// plain unescape on the consumer side.
fn escapeTsv(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var n: usize = 0;
    for (s) |c| n += switch (c) {
        '\\', '\t', '\r', '\n' => @as(usize, 2),
        else => 1,
    };
    const buf = try arena.alloc(u8, n);
    var i: usize = 0;
    for (s) |c| {
        const esc: ?u8 = switch (c) {
            '\\' => '\\',
            '\t' => 't',
            '\r' => 'r',
            '\n' => 'n',
            else => null,
        };
        if (esc) |e| {
            buf[i] = '\\';
            buf[i + 1] = e;
            i += 2;
        } else {
            buf[i] = c;
            i += 1;
        }
    }
    return buf[0..i];
}

fn ckToKind(ck: az.ContainerKind) Kind {
    return switch (ck) {
        .@"struct" => .@"struct",
        .@"enum" => .@"enum",
        .@"union" => .@"union",
        .@"opaque" => .@"opaque",
        .none => unreachable,
    };
}

/// How a fn body produces a type — classified from source alone, by its single top-level
/// `return`. `.descend` = `return <struct/union/enum/opaque {…}>`, the unambiguous "this fn
/// builds this type" case (we walk into it). `.delegate` = `return Other(args)` on a `type`-
/// returning fn — it forwards to another factory; we don't copy members (they live on the
/// target), we record the raw target text so the link isn't lost (resolving it to a path is a
/// later job). `.none` = a plain fn, a comptime/`@Type`-built type, or an ambiguous multi-return
/// — left an honest, undescended leaf. Exactly one top-level type-return, or it's `.none`.
const Factory = union(enum) {
    none,
    descend: Ast.Node.Index, // the container-literal node
    delegate: []const u8, // the raw call expression forwarded to
};

fn classifyFactory(ast: *const Ast, fn_decl: Ast.Node.Index, proto: *const Ast.full.FnProto) Factory {
    const body = ast.nodeData(fn_decl).node_and_node[1];
    var buf: [2]Ast.Node.Index = undefined;
    const stmts = ast.blockStatements(&buf, body) orelse return .none;
    var descend: ?Ast.Node.Index = null;
    var delegate: ?[]const u8 = null;
    var type_returns: usize = 0;
    for (stmts) |s| {
        if (ast.nodeTag(s) != .@"return") continue;
        const operand = ast.nodeData(s).opt_node.unwrap() orelse continue;
        if (az.containerKindOf(ast, operand) != .none) {
            descend = operand;
            type_returns += 1;
        } else {
            var cb: [1]Ast.Node.Index = undefined;
            if (ast.fullCall(&cb, operand) != null) {
                delegate = ast.getNodeSource(operand);
                type_returns += 1;
            }
        }
    }
    if (type_returns != 1) return .none; // 0 = opaque/passthrough, >1 = ambiguous — don't guess
    if (descend) |d| return .{ .descend = d };
    // a returned call is delegation only when the fn's declared return type is `type` (else it's
    // an ordinary value-returning fn like `return foo()`, not a factory forwarding to a type).
    const rt = proto.ast.return_type.unwrap() orelse return .none;
    if (!std.mem.eql(u8, std.mem.trim(u8, ast.getNodeSource(rt), " \t\r\n"), "type")) return .none;
    return .{ .delegate = delegate.? };
}

/// Emit one container-field member: its map row (`field`/`tag`, decided by the *parent*
/// container's kind — a void union variant looks type-less just like an enum tag, so only
/// the parent disambiguates), its `///` doc, and its `path·type·value` payload row. Fields
/// are always public and always leaves. `tuple_idx` names an unnamed (tuple) field by its
/// ordinal, and is advanced only when one is emitted.
fn emitField(
    w: *Walker,
    ast: *const Ast,
    node: Ast.Node.Index,
    cf: Ast.full.ContainerField,
    parent_kind: Kind,
    logical_path: []const u8,
    depth: u32,
    tuple_idx: *usize,
) !void {
    // Enum tags and void union variants parse identically to a tuple field whose "type" is a
    // bare identifier (`enum { a }` ≡ `struct { a }` at the syntax level). Only the container
    // keyword disambiguates: in an enum/union that identifier is the member NAME, not a type.
    // `convertToNonTupleLike` performs exactly that fix (identifier → name, type → none).
    var field = cf;
    if (parent_kind == .@"enum" or parent_kind == .@"union") field.convertToNonTupleLike(ast);

    const name = if (field.ast.tuple_like) blk: {
        const nm = try std.fmt.allocPrint(w.arena, "{d}", .{tuple_idx.*});
        tuple_idx.* += 1;
        break :blk nm;
    } else ast.tokenSlice(field.ast.main_token);
    const path = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ logical_path, name });
    const kind: Kind = if (parent_kind == .@"enum") .tag else .field;
    const ty = if (field.ast.type_expr.unwrap()) |tn|
        try collapseWs(w.arena, ast.getNodeSource(tn))
    else
        "";
    const value = if (field.ast.value_expr.unwrap()) |vn|
        try collapseWs(w.arena, ast.getNodeSource(vn))
    else
        "";
    try w.emit(.{ .path = path, .name = name, .depth = depth, .kind = kind });
    try w.emitDoc(path, try docComment(w, ast, node));
    try w.emitField(path, ty, value);
}

/// The map's `detail` for a fn — its parameter count, as a string.
fn fnDetail(w: *Walker, ast: *const Ast, proto: *const Ast.full.FnProto) ![]const u8 {
    var n: usize = 0;
    var it = proto.iterate(ast);
    while (it.next()) |_| n += 1;
    return std.fmt.allocPrint(w.arena, "{d}", .{n});
}

/// Collapse every run of whitespace (incl. newlines) to a single space, trimming the ends —
/// so a multi-line signature or doc becomes one clean TSV-safe field.
fn collapseWs(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const buf = try arena.alloc(u8, s.len);
    var n: usize = 0;
    var pending: bool = false; // a space owed, flushed only before the next non-space
    for (s) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            if (n > 0) pending = true;
        } else {
            if (pending) {
                buf[n] = ' ';
                n += 1;
                pending = false;
            }
            buf[n] = c;
            n += 1;
        }
    }
    return buf[0..n];
}

/// The fn's as-written signature: the raw source from the `fn` keyword through the return type
/// (the body excluded), whitespace-collapsed. Faithful — names, types, error set, `comptime`/
/// `anytype` all preserved exactly as written. Null only if the proto has no return type.
fn fnSig(w: *Walker, ast: *const Ast, proto: *const Ast.full.FnProto) !?[]const u8 {
    const ret = proto.ast.return_type.unwrap() orelse return null;
    const starts = ast.tokens.items(.start);
    const fn_tok = proto.ast.fn_token;
    const last = ast.lastToken(ret);
    const start = starts[fn_tok];
    const end = starts[last] + @as(u32, @intCast(ast.tokenSlice(last).len));
    return try collapseWs(w.arena, ast.source[start..end]);
}

/// A decl's `///` doc comment, joined and whitespace-collapsed; "" when undocumented. Finds the
/// contiguous run of `.doc_comment` tokens attached to the decl (works whether the AST counts
/// them inside or before the decl's first token).
fn docComment(w: *Walker, ast: *const Ast, node: Ast.Node.Index) ![]const u8 {
    const first = ast.firstToken(node);
    var start = first;
    while (start > 0 and ast.tokenTag(start - 1) == .doc_comment) start -= 1;
    var end = start;
    while (ast.tokenTag(end) == .doc_comment) end += 1;
    if (start == end) return "";

    var total: usize = 0;
    var t = start;
    while (t < end) : (t += 1) total += ast.tokenSlice(t).len + 1;
    const raw = try w.arena.alloc(u8, total);
    var n: usize = 0;
    t = start;
    while (t < end) : (t += 1) {
        var txt = ast.tokenSlice(t); // "/// text"
        if (std.mem.startsWith(u8, txt, "///")) txt = txt[3..];
        @memcpy(raw[n..][0..txt.len], txt);
        n += txt.len;
        raw[n] = ' ';
        n += 1;
    }
    return try collapseWs(w.arena, raw[0..n]);
}

/// Parse a child file and stash its Ast in the arena (so it outlives this frame for the
/// recursive walk).
fn parseChild(w: *Walker, path: []const u8) !?*const Ast {
    const v = (try az.parseFile(w.io, w.arena, path)) orelse return null;
    const a = try w.arena.create(Ast);
    a.* = v;
    return a;
}

/// Walk the members of a container (or the root) at `logical_path`, emitting each public decl.
pub fn walkMembers(
    w: *Walker,
    ast: *const Ast,
    members: []const Ast.Node.Index,
    base_dir: []const u8,
    logical_path: []const u8,
    depth: u32,
    parent_kind: Kind,
) anyerror!void {
    var tuple_idx: usize = 0; // names unnamed (tuple) fields by ordinal, per container
    for (members) |m| {
        const tag = ast.nodeTag(m);

        // test declarations → usage examples. `test <identifier>` is a *doctest* bound to the
        // decl of that name (owner = `logical_path.name`, which joins straight onto that node);
        // `test "…"` / `test {…}` is a free-standing test (owner = the enclosing namespace).
        // Tests are never public, so this is handled before the pub gates below.
        if (tag == .test_decl) {
            const name_tok = ast.nodeData(m).opt_token_and_node[0];
            var kind: []const u8 = "test";
            var name: []const u8 = "";
            var owner = logical_path;
            if (name_tok.unwrap()) |tok| {
                if (ast.tokenTag(tok) == .identifier) {
                    kind = "doctest";
                    name = ast.tokenSlice(tok);
                    // `test <Name>` where Name is the container's OWN name documents the container
                    // itself (`test BitStack` at the root of BitStack.zig → `std.BitStack`, not the
                    // non-existent `std.BitStack.BitStack`).
                    const base = if (std.mem.lastIndexOfScalar(u8, logical_path, '.')) |i| logical_path[i + 1 ..] else logical_path;
                    owner = if (std.mem.eql(u8, name, base))
                        logical_path
                    else
                        try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ logical_path, name });
                } else {
                    // string-literal name → drop the surrounding quotes for a clean field.
                    name = try escapeTsv(w.arena, std.mem.trim(u8, ast.tokenSlice(tok), "\""));
                }
            }
            try w.emitExample(owner, kind, name, try escapeTsv(w.arena, ast.getNodeSource(m)));
            continue;
        }

        // functions. A plain fn is a leaf (detail = param count). A *type factory* whose body
        // has a single top-level `return <container literal>` is descended: its produced type's
        // members hang under `<fn>()` — the `()` marks "instantiate first" (`std.ArrayList().append`
        // is reachable only after calling, unlike a static `std.mem.Allocator.alloc`).
        if (tag == .fn_decl) {
            var b: [1]Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&b, m) orelse continue;
            if (proto.visib_token == null) continue;
            const name_tok = proto.name_token orelse continue;
            const name = ast.tokenSlice(name_tok);
            const path = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ logical_path, name });

            // classify the body: a descendable factory (walk its produced type's members under
            // `<fn>()`), a delegating factory (record the raw target — members live there), or
            // neither (a plain fn / opaque factory — a leaf).
            const factory = classifyFactory(ast, m, &proto);
            var ret_members: []const Ast.Node.Index = &.{};
            var member_kind: Kind = .fn_decl;
            var cbuf: [2]Ast.Node.Index = undefined;
            if (factory == .descend) {
                ret_members = ast.fullContainerDecl(&cbuf, factory.descend).?.ast.members;
                member_kind = ckToKind(az.containerKindOf(ast, factory.descend));
            }
            const nkids = if (depth < w.max_depth) az.countPub(ast, ret_members) else 0;
            try w.emit(.{ .path = path, .name = name, .depth = depth, .kind = .fn_decl, .n_children = nkids, .detail = try fnDetail(w, ast, &proto) });
            try w.emitDoc(path, try docComment(w, ast, m));
            if (try fnSig(w, ast, &proto)) |sg| try w.emitSig(path, sg);
            switch (factory) {
                .descend => if (depth < w.max_depth) {
                    const child_logical = try std.fmt.allocPrint(w.arena, "{s}()", .{path});
                    try walkMembers(w, ast, ret_members, base_dir, child_logical, depth + 1, member_kind);
                },
                .delegate => |target| try w.emitDelegate(path, try collapseWs(w.arena, target)),
                .none => {},
            }
            continue;
        }

        // container fields — struct/union slots and enum tags. Leaves; always public.
        if (ast.fullContainerField(m)) |cf| {
            try emitField(w, ast, m, cf, parent_kind, logical_path, depth, &tuple_idx);
            continue;
        }

        const vd = ast.fullVarDecl(m) orelse continue;
        if (vd.visib_token == null) continue;
        const name = ast.tokenSlice(vd.ast.mut_token + 1);
        // doc applies to every decl kind; emit once here, before the branch decides the node.
        try w.emitDoc(try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ logical_path, name }), try docComment(w, ast, m));
        const init = vd.ast.init_node.unwrap() orelse {
            const path = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ logical_path, name });
            try w.emit(.{ .path = path, .name = name, .depth = depth, .kind = .const_decl });
            continue;
        };
        const init_src = ast.getNodeSource(init);

        // @import(...) — a whole-file namespace, a re-export of one decl, or a module ref.
        if (az.parseImport(init_src)) |imp| {
            const child_logical = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ logical_path, name });
            if (!std.mem.endsWith(u8, imp.file, ".zig")) {
                // module import (std/builtin/root) — a reference, not a file we own.
                try w.emit(.{ .path = child_logical, .name = name, .depth = depth, .kind = .modref, .detail = imp.file });
            } else {
                const child_path = try std.fs.path.resolve(w.arena, &.{ base_dir, imp.file });
                if (imp.selector.len == 0) {
                    // BARE whole-file import → a sub-namespace; follow it.
                    const rel = az.relPath(w.root_dir, child_path);
                    if (w.visited.contains(child_path) or depth >= w.max_depth) {
                        try w.emit(.{ .path = child_logical, .name = name, .depth = depth, .kind = .nsref, .detail = rel });
                    } else if (try parseChild(w, child_path)) |child_ast| {
                        try w.visited.put(child_path, {});
                        const cnt = az.countPub(child_ast, child_ast.rootDecls());
                        try w.emit(.{ .path = child_logical, .name = name, .depth = depth, .kind = .ns, .n_children = cnt, .detail = rel });
                        try walkMembers(w, child_ast, child_ast.rootDecls(), az.dirname(child_path), child_logical, depth + 1, .ns);
                    } else {
                        try w.emit(.{ .path = child_logical, .name = name, .depth = depth, .kind = .nserr, .detail = rel });
                    }
                } else {
                    // SELECTIVE re-export `@import("f").Sel` → collapse: A *is* the decl Sel
                    // resolves to (its members hang directly under A — no phantom doubling).
                    try emitReexport(w, child_path, imp.selector, child_logical, name, depth, 0);
                }
            }
            continue;
        }

        // inline container literal → descend into the AST subtree.
        const ck = az.containerKindOf(ast, init);
        if (ck != .none) {
            const child_logical = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ logical_path, name });
            var b: [2]Ast.Node.Index = undefined;
            const cd = ast.fullContainerDecl(&b, init).?;
            const cnt = if (depth < w.max_depth) az.countPub(ast, cd.ast.members) else 0;
            try w.emit(.{ .path = child_logical, .name = name, .depth = depth, .kind = ckToKind(ck), .n_children = cnt });
            if (depth < w.max_depth) {
                try walkMembers(w, ast, cd.ast.members, base_dir, child_logical, depth + 1, ckToKind(ck));
            }
            continue;
        }

        // an alias / plain const. A pure dotted chain is a re-export; record its raw RHS in
        // `detail` (the unresolved target a later link layer would resolve to a canonical path).
        const trimmed = std.mem.trim(u8, init_src, " \t\r\n");
        const is_alias = az.isAliasChain(trimmed);
        const path = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ logical_path, name });
        try w.emit(.{
            .path = path,
            .name = name,
            .depth = depth,
            .kind = if (is_alias) .alias else .const_decl,
            .detail = if (is_alias) trimmed else "",
        });
    }
}

/// Emit node `a_logical` (= `a_name`) for a selective re-export `@import(file).selector`,
/// COLLAPSED: A becomes whatever `selector` resolves to inside `file` — a container (members
/// hang directly under A), a fn (a leaf), or, when the chain can't be followed cleanly, an
/// `alias` leaf.
fn emitReexport(
    w: *Walker,
    file_abs: []const u8,
    selector: []const u8,
    a_logical: []const u8,
    a_name: []const u8,
    depth: u32,
    chain: u8,
) anyerror!void {
    const rel = az.relPath(w.root_dir, file_abs);
    // multi-segment selector or a too-deep chain → safe `alias` leaf (no false structure).
    if (chain > 16 or std.mem.indexOfScalar(u8, selector, '.') != null) {
        try w.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .alias, .detail = rel });
        return;
    }
    const fast = (try parseChild(w, file_abs)) orelse {
        try w.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .nserr, .detail = rel });
        return;
    };
    const found = az.findDecl(fast, fast.rootDecls(), selector) orelse {
        try w.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .alias, .detail = rel });
        return;
    };
    // re-exported function → A is that fn (leaf; detail = its param count).
    if (fast.nodeTag(found) == .fn_decl) {
        var b: [1]Ast.Node.Index = undefined;
        const proto = fast.fullFnProto(&b, found).?;
        try w.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .fn_decl, .detail = try fnDetail(w, fast, &proto) });
        if (try fnSig(w, fast, &proto)) |sg| try w.emitSig(a_logical, sg);
        return;
    }
    const vd = fast.fullVarDecl(found) orelse {
        try w.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .alias, .detail = rel });
        return;
    };
    const binit = vd.ast.init_node.unwrap() orelse {
        try w.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .const_decl });
        return;
    };
    // re-exported inline container → A IS it; hang its members directly under A (collapse).
    const ck = az.containerKindOf(fast, binit);
    if (ck != .none) {
        var b2: [2]Ast.Node.Index = undefined;
        const cd = fast.fullContainerDecl(&b2, binit).?;
        const cnt = if (depth < w.max_depth) az.countPub(fast, cd.ast.members) else 0;
        try w.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = ckToKind(ck), .n_children = cnt });
        if (depth < w.max_depth) {
            try walkMembers(w, fast, cd.ast.members, az.dirname(file_abs), a_logical, depth + 1, ckToKind(ck));
        }
        return;
    }
    // re-exported decl is itself an @import → A re-exports that (whole file → ns; selective → chain).
    if (az.parseImport(fast.getNodeSource(binit))) |imp2| {
        if (std.mem.endsWith(u8, imp2.file, ".zig")) {
            const gpath = try std.fs.path.resolve(w.arena, &.{ az.dirname(file_abs), imp2.file });
            if (imp2.selector.len == 0) {
                const grel = az.relPath(w.root_dir, gpath);
                if (w.visited.contains(gpath) or depth >= w.max_depth) {
                    try w.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .nsref, .detail = grel });
                } else if (try parseChild(w, gpath)) |gast| {
                    try w.visited.put(gpath, {});
                    const cnt = az.countPub(gast, gast.rootDecls());
                    try w.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .ns, .n_children = cnt, .detail = grel });
                    try walkMembers(w, gast, gast.rootDecls(), az.dirname(gpath), a_logical, depth + 1, .ns);
                } else {
                    try w.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .nserr, .detail = grel });
                }
            } else {
                try emitReexport(w, gpath, imp2.selector, a_logical, a_name, depth, chain + 1);
            }
            return;
        }
    }
    // generic instantiation, local alias, or plain value → alias leaf.
    try w.emit(.{ .path = a_logical, .name = a_name, .depth = depth, .kind = .alias, .detail = rel });
}
