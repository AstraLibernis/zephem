//! relation.zig — a tiny relational-TSV toolkit: the Zig replacement for the Nushell
//! dataframe verbs the pipeline leaned on (`open`/`to tsv`/`select`/`rename`/`where`/
//! `insert`/`uniq-by`/`group-by`/`sort-by`/`join --left`/`join --outer`).
//!
//! A `Table` is a header (column names) + rows of string cells. Every cell is text — TSV is
//! all we consume, and the parser already escaped tabs/newlines out of values — so columns
//! never contain a `\t` or `\n`. Numeric comparisons parse on demand at the one or two call
//! sites that need them; the model itself is string-only, which keeps joins and equality dead
//! simple. Ops allocate fresh tables from the caller's allocator (arena, in practice) and
//! freely SHARE cell slices with their input — nothing here mutates cells, so aliasing the
//! backing bytes is safe and copy-free.
//!
//! Membership/value lookups are HASH joins (build the right side once, probe linearly), never
//! per-row scans — the same discipline `scripts/lib.nu` enforced, for the same reason (a scan
//! is quadratic over full std).

const std = @import("std");

pub const Row = []const []const u8;

pub const Table = struct {
    columns: []const []const u8,
    rows: []const Row,
    a: std.mem.Allocator,

    /// Column index by name, or null if absent.
    pub fn colIndex(t: Table, name: []const u8) ?usize {
        for (t.columns, 0..) |c, i| if (std.mem.eql(u8, c, name)) return i;
        return null;
    }
    /// Column index by name — fail-loud: a missing column is a program error, not a runtime
    /// contingency (every access is against a schema we control).
    pub fn col(t: Table, name: []const u8) usize {
        return t.colIndex(name) orelse std.debug.panic("relation: no column '{s}' in [{s}]", .{ name, joinNames(t.columns) });
    }
    pub fn cell(t: Table, row: Row, name: []const u8) []const u8 {
        return row[t.col(name)];
    }
};

pub const Group = struct { key: []const u8, rows: []const Row };

fn joinNames(cols: []const []const u8) []const u8 {
    // best-effort, for panic messages only
    return if (cols.len == 0) "" else cols[0];
}

// ── load / write ────────────────────────────────────────────────────────────

/// Parse TSV text into a Table. First non-empty line is the header. Short rows are padded with
/// "" to the header width; extra cells are dropped — the schema (the header) is authoritative.
pub fn loadBytes(a: std.mem.Allocator, bytes: []const u8) !Table {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const header_line = lines.next() orelse return Table{ .columns = &.{}, .rows = &.{}, .a = a };
    const columns = try splitTab(a, header_line);
    var rows: std.ArrayList(Row) = .empty;
    while (lines.next()) |line| {
        if (line.len == 0) continue; // trailing newline → empty final chunk
        const cells = try splitTabPadded(a, line, columns.len);
        try rows.append(a, cells);
    }
    return Table{ .columns = columns, .rows = try rows.toOwnedSlice(a), .a = a };
}

pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) !Table {
    const bytes = try std.Io.Dir.cwd().readFileAllocOptions(io, path, a, .unlimited, .of(u8), 0);
    return loadBytes(a, bytes);
}

/// Serialize to TSV: header row, then each data row, every line tab-joined and `\n`-terminated
/// (trailing newline included). Deterministic; not required to match Nushell `to tsv` byte-for-byte.
pub fn writeTsv(t: Table, w: *std.Io.Writer) !void {
    try writeCells(w, t.columns);
    for (t.rows) |r| try writeCells(w, r);
}

pub fn writeFile(t: Table, io: std.Io, path: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [1 << 16]u8 = undefined;
    var fw = f.writer(io, &buf);
    try writeTsv(t, &fw.interface);
    try fw.interface.flush();
}

fn writeCells(w: *std.Io.Writer, cells: []const []const u8) !void {
    for (cells, 0..) |c, i| {
        if (i != 0) try w.writeByte('\t');
        try w.writeAll(c);
    }
    try w.writeByte('\n');
}

fn splitTab(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var n: usize = 1;
    for (line) |c| {
        if (c == '\t') n += 1;
    }
    const out = try a.alloc([]const u8, n);
    var it = std.mem.splitScalar(u8, line, '\t');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) out[i] = part;
    return out;
}

fn splitTabPadded(a: std.mem.Allocator, line: []const u8, width: usize) !Row {
    const out = try a.alloc([]const u8, width);
    @memset(out, "");
    var it = std.mem.splitScalar(u8, line, '\t');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= width) break;
        out[i] = part;
    }
    return out;
}

