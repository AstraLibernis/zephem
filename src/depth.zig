// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! depth.zig — the L5 reflection sweep engine (port of `scripts/build_depth.nu`). Reflection
//! evaluates decls, so one platform-gated / @compileError container makes a reflecting program
//! fail to compile. The defense is isolation, established cheaply: containers are probed in
//! batches (analysis only) to find the ones that fail, and only the clean ones are reflected
//! together; anything a batch cannot settle falls back to ONE container per subprocess
//! (`reflect/resolve.zig`, its TARGET lines rewritten, run with `zig run`) — the reference path,
//! also available whole as `--solo`. See "the batched sweep" below.
//!
//! Batches are data-parallel → one lane per CPU via `proc.parMap`; each lane owns its scratch
//! files + subprocesses, so lanes never collide, and results land in target order. Volatile bytes
//! are normalized out so a rebuild is stable: anonymous-type disambiguators (`__struct_1234` →
//! `__struct`), absolute toolchain paths in poison reasons (`<std_dir>/…` → `std/…`, the
//! scratch file → `<gen>`), and line/column inside the generated file.
const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const proc = @import("proc.zig");
const rel = @import("relation.zig");
const util = @import("util.zig");

/// One container's verdict. Slices are page_allocator-owned (built on a worker thread).
pub const One = struct {
    status: []const u8, // "path\tstatus\tn_rows"
    resolved: []const []const u8, // resolved rows (normalized), empty if poison/skipped
    poison: ?[]const u8, // "path\treason", or null
    skipped: bool = false, // structurally unreflectable (a `()` factory container) — not attempted
};

/// `.batched` (the default) and `.solo` produce byte-identical datasets; `.solo` is the
/// one-container-per-process reference the batched sweep was proven against, kept for re-proving.
pub const Mode = enum { batched, solo };

pub const Counts = struct {
    attempted: usize,
    resolved_containers: usize,
    resolved_rows: usize,
    poison: usize,
    skipped: usize,
    /// batched only: wall time of each phase, and how many compiles each ran (batches, the
    /// halves of split batches, and solo runs)
    probe_ms: u64 = 0,
    run_ms: u64 = 0,
    probe_compiles: usize = 0,
    run_compiles: usize = 0,
    solo_compiles: usize = 0,
};

var compiles_probe = std.atomic.Value(usize).init(0);
var compiles_run = std.atomic.Value(usize).init(0);
var compiles_solo = std.atomic.Value(usize).init(0);

const SweepCtx = struct {
    io: std.Io,
    zig_exe: []const u8,
    template: []const u8,
    std_dir: []const u8,
    scratch_dir: []const u8,
    timeout_s: u32,
    targets: []const []const u8,
    skips: []const []const []const u8, // per-target direct-child names to SKIP
};

