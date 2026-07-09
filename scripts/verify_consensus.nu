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

use verify_lib.nu *   # norm-path, presence

def main [dir: string = "data/std"] {
    for f in ["derived/consensus.tsv" "extracted/nodes.tsv" "extracted/resolved.tsv"] {
        if not ($"($dir)/($f)" | path exists) { print $"missing ($dir)/($f)"; exit 1 }
    }
    let con = (open $"($dir)/derived/consensus.tsv")
    # match build_consensus: field/tag rows AND factory members (`…()` paths) are out of the
    # compare's scope (reflect never resolves them as paths), so the census universe is
    # decls/containers only.
    let nodes = (open $"($dir)/extracted/nodes.tsv" | where kind not-in ["field" "tag"] | where {|r| not ($r.path | str contains "(")} | select path | insert np {|r| norm-path $r.path})
    let res = (open $"($dir)/extracted/resolved.tsv" | select path | uniq-by path | insert np {|r| norm-path $r.path})
    # joinable membership views — a hash join beats per-row probes into a 60k-key record.
    let node_np = (presence $nodes np _inN)
    let res_np = (presence $res np _inR)
    mut ok = true
    print $"consensus: ($con | length) paths"

    # 1. PARTITION — origin must equal actual membership; census = the union of the two layers.
    # Vectorized: attach membership by join, then check each of the 4 (inN,inR) cells with a filter —
    # no per-row closure over the 28k-row overlay.
    let cj = ($con | insert np {|r| norm-path $r.path} | join --left $node_np np | join --left $res_np np
        | default false _inN | default false _inR)
    let mis = ([
        ($cj | where _inN == true  | where _inR == true  | where origin != "read+run"  | insert should_be "read+run")
        ($cj | where _inN == false | where _inR == true  | where origin != "run-only"  | insert should_be "run-only")
        ($cj | where _inN == true  | where _inR == false | where origin != "read-only" | insert should_be "read-only")
        ($cj | where _inN == false | where _inR == false | where origin != "ABSENT"    | insert should_be "ABSENT")
    ] | flatten | select path origin should_be)
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
    let bad_owner = ($con | where owner != "" | insert np {|r| norm-path $r.owner} | join --left $node_np np | where _inN == null | length)
    print "── 3. owner is a real readable node ──"
    if $bad_owner > 0 { print $"  ✗ ($bad_owner) owner\(s\) are not a node in the map"; $ok = false } else { print "  ✓ every owner is a real node \(the doorway/container exists\)" }

    print ""
    if $ok { print "CONSENSUS VERDICT: ✓ overlay reconciles with the two witnesses" } else { print "CONSENSUS VERDICT: ✗ reconciliation FAILED"; exit 1 }
}
