#!/usr/bin/env nu
# verify_sigshape.nu — reconcile the signature-shape overlay against the signatures, the other way.
#
# build_sigshape.nu classified each sig with a depth-aware parameter scan. This re-derives every
# label from the RAW signature with INDEPENDENT regex (no shared parsing machinery) and proves they
# agree — so a bug in either method shows up as a mismatch:
#
#   1. REGISTRATION   every path is a signed fn — |sigshape| = |sigs| = the map's fn set.
#   2. PARTITION      first_param ∈ {none,self,allocator,other}; io,generic ∈ {yes,no}.
#   3. CONSISTENCY    each stored label equals an independent regex re-read of the signature.
#
# Usage:  nu scripts/verify_sigshape.nu [data/std]

def main [dir: string = "data/std"] {
    for f in ["derived/sigshape.tsv" "extracted/attrs.tsv" "extracted/nodes.tsv"] {
        if not ($"($dir)/($f)" | path exists) { print $"missing ($dir)/($f)"; exit 1 }
    }
    let ss = (open $"($dir)/derived/sigshape.tsv")
    let sigs = (open $"($dir)/extracted/attrs.tsv" | where attr == "sig")
    let sigmap = ($sigs | reduce --fold {} {|r, acc| $acc | upsert $r.path $r.value})
    let sigset = ($sigs | get path | reduce --fold {} {|p, acc| $acc | upsert $p true})
    let fns = (open $"($dir)/extracted/nodes.tsv" | where kind == "fn" | length)
    mut ok = true
    print $"sigshape: ($ss | length) fns"

    # 1. REGISTRATION — one row per signature, which is exactly the map's fn set.
    let cnt = ($ss | length)
    let orphans = ($ss | where {|r| ($sigset | get -o $r.path) != true} | length)
    print "── 1. registration (each path is a signed fn) ──"
    if $cnt != ($sigs | length) { print $"  ✗ rows ($cnt) ≠ sigs.tsv (($sigs | length))"; $ok = false } else { print $"  ✓ one row per signature \(($cnt)\)" }
    if $cnt != $fns { print $"  ✗ rows ($cnt) ≠ map fn count ($fns)"; $ok = false } else { print $"  ✓ matches the map's fn set \(($fns)\)" }
    if $orphans > 0 { print $"  ✗ ($orphans) path\(s\) not in sigs.tsv"; $ok = false } else { print "  ✓ every path has a signature" }

    # 2. PARTITION — every field is a known value.
    let badfp = ($ss | where {|r| $r.first_param not-in ["none" "self" "allocator" "other"]} | length)
    let badflag = ($ss | where {|r| ($r.io not-in ["yes" "no"]) or ($r.generic not-in ["yes" "no"])} | length)
    print "── 2. partition (every field a known value) ──"
    if $badfp > 0 { print $"  ✗ ($badfp) row\(s\) with first_param ∉ none/self/allocator/other"; $ok = false } else { print "  ✓ first_param ∈ none/self/allocator/other" }
    if $badflag > 0 { print $"  ✗ ($badflag) row\(s\) with io/generic ∉ yes/no"; $ok = false } else { print "  ✓ io, generic ∈ yes/no" }

    # 3. CONSISTENCY — independent regex re-derivation of every label must match.
    let mism = ($ss | each {|r|
        let sig = ($sigmap | get -o $r.path)
        # anchor to the parameter list — the FIRST `(` — so `@This()` etc. in a type can't masquerade.
        let want_fp = (if ($sig =~ '^[^(]*\(\s*\)') { "none" } else if ($sig =~ '^[^(]*\(\s*(self|this)\b') { "self" } else if ($sig =~ '^[^(]*\(\s*[^,)]*Allocator') { "allocator" } else { "other" })
        let want_io = (if ($sig =~ "Io") { "yes" } else { "no" })
        let want_g = (if (($sig =~ "comptime ") or ($sig =~ "anytype")) { "yes" } else { "no" })
        if ($r.first_param == $want_fp) and ($r.io == $want_io) and ($r.generic == $want_g) { null } else { {path: $r.path, got: $"($r.first_param)/($r.io)/($r.generic)", want: $"($want_fp)/($want_io)/($want_g)", sig: $sig} }
    } | compact)
    print "── 3. consistency (labels re-derived from the raw sig, independently) ──"
    if ($mism | length) > 0 { print $"  ✗ ($mism | length) row\(s\) whose stored label ≠ re-derivation:"; $mism | first 5 | print; $ok = false } else { print "  ✓ every stored label matches an independent re-read of the signature" }

    print ""
    if $ok { print "SIGSHAPE VERDICT: ✓ overlay reconciles with the signatures" } else { print "SIGSHAPE VERDICT: ✗ reconciliation FAILED"; exit 1 }
}