/// Reflect the whole target set into `outdir` (writes extracted/{status,resolved,poison}.tsv),
/// running up to `jobs` lanes. Deterministic: results are assembled in target order.
pub fn sweep(
    c: Ctx,
    targets: []const []const u8,
    skips: []const []const []const u8,
    zig_exe: []const u8,
    template: []const u8,
    std_dir: []const u8,
    scratch_dir: []const u8,
    outdir: []const u8,
    timeout_s: u32,
    jobs: usize,
    mode: Mode,
) !Counts {
    try std.Io.Dir.cwd().createDirPath(c.io, scratch_dir);
    try std.Io.Dir.cwd().createDirPath(c.io, try std.fs.path.join(c.a, &.{ outdir, "extracted" }));

    const sctx = SweepCtx{
        .io = c.io,
        .zig_exe = zig_exe,
        .template = template,
        .std_dir = std_dir,
        .scratch_dir = scratch_dir,
        .timeout_s = timeout_s,
        .targets = targets,
        .skips = skips,
    };
    var phases: Phases = .{};
    const results = switch (mode) {
        // the reference path: one `zig run` per container
        .solo => try proc.parMap(One, c.a, jobs, targets.len, sctx, reflectOne),
        .batched => try sweepBatched(c, sctx, jobs, &phases),
    };

    // assemble in target order
    var status: std.Io.Writer.Allocating = .init(c.a);
    var resolved: std.Io.Writer.Allocating = .init(c.a);
    var poison: std.Io.Writer.Allocating = .init(c.a);
    try status.writer.writeAll("path\tstatus\tn_rows\n");
    try resolved.writer.writeAll("path\tkind\tdetail\n");
    try poison.writer.writeAll("path\treason\n");

    var counts = Counts{
        .attempted = targets.len,
        .resolved_containers = 0,
        .resolved_rows = 0,
        .poison = 0,
        .skipped = 0,
        .probe_ms = phases.probe_ms,
        .run_ms = phases.run_ms,
        .probe_compiles = compiles_probe.load(.monotonic),
        .run_compiles = compiles_run.load(.monotonic),
        .solo_compiles = compiles_solo.load(.monotonic),
    };
    for (results) |one| {
        try status.writer.print("{s}\n", .{one.status});
        if (one.skipped) {
            counts.skipped += 1;
        } else if (one.poison) |p| {
            try poison.writer.print("{s}\n", .{p});
            counts.poison += 1;
        } else {
            counts.resolved_containers += 1;
            for (one.resolved) |row| {
                try resolved.writer.print("{s}\n", .{row});
                counts.resolved_rows += 1;
            }
        }
    }

    try writeFileStr(c, try std.fs.path.join(c.a, &.{ outdir, "extracted/status.tsv" }), status.writer.buffered());
    try writeFileStr(c, try std.fs.path.join(c.a, &.{ outdir, "extracted/resolved.tsv" }), resolved.writer.buffered());
    try writeFileStr(c, try std.fs.path.join(c.a, &.{ outdir, "extracted/poison.tsv" }), poison.writer.buffered());
    return counts;
}

/// Per-lane unit of work. Thread-safe: reads only shared read-only state and allocates from the
/// page allocator (never a shared arena). Returns page_allocator-owned strings.
fn reflectOne(cx: SweepCtx, i: usize) One {
    const a = std.heap.page_allocator; // zsnag:ok — R009: thread-safe per-lane allocator, see the doc comment
    const path = cx.targets[i];
    const skip = cx.skips[i];

    // A `()` factory container is an UNINSTANTIATED generic — `@import("std").Foo()` can't be
    // reflected standalone (the compiler needs the type args), so it would only ever poison.
    // Skip it structurally (no compile, no wasted process) — its real members are Phase D
    // (instantiate the generic, then reflect). Provably safe: no `()` container resolves.
    if (std.mem.find(u8, path, "()") != null) return skippedOne(a, path);

    const rfile = std.fmt.allocPrint(a, "{s}/r-{d}.zig", .{ cx.scratch_dir, i }) catch return poisonOne(a, path, "scratch alloc failed");
    return soloReflect(a, cx.io, cx.zig_exe, cx.template, cx.std_dir, cx.timeout_s, path, skip, rfile);
}

