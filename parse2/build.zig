//! parse2/build.zig — NEW parser prototype (separate from parse/, the current one).
//!
//! One walk, node-centric: at each node we pull the Tree, and every Edge that node offers, then
//! RESOLVE each edge's target to mark WHERE it points — inside its own container, elsewhere in the
//! tree, at a language primitive, or out of the tree entirely. So instead of many tiny files, the
//! shape carries its own edges with their reach recorded.
//!
//!   nodes.tsv : path · kind · name · vis          (the Tree; vis = pub|priv)
//!   attrs.tsv : path · attr · value                (the node's own facts: doc · sig · value)
//!   edges.tsv : src · type · target · scope        (typed Edges, resolved)
//!
//! Edge types (declaration-level, read where the decl is declared):
//!   alias · imports · has_type · error_set · delegates
//! Scope (resolved in a 2nd pass against the walked node set):
//!   local     → resolves to a node inside src's own container (incl. @This())
//!   cross     → resolves to a node elsewhere in the tree              ← "points outside itself"
//!   primitive → a language builtin (i32, usize, type, …)
//!   module    → an @import alias / a file or module we didn't walk    ← "points outside the tree"
//!   unresolved→ couldn't place it (generic param, comptime-built, …)
//!
//! Factory descent IS handled: `fn F() type { return struct {…} }` walks the produced type's
//! members under `F()`. (Cross-file @import following is still deferred — imports mark `module`.)
//!
//! Run: zig run parse2/build.zig -- <root.zig> <nodes_out> <edges_out>

const std = @import("std");
const Ast = std.zig.Ast;

const Edge = struct { src: []const u8, etype: []const u8, target: []const u8 };

const MAX_DEPTH: u32 = 24;

const W = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    nodes: *std.Io.Writer,
    attrs: *std.Io.Writer, // path · attr · value — the node's own facts (doc / sig / value)
    node_set: std.StringHashMap(void), // every emitted path — the resolution target set
    imports: std.StringHashMap([]const u8), // alias → target, for NON-followed imports only (modules)
    visited: std.StringHashMap(void), // abs file paths already expanded (walk each file once)
    aliases: std.StringHashMap([]const u8), // alias-node path → its RHS target text (for chasing)
    generics: std.StringHashMap(void), // "<factory()path>#<paramname>" — comptime type params in scope
    edges: std.ArrayList(Edge), // raw edges, resolved in phase 2

    fn node(w: *W, path: []const u8, kind: []const u8, name: []const u8, vis: []const u8) !void {
        try w.nodes.print("{s}\t{s}\t{s}\t{s}\n", .{ path, kind, name, vis });
        try w.node_set.put(path, {});
    }
    fn edge(w: *W, src: []const u8, etype: []const u8, target: []const u8) !void {
        try w.edges.append(w.arena, .{ .src = src, .etype = etype, .target = target });
    }
    fn attr(w: *W, path: []const u8, name: []const u8, value: []const u8) !void {
        if (value.len == 0) return; // sparse: only documented decls, real sigs, valued fields
        try w.attrs.print("{s}\t{s}\t{s}\n", .{ path, name, value });
    }
};

const Factory = union(enum) { none, descend: Ast.Node.Index, delegate: []const u8 };

fn parent(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "";
    return path[0..i];
}

fn collapse(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const buf = try arena.alloc(u8, s.len);
    var n: usize = 0;
    var pending = false;
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
fn typeText(w: *W, ast: *const Ast, n: Ast.Node.Index) ![]const u8 {
    return collapse(w.arena, ast.getNodeSource(n));
}

/// A decl's `///` doc-comment run, whitespace-collapsed; "" when undocumented.
fn docComment(w: *W, ast: *const Ast, node: Ast.Node.Index) ![]const u8 {
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
        var txt = ast.tokenSlice(t);
        if (std.mem.startsWith(u8, txt, "///")) txt = txt[3..];
        @memcpy(raw[n..][0..txt.len], txt);
        n += txt.len;
        raw[n] = ' ';
        n += 1;
    }
    return collapse(w.arena, raw[0..n]);
}

/// A fn's as-written signature: the `fn` keyword through the return type, whitespace-collapsed.
fn fnSig(w: *W, ast: *const Ast, proto: *const Ast.full.FnProto) !?[]const u8 {
    const ret = proto.ast.return_type.unwrap() orelse return null;
    const starts = ast.tokens.items(.start);
    const last = ast.lastToken(ret);
    const start = starts[proto.ast.fn_token];
    const end = starts[last] + @as(u32, @intCast(ast.tokenSlice(last).len));
    return try collapse(w.arena, ast.source[start..end]);
}

