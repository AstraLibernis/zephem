#!/usr/bin/env nu
# verify_lib.nu — shared helpers for the backward-check verifiers (scripts/verify_*.nu).
#
# Membership and value lookups are done with hash JOINS, never per-row probes into a big record
# (which is quadratic to build and linear to probe — minutes on full std). These two builders make
# the right-hand side of such a join once; the join itself stays visible at each call site.

# Strip Zig keyword-quoting so the parser's `@"type"` and the compiler's bare `type` compare equal.
# Fast path: skip the regex unless the path actually carries a `@"…"` quote (the vast majority don't).
export def norm-path [p: string] {
    if ($p | str contains '@"') { $p | str replace --regex --all '@"([^"]+)"' '$1' } else { $p }
}

# A joinable MEMBERSHIP view: the unique `col` values of `tbl`, tagged with marker column `mark`.
# Left-join against it, then keep `mark == null` (absent) or `mark == true` (present). Distinct
# markers let one table be probed against several sets at once without column collisions.
export def presence [tbl: table, col: string, mark: string] {
    $tbl | select $col | uniq-by $col | insert $mark true
}

# A joinable VALUE view: unique `key` → `val` from `tbl`, with `val` renamed to `as` (so the joined
# column can't collide with a same-named column on the left of the join).
export def lookup [tbl: table, key: string, val: string, as: string] {
    $tbl | select $key $val | uniq-by $key | rename --column {($val): $as}
}