/// Reflect ONE container via the solo `resolve.zig` template — the canonical path. Shared by the
/// solo sweep and by the batch sweep's size-1 bisect base case / special-path fallback, so a
/// container reflected alone here produces byte-identical output regardless of which sweep drove it.
fn soloReflect(a: std.mem.Allocator, io: std.Io, zig_exe: []const u8, template: []const u8, std_dir: []const u8, timeout_s: u32, path: []const u8, skip: []const []const u8, rfile: []const u8) One {
    const src = genSource(a, template, path, skip) catch return poisonOne(a, path, "gen failed");
    util.writeFile(io, rfile, src) catch return poisonOne(a, path, "scratch write failed");
    const out = proc.runTimed(a, io, &.{ zig_exe, "run", rfile }, timeout_s) catch return poisonOne(a, path, "spawn failed");

    if (out.exit_code == 0) {
        const status = std.fmt.allocPrint(a, "{s}\tresolved\t{d}", .{ path, 0 }) catch path;
        // Out of memory here must not produce a container marked `resolved` with rows missing —
        // it is recorded like any other failure: not resolved, with the reason.
        const rows = parseRows(a, out.stdout, true) catch return poisonOne(a, path, "out of memory reading resolver output");
        return .{ .status = std.fmt.allocPrint(a, "{s}\tresolved\t{d}", .{ path, rows.len }) catch status, .resolved = rows, .poison = null };
    }
    if (out.exit_code == 124) {
        return poisonOne(a, path, std.fmt.allocPrint(a, "timeout after {d}s", .{timeout_s}) catch "timeout");
    }
    var reason = normReason(a, firstErrorLine(out.stderr), std_dir, rfile);
    if (reason.len == 0) reason = std.fmt.allocPrint(a, "exit {d}", .{out.exit_code}) catch "exit";
    return poisonOne(a, path, reason);
}

/// Parse resolver stdout into normalized rows. `has_header` skips the leading `path\tkind\tdetail`.
/// Fails rather than dropping a row: this used to `catch {}` the append and return an empty
/// slice on a failed `toOwnedSlice`, so an allocation failure silently shortened resolved.tsv.
fn parseRows(a: std.mem.Allocator, stdout: []const u8, has_header: bool) ![]const []const u8 {
    var rows: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    if (has_header) _ = lines.next();
    while (lines.next()) |ln| {
        if (ln.len == 0) continue;
        try rows.append(a, try normRow(a, ln));
    }
    return rows.toOwnedSlice(a);
}

/// A `()` factory container is structurally unreflectable standalone — recorded as skipped.
fn skippedOne(a: std.mem.Allocator, path: []const u8) One {
    return .{
        .status = std.fmt.allocPrint(a, "{s}\tskipped\t0", .{path}) catch path,
        .resolved = &.{},
        .poison = null,
        .skipped = true,
    };
}

fn poisonOne(a: std.mem.Allocator, path: []const u8, reason: []const u8) One {
    const status = std.fmt.allocPrint(a, "{s}\tpoison\t0", .{path}) catch path;
    const p = std.fmt.allocPrint(a, "{s}\t{s}", .{ path, reason }) catch path;
    return .{ .status = status, .resolved = &.{}, .poison = p };
}

/// Rewrite the template's three TARGET lines for `path`. The access chain is the path tail
/// appended to `@import("std")` (dropping the leading "std").
fn genSource(a: std.mem.Allocator, template: []const u8, path: []const u8, skip: []const []const u8) ![]const u8 {
    const tail = if (std.mem.eql(u8, path, "std")) "" else path[3..];
    const target_path_line = try std.fmt.allocPrint(a, "const TARGET_PATH = {s};", .{try zigString(a, path)});
    const target_line = try std.fmt.allocPrint(a, "const TARGET = @import(\"std\"){s};", .{tail});

    const skip_line = try std.fmt.allocPrint(a, "const SKIP = {s};", .{try skipLiteral(a, skip)});

    var out: std.Io.Writer.Allocating = .init(a);
    var lines = std.mem.splitScalar(u8, template, '\n');
    var first = true;
    while (lines.next()) |ln| {
        if (!first) try out.writer.writeByte('\n');
        first = false;
        if (std.mem.startsWith(u8, ln, "const TARGET_PATH = ")) {
            try out.writer.writeAll(target_path_line);
        } else if (std.mem.startsWith(u8, ln, "const TARGET = ")) {
            try out.writer.writeAll(target_line);
        } else if (std.mem.startsWith(u8, ln, "const SKIP = ")) {
            try out.writer.writeAll(skip_line);
        } else {
            try out.writer.writeAll(ln);
        }
    }
    return out.writer.buffered();
}

