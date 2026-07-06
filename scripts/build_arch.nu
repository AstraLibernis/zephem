#!/usr/bin/env nu
# build_arch.nu — regenerate the docs site (hub + per-slice pages) from the project itself.
#
# Nothing here is hand-authored: structure lives in docs/*.tmpl.html + docs/views/*.tmpl.html,
# styling in docs/style.css, and EVERY number/chart/row is injected live from data/std + the
# engine source. So the pages can never drift from the data — and --check proves each one
# byte-identical across a fresh rebuild. Charts are generated CSS bars (no JS, no fetch), so the
# whole site works straight off the filesystem and updates the moment the data does.
#
# Usage:  nu scripts/build_arch.nu            # regenerate every page
#         nu scripts/build_arch.nu --check    # prove each still matches the data (no write)

const PAGES = [
  [tmpl, out];
  ["docs/architecture.tmpl.html",     "docs/architecture.html"]
  ["docs/views/index.tmpl.html",      "docs/views/index.html"]
  ["docs/views/canon.tmpl.html",      "docs/views/canon.html"]
  ["docs/views/consensus.tmpl.html",  "docs/views/consensus.html"]
  ["docs/views/doccov.tmpl.html",     "docs/views/doccov.html"]
  ["docs/views/sigshape.tmpl.html",   "docs/views/sigshape.html"]
  ["docs/views/callcard.tmpl.html",   "docs/views/callcard.html"]
]

# The hand-written markdown docs, brought under the SAME no-drift discipline as the HTML
# pages: prose lives in the .tmpl.md, every number is an @@TOKEN@@ injected from data/std.
# They fill from the shared `common` record only (no page-specific charts/rows).
const MD_PAGES = [
  [tmpl, out];
  ["README.tmpl.md",        "README.md"]
  ["PLAN.tmpl.md",          "PLAN.md"]
  ["parse/README.tmpl.md",  "parse/README.md"]
  ["data/README.tmpl.md",   "data/README.md"]
]

# 12345 -> "12,345" (no lookahead in the regex engine, so group from the right by hand).
def commafy [n: int] {
    let rev = ($n | into string | split chars | reverse | str join)
    $rev | split chars | chunks 3 | each {|c| $c | str join } | str join "," | split chars | reverse | str join
}
def lc [path: string] { open --raw $path | lines | length }

# Escape the three HTML-significant chars so data (poison reasons hold `<gen>`, `&`) renders verbatim.
def esc [s: string] { $s | str replace --all "&" "&amp;" | str replace --all "<" "&lt;" | str replace --all ">" "&gt;" }

# A list of {k: label, v: count} -> label-on-top CSS bar rows, widths relative to the largest.
def lbars [items: list, cls: string = ""] {
    if ($items | is-empty) { return "" }
    let mx = ($items | get v | math max)
    $items | each {|r|
        let raw = ((($r.v * 100) / $mx) | math round | into int)
        let pct = (if $raw < 1 { 1 } else { $raw })
        $'    <div class="lbar ($cls)"><div class="lt"><span class="lk">(esc ($r.k | into string))</span><span class="lv">(commafy $r.v)</span></div><div class="ltrack"><span class="lfill" style="width:($pct)%"></span></div></div>'
    } | str join "\n"
}

# 2nd path segment = top-level module under std ("(root)" for bare `std`).
def module-of [p: string] { let s = ($p | split row "."); if ($s | length) >= 2 { $s | get 1 } else { "(root)" } }

# Generalise a poison reason to its error CATEGORY: text after `error:`, quoted names -> '…', tail dropped.
def errcat [reason: string] {
    let after = (if ($reason | str contains "error:") { $reason | split row "error:" | last | str trim } else { $reason })
    $after | str replace --regex --all "'[^']*'" "'…'" | split row ";" | first | str trim
}

# Fill one template's @@TOKEN@@s from a {token: value} record.
def fill [tmpl: string, subs: record] {
    mut html = (open --raw $tmpl)
    for k in ($subs | columns) { $html = ($html | str replace --all $k ($subs | get $k)) }
    $html
}

