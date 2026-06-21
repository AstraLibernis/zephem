//! tunnels/edges.zig — emit the tunnel stream: write one tagged edge, and harvest the
//! `usage` edges (type names referenced in fn signatures).
//!
//!   from_path · kind · status · to_or_raw · reason
//!
//! `emitEdge` is the single writer for every status; `walkUsage` scans each public fn's
//! param + return type expressions and routes each dotted chain through `resolve`.

const std = @import("std");
const Ast = std.zig.Ast;
const fs = @import("../common/fs.zig");
const rsv = @import("resolve.zig");

pub fn emitEdge(w: *std.Io.Writer, from: []const u8, kind: []const u8, r: rsv.Res, raw: []const u8) !void {
    switch (r) {
        .resolved => |to| try w.print("{s}\t{s}\tresolved\t{s}\t\n", .{ from, kind, to }),
        .primitive => |p| try w.print("{s}\t{s}\tprimitive\t{s}\t\n", .{ from, kind, p }),
        .internal => |t| try w.print("{s}\t{s}\tinternal\t{s}\t{s}\n", .{ from, kind, raw, t }),
        .unresolved => |why| try w.print("{s}\t{s}\tunresolved\t{s}\t{s}\n", .{ from, kind, raw, why }),
    }
}

/// Extract dotted-identifier chains from a type-expression source slice, resolving + emitting
/// each as a `usage` edge. `@This()`/`@import(...)` and the like are skipped (handled elsewhere
/// or not references); a chain starting with `@` is a builtin call, not a type name.
fn emitTypeRefs(ctx: *rsv.Ctx, w: *std.Io.Writer, from: []const u8, file: []const u8, expr: []const u8) !void {
    var i: usize = 0;
    while (i < expr.len) {
        const c = expr[i];
        // a chain starts at an identifier-start not preceded by '.' or '@' or an ident char
        if ((std.ascii.isAlphabetic(c) or c == '_')) {
            const prev = if (i == 0) 0 else expr[i - 1];
            if (prev == '.' or prev == '@' or std.ascii.isAlphanumeric(prev) or prev == '_') {
                i += 1;
                continue;
            }
            var j = i;
            while (j < expr.len and (std.ascii.isAlphanumeric(expr[j]) or expr[j] == '_' or expr[j] == '.')) j += 1;
            var chain = expr[i..j];
            while (chain.len > 0 and chain[chain.len - 1] == '.') chain = chain[0 .. chain.len - 1];
            i = j;
            if (chain.len == 0) continue;
            // skip Zig keywords that can appear in type position
            if (std.mem.eql(u8, chain, "anytype") or std.mem.eql(u8, chain, "comptime") or
                std.mem.eql(u8, chain, "type")) {
                if (rsv.isPrimitive(chain)) try emitEdge(w, from, "usage", .{ .primitive = chain }, chain);
                continue;
            }
            const r = try rsv.resolve(ctx, file, chain, 0);
            try emitEdge(w, from, "usage", r, chain);
        } else i += 1;
    }
}

/// Walk a file's public fns and emit usage edges for their param + return type expressions.
pub fn walkUsage(ctx: *rsv.Ctx, w: *std.Io.Writer, file: []const u8) !void {
    const logical = ctx.file2path.get(file) orelse return;
    _ = (try rsv.symsOf(ctx, file)) orelse return; // ensures parsed
    const abs = try std.fs.path.resolve(ctx.arena, &.{ ctx.root_dir, file });
    const ast = (try fs.parseFile(ctx.io, ctx.arena, abs)) orelse return;
    var a = ast;
    for (a.rootDecls()) |m| {
        if (a.nodeTag(m) != .fn_decl) continue;
        var b: [1]Ast.Node.Index = undefined;
        const proto = a.fullFnProto(&b, m) orelse continue;
        if (proto.visib_token == null) continue;
        const nt = proto.name_token orelse continue;
        const fname = a.tokenSlice(nt);
        const from = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ logical, fname });
        if (!rsv.has(ctx, from)) continue; // only emit from decls the map actually has
        var pit = proto.iterate(&a);
        while (pit.next()) |param| {
            if (param.type_expr) |te| try emitTypeRefs(ctx, w, from, file, a.getNodeSource(te));
        }
        if (proto.ast.return_type.unwrap()) |rt| try emitTypeRefs(ctx, w, from, file, a.getNodeSource(rt));
    }
}
