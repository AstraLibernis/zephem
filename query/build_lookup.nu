#!/usr/bin/env nu
# build_lookup.nu — emit the denormalized "lookup" table that `zlook` searches.
#
# Joins zephem's published shape-model streams (nodes/attrs/edges) + the resolved and
# derived overlays into ONE row per map node, so a single line carries everything
# discovery needs:
#   path · depth · kind · name · n_children · detail · sig · doc · rkind · rdetail · canon
#   · ftype · fval · delegate · vis
# (columns 0..13 are the fixed contract `zlook.zig` hard-codes by index; `vis` is
# appended as column 14 — appending never shifts 0..13, so zlook needs no change, and
# private/public becomes searchable.)
#
#   detail   = attrs[loc]        (file:line — preserves "search by filename")
#   sig      = attrs[sig]        (a fn's as-written signature)
#   doc      = attrs[doc]        (/// comment)
#   rkind    = resolved.kind     (renamed; the compiler-reflected kind)
#   rdetail  = resolved.detail   (the compiler-reflected type / error set)
#   canon    = canon.canon       (alias-family head; blank if not aliased)
#   ftype    = edges[has_type].target  (a field/tag's resolved type)
#   fval     = attrs[value]      (a field default / const literal / enum tag value)
#   delegate = edges[delegates].target (a delegating factory's target)
# All blank when not applicable.
#
# This is a pure left-join over the map's nodes — same symbol universe as nodes.tsv,
# just enriched. Deterministic: same zephem snapshot -> byte-identical lookup.tsv.
#
#   nu query/build_lookup.nu                 # write ~/.config/zephem/lookup.tsv (what zlook reads)
#   nu query/build_lookup.nu --out other.tsv
#
# Reads zephem's datasets at $ZEPHEM_DATA (default: this repo's own data/std, self-located);
# writes the lookup table at $ZEPHEM_LOOKUP (default ~/.config/zephem/lookup.tsv).
use lib.nu *   # zephem-dir, attr-col, zephem-staleness, lookup-path, lookup-inputs

# depth = dotted levels + factory-call levels in a path, matching index.zig's counting
# ("()" marks a descent into a `fn(…) type` factory's members).
def path-depth [p: string] {
    (($p | split row '.' | length) - 1) + (($p | split row '()' | length) - 1)
}

# typed edges → a narrow {path, <col>} table for one edge type (src keyed as path).
def edge-col [edges: table, etype: string, col: string] {
    $edges | where type == $etype | select src target | rename --column {src: "path", target: $col} | uniq-by path
}

def main [--out: string, --force] {
    let d = (zephem-dir)
    for f in (lookup-inputs) {
        if not ($d | path join $f | path exists) {
            error make {msg: $"zephem dataset ($f) not found at ($d) — run `nu scripts/build_std.nu`, or set $ZEPHEM_DATA"}
        }
    }
    # A baked lookup.tsv is read later by zlook WITHOUT the datasets present, so a stale
    # one can't be caught at read time — refuse to build it if the map's pinned zig differs
    # from the installed zig. --force overrides (e.g. deliberately snapshotting an old map).
    let stale = (zephem-staleness $d)
    if not ($stale | is-empty) {
        if $force { print -e $stale } else {
            error make {msg: $"($stale)\nrefusing to build a possibly-stale lookup.tsv — pass --force to override."}
        }
    }
    let out = ($out | default (lookup-path))
    mkdir ($out | path dirname)

    let nodes    = (open ($d | path join extracted nodes.tsv))     # path kind name vis
    let attrs    = (open ($d | path join extracted attrs.tsv))     # path attr value
    let edges    = (open ($d | path join extracted edges.tsv))     # src type target scope
    let resolved = (open ($d | path join extracted resolved.tsv) | rename --column {kind: "rkind", detail: "rdetail"} | uniq-by path)
    let index    = (open ($d | path join derived index.tsv) | select path n_children | uniq-by path)
    let canon    = (open ($d | path join derived canon.tsv) | uniq-by path)

    let detail = (attr-col $attrs "loc"   "detail")
    let sig    = (attr-col $attrs "sig"   "sig")
    let doc    = (attr-col $attrs "doc"   "doc")
    let fval   = (attr-col $attrs "value" "fval")
    # ftype is a field/tag's resolved type. Many non-field nodes (fns) also carry
    # has_type edges (param/return types), so scope this column to field/tag nodes —
    # otherwise zlook would print a redundant ": type" line under every fn's signature.
    let fieldish = ($nodes | where kind in ["field" "tag"] | select path)
    let ftype    = (edge-col $edges "has_type"  "ftype" | join $fieldish path)
    let delegate = (edge-col $edges "delegates" "delegate")

    let lookup = ($nodes
        | insert depth {|r| path-depth $r.path }
        | join --left $index    path
        | join --left $detail   path
        | join --left $sig      path
        | join --left $doc      path
        | join --left $resolved path
        | join --left $canon    path
        | join --left $ftype    path
        | join --left $fval     path
        | join --left $delegate path
        # project to the fixed 14-column order zlook.zig indexes, + vis as column 14.
        | select path depth kind name n_children detail sig doc rkind rdetail canon ftype fval delegate vis)

    # self-check: a left-join over nodes must preserve exactly the node rows (1:1).
    if ($lookup | length) != ($nodes | length) {
        error make {msg: $"lookup row count (($lookup | length)) != nodes (($nodes | length)) — join not 1:1"}
    }

    $lookup | save -f $out
    print $"lookup: ($lookup | length) rows -> ($out)"
}
