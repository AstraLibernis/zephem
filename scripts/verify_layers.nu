#!/usr/bin/env nu
# verify_layers.nu — cross-LAYER agreement: do independently-built layers agree on shared facts?
#
# The other verifiers (verify_std / verify_tunnels / verify_depth) each prove ONE layer
# reconciles with itself or the map by re-reading the *same* artifact a second way. That catches
# corruption and loss, but it cannot catch a blind spot shared by the producer and the checker.
#
# This script is different on purpose. It joins TWO views of the same symbols that were produced
# by SEPARATE machinery and asks whether they agree:
#
#   PARSER view    L0  data/std/extracted/nodes.tsv     ← parse/build.zig, walking the AST (syntax)
#   COMPILER view  L5  data/std/extracted/resolved.tsv  ← reflection, semantic analysis (what it *is*)
#
# build.zig and the compiler share no code path, so when they agree on a symbol's kind that
# agreement is *evidence*. (Contrast the old decls⇔map "bijection": build.zig and enrich.zig
# running the same fn-gate twice — agreement guaranteed by construction, proving nothing.)
#
# Two reconciliations the views need before a delta is real (parse-don't-reflect by design):
#   - KEYWORD QUOTING. The parser is source-faithful: a fn named with a reserved word is emitted
#     `@"type"`. The compiler reflects the bare member name `type`. Same fn — so paths are
#     compared quote-normalized (`@"x"` → `x`).
#   - TYPE BINDINGS. The parser does NOT descend into `const X = OtherType` or `const X =
#     Generic(args)` or an `alias` re-export — it records a leaf. The compiler reflects the full
#     member set of the resolved type. So a compiler-fn the parser "didn't emit" is classified by
#     what the parser calls its PARENT: alias/nsref → re-home; const → behind a type binding;
#     a real container (struct/enum/union/opaque/ns) the parser descended into → GENUINE miss.
#
# Pure OBSERVABILITY: this prints the full agreement table and every delta, and NEVER exits
# non-zero. Watch a section stay clean across rebuilds, then promote it to a hard gate.
#
# The shared "tag" is (path, kind): each layer emits a kind per path; the join is the comparison.
# When L4/L6 land they register the same way — add their kind column to the join, nothing else.
#
# Usage:  nu scripts/verify_layers.nu [--dir data/std] [--anchor]

# Canonical semantic kind for the PARSER (nodes.tsv) vocabulary.
def parser-kind [k: string] {
    if $k == "fn" { "fn" } else if $k in ["struct" "enum" "union" "opaque" "ns" "nsref"] { "type" } else if $k == "const" { "const" } else if $k == "alias" { "alias" } else { $k }
}

# Canonical semantic kind for the COMPILER (resolved.tsv) vocabulary.
def compiler-kind [k: string] {
    if $k == "fn" { "fn" } else if $k == "type" { "type" } else if $k in ["const_int" "const_bool" "const_other"] { "const" } else { $k }
}

# Strip Zig keyword-quoting so the parser's `@"type"` and the compiler's `type` compare equal.
def norm-path [p: string] {
    $p | str replace --regex --all '@"([^"]+)"' '$1'
}

# Walk a path's ancestors; return {kind, immediate} for the nearest ancestor the parser knows.
# `immediate` = that ancestor is the path's direct parent (no unseen segments between).
def nearest-ancestor [p: string, kindOf: record] {
    let segs = ($p | split row ".")
    let n = ($segs | length)
    mut i = 1
    mut out = {kind: "", immediate: false}
    while $i < $n {
        let anc = ($segs | first ($n - $i) | str join ".")
        let k = ($kindOf | get -o $anc)
        if $k != null { $out = {kind: $k, immediate: ($i == 1)}; break }
        $i = $i + 1
    }
    $out
}

