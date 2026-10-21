// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! cmd/depth.zig — the `zephem depth` subcommand: the L5 reflection sweep (port of
//! `scripts/build_depth.nu`). Deliberately separate from `zephem std --check` — an L5 rebuild is a
//! full reflection sweep and is slow/machine-dependent, so its reproducibility lives here.
const std = @import("std");
const argv = @import("../args.zig");
const Ctx = @import("../ctx.zig").Ctx;
const vars = @import("../vars.zig");
const toolchain = @import("../toolchain.zig");
const manifest = @import("../manifest.zig");
const depth = @import("../depth.zig");
const verify = @import("../verify/depth.zig");
const rel = @import("../relation.zig");
const util = @import("../util.zig");

const names = [_][]const u8{ "extracted/status.tsv", "extracted/resolved.tsv", "extracted/poison.tsv" };
const scratch_root = ".zig-cache/zephem-depth";

pub fn run(c: Ctx, args: []const []const u8) !void {
    var only: ?[]const u8 = null;
    var filter: ?[]const u8 = null;
    var list: ?[]const u8 = null;
    var limit: usize = 0;
    var timeout_s: u32 = 90;
    var jobs: usize = 0;
    var out: ?[]const u8 = null;
    var commit = false;
    var check = false;
    var mode: depth.Mode = .batched;
    const usage =
        \\usage: zephem depth [--commit] [--check] [--solo] [--only P] [--filter S]
        \\                    [--list FILE] [--limit N] [--timeout S] [--jobs N] [--out DIR]
        \\
        \\  run the L5 reflection sweep: containers are probed ~50 per object file, then the
        \\  clean ones reflected ~50 per binary (see src/depth.zig)
        \\
        \\  --solo     the reference sweep: one `zig run` per container (minutes); produces
        \\             byte-identical datasets, kept to re-prove the batched one
        \\
    ;
    if (try argv.helpRequested(c, args, usage)) return;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--commit")) commit = true else if (std.mem.eql(u8, arg, "--check")) check = true else if (std.mem.eql(u8, arg, "--solo")) mode = .solo else if (std.mem.eql(u8, arg, "--only")) {
            only = argv.value(c, args, &i, "--only", usage);
        } else if (std.mem.eql(u8, arg, "--filter")) {
            filter = argv.value(c, args, &i, "--filter", usage);
        } else if (std.mem.eql(u8, arg, "--list")) {
            list = argv.value(c, args, &i, "--list", usage);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            limit = argv.intValue(c, usize, args, &i, "--limit", usage);
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            timeout_s = argv.intValue(c, u32, args, &i, "--timeout", usage);
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            jobs = argv.intValue(c, usize, args, &i, "--jobs", usage);
        } else if (std.mem.eql(u8, arg, "--out")) {
            out = argv.value(c, args, &i, "--out", usage);
        } else argv.reject(c, arg, usage);
    }

    if (commit and (only != null or filter != null or list != null or limit != 0)) {
        try argv.diag(c, "zephem depth: --commit replaces the whole overlay; it cannot be combined with --only, --filter, --list or --limit (use --out DIR for a partial sweep)\n", .{});
        std.process.exit(2);
    }

    const a = c.a;
    const data_dir = try vars.dataDir(c);
    const index_path = try std.fs.path.join(a, &.{ data_dir, "derived/index.tsv" });
    const index = try rel.load(a, c.io, index_path);
    const template = try std.Io.Dir.cwd().readFileAlloc(c.io, try vars.repoFile(c, "reflect/resolve.zig"), a, .unlimited);
    const env = try toolchain.probe(c);
    const jcount = if (jobs > 0) jobs else @import("../proc.zig").ncpu();

    var ow = std.Io.File.stdout().writerStreaming(c.io, try a.alloc(u8, 4096));
    const w = &ow.interface;
    defer w.flush() catch {}; // zsnag:ok — progress report only (datasets are written with `try`); a defer cannot return the error

    // the direct-child names of each container, for the SKIP set (dotted split-drop-last, exactly
    // as the Nushell built it — quote edge cases included).
    const kids = try buildKids(a, index);

    // The overlay is keyed onto the core map and reflected with the compiler: both must be the
    // same Zig, or every row describes a different std than the map it is attached to.
    if (commit or check) if (try toolchain.staleness(c, data_dir)) |msg| {
        try argv.diag(c, "zephem depth: ✗ {s}\n  (the core map in {s} and the compiler doing the reflection must be the same Zig)\n", .{ msg, data_dir });
        std.process.exit(1);
    };
    if (try depth.selfTest(c, env.zig_exe, template, try std.fs.path.join(a, &.{ scratch_root, "selftest" }), timeout_s)) |err| {
        try argv.diag(c, "zephem depth: ✗ the reflection template (reflect/resolve.zig) does not work with zig {s} — port it before sweeping:\n{s}\n", .{ env.version, err });
        std.process.exit(1);
    }

    if (check) {
        try proveReproducible(c, index, kids, env, template, data_dir, timeout_s, jcount, mode, w);
        return;
    }

    const all_targets = try selectTargets(a, c, index, only, filter, list, limit);
    const skips = try skipsFor(a, all_targets, kids);
    const values = try valuesFor(a, all_targets, index);
    // --commit sweeps into a staging dir and installs into data_dir only after verify passes, so a
    // rejected sweep leaves the committed overlay untouched.
    const outdir = if (commit) try std.fs.path.join(a, &.{ scratch_root, "commit" }) else (out orelse try std.fs.path.join(a, &.{ scratch_root, "out" }));

    try w.print("[L5] reflecting {d} container(s) — {s}, {d} lanes, {d}s timeout per compile\n", .{ all_targets.len, @tagName(mode), jcount, timeout_s });
    const counts = try depth.sweep(c, all_targets, skips, values, env.zig_exe, template, env.std_dir, try std.fs.path.join(a, &.{ scratch_root, "scratch" }), outdir, timeout_s, jcount, mode);
    try w.print("[L5] resolved: {d} containers + {d} partial, {d} rows   poison: {d} containers + {d} decls   private: {d}   skipped: {d} (no expression reaches it, or a value its parent reflects)   attempted: {d}\n", .{ counts.resolved_containers, counts.partial, counts.resolved_rows, counts.poison, counts.decl_poison, counts.private, counts.skipped, counts.attempted });
    if (mode == .batched) try w.print("[L5] probe {d} ms ({d} compiles) · run {d} ms ({d} compiles) · {d} solo\n", .{ counts.probe_ms, counts.probe_compiles, counts.run_ms, counts.run_compiles, counts.solo_compiles });
    try w.flush();

    if (!try verify.run(c, outdir, index_path, commit)) {
        try w.writeAll("build_depth: ✗ overlay rejected by verify_depth\n");
        try w.flush();
        std.process.exit(1);
    }

    if (commit) {
        const cwd = std.Io.Dir.cwd();
        for (names) |name| {
            try cwd.copyFile(try std.fs.path.join(a, &.{ outdir, name }), cwd, try std.fs.path.join(a, &.{ data_dir, name }), c.io, .{});
        }
        try writeManifest(c, data_dir, try std.fs.path.join(a, &.{ data_dir, "SHA256SUMS.depth" }));
        try w.writeAll("[L5] manifest → SHA256SUMS.depth  (run --check to prove it rebuilds — SLOW)\n");
    }
}

