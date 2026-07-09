#!/usr/bin/env nu
# build_callcard.nu — the call-card: one row per callable, MERGING the two witnesses' views of it.
#
# The parser sees a fn's NAME, param names, doc, and its as-written signature (`@This()`, `Self`).
# Reflection sees the same fn's RESOLVED types (`@This()` → the real type, concrete error sets) but
# loses the names. Neither half is complete; joined on `path` they're a full card for the callable.
# This is the sigs ⋈ resolved join PLAN.md calls the call-card. One job.
#
#   callcard.tsv   path · witness · sig · resolved
#
#   witness = both          parser AND reflect saw it — full card (names + resolved types)
#             parser-only   written sig, but the compiler couldn't build it here (poison / gated /
#                           uninstantiated generic) → no resolved types
#             reflect-only  compiler-manufactured (a generic instantiation / synthesised member) →
#                           resolved types but no as-written name
#   sig        the parser's as-written signature ("" when reflect-only)
#   resolved   reflection's resolved fn type   ("" when parser-only)
#
# (doc coverage is doccov's job; join it on path if you want it — kept out to avoid duplication.)
#
# A pure JOIN of committed outputs — attrs[sig] + resolved — keyed by `path` (keyword-quoting
# normalised, the trick consensus uses). Self-checking. Writes data/std/derived/callcard.tsv +
# SHA256SUMS.callcard; --check rebuilds byte-identical.
#
# Usage:  nu scripts/build_callcard.nu [--dir data/std]
#         nu scripts/build_callcard.nu --check

const MANIFEST = "data/std/SHA256SUMS.callcard"
use lib.nu *   # norm-path, check-manifest, write-manifest

def derive [dir: string] {
    for f in ["extracted/attrs.tsv" "extracted/resolved.tsv"] {
        if not ($"($dir)/($f)" | path exists) { print $"missing ($dir)/($f)"; exit 1 }
    }
    let sigs = (open $"($dir)/extracted/attrs.tsv" | where attr == "sig" | select path value | rename --column {path: spath, value: sig} | insert np {|r| norm-path $r.spath})
    let res = (open $"($dir)/extracted/resolved.tsv" | where kind == "fn" | select path detail | uniq-by path | rename --column {path: rpath, detail: resolved} | insert np {|r| norm-path $r.rpath})
    $sigs | join --outer $res np | each {|r|
        let path = (if $r.spath != null { $r.spath } else { $r.rpath })
        let witness = (if (($r.spath != null) and ($r.rpath != null)) { "both" } else if ($r.spath != null) { "parser-only" } else { "reflect-only" })
        {
            path: $path,
            witness: $witness,
            sig: ($r.sig | default ""),
            resolved: ($r.resolved | default ""),
        }
    } | sort-by path
}

def main [--dir: string = "data/std", --check] {
    if $check { check-manifest $MANIFEST (derive $dir | to tsv) "callcard"; return }
    let rows = (derive $dir)
    let tsv = ($rows | to tsv)
    $tsv | save -f $"($dir)/derived/callcard.tsv"
    let n = ($rows | length)
    print $"[callcard] ($n) callables → ($dir)/derived/callcard.tsv"
    $rows | group-by witness | items {|k, v| {witness: $k, n: ($v | length)}} | sort-by n --reverse | print
    write-manifest $tsv "data/std/derived/callcard.tsv" $MANIFEST
    print $"[callcard] manifest → ($MANIFEST)  \(run --check to prove it rebuilds\)"
}