// ── ops (each returns a fresh Table) ─────────────────────────────────────────

/// Project `cols` (by name, in the given order).
pub fn select(a: std.mem.Allocator, t: Table, cols: []const []const u8) !Table {
    const idx = try a.alloc(usize, cols.len);
    for (cols, 0..) |c, i| idx[i] = t.col(c);
    const rows = try a.alloc(Row, t.rows.len);
    for (t.rows, 0..) |r, ri| {
        const nr = try a.alloc([]const u8, cols.len);
        for (idx, 0..) |ci, k| nr[k] = r[ci];
        rows[ri] = nr;
    }
    return Table{ .columns = try a.dupe([]const u8, cols), .rows = rows, .a = a };
}

/// Rename column `from` → `to` (shares rows).
pub fn rename(a: std.mem.Allocator, t: Table, from: []const u8, to: []const u8) !Table {
    const cols = try a.dupe([]const u8, t.columns);
    cols[t.col(from)] = to;
    return Table{ .columns = cols, .rows = t.rows, .a = a };
}

/// Keep rows for which `pred(ctx, row)` is true. Shares surviving row slices.
pub fn filter(a: std.mem.Allocator, t: Table, ctx: anytype, comptime pred: fn (@TypeOf(ctx), Row) bool) !Table {
    var kept: std.ArrayList(Row) = .empty;
    for (t.rows) |r| {
        if (pred(ctx, r)) try kept.append(a, r);
    }
    return Table{ .columns = t.columns, .rows = try kept.toOwnedSlice(a), .a = a };
}

/// Append a computed column `name`; `compute(ctx, row)` returns its cell (may allocate via ctx).
pub fn insert(a: std.mem.Allocator, t: Table, name: []const u8, ctx: anytype, comptime compute: fn (@TypeOf(ctx), Row) []const u8) !Table {
    const cols = try a.alloc([]const u8, t.columns.len + 1);
    @memcpy(cols[0..t.columns.len], t.columns);
    cols[t.columns.len] = name;
    const rows = try a.alloc(Row, t.rows.len);
    for (t.rows, 0..) |r, ri| {
        const nr = try a.alloc([]const u8, cols.len);
        @memcpy(nr[0..r.len], r);
        nr[r.len] = compute(ctx, r);
        rows[ri] = nr;
    }
    return Table{ .columns = cols, .rows = rows, .a = a };
}

/// Keep the FIRST row for each distinct value of `key` (Nushell `uniq-by` semantics).
pub fn uniqBy(a: std.mem.Allocator, t: Table, key: []const u8) !Table {
    const ki = t.col(key);
    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    var kept: std.ArrayList(Row) = .empty;
    for (t.rows) |r| {
        const gop = try seen.getOrPut(r[ki]);
        if (!gop.found_existing) try kept.append(a, r);
    }
    return Table{ .columns = t.columns, .rows = try kept.toOwnedSlice(a), .a = a };
}

/// Ascending sort by `keys` (byte-lexicographic), made a TOTAL order by using each row's
/// original position as the final tiebreaker — so the result is deterministic and stable
/// without needing a stable sort primitive.
pub fn sortBy(a: std.mem.Allocator, t: Table, keys: []const []const u8) !Table {
    const kidx = try a.alloc(usize, keys.len);
    for (keys, 0..) |k, i| kidx[i] = t.col(k);
    const order = try a.alloc(usize, t.rows.len);
    for (order, 0..) |*o, i| o.* = i;
    const Ctx = struct { rows: []const Row, kidx: []const usize };
    const ctx = Ctx{ .rows = t.rows, .kidx = kidx };
    std.mem.sort(usize, order, ctx, struct {
        fn lt(c: Ctx, ia: usize, ib: usize) bool {
            for (c.kidx) |ci| {
                const o = std.mem.order(u8, c.rows[ia][ci], c.rows[ib][ci]);
                if (o != .eq) return o == .lt;
            }
            return ia < ib; // total order → deterministic
        }
    }.lt);
    const rows = try a.alloc(Row, t.rows.len);
    for (order, 0..) |oi, i| rows[i] = t.rows[oi];
    return Table{ .columns = t.columns, .rows = rows, .a = a };
}

