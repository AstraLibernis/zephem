#!/usr/bin/env nu
# build_arch.nu — regenerate docs/architecture.html from the project itself.
#
# The viewer is a GENERATED artifact, not hand-authored: the structure/CSS live in
# docs/architecture.tmpl.html, and every number is injected live from data/std + the engine
# source line counts. So it can never drift from the data — and --check proves it byte-identical.
#
# Usage:  nu scripts/build_arch.nu            # regenerate docs/architecture.html
#         nu scripts/build_arch.nu --check    # prove it still matches the data (no write)

const TMPL = "docs/architecture.tmpl.html"
const OUT  = "docs/architecture.html"

# 12345 -> "12,345" (no lookahead in the regex engine, so group from the right by hand).
def commafy [n: int] {
    let rev = ($n | into string | split chars | reverse | str join)
    $rev | split chars | chunks 3 | each {|c| $c | str join } | str join "," | split chars | reverse | str join
}

def lc [path: string] { open --raw $path | lines | length }

# Build the filled HTML as a string from the live project state.
def render [] {
    let nodes = (open data/std/nodes.tsv)
    let n     = ($nodes | length)
    let files = ($nodes | where kind == "ns" | length)
    let depth = ($nodes | get depth | math max)

    # kind distribution → data-driven bar rows (widths relative to the largest kind)
    let kinds = ($nodes | group-by kind | items {|k, v| {kind: $k, n: ($v | length)} } | sort-by n --reverse)
    let kmax  = ($kinds | get n | math max)
    let kbars = ($kinds | each {|r|
        let raw = ((($r.n * 100) / $kmax) | math round | into int)
        let pct = (if $raw < 1 { 1 } else { $raw })
        $'        <div class="kbar"><span class="kname">($r.kind)</span><span class="ktrack"><span class="kfill" style="width:($pct)%"></span></span><span class="kn">(commafy $r.n)</span></div>'
    } | str join "\n")

    let status   = (open data/std/status.tsv)
    let res_cont = ($status | where status == "resolved" | length)
    let poison   = ($status | where status == "poison" | length)
    let resolved = (open data/std/resolved.tsv | length)
    let index    = (open data/std/index.tsv | length)

    let canon    = (open data/std/canon.tsv)
    let subs = {
        "@@ZIG@@":            (open data/std/PINNED | str trim)
        "@@N_NODES@@":        (commafy $n)
        "@@N_FILES@@":        (commafy $files)
        "@@MAXDEPTH@@":       ($depth | into string)
        "@@N_RESOLVED@@":     (commafy $resolved)
        "@@N_RES_CONT@@":     (commafy $res_cont)
        "@@N_POISON@@":       (commafy $poison)
        "@@N_INDEX@@":        (commafy $index)
        "@@N_CANON@@":        (commafy ($canon | length))
        "@@CANON_RR@@":       (commafy ($canon | where origin == "read+run" | length))
        "@@CANON_RUNONLY@@":  (commafy ($canon | where origin == "run-only" | length))
        "@@CANON_READONLY@@": (commafy ($canon | where origin == "read-only" | length))
        "@@LC_BUILD@@":       ((lc "parse/build.zig") | into string)
        "@@LC_WALK@@":        ((lc "parse/walk.zig") | into string)
        "@@LC_AST@@":         ((lc "parse/ast.zig") | into string)
        "@@LC_RESOLVE@@":     ((lc "reflect/resolve.zig") | into string)
        "@@LC_INDEX@@":       ((lc "derive/index.zig") | into string)
        "@@KIND_BARS@@":      $kbars
    }

    mut html = (open --raw $TMPL)
    for k in ($subs | columns) { $html = ($html | str replace --all $k ($subs | get $k)) }
    $html
}

def main [--check] {
    let html = (render)
    let left = ($html | find "@@" | length)
    if $left > 0 { print $"arch: ✗ ($left) unfilled @@TOKEN@@ line\(s\) remain — template/generator out of sync"; exit 1 }

    if $check {
        if not ($OUT | path exists) { print $"arch: ✗ ($OUT) missing — run without --check"; exit 1 }
        if $html == (open --raw $OUT) {
            print "arch: ✓ regenerates byte-identical from data/std + engine source"
        } else {
            print "arch: ✗ DRIFT — docs/architecture.html no longer matches the data; rerun build_arch.nu"
            exit 1
        }
        return
    }
    $html | save -f $OUT
    print $"arch: ✓ regenerated ($OUT) from data/std + engine source"
}
