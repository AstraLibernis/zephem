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
# A pure JOIN of committed outputs — sigs + resolved — keyed by `path` (keyword-quoting
# normalised, the trick consensus uses). Self-checking. Writes data/std/callcard.tsv +
# SHA256SUMS.callcard; --check rebuilds byte-identical.
#
# Usage:  nu scripts/build_callcard.nu [--dir data/std]
#         nu scripts/build_callcard.nu --check

const MANIFEST = "data/std/SHA256SUMS.callcard"

# Strip Zig keyword-quoting so the parser's `@"x"` and the compiler's `x` key equal.
def norm-path [p: string] { $p | str replace --regex --all '@"([^"]+)"' '$1' }

def derive [dir: string] {
    for f in ["sigs.tsv" "resolved.tsv"] {
        if not ($"($dir)/($f)" | path exists) { print $"missing ($dir)/($f)"; exit 1 }
    }
    let sigs = (open $"($dir)/sigs.tsv" | select path sig | rename --column {path: spath} | insert np {|r| norm-path $r.spath})
    let res = (open $"($dir)/resolved.tsv" | where kind == "fn" | select path detail | uniq-by path | rename --column {path: rpath, detail: resolved} | insert np {|r| norm-path $r.rpath})
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
    if $check {
        if not ($MANIFEST | path exists) { print $"[callcard check] no ($MANIFEST) — build first"; exit 1 }
        let fresh = (derive $dir | to tsv)
        let want = (open $MANIFEST | lines | first | parse -r '(?<hash>\S+)' | get hash.0)
        let got = ($fresh | hash sha256)
        if $got == $want { print $"[callcard check] ✓ rebuilds byte-identical \(($got)\)" } else {
            print $"[callcard check] ✗ DRIFT — manifest ($want) vs rebuild ($got)"; exit 1
        }
        return
    }
    let rows = (derive $dir)
    $rows | to tsv | save -f $"($dir)/callcard.tsv"
    let n = ($rows | length)
    print $"[callcard] ($n) callables → ($dir)/callcard.tsv"
    $rows | group-by witness | items {|k, v| {witness: $k, n: ($v | length)}} | sort-by n --reverse | print
    let h = ($rows | to tsv | hash sha256)
    $"($h)  data/std/callcard.tsv\n" | save -f $MANIFEST
    print $"[callcard] manifest → ($MANIFEST)  \(run --check to prove it rebuilds\)"
}
