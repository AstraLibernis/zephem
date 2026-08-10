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

/// Print `usage` and exit 0 if any argument asks for help. Call FIRST, before any work.
pub fn helpRequested(c: Ctx, args: []const []const u8, usage: []const u8) !void {
    for (args) |a| {
        if (!isHelp(a)) continue;
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(c.io, &buf);
        try w.interface.writeAll(usage);
        try w.interface.flush();
        std.process.exit(0);
    }
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
