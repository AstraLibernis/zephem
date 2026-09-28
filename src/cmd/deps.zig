// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! cmd/deps.zig — the `zephem deps` subcommand: map a project's dependencies the way `zephem std`
//! maps std, so `look` and `map` answer for the packages a project actually uses.
//!
//!   1. read `<project>/build.zig.zon` (and, for each package, its own) — `src/pkg.zig`
//!   2. find each package where `zig build --fetch` unpacked it: `<project>/zig-pkg/<hash>/`, or
//!      its `.path` for a local one. Nothing is fetched and no build script is run.
//!   3. read each package's `build.zig` for the modules it exports (`b.addModule`)
//!   4. walk each module with the std parser, root named after the module (`clap.parse`),
//!      derive the index, run the same structural self-check, and record a manifest
//!
//! Output: `data/deps/<package-hash>/<module>/{extracted,derived}/…` + `SOURCE` + `SHA256SUMS`.
//! A map that fails its self-check is deleted, never queried. The compiler-reflection layer is
//! std-only (it would need the build system to `@import` a package), so dependency rows carry
//! the source-level facts: tree, signatures, docs, fields, references, test examples.
const std = @import("std");
const argv = @import("../args.zig");
const Ctx = @import("../ctx.zig").Ctx;
const vars = @import("../vars.zig");
const toolchain = @import("../toolchain.zig");
const manifest = @import("../manifest.zig");
const pkg = @import("../pkg.zig");
const parse = @import("parse");
const derive_index = @import("derive");
const verify = @import("../verify/std.zig");
const util = @import("../util.zig");

const dataset_names = [_][]const u8{ "extracted/nodes.tsv", "extracted/attrs.tsv", "extracted/edges.tsv", "derived/index.tsv" };

pub fn run(c: Ctx, args: []const []const u8) !void {
    const usage =
        \\usage: zephem deps [PROJECT_DIR]
        \\
        \\  map the dependencies of the Zig project in PROJECT_DIR (default: .) so `look` and
        \\  `map` cover them. Packages must be fetched first: `zig build --fetch` in the project.
        \\  Maps go to data/deps/ (git-ignored); `rm -rf data/deps` forgets them all.
        \\
    ;
    if (try argv.helpRequested(c, args, usage)) return;
    var project: []const u8 = ".";
    var positional: usize = 0;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) argv.reject(c, arg, usage);
        positional += 1;
        if (positional > 1) argv.reject(c, arg, usage);
        project = arg;
    }

    const a = c.a;
    var ow = std.Io.File.stdout().writer(c.io, try a.alloc(u8, 4096));
    const w = &ow.interface;
    defer w.flush() catch {}; // zsnag:ok — progress report only (datasets are written with `try`); a defer cannot return the error

    const zon_path = try std.fs.path.join(a, &.{ project, "build.zig.zon" });
    const zon = std.Io.Dir.cwd().readFileAllocOptions(c.io, zon_path, a, .unlimited, .of(u8), 0) catch |e| {
        try argv.diag(c, "zephem deps: cannot read {s} ({s}) — is {s} a Zig project?\n", .{ zon_path, @errorName(e), project });
        std.process.exit(2);
    };
    const zig_version = (try toolchain.probe(c)).version;
    const out_root = try vars.depsDir(c);

    // Breadth-first over the dependency graph: a package's own manifest lists ITS dependencies,
    // all unpacked into the top project's zig-pkg/. Each package directory is visited once.
    const Pending = struct { dep: pkg.Dep, manifest_dir: []const u8 };
    var queue: std.ArrayList(Pending) = .empty;
    for (try pkg.depsOf(a, zon)) |d| try queue.append(a, .{ .dep = d, .manifest_dir = project });
    var seen = std.StringHashMap(void).init(a);

    var mapped: usize = 0;
    var problems: usize = 0;
    var head: usize = 0;
    if (queue.items.len == 0) try w.print("{s} has no dependencies.\n", .{zon_path});
    while (head < queue.items.len) : (head += 1) {
        const p = queue.items[head];
        const dir = if (p.dep.hash) |h|
            try std.fs.path.join(a, &.{ project, "zig-pkg", h })
        else
            try std.fs.path.resolve(a, &.{ p.manifest_dir, p.dep.path.? });
        if ((try seen.getOrPut(dir)).found_existing) continue;

        if (!exists(c, dir)) {
            try w.print("  {s}: not fetched — run `zig build --fetch` in {s}\n", .{ p.dep.name, project });
            problems += 1;
            continue;
        }
        // its own dependencies
        const sub_zon = try std.fs.path.join(a, &.{ dir, "build.zig.zon" });
        if (std.Io.Dir.cwd().readFileAllocOptions(c.io, sub_zon, a, .unlimited, .of(u8), 0)) |bytes| {
            for (pkg.depsOf(a, bytes) catch &.{}) |d| try queue.append(a, .{ .dep = d, .manifest_dir = dir });
        } else |_| {}

        const build_zig = try std.fs.path.join(a, &.{ dir, "build.zig" });
        const build_src = std.Io.Dir.cwd().readFileAllocOptions(c.io, build_zig, a, .unlimited, .of(u8), 0) catch {
            try w.print("  {s}: no build.zig — nothing exported to map\n", .{p.dep.name});
            continue;
        };
        const modules = pkg.modulesOf(a, build_src) catch &.{};
        if (modules.len == 0) {
            try w.print("  {s}: its build.zig exports no module with a literal name and root (b.addModule(\"name\", .{{ .root_source_file = b.path(\"…\") }}))\n", .{p.dep.name});
            continue;
        }
        const key = p.dep.hash orelse try std.fmt.allocPrint(a, "local-{s}", .{p.dep.name});
        // One version per package: a map of the same package under another hash (an older
        // fetch) would answer for the same paths (`clap.parse`) and `map doc` would pick one
        // silently. It is replaced.
        for (try otherVersions(c, out_root, p.dep.name, key)) |old| {
            try std.Io.Dir.cwd().deleteTree(c.io, try std.fs.path.join(a, &.{ out_root, old }));
            try w.print("  {s}: replaced the map of an older version ({s})\n", .{ p.dep.name, old });
        }
        for (modules) |m| {
            const out = try std.fs.path.join(a, &.{ out_root, key, m.name });
            const root = try std.fs.path.join(a, &.{ dir, m.root });
            if (try mapModule(c, m.name, root, out)) |n| {
                try util.writeFile(c.io, try std.fs.path.join(a, &.{ out, "SOURCE" }), try std.fmt.allocPrint(a,
                    \\package {s}
                    \\{s} {s}
                    \\module {s}
                    \\root {s}
                    \\zig {s}
                    \\
                , .{ p.dep.name, if (p.dep.hash != null) "hash" else "path", p.dep.hash orelse p.dep.path.?, m.name, m.root, zig_version }));
                try w.print("  {s} → module {s}: {d} declarations  ✓ self-check\n", .{ p.dep.name, m.name, n });
                mapped += 1;
            } else {
                try w.print("  {s} → module {s}: ✗ failed its self-check — not kept\n", .{ p.dep.name, m.name });
                problems += 1;
            }
        }
        try w.flush();
    }
    try w.print("deps: {d} module(s) mapped into {s}{s}\n", .{ mapped, out_root, if (problems > 0) " — see the problems above" else "" });
    if (mapped > 0) try w.writeAll("      `zephem look` / `zephem map` now include them (paths start with the module name).\n");
    if (problems > 0) {
        try w.flush();
        std.process.exit(1);
    }
}

