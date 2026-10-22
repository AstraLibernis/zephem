// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! parse/walk.zig — the parser engine: one walk over the source tree emitting the shape model.
//! Built by the Zig whose std it maps and run as its own program (parse/main.zig; version
//! differences in compat.zig). `zephem deps` still imports it in-process as the `parse` module.
//! The walk/resolve logic is the heart of the read-it engine.
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
//! Driven by `zephem std` via `run(arena, io, root, nodes_out, edges_out, attrs_out)`.

const std = @import("std");
const Ast = std.zig.Ast;
const compat = @import("compat.zig");
// zsnag:allow R011 — this file is compiled by every supported Zig (see compat.zig); it keeps std names that exist in all of them, even where the newest deprecates them.

const Edge = struct { src: []const u8, etype: []const u8, target: []const u8 };

const MAX_DEPTH: u32 = 24;

/// Hops one edge may take through aliases, factory instances and forwarding factories
/// (`BufSetHashMap` → `StringHashMap` → `std.StringHashMap` → `hash_map.StringHashMap` →
/// `HashMap()`, each lookup costing one); a bound against cycles, not a depth anything needs.
const resolve_fuel: u8 = 16;

const W = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    nodes: *std.Io.Writer,
    attrs: *std.Io.Writer, // path · attr · value — the node's own facts (doc / sig / value)
    node_set: std.StringHashMap(void), // every emitted path — the resolution target set
    imports: std.StringHashMap([]const u8), // modref node path → module path (`std`, `std.os.uefi`), for NON-followed imports only
    visited: std.StringHashMap(void), // abs file paths already expanded (walk each file once)
    aliases: std.StringHashMap([]const u8), // alias-node path → its RHS target text (for chasing)
    instances: std.StringHashMap([]const u8), // const built by a call → the callee as written (`StringHashMap`)
    forwards: std.StringHashMap([]const u8), // forwarding factory fn → the call it returns (`SipHash(u128, c, d)`)
    generics: std.StringHashMap(void), // "<factory()path>#<paramname>" — comptime type params in scope
    root_dir: []const u8, // std root dir, for machine-independent relative loc paths
    root_name: []const u8, // the root module's name (`std`): an import of it points back into the tree
    ast_cache: std.StringHashMap(*Ast), // abs file path → parsed Ast — parse each file once per build
    line_cache: std.StringHashMap([]usize), // rel file → sorted newline offsets (fast line lookup)
    edges: std.ArrayList(Edge), // raw edges, resolved in phase 2
    // A file reached only through `@import("f.zig").Sel`: Sel lives at its re-export path, the
    // rest of the file under a private node for the file, and names inside Sel resolve there.
    deferred: std.ArrayList(Deferred), // re-exported files to settle after the walk
    file_home: std.StringHashMap([]const u8), // abs file path → the node its declarations live under
    lexical: std.StringHashMap([]const u8), // node path → the scope its names resolve in, when that is not its parent
    lexical_names: std.StringHashMap([]const u8), // `<file node>.Sel` → Sel's re-export path (where its tests belong)
    nsrefs: std.ArrayList([2][]const u8), // (nsref path, abs file): linked to the file's home after the walk
    selected: std.StringHashMap([]const u8), // "rel\x00Name" → that file's top-level Name's one home (see `homeOf`)
    best: std.StringHashMap(Home), // "rel\x00Name" → the best placement this pass met (see `homeOf`)
    private_nodes: std.StringHashMap(void), // every path emitted with vis `priv` (see `Home.private`)

    fn node(w: *W, path: []const u8, kind: []const u8, name: []const u8, vis: []const u8) !void {
        try w.nodes.print("{s}\t{s}\t{s}\t{s}\n", .{ path, kind, name, vis });
        try w.node_set.put(path, {});
        if (std.mem.eql(u8, vis, "priv")) try w.private_nodes.put(path, {});
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

const Deferred = struct { sel_path: []const u8, abs: []const u8, sel: []const u8, owner: []const u8, depth: u32 };

/// A place the walk put a file's top-level declaration: whole-file (`x.Name`) or selected
/// (`X = @import("f.zig").Name`; `renamed` when X is not Name). `private` when the placement or
/// any node above it is private (`const variants = @import("ascon.zig")`, a `@"f.zig"` file node):
/// no code outside can write that name.
const Home = struct { path: []const u8, private: bool, renamed: bool, segments: usize };

/// The order of homes: a public path before a private one; the declaration's own name before a
/// rename (`std.crypto.ecc.Curve25519` over `std.crypto.dh.X25519.Curve`, both
/// `@import("curve25519.zig").Curve25519`); then the shorter path. Neither autodoc nor the
/// compiler ranks re-exports; both name a declaration after where it is defined, and of the
/// writable names this is the closest to that.
fn betterHome(a: Home, b: Home) bool {
    if (a.private != b.private) return !a.private;
    if (a.renamed != b.renamed) return !a.renamed;
    return a.segments < b.segments;
}

/// Is any node above `path` private? Parents are emitted before the walk descends into them.
fn underPrivate(w: *const W, path: []const u8) bool {
    var p = parent(path);
    while (p.len > 0) : (p = parent(p)) if (w.private_nodes.contains(p)) return true;
    return false;
}

fn segmentsOf(path: []const u8) usize {
    var n: usize = 0;
    var p = path;
    while (p.len > 0) : (n += 1) p = parent(p);
    return n;
}

/// One home per declaration: the walk meets `key` (`rel\x00Name`) at `cp`. Returns the home `cp`
/// is an alias of, or null when `cp` is the home. The best placement is not known until the whole
/// tree is walked, so `runNamed` walks again with the previous pass's best homes in `selected`,
/// until each home is the best placement and was reached; on the first pass the first placement
/// met is the home. Of equal placements the first met wins, in the final tree's walk order (not
/// whatever an earlier pass chose, which would carry over placements that no longer exist).
fn homeOf(w: *W, key: []const u8, cp: []const u8, is_pub: bool, renamed: bool) !?[]const u8 {
    const here: Home = .{ .path = cp, .private = !is_pub or underPrivate(w, cp), .renamed = renamed, .segments = segmentsOf(cp) };
    const gop = try w.best.getOrPut(key);
    if (!gop.found_existing or betterHome(here, gop.value_ptr.*)) gop.value_ptr.* = here;
    if (w.selected.get(key)) |home| return if (std.mem.eql(u8, home, cp)) null else home;
    try w.selected.put(key, cp);
    return null;
}

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
    var start = ast.firstToken(node);
    while (start > 0 and ast.tokenTag(start - 1) == .doc_comment) start -= 1;
    return docRun(w, ast, start, .doc_comment, "///");
}

/// A file's own `//!` doc: the container doc comments it opens with ("" if none).
fn fileDoc(w: *W, ast: *const Ast) ![]const u8 {
    return docRun(w, ast, 0, .container_doc_comment, "//!");
}

/// The run of `tag` comment tokens starting at `start`, markers stripped, whitespace-collapsed.
fn docRun(w: *W, ast: *const Ast, start: Ast.TokenIndex, tag: std.zig.Token.Tag, marker: []const u8) ![]const u8 {
    var end = start;
    while (end < ast.tokens.len and ast.tokenTag(end) == tag) end += 1;
    if (start == end) return "";
    var total: usize = 0;
    var t = start;
    while (t < end) : (t += 1) total += ast.tokenSlice(t).len + 1;
    const raw = try w.arena.alloc(u8, total);
    var n: usize = 0;
    t = start;
    while (t < end) : (t += 1) {
        var txt = ast.tokenSlice(t);
        if (std.mem.startsWith(u8, txt, marker)) txt = txt[marker.len..];
        @memcpy(raw[n..][0..txt.len], txt);
        n += txt.len;
        raw[n] = ' ';
        n += 1;
    }
    return collapse(w.arena, raw[0..n]);
}

/// A namespace's doc: the `///` on the line that imports it, then the file's own `//!`.
fn joinDocs(w: *W, decl_doc: []const u8, file_doc: []const u8) ![]const u8 {
    if (decl_doc.len == 0) return file_doc;
    if (file_doc.len == 0) return decl_doc;
    return std.fmt.allocPrint(w.arena, "{s} {s}", .{ decl_doc, file_doc });
}

/// A fn's as-written signature: the `fn` keyword through the return type, whitespace-collapsed.
fn fnSig(w: *W, ast: *const Ast, proto: *const Ast.full.FnProto) !?[]const u8 {
    const ret = proto.ast.return_type.unwrap() orelse return null;
    const starts = ast.tokens.items(.start);
    const last = ast.lastToken(ret);
    const start = starts[proto.ast.fn_token];
    const end = starts[last] + @as(u32, @intCast(ast.tokenSlice(last).len)); // zsnag:ok — R007: a token is shorter than the source, and Ast offsets are u32
    // drop `//` and `///` comments first: collapsed onto one line, a comment would swallow the rest
    return try collapse(w.arena, try stripComments(w.arena, ast.source[start..end]));
}