/// Strip the volatile anonymous-type disambiguator digits: `__struct_1234` → `__struct` (kind
/// marker kept). Covers struct/union/enum/opaque.
fn normRow(a: std.mem.Allocator, line: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var i: usize = 0;
    while (i < line.len) {
        if (matchAnonPrefix(line[i..])) |kind_len| {
            // "__<kind>_" then digits — emit "__<kind>", skip the "_<digits>"
            const kw_end = i + kind_len; // index of the '_' before digits
            try out.writer.writeAll(line[i..kw_end]);
            i = kw_end + 1; // skip '_'
            while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
        } else {
            try out.writer.writeByte(line[i]);
            i += 1;
        }
    }
    return out.writer.buffered();
}

/// If `s` starts with `__<kind>_<digit>`, return the byte length of `__<kind>` (up to but not
/// including the trailing `_`). Else null.
fn matchAnonPrefix(s: []const u8) ?usize {
    inline for (.{ "struct", "union", "enum", "opaque" }) |kw| {
        const pat = "__" ++ kw ++ "_";
        if (std.mem.startsWith(u8, s, pat) and s.len > pat.len and s[pat.len] >= '0' and s[pat.len] <= '9') {
            return 2 + kw.len; // "__" + kw, excludes the trailing '_'
        }
    }
    return null;
}

/// The compiler's first `error:` line (trimmed), else the first non-empty line, else "" (the
/// caller substitutes a stable `exit N`).
fn firstErrorLine(stderr: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |ln| {
        if (std.mem.find(u8, ln, "error:") != null) return std.mem.trim(u8, ln, " \t\r");
    }
    var l2 = std.mem.splitScalar(u8, stderr, '\n');
    while (l2.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (t.len != 0) return t;
    }
    return "";
}

/// Render a poison reason location-independent: the scratch file → `<gen>`, the std dir → `std/`.
fn normReason(a: std.mem.Allocator, reason: []const u8, std_dir: []const u8, rfile: []const u8) []const u8 {
    const std_prefix = std.fmt.allocPrint(a, "{s}/", .{std_dir}) catch return reason;
    const s1 = replaceAll(a, reason, rfile, "<gen>") catch reason;
    return dropGenLocation(a, replaceAll(a, s1, std_prefix, "std/") catch s1);
}

/// `<gen>:32:55: error: …` → `<gen>: error: …`. The line and column point into the generated
/// wrapper, not into std, so they carry no information about the container — but they move
/// whenever the template changes. Adding a three-line licence header to `reflect/resolve.zig`
/// shifted all 891 of them and broke `depth --check` with no change to what was poisoned.
/// Locations inside std (`std/…/x.zig:12:3`) are real and are kept.
fn dropGenLocation(a: std.mem.Allocator, reason: []const u8) []const u8 {
    const head = "<gen>:";
    if (!std.mem.startsWith(u8, reason, head)) return reason;
    var i = head.len;
    var colons: usize = 0;
    while (i < reason.len and colons < 2) : (i += 1) {
        const ch = reason[i];
        if (ch == ':') {
            colons += 1;
        } else if (!std.ascii.isDigit(ch)) return reason; // not `L:C:` — leave it alone
    }
    if (colons < 2) return reason;
    return std.fmt.allocPrint(a, "{s}{s}", .{ head, reason[i..] }) catch reason;
}

const replaceAll = util.replaceAll;

fn writeFileStr(c: Ctx, path: []const u8, bytes: []const u8) !void {
    return util.writeFile(c.io, path, bytes);
}