fn proveReproducible(c: Ctx, index: rel.Table, kids: Kids, env: toolchain.Env, template: []const u8, data_dir: []const u8, timeout_s: u32, jcount: usize, mode: depth.Mode, w: *std.Io.Writer) !void {
    const a = c.a;
    const man_path = try std.fs.path.join(a, &.{ data_dir, "SHA256SUMS.depth" });
    const man_bytes = std.Io.Dir.cwd().readFileAlloc(c.io, man_path, a, .unlimited) catch {
        try w.writeAll("[L5 check] no SHA256SUMS.depth — run --commit first\n");
        std.process.exit(1);
    };
    const recorded = try manifest.parse(a, man_bytes);
    try w.print("[L5 check] proving the depth overlay rebuilds — two full {s} sweeps, {d} lanes each\n", .{ @tagName(mode), jcount });

    var committed: [names.len][manifest.hex_len]u8 = undefined;
    for (names, 0..) |name, k| committed[k] = try manifest.sha256File(c.io, a, try std.fs.path.join(a, &.{ data_dir, name }));

    const targets = try allPaths(a, index);
    const skips = try skipsFor(a, targets, kids);
    const values = try valuesFor(a, targets, index);
    const dir_a = try std.fs.path.join(a, &.{ scratch_root, "check-a" });
    const dir_b = try std.fs.path.join(a, &.{ scratch_root, "check-b" });
    _ = try depth.sweep(c, targets, skips, values, env.zig_exe, template, env.std_dir, try std.fs.path.join(a, &.{ scratch_root, "sa" }), dir_a, timeout_s, jcount, mode);
    _ = try depth.sweep(c, targets, skips, values, env.zig_exe, template, env.std_dir, try std.fs.path.join(a, &.{ scratch_root, "sb" }), dir_b, timeout_s, jcount, mode);

    var ok = true;
    for (names, 0..) |name, k| {
        const ha = try manifest.sha256File(c.io, a, try std.fs.path.join(a, &.{ dir_a, name }));
        const hb = try manifest.sha256File(c.io, a, try std.fs.path.join(a, &.{ dir_b, name }));
        const want = manifest.hexFor(recorded, name);
        const intrinsic = std.mem.eql(u8, &ha, &hb);
        const regression = if (want) |x| std.mem.eql(u8, &ha, x) else false;
        const integrity = if (want) |x| std.mem.eql(u8, &committed[k], x) else false;
        if (!intrinsic or !regression or !integrity) ok = false;
        try w.print("  {s}: intrinsic {s}   reproduces-manifest {s}   on-disk-matches-manifest {s}\n", .{ name, mark(intrinsic), mark(regression), mark(integrity) });
    }
    if (ok) {
        try w.writeAll("L5 reproducible: ✓ two fresh rebuilds agree, reproduce the manifest, and the snapshot matches it\n");
    } else {
        try w.writeAll("L5 reproducible: ✗ DRIFT — the overlay is NOT provably rebuildable\n");
        try w.flush();
        std.process.exit(1);
    }
}