/// `s` without its `//` comments (to the end of each line). A `//` inside a string or character
/// literal is kept.
fn stripComments(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.find(u8, s, "//") == null) return s;
    const out = try arena.alloc(u8, s.len);
    var n: usize = 0;
    var quote: u8 = 0; // the open literal's delimiter, or 0
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (c == '\\' and i + 1 < s.len) {
                out[n] = c;
                out[n + 1] = s[i + 1];
                n += 2;
                i += 1;
                continue;
            }
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '/' and i + 1 < s.len and s[i + 1] == '/') {
            while (i < s.len and s[i] != '\n') i += 1;
            if (i < s.len) {
                out[n] = '\n';
                n += 1;
            }
            continue;
        }
        out[n] = c;
        n += 1;
    }
    return out[0..n];
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

/// A fn's leading qualifier — `extern` / `export` / `inline`, an extern with its library
/// (`extern "kernel32"`) — or "" (the `sig` attr starts at the `fn` keyword, so these, which
/// precede it, would otherwise be lost).
fn fnMod(w: *W, ast: *const Ast, proto: *const Ast.full.FnProto) ![]const u8 {
    const t = proto.extern_export_inline_token orelse return "";
    const lib = proto.lib_name orelse return ast.tokenSlice(t);
    return std.fmt.allocPrint(w.arena, "{s} {s}", .{ ast.tokenSlice(t), ast.tokenSlice(lib) });
}

/// Emit each member of a named `error{A, B, C}` literal as an `errmember` attr on the decl. Members
/// can carry `///` doc-comments and span lines, so within each comma-separated chunk we take the
/// last non-comment line and pull its leading identifier (or `@"…"`) — never raw text (a value with
/// an embedded newline would corrupt the TSV).
fn emitErrMembers(w: *W, cp: []const u8, src: []const u8) !void {
    const lb = std.mem.findScalar(u8, src, '{') orelse return;
    const rb = std.mem.findScalarLast(u8, src, '}') orelse return;
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
        const close = std.mem.findScalarPos(u8, t, 2, '"') orelse return t;
        return t[0 .. close + 1];
    }
    var j: usize = 0;
    while (j < t.len and (std.ascii.isAlphanumeric(t[j]) or t[j] == '_')) j += 1;
    return t[0..j];
}

fn importTarget(src: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, src, " \t\r\n");
    if (!std.mem.startsWith(u8, t, "@import(")) return null;
    const o = std.mem.findScalar(u8, t, '"') orelse return null;
    const rest = t[o + 1 ..];
    const c = std.mem.findScalar(u8, rest, '"') orelse return null;
    return rest[0..c];
}

/// Read + parse a child file, arena-storing the Ast so it outlives the recursive walk. null on
/// read/parse failure (the caller emits an `nserr` leaf).
fn parseChild(w: *W, abs: []const u8) ?*Ast {
    if (w.ast_cache.get(abs)) |a| return a; // already parsed this build — reuse (Asts are arena-persistent)
    const src = std.Io.Dir.cwd().readFileAllocOptions(w.io, abs, w.arena, .unlimited, .of(u8), 0) catch return null;
    const a = w.arena.create(Ast) catch return null;
    a.* = compat.parseZig(w.arena, src) catch return null;
    if (a.errors.len != 0) return null;
    w.ast_cache.put(abs, a) catch {}; // zsnag:ok — a failed cache insert only means this file is re-parsed later, same output
    return a;
}

fn isAliasChain(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') continue;
        // a quoted segment, `crc.@"CRC-32/ISO-HDLC"`, is a name like any other
        if (c == '@' and i > 0 and s[i - 1] == '.') if (quotedEnd(s, i)) |e| {
            i = e - 1;
            continue;
        };
        return false;
    }
    return true;
}

/// Past the `@"…"` identifier starting at `s[i]`, or null when there is none.
fn quotedEnd(s: []const u8, i: usize) ?usize {
    if (i + 1 >= s.len or s[i] != '@' or s[i + 1] != '"') return null;
    const close = std.mem.findScalarPos(u8, s, i + 2, '"') orelse return null;
    return close + 1;
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
/// `[N]Elem`→`Elem`, `[]align(4) u8`→`u8`, `?Node.Index`→`Node.Index`, `ArrayList(u8)`→`ArrayList`,
/// `@This()`→`@This`. "" if none. A `[…]` group (array length, sentinel) and an `align(…)` /
/// `addrspace(…)` qualifier hold values, not the referenced type, so they are skipped whole.
fn extractBase(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '[') {
            i = skipGroup(s, i, '[', ']');
            continue;
        }
        // start of an identifier or @builtin
        if (std.ascii.isAlphabetic(s[i]) or s[i] == '_' or s[i] == '@') {
            var j = i + 1;
            while (j < s.len) {
                if (std.ascii.isAlphanumeric(s[j]) or s[j] == '_' or s[j] == '.') {
                    j += 1;
                } else if (s[j] == '@' and s[j - 1] == '.') { // `OptionalHeader.@"PE32+"`
                    j = quotedEnd(s, j) orelse break;
                } else break;
            }
            const word = s[i..j];
            // decoration keywords are not the referenced type — skip and keep scanning
            if (std.mem.eql(u8, word, "const") or std.mem.eql(u8, word, "volatile") or
                std.mem.eql(u8, word, "allowzero") or std.mem.eql(u8, word, "comptime") or
                std.mem.eql(u8, word, "error"))
            {
                i = j;
                continue;
            }
            if (std.mem.eql(u8, word, "align") or std.mem.eql(u8, word, "addrspace")) {
                var k = j;
                while (k < s.len and s[k] == ' ') k += 1;
                if (k < s.len and s[k] == '(') {
                    i = skipGroup(s, k, '(', ')');
                    continue;
                }
            }
            return word;
        }
        i += 1;
    }
    return "";
}

