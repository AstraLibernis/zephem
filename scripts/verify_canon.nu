#!/usr/bin/env nu
# verify_canon.nu — reconcile the canon (dedup/dealias) overlay against resolved.tsv, the other way.
#
# build_canon.nu grouped resolved type identities into alias/dup families. This re-reads resolved.tsv
# independently and proves every claim — no trust in the overlay's own output:
#
#   1. SOURCED   every (path · canon) is a real kind=type row in resolved.tsv whose detail == canon.
#   2. NOMINAL   no canon is an excluded identity (primitive / error set / anon marker).
#   3. FAMILIES  every canon value appears on >= 2 paths (a real collision, not a singleton), and the
#                overlay holds EVERY path that shares it — no family silently truncated.
#
# Usage:  nu scripts/verify_canon.nu [data/std]

use lib.nu *   # lookup

def nominal [id: string] {
    not (($id | str starts-with "error{")
      or ($id =~ '__(struct|enum|union|opaque)')
      or ($id =~ '^(void|anyopaque|anyerror|anyframe|bool|type|noreturn|comptime_int|comptime_float|isize|usize|[uif][0-9]+|c_[a-z]+)$'))
}

def main [dir: string = "data/std"] {
    for f in ["derived/canon.tsv" "extracted/resolved.tsv"] {
        if not ($"($dir)/($f)" | path exists) { print $"missing ($dir)/($f)"; exit 1 }
    }
    let canon = (open $"($dir)/derived/canon.tsv")
    let types = (open $"($dir)/extracted/resolved.tsv" | where kind == "type")
    # joinable path → resolved detail (hash join, not a per-row probe into a big record).
    let type_detail = (lookup $types path detail _detail)
    mut ok = true
    print $"canon: ($canon | length) aliased/duplicated paths"

    # 1. SOURCED — every claimed (path → canon) is exactly what resolved.tsv says.
    let unsourced = ($canon | join --left $type_detail path | where {|r| ($r._detail? | default null) != $r.canon})
    print "── 1. sourced (every path·canon is a resolved type row) ──"
    if ($unsourced | length) > 0 { print $"  ✗ ($unsourced | length) row\(s\) not backed by resolved.tsv"; $unsourced | first 5 | print; $ok = false } else { print "  ✓ every path resolves to its stated canon in resolved.tsv" }

    # 2. NOMINAL — no excluded (primitive / error set / anon) identity slipped in.
    let nonnominal = ($canon | where {|r| not (nominal $r.canon)})
    print "── 2. nominal (no primitive / error set / anon identity) ──"
    if ($nonnominal | length) > 0 { print $"  ✗ ($nonnominal | length) canon\(s\) are excluded identities"; $nonnominal | first 5 | print; $ok = false } else { print "  ✓ every canon is a nominal/composite identity" }

    # 3. FAMILIES — every canon shared by >=2 paths, and ALL such paths present (recomputed truth).
    let fams = ($canon | group-by canon)
    let singletons = ($fams | items {|k, v| if ($v | length) < 2 { $k } else { null }} | compact)
    let truth = ($types | where {|r| nominal $r.detail} | group-by detail)
    let truncated = ($fams | items {|id, rows|
        let want = ($truth | get -o $id | default [] | get path | sort)
        let have = ($rows | get path | sort)
        if $want != $have { $id } else { null }
    } | compact)
    print "── 3. families (each canon on >=2 paths, none truncated) ──"
    if ($singletons | length) > 0 { print $"  ✗ ($singletons | length) canon\(s\) appear on a single path"; $ok = false } else { print "  ✓ every canon is a real collision \(>= 2 paths\)" }
    if ($truncated | length) > 0 { print $"  ✗ ($truncated | length) famil\(ies\) missing members vs resolved.tsv"; $truncated | first 5 | print; $ok = false } else { print "  ✓ every family holds all paths that share its identity" }

    print ""
    if $ok { print "CANON VERDICT: ✓ overlay reconciles with resolved.tsv — real alias/dup families, complete" } else { print "CANON VERDICT: ✗ reconciliation FAILED"; exit 1 }
}
