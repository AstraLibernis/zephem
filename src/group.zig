//! group.zig — the "shape" clustering over the map's flat `kind` vocabulary.
//!
//! A pure classification (no data change): every nodes.tsv `kind` collapses into one of four
//! browse-oriented groups. The switch is EXHAUSTIVE over `walk.Kind`, so adding a new kind to
//! the map forces a classification decision here at compile time — the grouping can never
//! silently fall out of sync with the vocabulary.
//!
//!   namespace  ns · nsref                  — file-level scopes you dot into
//!   type       struct · enum · union · opaque — inline type definitions
//!   member     fn · const · alias          — the decls / values a scope holds
//!   boundary   modref · nserr              — edges of the map (external / unreadable)
//!
//! Use `groupOf` from a Zig consumer that already has a `walk.Kind`; use `groupOfName` from
//! one reading the `kind` column straight out of nodes.tsv. Both share one source of truth.

const std = @import("std");
const walk = @import("walk.zig");

pub const Group = enum { namespace, type, member, boundary };

pub fn groupStr(g: Group) []const u8 {
    return switch (g) {
        .namespace => "namespace",
        .type => "type",
        .member => "member",
        .boundary => "boundary",
    };
}

/// The shape group of a map kind. Exhaustive — a new `walk.Kind` won't compile until classified.
pub fn groupOf(kind: walk.Kind) Group {
    return switch (kind) {
        .ns, .nsref => .namespace,
        .@"struct", .@"enum", .@"union", .@"opaque" => .type,
        .fn_decl, .const_decl, .alias => .member,
        .modref, .nserr => .boundary,
    };
}

/// Same classification keyed by the wire spelling (the nodes.tsv `kind` column).
/// null for an unrecognized string — kept consistent with `walk.kindStr` by construction.
pub fn groupOfName(kind: []const u8) ?Group {
    inline for (std.meta.tags(walk.Kind)) |k| {
        if (std.mem.eql(u8, kind, walk.kindStr(k))) return groupOf(k);
    }
    return null;
}

test "every kind classifies, and the string path agrees with the enum path" {
    inline for (std.meta.tags(walk.Kind)) |k| {
        const g = groupOf(k);
        try std.testing.expectEqual(g, groupOfName(walk.kindStr(k)).?);
    }
    try std.testing.expect(groupOfName("not-a-kind") == null);
}
