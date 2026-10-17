// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const diff = @import("zephem").diff;
const snapshot = @import("zephem").snapshot;

// A small std: a module `mem`, an enum `Mode` whose tags are renamed, a namespace `builtin`
// whose `Type` moves to `lang`, a deprecated fn that is then removed, a fn that becomes
// deprecated, a constant whose resolved value changes.
const old_nodes =
    "path\tkind\tname\tvis\n" ++
    "std\tns\tstd\tpub\n" ++
    "std.mem\tns\tmem\tpub\n" ++
    "std.mem.eql\tfn\teql\tpub\n" ++
    "std.mem.gone\tfn\tgone\tpub\n" ++
    "std.mem.resized\tfn\tresized\tpub\n" ++
    "std.mem.hidden\tfn\thidden\tpriv\n" ++
    "std.mem.Kind\tconst\tKind\tpub\n" ++
    "std.mem.indexOf\tfn\tindexOf\tpub\n" ++
    "std.mem.max\tconst\tmax\tpub\n" ++
    "std.builtin\tns\tbuiltin\tpub\n" ++
    "std.builtin.Type\tstruct\tType\tpub\n" ++
    "std.builtin.Type.name\tfield\tname\tpub\n" ++
    "std.builtin.Mode\tenum\tMode\tpub\n" ++
    "std.builtin.Mode.Debug\ttag\tDebug\tpub\n" ++
    "std.builtin.Mode.ReleaseSafe\ttag\tReleaseSafe\tpub\n" ++
    "std.builtin.Options\tstruct\tOptions\tpub\n" ++
    "std.io.Options\tstruct\tOptions\tpub\n";
const old_attrs =
    "path\tattr\tvalue\n" ++
    "std.mem.eql\tsig\tfn eql(comptime T: type, a: []const T, b: []const T) bool\n" ++
    "std.mem.gone\tsig\tfn gone() void\n" ++
    "std.mem.gone\tdoc\tDeprecated; use nothing.\n" ++
    "std.mem.resized\tsig\tfn resized(a: u32) void\n" ++
    "std.mem.indexOf\tsig\tfn indexOf(comptime T: type, h: []const T, n: []const T) ?usize\n" ++
    "std.mem.eql\tdoc\tCompares two slices\n";
const new_nodes =
    "path\tkind\tname\tvis\n" ++
    "std\tns\tstd\tpub\n" ++
    "std.mem\tns\tmem\tpub\n" ++
    "std.mem.eql\tfn\teql\tpub\n" ++
    "std.mem.resized\tfn\tresized\tpub\n" ++
    "std.mem.hidden\tfn\thidden\tpriv\n" ++
    "std.mem.Kind\tenum\tKind\tpub\n" ++
    "std.mem.fresh\tfn\tfresh\tpub\n" ++
    "std.mem.secret\tfn\tsecret\tpriv\n" ++
    "std.mem.indexOf\tfn\tindexOf\tpub\n" ++
    "std.mem.max\tconst\tmax\tpub\n" ++
    "std.lang\tns\tlang\tpub\n" ++
    "std.lang.Type\tstruct\tType\tpub\n" ++
    "std.lang.Type.name\tfield\tname\tpub\n" ++
    "std.builtin\tns\tbuiltin\tpub\n" ++
    "std.builtin.Mode\tenum\tMode\tpub\n" ++
    "std.builtin.Mode.debug\ttag\tdebug\tpub\n" ++
    "std.builtin.Mode.safe\ttag\tsafe\tpub\n" ++
    "std.fs.Options\tstruct\tOptions\tpub\n" ++
    "std.net.Options\tstruct\tOptions\tpub\n";
const new_attrs =
    "path\tattr\tvalue\n" ++
    "std.mem.eql\tsig\tfn eql(comptime T: type, a: []const T, b: []const T) bool\n" ++
    "std.mem.resized\tsig\tfn resized(a: u64) void\n" ++
    "std.mem.fresh\tsig\tfn fresh() void\n" ++
    "std.mem.indexOf\tsig\tfn indexOf(comptime T: type, h: []const T, n: []const T) ?usize\n" ++
    "std.mem.indexOf\tdoc\tDeprecated: use `find`.\n";

