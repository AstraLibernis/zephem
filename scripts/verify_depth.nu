#!/usr/bin/env nu
# verify_depth.nu — prove the L5 depth overlay reconciles with the map, read a SECOND way.
#
# build_depth.nu sorted every attempted container into exactly one of resolved / poison and
# logged it in status.tsv. This script never trusts that ledger on its own: it re-reads the
# bucket files and the map (index.tsv) and proves they reconcile. Same spirit as verify_std.nu —
# the data checks itself, no oracle.
#
#   PARTITION     status holds each attempted container once, as resolved OR poison; the poison
#                 bucket file matches its status slice.
#   CONSERVATION  Σ status.n_rows (resolved containers) == rows in resolved.tsv.
#   REGISTRATION  every attempted container is a real container in index.tsv (no phantom).
#   HONEST POISON every poison reason is the compiler's own `error:` line or a `timeout after`
#                 tag — never a bare `exit N` masquerading as a compile error.
#   PRISTINE      no path appears in resolved.tsv twice with conflicting (kind, detail).
#   COVERAGE      (--full) every index.tsv container was attempted — the sweep skipped nothing.
#
# Usage:  nu scripts/verify_depth.nu <outdir> [--full]

# Safe column read — an all-header (zero-row) TSV opens as an empty list with no columns.
def col [t: list, name: string] {
    if ($t | is-empty) { [] } else { $t | get $name }
}

def main [outdir: string, --full] {
    for f in ["extracted/status.tsv" "extracted/resolved.tsv" "extracted/poison.tsv"] {
        if not ($"($outdir)/($f)" | path exists) { print $"missing ($outdir)/($f)"; exit 1 }
    }
    let status = (open $"($outdir)/extracted/status.tsv")
    let resolved = (open $"($outdir)/extracted/resolved.tsv")
    let poison = (open $"($outdir)/extracted/poison.tsv")
    let idxpaths = (open data/std/derived/index.tsv | get path)
    mut ok = true

    let spaths = (col $status "path")
    let n_res = ($status | where status == "resolved" | length)
    let s_poi = (($status | where status == "poison" | get path) | sort)

    # 1. PARTITION — one row per container, resolved OR poison, poison file == status slice.
    let sdups = ($spaths | uniq -d)
    let badstat = ($status | where status not-in ["resolved" "poison"])
    let f_poi = ((col $poison "path") | sort)
    print $"partition:    ($status | length) attempted = ($n_res) resolved + ($s_poi | length) poison"
    if ($sdups | length) > 0 { print $"  ✗ ($sdups | length) container\(s\) appear twice in status"; $ok = false }
    if ($badstat | length) > 0 { print $"  ✗ ($badstat | length) row\(s\) with an unknown status"; $ok = false }
    if $s_poi != $f_poi { print "  ✗ poison status set ≠ poison.tsv paths"; $ok = false }
    if ($n_res + ($s_poi | length)) != ($status | length) { print "  ✗ buckets don't sum to attempted"; $ok = false }
    if $ok { print "  ✓ every container is resolved or poison; the poison file agrees with the ledger" }

    # 2. CONSERVATION — recorded resolved row-counts sum to the actual resolved.tsv rows.
    let declared = ($status | where status == "resolved" | get n_rows | each {|x| $x | into int} | math sum)
    let actual = ($resolved | length)
    print $"conservation: Σ resolved n_rows = ($declared)   resolved.tsv rows = ($actual)"
    if $declared != $actual { print "  ✗ row accounting disagrees"; $ok = false } else { print "  ✓ resolved rows fully accounted to their containers" }

    # 3. REGISTRATION — every attempted container is a real container in the map.
    let phantom = ($spaths | where {|p| $p not-in $idxpaths})
    print $"registration: ($spaths | length) attempted containers vs ($idxpaths | length) in index.tsv"
    if ($phantom | length) > 0 { print $"  ✗ ($phantom | length) attempted path\(s\) are not containers in the map"; $phantom | first 10 | print; $ok = false } else { print "  ✓ every attempted container exists in the map" }

    # 4. HONEST POISON — every reason is a real compiler `error:` line or a `timeout after` tag.
    # A bare `exit N` reason means something failed without the compiler refusing (the old
    # timeout-masquerades-as-poison bug); reject it so poison always means "the compiler said no".
    let reasons = (col $poison "reason")
    let dishonest = ($reasons | where {|r| not (($r =~ 'error:') or ($r | str starts-with "timeout after"))})
    print $"honest-poison: ($reasons | length) poison reason\(s\)"
    if ($dishonest | length) > 0 { print $"  ✗ ($dishonest | length) reason\(s\) are neither a compiler error nor a timeout tag"; $dishonest | first 10 | print; $ok = false } else { print "  ✓ every poison reason is a compiler error or an explicit timeout" }

    # 5. PRISTINE — no path resolved to two different facts.
    let rpaths = (col $resolved "path")
    let conflicts = ($resolved | group-by path | items {|p, rows|
        { path: $p, variants: ($rows | each {|r| $"($r.kind)\t($r.detail)" } | uniq | length) }
    } | where variants > 1)
    print $"pristine:     ($rpaths | uniq | length) distinct resolved paths"
    if ($conflicts | length) > 0 { print $"  ✗ ($conflicts | length) path\(s\) carry conflicting facts"; $conflicts | first 10 | print; $ok = false } else { print "  ✓ no path resolves to two different values" }

    # 6. COVERAGE — (full sweep only) the map was swept in full, nothing skipped.
    if $full {
        let missed = ($idxpaths | where {|p| $p not-in $spaths})
        print $"coverage:     ($spaths | length) attempted / ($idxpaths | length) map containers"
        if ($missed | length) > 0 { print $"  ✗ ($missed | length) map container\(s\) never attempted"; $missed | first 10 | print; $ok = false } else { print "  ✓ every container in the map was attempted" }
    }

    print ""
    if $ok { print "DEPTH VERDICT: ✓ overlay reconciles with the map" } else { print "DEPTH VERDICT: ✗ reconciliation FAILED"; exit 1 }
}