def main [--dir: string = "data/std", --anchor] {
    for f in ["extracted/nodes.tsv" "extracted/resolved.tsv"] {
        if not ($"($dir)/($f)" | path exists) { print $"missing ($dir)/($f)"; exit 1 }
    }
    let nodes = (open $"($dir)/extracted/nodes.tsv" | select path kind
        | insert npath {|r| norm-path $r.path} | insert pk {|r| parser-kind $r.kind} | rename --column {kind: nraw})
    let res = (open $"($dir)/extracted/resolved.tsv" | select path kind | uniq-by path
        | insert npath {|r| norm-path $r.path} | insert ck {|r| compiler-kind $r.kind} | rename --column {kind: rraw, path: cpath})

    let j = ($nodes | join $res npath)
    print $"layers: parser ($nodes | length) paths  ×  compiler ($res | length) paths  →  ($j | length) shared \(quote-normalized\)"
    print ""

    # ── 1. PROVABLE INVARIANTS (printed pass/fail, never exits) ────────────────────────────────
    print "── provable kind agreement (independent views — agreement is evidence) ──"
    let pf = ($j | where pk == "fn")
    let pf_bad = ($pf | where ck != "fn")
    print $"  parser fn ⟹ compiler fn:            (($pf | length) - ($pf_bad | length)) / ($pf | length) agree"
    if ($pf_bad | length) > 0 {
        print $"    ✗ ($pf_bad | length) parser-fn resolve to a NON-fn — genuine conflict:"
        $pf_bad | select path nraw rraw | first 15 | print
    } else { print "    ✓ every function the parser found, the compiler also resolves as a function" }

    let pt = ($j | where pk == "type")
    let pt_bad = ($pt | where ck != "type")
    print $"  parser container ⟹ compiler type:   (($pt | length) - ($pt_bad | length)) / ($pt | length) agree"
    if ($pt_bad | length) > 0 {
        print $"    ✗ ($pt_bad | length) parser-container resolve to a NON-type — genuine conflict:"
        $pt_bad | select path nraw rraw | first 15 | print
    } else { print "    ✓ every struct/enum/union/opaque/ns the parser found is a type to the compiler" }
    print ""

    # ── 2. AMBIGUOUS BY NATURE (reported, never asserted) ──────────────────────────────────────
    print "── ambiguous bindings (const/alias — reported, not gated) ──"
    for grp in [[pk]; [const] [alias]] {
        let rows = ($j | where pk == $grp.pk)
        let dist = ($rows | group-by ck | items {|k, v| $"($k):($v | length)"} | str join "  ")
        print $"  parser ($grp.pk) \(($rows | length)\) → ($dist)"
    }
    print ""

    # ── 3. COVERAGE DELTAS — classified, so only a TRUE miss is flagged ─────────────────────────
    let CONTAINERS = ["struct" "enum" "union" "opaque" "ns"]
    let kindOf = ($nodes | reduce --fold {} {|r, acc| $acc | upsert $r.npath $r.nraw })
    let nodeset = ($nodes | get npath | reduce --fold {} {|p, acc| $acc | upsert $p true })
    let node_fnset = ($nodes | where pk == "fn" | get npath | reduce --fold {} {|p, acc| $acc | upsert $p true })
    let comp_fnset = ($res | where ck == "fn" | get npath | reduce --fold {} {|p, acc| $acc | upsert $p true })

    print "── coverage deltas (functions one view has, the other lacks — quote-normalized) ──"

    # (a) compiler-fns the parser didn't emit, bucketed by what the parser calls the parent.
    let unseen = ($res | where ck == "fn" | where {|r| ($nodeset | get -o $r.npath) != true})
    let classed = ($unseen | each {|r|
        let a = (nearest-ancestor $r.npath $kindOf)
        let bucket = (if $a.kind == "" { "truly-absent (no known ancestor)" } else if ($a.immediate and ($a.kind in $CONTAINERS)) { "GENUINE-missing (parser descended here)" } else if $a.kind in ["alias" "nsref"] { "alias/ns re-home" } else if $a.kind == "const" { "behind const/generic type" } else if $a.kind in $CONTAINERS { "behind nested const/generic type" } else { $"behind ($a.kind)" })
        {path: $r.cpath, parent_kind: $a.kind, immediate: $a.immediate, bucket: $bucket}
    })
    print $"  compiler-fn the parser didn't emit \(($unseen | length)\) — classified:"
    $classed | group-by bucket | items {|k, v| {bucket: $k, n: ($v | length)} } | sort-by n --reverse | print
    let flagged = ($classed | where bucket =~ '^(GENUINE-missing|truly-absent)')
    if ($flagged | length) > 0 {
        print $"  ⚠ ($flagged | length) TRULY MISSING — parser descended into the container yet didn't emit \(or no record at all\). Investigate:"
        $flagged | select path parent_kind bucket | first 25 | print
    } else {
        print "  ✓ 0 truly missing — every one is an alias re-home or behind a const/generic type binding (parse-don't-reflect, expected)"
    }

    # (b) compiler-fns whose path IS a parser node but NOT a parser fn (const/alias bound to a fn).
    let reclassed = ($res | where ck == "fn" | where {|r| ($nodeset | get -o $r.npath) == true and ($node_fnset | get -o $r.npath) != true})
    print $"  compiler-fn the parser emitted as non-fn:      ($reclassed | length)   \(const/alias bound to a fn — benign\)"

    # (c) parser-fns the compiler never resolved → container didn't reflect (poison). Cross-check.
    let poison_paths = if ($"($dir)/extracted/poison.tsv" | path exists) { (open $"($dir)/extracted/poison.tsv" | get -o path | default []) } else { [] }
    let poiset = ($poison_paths | each {|p| norm-path $p} | reduce --fold {} {|p, acc| $acc | upsert $p true })
    let parser_only = ($nodes | where pk == "fn" | where {|r| ($comp_fnset | get -o $r.npath) != true})
    let parser_only_unexplained = ($parser_only | where {|r| ($poiset | get -o ($r.npath | split row "." | drop 1 | str join ".")) != true})
    print $"  parser-fn the compiler never resolved:         ($parser_only | length)   \(of which (($parser_only | length) - ($parser_only_unexplained | length)) sit under a poison container\)"
    if ($parser_only_unexplained | length) > 0 {
        print $"    ⚠ ($parser_only_unexplained | length) NOT explained by poison — worth a look:"
        $parser_only_unexplained | select path | first 25 | print
    } else { print "    ✓ every unresolved parser-fn sits under a container that genuinely failed to reflect (poison)" }
    print ""

    # ── 4. FULL CONTINGENCY (parser kind × compiler kind) ──────────────────────────────────────
    print "── contingency: every shared path, parser kind × compiler kind ──"
    $j | group-by nraw | items {|nk, rows|
        { parser: $nk, n: ($rows | length),
          compiler: ($rows | group-by rraw | items {|rk, rr| $"($rk):($rr | length)"} | str join "  ") }
    } | sort-by n --reverse | print

    # ── 5. SOURCE ANCHOR (optional, --anchor): raw text, no walk at all ─────────────────────────
    # A third witness independent of BOTH the parser and the compiler: grep `pub fn` straight out
    # of the source for a few leaf namespaces (whole subtree lives in one file). Approximate — raw
    # text can't account for comments or multi-line signatures — so it's informational only.
    if $anchor {
        print ""
        print "── source anchor: grep `pub fn` vs parser fn count, leaf namespaces (approx) ──"
        let std_dir = (^zig env | lines | parse -r '\.std_dir = "(?<p>[^"]+)"' | get p.0)
        let ns = (open $"($dir)/extracted/nodes.tsv" | where kind == "ns" | select path detail)
        let nspaths = ($ns | get path)
        let leaves = ($ns | where {|r| ($nspaths | where ($it | str starts-with $"($r.path).") | is-empty) })
        let allfns = (open $"($dir)/extracted/nodes.tsv" | where kind == "fn" | get path)
        for r in ($leaves | first 6) {
            let file = $"($std_dir)/($r.detail)"
            if not ($file | path exists) { continue }
            let grepn = (open --raw $file | lines | where ($it =~ '^\s*pub fn ') | length)
            let parsern = ($allfns | where ($it | str starts-with $"($r.path).") | length)
            let mark = (if $grepn == $parsern { "✓" } else { "≈" })
            print $"  ($mark) ($r.path): grep pub fn = ($grepn)   parser fn = ($parsern)   \(($r.detail)\)"
        }
    }

    print ""
    print "LAYERS: observability only — see deltas above; no gate enforced (by design)."
}
