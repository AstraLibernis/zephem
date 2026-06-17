#!/usr/bin/env nu
# cluster_shapes.nu — cluster the structural map by SHAPE (count-signature) with
# explicit, verifiable rules, then render a dependency-free SVG to view on Codeberg.
#
# Shape = (n_types, n_fns, n_consts, n_fields). Rules are printed in docs/clusters.md
# so the grouping is auditable, not opaque.
#
# Inputs:  data/crypto_tree.tsv
# Outputs: data/clusters.tsv, docs/clusters.svg, docs/clusters.md

# --- shape rules (first match wins) ---
def classify [r] {
    if $r.n_fns >= 13 { "math"
    } else if $r.n_types >= 1 and $r.n_fns == 0 and $r.n_consts == 0 and $r.n_fields == 0 { "namespace"
    } else if $r.n_types >= 1 { "scheme"
    } else if $r.n_fns == 0 and ($r.n_fields >= 1 or $r.kind == "enum") { "config"
    } else if $r.n_fields >= 1 and $r.n_fns >= 1 { "stateful"
    } else if $r.n_fields == 0 and $r.n_fns >= 1 { "ops"
    } else { "other" }
}

# deterministic jitter in [-span/2, span/2] from a path hash. Parse hex digit by
# digit — `into int --radix 16` on a multi-char slice misreads a leading "0b".
def jit [path: string, span: float] {
    let h = ($path | hash md5 | split chars | first 6 | each {|c| $c | into int --radix 16 } | reduce --fold 0 {|it, acc| $acc * 16 + $it })
    ((($h mod 1000) / 1000.0) - 0.5) * $span
}

const LABELS = {
    math: "Field / curve math", scheme: "Containers w/ own API",
    namespace: "Namespaces (pure containers)", config: "Config and data",
    stateful: "Stateful primitives", ops: "Stateless operations",
    other: "Empty marker structs",
}
const COLORS = {
    math: "#e4572e", scheme: "#4a6fa5", namespace: "#17bebb", config: "#f3a712",
    stateful: "#8e44ad", ops: "#2e9e5b", other: "#9aa0a6",
}

# plot geometry
const W = 1200
const H = 900
const PX = 70
const PY = 110
const PW = 700
const PH = 540
const FX = 22.0      # x axis max (n_fns)
const FY = 24.0      # y axis max (structure = types+consts+fields)