/// The index just past the group that opens at `s[start]`, nesting included (or `s.len`).
fn skipGroup(s: []const u8, start: usize, open: u8, close: u8) usize {
    var depth: usize = 0;
    var i = start;
    while (i < s.len) : (i += 1) {
        if (s[i] == open) depth += 1 else if (s[i] == close) {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return s.len;
}

/// True when `raw` is an anonymous container literal in type position — `struct {…}`,
/// `enum(u8) {…}`, `union(enum) {…}`, `opaque {…}`, `error{…}` (optionally `extern`/`packed`).
/// The leading keyword is what marks it, NOT the mere presence of `{`: `Tuple(&.{u8})` and
/// `meta.Int(.{…})` carry a brace but reference a real decl, so they must resolve, not bucket as inline.
fn isInlineContainer(raw: []const u8) bool {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.findScalar(u8, s, '{') == null) return false;
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

/// Resolve a bare name in src's lexical scope: try container.name, then walk up the ancestors (from
/// a re-exported Sel, through the file it is declared in: `lexical`).
fn resolveBare(w: *W, container: []const u8, name: []const u8) ?[]const u8 {
    var scope = container;
    while (true) {
        const cand = if (scope.len == 0) name else std.fmt.allocPrint(w.arena, "{s}.{s}", .{ scope, name }) catch return null;
        if (w.node_set.contains(cand)) return cand;
        // a name of a re-exported file whose home is elsewhere (`Config` in debug_allocator.zig
        // is `std.heap.DebugAllocatorConfig`): it resolves there
        if (w.lexical_names.get(cand)) |home| return home;
        if (scope.len == 0) return null;
        scope = w.lexical.get(scope) orelse parent(scope); // a re-exported Sel continues in its own file
    }
}

/// True if `base` is a comptime type param in scope at `src`: declared by `src` itself (a fn's
/// own `comptime T: type`) or by an ancestor (a factory, whose params cover all of `<fn>()`).
fn isGenericParam(w: *W, src: []const u8, base: []const u8) bool {
    var a = src;
    while (true) {
        const key = std.fmt.allocPrint(w.arena, "{s}#{s}", .{ a, base }) catch return false;
        if (w.generics.contains(key)) return true;
        if (a.len == 0) return false;
        a = parent(a);
    }
}

/// Is `head`, the first segment of a dotted path written at `src`, a comptime param in scope, or
/// an alias (chain) ending at one?
fn genericHead(w: *W, src: []const u8, container: []const u8, head: []const u8, fuel: u8) bool {
    if (isGenericParam(w, src, head)) return true;
    var node = resolveBare(w, container, head) orelse return false;
    var f = fuel;
    while (f > 0) : (f -= 1) {
        const t = w.aliases.get(node) orelse return false;
        const r = resolve(w, node, t, f - 1);
        switch (r.scope) {
            .generic => return true,
            .local, .cross => node = r.target,
            else => return false,
        }
    }
    return false;
}

/// Record a fn's compile-time params under `owner` — a type (`T: type`), `anytype`, or any
/// `comptime` one (`comptime flag: @EnumLiteral()`) — so a reference to one from `owner` or below
/// (`T`, `T.Index`, `flags = flag`) resolves to a `generic` scope: fixed per instance, no node.
fn registerTypeParams(w: *W, ast: *const Ast, proto: *const Ast.full.FnProto, owner: []const u8) !void {
    var pit = proto.iterate(ast);
    while (pit.next()) |p| {
        const is_comptime = if (p.comptime_noalias) |t| ast.tokenTag(t) == .keyword_comptime else false;
        const is_type_param = is_comptime or p.anytype_ellipsis3 != null or
            (p.type_expr != null and std.mem.eql(u8, std.mem.trim(u8, ast.getNodeSource(p.type_expr.?), " \t\r\n"), "type"));
        if (is_type_param) if (p.name_token) |nt| {
            const key = try std.fmt.allocPrint(w.arena, "{s}#{s}", .{ owner, ast.tokenSlice(nt) });
            try w.generics.put(key, {});
        };
    }
}

/// A resolved node, `local` when it lies inside `container`, else `cross`.
fn placed(container: []const u8, p: []const u8) Res {
    const inside = std.mem.eql(u8, p, container) or
        (p.len > container.len and container.len > 0 and std.mem.startsWith(u8, p, container) and p[container.len] == '.');
    return Res{ .scope = if (inside) .local else .cross, .target = p };
}

/// `rest` (`.Error`, `.KeyIterator.next`) below the node `b`, following what `b` is defined as when
/// the member is not a node under `b` itself: an alias's target, the type a const built by a call
/// is (`BufSetHashMap = StringHashMap(void)` → `StringHashMap().KeyIterator`), each followed in its
/// own scope. Null when nothing is left to follow or `fuel` runs out.
fn memberOf(w: *W, b: []const u8, rest: []const u8, fuel: u8) ?[]const u8 {
    const direct = std.fmt.allocPrint(w.arena, "{s}{s}", .{ b, rest }) catch return null;
    if (w.node_set.contains(direct)) return direct;
    if (fuel == 0) return null;
    if (w.aliases.get(b)) |t| {
        const r = resolve(w, b, t, fuel - 1);
        if (r.scope != .local and r.scope != .cross) return null;
        return memberOf(w, r.target, rest, fuel - 1);
    }
    if (w.instances.get(b)) |callee| {
        const r = resolve(w, b, callee, fuel - 1);
        if (r.scope != .local and r.scope != .cross) return null;
        const produced = instanceOf(w, r.target, fuel - 1) orelse return null;
        return memberOf(w, produced, rest, fuel - 1);
    }
    // A node part-way down `rest` defined as something else (`Edwards25519.scalar`, an alias of
    // `Curve25519.scalar`, in `.scalar.CompressedScalar`): continue from there. The deepest such
    // node first, as `resolveRooted` takes the longest prefix.
    var k = rest.len;
    while (lastDot(rest[0..k])) |d| {
        k = d;
        if (k == 0) break;
        const mid = std.fmt.allocPrint(w.arena, "{s}{s}", .{ b, rest[0..k] }) catch return null;
        if (!w.node_set.contains(mid)) continue;
        if (w.aliases.get(mid) == null and w.instances.get(mid) == null) continue;
        return memberOf(w, mid, rest[k..], fuel - 1);
    }
    return null;
}

/// The last `.` in `s` outside a `@"…"` quoted name (where a dot is part of the name).
fn lastDot(s: []const u8) ?usize {
    var inq = false;
    var last: ?usize = null;
    for (s, 0..) |c, j| {
        if (inq) {
            if (c == '"') inq = false;
        } else if (c == '"') {
            inq = true;
        } else if (c == '.') last = j;
    }
    return last;
}

/// The node of the type a factory fn returns: `<f>()` when the walk descended it; through an
/// alias of the fn; or, for a factory that forwards (`fn SipHash128() type { return SipHash(…); }`),
/// the type of the one it forwards to.
fn instanceOf(w: *W, f: []const u8, fuel: u8) ?[]const u8 {
    const produced = std.fmt.allocPrint(w.arena, "{s}()", .{f}) catch return null;
    if (w.node_set.contains(produced)) return produced;
    if (fuel == 0) return null;
    const next = w.aliases.get(f) orelse w.forwards.get(f) orelse return null;
    const r = resolve(w, f, next, fuel - 1);
    if (r.scope != .local and r.scope != .cross) return null;
    return instanceOf(w, r.target, fuel - 1);
}

/// `base` (`head.rest`, not a node itself) through its longest prefix that is: from there,
/// `memberOf`. Null when no prefix resolves or the member is not found that way.
fn resolvePrefixed(w: *W, container: []const u8, base: []const u8, fuel: u8) ?[]const u8 {
    var k = base.len;
    while (std.mem.findScalarLast(u8, base[0..k], '.')) |d| {
        k = d;
        const p = resolveBare(w, container, base[0..k]) orelse continue;
        return memberOf(w, p, base[k..], fuel);
    }
    return null;
}

/// Resolve `full`, a path written from the tree's root (`std.mem.Allocator.Error`). When the path
/// is not a node itself, its longest walked prefix is, and the rest is found from there
/// (`memberOf`: through aliases and factory instances, each in its own scope).
fn resolveRooted(w: *W, src: []const u8, full: []const u8, fuel: u8) ?Res {
    if (w.node_set.contains(full)) return placed(parent(src), full);
    var k = full.len;
    while (std.mem.findScalarLast(u8, full[0..k], '.')) |d| {
        k = d;
        const p = full[0..k];
        if (!w.node_set.contains(p)) continue;
        const t = memberOf(w, p, full[k..], fuel) orelse return null;
        return placed(parent(src), t);
    }
    return null;
}

/// Classify (and where possible canonicalize) one edge target. `fuel` bounds alias-chasing.
fn resolve(w: *W, src: []const u8, raw: []const u8, fuel: u8) Res {
    const container = w.lexical.get(src) orelse parent(src); // a re-exported fn resolves in its own file
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    // an inline/anonymous type in the signature (`error{…}`, `struct {…}`) — no node to point at.
    if (isInlineContainer(trimmed)) return Res{ .scope = .@"inline", .target = trimmed };
    const base = extractBase(raw);
    if (base.len == 0) return Res{ .scope = .unresolved, .target = raw };

    if (std.mem.eql(u8, base, "@This")) return Res{ .scope = .local, .target = container };
    if (base[0] == '@') return Res{ .scope = .unresolved, .target = raw };

    const dotted = std.mem.findScalar(u8, base, '.') != null;
    if (!dotted and std.zig.primitives.isPrimitive(base)) return Res{ .scope = .primitive, .target = base };
    if (!dotted and (std.mem.eql(u8, base, "type") or std.mem.eql(u8, base, "anytype") or
        std.mem.eql(u8, base, "anyopaque") or std.mem.eql(u8, base, "anyerror") or std.mem.eql(u8, base, "noreturn")))
        return Res{ .scope = .primitive, .target = base };

    if (dotted) {
        const head = base[0..std.mem.findScalar(u8, base, '.').?];
        const head_node = resolveBare(w, container, head) orelse "";
        if (w.imports.get(head_node)) |tgt| {
            const full = std.fmt.allocPrint(w.arena, "{s}{s}", .{ tgt, base[head.len..] }) catch return Res{ .scope = .unresolved, .target = raw };
            // The import is the tree being walked (`std`, or `std.os.uefi` inside std): the rest of
            // the path names a walked node, so resolve it from the root rather than stopping there.
            if (std.mem.eql(u8, tgt, w.root_name) or (std.mem.startsWith(u8, tgt, w.root_name) and tgt.len > w.root_name.len and tgt[w.root_name.len] == '.')) {
                if (resolveRooted(w, src, full, fuel)) |r| return r;
                return Res{ .scope = .unresolved, .target = full };
            }
            // A module outside the tree (`builtin`): keep the whole path, not just its name.
            return Res{ .scope = .module, .target = full };
        }
    }
    if (resolveBare(w, container, base)) |p| return placed(container, p);
    // A member through an alias or a factory instance: `Allocator.Error` (`Allocator` a private
    // alias of `mem.Allocator`), `BufSetHashMap.KeyIterator` (`BufSetHashMap = StringHashMap(void)`).
    if (dotted and fuel > 0) {
        if (resolvePrefixed(w, container, base, fuel - 1)) |p| return placed(container, p);
    }
    // GENERIC PARAM: a comptime param (T/K/V) declared by a factory ancestor — or a path through
    // one (`T.Index`, `Curve.scalar.Scalar` where `Curve` aliases the param): what it names is
    // fixed per instance, so it has no node either.
    if (!dotted and isGenericParam(w, src, base)) return Res{ .scope = .generic, .target = base };
    if (dotted and genericHead(w, src, container, base[0..std.mem.findScalar(u8, base, '.').?], fuel)) return Res{ .scope = .generic, .target = base };
    return Res{ .scope = .unresolved, .target = raw };
}

/// One `error_set` edge per set in `n`: `A || B || C` names three sets, not one.
fn errorSetEdges(w: *W, ast: *const Ast, cp: []const u8, n: Ast.Node.Index) !void {
    if (ast.nodeTag(n) == .merge_error_sets) {
        const d = ast.nodeData(n).node_and_node;
        try errorSetEdges(w, ast, cp, d[0]);
        try errorSetEdges(w, ast, cp, d[1]);
    } else try w.edge(cp, "error_set", try typeText(w, ast, n));
}

fn fnEdges(w: *W, ast: *const Ast, cp: []const u8, m: Ast.Node.Index, proto: *const Ast.full.FnProto) !void {
    if (proto.ast.return_type.unwrap()) |rt| {
        if (ast.nodeTag(rt) == .error_union) {
            const d = ast.nodeData(rt).node_and_node;
            try errorSetEdges(w, ast, cp, d[0]);
            try w.edge(cp, "has_type", try typeText(w, ast, d[1]));
        } else try w.edge(cp, "has_type", try typeText(w, ast, rt));
    }
    var it = proto.iterate(ast);
    while (it.next()) |p| {
        if (p.type_expr) |te| try w.edge(cp, "has_type", try typeText(w, ast, te));
    }
    if (ast.nodeTag(m) == .fn_decl) switch (classifyFactory(ast, m, proto)) {
        .delegate => |tgt| {
            const t = try collapse(w.arena, tgt);
            try w.edge(cp, "delegates", t);
            try w.forwards.put(cp, t);
        },
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
    try w.attr(cp, "mod", try fnMod(w, ast, proto)); // extern/export/inline (sparse; sig starts at `fn`)
    try registerTypeParams(w, ast, proto, cp); // `fn f(comptime T: type, x: T)`: T is the fn's own
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
            // the factory's type params are in scope for every member of `<fn>()`
            try registerTypeParams(w, ast, proto, child);
            const first_edge = w.edges.items.len;
            try walk(w, ast, cd.ast.members, child, ck, dir, depth + 1, rel);
            // A factory that returns a different type under some condition (`if (non-exhaustive)
            // return struct {…};` before the final `return struct {…}`): each earlier one is a
            // variant `<fn>().[return<k>]`, k-th in source order, as the arms of a per-platform
            // const are.
            var nested: std.ArrayList(Ast.Node.Index) = .empty;
            try containerReturns(w, ast, ast.nodeData(node).node_and_node[1], &nested);
            var ordinal: usize = 0;
            for (nested.items) |r| {
                if (r == d) continue;
                const line = try lineOf(w, ast.source, rel, ast.tokens.items(.start)[ast.firstToken(r)]);
                ordinal += 1; // by order, not line: a label must survive edits elsewhere in the file
                const vname = try std.fmt.allocPrint(w.arena, "[return{d}]", .{ordinal});
                const vp = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ child, vname });
                var rbuf: [2]Ast.Node.Index = undefined;
                const rd = ast.fullContainerDecl(&rbuf, r).?;
                const rk = ast.tokenSlice(rd.ast.main_token);
                try w.attr(vp, "loc", try locOf(w, ast, r, rel));
                try w.attr(vp, "when", try std.fmt.allocPrint(w.arena, "the return at {s}:{d}, under the condition around it", .{ rel, line }));
                try w.node(vp, rk, vname, vis);
                try registerTypeParams(w, ast, proto, vp);
                try walk(w, ast, rd.ast.members, vp, rk, dir, depth + 1, rel);
            }
            // after the product and its variants, whose public members say which locals they name
            try factoryLocals(w, ast, node, child, first_edge, dir, depth, rel);
        },
        else => {},
    }
}