// ── the batched sweep ───────────────────────────────────────────────────────────────────────
//
// Why: every `zig run` pays ~140 ms of analysis for std's startup code (start.zig,
// std.process.Init, Io) before it reaches the container, and then builds, links and runs a
// debug executable. Measured cold (benchfence, one pinned core, release build): 169 ms per
// container solo, 5.0 ms per container when 50 share one binary, with byte-identical rows.
//
// A container that fails to compile would fail a whole batch, which is what sank the first
// batching attempt (every batch held one, and bisecting cost more than it saved). So the
// failing containers are found first, cheaply, and never enter a run batch:
//
//   1. PROBE  ~50 containers per object file, analysis only (`build-obj -fno-emit-bin`), one
//      `export fn` each. Zig keeps analysing after an error, so each failing container reports
//      its own. An error located in the generated file is attributed by line range (zephem
//      wrote the file, so it knows where every probe starts and ends). An error located in std
//      could be shared by several containers and reported once, so a batch that has one is
//      split in half and re-probed; a single container left failing runs the solo `zig run`
//      for its exact reason.
//   2. RUN    the containers that passed, ~50 per binary, each introduced by a
//      `#zephem-target\t<i>` line so the rows split back out. A batch that fails anyway (a
//      timeout, a codegen-only error) is split in half, down to the solo path.
//
// The solo path is the base case of both, so any container the batching cannot settle gets
// exactly the reference treatment.

const batch_size = 50;

const Phases = struct { probe_ms: u64 = 0, run_ms: u64 = 0 };

fn msSince(io: std.Io, t: std.Io.Timestamp) u64 {
    return @intCast(@divTrunc(t.durationTo(std.Io.Clock.awake.now(io)).nanoseconds, std.time.ns_per_ms)); // zsnag:ok — R007: elapsed ms of one sweep, non-negative and far below u64 max
}

fn sweepBatched(c: Ctx, sctx: SweepCtx, jobs: usize, phases: *Phases) ![]One {
    const n = sctx.targets.len;
    const results = try c.a.alloc(One, n);
    const settled = try c.a.alloc(bool, n);
    @memset(settled, false);

    // `()` factory containers are skipped structurally, exactly as in the solo path
    var todo: std.ArrayList(usize) = .empty;
    for (sctx.targets, 0..) |path, i| {
        if (std.mem.find(u8, path, "()") != null) {
            results[i] = skippedOne(c.a, path);
            settled[i] = true;
        } else try todo.append(c.a, i);
    }

    // 1. probe
    var t = std.Io.Clock.awake.now(c.io);
    const probe_groups = try chunk(c.a, todo.items, batch_size);
    const probed = try proc.parMap([]Verdict, c.a, jobs, probe_groups.len, BatchCtx{ .s = sctx, .groups = probe_groups }, probeGroup);
    var clean: std.ArrayList(usize) = .empty;
    for (probed) |vs| for (vs) |v| switch (v.what) {
        .clean => try clean.append(c.a, v.i),
        .settled => {
            results[v.i] = v.one;
            settled[v.i] = true;
        },
    };
    std.mem.sort(usize, clean.items, {}, std.sort.asc(usize)); // keep target order within run batches

    phases.probe_ms = msSince(c.io, t);

    // 2. run
    t = std.Io.Clock.awake.now(c.io);
    const run_groups = try chunk(c.a, clean.items, batch_size);
    const ran = try proc.parMap([]Verdict, c.a, jobs, run_groups.len, BatchCtx{ .s = sctx, .groups = run_groups }, runGroup);
    for (ran) |vs| for (vs) |v| {
        results[v.i] = v.one;
        settled[v.i] = true;
    };

    phases.run_ms = msSince(c.io, t);

    for (settled, 0..) |ok, i| if (!ok) std.debug.panic("depth: container {d} ({s}) was never settled", .{ i, sctx.targets[i] });
    return results;
}

const BatchCtx = struct { s: SweepCtx, groups: []const []const usize };

/// A container's outcome from one batch step: settled (resolved/poison, final), or clean
/// (passed the probe; its rows come from the run step).
const Verdict = struct { i: usize, what: enum { clean, settled }, one: One = undefined };

