#!/usr/bin/env nu
# lib.nu — shared helpers for the pipeline scripts (scripts/build_*.nu · scripts/verify_*.nu).
#
# Two families of helper:
#   • JOIN builders (norm-path, presence, lookup) — membership/value lookups are done with hash
#     JOINS, never per-row probes into a big record (quadratic to build, linear to probe — minutes
#     on full std). These build the right-hand side once; the join stays visible at each call site.
#   • MANIFEST helpers (check-manifest, write-manifest) — the identical SHA256SUMS.<slice> write and
#     --check-rebuild dance every single-file overlay builder repeats.

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

# Prove an overlay rebuilds byte-identical: hash the fresh rebuild and compare to the committed
# single-file manifest. `label` names the overlay in messages; exits non-zero on drift or a missing
# manifest.
export def check-manifest [manifest: string, fresh_tsv: string, label: string] {
    if not ($manifest | path exists) { print $"[($label) check] no ($manifest) — build first"; exit 1 }
    let want = (open $manifest | lines | first | parse -r '(?<hash>\S+)' | get hash.0)
    let got = ($fresh_tsv | hash sha256)
    if $got == $want { print $"[($label) check] ✓ rebuilds byte-identical \(($got)\)" } else {
        print $"[($label) check] ✗ DRIFT — manifest ($want) vs rebuild ($got)"; exit 1
    }
}

# Write a `sha256sum -c`-compatible single-file manifest for an overlay's tsv text.
export def write-manifest [tsv: string, outpath: string, manifest: string] {
    $"($tsv | hash sha256)  ($outpath)\n" | save -f $manifest
}
