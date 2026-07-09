#!/usr/bin/env nu
# verify_doccov.nu — reconcile the doc-coverage overlay against the map and the docs overlay.
#
# build_doccov.nu tagged every node by membership in docs.tsv. This re-reads both sources the other
# way and proves the overlay can't drift from, or lie about, what it counts:
#
#   1. CENSUS      one row per map node — every doccov path is a real node, no dups, |doccov|=|nodes|.
#   2. PARTITION   documented ∈ {yes,no}; each row's kind equals the node's kind in the map.
#   3. TRUTH       documented=="yes" ⟺ path ∈ docs.tsv — no missed doc, no phantom doc.
#
# Usage:  nu scripts/verify_doccov.nu [data/std]

def main [dir: string = "data/std"] {
    for f in ["derived/doccov.tsv" "extracted/nodes.tsv" "extracted/attrs.tsv"] {
        if not ($"($dir)/($f)" | path exists) { print $"missing ($dir)/($f)"; exit 1 }
    }
    let dc = (open $"($dir)/derived/doccov.tsv")
    let nodes = (open $"($dir)/extracted/nodes.tsv" | select path kind)
    let docpaths = (open $"($dir)/extracted/attrs.tsv" | where attr == "doc" | get path | uniq)
    # joinable views — a hash join beats per-row probes into a 60k-key record (quadratic to build).
    let node_exists = ($nodes | select path | insert _n true)
    let node_kind = ($nodes | rename --column {kind: _mapkind})
    let doc_exists = ($docpaths | wrap path | insert _d true)
    mut ok = true
    print $"doccov: ($dc | length) nodes"

    # 1. CENSUS — one row per node, no orphan paths, no duplicates.
    let dcount = ($dc | length)
    let ncount = ($nodes | length)
    let uniqn = ($dc | get path | uniq | length)
    let orphans = ($dc | join --left $node_exists path | where _n == null | length)
    print "── 1. census (one row per map node) ──"
    if $dcount != $ncount { print $"  ✗ row count ($dcount) ≠ nodes ($ncount)"; $ok = false } else { print $"  ✓ one row per node \(($dcount)\)" }
    if $uniqn != $dcount { print $"  ✗ (($dcount) - ($uniqn)) duplicate path\(s\)"; $ok = false } else { print "  ✓ no duplicate paths" }
    if $orphans > 0 { print $"  ✗ ($orphans) path\(s\) not in the map"; $ok = false } else { print "  ✓ every path is a real node" }

    # 2. PARTITION — documented flag is yes/no; kind agrees with the map.
    let badval = ($dc | where documented not-in ["yes" "no"] | length)
    let badkind = ($dc | join --left $node_kind path | where {|r| $r.kind != ($r._mapkind? | default null)} | length)
    print "── 2. partition (documented flag + kind agree with the map) ──"
    if $badval > 0 { print $"  ✗ ($badval) row\(s\) with documented ∉ yes/no"; $ok = false } else { print "  ✓ every documented flag is yes or no" }
    if $badkind > 0 { print $"  ✗ ($badkind) row\(s\) whose kind disagrees with the map"; $ok = false } else { print "  ✓ every kind matches the map" }

    # 3. TRUTH — documented=="yes" exactly when the path has a `///` doc.
    let yes = ($dc | where documented == "yes")
    let wrong_yes = ($yes | join --left $doc_exists path | where _d == null | length)
    let no = ($dc | where documented == "no")
    let wrong_no = ($no | join --left $doc_exists path | where _d == true | length)
    print "── 3. truth (yes ⟺ present in docs.tsv) ──"
    print $"  documented \(yes\): ($yes | length)   docs.tsv paths: ($docpaths | length)"
    if ($yes | length) != ($docpaths | length) { print "  ✗ documented count ≠ docs.tsv path count"; $ok = false }
    if $wrong_yes > 0 { print $"  ✗ ($wrong_yes) 'yes' row\(s\) absent from docs.tsv"; $ok = false }
    if $wrong_no > 0 { print $"  ✗ ($wrong_no) 'no' row\(s\) that DO have a doc"; $ok = false }
    if ($wrong_yes == 0) and ($wrong_no == 0) and (($yes | length) == ($docpaths | length)) { print "  ✓ documented ⟺ present in docs.tsv" }

    print ""
    if $ok { print "DOCCOV VERDICT: ✓ overlay reconciles with the map and the docs overlay" } else { print "DOCCOV VERDICT: ✗ reconciliation FAILED"; exit 1 }
}