fn chunk(a: std.mem.Allocator, xs: []const usize, size: usize) ![]const []const usize {
    var out: std.ArrayList([]const usize) = .empty;
    var k: usize = 0;
    while (k < xs.len) : (k += size) try out.append(a, xs[k..@min(k + size, xs.len)]);
    return out.items;
}

fn probeGroup(cx: BatchCtx, g: usize) []Verdict {
    const a = std.heap.page_allocator; // zsnag:ok — R009: thread-safe per-lane allocator (parMap worker)
    var out: std.ArrayList(Verdict) = .empty;
    probeSet(a, cx.s, cx.groups[g], g, 0, &out) catch |e| std.debug.panic("depth: probe batch {d} failed: {s}", .{ g, @errorName(e) });
    return out.items;
}

fn runGroup(cx: BatchCtx, g: usize) []Verdict {
    const a = std.heap.page_allocator; // zsnag:ok — R009: thread-safe per-lane allocator (parMap worker)
    var out: std.ArrayList(Verdict) = .empty;
    runSet(a, cx.s, cx.groups[g], g, 0, &out) catch |e| std.debug.panic("depth: run batch {d} failed: {s}", .{ g, @errorName(e) });
    return out.items;
}

/// Settle one container through the reference path.
fn solo(a: std.mem.Allocator, s: SweepCtx, i: usize, out: *std.ArrayList(Verdict)) !void {
    _ = compiles_solo.fetchAdd(1, .monotonic);
    try out.append(a, .{ .i = i, .what = .settled, .one = reflectOne(s, i) });
}

/// The template minus its per-container lines and its `main`: the shared reflection helpers.
fn helpers(template: []const u8) []const u8 {
    const main_at = std.mem.find(u8, template, "pub fn main(") orelse template.len;
    return template[0..main_at];
}

/// `@import("std")` plus the path tail, as genSource writes it.
fn targetExpr(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const tail = if (std.mem.eql(u8, path, "std")) "" else path[3..];
    return std.fmt.allocPrint(a, "@import(\"std\"){s}", .{tail});
}

/// The SKIP array literal. Entries are BARE decl names — the template compares them with
/// `@typeInfo`'s decl names — so a quoted child (`@"PE32+"`) is unquoted first, and every entry
/// is written as an escaped Zig string. Writing `"@"PE32+""` raw used to be a syntax error that
/// poisoned the parent container and matched nothing even when it parsed.
fn skipLiteral(a: std.mem.Allocator, skip: []const []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.writeAll("[_][]const u8{");
    for (skip, 0..) |x, k| try w.writer.print("{s}{s}", .{ if (k == 0) " " else ", ", try zigString(a, bareName(x)) });
    try w.writer.writeAll(if (skip.len > 0) " }" else "}");
    return w.written();
}

/// `s` as a double-quoted, escaped Zig string literal. Paths can contain quoted identifiers
/// (`std.coff.OptionalHeader.@"PE32+"`); pasting them raw between quotes broke the generated
/// file, and the four containers involved were recorded as compiler poison.
fn zigString(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "\"{f}\"", .{std.zig.fmtString(s)});
}

/// `@"PE32+"` → `PE32+`; any other name unchanged.
fn bareName(s: []const u8) []const u8 {
    if (s.len >= 3 and std.mem.startsWith(u8, s, "@\"") and s[s.len - 1] == '"') return s[2 .. s.len - 1];
    return s;
}

/// Write `helpers` with the per-container lines removed (a batch has no single TARGET).
fn writeHelpers(w: *std.Io.Writer, template: []const u8) !usize {
    var lines_out: usize = 0;
    var lines = std.mem.splitScalar(u8, helpers(template), '\n');
    while (lines.next()) |ln| {
        if (std.mem.startsWith(u8, ln, "const TARGET_PATH = ") or std.mem.startsWith(u8, ln, "const TARGET = ") or std.mem.startsWith(u8, ln, "const SKIP = ")) {
            try w.writeAll("\n"); // keep the line count, drop the declaration
        } else {
            try w.writeAll(ln);
            try w.writeAll("\n");
        }
        lines_out += 1;
    }
    return lines_out;
}

