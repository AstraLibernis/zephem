//! ast.zig — the parser's low-level reading primitives.
//!
//! Two groups, both pure (no comptime evaluation, so platform-gated / "poison" decls are
//! harmless text — which is what lets the walk read ALL of std without dying):
//!
//!   files & paths — dirname, relPath (machine-independent), parseFile (source → Ast)
//!   AST syntax    — parseImport, isAliasChain, findDecl, countPub, containerKindOf
//!
//! `relPath` renders absolute paths relative to the module root so the dataset is identical
//! regardless of where the toolchain lives on disk; `parseFile` is silent on read failure so
//! a missing file never injects an off-schema row (the caller emits the right leaf).

const std = @import("std");
const Ast = std.zig.Ast;

// ── files & paths ────────────────────────────────────────────────────────────

/// The directory part of `path` (everything before the last '/'), or "." if none.
pub fn dirname(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[0..i];
    return ".";
}

/// `abs` rendered relative to `root_dir` (machine-independent dataset paths).
pub fn relPath(root_dir: []const u8, abs: []const u8) []const u8 {
    if (abs.len > root_dir.len and std.mem.startsWith(u8, abs, root_dir) and abs[root_dir.len] == '/')
        return abs[root_dir.len + 1 ..];
    return abs;
}

/// Parse a file's source into an Ast (caller keeps `arena` alive for the walk).
/// Returns null on read failure so the caller can emit the right leaf row.
pub fn parseFile(io: std.Io, arena: std.mem.Allocator, path: []const u8) !?Ast {
    const src = std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .unlimited, .of(u8), 0) catch {
        return null;
    };
    return try Ast.parse(arena, src, .zig);
}

// ── AST syntax predicates ────────────────────────────────────────────────────

/// An `@import` init split into the imported file and any selector that follows.
///   `@import("f.zig")`     → { file: "f.zig", selector: "" }   (whole-file namespace)
///   `@import("f.zig").Foo` → { file: "f.zig", selector: "Foo" } (re-export of one decl)
pub const ImportRef = struct { file: []const u8, selector: []const u8 };

/// Parse a clean `@import`-or-`@import`-selection init. Returns null when the init is not
/// one (a generic call `@import("f").Foo(args)`, an operator, etc. — those are values).
/// A present selector is always a pure dotted identifier chain (see `isAliasChain`); a
/// selector that isn't is treated as "not a clean re-export" → null, so the caller falls
/// through to its value/alias-leaf path.
pub fn parseImport(src: []const u8) ?ImportRef {
    const t = std.mem.trim(u8, src, " \t\r\n");
    const prefix = "@import(\"";
    if (!std.mem.startsWith(u8, t, prefix)) return null;
    const after_q = t[prefix.len..];
    const qend = std.mem.indexOfScalar(u8, after_q, '"') orelse return null;
    const file = after_q[0..qend];
    var rest = std.mem.trim(u8, after_q[qend + 1 ..], " \t\r\n");
    if (!std.mem.startsWith(u8, rest, ")")) return null; // malformed / not a plain @import
    rest = std.mem.trim(u8, rest[1..], " \t\r\n");
    if (rest.len == 0) return .{ .file = file, .selector = "" }; // whole-file import
    if (rest[0] != '.') return null; // a call or operator on the import → a value
    const sel = std.mem.trim(u8, rest[1..], " \t\r\n");
    if (sel.len == 0 or !isAliasChain(sel)) return null;
    return .{ .file = file, .selector = sel };
}

/// True iff `s` is a pure dotted identifier chain — `Foo`, `mem.Allocator`,
/// `crypto.hash.sha2.Sha256` — and nothing else (a re-export alias). Anything with an
/// operator, call, `@builtin`, or whitespace is a computed value, not an alias.
pub fn isAliasChain(s: []const u8) bool {
    if (s.len == 0) return false;
    var expect_start = true; // at the first char of an identifier segment
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
    return !expect_start; // must not end on a trailing '.'
}

/// The public decl named `name` among `members`, or null.
pub fn findDecl(ast: *const Ast, members: []const Ast.Node.Index, name: []const u8) ?Ast.Node.Index {
    for (members) |m| {
        if (ast.nodeTag(m) == .fn_decl) {
            var b: [1]Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&b, m) orelse continue;
            if (proto.visib_token == null) continue;
            const nt = proto.name_token orelse continue;
            if (std.mem.eql(u8, ast.tokenSlice(nt), name)) return m;
            continue;
        }
        const vd = ast.fullVarDecl(m) orelse continue;
        if (vd.visib_token == null) continue;
        if (std.mem.eql(u8, ast.tokenSlice(vd.ast.mut_token + 1), name)) return m;
    }
    return null;
}

/// Count the public decls a container emits as direct children — the SAME predicate the
/// walker uses to emit, so recorded count == emitted rows (the conservation law).
pub fn countPub(ast: *const Ast, members: []const Ast.Node.Index) usize {
    var n: usize = 0;
    for (members) |m| {
        if (ast.nodeTag(m) == .fn_decl) {
            var b: [1]Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&b, m) orelse continue;
            if (proto.visib_token != null and proto.name_token != null) n += 1;
            continue;
        }
        const vd = ast.fullVarDecl(m) orelse continue;
        if (vd.visib_token != null) n += 1;
    }
    return n;
}

pub const ContainerKind = enum { @"struct", @"enum", @"union", @"opaque", none };

pub fn containerKindOf(ast: *const Ast, node: Ast.Node.Index) ContainerKind {
    var buf: [2]Ast.Node.Index = undefined;
    const cd = ast.fullContainerDecl(&buf, node) orelse return .none;
    return switch (ast.tokenTag(cd.ast.main_token)) {
        .keyword_struct => .@"struct",
        .keyword_enum => .@"enum",
        .keyword_union => .@"union",
        .keyword_opaque => .@"opaque",
        else => .@"struct",
    };
}