/// Group by `key`, preserving first-seen key order. Each group shares its input row slices.
pub fn groupBy(a: std.mem.Allocator, t: Table, key: []const u8) ![]const Group {
    const ki = t.col(key);
    var index = std.StringHashMap(usize).init(a); // key → position in `lists`
    defer index.deinit();
    var order: std.ArrayList([]const u8) = .empty;
    var lists: std.ArrayList(std.ArrayList(Row)) = .empty;
    for (t.rows) |r| {
        const gop = try index.getOrPut(r[ki]);
        if (!gop.found_existing) {
            gop.value_ptr.* = lists.items.len;
            try order.append(a, r[ki]);
            try lists.append(a, .empty);
        }
        try lists.items[gop.value_ptr.*].append(a, r);
    }
    const groups = try a.alloc(Group, order.items.len);
    for (order.items, 0..) |k, i| groups[i] = .{ .key = k, .rows = try lists.items[i].toOwnedSlice(a) };
    return groups;
}

/// Build key → first-matching-row index over `right` (first wins, matching an upstream uniq-by).
fn indexByKey(a: std.mem.Allocator, right: Table, ki: usize) !std.StringHashMap(usize) {
    var m = std.StringHashMap(usize).init(a);
    for (right.rows, 0..) |r, i| {
        const gop = try m.getOrPut(r[ki]);
        if (!gop.found_existing) gop.value_ptr.* = i;
    }
    return m;
}

/// Left join on `key`: keep every left row, append right's non-key columns (or "" when no
/// match). Right is treated as 1:1 on `key` (first match wins) — the callers dedup it first,
/// so the row count is preserved exactly (their 1:1 self-check depends on this).
pub fn joinLeft(a: std.mem.Allocator, left: Table, right: Table, key: []const u8) !Table {
    const lki = left.col(key);
    const rki = right.col(key);
    var rcols: std.ArrayList(usize) = .empty; // right column indices except the key
    for (right.columns, 0..) |_, i| {
        if (i == rki) continue;
        try rcols.append(a, i);
    }
    var idx = try indexByKey(a, right, rki);
    defer idx.deinit();

    const cols = try a.alloc([]const u8, left.columns.len + rcols.items.len);
    @memcpy(cols[0..left.columns.len], left.columns);
    for (rcols.items, 0..) |ci, k| cols[left.columns.len + k] = right.columns[ci];

    const rows = try a.alloc(Row, left.rows.len);
    for (left.rows, 0..) |lr, ri| {
        const nr = try a.alloc([]const u8, cols.len);
        @memcpy(nr[0..lr.len], lr);
        const match = idx.get(lr[lki]);
        for (rcols.items, 0..) |ci, k| nr[left.columns.len + k] = if (match) |mi| right.rows[mi][ci] else "";
        rows[ri] = nr;
    }
    return Table{ .columns = cols, .rows = rows, .a = a };
}

/// Full outer join on `key`: matched rows (left+right), then left-only (right cols ""), then
/// right-only (left cols "" except `key`, taken from the right). Columns = left ++ right-non-key.
/// Right is 1:1 on `key`. Deterministic order: left rows in input order, then unmatched right
/// rows in input order.
pub fn joinOuter(a: std.mem.Allocator, left: Table, right: Table, key: []const u8) !Table {
    const lki = left.col(key);
    const rki = right.col(key);
    var rcols: std.ArrayList(usize) = .empty;
    for (right.columns, 0..) |_, i| {
        if (i == rki) continue;
        try rcols.append(a, i);
    }
    var ridx = try indexByKey(a, right, rki);
    defer ridx.deinit();
    var lkeys = std.StringHashMap(void).init(a);
    defer lkeys.deinit();

    const cols = try a.alloc([]const u8, left.columns.len + rcols.items.len);
    @memcpy(cols[0..left.columns.len], left.columns);
    for (rcols.items, 0..) |ci, k| cols[left.columns.len + k] = right.columns[ci];

    var rows: std.ArrayList(Row) = .empty;
    for (left.rows) |lr| {
        try lkeys.put(lr[lki], {});
        const nr = try a.alloc([]const u8, cols.len);
        @memcpy(nr[0..lr.len], lr);
        const match = ridx.get(lr[lki]);
        for (rcols.items, 0..) |ci, k| nr[left.columns.len + k] = if (match) |mi| right.rows[mi][ci] else "";
        try rows.append(a, nr);
    }
    // right-only rows
    for (right.rows) |rr| {
        if (lkeys.contains(rr[rki])) continue;
        const nr = try a.alloc([]const u8, cols.len);
        @memset(nr[0..left.columns.len], "");
        nr[lki] = rr[rki]; // carry the join key into the left key slot
        for (rcols.items, 0..) |ci, k| nr[left.columns.len + k] = rr[ci];
        try rows.append(a, nr);
    }
    return Table{ .columns = cols, .rows = try rows.toOwnedSlice(a), .a = a };
}