fn importTarget(src: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, src, " \t\r\n");
    if (!std.mem.startsWith(u8, t, "@import(")) return null;
    const o = std.mem.indexOfScalar(u8, t, '"') orelse return null;
    const rest = t[o + 1 ..];
    const c = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..c];
}

/// Read + parse a child file, arena-storing the Ast so it outlives the recursive walk. null on
/// read/parse failure (the caller emits an `nserr` leaf).
fn parseChild(w: *W, abs: []const u8) ?*Ast {
    const src = std.Io.Dir.cwd().readFileAllocOptions(w.io, abs, w.arena, .unlimited, .of(u8), 0) catch return null;
    const a = w.arena.create(Ast) catch return null;
    a.* = Ast.parse(w.arena, src, .zig) catch return null;
    if (a.errors.len != 0) return null;
    return a;
}

fn isAliasChain(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) return false;
    return true;
}

fn containerKind(ast: *const Ast, n: Ast.Node.Index) ?[]const u8 {
    var buf: [2]Ast.Node.Index = undefined;
    const cd = ast.fullContainerDecl(&buf, n) orelse return null;
    return ast.tokenSlice(cd.ast.main_token);
}

fn classifyFactory(ast: *const Ast, fn_decl: Ast.Node.Index, proto: *const Ast.full.FnProto) Factory {
    const body = ast.nodeData(fn_decl).node_and_node[1];
    var buf: [2]Ast.Node.Index = undefined;
    const stmts = ast.blockStatements(&buf, body) orelse return .none;
    var descend: ?Ast.Node.Index = null;
    var delegate: ?[]const u8 = null;
    var type_returns: usize = 0;
    for (stmts) |s| {
        if (ast.nodeTag(s) != .@"return") continue;
        const op = ast.nodeData(s).opt_node.unwrap() orelse continue;
        if (containerKind(ast, op) != null) {
            descend = op;
            type_returns += 1;
        } else {
            var cb: [1]Ast.Node.Index = undefined;
            if (ast.fullCall(&cb, op) != null) {
                delegate = ast.getNodeSource(op);
                type_returns += 1;
            }
        }
    }
    if (type_returns != 1) return .none;
    if (descend) |d| return .{ .descend = d };
    const rt = proto.ast.return_type.unwrap() orelse return .none;
    if (!std.mem.eql(u8, std.mem.trim(u8, ast.getNodeSource(rt), " \t\r\n"), "type")) return .none;
    return .{ .delegate = delegate.? };
}

/// Peel a type expression down to the leading referenced name: `[]const u8`→`u8`,
/// `?Node.Index`→`Node.Index`, `ArrayList(u8)`→`ArrayList`, `@This()`→`@This`. "" if none.
fn extractBase(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        // start of an identifier or @builtin
        if (std.ascii.isAlphabetic(s[i]) or s[i] == '_' or s[i] == '@') {
            var j = i + 1;
            while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '_' or s[j] == '.')) j += 1;
            const word = s[i..j];
            // decoration keywords are not the referenced type — skip and keep scanning
            if (std.mem.eql(u8, word, "const") or std.mem.eql(u8, word, "volatile") or
                std.mem.eql(u8, word, "allowzero") or std.mem.eql(u8, word, "comptime") or
                std.mem.eql(u8, word, "error"))
            {
                i = j;
                continue;
            }
            return word;
        }
        i += 1;
    }
    return "";
}

const Scope = enum { local, cross, primitive, module, generic, @"inline", unresolved };
const Res = struct { scope: Scope, target: []const u8 };

/// Resolve a bare name in src's lexical scope: try container.name, then walk up the ancestors.
fn resolveBare(w: *W, container: []const u8, name: []const u8) ?[]const u8 {
    var scope = container;
    while (true) {
        const cand = if (scope.len == 0) name else std.fmt.allocPrint(w.arena, "{s}.{s}", .{ scope, name }) catch return null;
        if (w.node_set.contains(cand)) return cand;
        if (scope.len == 0) return null;
        scope = parent(scope);
    }
}

/// True if `base` is a comptime type param in scope — declared by a factory ancestor (`…()` node).
fn isGenericParam(w: *W, container: []const u8, base: []const u8) bool {
    var a = container;
    while (true) {
        if (std.mem.endsWith(u8, a, "()")) {
            const key = std.fmt.allocPrint(w.arena, "{s}#{s}", .{ a, base }) catch return false;
            if (w.generics.contains(key)) return true;
        }
        if (a.len == 0) return false;
        a = parent(a);
    }
}

