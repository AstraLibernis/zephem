//! common/tsv.zig — minimal TSV helpers shared by the readers (tunnels, index).

const std = @import("std");

/// The n-th tab-separated column of `line` (0-based), or "" if absent.
pub fn col(line: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var rest = line;
    while (i < n) : (i += 1) {
        const t = std.mem.indexOfScalar(u8, rest, '\t') orelse return "";
        rest = rest[t + 1 ..];
    }
    const end = std.mem.indexOfScalar(u8, rest, '\t') orelse rest.len;
    return rest[0..end];
}
