// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! ⚠ DATED, NON-BUILDING COMPARISON ARTIFACT — not part of the zephem toolchain and not built by
//! `build.zig`. It `@import("Walk.zig")`/`@import("Decl.zig")` from Zig's autodoc tree (not vendored
//! here) and hardcodes a std root; it was run once, against a pinned Zig, to produce the figures in
//! `autodoc-vs-zephem.md`. Kept for provenance/reproduction of that note only — do not expect it to
//! compile as-is.
//!
//! Drives autodoc's OWN Walk.zig + Decl.zig natively to dump the exact set of
//! reachable pub-decl FQNs it would show for std, mirroring the browser UI's
//! navigation (namespace_members with include_private=false, descending through
//! aliases and type-functions).
const std = @import("std");
const Walk = @import("Walk.zig");
const Decl = Walk.Decl;

const gpa = std.heap.page_allocator; // zsnag:ok — R009: a one-shot dump; everything lives until exit, so the page allocator is the simplest correct choice

const STD_ROOT = "/usr/lib/zig/std";

pub fn main() !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = threaded.io();

    // 1. Load every std/*.zig file into the walker.
    var std_std_file: ?Walk.File.Index = null;
    var dir = try std.Io.Dir.openDirAbsolute(io, STD_ROOT, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var file_count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const raw = try dir.readFileAlloc(io, entry.path, gpa, .unlimited);
        // add_file requires a trailing newline (it becomes the 0 sentinel).
        var bytes = raw;
        if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') {
            bytes = try gpa.realloc(raw, raw.len + 1);
            bytes[bytes.len - 1] = '\n';
        }
        // Name files under a "std/" module prefix, matching autodoc's tar layout.
        const name = try std.fmt.allocPrint(gpa, "std/{s}", .{entry.path});
        // Normalize backslashes just in case (posix here, but be safe).
        const fidx = try Walk.add_file(name, bytes);
        if (std.mem.eql(u8, entry.path, "std.zig")) std_std_file = fidx;
        file_count += 1;
    }

    const root_file = std_std_file orelse return error.NoStdRoot;
    try Walk.modules.put(gpa, "std", root_file);
    const root_decl = root_file.findRootDecl();
    if (root_decl == .none) return error.NoRootDecl;

    // 2. BFS the reachable pub-decl tree.
    var visited = std.AutoHashMap(u32, void).init(gpa); // expanded container decls
    var seen_fqn = std.StringHashMap(void).init(gpa); // dedup printed paths
    var queue = std.ArrayList(Decl.Index).empty;
    try queue.append(gpa, root_decl);
    try visited.put(@intFromEnum(root_decl), {});

    var stdout_buf: [1 << 16]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const w = &fw.interface;

    var printed: usize = 0;
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const parent = queue.items[qi];
        for (Walk.decls.items, 0..) |*decl, i| {
            if (decl.parent != parent) continue;
            if (!decl.is_pub()) continue;

            // Print this member's FQN.
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(gpa);
            try decl.fqn(&buf);
            const gop = try seen_fqn.getOrPut(buf.items);
            if (!gop.found_existing) {
                gop.key_ptr.* = try gpa.dupe(u8, buf.items);
                try w.writeAll(buf.items);
                try w.writeAll("\n");
                printed += 1;
            }

            // Decide whether to descend (resolve aliases first).
            var tgt: u32 = @intCast(i); // zsnag:ok — R007: `i` indexes Walk.decls, which autodoc itself indexes with u32
            var chase: usize = 0;
            const target_cat = while (chase < 32) : (chase += 1) {
                const c = @as(Decl.Index, @enumFromInt(tgt)).get().categorize();
                switch (c) {
                    .alias => |a| {
                        if (a == .none) break c;
                        tgt = @intFromEnum(a);
                    },
                    else => break c,
                }
            } else @as(Decl.Index, @enumFromInt(tgt)).get().categorize();

            const expandable = switch (target_cat) {
                .namespace, .container, .type_function => true,
                else => false,
            };
            if (expandable and !visited.contains(tgt)) {
                try visited.put(tgt, {});
                try queue.append(gpa, @enumFromInt(tgt));
            }
        }
    }

    try w.flush();
    std.debug.print("# files={d} reachable_pub_fqns={d} total_decls={d}\n", .{ file_count, printed, Walk.decls.items.len }); // zsnag:ok — R010: this stderr summary line is the program's intended output, read by the comparison note
}
