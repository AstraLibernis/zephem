#!/usr/bin/env nu
# build_arch.nu — regenerate the markdown docs from the project itself.
#
# Nothing here is hand-authored: prose lives in templates/*.tmpl.md, and EVERY number is an
# @@TOKEN@@ injected live from data/std. So the docs can never drift from the data — and --check
# proves each one byte-identical across a fresh rebuild. Each generated file also leads with a
# banner (an HTML comment) naming its source template.
#
# (A visual HTML viewer used to live here too; it was cut to keep the docs simple — to be rebuilt
# later. This script is now markdown-only.)
#
# Usage:  nu scripts/build_arch.nu            # regenerate every doc
#         nu scripts/build_arch.nu --check    # prove each still matches the data (no write)

const MD_PAGES = [
  [tmpl, out];
  ["templates/root.tmpl.md",      "README.md"]
  ["templates/plan.tmpl.md",      "PLAN.md"]
  ["templates/parse.tmpl.md",     "parse/README.md"]
  ["templates/reflect.tmpl.md",   "reflect/README.md"]
  ["templates/data.tmpl.md",      "data/README.md"]
  ["templates/extracted.tmpl.md", "data/std/extracted/README.md"]
  ["templates/derived.tmpl.md",   "data/std/derived/README.md"]
]

# 12345 -> "12,345" (no lookahead in the regex engine, so group from the right by hand).
def commafy [n: int] {
    let rev = ($n | into string | split chars | reverse | str join)
    $rev | split chars | chunks 3 | each {|c| $c | str join } | str join "," | split chars | reverse | str join
}
# Fill one template's @@TOKEN@@s from a {token: value} record.
def fill [tmpl: string, subs: record] {
    mut md = (open --raw $tmpl)
    for k in ($subs | columns) { $md = ($md | str replace --all $k ($subs | get $k)) }
    $md
}

