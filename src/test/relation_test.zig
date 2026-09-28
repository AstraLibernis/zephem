// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const rel = @import("zephem").relation;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "loadBytes: header + rows, short-row padding, trailing newline" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try rel.loadBytes(a, "path\tkind\tvis\na\tns\tpub\nb\tconst\n");
    try std.testing.expectEqual(@as(usize, 3), t.columns.len);
    try std.testing.expectEqual(@as(usize, 2), t.rows.len);
    try std.testing.expectEqualStrings("pub", t.cell(t.rows[0], "vis"));
    try std.testing.expectEqualStrings("", t.cell(t.rows[1], "vis")); // padded
}

test "round-trip: loadBytes -> writeTsv reproduces content" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src = "path\tkind\na\tns\nb\tconst\n";
    const t = try rel.loadBytes(a, src);
    var w = std.Io.Writer.Allocating.init(a);
    try rel.writeTsv(t, &w.writer);
    try std.testing.expectEqualStrings(src, w.writer.buffered());
}

test "select / rename / filter" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try rel.loadBytes(a, "path\tkind\tvis\na\tns\tpub\nb\tconst\tpriv\nc\tfn\tpub\n");
    const s = try rel.select(a, t, &.{ "path", "vis" });
    try std.testing.expectEqual(@as(usize, 2), s.columns.len);
    const r = try rel.rename(a, s, "vis", "v");
    try std.testing.expectEqualStrings("v", r.columns[1]);
    const Ctx = struct { vi: usize };
    const pub_only = try rel.filter(a, t, Ctx{ .vi = t.col("vis") }, struct {
        fn p(c: Ctx, row: rel.Row) bool {
            return std.mem.eql(u8, row[c.vi], "pub");
        }
    }.p);
    try std.testing.expectEqual(@as(usize, 2), pub_only.rows.len);
}

test "uniqBy keeps first occurrence" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try rel.loadBytes(a, "k\tv\nx\t1\nx\t2\ny\t3\n");
    const u = try rel.uniqBy(a, t, "k");
    try std.testing.expectEqual(@as(usize, 2), u.rows.len);
    try std.testing.expectEqualStrings("1", u.cell(u.rows[0], "v"));
}

test "sortBy ascending, stable via original position" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try rel.loadBytes(a, "k\tt\nb\t1\na\t2\nb\t3\na\t4\n");
    const s = try rel.sortBy(a, t, &.{"k"});
    try std.testing.expectEqualStrings("a", s.cell(s.rows[0], "k"));
    try std.testing.expectEqualStrings("2", s.cell(s.rows[0], "t")); // first 'a' kept ahead of second
    try std.testing.expectEqualStrings("4", s.cell(s.rows[1], "t"));
}

test "joinLeft preserves left count, fills unmatched with empty" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const left = try rel.loadBytes(a, "path\tkind\na\tns\nb\tfn\nc\tconst\n");
    const right = try rel.loadBytes(a, "path\tsig\nb\tfn b() void\n");
    const j = try rel.joinLeft(a, left, right, "path");
    try std.testing.expectEqual(left.rows.len, j.rows.len);
    try std.testing.expectEqualStrings("fn b() void", j.cell(j.rows[1], "sig"));
    try std.testing.expectEqualStrings("", j.cell(j.rows[0], "sig"));
}

test "joinOuter: matched, left-only, right-only" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const left = try rel.loadBytes(a, "ppath\tk\nP.a\ta\nP.b\tb\n");
    const right = try rel.loadBytes(a, "cpath\tk\nC.b\tb\nC.z\tz\n");
    const j = try rel.joinOuter(a, left, right, "k");
    // a (left-only), b (matched), z (right-only)
    try std.testing.expectEqual(@as(usize, 3), j.rows.len);
    // right-only row: ppath empty, cpath present, key carried
    const last = j.rows[2];
    try std.testing.expectEqualStrings("", j.cell(last, "ppath"));
    try std.testing.expectEqualStrings("C.z", j.cell(last, "cpath"));
    try std.testing.expectEqualStrings("z", j.cell(last, "k"));
}

test "groupBy preserves first-seen key order" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try rel.loadBytes(a, "g\tv\nx\t1\ny\t2\nx\t3\n");
    const groups = try rel.groupBy(a, t, "g");
    try std.testing.expectEqual(@as(usize, 2), groups.len);
    try std.testing.expectEqualStrings("x", groups[0].key);
    try std.testing.expectEqual(@as(usize, 2), groups[0].rows.len);
    try std.testing.expectEqualStrings("y", groups[1].key);
}
