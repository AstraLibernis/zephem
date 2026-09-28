// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! cmd/std.zig — the `zephem std` subcommand: regenerate the core map, prove it (forward ==
//! backward), and record the reproducibility manifest. Port of `scripts/build_std.nu`.
//!
//!   normal   parse std → nodes/attrs/edges, derive index, write PINNED, verify, write SHA256SUMS
//!   --check  two fresh rebuilds must agree (intrinsic), reproduce the committed manifest
//!            (regression), and match the on-disk snapshot (integrity)
//!
//! Everything runs in-process — no `zig run` handoff. The intermediate TSVs ARE the product, so
//! they are still written to disk; only the orchestration moved from Nushell into Zig.
const std = @import("std");
const argv = @import("../args.zig");
const Ctx = @import("../ctx.zig").Ctx;
const vars = @import("../vars.zig");
const toolchain = @import("../toolchain.zig");
const manifest = @import("../manifest.zig");
const parse = @import("parse");
const derive_index = @import("derive");
const langref = @import("langref");
const verify = @import("../verify/std.zig");
const rel = @import("../relation.zig");
const util = @import("../util.zig");

/// The datasets this build produces and hashes, as data-dir-relative names (manifest keys).
const names = [_][]const u8{
    "extracted/nodes.tsv",
    "extracted/attrs.tsv",
    "extracted/edges.tsv",
    "extracted/builtins.tsv",
    "derived/index.tsv",
};

const check_base = ".zig-cache/zephem-check";

pub fn run(c: Ctx, args: []const []const u8) !void {
    const usage =
        \\usage: zephem std [--check] [--depth N]
        \\
        \\  regenerate the core std map (parse + index + verify + manifest)
        \\
        \\  --check      prove the map rebuilds; do not overwrite
        \\  --depth N    parse depth (default 24)
        \\
    ;
    if (try argv.helpRequested(c, args, usage)) return;

    var check = false;
    var depth: u32 = 24;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--check")) {
            check = true;
        } else if (std.mem.eql(u8, args[i], "--depth")) {
            depth = argv.intValue(c, u32, args, &i, "--depth", usage);
        } else argv.reject(c, args[i], usage);
    }

    const data_dir = try vars.dataDir(c);
    const env = try toolchain.probe(c);
    const root = try std.fs.path.join(c.a, &.{ env.std_dir, "std.zig" });
    const zver = env.version;
    const src: Sources = .{ .root = root, .builtin_fn = try std.fs.path.join(c.a, &.{ env.std_dir, "zig", "BuiltinFn.zig" }), .langref = langrefPath(c, env) };

    var buf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writer(c.io, &buf);
    const w = &ow.interface;

    if (check) {
        try proveReproducible(c, src, data_dir, zver, depth, w);
        try w.flush();
        return;
    }

    // ── forward: regenerate ──────────────────────────────────────────────────
    try w.print("[forward]  scanning {s}  (zig {s}, depth {d})\n", .{ root, zver, depth });
    if (src.langref == null) try w.writeAll("[builtins] ⚠ this toolchain ships no doc/langref.html — builtins get names and arity only\n");
    _ = try regen(c, src, data_dir);
    // PINNED: first line the version (consumers read it), second the target triple (the reflect
    // layer is target-scoped — a Windows decl poisons on linux, usize=u64 here, etc.).
    try writeFileStr(c, try join(c.a, data_dir, "PINNED"), try std.fmt.allocPrint(c.a, "zig {s}\ntarget {s}\n", .{ zver, env.target }));
    try report(c, data_dir, w);

    // ── backward: verify ─────────────────────────────────────────────────────
    try w.writeAll("[backward] re-reading the datasets — must reconcile...\n");
    try w.flush();
    if (!try verify.run(c, data_dir)) {
        try w.writeAll("build_std: ✗ forward and backward DISAGREE — snapshot rejected.\n");
        try w.flush();
        std.process.exit(1);
    }

    // ── record the manifest ──────────────────────────────────────────────────
    try writeManifest(c, data_dir, try join(c.a, data_dir, "SHA256SUMS"));
    try w.writeAll("build_std: ✓ true (forward == backward) and recorded — run --check to prove it rebuilds.\n");
    try w.flush();
}

const Sources = struct { root: []const u8, builtin_fn: []const u8, langref: ?[]const u8 };

/// `doc/langref.html` beside the toolchain's `lib/` (the layout of the official tarballs), or
/// null when this install has no docs.
fn langrefPath(c: Ctx, env: toolchain.Env) ?[]const u8 {
    const lib = std.fs.path.dirname(env.std_dir) orelse return null;
    const prefix = std.fs.path.dirname(lib) orelse return null;
    const p = std.fs.path.join(c.a, &.{ prefix, "doc", "langref.html" }) catch return null;
    std.Io.Dir.cwd().access(c.io, p, .{}) catch return null;
    return p;
}

/// Regenerate the datasets into `out_dir`. The single build path, shared by the normal build
/// and --check, so they cannot diverge.
fn regen(c: Ctx, src: Sources, out_dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(c.io, try join(c.a, out_dir, "extracted"));
    try std.Io.Dir.cwd().createDirPath(c.io, try join(c.a, out_dir, "derived"));
    const nodes = try join(c.a, out_dir, "extracted/nodes.tsv");
    const edges = try join(c.a, out_dir, "extracted/edges.tsv");
    const attrs = try join(c.a, out_dir, "extracted/attrs.tsv");
    const index = try join(c.a, out_dir, "derived/index.tsv");
    _ = try parse.run(c.a, c.io, src.root, nodes, edges, attrs);
    _ = try langref.run(c.a, c.io, src.builtin_fn, src.langref, try join(c.a, out_dir, "extracted/builtins.tsv"));
    _ = try derive_index.run(c.a, c.io, nodes, index);
}