fn walk(w: *W, ast: *const Ast, members: []const Ast.Node.Index, path: []const u8, parent_kind: []const u8, base_dir: []const u8, depth: u32, rel: []const u8) !void {
    var tuple_idx: usize = 0; // names unnamed (positional) tuple fields per container
    // A file's top-level declarations have one home each: the first place the walk puts them,
    // whole (`@import("f.zig")`) or selected (`@import("f.zig").Name`). Met again, a declaration
    // is an alias of that home, not a second copy of its subtree.
    const at_file_root = members.len > 0 and std.mem.findScalar(Ast.Node.Index, ast.rootDecls(), members[0]) != null;
    for (members) |m| {
        if (at_file_root) if (declName(ast, m)) |dn| {
            const key = try std.fmt.allocPrint(w.arena, "{s}\x00{s}", .{ rel, dn });
            const cp = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ path, dn });
            if (try homeOf(w, key, cp, isPubDecl(ast, m), false)) |home| {
                try declFacts(w, cp, try locOf(w, ast, m, rel), try docComment(w, ast, m));
                try w.node(cp, "alias", dn, if (isPubDecl(ast, m)) "pub" else "priv");
                try w.edge(cp, "alias", home);
                try w.aliases.put(cp, home);
                continue;
            }
        };
        // test / doctest → an `example` fact on the decl it documents (`test <ident>`) or on the
        // enclosing namespace (`test "…"`). Attached by owner path, in the shape's attrs stream.
        if (ast.nodeTag(m) == .test_decl) {
            var owner = path;
            const nt = ast.nodeData(m).opt_token_and_node[0];
            if (nt.unwrap()) |tok| if (ast.tokenTag(tok) == .identifier) {
                const nm = ast.tokenSlice(tok);
                const base = if (std.mem.findScalarLast(u8, path, '.')) |k| path[k + 1 ..] else path;
                owner = if (std.mem.eql(u8, nm, base)) path else try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ path, nm });
            };
            owner = w.lexical_names.get(owner) orelse owner; // `test Sel` in a re-exported file: Sel's real path
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
            if (field.ast.type_expr.unwrap()) |te| {
                // the edge names the referenced type (`?*Node` → Node); the attr keeps the type as written
                const tt = try typeText(w, ast, te);
                try w.edge(cp, "has_type", tt);
                try w.attr(cp, "type", tt);
                // a container written as the field's type (`relative: struct { … }`): its members
                // live under the field, as under any container
                if (containerKind(ast, te)) |fk| {
                    var tbuf: [2]Ast.Node.Index = undefined;
                    const fcd = ast.fullContainerDecl(&tbuf, te).?;
                    try walk(w, ast, fcd.ast.members, cp, fk, base_dir, depth + 1, rel);
                }
            }
            if (field.ast.value_expr.unwrap()) |ve| try w.attr(cp, "value", try typeText(w, ast, ve));
            continue;
        }
        // var/const decls
        const vd = ast.fullVarDecl(m) orelse continue;
        const name = ast.tokenSlice(vd.ast.mut_token + 1);
        const vis = if (vd.visib_token != null) "pub" else "priv";
        const cp = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ path, name });
        try varFacts(w, ast, vd, cp);
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
        if (try emitImport(w, ast, init, init_src, cp, name, vis, isVar(ast, vd), decl_loc, decl_doc, path, base_dir, depth, rel)) continue;
        try declFacts(w, cp, decl_loc, decl_doc);
        try emitInit(w, ast, init, cp, name, vis, isVar(ast, vd), vd.ast.type_node.unwrap(), path, base_dir, depth, rel);
    }
}