fn scratchName(a: std.mem.Allocator, s: SweepCtx, kind: []const u8, g: usize, depth: usize, first: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}-{d}-{d}-{d}.zig", .{ s.scratch_dir, kind, g, depth, first });
}

fn probeSet(a: std.mem.Allocator, s: SweepCtx, set: []const usize, g: usize, depth: usize, out: *std.ArrayList(Verdict)) !void {
    if (set.len == 0) return;
    if (set.len == 1) {
        // one container: its outcome is decided exactly by the reference path
        return solo(a, s, set[0], out);
    }
    var w: std.Io.Writer.Allocating = .init(a);
    var line = try writeHelpers(&w.writer, s.template);
    const ranges = try a.alloc([2]usize, set.len); // 1-based [first, last] line of each probe
    for (set, 0..) |i, k| {
        const path = s.targets[i];
        const body = try std.fmt.allocPrint(a,
            \\export fn zephem_probe_{d}() void {{
            \\    var wbuf: [1 << 16]u8 = undefined;
            \\    var dw: std.Io.Writer = .fixed(&wbuf);
            \\    const TARGET = {s};
            \\    const SKIP = {s};
            \\    if (comptime @TypeOf(TARGET) == type) emit(&dw, &SKIP, {s}, TARGET, DESCEND, true) catch {{}} else emitScalar(&dw, {s}, TARGET) catch {{}};
            \\}}
            \\
        , .{ k, try targetExpr(a, path), try skipLiteral(a, s.skips[i]), try zigString(a, path), try zigString(a, path) });
        const nl = std.mem.count(u8, body, "\n");
        ranges[k] = .{ line + 1, line + nl };
        line += nl;
        try w.writer.writeAll(body);
    }
    const file = try scratchName(a, s, "p", g, depth, set[0]);
    try util.writeFile(s.io, file, w.written());
    _ = compiles_probe.fetchAdd(1, .monotonic);
    const res = proc.runTimed(a, s.io, &.{ s.zig_exe, "build-obj", "-fno-emit-bin", file }, s.timeout_s) catch return split(a, s, set, g, depth, out, probeSet);
    if (res.exit_code == 0) {
        for (set) |i| try out.append(a, .{ .i = i, .what = .clean });
        return;
    }
    if (res.exit_code == 124) return split(a, s, set, g, depth, out, probeSet);

    // Attribute errors: one in the generated file belongs to the probe whose line range holds it.
    // Any error elsewhere (inside std) may be shared and reported once, so it cannot be
    // attributed safely: split and re-probe.
    const first_err = try a.alloc(?[]const u8, set.len);
    @memset(first_err, null);
    var lines = std.mem.splitScalar(u8, res.stderr, '\n');
    var any = false;
    while (lines.next()) |raw| {
        if (raw.len == 0 or raw[0] == ' ' or raw[0] == '\t') continue; // echoed source, carets, traces
        const at = std.mem.find(u8, raw, ": error: ") orelse continue;
        any = true;
        const loc = raw[0..at];
        if (!std.mem.startsWith(u8, loc, file) or loc.len <= file.len or loc[file.len] != ':') {
            return split(a, s, set, g, depth, out, probeSet);
        }
        const ln_end = std.mem.findScalarPos(u8, loc, file.len + 1, ':') orelse loc.len;
        const ln = std.fmt.parseInt(usize, loc[file.len + 1 .. ln_end], 10) catch return split(a, s, set, g, depth, out, probeSet);
        const k = for (ranges, 0..) |r, k| {
            if (ln >= r[0] and ln <= r[1]) break k;
        } else return split(a, s, set, g, depth, out, probeSet); // an error in the shared helpers
        if (first_err[k] == null) first_err[k] = std.mem.trim(u8, raw, " \t\r");
    }
    if (!any) return split(a, s, set, g, depth, out, probeSet); // failed without a readable error
    for (set, 0..) |i, k| {
        if (first_err[k]) |e| {
            try out.append(a, .{ .i = i, .what = .settled, .one = poisonOne(a, s.targets[i], normReason(a, e, s.std_dir, file)) });
        } else try out.append(a, .{ .i = i, .what = .clean });
    }
}

