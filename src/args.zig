//! Argument validation shared by every subcommand.
//!
//! Each subcommand used to parse its flags with an `if / else if` chain and NO final `else`, so
//! an unrecognised argument was silently discarded and execution continued into the action.
//! `zephem std --help` therefore performed a full map regeneration and `zephem depth --help`
//! started the multi-minute reflection sweep — five of the eight subcommands are destructive if
//! they proceed. A help flag must never be the most expensive operation the tool can do.
const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;

pub fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

/// True if any argument asks for help, having printed `usage` to stdout.
///
/// Returns a bool rather than exiting. Calling `std.process.exit(0)` from here was actively
/// dangerous: in a test binary it exits the TEST RUNNER with status 0, so `zig build test`
/// reads success while every remaining test silently vanishes. A false pass is the worst
/// failure mode a test helper can have. Exiting is `main`'s job.
pub fn helpRequested(c: Ctx, args: []const []const u8, usage: []const u8) !bool {
    for (args) |a| {
        if (!isHelp(a)) continue;
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(c.io, &buf);
        try w.interface.writeAll(usage);
        try w.interface.flush();
        return true;
    }
    return false;
}

/// Consume the value that must follow `flag`, or reject.
///
/// Every `--flag VALUE` handler used to be `i += 1; if (i < args.len) …` with NO else — so an
/// omitted value meant the flag was consumed, forgotten, and the ACTION RAN WITH DEFAULTS.
/// `zephem std --depth` regenerated the whole map; `zephem depth --only` — the flag whose
/// entire purpose is to avoid the multi-minute sweep — started the sweep. That is the same
/// hazard this module was written to close, wearing a different hat.
pub fn value(c: Ctx, args: []const []const u8, i: *usize, flag: []const u8, usage: []const u8) []const u8 {
    i.* += 1;
    if (i.* >= args.len) missingValue(c, flag, usage);
    return args[i.*];
}

fn missingValue(c: Ctx, flag: []const u8, usage: []const u8) noreturn {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(c.io, &buf);
    w.interface.print("zephem: {s} requires a value\n\n", .{flag}) catch {};
    w.interface.writeAll(usage) catch {};
    w.interface.flush() catch {};
    std.process.exit(2);
}

/// Parse a required numeric flag value, rejecting a non-number instead of silently keeping the
/// default — `zephem std --depth notanumber` used to regenerate the map at depth 24.
pub fn intValue(c: Ctx, comptime T: type, args: []const []const u8, i: *usize, flag: []const u8, usage: []const u8) T {
    const raw = value(c, args, i, flag, usage);
    return std.fmt.parseInt(T, raw, 10) catch {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(c.io, &buf);
        w.interface.print("zephem: {s} expects a number, got: {s}\n\n", .{ flag, raw }) catch {};
        w.interface.writeAll(usage) catch {};
        w.interface.flush() catch {};
        std.process.exit(2);
    };
}

/// A diagnostic line to STDERR. Misses, error-usage and unavailability are not results:
/// `zephem look x > out.txt` used to write "no lookup entry matches: x" into the data file.
/// A miss now leaves stdout empty, like grep.
pub fn diag(c: Ctx, comptime fmt: []const u8, fmt_args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(c.io, &buf);
    try w.interface.print(fmt, fmt_args);
    try w.interface.flush();
}

/// Reject an argument the subcommand did not consume. Exits 2 with usage.
pub fn reject(c: Ctx, arg: []const u8, usage: []const u8) noreturn {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(c.io, &buf);
    w.interface.print("zephem: unrecognised argument: {s}\n\n", .{arg}) catch {};
    w.interface.writeAll(usage) catch {};
    w.interface.flush() catch {};
    std.process.exit(2);
}
