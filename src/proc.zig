// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! proc.zig — subprocess + parallelism helpers: the Zig replacement for `^nproc`, `par-each`,
//! and `^timeout Ns zig run` (`scripts/build_depth.nu`). Phase 0 provides `ncpu` and a plain
//! `capture` (for `zig env`); the timed sweep primitives (`runTimed`, `parMap`) are added in the
//! depth phase, where they can be tested against real `zig run` invocations.
const std = @import("std");

/// Available logical CPUs (falls back to 1). The adaptive lane count for the data-parallel sweep.
pub fn ncpu() usize {
    return std.Thread.getCpuCount() catch 1;
}

pub const Output = struct {
    /// 0 on clean exit; the child's exit status otherwise. 128+signal for a killed child.
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
};

fn codeOf(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        .signal => |s| 128 +% @as(u8, @truncate(@intFromEnum(s))),
        else => 255,
    };
}

/// Run `argv`, wait, and capture stdout/stderr. No timeout — for short, trusted commands like
/// `zig env`. Caller owns the returned buffers (arena, in practice).
pub fn capture(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Output {
    const r = try std.process.run(a, io, .{ .argv = argv });
    return .{ .exit_code = codeOf(r.term), .stdout = r.stdout, .stderr = r.stderr };
}

/// Like `capture`, but bounded by `timeout_s` seconds of wall clock (an absolute deadline, so a
/// slow-but-steady child can't outlast it). On timeout the child is killed and `exit_code` is
/// 124 — the coreutils `timeout` convention, so the depth sweep can tag it distinctly from a real
/// compile error. `a` MUST be thread-safe (the sweep runs many of these concurrently).
pub fn runTimed(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, timeout_s: u32) !Output {
    const dur = std.Io.Clock.Duration{ .raw = std.Io.Duration.fromSeconds(@intCast(timeout_s)), .clock = .awake }; // zsnag:ok — R007: u32 seconds always fit the signed parameter
    const deadline = (std.Io.Timeout{ .duration = dur }).toDeadline(io);
    const r = std.process.run(a, io, .{ .argv = argv, .timeout = deadline }) catch |err| switch (err) {
        error.Timeout => return .{ .exit_code = 124, .stdout = "", .stderr = "" },
        else => return err,
    };
    return .{ .exit_code = codeOf(r.term), .stdout = r.stdout, .stderr = r.stderr };
}

/// Data-parallel map: apply `work(ctx, i)` for i in [0, n) across up to `jobs` worker threads,
/// writing each result into `results[i]` — so the output preserves input order with no post-sort
/// and no result mutex (each slot is written by exactly one worker). Work is handed out via an
/// atomic counter (dynamic load-balancing), matching `par-each`'s SIMD-over-containers shape.
///
/// `work` must be thread-safe: it may only touch shared state read-only and must allocate from a
/// thread-safe allocator (e.g. `std.heap.page_allocator`), never a shared arena. `a` is used once,
/// before any thread starts, to allocate the results/threads arrays.
pub fn parMap(
    comptime R: type,
    a: std.mem.Allocator,
    jobs: usize,
    n: usize,
    ctx: anytype,
    comptime work: fn (@TypeOf(ctx), usize) R,
) ![]R {
    const results = try a.alloc(R, n);
    if (n == 0) return results;
    var counter = std.atomic.Value(usize).init(0);
    const Worker = struct {
        fn go(cnt: *std.atomic.Value(usize), res: []R, cx: @TypeOf(ctx), total: usize) void {
            while (true) {
                const i = cnt.fetchAdd(1, .monotonic);
                if (i >= total) break;
                res[i] = work(cx, i);
            }
        }
    };
    const nthreads = @min(@max(jobs, 1), n);
    if (nthreads == 1) {
        Worker.go(&counter, results, ctx, n);
        return results;
    }
    const threads = try a.alloc(std.Thread, nthreads);
    var spawned: usize = 0;
    while (spawned < nthreads) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, Worker.go, .{ &counter, results, ctx, n }) catch break;
    }
    // If some spawns failed, this thread also drains the queue so nothing is left unprocessed.
    if (spawned < nthreads) Worker.go(&counter, results, ctx, n);
    for (threads[0..spawned]) |t| t.join();
    return results;
}