const old_builtins =
    "name\tparams\tsig\tdoc\texample\n" ++
    "@splat\t1\t@splat(scalar: anytype) anytype\tvector only\t\n" ++
    "@setCold\t1\t@setCold(is_cold: bool) void\tgone\t\n";
const new_builtins =
    "name\tparams\tsig\tdoc\texample\n" ++
    "@splat\t1\t@splat(element: anytype) anytype\tarray or vector\t\n" ++
    "@branchHint\t1\t@branchHint(hint: BranchHint) void\tnew\t\n";
const old_resolved =
    "path\tkind\tdetail\n" ++
    "std.mem.max\tconst_int\t4096\n" ++
    "std.mem.eql\tfn\tfn (...) bool\n";
const new_resolved =
    "path\tkind\tdetail\n" ++
    "std.mem.max\tconst_int\t8192\n" ++
    "std.mem.eql\tfn\tfn (...) bool\n";

fn sides(a: std.mem.Allocator) !struct { diff.Side, diff.Side } {
    var old = try diff.loadSideBytes(a, old_nodes, old_attrs);
    var new = try diff.loadSideBytes(a, new_nodes, new_attrs);
    try diff.loadExtrasBytes(a, &old, old_builtins, old_resolved);
    try diff.loadExtrasBytes(a, &new, new_builtins, new_resolved);
    return .{ old, new };
}

fn findChange(changes: []const diff.Change, path: []const u8) ?diff.Change {
    for (changes) |ch| if (std.mem.eql(u8, ch.path, path)) return ch;
    return null;
}

test "compute: added, removed, kind and signature changes; private declarations skipped by default" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sides(a);
    const changes = try diff.compute(a, s[0], s[1], false);

    const kind = findChange(changes, "std.mem.Kind").?;
    try std.testing.expectEqual(diff.What.changed, kind.what);
    try std.testing.expectEqualStrings("const", kind.old.?.kind);
    try std.testing.expectEqualStrings("enum", kind.new.?.kind);

    const fresh = findChange(changes, "std.mem.fresh").?;
    try std.testing.expectEqual(diff.What.added, fresh.what);
    try std.testing.expectEqualStrings("fn fresh() void", fresh.new.?.sig.?);

    try std.testing.expectEqual(diff.What.removed, findChange(changes, "std.mem.gone").?.what);

    const resized = findChange(changes, "std.mem.resized").?;
    try std.testing.expectEqual(diff.What.changed, resized.what);
    try std.testing.expectEqualStrings("fn resized(a: u32) void", resized.old.?.sig.?);
    try std.testing.expectEqualStrings("fn resized(a: u64) void", resized.new.?.sig.?);

    // A doc-only change (indexOf became deprecated) is NOT a declaration change.
    try std.testing.expectEqual(@as(?diff.Change, null), findChange(changes, "std.mem.indexOf"));
    // Private: never listed.
    try std.testing.expectEqual(@as(?diff.Change, null), findChange(changes, "std.mem.secret"));
    // Sorted by path.
    for (changes[1..], changes[0 .. changes.len - 1]) |later, earlier| {
        try std.testing.expect(std.mem.order(u8, earlier.path, later.path) == .lt);
    }
}

test "compute: --private includes private additions" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sides(a);
    const changes = try diff.compute(a, s[0], s[1], true);
    try std.testing.expectEqual(diff.What.added, findChange(changes, "std.mem.secret").?.what);
}

test "moves: Type follows builtin → lang with its field; an ambiguous `Options` does not pair; tags never pair" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sides(a);
    const r = try diff.analyze(a, s[0], s[1], false);

    try std.testing.expectEqual(@as(usize, 2), r.moves.len);
    try std.testing.expectEqualStrings("std.builtin.Type", r.moves[0].from);
    try std.testing.expectEqualStrings("std.lang.Type", r.moves[0].to);
    try std.testing.expectEqualStrings("std.builtin.Type.name", r.moves[1].from);
    try std.testing.expectEqualStrings("std.lang.Type.name", r.moves[1].to);
    // Two removed `Options` structs and two added ones: no unique match, so no move.
    for (r.moves) |m| try std.testing.expect(std.mem.find(u8, m.from, "Options") == null);
    try std.testing.expect(r.moved.contains("std.lang.Type"));
    try std.testing.expect(!r.moved.contains("std.builtin.Mode.Debug"));
}

