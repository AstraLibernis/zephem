// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const man = @import("zephem").manifest;

test "sha256Hex is the known empty-input digest" {
    const hex = man.sha256Hex("");
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &hex,
    );
}

test "parse manifest lines (two-space separator) and hexFor lookup" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text =
        "aaaa  data/std/extracted/nodes.tsv\n" ++
        "bbbb  data/std/derived/index.tsv\n";
    const recs = try man.parse(a, text);
    try std.testing.expectEqual(@as(usize, 2), recs.len);
    try std.testing.expectEqualStrings("aaaa", man.hexFor(recs, "data/std/extracted/nodes.tsv").?);
    try std.testing.expectEqualStrings("bbbb", man.hexFor(recs, "data/std/derived/index.tsv").?);
    try std.testing.expectEqual(@as(?[]const u8, null), man.hexFor(recs, "nope"));
}