/// A declaration whose initializer is an `@import` — a module reference, a whole file (walked
/// once, at its first import), or one declaration of a file (`emitReexport`). The one place for
/// this, shared by declarations (`walk`) and the arms of per-platform consts (`emitArm`), so an
/// `@import` in a switch arm (`arch_bits = switch (native_arch) { .x86_64 =>
/// @import("linux/x86_64.zig"), … }`) maps its file like any other. False when `init_src` is
/// not an import.
fn emitImport(w: *W, ast: *const Ast, init: Ast.Node.Index, init_src: []const u8, cp: []const u8, name: []const u8, vis: []const u8, mutable: bool, decl_loc: []const u8, decl_doc: []const u8, path: []const u8, base_dir: []const u8, depth: u32, rel: []const u8) anyerror!bool {
    const tgt = importTarget(init_src) orelse return false;
    const sel = selectorOf(init_src);
    // `@import("f").foo()` — a CALL selector yields a computed value/type we can't resolve by
    // parsing (it needs the compiler). Neither a namespace nor a plain re-export: a const.
    if (std.mem.findScalar(u8, sel, '(') != null) {
        try declFacts(w, cp, decl_loc, decl_doc);
        try emitInit(w, ast, init, cp, name, vis, mutable, null, path, base_dir, depth, rel);
        return true;
    }
    const bare = sel.len == 0; // `@import("x")` vs `@import("x").Sel`
    if (!std.mem.endsWith(u8, tgt, ".zig")) {
        // An expression on a module (`@import("builtin").mode == .debug`) is a value, not a
        // reference to the module: a const with its initializer.
        if (!bare and !isAliasChain(sel)) {
            try declFacts(w, cp, decl_loc, decl_doc);
            try w.node(cp, "const", name, vis);
            try w.attr(cp, "value", try collapse(w.arena, std.mem.trim(u8, init_src, " \t\r\n")));
            return true;
        }
        // a MODULE we don't own (std / builtin / root) — external, never followed. Keyed by
        // this node's path, so the name resolves lexically like any other declaration (one
        // file's `uefi = @import("std").os.uefi` must not redefine `uefi` in another file),
        // with the selector kept: `uefi.tables` is `std.os.uefi.tables`.
        try declFacts(w, cp, decl_loc, decl_doc);
        try w.node(cp, "modref", name, vis);
        try w.imports.put(cp, if (bare) tgt else try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ tgt, sel }));
        try w.edge(cp, "imports", tgt);
        return true;
    }
    if (!bare) { // `@import("x").Sel` — FOLLOW it, place Sel under cp (its single home).
        const rabs = std.fs.path.resolve(w.arena, &.{ base_dir, tgt }) catch {
            try declFacts(w, cp, decl_loc, decl_doc);
            try w.node(cp, "alias", name, vis);
            try w.edge(cp, "alias", tgt);
            try w.aliases.put(cp, tgt);
            return true;
        };
        try emitReexport(w, rabs, sel, cp, name, vis, depth + 1, decl_loc, decl_doc);
        return true;
    }
    // an OWNED .zig file — FOLLOW it, once, building the full tree.
    const abs = std.fs.path.resolve(w.arena, &.{ base_dir, tgt }) catch {
        try declFacts(w, cp, decl_loc, decl_doc);
        try w.node(cp, "nserr", name, vis);
        return true;
    };
    try w.edge(cp, "imports", tgt);
    if (w.visited.contains(abs) or depth >= MAX_DEPTH) {
        try declFacts(w, cp, decl_loc, decl_doc);
        try w.node(cp, "nsref", name, vis); // already expanded elsewhere (its canonical home)
        try w.nsrefs.append(w.arena, .{ cp, abs });
        return true;
    }
    if (parseChild(w, abs)) |child| {
        try declFacts(w, cp, decl_loc, try joinDocs(w, decl_doc, try fileDoc(w, child)));
        try w.visited.put(abs, {}); // mark visited only on a successful parse — a failed
        try w.file_home.put(abs, cp);
        try w.node(cp, "ns", name, vis); // read stays `nserr` and can be retried elsewhere
        const child_dir = std.fs.path.dirname(abs) orelse ".";
        try walk(w, child, child.rootDecls(), cp, "struct", child_dir, depth + 1, relOf(w, abs));
    } else {
        try declFacts(w, cp, decl_loc, decl_doc);
        try w.node(cp, "nserr", name, vis);
    }
    return true;
}

/// A var/const's own qualifiers (`mod`) and declared type (`const x: T`), shared by `walk` and
/// `emitReexport`.
fn varFacts(w: *W, ast: *const Ast, vd: Ast.full.VarDecl, cp: []const u8) !void {
    try w.attr(cp, "mod", try varMod(w, ast, vd)); // var/extern/export/threadlocal/comptime (sparse)
    if (vd.ast.type_node.unwrap()) |tn| { // `const x: T = …` — the declared type, as written
        const tt = try typeText(w, ast, tn);
        try w.attr(cp, "type", tt);
        try w.edge(cp, "has_type", tt);
    }
}

/// Is the declaration a `var` (rather than a `const`)?
fn isVar(ast: *const Ast, vd: Ast.full.VarDecl) bool {
    return std.mem.eql(u8, ast.tokenSlice(vd.ast.mut_token), "var");
}

/// The keyword values an initializer can be that read like a name but alias nothing.
fn isValueWord(s: []const u8) bool {
    for ([_][]const u8{ "null", "undefined", "true", "false", "unreachable" }) |k| if (std.mem.eql(u8, s, k)) return true;
    return false;
}

/// What a const's initializer makes it — a container (walked), an alias, `@This()` (an alias of
/// `container`), or a value: its text, and the error sets it merges, the factory it calls, or
/// the arms it chooses between. The one place for this, shared by declarations in place (`walk`)
/// and followed re-exports (`emitReexport`), so the two cannot record a const differently.
fn emitInit(w: *W, ast: *const Ast, init: Ast.Node.Index, cp: []const u8, name: []const u8, vis: []const u8, mutable: bool, declared: ?Ast.Node.Index, container: []const u8, base_dir: []const u8, depth: u32, rel: []const u8) anyerror!void {
    if (containerKind(ast, init)) |ck| {
        try w.node(cp, ck, name, vis);
        var cbuf: [2]Ast.Node.Index = undefined;
        const cd = ast.fullContainerDecl(&cbuf, init).?;
        try walk(w, ast, cd.ast.members, cp, ck, base_dir, depth + 1, rel);
        return;
    }
    const trimmed = std.mem.trim(u8, ast.getNodeSource(init), " \t\r\n");
    // a `var` holds a value whatever it starts as; `null`/`undefined`/`true`/`false` are values
    if (!mutable and isAliasChain(trimmed) and !isValueWord(trimmed)) {
        try w.node(cp, "alias", name, vis);
        try w.edge(cp, "alias", trimmed);
        try w.aliases.put(cp, trimmed);
    } else if (std.mem.eql(u8, trimmed, "@This()")) {
        // `const Self = @This();` names its own container
        try w.node(cp, "alias", name, vis);
        try w.edge(cp, "alias", trimmed);
        try w.aliases.put(cp, container);
    } else {
        try w.node(cp, "const", name, vis);
        try w.attr(cp, "value", try collapse(w.arena, trimmed)); // the initializer as written
        try emitVariants(w, ast, init, cp, base_dir, depth, rel); // `switch (native_os) {…}`
        if (ast.nodeTag(init) == .merge_error_sets) {
            try errorSetEdges(w, ast, cp, init); // `Error = A || B`
        } else {
            // `Sha256 = Sha2x32(iv256, 256)`: the const is what that factory returns
            var cbuf: [1]Ast.Node.Index = undefined;
            if (ast.fullCall(&cbuf, init)) |call| {
                // a decl literal (`x: Allocator = .init(…)`) calls a member of the declared type
                const written = try typeText(w, ast, call.ast.fn_expr);
                const callee = if (std.mem.startsWith(u8, written, ".") and declared != null) try std.fmt.allocPrint(w.arena, "{s}{s}", .{ try typeText(w, ast, declared.?), written }) else written;
                try w.edge(cp, "instantiates", callee);
                try w.instances.put(cp, callee);
            }
        }
    }
}

/// A const chosen per platform or option — `switch (native_os) { .linux => linux.IPPROTO,
/// .macos => struct {…}, else => void }`, or `if (cond) A else B` — has no single shape to map, so
/// each arm becomes a variant node under it, `<cp>.[<label>]` (bracketed like a tuple field's
/// `[0]`, so a path still splits on its dots): `std.c.IPPROTO.[macos].TCP`. The label is the
/// prong's tags (`[linux,emscripten]`, `[else]`) or `[then]`/`[else]` for an `if`; the arm's full
/// condition is its `when` attr. An arm is walked like any const: a container literal's members,
/// an alias, a nested switch/if, or a value. Not a switch/if: nothing.
fn emitVariants(w: *W, ast: *const Ast, n: Ast.Node.Index, cp: []const u8, base_dir: []const u8, depth: u32, rel: []const u8) anyerror!void {
    if (ast.fullSwitch(n)) |sw| {
        for (sw.ast.cases, 0..) |case_node, k| {
            const case = ast.fullSwitchCase(case_node).?;
            const vals = case.ast.values;
            const when = if (vals.len == 0) "else" else try collapse(w.arena, ast.source[ast.tokens.items(.start)[ast.firstToken(vals[0])]..ast.tokens.items(.start)[case.ast.arrow_token]]);
            const label = try armLabel(w, ast, vals, k);
            try emitArm(w, ast, case.ast.target_expr, cp, label, std.mem.trim(u8, when, " "), base_dir, depth, rel);
        }
    } else if (ast.fullIf(n)) |iff| {
        try emitArm(w, ast, iff.ast.then_expr, cp, "then", try typeText(w, ast, iff.ast.cond_expr), base_dir, depth, rel);
        if (iff.ast.else_expr.unwrap()) |e| try emitArm(w, ast, e, cp, "else", "else", base_dir, depth, rel);
    } else if (ast.nodeTag(n) == .@"orelse") {
        // `std.Options.FilePermissions orelse if (is_windows) enum {…} else …`: the option when
        // it is set, else the default (whose own arms are split under `[orelse]`)
        const lhs, const rhs = ast.nodeData(n).node_and_node;
        const opt = try typeText(w, ast, lhs);
        try emitArm(w, ast, lhs, cp, "given", try std.fmt.allocPrint(w.arena, "{s} != null", .{opt}), base_dir, depth, rel);
        try emitArm(w, ast, rhs, cp, "orelse", try std.fmt.allocPrint(w.arena, "{s} == null", .{opt}), base_dir, depth, rel);
    }
}

