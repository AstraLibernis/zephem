//! parse/build.zig — the parser engine: one walk over the source tree emitting the shape model.
//! Imported as the `parse` module and driven in-process by `zephem std` via `run` (no `zig run`
//! handoff). The walk/resolve logic is the heart of the read-it engine.
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
//! Run: zig run parse/build.zig -- <root.zig> <nodes_out> <edges_out> <attrs_out>

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
    root_dir: []const u8, // std root dir, for machine-independent relative loc paths
    ast_cache: std.StringHashMap(*Ast), // abs file path → parsed Ast — parse each file once per build
    line_cache: std.StringHashMap([]usize), // rel file → sorted newline offsets (fast line lookup)
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

/// The parent path in the tree. A `<fn>()` factory container's parent is the fn it descends from
/// (drop the trailing `()`); otherwise drop the last dotted segment, treating a `.` inside a `@"…"`
/// quoted name as part of the name, not a separator — so all three `parent` readers (here,
/// `index.zig`, `verify_std.nu`) agree, incl. names like `Version.@"HTTP/1.1"`.
pub fn parent(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, "()")) return path[0 .. path.len - 2];
    var inq = false;
    var last_dot: ?usize = null;
    for (path, 0..) |c, j| {
        if (inq) {
            if (c == '"') inq = false;
        } else if (c == '"') {
            inq = true;
        } else if (c == '.') {
            last_dot = j;
        }
    }
    return if (last_dot) |k| path[0..k] else "";
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