/// Walk one module into `out` and prove it. Returns its node count, or null (and deletes `out`)
/// if the self-check fails.
fn mapModule(c: Ctx, name: []const u8, root: []const u8, out: []const u8) !?usize {
    const a = c.a;
    std.Io.Dir.cwd().deleteTree(c.io, out) catch {}; // zsnag:ok — a previous map of this module is replaced; if it is absent there is nothing to delete
    try std.Io.Dir.cwd().createDirPath(c.io, try std.fs.path.join(a, &.{ out, "extracted" }));
    try std.Io.Dir.cwd().createDirPath(c.io, try std.fs.path.join(a, &.{ out, "derived" }));
    const nodes = try std.fs.path.join(a, &.{ out, "extracted/nodes.tsv" });
    const stats = try parse.runNamed(a, c.io, root, name, nodes, try std.fs.path.join(a, &.{ out, "extracted/edges.tsv" }), try std.fs.path.join(a, &.{ out, "extracted/attrs.tsv" }), false);
    _ = try derive_index.run(a, c.io, nodes, try std.fs.path.join(a, &.{ out, "derived/index.tsv" }));
    if (!try verify.runShape(c, out)) {
        std.Io.Dir.cwd().deleteTree(c.io, out) catch {}; // zsnag:ok — best effort; a leftover without SHA256SUMS is never queried
        return null;
    }
    var entries: [dataset_names.len]manifest.Entry = undefined;
    for (dataset_names, 0..) |n, k| entries[k] = .{ .path = n, .hex = try manifest.sha256File(c.io, a, try std.fs.path.join(a, &.{ out, n })) };
    try manifest.writeManifest(c.io, &entries, try std.fs.path.join(a, &.{ out, "SHA256SUMS" }));
    return stats.nodes;
}

/// Package directories under `root` (other than `keep`) whose modules record `package <name>`.
fn otherVersions(c: Ctx, root: []const u8, name: []const u8, keep: []const u8) ![]const []const u8 {
    const a = c.a;
    var out: std.ArrayList([]const u8) = .empty;
    const want = try std.fmt.allocPrint(a, "package {s}\n", .{name});
    var top = std.Io.Dir.cwd().openDir(c.io, root, .{ .iterate = true }) catch return out.items;
    defer top.close(c.io);
    var it = top.iterate();
    while (try it.next(c.io)) |e| {
        if (e.kind != .directory or std.mem.eql(u8, e.name, keep)) continue;
        const pkg_dir = try std.fs.path.join(a, &.{ root, e.name });
        var pd = std.Io.Dir.cwd().openDir(c.io, pkg_dir, .{ .iterate = true }) catch continue;
        defer pd.close(c.io);
        var mit = pd.iterate();
        while (try mit.next(c.io)) |m| {
            if (m.kind != .directory) continue;
            const source = std.Io.Dir.cwd().readFileAlloc(c.io, try std.fs.path.join(a, &.{ pkg_dir, m.name, "SOURCE" }), a, .unlimited) catch continue;
            if (std.mem.startsWith(u8, source, want)) {
                try out.append(a, try a.dupe(u8, e.name));
                break;
            }
        }
    }
    return out.items;
}

fn exists(c: Ctx, path: []const u8) bool {
    std.Io.Dir.cwd().access(c.io, path, .{}) catch return false;
    return true;
}
