// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const testing = std.testing;
const langref = @import("langref");

test "the compiler table: names in order, fixed arity and variadic" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const src =
        \\param_count: ?u8,
        \\pub const list = list: {
        \\        .{
        \\            "@addWithOverflow",
        \\            .{
        \\                .tag = .add_with_overflow,
        \\                .param_count = 2,
        \\            },
        \\        },
        \\        .{
        \\            "@compileLog",
        \\            .{
        \\                .tag = .compile_log,
        \\                .param_count = null,
        \\            },
        \\        },
    ;
    const t = try langref.table(a.allocator(), src);
    try testing.expectEqual(2, t.len);
    try testing.expectEqualStrings("@addWithOverflow", t[0].name);
    try testing.expectEqual(@as(?u8, 2), t[0].params);
    try testing.expectEqual(@as(?u8, null), t[1].params);
}

test "an unreadable table is an error, not an empty dataset" {
    try testing.expectError(error.TableUnreadable, langref.table(testing.allocator, "nothing here"));
}

test "arity: plain, nested types, trailing comma, variadic" {
    try testing.expectEqual(@as(?usize, 1), langref.sigParams("@intCast(int: anytype) anytype"));
    try testing.expectEqual(@as(?usize, 0), langref.sigParams("@This() type"));
    try testing.expectEqual(@as(?usize, 2), langref.sigParams("@f(a: fn (u8, u8) void, b: [2]u8) void"));
    // @Pointer's multi-line form ends its list with a comma; that is not a parameter
    try testing.expectEqual(@as(?usize, 2), langref.sigParams("@P(\n    a: A,\n    b: ?B,\n) type"));
    try testing.expectEqual(@as(?usize, null), langref.sigParams("@compileLog(...) void"));
}

test "a section: signature, prose without figures, first zig example, entities decoded" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const html =
        \\<h3 id="intCast"><a href="#toc-intCast">@intCast</a> <a class="hdr" href="#intCast">§</a></h3>
        \\<pre><code><span class="tok-builtin">@intCast</span>(int: <span class="tok-kw">anytype</span>) anytype</code></pre>
        \\<p>
        \\  Converts an integer &amp; keeps
        \\  its value.
        \\</p>
        \\<figure><figcaption class="zig-cap"><cite>t.zig</cite></figcaption><pre><code>test &quot;x&quot; {
        \\    _ = 1;
        \\}</code></pre></figure><figure><figcaption class="shell-cap">Shell</figcaption><pre><samp>$ zig test</samp></pre></figure>
        \\<p>See <a href="#truncate">@truncate</a>.</p>
        \\<h3 id="next"><a href="#toc-next">@next</a></h3>
        \\<pre><code>@next() void</code></pre>
        \\<h2 id="Other">Other</h2>
    ;
    const s = try langref.sections(a.allocator(), html);
    try testing.expectEqual(2, s.count());
    const d = s.get("@intCast").?;
    try testing.expectEqualStrings("@intCast(int: anytype) anytype", d.sig);
    try testing.expectEqualStrings("Converts an integer & keeps its value. See @truncate.", d.doc);
    try testing.expectEqualStrings("test \"x\" {\\n    _ = 1;\\n}", d.example);
    try testing.expectEqual(@as(?usize, 1), d.arity);
    try testing.expectEqualStrings("", s.get("@next").?.doc);
}

test "a doc comment inside the parameter list does not change the arity" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const html =
        \\<h3 id="U"><a href="#toc-U">@U</a></h3>
        \\<pre><code>@U(
        \\    comptime a: A,
        \\    /// Either this, or that, depending.
        \\    comptime b: ?type,
        \\) type</code></pre>
    ;
    const s = try langref.sections(a.allocator(), html);
    try testing.expectEqual(@as(?usize, 2), s.get("@U").?.arity);
}