/// Classify (and where possible canonicalize) one edge target. `fuel` bounds alias-chasing.
fn resolve(w: *W, src: []const u8, raw: []const u8, fuel: u8) Res {
    const container = parent(src);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    // an inline/anonymous type in the signature (`error{…}`, `struct {…}`) — no node to point at.
    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) return Res{ .scope = .@"inline", .target = trimmed };
    const base = extractBase(raw);
    if (base.len == 0) return Res{ .scope = .unresolved, .target = raw };

    if (std.mem.eql(u8, base, "@This")) return Res{ .scope = .local, .target = container };
    if (base[0] == '@') return Res{ .scope = .unresolved, .target = raw };

    const dotted = std.mem.indexOfScalar(u8, base, '.') != null;
    if (!dotted and std.zig.primitives.isPrimitive(base)) return Res{ .scope = .primitive, .target = base };
    if (!dotted and (std.mem.eql(u8, base, "type") or std.mem.eql(u8, base, "anytype") or
        std.mem.eql(u8, base, "anyopaque") or std.mem.eql(u8, base, "anyerror") or std.mem.eql(u8, base, "noreturn")))
        return Res{ .scope = .primitive, .target = base };

    if (dotted) {
        const head = base[0..std.mem.indexOfScalar(u8, base, '.').?];
        if (w.imports.get(head)) |tgt| return Res{ .scope = .module, .target = tgt };
    }
    if (resolveBare(w, container, base)) |p| {
        const inside = std.mem.eql(u8, p, container) or
            (p.len > container.len and container.len > 0 and std.mem.startsWith(u8, p, container) and p[container.len] == '.');
        return Res{ .scope = if (inside) .local else .cross, .target = p };
    }
    // ALIAS-CHASING: base is `head.rest` and head resolves to an alias — follow it, then retry.
    // (`Allocator.Error` → `Allocator` is a private alias to `mem.Allocator` → `mem.Allocator.Error`.)
    if (dotted and fuel > 0) {
        const dot = std.mem.indexOfScalar(u8, base, '.').?;
        if (resolveBare(w, container, base[0..dot])) |ph| {
            if (w.aliases.get(ph)) |tgt| {
                const chased = std.fmt.allocPrint(w.arena, "{s}{s}", .{ tgt, base[dot..] }) catch return Res{ .scope = .unresolved, .target = raw };
                return resolve(w, src, chased, fuel - 1);
            }
        }
    }
    // GENERIC PARAM: a comptime type param (T/K/V) declared by a factory ancestor.
    if (!dotted and isGenericParam(w, container, base)) return Res{ .scope = .generic, .target = base };
    return Res{ .scope = .unresolved, .target = raw };
}

fn fnEdges(w: *W, ast: *const Ast, cp: []const u8, m: Ast.Node.Index, proto: *const Ast.full.FnProto) !void {
    if (proto.ast.return_type.unwrap()) |rt| {
        if (ast.nodeTag(rt) == .error_union) {
            const d = ast.nodeData(rt).node_and_node;
            try w.edge(cp, "error_set", try typeText(w, ast, d[0]));
            try w.edge(cp, "has_type", try typeText(w, ast, d[1]));
        } else try w.edge(cp, "has_type", try typeText(w, ast, rt));
    }
    var it = proto.iterate(ast);
    while (it.next()) |p| {
        if (p.type_expr) |te| try w.edge(cp, "has_type", try typeText(w, ast, te));
    }
    if (ast.nodeTag(m) == .fn_decl) switch (classifyFactory(ast, m, proto)) {
        .delegate => |tgt| try w.edge(cp, "delegates", try collapse(w.arena, tgt)),
        else => {},
    };
}

