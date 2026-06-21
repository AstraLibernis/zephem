#!/usr/bin/env nu
# build_canon.nu — the canonical-link overlay (L-canon): every path, tagged by PROVENANCE.
#
# The other layers force two views to line up 1:1 and treat a non-match as a "miss". That is the
# wrong demand: the parser (text) and the compiler (reflection) are NOT meant to be identical —
# each sees things the other cannot. This overlay stops forcing the match and instead CLASSIFIES
# every path by the only two questions that matter:
#
#     can the TEXT layer read it?   (is the path in nodes.tsv?)
#     can the COMMAND layer make it here?  (is the path in resolved.tsv?)
#
# That 2×2 has exactly three populated cells — the three buckets recorded in `origin`:
#
#                       command CAN make            command CANNOT make (this OS)
#   text CAN read   │   read+run  (matched 1:1)  │   read-only  (poison / root)
#   text CANNOT read│   run-only  (made by refl) │   —  (unobservable: correctly empty)
#
#   read+run   the parser read it AND reflection resolved it — they agree. Agreement is evidence.
#   run-only   only exists when RUN: members of a generic/alias the parser recorded as a leaf
#              (`Sha256 = Sha2x32(iv,256)` → the parser has `Sha256`, reflection makes `.digest_length`).
#   read-only  the parser read it but reflection can't make it here — POISON (a Windows decl on
#              Linux, an @compileError), or the namespace ROOT (`std` has no member-row of its own).
#
# So nothing is "missing": every path lands in exactly one bucket, and the buckets that CAN be
# linked carry the link. Columns:
#
#   path · origin · owner · owner_canon · note
#
#   owner        the parent path this hangs off in the readable map (for run-only: the doorway
#                decl the parser DID record; for read-only poison: the container that failed).
#   owner_canon  the de-aliased @typeName identity of that owner, from reflection — so a member
#                under `Sha256` shows it really lives on `crypto.sha2.Sha2x32(...)`. Best-effort:
#                empty when the owner has no resolved type (e.g. a scalar parent).
#   note         for read-only: the compiler's exact poison reason, or `root`. Empty otherwise.
#
# Pure, fast, deterministic derivation of already-committed files (nodes/resolved/poison) — no
# reflection, no compile. Writes data/std/canon.tsv + SHA256SUMS.canon; `--check` proves it rebuilds.
#
# Usage:  nu scripts/build_canon.nu [--dir data/std]      # derive + write + manifest
#         nu scripts/build_canon.nu --check               # prove the committed overlay rebuilds

const MANIFEST = "data/std/SHA256SUMS.canon"

# Strip Zig keyword-quoting so the parser's `@"type"` and the compiler's `type` key equal.
def norm-path [p: string] { $p | str replace --regex --all '@"([^"]+)"' '$1' }

# The path's parent (drop the last dotted segment); "" for a single-segment root.
def parent-of [p: string] { $p | split row "." | drop 1 | str join "." }

# Nearest ancestor of `p` present as a key in `lut` (record np→value); "" if none.
def nearest-val [p: string, lut: record] {
    let segs = ($p | split row ".")
    let n = ($segs | length)
    mut i = 1
    mut out = ""
    while $i < $n {
        let anc = ($segs | first ($n - $i) | str join ".")
        let v = ($lut | get -o $anc)
        if $v != null { $out = $v; break }
        $i = $i + 1
    }
    $out
}

# Derive the full census table from the three committed inputs.
def derive [dir: string] {
    for f in ["nodes.tsv" "resolved.tsv" "poison.tsv"] {
        if not ($"($dir)/($f)" | path exists) { print $"missing ($dir)/($f)"; exit 1 }
    }
    let nodes = (open $"($dir)/nodes.tsv" | select path kind
        | insert np {|r| norm-path $r.path} | rename --column {path: ppath, kind: pk})
    let res = (open $"($dir)/resolved.tsv" | select path kind detail | uniq-by path
        | insert np {|r| norm-path $r.path} | rename --column {path: cpath, kind: ck})

    # owner_canon source: the @typeName of every resolved TYPE row, keyed by normalized path.
    let typeDetail = ($res | where ck == "type" | reduce --fold {} {|r, acc| $acc | upsert $r.np $r.detail })
    # poison reasons keyed by normalized container path.
    let poisonReason = (open $"($dir)/poison.tsv" | select path reason
        | insert np {|r| norm-path $r.path}
        | reduce --fold {} {|r, acc| $acc | upsert $r.np $r.reason })

    let j = ($nodes | join --outer $res np)

    $j | each {|r|
        let path = (if $r.ppath != null { $r.ppath } else { $r.cpath })
        let origin = (if ($r.ppath != null and $r.cpath != null) { "read+run" } else if ($r.cpath != null) { "run-only" } else { "read-only" })
        let parent = (parent-of $path)
        let owner_canon = ($typeDetail | get -o (norm-path $parent) | default "")
        let note = (if $origin != "read-only" { "" } else if $parent == "" { "root" } else { nearest-val (norm-path $path) $poisonReason })
        {path: $path, origin: $origin, owner: $parent, owner_canon: $owner_canon, note: $note}
    } | sort-by path
}

def main [--dir: string = "data/std", --check] {
    if $check {
        if not ($MANIFEST | path exists) { print $"[canon check] no ($MANIFEST) — build first"; exit 1 }
        let fresh = (derive $dir | to tsv)
        let want = (open $MANIFEST | lines | first | parse -r '(?<hash>\S+)' | get hash.0)
        let got = ($fresh | hash sha256)
        if $got == $want { print $"[canon check] ✓ rebuilds byte-identical \(($got)\)" } else {
            print $"[canon check] ✗ DRIFT — manifest ($want) vs rebuild ($got)"; exit 1
        }
        return
    }

    let rows = (derive $dir)
    $rows | to tsv | save -f $"($dir)/canon.tsv"

    # summary: the bucket census + the zero-blank guarantee, printed so it can't hide a gap.
    let n = ($rows | length)
    print $"[canon] ($n) paths → ($dir)/canon.tsv"
    $rows | group-by origin | items {|k, v| {origin: $k, n: ($v | length)} } | sort-by n --reverse | print
    let blank_origin = ($rows | where origin == "" | length)
    let blank_owner = ($rows | where owner == "" and note != "root" | length)
    let linked_canon = ($rows | where origin == "run-only" and owner_canon != "" | length)
    let run_only = ($rows | where origin == "run-only" | length)
    print $"  zero-blank: ($blank_origin) paths with no origin, ($blank_owner) non-root paths with no owner"
    print $"  run-only linked to a canonical owner: ($linked_canon)/($run_only)"

    let h = ($rows | to tsv | hash sha256)
    $"($h)  data/std/canon.tsv\n" | save -f $MANIFEST
    print $"[canon] manifest → ($MANIFEST)  \(run --check to prove it rebuilds\)"
}
