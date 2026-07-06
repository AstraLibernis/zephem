#!/usr/bin/env nu
# verify_consensus.nu — reconcile the consensus overlay against the two witnesses, the other way.
#
# build_consensus.nu tagged every path by membership in nodes / resolved. This re-reads both sources
# independently and proves the overlay can't drift from, or lie about, the layers it compares:
#
#   1. PARTITION   every path's origin equals its real membership: read+run = in nodes ∩ resolved,
#                  read-only = nodes only, run-only = resolved only. Census = |nodes ∪ resolved|.
#   2. ZERO-BLANK  every path has an origin; every path but the root has an owner.
#   3. OWNER REAL  every owner is a real readable node — the doorway/container exists.
#
# Usage:  nu scripts/verify_consensus.nu [data/std]

def norm-path [p: string] { $p | str replace --regex --all '@"([^"]+)"' '$1' }

def main [dir: string = "data/std"] {
    for f in ["consensus.tsv" "nodes.tsv" "resolved.tsv"] {
        if not ($"($dir)/($f)" | path exists) { print $"missing ($dir)/($f)"; exit 1 }
    }
    let con = (open $"($dir)/consensus.tsv")
    # match build_consensus: field/tag rows are out of the compare's scope (reflect never
    # resolves them as paths), so the census universe is decls/containers only.
    let nodes = (open $"($dir)/nodes.tsv" | where kind not-in ["field" "tag"] | select path | insert np {|r| norm-path $r.path})
    let res = (open $"($dir)/resolved.tsv" | select path | uniq-by path | insert np {|r| norm-path $r.path})
    let nodeset = ($nodes | get np | reduce --fold {} {|p, acc| $acc | upsert $p true})
    let resset = ($res | get np | reduce --fold {} {|p, acc| $acc | upsert $p true})
    mut ok = true
    print $"consensus: ($con | length) paths"

    # 1. PARTITION — origin must equal actual membership; census = the union of the two layers.
    let mis = ($con | each {|r|
        let np = (norm-path $r.path)
        let inN = (($nodeset | get -o $np) == true)
        let inR = (($resset | get -o $np) == true)
        let want = (if ($inN and $inR) { "read+run" } else if $inR { "run-only" } else if $inN { "read-only" } else { "ABSENT" })
        if $r.origin == $want { null } else { {path: $r.path, origin: $r.origin, should_be: $want} }
    } | compact)
    let union = (($nodes | get np) ++ ($res | get np) | uniq | length)
    print "── 1. partition (origin = membership; census = |nodes ∪ resolved|) ──"
    print $"  census ($con | length) vs union ($union)"
    if ($con | length) != $union { print "  ✗ census size ≠ union of the two layers"; $ok = false }
    if ($mis | length) > 0 { print $"  ✗ ($mis | length) path\(s\) tagged with the wrong origin:"; $mis | first 5 | print; $ok = false } else { print "  ✓ every origin equals the path's real membership" }

    # 2. ZERO-BLANK — origin always present; owner present unless the path is the root (no dot).
    let blank_o = ($con | where origin == "" | length)
    let blank_owner = ($con | where owner == "" | where {|r| ($r.path | str contains ".")} | length)
    print "── 2. zero-blank ──"
    if $blank_o > 0 { print $"  ✗ ($blank_o) path\(s\) with no origin"; $ok = false } else { print "  ✓ every path has an origin" }
    if $blank_owner > 0 { print $"  ✗ ($blank_owner) non-root path\(s\) with no owner"; $ok = false } else { print "  ✓ every non-root path has an owner" }

    # 3. OWNER REAL — every non-empty owner is a readable node.
    let bad_owner = ($con | where owner != "" | where {|r| ($nodeset | get -o (norm-path $r.owner)) != true} | length)
    print "── 3. owner is a real readable node ──"
    if $bad_owner > 0 { print $"  ✗ ($bad_owner) owner\(s\) are not a node in the map"; $ok = false } else { print "  ✓ every owner is a real node \(the doorway/container exists\)" }

    print ""
    if $ok { print "CONSENSUS VERDICT: ✓ overlay reconciles with the two witnesses" } else { print "CONSENSUS VERDICT: ✗ reconciliation FAILED"; exit 1 }
}
