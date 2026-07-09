#!/usr/bin/env nu
# verify_layers.nu — cross-LAYER agreement: do independently-built layers agree on shared facts?
#
# The other verifiers (verify_std / verify_depth) each prove ONE layer
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

use lib.nu *   # norm-path, presence

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
    # joinable membership/kind views — a hash join beats per-row probes into 60k-key records.
    let node_np = (presence $nodes npath _n)
    let node_fn_np = (presence ($nodes | where pk == "fn") npath _fn)
    let comp_fn_np = (presence ($res | where ck == "fn") npath _cfn)
    # node_kind keeps the key too (renamed _anc) so it can join an exploded ancestor column.
    let node_kind = ($nodes | select npath nraw | uniq-by npath | rename --column {npath: _anc, nraw: _anckind})

    print "── coverage deltas (functions one view has, the other lacks — quote-normalized) ──"

    # (a) compiler-fns the parser didn't emit, bucketed by what the parser calls the parent.
    let unseen = ($res | where ck == "fn" | join --left $node_np npath | where _n == null)
    # nearest known ancestor per unseen path: explode to ancestors, keep those that are real nodes,
    # take the closest (min level) — set-based, replacing the walk over a 60k-key kind record.
    let anc = ($unseen | select cpath npath | each {|r|
        let segs = ($r.npath | split row ".")
        let n = ($segs | length)
        (1..($n - 1)) | each {|i| {cpath: $r.cpath, npath: $r.npath, _anc: ($segs | first ($n - $i) | str join "."), level: $i}}
    } | flatten)
    let nearest = ($anc | join $node_kind _anc | group-by npath | items {|np, rows|
        let b = ($rows | sort-by level | first)
        {npath: $np, akind: $b._anckind, immediate: ($b.level == 1)}
    })
    let classed = ($unseen | join --left $nearest npath | each {|r|
        let akind = ($r.akind? | default "")
        let immediate = ($r.immediate? | default false)
        let bucket = (if $akind == "" { "truly-absent (no known ancestor)" } else if ($immediate and ($akind in $CONTAINERS)) { "GENUINE-missing (parser descended here)" } else if $akind in ["alias" "nsref"] { "alias/ns re-home" } else if $akind == "const" { "behind const/generic type" } else if $akind in $CONTAINERS { "behind nested const/generic type" } else { $"behind ($akind)" })
        {path: $r.cpath, parent_kind: $akind, immediate: $immediate, bucket: $bucket}
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
    let reclassed = ($res | where ck == "fn" | join --left $node_np npath | where _n == true | join --left $node_fn_np npath | where _fn == null | length)
    print $"  compiler-fn the parser emitted as non-fn:      ($reclassed)   \(const/alias bound to a fn — benign\)"

    # (c) parser-fns the compiler never resolved → container didn't reflect (poison). Cross-check.
    let poison_paths = if ($"($dir)/extracted/poison.tsv" | path exists) { (open $"($dir)/extracted/poison.tsv" | get -o path | default []) } else { [] }
    let poi_cont = ($poison_paths | each {|p| norm-path $p} | wrap _cont | uniq-by _cont | insert _poi true)
    let parser_only = ($nodes | where pk == "fn" | join --left $comp_fn_np npath | where _cfn == null)
    let parser_only_unexplained = ($parser_only | insert _cont {|r| $r.npath | split row "." | drop 1 | str join "."} | join --left $poi_cont _cont | where _poi == null)
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
        let ns = (open $"($dir)/extracted/nodes.tsv" | where kind == "ns" | get path)
        let leaves = ($ns | where {|p| ($ns | where ($it | str starts-with $"($p).") | is-empty) })
        # a node's source file now comes from its `loc` attr (`file:line`); an ns's own loc is the
        # IMPORT site, so take a child's loc file — the subtree lives in one file.
        let locTable = (open $"($dir)/extracted/attrs.tsv" | where attr == "loc"
            | insert file {|r| $r.value | split row ":" | first } | select path file)
        let allfns = (open $"($dir)/extracted/nodes.tsv" | where kind == "fn" | get path)
        for p in ($leaves | first 6) {
            let child = ($allfns | where ($it | str starts-with $"($p).") | first)
            let rel = (if $child != null { $locTable | where path == $child | get file.0? } else { null })
            if $rel == null { continue }
            let file = $"($std_dir)/($rel)"
            if not ($file | path exists) { continue }
            let grepn = (open --raw $file | lines | where ($it =~ '^\s*pub fn ') | length)
            let parsern = ($allfns | where ($it | str starts-with $"($p).") | length)
            let mark = (if $grepn == $parsern { "✓" } else { "≈" })
            print $"  ($mark) ($p): grep pub fn = ($grepn)   parser fn = ($parsern)   \(($rel)\)"
        }
    }

    print ""
    print "LAYERS: observability only — see deltas above; no gate enforced (by design)."
}