# Compute each doc's filled markdown from the live project state. Returns [{out, tmpl, md}].
def render [] {
    let nodes = (open data/std/extracted/nodes.tsv)
    let attrs = (open data/std/extracted/attrs.tsv)
    let edges = (open data/std/extracted/edges.tsv)
    let index = (open data/std/derived/index.tsv)
    let canon = (open data/std/derived/canon.tsv)
    let consensus = (open data/std/derived/consensus.tsv)
    let status = (open data/std/extracted/status.tsv)
    let poison = (open data/std/extracted/poison.tsv)
    let doccov = (open data/std/derived/doccov.tsv)
    let sigshape = (open data/std/derived/sigshape.tsv)
    let callcard = (open data/std/derived/callcard.tsv)

    let n     = ($nodes | length)
    let files = ($nodes | where kind == "ns" | length)
    let priv  = ($nodes | where vis == "priv" | length)
    let depth = ($index | get depth | math max)      # matches build_std's printed max depth

    # the parser's three streams — attrs (a node's own facts) and edges (typed references)
    let a_doc = ($attrs | where attr == "doc" | length)
    let a_sig = ($attrs | where attr == "sig" | length)
    let a_val = ($attrs | where attr == "value" | length)
    let a_loc = ($attrs | where attr == "loc" | length)
    let a_ex  = ($attrs | where attr == "example" | length)
    let fields = ($nodes | where kind in ["field" "tag"] | length)
    let e_res = ($edges | where scope in ["local" "cross" "primitive" "generic"] | length)
    let e_unres = ($edges | where scope == "unresolved" | length)
    let e_deleg = ($edges | where type == "delegates" | length)

    let dc_total = ($doccov | length)
    let dc_doc   = ($doccov | where documented == "yes" | length)
    let dc_pct   = (($dc_doc * 100) / $dc_total | math round | into int)

    let sg_total = ($sigshape | length)
    let sg_self  = ($sigshape | where first_param == "self" | length)
    let sg_io    = ($sigshape | where io == "yes" | length)
    let sg_gen   = ($sigshape | where generic == "yes" | length)

    let cc_total   = ($callcard | length)
    let cc_both    = ($callcard | where witness == "both" | length)
    let cc_parser  = ($callcard | where witness == "parser-only" | length)
    let cc_reflect = ($callcard | where witness == "reflect-only" | length)

    let families = ($canon | group-by canon | items {|k, v| {canon: $k, n: ($v | length)} })

    let con_ro = ($consensus | where origin == "read-only" | length)
    let con_run = ($consensus | where origin == "run-only" | length)
    let con_rr = ($consensus | where origin == "read+run" | length)
    let con_total = ($consensus | length)

    let common = {
        "@@ZIG@@":            (open data/std/PINNED | str trim)
        "@@N_NODES@@":        (commafy $n)
        "@@N_PUB@@":          (commafy ($n - $priv))
        "@@N_PRIV@@":         (commafy $priv)
        "@@N_FILES@@":        (commafy $files)
        "@@MAXDEPTH@@":       ($depth | into string)
        "@@N_RESOLVED@@":     (commafy (open data/std/extracted/resolved.tsv | length))
        "@@N_RES_CONT@@":     (commafy ($status | where status == "resolved" | length))
        "@@N_POISON@@":       (commafy ($poison | length))
        "@@N_INDEX@@":        (commafy ($index | length))
        # attributes (path · attr · value) — a node's own facts
        "@@N_ATTRS@@":        (commafy ($attrs | length))
        "@@N_SIGS@@":         (commafy $a_sig)
        "@@N_DOCS@@":         (commafy $a_doc)
        "@@N_VALUES@@":       (commafy $a_val)
        "@@N_LOC@@":          (commafy $a_loc)
        "@@N_EXAMPLES@@":     (commafy $a_ex)
        "@@N_FIELDS@@":       (commafy $fields)
        # edges (src · type · target · scope) — typed references, resolved to a reach
        "@@N_EDGES@@":        (commafy ($edges | length))
        "@@N_HASTYPE@@":      (commafy ($edges | where type == "has_type" | length))
        "@@N_ALIASEDGE@@":    (commafy ($edges | where type == "alias" | length))
        "@@N_ERRSET@@":       (commafy ($edges | where type == "error_set" | length))
        "@@N_IMPORTS@@":      (commafy ($edges | where type == "imports" | length))
        "@@N_DELEGATES@@":    (commafy $e_deleg)
        "@@E_LOCAL@@":        (commafy ($edges | where scope == "local" | length))
        "@@E_CROSS@@":        (commafy ($edges | where scope == "cross" | length))
        "@@E_PRIM@@":         (commafy ($edges | where scope == "primitive" | length))
        "@@E_MODULE@@":       (commafy ($edges | where scope == "module" | length))
        "@@E_GENERIC@@":      (commafy ($edges | where scope == "generic" | length))
        "@@E_INLINE@@":       (commafy ($edges | where scope == "inline" | length))
        "@@E_UNRES@@":        (commafy $e_unres)
        "@@E_RESOLVED@@":     (commafy $e_res)
        "@@E_RESOLVED_PCT@@": ((($e_res * 100) / ($e_res + $e_unres) | math round | into int) | into string)
        "@@N_FN@@":           (commafy ($nodes | where kind == "fn" | length))
        "@@N_NSREF@@":        (commafy ($nodes | where kind == "nsref" | length))
        # raw (un-commafied) variants — for sample console transcripts that must match
        # what build_std.nu actually prints (it prints plain ints, no thousands separators).
        "@@N_NODES_RAW@@":    ($n | into string)
        "@@N_PRIV_RAW@@":     ($priv | into string)
        "@@N_INDEX_RAW@@":    (($index | length) | into string)
        "@@N_ATTRS_RAW@@":    (($attrs | length) | into string)
        "@@N_EDGES_RAW@@":    (($edges | length) | into string)
        "@@E_RESOLVED_RAW@@": ($e_res | into string)
        "@@E_UNRES_RAW@@":    ($e_unres | into string)
        "@@A_DOC_RAW@@":      ($a_doc | into string)
        "@@A_SIG_RAW@@":      ($a_sig | into string)
        "@@A_VAL_RAW@@":      ($a_val | into string)
        "@@A_EX_RAW@@":       ($a_ex | into string)
        # std.crypto's own index coordinates (illustrative ranged-read example in README)
        "@@CRYPTO_LINE@@":    (($index | where path == "std.crypto" | get line.0) | into string)
        "@@CRYPTO_SPAN@@":    (($index | where path == "std.crypto" | get span.0) | into string)
        "@@N_CANON@@":        (commafy ($canon | length))
        "@@CANON_FAMILIES@@": (commafy ($families | length))
        "@@N_CONSENSUS@@":    (commafy $con_total)
        "@@CON_RR@@":         (commafy $con_rr)
        "@@CON_RUNONLY@@":    (commafy $con_run)
        "@@CON_READONLY@@":   (commafy $con_ro)
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

    $MD_PAGES | each {|p| {out: $p.out, tmpl: $p.tmpl, md: (fill $p.tmpl $common)} }
}

def main [--check] {
    let pages = (render)
    mut ok = true
    for p in $pages {
        # Every generated file leads with a banner naming its source template — an HTML comment,
        # so it renders invisibly on the forge but stops anyone editing the artifact by hand.
        let banner = $"<!-- GENERATED from ($p.tmpl) by scripts/build_arch.nu — edit the template, not this file. -->\n"
        let content = ($banner + $p.md)
        let left = ($content | find "@@" | length)
        if $left > 0 { print $"arch: ✗ unfilled @@TOKEN@@ remains in ($p.out) — template/generator out of sync"; exit 1 }
        if $check {
            if not ($p.out | path exists) { print $"arch: ✗ ($p.out) missing — run without --check"; exit 1 }
            if $content == (open --raw $p.out) { print $"  ✓ ($p.out)" } else { print $"  ✗ DRIFT ($p.out)"; $ok = false }
        } else {
            $content | save -f $p.out
            print $"  ✓ ($p.out)"
        }
    }
    if not $ok { print "arch: ✗ DRIFT — a doc no longer matches the data; rerun build_arch.nu"; exit 1 }
    if $check { print "arch: ✓ every doc regenerates byte-identical from data/std + engine source" } else { print "arch: ✓ regenerated the markdown docs from data/std + engine source" }
}