# Compute every page's filled HTML from the live project state. Returns [{out, html}].
def render [] {
    let nodes = (open data/std/nodes.tsv)
    let index = (open data/std/index.tsv)
    let canon = (open data/std/canon.tsv)
    let consensus = (open data/std/consensus.tsv)
    let status = (open data/std/status.tsv)
    let poison = (open data/std/poison.tsv)
    let doccov = (open data/std/doccov.tsv)
    let sigshape = (open data/std/sigshape.tsv)
    let callcard = (open data/std/callcard.tsv)

    let n     = ($nodes | length)
    let files = ($nodes | where kind == "ns" | length)
    let depth = ($nodes | get depth | math max)

    # doccov — documentation coverage
    let dc_total = ($doccov | length)
    let dc_doc   = ($doccov | where documented == "yes" | length)
    let dc_pct   = (($dc_doc * 100) / $dc_total | math round | into int)

    # sigshape — signature shapes
    let sg_total = ($sigshape | length)
    let sg_self  = ($sigshape | where first_param == "self" | length)
    let sg_none  = ($sigshape | where first_param == "none" | length)
    let sg_alloc = ($sigshape | where first_param == "allocator" | length)
    let sg_other = ($sigshape | where first_param == "other" | length)
    let sg_io    = ($sigshape | where io == "yes" | length)
    let sg_gen   = ($sigshape | where generic == "yes" | length)

    # callcard — the sigs ⋈ resolved merge
    let cc_total   = ($callcard | length)
    let cc_both    = ($callcard | where witness == "both" | length)
    let cc_parser  = ($callcard | where witness == "parser-only" | length)
    let cc_reflect = ($callcard | where witness == "reflect-only" | length)

    # hub: kind distribution across the whole map (.kbar style)
    let kinds = ($nodes | group-by kind | items {|k, v| {kind: $k, n: ($v | length)} } | sort-by n --reverse)
    let kmax  = ($kinds | get n | math max)
    let kbars = ($kinds | each {|r|
        let raw = ((($r.n * 100) / $kmax) | math round | into int)
        let pct = (if $raw < 1 { 1 } else { $raw })
        $'        <div class="kbar"><span class="kname">($r.kind)</span><span class="ktrack"><span class="kfill" style="width:($pct)%"></span></span><span class="kn">(commafy $r.n)</span></div>'
    } | str join "\n")

    # canon families
    let families = ($canon | group-by canon | items {|k, v| {canon: $k, n: ($v | length)} })
    let canon_max = (if ($families | is-empty) { 0 } else { $families | get n | math max })

    # consensus split
    let con_ro = ($consensus | where origin == "read-only" | length)
    let con_run = ($consensus | where origin == "run-only" | length)
    let con_rr = ($consensus | where origin == "read+run" | length)
    let con_total = ($consensus | length)
    let con_diff = ($con_ro + $con_run)

    # ── shared tokens (used across pages) ──
    let common = {
        "@@ZIG@@":            (open data/std/PINNED | str trim)
        "@@N_NODES@@":        (commafy $n)
        "@@N_FILES@@":        (commafy $files)
        "@@MAXDEPTH@@":       ($depth | into string)
        "@@N_RESOLVED@@":     (commafy (open data/std/resolved.tsv | length))
        "@@N_RES_CONT@@":     (commafy ($status | where status == "resolved" | length))
        "@@N_POISON@@":       (commafy ($poison | length))
        "@@N_INDEX@@":        (commafy ($index | length))
        "@@N_SIGS@@":         (commafy (open data/std/sigs.tsv | length))
        "@@N_DOCS@@":         (commafy (open data/std/docs.tsv | length))
        "@@N_FIELDS@@":       (commafy (open data/std/fields.tsv | length))
        "@@N_FN@@":           (commafy ($nodes | where kind == "fn" | length))
        "@@N_NSREF@@":        (commafy ($nodes | where kind == "nsref" | length))
        "@@N_EDGES@@":        (commafy ($n - 1))
        # raw (un-commafied) variants — for sample console transcripts that must match
        # what build_std.nu actually prints (it prints plain ints, no thousands separators).
        "@@N_NODES_RAW@@":    ($n | into string)
        "@@N_INDEX_RAW@@":    (($index | length) | into string)
        "@@N_EDGES_RAW@@":    (($n - 1) | into string)
        # std.crypto's own index coordinates (illustrative ranged-read example in README)
        "@@CRYPTO_LINE@@":    (($index | where path == "std.crypto" | get line.0) | into string)
        "@@CRYPTO_SPAN@@":    (($index | where path == "std.crypto" | get span.0) | into string)
        "@@N_CANON@@":        (commafy ($canon | length))
        "@@CANON_FAMILIES@@": (commafy ($families | length))
        "@@N_CONSENSUS@@":    (commafy $con_total)
        "@@CON_RR@@":         (commafy $con_rr)
        "@@CON_RUNONLY@@":    (commafy $con_run)
        "@@CON_READONLY@@":   (commafy $con_ro)
        "@@CON_DIFF@@":       (commafy $con_diff)
        "@@LC_BUILD@@":       ((lc "parse/build.zig") | into string)
        "@@LC_WALK@@":        ((lc "parse/walk.zig") | into string)
        "@@LC_AST@@":         ((lc "parse/ast.zig") | into string)
        "@@LC_RESOLVE@@":     ((lc "reflect/resolve.zig") | into string)
        "@@LC_INDEX@@":       ((lc "derive/index.zig") | into string)
        "@@DOC_DOCUMENTED@@": (commafy $dc_doc)
        "@@DOC_UNDOC@@":      (commafy ($dc_total - $dc_doc))
        "@@DOC_PCT@@":        ($dc_pct | into string)
        "@@DOC_UNDOC_PCT@@":  ((100 - $dc_pct) | into string)
        "@@N_SIGSHAPE@@":     (commafy $sg_total)
        "@@SIG_METHODS@@":    (commafy $sg_self)
        "@@SIG_IO@@":         (commafy $sg_io)
        "@@SIG_GENERIC@@":    (commafy $sg_gen)
        "@@N_CALLCARD@@":     (commafy $cc_total)
        "@@CC_BOTH@@":        (commafy $cc_both)
        "@@CC_PARSER@@":      (commafy $cc_parser)
        "@@CC_REFLECT@@":     (commafy $cc_reflect)
    }

    # ── hub ──
    let hub = ($common | merge { "@@KIND_BARS@@": $kbars })

    # ── index slice ──
    let idx_depth = ($index | group-by depth | items {|k, v| {k: $"depth ($k)", v: ($v | length), d: ($k | into int)} } | sort-by d)
    let idx_kind  = ($index | group-by kind  | items {|k, v| {k: $k, v: ($v | length)} } | sort-by v --reverse)
    let idx_big   = ($index | sort-by span --reverse | first 15 | each {|r|
        $'      <tr><td class="mono">(esc $r.path)</td><td class="num">(commafy $r.span)</td><td class="dim">($r.depth)</td><td class="dim">(esc $r.kind)</td></tr>'
    } | str join "\n")
    let idx = ($common | merge {
        "@@IDX_DEPTH_BARS@@": (lbars $idx_depth)
        "@@IDX_KIND_BARS@@":  (lbars $idx_kind)
        "@@IDX_BIG_ROWS@@":   $idx_big
    })

    # ── canon slice ──
    let fam_sizes = ($families | group-by n | items {|k, v| {k: $"($k) paths", v: ($v | length), sz: ($k | into int)} } | sort-by sz)
    let canon_mod = ($canon | insert m {|r| module-of $r.path } | group-by m
        | items {|k, v| {k: $k, v: ($v | length)} } | sort-by v --reverse | first 12)
    let canon_rows = ($families | sort-by n --reverse | first 12 | each {|r|
        let label = (if ($r.canon | str length) > 64 { ($r.canon | str substring 0..63) + "…" } else { $r.canon })
        $'      <tr><td class="mono">(esc $label)</td><td class="num">×($r.n)</td></tr>'
    } | str join "\n")
    let canonp = ($common | merge {
        "@@CANON_COLLAPSE@@":   (commafy (($canon | length) - ($families | length)))
        "@@CANON_MAX@@":        (commafy $canon_max)
        "@@CANON_SIZE_BARS@@":  (lbars $fam_sizes)
        "@@CANON_MODULE_BARS@@":(lbars $canon_mod)
        "@@CANON_FAMILY_ROWS@@":$canon_rows
    })

    # ── consensus slice ──
    let diff_rows = ($consensus | where origin != "read+run" | insert mod {|r| module-of $r.path }
        | group-by mod | items {|k, v| {mod: $k, n: ($v | length), ro: ($v | where origin == "read-only" | length), run: ($v | where origin == "run-only" | length)} }
        | sort-by n --reverse | first 12 | each {|r|
            $'      <tr><td class="mono">std.($r.mod)</td><td class="num">($r.n)</td><td class="dim">($r.ro)</td><td class="dim">($r.run)</td></tr>'
    } | str join "\n")
    let perr = ($poison | insert cat {|r| errcat $r.reason } | group-by cat
        | items {|k, v| {k: $k, v: ($v | length)} } | sort-by v --reverse | first 10)
    let poison_rows = ($poison | each {|r|
        $'      <tr><td class="mono">(esc $r.path)</td><td class="dim">(esc $r.reason)</td></tr>'
    } | str join "\n")
    let conp = ($common | merge {
        "@@CON_RO_PCT@@":          (($con_ro * 100 / $con_total) | math round | into int | into string)
        "@@CON_RR_PCT@@":          (($con_rr * 100 / $con_total) | math round | into int | into string)
        "@@CON_RUN_PCT@@":         (($con_run * 100 / $con_total) | math round | into int | into string)
        "@@CONSENSUS_DIFF_ROWS@@": $diff_rows
        "@@POISON_ERR_BARS@@":     (lbars $perr "ro")
        "@@POISON_ROWS@@":         $poison_rows
    })

    # ── doccov slice ──
    let dc_kind_rows = ($doccov | group-by kind | items {|k, v| {kind: $k, total: ($v | length), doc: ($v | where documented == "yes" | length)} }
        | sort-by total --reverse | each {|r|
            let pct = (($r.doc * 100) / $r.total | math round | into int)
            $'      <tr><td class="mono">($r.kind)</td><td class="num">(commafy $r.total)</td><td class="dim">(commafy $r.doc)</td><td class="num">($pct)%</td></tr>'
    } | str join "\n")
    let dc_mod_rows = ($doccov | insert m {|r| module-of $r.path } | group-by m
        | items {|k, v| {m: $k, total: ($v | length), doc: ($v | where documented == "yes" | length)} }
        | sort-by total --reverse | first 14 | each {|r|
            let pct = (($r.doc * 100) / $r.total | math round | into int)
            $'      <tr><td class="mono">std.($r.m)</td><td class="num">(commafy $r.total)</td><td class="dim">(commafy $r.doc)</td><td class="num">($pct)%</td></tr>'
    } | str join "\n")
    let doccovp = ($common | merge {
        "@@DOCCOV_KIND_ROWS@@":   $dc_kind_rows
        "@@DOCCOV_MODULE_ROWS@@": $dc_mod_rows
    })

    # ── sigshape slice ──
    let fp = ([{k: "other (free fn)", v: $sg_other} {k: "self (method)", v: $sg_self} {k: "none (niladic)", v: $sg_none} {k: "allocator", v: $sg_alloc}] | sort-by v --reverse)
    let sg_fp_bars = (lbars $fp)
    let traits = [{t: "method (self-first)", n: $sg_self} {t: "Io-threading", n: $sg_io} {t: "generic (comptime/anytype)", n: $sg_gen} {t: "niladic (no params)", n: $sg_none}]
    let sg_trait_rows = ($traits | each {|r|
        let pct = (($r.n * 100) / $sg_total | math round | into int)
        $'      <tr><td class="mono">($r.t)</td><td class="num">(commafy $r.n)</td><td class="num">($pct)%</td></tr>'
    } | str join "\n")
    let sg_mod_rows = ($sigshape | insert m {|r| module-of $r.path } | group-by m
        | items {|k, v| {m: $k, n: ($v | length), gen: ($v | where generic == "yes" | length), io: ($v | where io == "yes" | length)} }
        | sort-by n --reverse | first 14 | each {|r|
            $'      <tr><td class="mono">std.($r.m)</td><td class="num">(commafy $r.n)</td><td class="dim">(commafy $r.gen)</td><td class="dim">(commafy $r.io)</td></tr>'
    } | str join "\n")
    let sigshapep = ($common | merge {
        "@@SIG_NONE@@":         (commafy $sg_none)
        "@@SIG_ALLOC@@":        (commafy $sg_alloc)
        "@@SIG_OTHER@@":        (commafy $sg_other)
        "@@SIG_FP_BARS@@":      $sg_fp_bars
        "@@SIG_TRAIT_ROWS@@":   $sg_trait_rows
        "@@SIG_MODULE_ROWS@@":  $sg_mod_rows
    })

    # ── callcard slice ──
    # showcase rows: "both" callables whose as-written sig still says @This()/Self — so the resolved
    # column visibly fills in the real type. Deterministic (filter + sort + take).
    let cc_rows = ($callcard | where witness == "both"
        | where {|r| ($r.sig | str contains "@This()") or ($r.sig | str contains "Self") }
        | sort-by path | first 14 | each {|r|
            $'      <tr><td class="mono">(esc $r.path)</td><td class="mono dim">(esc $r.sig)</td><td class="mono">(esc $r.resolved)</td></tr>'
    } | str join "\n")
    let cc_mod_rows = ($callcard | insert m {|r| module-of $r.path } | group-by m
        | items {|k, v| {m: $k, n: ($v | length), both: ($v | where witness == "both" | length), refl: ($v | where witness == "reflect-only" | length)} }
        | sort-by n --reverse | first 14 | each {|r|
            $'      <tr><td class="mono">std.($r.m)</td><td class="num">(commafy $r.n)</td><td class="dim">(commafy $r.both)</td><td class="dim">(commafy $r.refl)</td></tr>'
    } | str join "\n")
    let callcardp = ($common | merge {
        "@@CC_PARSER@@":            (commafy $cc_parser)
        "@@CC_REFLECT@@":           (commafy $cc_reflect)
        "@@CC_BOTH_PCT@@":          (($cc_both * 100 / $cc_total) | math round | into int | into string)
        "@@CC_PARSER_PCT@@":        (($cc_parser * 100 / $cc_total) | math round | into int | into string)
        "@@CC_REFLECT_PCT@@":       (($cc_reflect * 100 / $cc_total) | math round | into int | into string)
        "@@CALLCARD_ROWS@@":        $cc_rows
        "@@CALLCARD_MODULE_ROWS@@": $cc_mod_rows
    })

    let subs = [$hub, $idx, $canonp, $conp, $doccovp, $sigshapep, $callcardp]
    let html_pages = ($PAGES | enumerate | each {|p| {out: $p.item.out, html: (fill $p.item.tmpl ($subs | get $p.index))} })
    # markdown docs fill from the shared token set only — same fill, same --check, same no-drift guarantee.
    let md_pages = ($MD_PAGES | each {|p| {out: $p.out, html: (fill $p.tmpl $common)} })
    $html_pages | append $md_pages
}

def main [--check] {
    let pages = (render)
    mut ok = true
    for p in $pages {
        let left = ($p.html | find "@@" | length)
        if $left > 0 { print $"arch: ✗ unfilled @@TOKEN@@ remains in ($p.out) — template/generator out of sync"; exit 1 }
        if $check {
            if not ($p.out | path exists) { print $"arch: ✗ ($p.out) missing — run without --check"; exit 1 }
            if $p.html == (open --raw $p.out) { print $"  ✓ ($p.out)" } else { print $"  ✗ DRIFT ($p.out)"; $ok = false }
        } else {
            $p.html | save -f $p.out
            print $"  ✓ ($p.out)"
        }
    }
    if not $ok { print "arch: ✗ DRIFT — a page no longer matches the data; rerun build_arch.nu"; exit 1 }
    if $check { print "arch: ✓ every page regenerates byte-identical from data/std + engine source" } else { print "arch: ✓ regenerated the docs site from data/std + engine source" }
}