/// Escape a code snippet for one TSV cell — `\` `\t` `\r` `\n` → two chars — so a multi-line test
/// body survives as a single row (collapse would destroy its formatting).
fn escapeTsv(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var n: usize = 0;
    for (s) |c| n += switch (c) {
        '\\', '\t', '\r', '\n' => @as(usize, 2),
        else => 1,
    };
    const buf = try arena.alloc(u8, n);
    var i: usize = 0;
    for (s) |c| {
        const e: ?u8 = switch (c) {
            '\\' => '\\',
            '\t' => 't',
            '\r' => 'r',
            '\n' => 'n',
            else => null,
        };
        if (e) |x| {
            buf[i] = '\\';
            buf[i + 1] = x;
            i += 2;
        } else {
            buf[i] = c;
            i += 1;
        }
    }
    return buf[0..i];
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

/// Space-joined modifier keywords on a var/const decl — `extern`/`export` · `threadlocal` ·
/// `comptime` · `var` (const is the default, omitted). "" when none, so the `mod` attr stays sparse.
fn varMod(w: *W, ast: *const Ast, vd: Ast.full.VarDecl) ![]const u8 {
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    if (vd.extern_export_token) |t| {
        parts[n] = ast.tokenSlice(t);
        n += 1;
    }
    if (vd.threadlocal_token != null) {
        parts[n] = "threadlocal";
        n += 1;
    }
    if (vd.comptime_token != null) {
        parts[n] = "comptime";
        n += 1;
    }
    if (std.mem.eql(u8, ast.tokenSlice(vd.ast.mut_token), "var")) {
        parts[n] = "var";
        n += 1;
    }
    return if (n == 0) "" else std.mem.join(w.arena, " ", parts[0..n]);
}

/// A fn's leading qualifier — `extern` / `export` / `inline` — or "" (the `sig` attr starts at the
/// `fn` keyword, so these, which precede it, would otherwise be lost).
fn fnMod(ast: *const Ast, proto: *const Ast.full.FnProto) []const u8 {
    return if (proto.extern_export_inline_token) |t| ast.tokenSlice(t) else "";
}

/// Emit each member of a named `error{A, B, C}` literal as an `errmember` attr on the decl. Members
/// can carry `///` doc-comments and span lines, so within each comma-separated chunk we take the
/// last non-comment line and pull its leading identifier (or `@"…"`) — never raw text (a value with
/// an embedded newline would corrupt the TSV).
fn emitErrMembers(w: *W, cp: []const u8, src: []const u8) !void {
    const lb = std.mem.indexOfScalar(u8, src, '{') orelse return;
    const rb = std.mem.lastIndexOfScalar(u8, src, '}') orelse return;
    if (rb <= lb + 1) return; // empty `error{}`
    var chunks = std.mem.splitScalar(u8, src[lb + 1 .. rb], ',');
    while (chunks.next()) |chunk| {
        var member: []const u8 = "";
        var lines = std.mem.splitScalar(u8, chunk, '\n');
        while (lines.next()) |ln| {
            const t = std.mem.trim(u8, ln, " \t\r");
            if (t.len == 0 or std.mem.startsWith(u8, t, "//")) continue; // skip blanks + doc/comments
            member = leadingIdent(t);
        }
        if (member.len != 0) try w.attr(cp, "errmember", member);
    }
}

/// The leading identifier of `t` — a `@"…"` quoted name, or the run of identifier chars — dropping
/// any trailing comment/whitespace.
fn leadingIdent(t: []const u8) []const u8 {
    if (std.mem.startsWith(u8, t, "@\"")) {
        const close = std.mem.indexOfScalarPos(u8, t, 2, '"') orelse return t;
        return t[0 .. close + 1];
    }
    var j: usize = 0;
    while (j < t.len and (std.ascii.isAlphanumeric(t[j]) or t[j] == '_')) j += 1;
    return t[0..j];
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
    if (w.ast_cache.get(abs)) |a| return a; // already parsed this build — reuse (Asts are arena-persistent)
    const src = std.Io.Dir.cwd().readFileAllocOptions(w.io, abs, w.arena, .unlimited, .of(u8), 0) catch return null;
    const a = w.arena.create(Ast) catch return null;
    a.* = Ast.parse(w.arena, src, .zig) catch return null;
    if (a.errors.len != 0) return null;
    w.ast_cache.put(abs, a) catch {};
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

/// True when `raw` is an anonymous container literal in type position — `struct {…}`,
/// `enum(u8) {…}`, `union(enum) {…}`, `opaque {…}`, `error{…}` (optionally `extern`/`packed`).
/// The leading keyword is what marks it, NOT the mere presence of `{`: `Tuple(&.{u8})` and
/// `meta.Int(.{…})` carry a brace but reference a real decl, so they must resolve, not bucket as inline.
fn isInlineContainer(raw: []const u8) bool {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOfScalar(u8, s, '{') == null) return false;
    var t = s;
    for ([_][]const u8{ "extern ", "packed " }) |q| {
        if (std.mem.startsWith(u8, t, q)) {
            t = std.mem.trimStart(u8, t[q.len..], " \t");
            break;
        }
    }
    for ([_][]const u8{ "struct", "enum", "union", "opaque", "error" }) |kw| {
        if (std.mem.startsWith(u8, t, kw)) {
            const rest = t[kw.len..];
            if (rest.len == 0) return false; // bare keyword, no body
            return rest[0] == '{' or rest[0] == ' ' or rest[0] == '(';
        }
    }
    return false;
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
    if (isInlineContainer(trimmed)) return Res{ .scope = .@"inline", .target = trimmed };
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

/// A node's own declaration-site facts — its source location and `///` doc. One place so the
/// two callers (in-place walk · re-export follower) can never emit a differing shape.
fn declFacts(w: *W, cp: []const u8, loc: []const u8, doc: []const u8) !void {
    try w.attr(cp, "loc", loc);
    try w.attr(cp, "doc", doc);
}

/// Emit a fn node with its facts (loc · doc · sig · edges) and, when it's a single-return type
/// factory, descend the produced type under `<cp>()` — recording the factory's comptime type
/// params so `T`/`K`/`V` inside resolve to `generic`. Shared by `walk` (in-place decls) and
/// `emitReexport` (followed re-exports) so loc/doc/generics/factory-loc can't drift between them.
fn emitFn(w: *W, ast: *const Ast, cp: []const u8, name: []const u8, vis: []const u8, node: Ast.Node.Index, proto: *const Ast.full.FnProto, dir: []const u8, rel: []const u8, depth: u32, fallback_doc: []const u8) anyerror!void {
    try w.node(cp, "fn", name, vis);
    const own_doc = try docComment(w, ast, node);
    try declFacts(w, cp, try locOf(w, ast, node, rel), if (own_doc.len != 0) own_doc else fallback_doc);
    if (try fnSig(w, ast, proto)) |sg| try w.attr(cp, "sig", sg);
    try w.attr(cp, "mod", fnMod(ast, proto)); // extern/export/inline (sparse; sig starts at `fn`)
    try fnEdges(w, ast, cp, node, proto);
    if (ast.nodeTag(node) != .fn_decl) return;
    switch (classifyFactory(ast, node, proto)) {
        .descend => |d| {
            const child = try std.fmt.allocPrint(w.arena, "{s}()", .{cp});
            var cbuf: [2]Ast.Node.Index = undefined;
            const cd = ast.fullContainerDecl(&cbuf, d).?;
            const ck = ast.tokenSlice(cd.ast.main_token);
            try w.node(child, ck, name, vis);
            try w.attr(child, "loc", try locOf(w, ast, d, rel)); // the produced type's own location
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
            try walk(w, ast, cd.ast.members, child, ck, dir, depth + 1, rel);
        },
        else => {},
    }
}

fn walk(w: *W, ast: *const Ast, members: []const Ast.Node.Index, path: []const u8, parent_kind: []const u8, base_dir: []const u8, depth: u32, rel: []const u8) !void {
    var tuple_idx: usize = 0; // names unnamed (positional) tuple fields per container
    for (members) |m| {
        // test / doctest → an `example` fact on the decl it documents (`test <ident>`) or on the
        // enclosing namespace (`test "…"`). Attached by owner path, in the shape's attrs stream.
        if (ast.nodeTag(m) == .test_decl) {
            var owner = path;
            const nt = ast.nodeData(m).opt_token_and_node[0];
            if (nt.unwrap()) |tok| if (ast.tokenTag(tok) == .identifier) {
                const nm = ast.tokenSlice(tok);
                const base = if (std.mem.lastIndexOfScalar(u8, path, '.')) |k| path[k + 1 ..] else path;
                owner = if (std.mem.eql(u8, nm, base)) path else try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ path, nm });
            };
            try w.attr(owner, "example", try escapeTsv(w.arena, ast.getNodeSource(m)));
            continue;
        }
        // functions (incl. type factories)
        var fbuf: [1]Ast.Node.Index = undefined;
        if (ast.fullFnProto(&fbuf, m)) |proto| {
            const name = ast.tokenSlice(proto.name_token orelse continue);
            const vis = if (proto.visib_token != null) "pub" else "priv";
            const cp = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ path, name });
            try emitFn(w, ast, cp, name, vis, m, &proto, base_dir, rel, depth, "");
            continue;
        }
        // container fields / enum tags
        if (ast.fullContainerField(m)) |cf| {
            var field = cf;
            if (std.mem.eql(u8, parent_kind, "enum") or std.mem.eql(u8, parent_kind, "union")) field.convertToNonTupleLike(ast);
            // positional (tuple) fields have no source name — name them `[N]` so they never collide
            // with a real named field and read as an index, not data.
            const name = if (field.ast.tuple_like) blk: {
                const s = try std.fmt.allocPrint(w.arena, "[{d}]", .{tuple_idx});
                tuple_idx += 1;
                break :blk s;
            } else ast.tokenSlice(field.ast.main_token);
            const cp = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ path, name });
            try w.node(cp, if (std.mem.eql(u8, parent_kind, "enum")) "tag" else "field", name, "pub");
            try w.attr(cp, "loc", try locOf(w, ast, m, rel));
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
        try w.attr(cp, "mod", try varMod(w, ast, vd)); // var/extern/export/threadlocal/comptime (sparse)
        // Declaration-site facts. Used for every kind EXCEPT a followed selective re-export,
        // whose loc/doc come from the target it resolves to (emitReexport owns them, falling
        // back to these only when the target can't be reached).
        const decl_loc = try locOf(w, ast, m, rel);
        const decl_doc = try docComment(w, ast, m);
        const init = vd.ast.init_node.unwrap() orelse {
            try declFacts(w, cp, decl_loc, decl_doc);
            try w.node(cp, "const", name, vis);
            continue;
        };
        const init_src = ast.getNodeSource(init);
        if (ast.nodeTag(init) == .error_set_decl) try emitErrMembers(w, cp, init_src); // errmember attrs
        if (importTarget(init_src)) |tgt| {
            const sel = selectorOf(init_src);
            // `@import("f").foo()` — a CALL selector yields a computed value/type we can't resolve by
            // parsing (it needs the compiler). Neither a namespace nor a plain re-export: a const.
            if (std.mem.indexOfScalar(u8, sel, '(') != null) {
                try declFacts(w, cp, decl_loc, decl_doc);
                try w.node(cp, "const", name, vis);
                continue;
            }
            const bare = sel.len == 0; // `@import("x")` vs `@import("x").Sel`
            if (!std.mem.endsWith(u8, tgt, ".zig")) {
                // a MODULE we don't own (std / builtin / root) — external, never followed.
                try declFacts(w, cp, decl_loc, decl_doc);
                try w.node(cp, "modref", name, vis);
                try w.imports.put(name, tgt);
                try w.edge(cp, "imports", tgt);
                continue;
            }
            if (!bare) { // `@import("x").Sel` — FOLLOW it, place Sel under cp (its single home).
                const rabs = std.fs.path.resolve(w.arena, &.{ base_dir, tgt }) catch {
                    try declFacts(w, cp, decl_loc, decl_doc);
                    try w.node(cp, "alias", name, vis);
                    try w.edge(cp, "alias", tgt);
                    try w.aliases.put(cp, tgt);
                    continue;
                };
                try emitReexport(w, rabs, sel, cp, name, vis, depth + 1, decl_loc, decl_doc);
                continue;
            }
            // an OWNED .zig file — FOLLOW it, once, building the full tree.
            try declFacts(w, cp, decl_loc, decl_doc);
            const abs = std.fs.path.resolve(w.arena, &.{ base_dir, tgt }) catch {
                try w.node(cp, "nserr", name, vis);
                continue;
            };
            try w.edge(cp, "imports", tgt);
            if (w.visited.contains(abs) or depth >= MAX_DEPTH) {
                try w.node(cp, "nsref", name, vis); // already expanded elsewhere (its canonical home)
                continue;
            }
            if (parseChild(w, abs)) |child| {
                try w.visited.put(abs, {}); // mark visited only on a successful parse — a failed
                try w.node(cp, "ns", name, vis); // read stays `nserr` and can be retried elsewhere
                const child_dir = std.fs.path.dirname(abs) orelse ".";
                try walk(w, child, child.rootDecls(), cp, "struct", child_dir, depth + 1, relOf(w, abs));
            } else try w.node(cp, "nserr", name, vis);
            continue;
        }
        try declFacts(w, cp, decl_loc, decl_doc);
        if (containerKind(ast, init)) |ck| {
            try w.node(cp, ck, name, vis);
            var cbuf: [2]Ast.Node.Index = undefined;
            const cd = ast.fullContainerDecl(&cbuf, init).?;
            try walk(w, ast, cd.ast.members, cp, ck, base_dir, depth + 1, rel);
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

/// 1-based line of `off`, via a per-file newline-offset table (built once, then binary-searched) —
/// std.zig.findLineColumn rescans from byte 0 each call, which is O(file) per node.
/// Fallible: reserve once, then fill infallibly — so a low-memory condition surfaces here
/// instead of silently dropping offsets, which would skew every line number after the gap.
fn lineOf(w: *W, source: []const u8, rel: []const u8, off: usize) !usize {
    const table = w.line_cache.get(rel) orelse blk: {
        var count: usize = 0;
        for (source) |c| {
            if (c == '\n') count += 1;
        }
        var list: std.ArrayList(usize) = .empty;
        try list.ensureTotalCapacity(w.arena, count);
        for (source, 0..) |c, i| if (c == '\n') list.appendAssumeCapacity(i);
        try w.line_cache.put(rel, list.items);
        break :blk list.items;
    };
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) { // count of newlines strictly before off
        const mid = lo + (hi - lo) / 2;
        if (table[mid] < off) lo = mid + 1 else hi = mid;
    }
    return lo + 1;
}
/// `<relfile>:<line>` for a node's first token.
fn locOf(w: *W, ast: *const Ast, node: Ast.Node.Index, rel: []const u8) ![]const u8 {
    const off = ast.tokens.items(.start)[ast.firstToken(node)];
    return std.fmt.allocPrint(w.arena, "{s}:{d}", .{ rel, try lineOf(w, ast.source, rel, off) });
}
fn relOf(w: *W, abs: []const u8) []const u8 {
    if (std.mem.startsWith(u8, abs, w.root_dir) and abs.len > w.root_dir.len) {
        const r = abs[w.root_dir.len..];
        return if (r.len > 0 and r[0] == '/') r[1..] else r;
    }
    return abs;
}
/// The selector after `@import("f").` — e.g. `@import("x.zig").Foo` → `Foo`.
fn selectorOf(src: []const u8) []const u8 {
    const t = std.mem.trim(u8, src, " \t\r\n");
    const close = std.mem.indexOfScalar(u8, t, ')') orelse return "";
    var s = std.mem.trim(u8, t[close + 1 ..], " \t\r\n");
    if (s.len > 0 and s[0] == '.') s = s[1..];
    return s;
}
/// Find a pub `const`/`fn` named `sel` among a file's root decls.
fn findDecl(ast: *const Ast, members: []const Ast.Node.Index, sel: []const u8) ?Ast.Node.Index {
    for (members) |m| {
        if (ast.fullVarDecl(m)) |vd| {
            if (std.mem.eql(u8, ast.tokenSlice(vd.ast.mut_token + 1), sel)) return m;
        } else {
            var fb: [1]Ast.Node.Index = undefined;
            if (ast.fullFnProto(&fb, m)) |proto| {
                if (proto.name_token) |nt| if (std.mem.eql(u8, ast.tokenSlice(nt), sel)) return m;
            }
        }
    }
    return null;
}