// ── target selection ────────────────────────────────────────────────────────

fn selectTargets(a: std.mem.Allocator, c: Ctx, index: rel.Table, only: ?[]const u8, filter: ?[]const u8, list: ?[]const u8, limit: usize) ![]const []const u8 {
    var targets: []const []const u8 = undefined;
    if (only) |o| {
        const t = try a.alloc([]const u8, 1);
        t[0] = o;
        targets = t;
    } else if (list) |lp| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(c.io, lp, a, .unlimited);
        var out: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |ln| {
            const t = std.mem.trim(u8, ln, " \t\r");
            if (t.len != 0) try out.append(a, t);
        }
        targets = try out.toOwnedSlice(a);
    } else if (filter) |f| {
        var out: std.ArrayList([]const u8) = .empty;
        const pi = index.col("path");
        for (index.rows) |r| {
            if (std.mem.find(u8, r[pi], f) != null) try out.append(a, r[pi]);
        }
        targets = try out.toOwnedSlice(a);
    } else {
        targets = try allPaths(a, index);
    }
    if (limit > 0 and targets.len > limit) targets = targets[0..limit];
    return targets;
}

fn allPaths(a: std.mem.Allocator, index: rel.Table) ![]const []const u8 {
    const pi = index.col("path");
    const out = try a.alloc([]const u8, index.rows.len);
    for (index.rows, 0..) |r, k| out[k] = r[pi];
    return out;
}

// ── the SKIP (direct-child) map ─────────────────────────────────────────────

const Kids = std.StringHashMap(std.ArrayList([]const u8));

/// Group each index path's last dotted segment under its dotted parent (all-but-last segment),
/// exactly matching the Nushell `split row "." | drop 1` behaviour.
fn buildKids(a: std.mem.Allocator, index: rel.Table) !Kids {
    var kids = Kids.init(a);
    const pi = index.col("path");
    const ki = index.col("kind");
    for (index.rows) |r| {
        const path = r[pi];
        // A const/alias is a container only through its `[…]` variants and is not reflected on
        // its own turn (`valuesFor`), so its parent must descend into it as into any value.
        if (std.mem.eql(u8, r[ki], "const") or std.mem.eql(u8, r[ki], "alias") or std.mem.eql(u8, r[ki], "field")) continue;
        const par = util.dottedParent(path);
        const child = util.lastSeg(path);
        const gop = try kids.getOrPut(par);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, child);
    }
    return kids;
}

fn skipsFor(a: std.mem.Allocator, targets: []const []const u8, kids: Kids) ![]const []const []const u8 {
    const out = try a.alloc([]const []const u8, targets.len);
    for (targets, 0..) |t, k| {
        out[k] = if (kids.get(t)) |g| g.items else &.{};
    }
    return out;
}

// ── misc ────────────────────────────────────────────────────────────────────

/// The sweep's files, then the core manifest it reflected against: if the core is regenerated
/// with a different result afterwards, that line no longer matches and `snapshot` refuses to
/// freeze the mix.
fn writeManifest(c: Ctx, data_dir: []const u8, out_path: []const u8) !void {
    var entries: [names.len + 1]manifest.Entry = undefined;
    for (names, 0..) |name, k| entries[k] = .{ .path = name, .hex = try manifest.sha256File(c.io, c.a, try std.fs.path.join(c.a, &.{ data_dir, name })) };
    entries[names.len] = .{ .path = "SHA256SUMS", .hex = try manifest.sha256File(c.io, c.a, try std.fs.path.join(c.a, &.{ data_dir, "SHA256SUMS" })) };
    try manifest.writeManifest(c.io, &entries, out_path);
}

const mark = util.mark;

/// Per target: is it a `const` or `alias` in the index? Such a node is a container only because
/// it has `[…]` variants under it (a per-platform switch); its value is reflected as a decl of its
/// parent, so it is not reflected again on its own.
fn valuesFor(a: std.mem.Allocator, targets: []const []const u8, index: rel.Table) ![]const bool {
    var kind: std.StringHashMapUnmanaged([]const u8) = .empty;
    const pi = index.col("path");
    const ki = index.col("kind");
    for (index.rows) |r| try kind.put(a, r[pi], r[ki]);
    const out = try a.alloc(bool, targets.len);
    for (targets, out) |t, *o| {
        const k = kind.get(t) orelse "";
        o.* = std.mem.eql(u8, k, "const") or std.mem.eql(u8, k, "alias") or std.mem.eql(u8, k, "field");
        // under a field whose type is a container literal (`contents: union { pub const X … }`):
        // no expression reaches it either; its members are reflected through the field's type
        var p = util.dottedParent(t);
        while (!o.* and p.len > 0) : (p = util.dottedParent(p)) {
            if (std.mem.eql(u8, kind.get(p) orelse "", "field")) o.* = true;
            if (std.mem.findScalar(u8, p, '.') == null) break;
        }
    }
    return out;
}