/// A prong's label: its enum tags without the dots, comma-joined (`.linux, .emscripten` →
/// `linux,emscripten`), `else` for the else prong; `arm<k>` when a value is anything else (a
/// range, an expression), whose text stays in the `when` attr.
fn armLabel(w: *W, ast: *const Ast, vals: []const Ast.Node.Index, k: usize) ![]const u8 {
    if (vals.len == 0) return "else";
    var out: std.ArrayList(u8) = .empty;
    for (vals, 0..) |v, i| {
        const src = std.mem.trim(u8, ast.getNodeSource(v), " \t\r\n");
        const tag = if (std.mem.startsWith(u8, src, ".")) src[1..] else src;
        if (tag.len == 0 or !isAliasChain(tag) or std.mem.findScalar(u8, tag, '.') != null) return std.fmt.allocPrint(w.arena, "arm{d}", .{k});
        if (i > 0) try out.append(w.arena, ',');
        try out.appendSlice(w.arena, tag);
    }
    return out.items;
}

/// One variant: the node `<cp>.[<label>]`, its `when`, and what the arm evaluates to.
fn emitArm(w: *W, ast: *const Ast, expr: Ast.Node.Index, cp: []const u8, label: []const u8, when: []const u8, base_dir: []const u8, depth: u32, rel: []const u8) anyerror!void {
    const name = try std.fmt.allocPrint(w.arena, "[{s}]", .{label});
    const vp = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ cp, name });
    if (w.node_set.contains(vp)) return; // a repeated label (two `arm<k>` cannot collide; tags cannot repeat)
    const loc = try locOf(w, ast, expr, rel);
    try w.attr(vp, "when", when);
    // `impl: { break :impl @import("aes/aesni.zig"); }`: the arm is what its block breaks with
    const value = blockResult(ast, expr) orelse expr;
    if (try emitImport(w, ast, value, ast.getNodeSource(value), vp, name, "pub", false, loc, "", cp, base_dir, depth, rel)) return;
    try w.attr(vp, "loc", loc);
    if (containerKind(ast, value)) |ck| {
        try w.node(vp, ck, name, "pub");
        var cbuf: [2]Ast.Node.Index = undefined;
        const cd = ast.fullContainerDecl(&cbuf, value).?;
        try walk(w, ast, cd.ast.members, vp, ck, base_dir, depth + 1, rel);
        return;
    }
    const src = std.mem.trim(u8, ast.getNodeSource(value), " \t\r\n");
    if (isAliasChain(src) and !isValueWord(src)) {
        try w.node(vp, "alias", name, "pub");
        try w.edge(vp, "alias", src);
        try w.aliases.put(vp, src);
        return;
    }
    try w.node(vp, "const", name, "pub");
    try w.attr(vp, "value", try collapse(w.arena, src));
    try emitVariants(w, ast, value, vp, base_dir, depth + 1, rel);
}

/// The consts a factory's body declares around its `return struct {…}` (`const Block =
/// [BlockCipher.block.block_length]u8;`) are the factory's machinery and are not mapped — except
/// one a public member of the product names (`k1: Block`, `fn initComptime(…) ReturnType`): code
/// using the product reaches it, so it is mapped, private (no code outside the fn can write its
/// name), under `<fn>()` where the product's names resolve. A local mapped so is surface in turn:
/// one its public members name is mapped too (`ReturnType.enum_to_oid: EnumToOid`), until no more.
/// `first_edge` is where the product's own edges start.
fn factoryLocals(w: *W, ast: *const Ast, fn_node: Ast.Node.Index, child: []const u8, first_edge: usize, dir: []const u8, depth: u32, rel: []const u8) !void {
    var buf: [2]Ast.Node.Index = undefined;
    const stmts = ast.blockStatements(&buf, ast.nodeData(fn_node).node_and_node[1]) orelse return;
    var mapped = std.StringHashMap(void).init(w.arena);
    var added = true;
    while (added) {
        added = false;
        for (stmts) |s| {
            const vd = ast.fullVarDecl(s) orelse continue;
            if (ast.tokenTag(vd.ast.mut_token) != .keyword_const) continue;
            const init = vd.ast.init_node.unwrap() orelse continue;
            const name = ast.tokenSlice(vd.ast.mut_token + 1);
            const cp = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ child, name });
            if (mapped.contains(cp)) continue;
            if (w.node_set.contains(cp)) continue; // a member of the product really named so
            if (!namedByPublicMember(w, child, first_edge, name, &mapped)) continue;
            try declFacts(w, cp, try locOf(w, ast, s, rel), try docComment(w, ast, s));
            try emitInit(w, ast, init, cp, name, "priv", false, vd.ast.type_node.unwrap(), child, dir, depth + 1, rel);
            try mapped.put(cp, {});
            added = true;
        }
    }
}

/// Does an edge of a public member of `child` (from `first_edge` on) name `name` — as the type,
/// alias target or error set it refers to, or the head of a path through it (`State.rate`)? A
/// local already `mapped` counts as public here: code using the product reaches it.
fn namedByPublicMember(w: *W, child: []const u8, first_edge: usize, name: []const u8, mapped: *const std.StringHashMap(void)) bool {
    for (w.edges.items[first_edge..]) |e| {
        if (!(e.src.len > child.len and std.mem.startsWith(u8, e.src, child) and e.src[child.len] == '.')) continue;
        var p = e.src;
        const public = while (p.len > child.len) : (p = parent(p)) {
            if (w.private_nodes.contains(p) and !mapped.contains(p)) break false;
        } else true;
        if (!public) continue;
        const base = extractBase(e.target);
        const head = base[0 .. std.mem.findScalar(u8, base, '.') orelse base.len];
        if (std.mem.eql(u8, head, name)) return true;
    }
    return false;
}

/// Every `return <container literal>` in a fn body, through blocks and `if`/`else` (not into
/// nested functions or containers, whose returns are their own), in source order.
fn containerReturns(w: *W, ast: *const Ast, n: Ast.Node.Index, out: *std.ArrayList(Ast.Node.Index)) !void {
    var buf: [2]Ast.Node.Index = undefined;
    if (ast.blockStatements(&buf, n)) |stmts| {
        for (stmts) |s| try containerReturns(w, ast, s, out);
    } else if (ast.fullIf(n)) |iff| {
        try containerReturns(w, ast, iff.ast.then_expr, out);
        if (iff.ast.else_expr.unwrap()) |e| try containerReturns(w, ast, e, out);
    } else if (ast.nodeTag(n) == .@"return") {
        const op = ast.nodeData(n).opt_node.unwrap() orelse return;
        if (containerKind(ast, op) != null) try out.append(w.arena, op);
    }
}

/// The value a labeled block yields when it ends in `break :label value` (`impl: { break :impl
/// @import("aes/soft.zig"); }`), or null for any other node.
fn blockResult(ast: *const Ast, n: Ast.Node.Index) ?Ast.Node.Index {
    var buf: [2]Ast.Node.Index = undefined;
    const stmts = ast.blockStatements(&buf, n) orelse return null;
    if (stmts.len == 0) return null;
    const last = stmts[stmts.len - 1];
    if (ast.nodeTag(last) != .@"break") return null;
    const label, const val = ast.nodeData(last).opt_token_and_opt_node;
    if (label.unwrap() == null) return null;
    return val.unwrap();
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
    const close = std.mem.findScalar(u8, t, ')') orelse return "";
    var s = std.mem.trim(u8, t[close + 1 ..], " \t\r\n");
    if (s.len > 0 and s[0] == '.') s = s[1..];
    return s;
}
/// Is a container member declared `pub`?
fn isPubDecl(ast: *const Ast, m: Ast.Node.Index) bool {
    if (ast.fullVarDecl(m)) |vd| return vd.visib_token != null;
    var fb: [1]Ast.Node.Index = undefined;
    if (ast.fullFnProto(&fb, m)) |proto| return proto.visib_token != null;
    return false;
}

