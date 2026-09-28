// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! langref.zig — the builtins (`@intCast`, `@memcpy`, …). They are not std declarations, so the
//! walk never sees them, yet they change between Zig releases as much as std does.
//!
//! Two witnesses, both shipped with the active toolchain:
//!   - `std/zig/BuiltinFn.zig` — the compiler's own table: every builtin name and its
//!     `param_count` (null = variadic). This decides what EXISTS.
//!   - `doc/langref.html` — the language reference: each builtin's signature, prose, and first
//!     example. This decides what it SAYS.
//!
//! Output `builtins.tsv`: `name · params · sig · doc · example`, one row per table entry, in the
//! table's source order. A builtin the table has but langref doesn't document keeps empty
//! sig/doc/example — that absence is a fact, not a gap to fill. The run FAILS if langref
//! documents a builtin the compiler doesn't know, or if a documented signature's parameter
//! count disagrees with the table's.
const std = @import("std");

pub const Entry = struct { name: []const u8, params: ?u8 };
pub const Doc = struct { sig: []const u8, doc: []const u8, example: []const u8, arity: ?usize = null };

pub const Stats = struct { builtins: usize, documented: usize, examples: usize };

pub const Error = error{ TableUnreadable, UnknownBuiltinDocumented, ParamCountMismatch };

/// The compiler's builtin table, read from BuiltinFn.zig's `list` initializer: each
/// `"@name",` string is followed (in its own `.{ … }`) by `.param_count = N` or `= null`.
pub fn table(a: std.mem.Allocator, src: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var pending: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "\"@") and std.mem.endsWith(u8, line, "\",")) {
            pending = line[1 .. line.len - 2];
        } else if (std.mem.startsWith(u8, line, ".param_count = ")) {
            const name = pending orelse continue;
            const v = std.mem.trimEnd(u8, line[".param_count = ".len..], ",");
            const params: ?u8 = if (std.mem.eql(u8, v, "null")) null else try std.fmt.parseInt(u8, v, 10);
            try out.append(a, .{ .name = name, .params = params });
            pending = null;
        }
    }
    if (out.items.len == 0) return Error.TableUnreadable;
    return out.items;
}

/// Every builtin section of langref: `<h3 id="…"><a href="#toc-…">@name</a>` up to the next
/// `<h2`/`<h3`. The first `<pre>` is the signature; the first Zig `<figure>` is the example;
/// everything else, figures and shell output removed, is the prose.
pub fn sections(a: std.mem.Allocator, html: []const u8) !std.array_hash_map.String(Doc) {
    var out: std.array_hash_map.String(Doc) = .empty;
    var pos: usize = 0;
    while (std.mem.findPos(u8, html, pos, "<h3 id=\"")) |h| {
        pos = h + 1;
        const head_end = std.mem.findPos(u8, html, h, "</h3>") orelse break;
        const head = html[h..head_end];
        const at = std.mem.find(u8, head, "\">@") orelse continue;
        const name_start = at + 2;
        const name_end = std.mem.findScalarPos(u8, head, name_start, '<') orelse continue;
        const name = head[name_start..name_end];

        const body_start = head_end + "</h3>".len;
        const next_h3 = std.mem.findPos(u8, html, body_start, "<h3") orelse html.len;
        const next_h2 = std.mem.findPos(u8, html, body_start, "<h2") orelse html.len;
        const body = html[body_start..@min(next_h3, next_h2)];

        const sig_html = between(body, "<pre><code>", "</code></pre>");
        const sig = if (sig_html) |s| try text(a, s, .collapse) else "";
        // Arity is counted on the raw lines with `//` comments removed: a `///` doc comment
        // inside the parameter list (`@Union`) can itself contain commas.
        const arity = if (sig_html) |s| sigParams(try stripLineComments(a, try text(a, s, .keep_lines))) else null;
        const example = blk: {
            const fig = std.mem.find(u8, body, "<figcaption class=\"zig-cap\">") orelse break :blk "";
            const code = between(body[fig..], "<pre><code>", "</code></pre>") orelse break :blk "";
            break :blk try escapeTsv(a, try text(a, code, .keep_lines));
        };
        // prose: drop the signature block and every figure, then flatten what remains
        var prose = body;
        if (std.mem.find(u8, prose, "</pre>")) |e| {
            if (std.mem.find(u8, prose, "<pre>")) |s| {
                if (s < e) prose = try std.fmt.allocPrint(a, "{s}{s}", .{ prose[0..s], prose[e + "</pre>".len ..] });
            }
        }
        prose = try dropBlocks(a, prose, "<figure>", "</figure>");
        try out.put(a, name, .{ .sig = sig, .doc = try text(a, prose, .collapse), .example = example, .arity = arity });
    }
    return out;
}

/// Parameter count of a documented signature `@name(a: T, b: U) R`: top-level commas inside the
/// first parenthesis group. Null when variadic (`...`) or unparsable.
pub fn sigParams(sig: []const u8) ?usize {
    const open = std.mem.findScalar(u8, sig, '(') orelse return null;
    if (std.mem.find(u8, sig, "...") != null) return null;
    // Count non-empty top-level segments, so a multi-line signature's trailing comma
    // (`@Pointer(\n a: A,\n …,\n)`) is not a parameter.
    var depth: usize = 0;
    var n: usize = 0;
    var seg = false;
    for (sig[open..]) |ch| {
        switch (ch) {
            '(', '[', '{' => {
                depth += 1;
                if (depth > 1) seg = true;
            },
            ')', ']', '}' => {
                depth -= 1;
                if (depth == 0) return n + @intFromBool(seg);
            },
            ',' => if (depth == 1) {
                if (seg) n += 1;
                seg = false;
            },
            ' ', '\t', '\n', '\r' => {},
            else => if (depth == 1) {
                seg = true;
            },
        }
    }
    return null;
}

