//! depth.zig — the L5 reflection sweep engine (port of `scripts/build_depth.nu`). Reflection
//! evaluates decls, so one platform-gated / @compileError container makes a reflecting program
//! fail to compile. The defense is isolation: reflect ONE container per subprocess
//! (`reflect/resolve.zig`, its TARGET lines rewritten per call, run with `zig run`). A poison
//! container fails only its own process, recorded as `path · reason`; every clean one resolves.
//!
//! The sweep is data-parallel (same op over N independent containers) → one lane per CPU via
//! `proc.parMap`; each lane owns its scratch file + subprocess, so lanes never collide, and
//! results land in input order with no post-sort. Volatile bytes are normalized out so a rebuild
//! is stable: anonymous-type disambiguators (`__struct_1234` → `__struct`) and absolute toolchain
//! paths in poison reasons (`<std_dir>/…` → `std/…`, the scratch file → `<gen>`).
const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const proc = @import("proc.zig");
const rel = @import("relation.zig");

/// One container's verdict. Slices are page_allocator-owned (built on a worker thread).
pub const One = struct {
    status: []const u8, // "path\tstatus\tn_rows"
    resolved: []const []const u8, // resolved rows (normalized), empty if poison
    poison: ?[]const u8, // "path\treason", or null
};

pub const Counts = struct { attempted: usize, resolved_containers: usize, resolved_rows: usize, poison: usize };

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
    const results = try proc.parMap(One, c.a, jobs, targets.len, sctx, reflectOne);

    // assemble in target order
    var status: std.Io.Writer.Allocating = .init(c.a);
    var resolved: std.Io.Writer.Allocating = .init(c.a);
    var poison: std.Io.Writer.Allocating = .init(c.a);
    try status.writer.writeAll("path\tstatus\tn_rows\n");
    try resolved.writer.writeAll("path\tkind\tdetail\n");
    try poison.writer.writeAll("path\treason\n");

    var counts = Counts{ .attempted = targets.len, .resolved_containers = 0, .resolved_rows = 0, .poison = 0 };
    for (results) |one| {
        try status.writer.print("{s}\n", .{one.status});
        if (one.poison) |p| {
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
    const a = std.heap.page_allocator;
    const path = cx.targets[i];
    const skip = cx.skips[i];

    const src = genSource(a, cx.template, path, skip) catch return poisonOne(a, path, "gen failed");
    const rfile = std.fmt.allocPrint(a, "{s}/r-{d}.zig", .{ cx.scratch_dir, i }) catch return poisonOne(a, path, "scratch alloc failed");
    writeFileRaw(a, cx.io, rfile, src) catch return poisonOne(a, path, "scratch write failed");

    const out = proc.runTimed(a, cx.io, &.{ cx.zig_exe, "run", rfile }, cx.timeout_s) catch return poisonOne(a, path, "spawn failed");

    if (out.exit_code == 0) {
        // WORKS — record the resolved rows (skip the header line).
        var rows: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, out.stdout, '\n');
        _ = lines.next(); // header
        while (lines.next()) |ln| {
            if (ln.len == 0) continue;
            rows.append(a, normRow(a, ln) catch ln) catch {};
        }
        const status = std.fmt.allocPrint(a, "{s}\tresolved\t{d}", .{ path, rows.items.len }) catch path;
        return .{ .status = status, .resolved = rows.toOwnedSlice(a) catch &.{}, .poison = null };
    }

    // DOESN'T — poison. Timeout (124) is the one non-compiler case; tag it honestly.
    if (out.exit_code == 124) {
        return poisonOne(a, path, std.fmt.allocPrint(a, "timeout after {d}s", .{cx.timeout_s}) catch "timeout");
    }
    var reason = normReason(a, firstErrorLine(out.stderr), cx.std_dir, rfile);
    if (reason.len == 0) reason = std.fmt.allocPrint(a, "exit {d}", .{out.exit_code}) catch "exit";
    return poisonOne(a, path, reason);
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
    const target_path_line = try std.fmt.allocPrint(a, "const TARGET_PATH = \"{s}\";", .{path});
    const target_line = try std.fmt.allocPrint(a, "const TARGET = @import(\"std\"){s};", .{tail});

    var skip_lit: std.Io.Writer.Allocating = .init(a);
    if (skip.len == 0) {
        try skip_lit.writer.writeAll("[_][]const u8{}");
    } else {
        try skip_lit.writer.writeAll("[_][]const u8{ ");
        for (skip, 0..) |s, k| {
            if (k != 0) try skip_lit.writer.writeAll(", ");
            try skip_lit.writer.print("\"{s}\"", .{s});
        }
        try skip_lit.writer.writeAll(" }");
    }
    const skip_line = try std.fmt.allocPrint(a, "const SKIP = {s};", .{skip_lit.writer.buffered()});

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
        if (std.mem.indexOf(u8, ln, "error:") != null) return std.mem.trim(u8, ln, " \t\r");
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
    return replaceAll(a, s1, std_prefix, "std/") catch s1;
}

fn replaceAll(a: std.mem.Allocator, hay: []const u8, needle: []const u8, with: []const u8) ![]const u8 {
    if (needle.len == 0) return hay;
    const count = std.mem.count(u8, hay, needle);
    if (count == 0) return hay;
    const out = try a.alloc(u8, hay.len - needle.len * count + with.len * count);
    _ = std.mem.replace(u8, hay, needle, with, out);
    return out;
}

fn writeFileStr(c: Ctx, path: []const u8, bytes: []const u8) !void {
    try writeFileRaw(c.a, c.io, path, bytes);
}

fn writeFileRaw(a: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    _ = a;
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [1 << 16]u8 = undefined;
    var fw = f.writer(io, &buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}