/// The name a container member declares (a var/const or a fn), or null.
fn declName(ast: *const Ast, m: Ast.Node.Index) ?[]const u8 {
    if (ast.fullVarDecl(m)) |vd| return ast.tokenSlice(vd.ast.mut_token + 1);
    var fb: [1]Ast.Node.Index = undefined;
    if (ast.fullFnProto(&fb, m)) |proto| if (proto.name_token) |nt| return ast.tokenSlice(nt);
    return null;
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

/// Settle the files reached only through `@import("f.zig").Sel` (queued by `emitReexport`), after
/// the walk so a whole-file import anywhere wins: such a file's declarations already have a home,
/// and Sel's names resolve there. Otherwise the file gets a private node beside Sel —
/// `<owner>.@"f.zig"` — holding its other declarations and tests, and Sel's names resolve in it
/// (then, past it, in the owner, where Sel itself is). Settling a file can queue more.
fn scopeFiles(w: *W) !void {
    var k: usize = 0;
    while (k < w.deferred.items.len) : (k += 1) {
        const d = w.deferred.items[k];
        if (w.file_home.get(d.abs)) |home| {
            try w.lexical.put(d.sel_path, home);
            continue;
        }
        const ast = parseChild(w, d.abs) orelse continue;
        const fname = try std.fmt.allocPrint(w.arena, "@\"{s}\"", .{std.fs.path.basename(d.abs)});
        const fp = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ d.owner, fname });
        if (w.node_set.contains(fp)) continue; // a declaration really named so: leave it
        try w.visited.put(d.abs, {});
        try w.file_home.put(d.abs, fp);
        const rel = relOf(w, d.abs);
        try w.attr(fp, "loc", try std.fmt.allocPrint(w.arena, "{s}:1", .{rel}));
        try w.attr(fp, "doc", try fileDoc(w, ast));
        try w.node(fp, "ns", fname, "priv");
        // Sel itself already lives at its re-export path (a sibling of `fp`), where a lookup of
        // its name from inside the file lands; only the rest of the file is walked here.
        // So does every other declaration of this file selected somewhere (`chacha20.zig`'s
        // `ChaCha20IETF`, `XChaCha20IETF`, …): each has its home, not a copy here.
        var rest: std.ArrayList(Ast.Node.Index) = .empty;
        for (ast.rootDecls()) |m| {
            const dn = declName(ast, m) orelse "";
            // (a home seeded from an earlier pass may be right here, under `fp`: that one is walked)
            const here = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ fp, dn });
            if (w.selected.get(try std.fmt.allocPrint(w.arena, "{s}\x00{s}", .{ relOf(w, d.abs), dn }))) |home| if (!std.mem.eql(u8, home, here)) {
                try w.lexical_names.put(here, home);
                continue;
            };
            try rest.append(w.arena, m);
        }
        try walk(w, ast, rest.items, fp, "struct", std.fs.path.dirname(d.abs) orelse ".", d.depth + 1, rel);
        try w.lexical.put(d.sel_path, fp);
    }
}

/// Files std imports where no declaration names them — inside a call argument
/// (`Field(.{ .fiat = @import("p256_64.zig"), … })`), a function body, a struct literal — were
/// never walked, so their declarations had no node. After the walk, every walked file's `@import`s
/// of `.zig` files outside `test` blocks are checked; a file not walked yet gets a private node
/// `<home>.@"f.zig"` under the file importing it (as `scopeFiles` does), and is checked in turn.
/// Files are taken in path order, so the map does not depend on hash order.
fn sweepImports(w: *W) !void {
    var todo: std.ArrayList([2][]const u8) = .empty; // (abs, home)
    var it = w.file_home.iterator();
    while (it.next()) |e| try todo.append(w.arena, .{ e.key_ptr.*, e.value_ptr.* });
    std.mem.sort([2][]const u8, todo.items, {}, struct {
        fn lt(_: void, x: [2][]const u8, y: [2][]const u8) bool {
            return std.mem.order(u8, x[1], y[1]) == .lt;
        }
    }.lt);
    var k: usize = 0;
    while (k < todo.items.len) : (k += 1) {
        const abs, const home = todo.items[k];
        const ast = parseChild(w, abs) orelse continue;
        const dir = std.fs.path.dirname(abs) orelse ".";
        // token ranges of `test` blocks: imports there are test-only
        var tests: std.ArrayList([2]Ast.TokenIndex) = .empty;
        for (0..ast.nodes.len) |ni| {
            const n: Ast.Node.Index = @enumFromInt(ni); // zsnag:ok — R007: ni < nodes.len, a valid node index
            if (ast.nodeTag(n) == .test_decl) try tests.append(w.arena, .{ ast.firstToken(n), ast.lastToken(n) });
        }
        const tags = ast.tokens.items(.tag);
        var t: usize = 0;
        while (t + 2 < tags.len) : (t += 1) {
            if (tags[t] != .builtin or tags[t + 1] != .l_paren or tags[t + 2] != .string_literal) continue;
            const ti: Ast.TokenIndex = @intCast(t); // zsnag:ok — R007: t < tokens.len, which fits a TokenIndex
            if (!std.mem.eql(u8, ast.tokenSlice(ti), "@import")) continue;
            const in_test = for (tests.items) |r| {
                if (ti >= r[0] and ti <= r[1]) break true;
            } else false;
            if (in_test) continue;
            const lit = ast.tokenSlice(ti + 2);
            const target = lit[1 .. lit.len - 1];
            if (!std.mem.endsWith(u8, target, ".zig")) continue;
            const abs2 = std.fs.path.resolve(w.arena, &.{ dir, target }) catch continue;
            if (w.visited.contains(abs2)) continue;
            const child = parseChild(w, abs2) orelse continue;
            const fname = try std.fmt.allocPrint(w.arena, "@\"{s}\"", .{std.fs.path.basename(abs2)});
            const fp = try std.fmt.allocPrint(w.arena, "{s}.{s}", .{ home, fname });
            if (w.node_set.contains(fp)) continue;
            try w.visited.put(abs2, {});
            try w.file_home.put(abs2, fp);
            const rel2 = relOf(w, abs2);
            try w.attr(fp, "loc", try std.fmt.allocPrint(w.arena, "{s}:1", .{rel2}));
            try w.attr(fp, "doc", try fileDoc(w, child));
            try w.node(fp, "ns", fname, "priv");
            try walk(w, child, child.rootDecls(), fp, "struct", std.fs.path.dirname(abs2) orelse ".", 1, rel2);
            try todo.append(w.arena, .{ abs2, fp });
        }
    }
}

/// An `nsref` is a file imported again where it was already walked: link it to that walk (its
/// home) with an alias edge, so a name through it (`common.Field`, where `common` is an nsref of
/// common.zig) resolves like through any alias. After the walk and `scopeFiles`, when every file
/// has its home. A file with no home (never walked: a parse failure) stays unlinked.
fn linkNsrefs(w: *W) !void {
    for (w.nsrefs.items) |r| {
        const home = w.file_home.get(r[1]) orelse continue;
        if (std.mem.eql(u8, home, r[0])) continue;
        try w.edge(r[0], "alias", home);
        try w.aliases.put(r[0], home);
    }
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
    if (std.mem.findScalar(u8, sel, '.') != null or depth >= MAX_DEPTH) return leaf(w, cp, name, vis, sel, decl_loc, decl_doc);
    const ast = parseChild(w, abs) orelse {
        try declFacts(w, cp, decl_loc, decl_doc);
        return w.node(cp, "nserr", name, vis);
    };
    const found = findDecl(ast, ast.rootDecls(), sel) orelse return leaf(w, cp, name, vis, sel, decl_loc, decl_doc);
    const dir = std.fs.path.dirname(abs) orelse ".";
    const rel = relOf(w, abs);
    // `Sel` is defined in this file (not re-imported from another): its names are this file's
    // names, and the rest of the file has no other home yet. Settled after the walk (`scopeFiles`).
    // One home per declaration: selected again (`Ristretto255.Curve` and `Edwards25519` are the
    // same `Edwards25519` of edwards25519.zig), it is an alias of its home (`homeOf`).
    const key = try std.fmt.allocPrint(w.arena, "{s}\x00{s}", .{ relOf(w, abs), sel });
    if (try homeOf(w, key, cp, std.mem.eql(u8, vis, "pub"), !std.mem.eql(u8, name, sel))) |home| return leaf(w, cp, name, vis, home, decl_loc, decl_doc);
    const via_import = if (ast.fullVarDecl(found)) |fvd| if (fvd.ast.init_node.unwrap()) |ini| importTarget(ast.getNodeSource(ini)) != null else false else false;
    if (!via_import) try w.deferred.append(w.arena, .{ .sel_path = cp, .abs = abs, .sel = sel, .owner = parent(cp), .depth = depth });

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
    try varFacts(w, ast, vd, cp);
    const init = vd.ast.init_node.unwrap() orelse {
        try declFacts(w, cp, tgt_loc, tgt_doc);
        return w.node(cp, "const", name, vis);
    };
    const isrc = ast.getNodeSource(init);
    if (ast.nodeTag(init) == .error_set_decl) try emitErrMembers(w, cp, isrc); // errmember attrs
    if (importTarget(isrc)) |t2| {
        const isrc_sel = selectorOf(isrc);
        // `@import("f").foo()` — a CALL selector is a computed const, not a followable namespace.
        if (std.mem.findScalar(u8, isrc_sel, '(') != null) {
            try declFacts(w, cp, tgt_loc, tgt_doc);
            return emitInit(w, ast, init, cp, name, vis, isVar(ast, vd), vd.ast.type_node.unwrap(), parent(cp), dir, depth, rel);
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
            if (w.visited.contains(abs2) or depth >= MAX_DEPTH) {
                try w.nsrefs.append(w.arena, .{ cp, abs2 });
                return w.node(cp, "nsref", name, vis);
            }
            if (parseChild(w, abs2)) |c2| {
                try w.visited.put(abs2, {}); // mark visited only on a successful parse
                try w.file_home.put(abs2, cp);
                try w.node(cp, "ns", name, vis);
                try walk(w, c2, c2.rootDecls(), cp, "struct", std.fs.path.dirname(abs2) orelse ".", depth + 1, relOf(w, abs2));
            } else try w.node(cp, "nserr", name, vis);
            return;
        }
    }
    try declFacts(w, cp, tgt_loc, tgt_doc);
    try emitInit(w, ast, init, cp, name, vis, isVar(ast, vd), vd.ast.type_node.unwrap(), parent(cp), dir, depth, rel);
}