def main [] {
    let rows = (open data/crypto_tree.tsv | insert cl {|r| classify $r } | insert struct {|r| $r.n_types + $r.n_consts + $r.n_fields })

    $rows | select path cl | rename path cluster | save -f data/clusters.tsv
    let counts = ($rows | group-by cl | items {|k, v| {cl: $k, n: ($v | length)} })
    print "cluster counts:"
    print $counts

    # ---- build SVG (single-quoted attrs to avoid escaping) ----
    mut s = [
        $"<svg xmlns='http://www.w3.org/2000/svg' width='($W)' height='($H)' viewBox='0 0 ($W) ($H)' font-family='Inter,Segoe UI,Helvetica,Arial,sans-serif'>"
        $"<rect width='($W)' height='($H)' fill='#fbfbfd'/>"
        $"<text x='($PX)' y='44' font-size='26' font-weight='700' fill='#1a1a2e'>std.crypto — 400 containers clustered by structural shape</text>"
        $"<text x='($PX)' y='72' font-size='14' fill='#5f6368'>x = functions \(behaviour\), y = structure \(sub-types + consts + fields\); bubble size = total decls; colour = shape cluster. Zig 0.16, by reflection.</text>"
    ]

    # gridlines + axis ticks
    for gx in (seq 0 2 22) {
        let x = ($PX + ($gx / $FX) * $PW)
        $s = ($s | append $"<line x1='($x)' y1='($PY)' x2='($x)' y2='($PY + $PH)' stroke='#eceff3'/>")
        $s = ($s | append $"<text x='($x)' y='($PY + $PH + 18)' font-size='11' fill='#9aa0a6' text-anchor='middle'>($gx)</text>")
    }
    for gy in (seq 0 4 24) {
        let y = ($PY + $PH - ($gy / $FY) * $PH)
        $s = ($s | append $"<line x1='($PX)' y1='($y)' x2='($PX + $PW)' y2='($y)' stroke='#eceff3'/>")
        $s = ($s | append $"<text x='($PX - 10)' y='($y + 4)' font-size='11' fill='#9aa0a6' text-anchor='end'>($gy)</text>")
    }
    $s = ($s | append $"<text x='($PX + $PW / 2)' y='($PY + $PH + 42)' font-size='13' fill='#5f6368' text-anchor='middle'>number of functions →</text>")
    let ymid = ($PY + $PH / 2)
    $s = ($s | append $"<text x='22' y='($ymid)' font-size='13' fill='#5f6368' text-anchor='middle' transform='rotate\(-90 22 ($ymid)\)'>structure: sub-types + consts + fields →</text>")

    # points — big first so small sit on top
    let pts = ($rows | sort-by struct -r | each {|r|
        let fx = ([$r.n_fns 22] | math min)
        let fy = ([$r.struct 24] | math min)
        let cx = (($PX + ($fx / $FX) * $PW) + (jit $r.path 16.0) | math round --precision 1)
        let cy = (($PY + $PH - ($fy / $FY) * $PH) + (jit $"($r.path)y" 16.0) | math round --precision 1)
        let rad = (3 + 2.0 * ($r.n_decls | math sqrt) | math round --precision 1)
        let col = ($COLORS | get $r.cl)
        $"<circle cx='($cx)' cy='($cy)' r='($rad)' fill='($col)' fill-opacity='0.62' stroke='($col)' stroke-opacity='0.9' stroke-width='0.8'/>"
    })
    $s = ($s | append $pts)

    # legend
    let lx = ($PX + $PW + 30)
    mut ly = ($PY + 6)
    $s = ($s | append $"<text x='($lx)' y='($ly)' font-size='15' font-weight='700' fill='#1a1a2e'>Clusters</text>")
    $ly = ($ly + 22)
    for cid in [math scheme namespace config stateful ops other] {
        let n = ($rows | where cl == $cid | length)
        let col = ($COLORS | get $cid)
        let lab = ($LABELS | get $cid)
        $s = ($s | append $"<circle cx='($lx + 8)' cy='($ly - 4)' r='7' fill='($col)' fill-opacity='0.75' stroke='($col)'/>")
        $s = ($s | append $"<text x='($lx + 24)' y='($ly)' font-size='13' fill='#222'>($lab)</text>")
        $s = ($s | append $"<text x='($lx + 24)' y='($ly + 15)' font-size='11' fill='#80868b'>($n) nodes</text>")
        $ly = ($ly + 40)
    }

    # cluster summary cards
    let cy0 = ($PY + $PH + 70)
    $s = ($s | append $"<text x='($PX)' y='($cy0 - 12)' font-size='15' font-weight='700' fill='#1a1a2e'>Shape signature per cluster \(mean t/f/c/fld\) + examples</text>")
    let order = [namespace scheme stateful ops config math other]
    let cw = (($W - 2 * $PX) / ($order | length))
    for i in 0..(($order | length) - 1) {
        let cid = ($order | get $i)
        let items = ($rows | where cl == $cid)
        let x = ($PX + $i * $cw)
        let col = ($COLORS | get $cid)
        let mt = ($items | get n_types | math avg | math round)
        let mf = ($items | get n_fns | math avg | math round)
        let mc = ($items | get n_consts | math avg | math round)
        let mfl = ($items | get n_fields | math avg | math round)
        $s = ($s | append $"<rect x='($x + 4)' y='($cy0)' width='($cw - 8)' height='118' rx='8' fill='#ffffff' stroke='($col)' stroke-opacity='0.5'/>")
        $s = ($s | append $"<rect x='($x + 4)' y='($cy0)' width='($cw - 8)' height='6' rx='3' fill='($col)'/>")
        $s = ($s | append $"<text x='($x + 14)' y='($cy0 + 26)' font-size='12.5' font-weight='700' fill='#222'>($LABELS | get $cid)</text>")
        $s = ($s | append $"<text x='($x + 14)' y='($cy0 + 44)' font-size='11' fill='#5f6368'>($items | length) nodes · t($mt) f($mf) c($mc) fld($mfl)</text>")
        mut yy = ($cy0 + 64)
        for r in ($items | sort-by n_decls -r | first 3) {
            let nm0 = ($r.path | str replace "crypto." "")
            let nm = (if ($nm0 | str length) > 30 { $"($nm0 | str substring 0..29)…" } else { $nm0 })
            $s = ($s | append $"<text x='($x + 14)' y='($yy)' font-size='10' fill='#80868b'>($nm)</text>")
            $yy = ($yy + 15)
        }
    }
    $s = ($s | append "</svg>")
    $s | str join "\n" | save -f docs/clusters.svg
    print "docs/clusters.svg written"

    # ---- clusters.md ----
    let rules = "f>=13                                  -> math      (field/curve arithmetic)
types>=1 & f==0 & c==0 & fld==0        -> namespace (pure container of types)
types>=1                               -> scheme    (container + its own api/consts)
f==0 & (fld>=1 | enum)                 -> config    (options, enums, results)
fld>=1 & f>=1                          -> stateful  (state + methods)
fld==0 & f>=1                          -> ops       (methods, no state)
else                                   -> other     (empty marker structs)"
    mut md = ["# std.crypto shape clusters" "" "Every one of the 400 mapped containers, grouped by its structural **count-signature** `(sub-types, functions, consts, fields)` using the explicit rules below (first match wins). No semantic guessing — pure shape." "" "![clusters](clusters.svg)" "" "> If the image doesn't render inline, open **`docs/clusters.svg`** directly." "" "## Rules" "" "```" $rules "```" "" "## Counts" "" "| cluster | nodes |" "|---|---|"]
    for cid in [scheme stateful ops config namespace math other] {
        let n = ($rows | where cl == $cid | length)
        $md = ($md | append $"| ($LABELS | get $cid) | ($n) |")
    }
    $md = ($md | append ["" "*Generated by `scripts/cluster_shapes.nu` from `data/crypto_tree.tsv` (Zig 0.16, 2026-06-17). Cluster assignments in `data/clusters.tsv`.*"])
    $md | str join "\n" | save -f docs/clusters.md
    print "docs/clusters.md written"
}