test "deprecations: newly, lifted, and deprecated-then-removed" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sides(a);
    const r = try diff.analyze(a, s[0], s[1], false);
    try std.testing.expectEqual(@as(usize, 2), r.deprecations.len);
    try std.testing.expectEqualStrings("std.mem.gone", r.deprecations[0].path);
    try std.testing.expectEqual(diff.Deprecation.State.removed, r.deprecations[0].state);
    try std.testing.expectEqualStrings("std.mem.indexOf", r.deprecations[1].path);
    try std.testing.expectEqual(diff.Deprecation.State.newly, r.deprecations[1].state);
    try std.testing.expectEqualStrings("Deprecated: use `find`.", r.deprecations[1].doc);
}

test "tag sets: renamed tags are summarised under their enum" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sides(a);
    const r = try diff.analyze(a, s[0], s[1], false);
    try std.testing.expectEqual(@as(usize, 1), r.tag_sets.len);
    try std.testing.expectEqualStrings("std.builtin.Mode", r.tag_sets[0].@"enum");
    try std.testing.expectEqual(@as(usize, 2), r.tag_sets[0].removed.len);
    try std.testing.expectEqualStrings("Debug", r.tag_sets[0].removed[0]);
    try std.testing.expectEqual(@as(usize, 2), r.tag_sets[0].added.len);
    try std.testing.expectEqualStrings("debug", r.tag_sets[0].added[0]);
}

test "builtins: added, removed, re-signed" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sides(a);
    const r = try diff.analyze(a, s[0], s[1], false);
    try std.testing.expectEqual(@as(usize, 3), r.builtins.len);
    try std.testing.expectEqualStrings("@branchHint", r.builtins[0].name);
    try std.testing.expectEqual(diff.BuiltinChange.State.added, r.builtins[0].state);
    try std.testing.expectEqualStrings("@setCold", r.builtins[1].name);
    try std.testing.expectEqual(diff.BuiltinChange.State.removed, r.builtins[1].state);
    try std.testing.expectEqualStrings("@splat", r.builtins[2].name);
    try std.testing.expectEqual(diff.BuiltinChange.State.changed, r.builtins[2].state);
}

test "resolved values: a constant whose value changed" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sides(a);
    const r = try diff.analyze(a, s[0], s[1], false);
    try std.testing.expectEqual(@as(usize, 1), r.values.len);
    try std.testing.expectEqualStrings("std.mem.max", r.values[0].path);
    try std.testing.expectEqualStrings("4096", r.values[0].old);
    try std.testing.expectEqualStrings("8192", r.values[0].new);
}

test "module and under" {
    try std.testing.expectEqualStrings("std.mem", diff.module("std.mem.eql"));
    try std.testing.expectEqualStrings("std.mem", diff.module("std.mem"));
    try std.testing.expectEqualStrings("std", diff.module("std"));
    try std.testing.expectEqualStrings("std.Io", diff.module("std.Io.Dir.openDir"));
    try std.testing.expect(diff.under("std.mem.eql", "std.mem"));
    try std.testing.expect(diff.under("std.mem", "std.mem"));
    try std.testing.expect(!diff.under("std.memory", "std.mem"));
}

test "tallies: per module, largest first" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sides(a);
    const ts = try diff.tallies(a, try diff.compute(a, s[0], s[1], false));
    try std.testing.expect(ts.len >= 2);
    try std.testing.expectEqualStrings("std.builtin", ts[0].module); // 4 removed + 2 added tags/decls
    var mem: ?diff.Tally = null;
    for (ts) |t| if (std.mem.eql(u8, t.module, "std.mem")) {
        mem = t;
    };
    try std.testing.expectEqual(@as(usize, 1), mem.?.added);
    try std.testing.expectEqual(@as(usize, 1), mem.?.removed);
    try std.testing.expectEqual(@as(usize, 2), mem.?.changed);
}