/// Regenerate `builtins.tsv`. `langref_path` may be null (a toolchain packaged without docs):
/// the table alone is still written, every row undocumented.
pub fn run(a: std.mem.Allocator, io: std.Io, builtin_fn_path: []const u8, langref_path: ?[]const u8, out_path: []const u8) !Stats {
    const src = try std.Io.Dir.cwd().readFileAlloc(io, builtin_fn_path, a, .unlimited);
    const entries = try table(a, src);
    var docs: std.array_hash_map.String(Doc) = .empty;
    if (langref_path) |p| docs = try sections(a, try std.Io.Dir.cwd().readFileAlloc(io, p, a, .unlimited));

    // langref must not document a builtin the compiler lacks
    var known = std.StringHashMap(?u8).init(a);
    for (entries) |e| try known.put(e.name, e.params);
    for (docs.keys()) |name| {
        if (!known.contains(name)) {
            std.log.err("langref documents {s}, which the compiler's builtin table does not have", .{name});
            return Error.UnknownBuiltinDocumented;
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "name\tparams\tsig\tdoc\texample\n");
    var stats: Stats = .{ .builtins = entries.len, .documented = 0, .examples = 0 };
    for (entries) |e| {
        const d = docs.get(e.name) orelse Doc{ .sig = "", .doc = "", .example = "" };
        if (d.sig.len > 0) {
            stats.documented += 1;
            if (e.params) |want| {
                if (d.arity) |got| if (got != want) {
                    std.log.err("{s}: langref signature has {d} parameter(s), the compiler table says {d}", .{ e.name, got, want });
                    return Error.ParamCountMismatch;
                };
            }
        }
        if (d.example.len > 0) stats.examples += 1;
        const params = if (e.params) |p| try std.fmt.allocPrint(a, "{d}", .{p}) else "var";
        try buf.print(a, "{s}\t{s}\t{s}\t{s}\t{s}\n", .{ e.name, params, d.sig, d.doc, d.example });
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = buf.items });
    return stats;
}

// ── html → text ─────────────────────────────────────────────────────────────

fn between(s: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const i = std.mem.find(u8, s, open) orelse return null;
    const j = std.mem.findPos(u8, s, i + open.len, close) orelse return null;
    return s[i + open.len .. j];
}

fn dropBlocks(a: std.mem.Allocator, s: []const u8, open: []const u8, close: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.findPos(u8, s, pos, open)) |i| {
        try out.appendSlice(a, s[pos..i]);
        const j = std.mem.findPos(u8, s, i, close) orelse {
            pos = s.len;
            break;
        };
        pos = j + close.len;
    }
    try out.appendSlice(a, s[pos..]);
    return out.items;
}

const Mode = enum { collapse, keep_lines };

/// Strip tags, decode the entities langref uses, and either collapse all whitespace to single
/// spaces (prose, signatures) or keep line structure (code). Tabs/newlines never survive
/// `.collapse`, so the result is always safe as one TSV cell.
fn text(a: std.mem.Allocator, html: []const u8, mode: Mode) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var space = false;
    while (i < html.len) {
        const ch = html[i];
        if (ch == '<') {
            i = (std.mem.findScalarPos(u8, html, i, '>') orelse html.len) + 1;
            continue;
        }
        if (ch == '&') {
            const ents = [_]struct { []const u8, []const u8 }{
                .{ "&quot;", "\"" }, .{ "&amp;", "&" },  .{ "&lt;", "<" },   .{ "&gt;", ">" },
                .{ "&#39;", "'" },   .{ "&apos;", "'" }, .{ "&nbsp;", " " },
            };
            const hit = for (ents) |e| {
                if (std.mem.startsWith(u8, html[i..], e[0])) break e;
            } else null;
            if (hit) |e| {
                if (mode == .collapse and space and out.items.len > 0) try out.append(a, ' ');
                space = false;
                try out.appendSlice(a, e[1]);
                i += e[0].len;
                continue;
            }
        }
        if (mode == .collapse and std.ascii.isWhitespace(ch)) {
            space = true;
        } else {
            if (mode == .collapse and space and out.items.len > 0) try out.append(a, ' ');
            space = false;
            try out.append(a, ch);
        }
        i += 1;
    }
    return std.mem.trim(u8, out.items, " \n");
}

fn stripLineComments(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |line| {
        const cut = std.mem.find(u8, line, "//") orelse line.len;
        try out.appendSlice(a, line[0..cut]);
        try out.append(a, '\n');
    }
    return out.items;
}

/// Same escaping as the walk's `example` attr: `\` `\t` `\r` `\n` → two characters.
fn escapeTsv(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| switch (ch) {
        '\\' => try out.appendSlice(a, "\\\\"),
        '\t' => try out.appendSlice(a, "\\t"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\n' => try out.appendSlice(a, "\\n"),
        else => try out.append(a, ch),
    };
    return out.items;
}
