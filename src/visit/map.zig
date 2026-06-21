//! visit/map.zig — the structure visitor → nodes.tsv.
//!
//! One TSV row per public decl (the "labels"); container rows carry their PUBLIC-CHILD
//! COUNT so the "levels" tree falls out of the `path` column AND the data self-verifies:
//!
//!   path · depth · kind · name · n_children · detail
//!
//! The walker pre-formats every field (including a fn's param count into `detail`), so this
//! is a single verbatim print — all the structure decisions live in walk.zig.

const std = @import("std");
const walk = @import("../walk.zig");

pub const Visitor = struct {
    w: *std.Io.Writer,

    pub fn emit(self: Visitor, n: walk.Node) !void {
        try self.w.print("{s}\t{d}\t{s}\t{s}\t{d}\t{s}\n", .{
            n.path, n.depth, walk.kindStr(n.kind), n.name, n.n_children, n.detail,
        });
    }
};