/// A selective re-export `pub const X = @import("f").Sel` — follow into `f`, find `Sel`, and place
/// IT (its members, if a container) under `cp`. Selective-only files have no other home, so this is
/// option B's single canonical home, not duplication. The node takes the TARGET's loc/doc (that is
/// where the code lives); `decl_loc`/`decl_doc` are the re-export site, used only as a fallback when
/// the target can't be reached (unparsable file, missing decl, dotted/too-deep selector).
fn emitReexport(w: *W, abs: []const u8, sel: []const u8, cp: []const u8, name: []const u8, vis: []const u8, depth: u32, decl_loc: []const u8, decl_doc: []const u8) anyerror!void {
    const leaf = struct {
        fn f(ww: *W, c: []const u8, n: []const u8, v: []const u8, t: []const u8, loc: []const u8, doc: []const u8) !void {
            try declFacts(ww, c, loc, doc);
            try ww.node(c, "alias", n, v);
            try ww.edge(c, "alias", t);
            try ww.aliases.put(c, t);
        }
    }.f;
    if (std.mem.indexOfScalar(u8, sel, '.') != null or depth >= MAX_DEPTH) return leaf(w, cp, name, vis, sel, decl_loc, decl_doc);
    const ast = parseChild(w, abs) orelse {
        try declFacts(w, cp, decl_loc, decl_doc);
        return w.node(cp, "nserr", name, vis);
    };
    const found = findDecl(ast, ast.rootDecls(), sel) orelse return leaf(w, cp, name, vis, sel, decl_loc, decl_doc);
    const dir = std.fs.path.dirname(abs) orelse ".";
    const rel = relOf(w, abs);

    var fb: [1]Ast.Node.Index = undefined;
    if (ast.fullFnProto(&fb, found)) |proto| {
        try emitFn(w, ast, cp, name, vis, found, &proto, dir, rel, depth, decl_doc);
        return;
    }
    // A followed non-fn target owns its facts from where it is actually declared. Its doc is the
    // target's, falling back to the re-export site's own `///` when the target is undocumented.
    const tgt_loc = try locOf(w, ast, found, rel);
    const found_doc = try docComment(w, ast, found);
    const tgt_doc = if (found_doc.len != 0) found_doc else decl_doc;
    const vd = ast.fullVarDecl(found).?;
    const init = vd.ast.init_node.unwrap() orelse {
        try declFacts(w, cp, tgt_loc, tgt_doc);
        return w.node(cp, "const", name, vis);
    };
    const isrc = ast.getNodeSource(init);
    if (importTarget(isrc)) |t2| {
        const isrc_sel = selectorOf(isrc);
        // `@import("f").foo()` — a CALL selector is a computed const, not a followable namespace.
        if (std.mem.indexOfScalar(u8, isrc_sel, '(') != null) {
            try declFacts(w, cp, tgt_loc, tgt_doc);
            return w.node(cp, "const", name, vis);
        }
        if (std.mem.endsWith(u8, t2, ".zig")) {
            const abs2 = std.fs.path.resolve(w.arena, &.{ dir, t2 }) catch {
                try declFacts(w, cp, tgt_loc, tgt_doc);
                return w.node(cp, "nserr", name, vis);
            };
            const bare2 = isrc_sel.len == 0;
            if (!bare2) return emitReexport(w, abs2, isrc_sel, cp, name, vis, depth + 1, tgt_loc, tgt_doc);
            try declFacts(w, cp, tgt_loc, tgt_doc);
            try w.edge(cp, "imports", t2);
            if (w.visited.contains(abs2) or depth >= MAX_DEPTH) return w.node(cp, "nsref", name, vis);
            if (parseChild(w, abs2)) |c2| {
                try w.visited.put(abs2, {}); // mark visited only on a successful parse
                try w.node(cp, "ns", name, vis);
                try walk(w, c2, c2.rootDecls(), cp, "struct", std.fs.path.dirname(abs2) orelse ".", depth + 1, relOf(w, abs2));
            } else try w.node(cp, "nserr", name, vis);
            return;
        }
    }
    if (containerKind(ast, init)) |ck| {
        try declFacts(w, cp, tgt_loc, tgt_doc);
        try w.node(cp, ck, name, vis);
        var cb: [2]Ast.Node.Index = undefined;
        const cd = ast.fullContainerDecl(&cb, init).?;
        try walk(w, ast, cd.ast.members, cp, ck, dir, depth + 1, rel);
        return;
    }
    const trimmed = std.mem.trim(u8, isrc, " \t\r\n");
    if (isAliasChain(trimmed)) return leaf(w, cp, name, vis, trimmed, tgt_loc, tgt_doc);
    try declFacts(w, cp, tgt_loc, tgt_doc);
    try w.node(cp, "const", name, vis);
}