/// Scope tallies from edge resolution — returned so the caller can report without re-reading.
pub const Stats = struct {
    nodes: usize,
    edges: usize,
    scope: std.EnumArray(Scope, usize),
    passes: usize = 1, // phase-1 walks it took to settle the homes (`runNamed`)
};

/// Walk `root` (a std.zig path) and write the three TSV streams. `arena` must outlive nothing past
/// return (all working state is arena-scoped); pass a fresh arena per call.
pub fn run(arena: std.mem.Allocator, io: std.Io, root: []const u8, nodes_out: []const u8, edges_out: []const u8, attrs_out: []const u8) !Stats {
    return runNamed(arena, io, root, std.fs.path.stem(root), nodes_out, edges_out, attrs_out, true);
}

/// `run`, with the root node named `root_name` instead of after its file. A package's module
/// root is usually `src/root.zig` or similar; its paths must start with the MODULE name
/// (`clap.parse`), the name code `@import`s it by.
/// `report` prints the per-walk summary to stderr (std's regeneration shows it; `zephem deps`
/// prints one line per module instead).
pub fn runNamed(arena: std.mem.Allocator, io: std.Io, root: []const u8, root_name: []const u8, nodes_out: []const u8, edges_out: []const u8, attrs_out: []const u8, report: bool) !Stats {
    const src = try std.Io.Dir.cwd().readFileAllocOptions(io, root, arena, .unlimited, .of(u8), 0);
    var ast = try compat.parseZig(arena, src);
    var ast_cache = std.StringHashMap(*Ast).init(arena); // parsed once, carried from pass to pass (`walkPass` takes it by value)
    var line_cache = std.StringHashMap([]usize).init(arena);

    // Phase 1, repeated until every declaration's home is its best placement and was reached
    // (`homeOf`). Moving a home moves the paths inside it, so a pass can change the next one's
    // best; std settles in a few passes, and a walk that does not settle fails loudly.
    var prefer = std.StringHashMap([]const u8).init(arena);
    var pass: usize = 0;
    var w = while (true) : (pass += 1) {
        if (pass == MAX_HOME_PASSES) return error.HomesDidNotSettle;
        var pw = try walkPass(arena, io, &ast, root, root_name, nodes_out, attrs_out, &prefer, ast_cache, line_cache);
        ast_cache = pw.ast_cache; // the copies this pass grew; the ones passed in are stale
        line_cache = pw.line_cache;
        // `best` keys ⊆ `selected` keys (homeOf puts both; `prefer` seeds only `selected`), so equal
        // counts mean no seeded home went unmet this pass.
        var settled = pw.selected.count() == pw.best.count();
        var it = pw.best.iterator();
        while (it.next()) |e| {
            const home = pw.selected.get(e.key_ptr.*) orelse unreachable; // homeOf sets both
            if (!std.mem.eql(u8, home, e.value_ptr.path)) settled = false;
        }
        if (settled) break pw;
        prefer = std.StringHashMap([]const u8).init(arena);
        it = pw.best.iterator();
        while (it.next()) |e| try prefer.put(e.key_ptr.*, e.value_ptr.path);
    };

    // Phase 2 — resolve every edge target against the node set, emit with scope.
    var stats = try resolveEdges(&w, root, edges_out, report);
    stats.passes = pass + 1;
    return stats;
}

/// The most phase-1 passes `runNamed` takes to settle the homes before giving up.
const MAX_HOME_PASSES = 8;

/// One phase-1 walk of the whole organism, `prefer` (key → home) seeding `selected`. Writes the
/// nodes and attrs files; the returned W's writers are retired (`failing`), its maps stay valid.
fn walkPass(arena: std.mem.Allocator, io: std.Io, ast: *Ast, root: []const u8, root_name: []const u8, nodes_out: []const u8, attrs_out: []const u8, prefer: *const std.StringHashMap([]const u8), ast_cache: std.StringHashMap(*Ast), line_cache: std.StringHashMap([]usize)) !W {
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
        .instances = std.StringHashMap([]const u8).init(arena),
        .forwards = std.StringHashMap([]const u8).init(arena),
        .generics = std.StringHashMap(void).init(arena),
        .edges = .empty,
        .root_dir = std.fs.path.dirname(root) orelse ".",
        .root_name = root_name,
        .ast_cache = ast_cache,
        .line_cache = line_cache,
        .deferred = .empty,
        .file_home = std.StringHashMap([]const u8).init(arena),
        .lexical = std.StringHashMap([]const u8).init(arena),
        .lexical_names = std.StringHashMap([]const u8).init(arena),
        .nsrefs = .empty,
        .selected = try prefer.clone(),
        .best = std.StringHashMap(Home).init(arena),
        .private_nodes = std.StringHashMap(void).init(arena),
    };
    try w.nodes.print("path\tkind\tname\tvis\n", .{});
    try w.attrs.print("path\tattr\tvalue\n", .{});
    try w.node(root_name, "ns", root_name, "pub");
    try w.attr(root_name, "doc", try fileDoc(&w, ast));
    const root_abs = std.fs.path.resolve(arena, &.{root}) catch root;
    try w.visited.put(root_abs, {});

    // walk the whole organism: follow every @import, building the complete node set.
    const root_dir = std.fs.path.dirname(root) orelse ".";
    try walk(&w, ast, ast.rootDecls(), root_name, "root", root_dir, 0, std.fs.path.basename(root));
    try w.file_home.put(try std.fs.path.resolve(arena, &.{root}), root_name);
    try scopeFiles(&w);
    try sweepImports(&w);
    try linkNsrefs(&w);
    try w.nodes.flush();
    try w.attrs.flush();
    w.nodes = &failing_writer;
    w.attrs = &failing_writer;
    return w;
}

/// Where a retired W's writers point: the files are closed, a write is a bug.
var failing_writer: std.Io.Writer = .failing;

fn resolveEdges(w: *W, root: []const u8, edges_out: []const u8, report: bool) !Stats {
    const io = w.io;
    const ef = try std.Io.Dir.cwd().createFile(io, edges_out, .{});
    defer ef.close(io);
    var ebuf: [1 << 16]u8 = undefined;
    var efw = ef.writer(io, &ebuf);
    const ew = &efw.interface;
    try ew.print("src\ttype\ttarget\tscope\n", .{});
    var counts: std.EnumArray(Scope, usize) = .initFill(0); // by Scope
    for (w.edges.items) |e| {
        // an `imports` edge always reaches out of the tree (a file/module we didn't walk) — its
        // target is a path, not a name to look up, so it never goes through scope resolution.
        const r = if (std.mem.eql(u8, e.etype, "imports"))
            Res{ .scope = Scope.module, .target = e.target }
        else
            resolve(w, e.src, e.target, resolve_fuel);
        counts.getPtr(r.scope).* += 1;
        try ew.print("{s}\t{s}\t{s}\t{s}\n", .{ e.src, e.etype, r.target, @tagName(r.scope) });
    }
    try ew.flush();

    if (!report) return .{ .nodes = w.node_set.count(), .edges = w.edges.items.len, .scope = counts };
    var sbuf: [512]u8 = undefined;
    var sfw = std.Io.File.stderr().writerStreaming(io, &sbuf);
    const s = &sfw.interface;
    try s.print("[parse] {s}\n  nodes: {d}   edges: {d}\n  scope: local {d} · cross {d} · primitive {d} · module {d} · generic {d} · inline {d} · unresolved {d}\n", .{
        root,                         w.node_set.count(),        w.edges.items.len,
        counts.get(Scope.local),      counts.get(Scope.cross),   counts.get(Scope.primitive),
        counts.get(Scope.module),     counts.get(Scope.generic), counts.get(Scope.@"inline"),
        counts.get(Scope.unresolved),
    });
    try s.flush();

    return Stats{ .nodes = w.node_set.count(), .edges = w.edges.items.len, .scope = counts };
}