fn runSet(a: std.mem.Allocator, s: SweepCtx, set: []const usize, g: usize, depth: usize, out: *std.ArrayList(Verdict)) !void {
    if (set.len == 0) return;
    if (set.len == 1) return solo(a, s, set[0], out);
    var w: std.Io.Writer.Allocating = .init(a);
    _ = try writeHelpers(&w.writer, s.template);
    try w.writer.writeAll(
        \\pub fn main(init: std.process.Init) !void {
        \\    var wbuf: [1 << 16]u8 = undefined;
        \\    var fw = std.Io.File.stdout().writer(init.io, &wbuf);
        \\    const w = &fw.interface;
        \\
    );
    for (set, 0..) |i, k| {
        const path = s.targets[i];
        try w.writer.print(
            \\    {{
            \\        try w.writeAll("#zephem-target\t{d}\n");
            \\        const TARGET = {s};
            \\        const SKIP = {s};
            \\        if (comptime @TypeOf(TARGET) == type) try emit(w, &SKIP, {s}, TARGET, DESCEND, true) else try emitScalar(w, {s}, TARGET);
            \\    }}
            \\
        , .{ k, try targetExpr(a, path), try skipLiteral(a, s.skips[i]), try zigString(a, path), try zigString(a, path) });
    }
    try w.writer.writeAll("    try w.flush();\n}\n");
    const file = try scratchName(a, s, "r", g, depth, set[0]);
    try util.writeFile(s.io, file, w.written());
    _ = compiles_run.fetchAdd(1, .monotonic);
    const res = proc.runTimed(a, s.io, &.{ s.zig_exe, "run", file }, s.timeout_s) catch return split(a, s, set, g, depth, out, runSet);
    if (res.exit_code != 0) return split(a, s, set, g, depth, out, runSet);

    // split the rows back out by marker
    const rows = try a.alloc(std.ArrayList([]const u8), set.len);
    for (rows) |*r| r.* = .empty;
    var cur: ?usize = null;
    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |ln| {
        if (ln.len == 0) continue;
        if (std.mem.startsWith(u8, ln, "#zephem-target\t")) {
            cur = std.fmt.parseInt(usize, ln["#zephem-target\t".len..], 10) catch return split(a, s, set, g, depth, out, runSet);
            continue;
        }
        const k = cur orelse return split(a, s, set, g, depth, out, runSet);
        try rows[k].append(a, try normRow(a, ln));
    }
    for (set, 0..) |i, k| {
        const path = s.targets[i];
        const status = try std.fmt.allocPrint(a, "{s}\tresolved\t{d}", .{ path, rows[k].items.len });
        try out.append(a, .{ .i = i, .what = .settled, .one = .{ .status = status, .resolved = rows[k].items, .poison = null } });
    }
}

/// Halve a batch and handle each half the same way; a single container is settled by the
/// reference path (in `probeSet`/`runSet`).
fn split(
    a: std.mem.Allocator,
    s: SweepCtx,
    set: []const usize,
    g: usize,
    depth: usize,
    out: *std.ArrayList(Verdict),
    comptime again: fn (std.mem.Allocator, SweepCtx, []const usize, usize, usize, *std.ArrayList(Verdict)) anyerror!void,
) anyerror!void {
    const mid = set.len / 2;
    try again(a, s, set[0..mid], g, depth + 1, out);
    try again(a, s, set[mid..], g, depth + 1, out);
}
