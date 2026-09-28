// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! cmd/overlays.zig — the `zephem overlays` subcommand: rebuild the derived overlays (ports of
//! `scripts/build_{canon,consensus,callcard,doccov,sigshape}.nu`). Each overlay is a pure
//! relational transform; `--check` proves each rebuilds to its recorded single-file manifest.
const std = @import("std");
const argv = @import("../args.zig");
const Ctx = @import("../ctx.zig").Ctx;
const vars = @import("../vars.zig");
const manifest = @import("../manifest.zig");
const overlays = @import("../overlays.zig");
const rel = @import("../relation.zig");
const util = @import("../util.zig");

const Overlay = struct {
    name: []const u8, // derived/<name>.tsv and SHA256SUMS.<name>
    derive: *const fn (Ctx, []const u8) anyerror!rel.Table,
};

const all = [_]Overlay{
    .{ .name = "canon", .derive = overlays.canon },
    .{ .name = "consensus", .derive = overlays.consensus },
    .{ .name = "callcard", .derive = overlays.callcard },
    .{ .name = "doccov", .derive = overlays.doccov },
    .{ .name = "sigshape", .derive = overlays.sigshape },
};

pub fn run(c: Ctx, args: []const []const u8) !void {
    const usage =
        \\usage: zephem overlays [--check] [<name>]
        \\
        \\  rebuild the derived overlays; <name> limits it to one
        \\  names: canon · consensus · callcard · doccov · sigshape
        \\
    ;
    if (try argv.helpRequested(c, args, usage)) return;

    var check = false;
    var only: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) check = true else if (!std.mem.startsWith(u8, arg, "--")) only = arg else argv.reject(c, arg, usage);
    }

    // A name that matches no overlay used to skip every iteration, print nothing and exit 0 —
    // reporting success having done nothing. A typo must fail, not silently no-op.
    if (only) |o| {
        var known = false;
        for (all) |ov| {
            if (std.mem.eql(u8, o, ov.name)) known = true;
        }
        if (!known) argv.reject(c, o, usage);
    }

    const a = c.a;
    const dir = try vars.dataDir(c);
    try std.Io.Dir.cwd().createDirPath(c.io, try std.fs.path.join(a, &.{ dir, "derived" }));

    var ow = std.Io.File.stdout().writer(c.io, try a.alloc(u8, 4096));
    const w = &ow.interface;
    defer w.flush() catch {}; // zsnag:ok — progress report only (datasets are written with `try`); a defer cannot return the error

    var ok = true;
    for (all) |ov| {
        if (only) |o| if (!std.mem.eql(u8, o, ov.name)) continue;
        const table = try ov.derive(c, dir);
        const tsv = try serialize(a, table);
        const man_path = try std.fmt.allocPrint(a, "{s}/SHA256SUMS.{s}", .{ dir, ov.name });

        if (check) {
            const got = manifest.sha256Hex(tsv);
            const want = firstHash(c, man_path) catch {
                try w.print("[{s} check] no manifest — build first\n", .{ov.name});
                ok = false;
                continue;
            };
            if (std.mem.eql(u8, &got, want)) {
                try w.print("[{s} check] ✓ rebuilds byte-identical\n", .{ov.name});
            } else {
                try w.print("[{s} check] ✗ DRIFT — manifest {s} vs rebuild {s}\n", .{ ov.name, want, got[0..] });
                ok = false;
            }
        } else {
            const out_path = try std.fmt.allocPrint(a, "{s}/derived/{s}.tsv", .{ dir, ov.name });
            try writeBytes(c, out_path, tsv);
            var entry = [_]manifest.Entry{.{ .path = try std.fmt.allocPrint(a, "derived/{s}.tsv", .{ov.name}), .hex = manifest.sha256Hex(tsv) }};
            try manifest.writeManifest(c.io, &entry, man_path);
            try w.print("[{s}] {d} rows → derived/{s}.tsv  (manifest → SHA256SUMS.{s})\n", .{ ov.name, table.rows.len, ov.name, ov.name });
        }
    }
    if (!ok) {
        try w.flush();
        std.process.exit(1);
    }
}

fn serialize(a: std.mem.Allocator, t: rel.Table) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    try rel.writeTsv(t, &aw.writer);
    return aw.writer.buffered();
}

fn firstHash(c: Ctx, man_path: []const u8) ![]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(c.io, man_path, c.a, .unlimited);
    const recs = try manifest.parse(c.a, bytes);
    if (recs.len == 0) return error.EmptyManifest;
    return recs[0].hex;
}

fn writeBytes(c: Ctx, path: []const u8, bytes: []const u8) !void {
    return util.writeFile(c.io, path, bytes);
}
