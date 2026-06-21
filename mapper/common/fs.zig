//! common/fs.zig — path + file primitives shared by every parse-walk extractor.
//!
//! Deterministic by construction: `relPath` renders an absolute path relative to the
//! module root so the dataset is identical regardless of where the toolchain lives on
//! disk, and `parseFile` is silent on read failure (the caller emits the right leaf row),
//! so a missing file never injects an off-schema row.

const std = @import("std");
const Ast = std.zig.Ast;

/// The directory part of `path` (everything before the last '/'), or "." if none.
pub fn dirname(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[0..i];
    return ".";
}

/// `abs` rendered relative to `root_dir` (machine-independent dataset paths).
pub fn relPath(root_dir: []const u8, abs: []const u8) []const u8 {
    if (abs.len > root_dir.len and std.mem.startsWith(u8, abs, root_dir) and abs[root_dir.len] == '/')
        return abs[root_dir.len + 1 ..];
    return abs;
}

/// Parse a file's source into an Ast (caller keeps `arena` alive for the walk).
/// Returns null on read failure so the caller can emit the right leaf row.
pub fn parseFile(io: std.Io, arena: std.mem.Allocator, path: []const u8) !?Ast {
    const src = std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .unlimited, .of(u8), 0) catch {
        return null;
    };
    return try Ast.parse(arena, src, .zig);
}
