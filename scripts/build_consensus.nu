#!/usr/bin/env nu
# build_consensus.nu — the consensus overlay: COMPARE the two witnesses, HIGHLIGHT the differences.
#
# parse/ reads source text; reflect/ runs the compiler. They share no method, so where both land on
# the same path that AGREEMENT is independent evidence — and where only one sees a path, that
# DIFFERENCE is the interesting edge. This overlay compares the two and tags every path. One job.
#
#   consensus.tsv   path · origin · owner
#
#   origin = read+run   both saw it     — AGREEMENT: the parser read it AND the compiler made it
#            read-only  parser only     — the compiler can't build it here (poison / platform / root)
#            run-only   compiler only   — a member the compiler manufactures (a generic/alias's
#                                         resolved decl) that the text recorded only as a leaf
#   owner  = the parent path it hangs off in the readable map (drop the last segment); empty for root.
#
# read-only and run-only ARE the differences; read+run is the agreement. A pure JOIN of the two
# committed outputs — nodes + resolved — and nothing else: poison.tsv isn't needed, since read-only
# is simply "in nodes, not in resolved". Self-checking. Writes data/std/derived/consensus.tsv +
# SHA256SUMS.consensus; --check rebuilds.
#
# Usage:  nu scripts/build_consensus.nu [--dir data/std]
#         nu scripts/build_consensus.nu --check

const MANIFEST = "data/std/SHA256SUMS.consensus"
use lib.nu *   # norm-path, check-manifest, write-manifest

# The path's parent (drop the last dotted segment); "" for a single-segment root.
def parent-of [p: string] { $p | split row "." | drop 1 | str join "." }

def derive [dir: string] {
    for f in ["extracted/nodes.tsv" "extracted/resolved.tsv"] {
        if not ($"($dir)/($f)" | path exists) { print $"missing ($dir)/($f)"; exit 1 }
    }
    # Two universes are out of the compare's scope, because the reflect layer never resolves them
    # as their own paths (they'd all land in "read-only" and drown the real signal):
    #   • field/tag rows — struct/union slots, enum tags (structural members);
    #   • factory members — `…()` paths (a generic's members are uninstantiated here; resolving
    #     them is Phase D). A `(` in a path marks one.
    # The two engines only both speak about DECLS/CONTAINERS, so compare on those.
    let nodes = (open $"($dir)/extracted/nodes.tsv" | where kind not-in ["field" "tag"] | where {|r| not ($r.path | str contains "(")} | select path | insert np {|r| norm-path $r.path} | rename --column {path: ppath})
    let res = (open $"($dir)/extracted/resolved.tsv" | select path | uniq-by path | insert np {|r| norm-path $r.path} | rename --column {path: cpath})
    $nodes | join --outer $res np | each {|r|
        let path = (if $r.ppath != null { $r.ppath } else { $r.cpath })
        let origin = (if ($r.ppath != null and $r.cpath != null) { "read+run" } else if ($r.cpath != null) { "run-only" } else { "read-only" })
        {path: $path, origin: $origin, owner: (parent-of $path)}
    } | sort-by path
}

def main [--dir: string = "data/std", --check] {
    if $check { check-manifest $MANIFEST (derive $dir | to tsv) "consensus"; return }
    let rows = (derive $dir)
    let tsv = ($rows | to tsv)
    $tsv | save -f $"($dir)/derived/consensus.tsv"
    let n = ($rows | length)
    let agree = ($rows | where origin == "read+run" | length)
    print $"[consensus] ($n) paths → ($dir)/derived/consensus.tsv"
    print $"  AGREEMENT  read+run: ($agree)"
    print $"  DIFFERENCES: (($n) - ($agree)) ="
    $rows | where origin != "read+run" | group-by origin | items {|k, v| {origin: $k, n: ($v | length)}} | sort-by n --reverse | print
    write-manifest $tsv "data/std/derived/consensus.tsv" $MANIFEST
    print $"[consensus] manifest → ($MANIFEST)  \(run --check to prove it rebuilds\)"
}