test "report: moves, tags and deprecations get their own sections; removed list skips moved and tag paths" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sides(a);
    const r = try diff.analyze(a, s[0], s[1], false);

    var aw: std.Io.Writer.Allocating = .init(a);
    try diff.report(a, &aw.writer, "0.16.0", "0.17.0", r, .{});
    const text = aw.writer.buffered();
    try std.testing.expect(std.mem.find(u8, text, "## moved — INFERRED") != null);
    try std.testing.expect(std.mem.find(u8, text, "`std.builtin.Type` → `std.lang.Type`") != null);
    try std.testing.expect(std.mem.find(u8, text, "`std.builtin.Mode`: -Debug -ReleaseSafe +debug +safe") != null);
    try std.testing.expect(std.mem.find(u8, text, "deprecated, now removed") != null);
    try std.testing.expect(std.mem.find(u8, text, "newly deprecated: Deprecated: use `find`.") != null);
    try std.testing.expect(std.mem.find(u8, text, "was: fn resized(a: u32) void") != null);
    try std.testing.expect(std.mem.find(u8, text, "`@splat`\n    - was:") != null);
    try std.testing.expect(std.mem.find(u8, text, "`std.mem.max`  4096 → 8192") != null);
    // The removed list names `gone` and the ambiguous Options, but not the moved Type or the tags.
    const removed_at = std.mem.find(u8, text, "## removed").?;
    const next_at = std.mem.find(u8, text[removed_at..], "## enum tag sets").? + removed_at;
    const removed_section = text[removed_at..next_at];
    try std.testing.expect(std.mem.find(u8, removed_section, "`std.mem.gone`") != null);
    try std.testing.expect(std.mem.find(u8, removed_section, "`std.builtin.Options`") != null);
    try std.testing.expect(std.mem.find(u8, removed_section, "`std.builtin.Type`") == null);
    try std.testing.expect(std.mem.find(u8, removed_section, "Mode.Debug") == null);

    // TSV: a provenance column, moves labelled inferred.
    var tw: std.Io.Writer.Allocating = .init(a);
    try diff.report(a, &tw.writer, "0.16.0", "0.17.0", r, .{ .tsv = true });
    const t = tw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, t, "change\tprovenance\tpath\tkind_old\tkind_new\told\tnew\n"));
    try std.testing.expect(std.mem.find(u8, t, "moved\tinferred\tstd.builtin.Type\tstruct\tstruct\tstd.builtin.Type\tstd.lang.Type\n") != null);
    try std.testing.expect(std.mem.find(u8, t, "builtin_changed\textracted\t@splat\t") != null);
    try std.testing.expect(std.mem.find(u8, t, "value_changed\textracted\tstd.mem.max\tconst_int\tconst_int\t4096\t8192\n") != null);
    try std.testing.expect(std.mem.find(u8, t, "deprecated_removed\textracted\tstd.mem.gone\t") != null);

    // Filters: one kind, one prefix.
    var fw: std.Io.Writer.Allocating = .init(a);
    try diff.report(a, &fw.writer, "a", "b", r, .{ .only = .removed, .prefix = "std.mem" });
    try std.testing.expect(std.mem.find(u8, fw.writer.buffered(), "1 removed · 0 changed · 0 added") != null);
    try std.testing.expect(std.mem.find(u8, fw.writer.buffered(), "## moved") == null);
}

test "versionFromPinned reads the first line" {
    try std.testing.expectEqualStrings("0.17.0", snapshot.versionFromPinned("zig 0.17.0\ntarget x86_64-linux\n").?);
    try std.testing.expectEqual(@as(?[]const u8, null), snapshot.versionFromPinned("target only\n"));
    try std.testing.expectEqual(@as(?[]const u8, null), snapshot.versionFromPinned("zig \n"));
}
