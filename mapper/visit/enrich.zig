//! visit/enrich.zig — the L1 (signatures) + L2 (doc-comments) overlay → decls.tsv.
//!
//!   path · doc · sig
//!
//!   doc = the decl's `///` lines joined with a literal `\n`, backslash/tab escaped (L2).
//!   sig = a `fn`'s as-written signature `fn name(params) ret`, whitespace-collapsed (L1).
//!
//! SPARSE: a row exists only where there's something to say — every `fn` (it has a sig),
//! plus any decl carrying a doc-comment. Non-fn undocumented decls produce no row (already
//! covered by nodes.tsv). Because it rides the same walk as the map, every `path` it emits
//! lines up exactly with a map row — no hand-kept mirror.

const std = @import("std");
const Ast = std.zig.Ast;
const walk = @import("../walk.zig");

pub const Visitor = struct {
    w: *std.Io.Writer,

    pub fn emit(self: Visitor, n: walk.Node) !void {
        // functions — always a row (signature), doc optional.
        if (n.kind == .fn_decl) {
            const proto = n.proto.?;
            try self.w.print("{s}\t", .{n.path});
            if (docFirst(n.ds_ast, proto.visib_token.?)) |df| try writeDoc(self.w, n.ds_ast, df, proto.visib_token.?);
            try self.w.writeAll("\t");
            try writeSig(self.w, fnSigSource(n.ds_ast, proto));
            try self.w.writeAll("\n");
            return;
        }
        // everything else — a doc-only row, iff it carries a doc-comment.
        const tok = n.ds_tok orelse return;
        const df = docFirst(n.ds_ast, tok) orelse return;
        try self.w.print("{s}\t", .{n.path});
        try writeDoc(self.w, n.ds_ast, df, tok);
        try self.w.writeAll("\t\n");
    }
};

/// First doc-comment token preceding `start_tok` (the decl's visibility token), or null.
fn docFirst(ast: *const Ast, start_tok: Ast.TokenIndex) ?Ast.TokenIndex {
    if (start_tok == 0) return null;
    var first = start_tok;
    while (first > 0 and ast.tokenTag(first - 1) == .doc_comment) first -= 1;
    if (first == start_tok) return null;
    return first;
}

/// Stream doc-comment lines [first, end) as one escaped field (lines joined with `\n`).
fn writeDoc(w: *std.Io.Writer, ast: *const Ast, first: Ast.TokenIndex, end: Ast.TokenIndex) !void {
    var t = first;
    var line_started = false;
    while (t < end) : (t += 1) {
        if (ast.tokenTag(t) != .doc_comment) continue;
        const slice = ast.tokenSlice(t);
        var i: usize = 0;
        while (i < slice.len and slice[i] == '/') i += 1; // strip leading '///'
        if (i < slice.len and slice[i] == ' ') i += 1; // and one space
        if (line_started) try w.writeAll("\\n");
        line_started = true;
        for (slice[i..]) |c| switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '\t' => try w.writeAll("\\t"),
            '\r' => {},
            else => try w.writeByte(c),
        };
    }
}

/// The as-written signature `fn name(params) ret`, whitespace collapsed to single spaces.
fn fnSigSource(ast: *const Ast, proto: *const Ast.full.FnProto) []const u8 {
    const start = ast.tokenStart(proto.ast.fn_token);
    const end_tok = if (proto.ast.return_type.unwrap()) |rt|
        ast.lastToken(rt)
    else
        ast.lastToken(proto.ast.proto_node);
    const end = ast.tokenStart(end_tok) + ast.tokenSlice(end_tok).len;
    return ast.source[start..end];
}

fn writeSig(w: *std.Io.Writer, src: []const u8) !void {
    var pending_space = false;
    var started = false;
    for (src) |c| {
        const ws = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (ws) {
            if (started) pending_space = true;
            continue;
        }
        if (pending_space) {
            try w.writeByte(' ');
            pending_space = false;
        }
        if (c == '\\') try w.writeAll("\\\\") else try w.writeByte(c);
        started = true;
    }
}