/// Scope tallies from edge resolution — returned so the caller can report without re-reading.
pub const Stats = struct {
    nodes: usize,
    edges: usize,
    scope: [@typeInfo(Scope).@"enum".fields.len]usize,
};

/// Walk `root` (a std.zig path) and write the three TSV streams. `arena` must outlive nothing past
/// return (all working state is arena-scoped); pass a fresh arena per call.
pub fn run(arena: std.mem.Allocator, io: std.Io, root: []const u8, nodes_out: []const u8, edges_out: []const u8, attrs_out: []const u8) !Stats {
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
        .root_dir = std.fs.path.dirname(root) orelse ".",
        .ast_cache = std.StringHashMap(*Ast).init(arena),
        .line_cache = std.StringHashMap([]usize).init(arena),
    };
    try w.nodes.print("path\tkind\tname\tvis\n", .{});
    try w.attrs.print("path\tattr\tvalue\n", .{});
    const root_name = std.fs.path.stem(root);
    try w.node(root_name, "ns", root_name, "pub");
    const root_abs = std.fs.path.resolve(arena, &.{root}) catch root;
    try w.visited.put(root_abs, {});

    // Phase 1 — walk the whole organism: follow every @import, building the complete node set.
    const root_dir = std.fs.path.dirname(root) orelse ".";
    try walk(&w, &ast, ast.rootDecls(), root_name, "root", root_dir, 0, std.fs.path.basename(root));
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
    try s.print("[parse] {s}\n  nodes: {d}   edges: {d}\n  scope: local {d} · cross {d} · primitive {d} · module {d} · generic {d} · inline {d} · unresolved {d}\n", .{
        root, w.node_set.count(), w.edges.items.len,
        counts[@intFromEnum(Scope.local)], counts[@intFromEnum(Scope.cross)], counts[@intFromEnum(Scope.primitive)],
        counts[@intFromEnum(Scope.module)], counts[@intFromEnum(Scope.generic)], counts[@intFromEnum(Scope.@"inline")],
        counts[@intFromEnum(Scope.unresolved)],
    });
    try s.flush();

    return Stats{ .nodes = w.node_set.count(), .edges = w.edges.items.len, .scope = counts };
}
