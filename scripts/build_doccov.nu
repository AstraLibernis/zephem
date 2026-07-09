#!/usr/bin/env nu
# build_doccov.nu — the documentation-coverage census: which nodes carry a `///` doc, which don't.
#
# The parser emits two source-only overlays — sigs.tsv (signatures) and docs.tsv (`///` docs). docs
# is sparse: most nodes have no doc-comment. This overlay JOINS the map to docs and tags EVERY node
# (decls AND fields/tags — fields can be documented too) documented/not, so the gaps are first-class
# data you can group by kind and by module. Read per-kind, not just the blended headline. One job.
#
#   doccov.tsv   path · kind · documented
#
#   documented = yes   a `///` doc-comment sits above this decl (path ∈ docs.tsv)
#                no    no doc-comment
#   kind        carried from the map, so coverage groups by struct/fn/const/… without a re-join.
#
# A pure JOIN of two committed outputs — nodes + docs — one row per map node, nothing invented.
# Self-checking. Writes data/std/derived/doccov.tsv + SHA256SUMS.doccov; --check rebuilds byte-identical.
#
# Usage:  nu scripts/build_doccov.nu [--dir data/std]
#         nu scripts/build_doccov.nu --check

const MANIFEST = "data/std/SHA256SUMS.doccov"
use lib.nu *   # check-manifest, write-manifest

def derive [dir: string] {
    for f in ["extracted/nodes.tsv" "extracted/attrs.tsv"] {
        if not ($"($dir)/($f)" | path exists) { print $"missing ($dir)/($f)"; exit 1 }
    }
    # left-join the map to the `doc` attrs (version-agnostic — no optional `get`); unmatched → no.
    let docs = (open $"($dir)/extracted/attrs.tsv" | where attr == "doc" | select path | uniq-by path | insert documented "yes")
    open $"($dir)/extracted/nodes.tsv" | select path kind | join --left $docs path | each {|r|
        {path: $r.path, kind: $r.kind, documented: ($r.documented | default "no")}
    } | sort-by path
}

def main [--dir: string = "data/std", --check] {
    if $check { check-manifest $MANIFEST (derive $dir | to tsv) "doccov"; return }
    let rows = (derive $dir)
    let tsv = ($rows | to tsv)
    $tsv | save -f $"($dir)/derived/doccov.tsv"
    let n = ($rows | length)
    let doc = ($rows | where documented == "yes" | length)
    let pct = (($doc * 100) / $n | math round | into int)
    print $"[doccov] ($n) nodes → ($dir)/derived/doccov.tsv"
    print $"  documented: ($doc)   undocumented: (($n) - ($doc))   \(($pct)% covered\)"
    $rows | group-by kind | items {|k, v| {kind: $k, total: ($v | length), documented: ($v | where documented == "yes" | length)}} | sort-by total --reverse | print
    write-manifest $tsv "data/std/derived/doccov.tsv" $MANIFEST
    print $"[doccov] manifest → ($MANIFEST)  \(run --check to prove it rebuilds\)"
}