fn walk(w: *W, ast: *const Ast, members: []const Ast.Node.Index, path: []const u8, parent_kind: []const u8, base_dir: []const u8, depth: u32) !void {
    for (members) |m| {
        // functions (incl. type factories)
        var fbuf: [1]Ast.Node.Index = undefined;
        if (ast.fullFnProto(&fbuf, m)) |proto| {
            const name = ast.tokenSlice(proto.name_token orelse continue);
            const vis = if (proto.visib_token != null) "pub" else "priv";
            const cp = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ path, name });
            try w.node(cp, "fn", name, vis);
            try w.attr(cp, "doc", try docComment(w, ast, m));
            if (try fnSig(w, ast, &proto)) |sg| try w.attr(cp, "sig", sg);
            try fnEdges(w, ast, cp, m, &proto);
            // FACTORY DESCENT: a fn whose body is `return struct {…}` — walk it under `<fn>()`.
            if (ast.nodeTag(m) == .fn_decl) switch (classifyFactory(ast, m, &proto)) {
                .descend => |d| {
                    const child = try std.fmt.allocPrint(w.arena, "{s}()", .{cp});
                    var cbuf: [2]Ast.Node.Index = undefined;
                    const cd = ast.fullContainerDecl(&cbuf, d).?;
                    try w.node(child, ast.tokenSlice(cd.ast.main_token), name, vis);
                    // record this factory's comptime type params (`comptime T: type`, `anytype`) so
                    // references to T/K/V inside `<fn>()` resolve to a `generic` scope, not unresolved.
                    var pit = proto.iterate(ast);
                    while (pit.next()) |p| {
                        const is_type_param = p.anytype_ellipsis3 != null or
                            (p.type_expr != null and std.mem.eql(u8, std.mem.trim(u8, ast.getNodeSource(p.type_expr.?), " \t\r\n"), "type"));
                        if (is_type_param) if (p.name_token) |nt| {
                            const key = try std.fmt.allocPrint(w.arena, "{s}#{s}", .{ child, ast.tokenSlice(nt) });
                            try w.generics.put(key, {});
                        };
                    }
                    try walk(w, ast, cd.ast.members, child, ast.tokenSlice(cd.ast.main_token), base_dir, depth + 1);
                },
                else => {},
            };
            continue;
        }
        // container fields / enum tags
        if (ast.fullContainerField(m)) |cf| {
            var field = cf;
            if (std.mem.eql(u8, parent_kind, "enum") or std.mem.eql(u8, parent_kind, "union")) field.convertToNonTupleLike(ast);
            if (field.ast.tuple_like) continue;
            const name = ast.tokenSlice(field.ast.main_token);
            const cp = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ path, name });
            try w.node(cp, if (std.mem.eql(u8, parent_kind, "enum")) "tag" else "field", name, "pub");
            try w.attr(cp, "doc", try docComment(w, ast, m));
            if (field.ast.type_expr.unwrap()) |te| try w.edge(cp, "has_type", try typeText(w, ast, te));
            if (field.ast.value_expr.unwrap()) |ve| try w.attr(cp, "value", try typeText(w, ast, ve));
            continue;
        }
        // var/const decls
        const vd = ast.fullVarDecl(m) orelse continue;
        const name = ast.tokenSlice(vd.ast.mut_token + 1);
        const vis = if (vd.visib_token != null) "pub" else "priv";
        const cp = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ path, name });
        try w.attr(cp, "doc", try docComment(w, ast, m));
        const init = vd.ast.init_node.unwrap() orelse {
            try w.node(cp, "const", name, vis);
            continue;
        };
        const init_src = ast.getNodeSource(init);
        if (importTarget(init_src)) |tgt| {
            const t = std.mem.trim(u8, init_src, " \t\r\n");
            const bare = std.mem.endsWith(u8, t, ")"); // `@import("x")` vs `@import("x").Sel`
            if (!std.mem.endsWith(u8, tgt, ".zig")) {
                // a MODULE we don't own (std / builtin / root) — external, never followed.
                try w.node(cp, "modref", name, vis);
                try w.imports.put(name, tgt);
                try w.edge(cp, "imports", tgt);
                continue;
            }
            if (!bare) { // `@import("x").Sel` — selective re-export; leave as an alias leaf.
                try w.node(cp, "alias", name, vis);
                try w.edge(cp, "alias", tgt);
                try w.aliases.put(cp, tgt);
                continue;
            }
            // an OWNED .zig file — FOLLOW it, once, building the full tree.
            const abs = std.fs.path.resolve(w.arena, &.{ base_dir, tgt }) catch {
                try w.node(cp, "nserr", name, vis);
                continue;
            };
            try w.edge(cp, "imports", tgt);
            if (w.visited.contains(abs) or depth >= MAX_DEPTH) {
                try w.node(cp, "nsref", name, vis); // already expanded elsewhere (its canonical home)
                continue;
            }
            try w.visited.put(abs, {});
            if (parseChild(w, abs)) |child| {
                try w.node(cp, "ns", name, vis);
                const child_dir = std.fs.path.dirname(abs) orelse ".";
                try walk(w, child, child.rootDecls(), cp, "struct", child_dir, depth + 1);
            } else try w.node(cp, "nserr", name, vis);
            continue;
        }
        if (containerKind(ast, init)) |ck| {
            try w.node(cp, ck, name, vis);
            var cbuf: [2]Ast.Node.Index = undefined;
            const cd = ast.fullContainerDecl(&cbuf, init).?;
            try walk(w, ast, cd.ast.members, cp, ck, base_dir, depth + 1);
            continue;
        }
        const trimmed = std.mem.trim(u8, init_src, " \t\r\n");
        if (isAliasChain(trimmed)) {
            try w.node(cp, "alias", name, vis);
            try w.edge(cp, "alias", trimmed);
            try w.aliases.put(cp, trimmed);
        } else try w.node(cp, "const", name, vis);
    }
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const root = if (args.len > 1) args[1] else "/usr/lib/zig/std/std.zig";
    const nodes_out = if (args.len > 2) args[2] else "nodes.tsv";
    const edges_out = if (args.len > 3) args[3] else "edges.tsv";
    const attrs_out = if (args.len > 4) args[4] else "attrs.tsv";

    const src = try std.Io.Dir.cwd().readFileAllocOptions(io, root, arena, .unlimited, .of(u8), 0);
    var ast = try Ast.parse(arena, src, .zig);

    const nf = try std.Io.Dir.cwd().createFile(io, nodes_out, .{});
    defer nf.close(io);
    var nbuf: [1 << 16]u8 = undefined;
    var nfw = nf.writer(io, &nbuf);
    const af = try std.Io.Dir.cwd().createFile(io, attrs_out, .{});
    defer af.close(io);
    var abuf: [1 << 16]u8 = undefined;
    var afw = af.writer(io, &abuf);
    var w = W{
        .arena = arena,
        .io = io,
        .nodes = &nfw.interface,
        .attrs = &afw.interface,
        .node_set = std.StringHashMap(void).init(arena),
        .imports = std.StringHashMap([]const u8).init(arena),
        .visited = std.StringHashMap(void).init(arena),
        .aliases = std.StringHashMap([]const u8).init(arena),
        .generics = std.StringHashMap(void).init(arena),
        .edges = .empty,
    };
    try w.nodes.print("path\tkind\tname\tvis\n", .{});
    try w.attrs.print("path\tattr\tvalue\n", .{});
    const root_name = std.fs.path.stem(root);
    try w.node(root_name, "ns", root_name, "pub");
    const root_abs = std.fs.path.resolve(arena, &.{root}) catch root;
    try w.visited.put(root_abs, {});

    // Phase 1 — walk the whole organism: follow every @import, building the complete node set.
    const root_dir = std.fs.path.dirname(root) orelse ".";
    try walk(&w, &ast, ast.rootDecls(), root_name, "root", root_dir, 0);
    try w.nodes.flush();
    try w.attrs.flush();

    // Phase 2 — resolve every edge target against the node set, emit with scope.
    const ef = try std.Io.Dir.cwd().createFile(io, edges_out, .{});
    defer ef.close(io);
    var ebuf: [1 << 16]u8 = undefined;
    var efw = ef.writer(io, &ebuf);
    const ew = &efw.interface;
    try ew.print("src\ttype\ttarget\tscope\n", .{});
    var counts = [_]usize{0} ** @typeInfo(Scope).@"enum".fields.len; // by Scope
    for (w.edges.items) |e| {
        // an `imports` edge always reaches out of the tree (a file/module we didn't walk) — its
        // target is a path, not a name to look up, so it never goes through scope resolution.
        const r = if (std.mem.eql(u8, e.etype, "imports"))
            Res{ .scope = Scope.module, .target = e.target }
        else
            resolve(&w, e.src, e.target, 4);
        counts[@intFromEnum(r.scope)] += 1;
        try ew.print("{s}\t{s}\t{s}\t{s}\n", .{ e.src, e.etype, r.target, @tagName(r.scope) });
    }
    try ew.flush();

    var sbuf: [512]u8 = undefined;
    var sfw = std.Io.File.stderr().writer(io, &sbuf);
    const s = &sfw.interface;
    try s.print("[parse2] {s}\n  nodes: {d}   edges: {d}\n  scope: local {d} · cross {d} · primitive {d} · module {d} · generic {d} · inline {d} · unresolved {d}\n", .{
        root, w.node_set.count(), w.edges.items.len,
        counts[@intFromEnum(Scope.local)], counts[@intFromEnum(Scope.cross)], counts[@intFromEnum(Scope.primitive)],
        counts[@intFromEnum(Scope.module)], counts[@intFromEnum(Scope.generic)], counts[@intFromEnum(Scope.@"inline")],
        counts[@intFromEnum(Scope.unresolved)],
    });
    try s.flush();
}