/// The forward-build stats line, re-reading the datasets the way `build_std.nu` did.
fn report(c: Ctx, data_dir: []const u8, w: *std.Io.Writer) !void {
    const nodes = try rel.load(c.a, c.io, try join(c.a, data_dir, "extracted/nodes.tsv"));
    const ki = nodes.col("kind");
    const vi = nodes.col("vis");
    var files: usize = 0;
    var priv: usize = 0;
    for (nodes.rows) |r| {
        if (std.mem.eql(u8, r[ki], "ns")) files += 1;
        if (std.mem.eql(u8, r[vi], "priv")) priv += 1;
    }
    try w.print("           rows: {d}   files: {d}   private: {d}\n", .{ nodes.rows.len, files, priv });

    const attrs = try rel.load(c.a, c.io, try join(c.a, data_dir, "extracted/attrs.tsv"));
    const ai = attrs.col("attr");
    var doc: usize = 0;
    var sig: usize = 0;
    var value: usize = 0;
    var example: usize = 0;
    for (attrs.rows) |r| {
        const av = r[ai];
        if (std.mem.eql(u8, av, "doc")) doc += 1 else if (std.mem.eql(u8, av, "sig")) sig += 1 else if (std.mem.eql(u8, av, "value")) value += 1 else if (std.mem.eql(u8, av, "example")) example += 1;
    }
    try w.print("[attrs]    {d} rows — doc {d} · sig {d} · value {d} · example {d}\n", .{ attrs.rows.len, doc, sig, value, example });

    const bt = try rel.load(c.a, c.io, try join(c.a, data_dir, "extracted/builtins.tsv"));
    const bs = bt.col("sig");
    const be = bt.col("example");
    var documented: usize = 0;
    var examples: usize = 0;
    for (bt.rows) |r| {
        if (r[bs].len > 0) documented += 1;
        if (r[be].len > 0) examples += 1;
    }
    try w.print("[builtins] {d} builtins — {d} documented in langref · {d} with an example\n", .{ bt.rows.len, documented, examples });
}

// ── --check: reproducibility ────────────────────────────────────────────────

fn proveReproducible(c: Ctx, src: Sources, data_dir: []const u8, zver: []const u8, depth: u32, w: *std.Io.Writer) !void {
    try w.print("[check]    proving reproducibility  (zig {s}, depth {d})\n", .{ zver, depth });

    // committed hashes (before touching anything) + the recorded manifest
    var committed: [names.len][manifest.hex_len]u8 = undefined;
    for (names, 0..) |name, k| committed[k] = try manifest.sha256File(c.io, c.a, try join(c.a, data_dir, name));
    const man_bytes = std.Io.Dir.cwd().readFileAlloc(c.io, try join(c.a, data_dir, "SHA256SUMS"), c.a, .unlimited) catch {
        try w.writeAll("  ✗ no SHA256SUMS — run `zephem std` first\n");
        std.process.exit(1);
    };
    const recorded = try manifest.parse(c.a, man_bytes);

    const dir_a = try join(c.a, check_base, "a");
    const dir_b = try join(c.a, check_base, "b");
    std.Io.Dir.cwd().deleteTree(c.io, check_base) catch {}; // zsnag:ok — best-effort scratch cleanup; regen overwrites every file it later reads
    _ = try regen(c, src, dir_a);
    _ = try regen(c, src, dir_b);

    var ok = true;
    for (names, 0..) |name, k| {
        const ha = try manifest.sha256File(c.io, c.a, try join(c.a, dir_a, name));
        const hb = try manifest.sha256File(c.io, c.a, try join(c.a, dir_b, name));
        const want = manifest.hexFor(recorded, name);
        const intrinsic = std.mem.eql(u8, &ha, &hb);
        const regression = if (want) |x| std.mem.eql(u8, &ha, x) else false;
        const integrity = if (want) |x| std.mem.eql(u8, &committed[k], x) else false;
        if (!intrinsic or !regression or !integrity) ok = false;
        try w.print("  {s}: intrinsic {s}   reproduces-manifest {s}   on-disk-matches-manifest {s}\n", .{
            name, mark(intrinsic), mark(regression), mark(integrity),
        });
    }
    std.Io.Dir.cwd().deleteTree(c.io, check_base) catch {}; // zsnag:ok — best-effort scratch cleanup after the check; nothing reads it again

    if (ok) {
        try w.writeAll("reproducible: ✓ two fresh rebuilds agree, reproduce the manifest, and the snapshot matches it\n");
    } else {
        try w.writeAll("reproducible: ✗ DRIFT — the snapshot is NOT provably rebuildable\n");
        try w.flush();
        std.process.exit(1);
    }
}

const mark = util.mark;
const join = util.join;

fn writeManifest(c: Ctx, data_dir: []const u8, out_path: []const u8) !void {
    var entries: [names.len]manifest.Entry = undefined;
    for (names, 0..) |name, k| entries[k] = .{ .path = name, .hex = try manifest.sha256File(c.io, c.a, try join(c.a, data_dir, name)) };
    try manifest.writeManifest(c.io, &entries, out_path);
}

fn writeFileStr(c: Ctx, path: []const u8, bytes: []const u8) !void {
    return util.writeFile(c.io, path, bytes);
}
