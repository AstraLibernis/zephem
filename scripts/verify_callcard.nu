#!/usr/bin/env nu
# verify_callcard.nu — reconcile the call-card against its two sources, the other way.
#
# build_callcard.nu joined sigs + resolved on the normalised path. This re-reads each source
# independently and proves the merged row can't drift from, or invent, what it claims:
#
#   1. CENSUS       one row per callable — |callcard| = |sigs-fns ∪ resolved-fns|, no dups, no orphans.
#   2. WITNESS      witness equals real membership: both = in both, parser-only / reflect-only = one.
#   3. CONTENT      sig equals sigs.tsv's sig for that path (""=absent); resolved equals resolved.tsv's
#                   detail. So presence ⟺ the right witness.
#
# Usage:  nu scripts/verify_callcard.nu [data/std]

def norm-path [p: string] { $p | str replace --regex --all '@"([^"]+)"' '$1' }

def main [dir: string = "data/std"] {
    for f in ["derived/callcard.tsv" "extracted/attrs.tsv" "extracted/resolved.tsv"] {
        if not ($"($dir)/($f)" | path exists) { print $"missing ($dir)/($f)"; exit 1 }
    }
    let cc = (open $"($dir)/derived/callcard.tsv")
    let sigs = (open $"($dir)/extracted/attrs.tsv" | where attr == "sig" | select path value | rename --column {value: sig} | insert np {|r| norm-path $r.path})
    let res = (open $"($dir)/extracted/resolved.tsv" | where kind == "fn" | select path detail | insert np {|r| norm-path $r.path} | uniq-by np)
    let sigByNp = ($sigs | reduce --fold {} {|r, acc| $acc | upsert $r.np $r.sig})
    let resByNp = ($res | reduce --fold {} {|r, acc| $acc | upsert $r.np $r.detail})
    let signp = ($sigs | get np)
    let resnp = ($res | get np)
    let union = (($signp ++ $resnp) | uniq | length)
    mut ok = true
    print $"callcard: ($cc | length) callables"

    # 1. CENSUS — one row per callable in the union of the two fn sets.
    let ccount = ($cc | length)
    let uniqn = ($cc | get path | uniq | length)
    print "── 1. census (one row per callable; |callcard| = |sigs ∪ resolved-fns|) ──"
    print $"  callcard ($ccount) vs union ($union)"
    if $ccount != $union { print "  ✗ row count ≠ union of the two fn sets"; $ok = false } else { print "  ✓ one row per callable" }
    if $uniqn != $ccount { print $"  ✗ (($ccount) - ($uniqn)) duplicate path\(s\)"; $ok = false } else { print "  ✓ no duplicate paths" }

    # 2 + 3. WITNESS + CONTENT — re-derive every field from the sources independently.
    let mism = ($cc | each {|r|
        let np = (norm-path $r.path)
        let s = ($sigByNp | get -o $np)
        let rv = ($resByNp | get -o $np)
        let inS = ($s != null)
        let inR = ($rv != null)
        let want_w = (if ($inS and $inR) { "both" } else if $inS { "parser-only" } else if $inR { "reflect-only" } else { "ABSENT" })
        let want_sig = ($s | default "")
        let want_res = ($rv | default "")
        if ($r.witness == $want_w) and ($r.sig == $want_sig) and ($r.resolved == $want_res) { null } else {
            {path: $r.path, witness: $"($r.witness)|($want_w)", sig_ok: ($r.sig == $want_sig), res_ok: ($r.resolved == $want_res)}
        }
    } | compact)
    print "── 2+3. witness + content (re-derived from sigs / resolved) ──"
    if ($mism | length) > 0 { print $"  ✗ ($mism | length) row\(s\) disagree with the sources:"; $mism | first 5 | print; $ok = false } else { print "  ✓ every witness, sig, and resolved field matches its source" }

    # presence ⟺ witness — a parser-only row must carry no resolved type, and vice-versa.
    let bad_presence = ($cc | where {|r|
        (($r.witness == "parser-only") and ($r.resolved != "")) or (($r.witness == "reflect-only") and ($r.sig != "")) or (($r.witness == "both") and (($r.sig == "") or ($r.resolved == "")))
    } | length)
    print "── presence ⟺ witness ──"
    if $bad_presence > 0 { print $"  ✗ ($bad_presence) row\(s\) whose filled fields contradict the witness"; $ok = false } else { print "  ✓ sig present ⟺ parser saw it; resolved present ⟺ reflect saw it" }

    print ""
    if $ok { print "CALLCARD VERDICT: ✓ overlay reconciles with sigs + resolved" } else { print "CALLCARD VERDICT: ✗ reconciliation FAILED"; exit 1 }
}
