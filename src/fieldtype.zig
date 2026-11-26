// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! fieldtype.zig — the self-check on field types: does the type the map PRINTS for a field
//! agree with the type the compiler resolves for it?
//!
//! The map prints a field's type as written in source (`argv: []const []const u8`); reflection
//! records the compiler's `@typeName` of the same field. The two are not the same text (the
//! compiler qualifies names, `Allocator` → `mem.Allocator`, and expands aliases), so they are
//! compared by SHAPE: the chain of type constructors in front of the base name —
//! `?` optional · `*` pointer · `[*]` many-pointer · `[]` slice · `[N]` array. Qualifiers
//! (`const`, `align(…)`, …) are not shape.
//!
//!   agrees      the shapes are equal
//!   hidden      the written type stops at a NAME that stands for the rest (`items: Slice`,
//!               `Slice = []T`): the printed text is still true, only shorter
//!   wrong       anything else — a constructor the compiler does not have, or a primitive base
//!               (`u8`) printed for a `[]u8`: the answer would mislead a reader
const std = @import("std");

/// One type constructor in front of a base name.
pub const Ctor = enum(u8) { optional = '?', pointer = '*', many = 'M', slice = 'S', array = 'A' };

/// At most this many constructors are tracked; deeper chains compare on their first 16.
pub const max_depth = 16;

pub const Shape = struct {
    ctors: [max_depth]Ctor = undefined,
    len: usize = 0,
    /// the text after the constructors and qualifiers: `u8`, `mem.Allocator`, `fn (…) void`
    base: []const u8 = "",

    pub fn slice(s: *const Shape) []const Ctor {
        return s.ctors[0..s.len];
    }
};

/// The constructor chain and base of a type expression, as written or as `@typeName` prints it.
pub fn shapeOf(text: []const u8) Shape {
    var s: Shape = .{};
    var i: usize = 0;
    while (true) {
        i = skipQualifiers(text, i);
        if (i >= text.len) break;
        const ctor: Ctor = switch (text[i]) {
            '?' => blk: {
                i += 1;
                break :blk .optional;
            },
            '*' => blk: {
                i += 1;
                break :blk .pointer;
            },
            '[' => blk: {
                const close = matching(text, i) orelse break;
                const inner = std.mem.trim(u8, text[i + 1 .. close], " ");
                i = close + 1;
                break :blk if (inner.len == 0 or inner[0] == ':')
                    .slice
                else if (inner[0] == '*')
                    .many
                else
                    .array;
            },
            else => break,
        };
        if (s.len < max_depth) {
            s.ctors[s.len] = ctor;
            s.len += 1;
        }
    }
    s.base = std.mem.trim(u8, text[@min(i, text.len)..], " ");
    return s;
}

/// Index of the `]` that closes the `[` at `open`, counting nested brackets and parens.
fn matching(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '[', '(' => depth += 1,
            ']', ')' => {
                if (depth == 0) return null; // unbalanced: not a constructor
                depth -= 1;
                if (depth == 0) return if (text[i] == ']') i else null;
            },
            else => {},
        }
    }
    return null;
}

const qualifiers = [_][]const u8{ "const", "volatile", "allowzero" };
const call_qualifiers = [_][]const u8{ "align", "addrspace" };

/// Skip spaces and pointer qualifiers starting at `i`.
fn skipQualifiers(text: []const u8, start: usize) usize {
    var i = start;
    outer: while (true) {
        while (i < text.len and text[i] == ' ') i += 1;
        for (qualifiers) |q| if (keywordAt(text, i, q)) {
            i += q.len;
            continue :outer;
        };
        for (call_qualifiers) |q| if (keywordAt(text, i, q)) {
            var j = i + q.len;
            while (j < text.len and text[j] == ' ') j += 1;
            if (j >= text.len or text[j] != '(') return i;
            var depth: usize = 0;
            while (j < text.len) : (j += 1) {
                if (text[j] == '(') depth += 1;
                if (text[j] == ')') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            i = @min(j + 1, text.len);
            continue :outer;
        };
        return i;
    }
}

/// `word` at `i`, as a whole word (not the start of `constant`).
fn keywordAt(text: []const u8, i: usize, word: []const u8) bool {
    if (!std.mem.startsWith(u8, text[i..], word)) return false;
    const end = i + word.len;
    if (end == text.len) return true;
    const c = text[end];
    return !(std.ascii.isAlphanumeric(c) or c == '_');
}

pub const Verdict = enum { agrees, hidden, wrong };

/// Does the `printed` field type tell the truth about the compiler's `resolved` one?
pub fn judge(printed: []const u8, resolved: []const u8) Verdict {
    const p = shapeOf(printed);
    const r = shapeOf(resolved);
    if (std.mem.eql(Ctor, p.slice(), r.slice())) return .agrees;
    // A written name may stand for more constructors (`Slice` = `[]T`). A primitive cannot, and
    // neither can the resolved base itself (`Map` printed for `?*const Environ.Map`).
    if (p.len < r.len and std.mem.eql(Ctor, p.slice(), r.slice()[0..p.len]) and
        !std.zig.primitives.isPrimitive(p.base) and
        !std.mem.eql(u8, baseName(p.base), baseName(r.base))) return .hidden;
    return .wrong;
}

/// The last name of a base, without generic arguments: `process.Environ.Map` → `Map`,
/// `array_list.Aligned(u8,null)` → `Aligned`.
fn baseName(base: []const u8) []const u8 {
    const head = base[0 .. std.mem.findScalar(u8, base, '(') orelse base.len];
    const dot = std.mem.findScalarLast(u8, head, '.') orelse return head;
    return head[dot + 1 ..];
}
