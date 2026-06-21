#!/usr/bin/env nu
# verify_canon.nu — reconcile the canon overlay against the map, the OTHER way.
#
# build_canon.nu derives canon.tsv from nodes/resolved/poison. This re-reads the three sources
# independently and checks every claim the overlay makes — so the overlay can't drift from, or
# quietly lie about, the layers it summarizes. The contract it enforces:
#
#   1. PARTITION   every path's `origin` is exactly its membership: read+run = in both,
#                  run-only = resolved-only, read-only = nodes-only. Census = |nodes ∪ resolved|.
#   2. ZERO-BLANK  no path has an empty origin; every path except the root has an owner.
#   3. OWNER REAL  every owner is a real readable decl (a node) — the doorway/container exists.
#   4. LINKED      every run-only member carries a canonical owner identity (owner_canon), and it
#                  matches the resolved @typeName of its owner. This is the "no member left
#                  unlinked" guarantee, checked — not asserted.
#   5. POISON REAL every read-only path is either the root or sits under a real poison container,
#                  and its note is that container's recorded reason.
#
# Usage:  nu scripts/verify_canon.nu [data/std]

def norm-path [p: string] { $p | str replace --regex --all '@"([^"]+)"' '$1' }

def nearest-val [p: string, lut: record] {
    let segs = ($p | split row ".")
    let n = ($segs | length)
    mut i = 1
    mut out = ""
    while $i < $n {
        let anc = ($segs | first ($n - $i) | str join ".")
        let v = ($lut | get -o $anc)
        if $v != null { $out = $v; break }
        $i = $i + 1
    }
    $out
}

def main [dir: string = "data/std"] {
    for f in ["canon.tsv" "nodes.tsv" "resolved.tsv" "poison.tsv"] {
        if not ($"($dir)/($f)" | path exists) { print $"missing ($dir)/($f)"; exit 1 }
    }
    let canon = (open $"($dir)/canon.tsv")
    let nodes = (open $"($dir)/nodes.tsv" | select path kind | insert np {|r| norm-path $r.path})
    let res = (open $"($dir)/resolved.tsv" | select path kind detail | uniq-by path | insert np {|r| norm-path $r.path})

    let nodeset = ($nodes | get np | reduce --fold {} {|p, acc| $acc | upsert $p true })
    let resset = ($res | get np | reduce --fold {} {|p, acc| $acc | upsert $p true })
    let typeDetail = ($res | where kind == "type" | reduce --fold {} {|r, acc| $acc | upsert $r.np $r.detail })
    let poisonReason = (open $"($dir)/poison.tsv" | select path reason
        | insert np {|r| norm-path $r.path} | reduce --fold {} {|r, acc| $acc | upsert $r.np $r.reason })

    mut ok = true
    print $"canon: ($canon | length) paths"

    # 1. PARTITION — origin must equal actual membership in nodes/resolved.
    let mis = ($canon | each {|r|
        let np = (norm-path $r.path)
        let inN = (($nodeset | get -o $np) == true)
        let inR = (($resset | get -o $np) == true)
        let want = (if ($inN and $inR) { "read+run" } else if $inR { "run-only" } else if $inN { "read-only" } else { "ABSENT" })
        if $r.origin == $want { null } else { {path: $r.path, origin: $r.origin, should_be: $want} }
    } | compact)
    let union = (($nodes | get np) ++ ($res | get np) | uniq | length)
    print $"── 1. partition \(origin = membership; census = |nodes ∪ resolved|\) ──"
    print $"  census ($canon | length) vs union ($union)"
    if ($canon | length) != $union { print "  ✗ census size ≠ union of the two layers"; $ok = false }
    if ($mis | length) > 0 { print $"  ✗ ($mis | length) path\(s\) tagged with the wrong origin:"; $mis | first 5 | print; $ok = false } else { print "  ✓ every origin equals the path's real membership" }

    # 2. ZERO-BLANK — origin always present; owner present unless root.
    let blank_o = ($canon | where origin == "" | length)
    let blank_owner = ($canon | where owner == "" and note != "root" | length)
    print "── 2. zero-blank ──"
    if $blank_o > 0 { print $"  ✗ ($blank_o) path\(s\) with no origin"; $ok = false } else { print "  ✓ every path has an origin" }
    if $blank_owner > 0 { print $"  ✗ ($blank_owner) non-root path\(s\) with no owner"; $ok = false } else { print "  ✓ every non-root path has an owner" }

    # 3. OWNER REAL — every non-empty owner is a readable node.
    let bad_owner = ($canon | where owner != "" | where {|r| ($nodeset | get -o (norm-path $r.owner)) != true} | length)
    print "── 3. owner is a real readable decl ──"
    if $bad_owner > 0 { print $"  ✗ ($bad_owner) owner\(s\) are not a node in the map"; $ok = false } else { print "  ✓ every owner is a real node \(the doorway/container exists\)" }

    # 4. LINKED — every run-only member has a canonical owner identity matching its owner's @typeName.
    let run = ($canon | where origin == "run-only")
    let unlinked = ($run | where owner_canon == "" | length)
    let mismatched = ($run | where {|r|
        let want = ($typeDetail | get -o (norm-path $r.owner))
        $want != null and $r.owner_canon != $want
    } | length)
    print "── 4. every made member linked to its canonical owner ──"
    if $unlinked > 0 { print $"  ✗ ($unlinked) run-only member\(s\) with no canonical owner"; $ok = false } else { print $"  ✓ all ($run | length) run-only members carry a canonical owner identity" }
    if $mismatched > 0 { print $"  ✗ ($mismatched) owner_canon\(s\) disagree with the resolved @typeName"; $ok = false } else { print "  ✓ every owner_canon matches the owner's resolved @typeName" }

    # 5. POISON REAL — read-only non-root paths sit under a real poison container with that reason.
    let ro = ($canon | where origin == "read-only" and note != "root")
    let bad_poison = ($ro | where {|r| (nearest-val (norm-path $r.path) $poisonReason) != $r.note} | length)
    let root_rows = ($canon | where note == "root" | length)
    print "── 5. read-only explained \(poison reason or root\) ──"
    if $root_rows != 1 { print $"  ✗ expected exactly 1 root row, found ($root_rows)"; $ok = false } else { print "  ✓ exactly one root row \(std\)" }
    if $bad_poison > 0 { print $"  ✗ ($bad_poison) read-only path\(s\) whose note isn't the nearest poison reason"; $ro | first 3 | print; $ok = false } else { print $"  ✓ all ($ro | length) poison-shadowed paths carry their container's reason" }

    print ""
    if $ok { print "CANON VERDICT: ✓ overlay reconciles with the map — every path classified, zero blanks" } else { print "CANON VERDICT: ✗ reconciliation FAILED"; exit 1 }
}
