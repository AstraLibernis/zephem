#!/usr/bin/env nu
# verify_std.nu — prove the std map's integrity by reading it a SECOND way.
#
# The extractor (src/scan.zig) records, per container, how many public children
# it declares (`n_children`). This script never trusts that number on its own —
# it re-derives the truth by grouping every row under its parent path, then
# checks the two agree. No external tools, no oracle: the data checks itself.
#
#   CONSERVATION   Σ n_children  ==  (rows − 1)      # every non-root node is one child
#   PER-NODE       for each expanded container, observed children == n_children
#   PARTITION      Σ rows-per-kind == total rows     # no unclassified leftovers
#   @ref INTEGRITY every @ref path is expanded somewhere else (no dangling refs)
#
# Usage:  nu scripts/verify_std.nu            # checks data/std/nodes.tsv
#         nu scripts/verify_std.nu other.tsv

def parent [path: string] {
    let parts = ($path | split row ".")
    if ($parts | length) <= 1 { "" } else { $parts | drop 1 | str join "." }
}

def main [file: string = "data/std/nodes.tsv"] {
    let t = (open $file)
    let n = ($t | length)
    mut ok = true

    # 1. CONSERVATION — the one-number checksum.
    let declared = ($t | get n_children | math sum)
    let expect = ($n - 1)
    print $"conservation:  Σ n_children = ($declared)   rows − 1 = ($expect)"
    if $declared != $expect {
        print $"  ✗ MISMATCH — tree is not fully connected \(orphans or double-counts\)"
        $ok = false
    } else { print "  ✓ tree is fully connected — no orphans, no double-counts" }

    # 2. PER-NODE — observed children vs recorded, for every expanded container.
    let observed = ($t | each {|r| {parent: (parent $r.path)} } | group-by parent
        | items {|k, v| {path: $k, observed: ($v | length)} })
    let expanded = ($t | where n_children > 0 | select path n_children | update n_children {|r| $r.n_children | into int})
    let joined = ($expanded | join $observed path)
    let bad = ($joined | where {|r| ($r.n_children | into int) != ($r.observed | into int)})
    print $"per-node:       ($expanded | length) expanded containers checked"
    if ($bad | length) > 0 {
        print $"  ✗ ($bad | length) containers disagree:"
        $bad | first 10 | print
        $ok = false
    } else { print "  ✓ every container's recorded child count matches what's in the tree" }

    # 3. PARTITION — kinds must sum to the whole.
    let by_kind = ($t | group-by kind | items {|k, v| {kind: $k, n: ($v | length)} } | sort-by n --reverse)
    let kind_sum = ($by_kind | get n | math sum)
    print $"partition:      Σ kinds = ($kind_sum)   rows = ($n)"
    if $kind_sum != $n { print "  ✗ unclassified rows exist"; $ok = false } else { print "  ✓ every row classified exactly once" }
    $by_kind | print

    # 4. nsref INTEGRITY — every reference's target file is expanded somewhere.
    let expanded_files = ($t | where kind == "ns" | get detail | uniq)
    let refs = ($t | where kind == "nsref")
    let dangling = ($refs | where {|r| $r.detail not-in $expanded_files })
    print $"nsref integrity: ($refs | length) refs"
    if ($dangling | length) > 0 { print $"  ✗ ($dangling | length) dangling"; $dangling | first 10 | print; $ok = false } else { print "  ✓ every reference's target file is expanded somewhere" }

    # 5. INDEX (table of contents) — re-derive each block from nodes.tsv depths.
    #    The index claims "node X lives at line L for span S rows". We DON'T trust
    #    its numbers: we look up the depths at L+S-1 (last claimed row) and L+S
    #    (row after) directly in nodes.tsv. A correct span ends exactly where the
    #    subtree does — the last row is deeper than the node, the next is not.
    if ("data/std/index.tsv" | path exists) {
        let nl = ($t | enumerate | each {|r| {line: ($r.index + 2), depth: ($r.item.depth | into int), path: $r.item.path, kind: $r.item.kind} })
        let ix = (open data/std/index.tsv | each {|r| {path: $r.path, line: ($r.line | into int), span: ($r.span | into int), depth: ($r.depth | into int), kind: $r.kind} })
        print $"index toc:      ($ix | length) containers"
        mut iok = true
        # root must own the whole file
        let rootspan = ($ix | get span | math max)
        if $rootspan != $n { print $"  ✗ root span ($rootspan) != rows ($n)"; $iok = false }
        # every index line must point at the named container in nodes.tsv
        let nlk = ($nl | select line path kind | rename --column {path: npath, kind: nkind})
        let jb = ($ix | join $nlk line)
        let badB = ($jb | where {|r| $r.path != $r.npath or $r.kind != $r.nkind})
        if (($jb | length) != ($ix | length)) or (($badB | length) > 0) { print "  ✗ some index lines don't point at the right node"; $iok = false }
        # re-derive the span boundary straight from nodes.tsv depths
        let datl = ($nl | select line depth | rename --column {line: atline, depth: atdepth})
        let badlast = ($ix | insert atline {|r| $r.line + $r.span - 1} | join $datl atline | where {|r| $r.atdepth <= $r.depth})
        let badafter = ($ix | insert atline {|r| $r.line + $r.span} | join $datl atline | where {|r| $r.atdepth > $r.depth})
        if (($badlast | length) > 0) or (($badafter | length) > 0) { print $"  ✗ (($badlast | length) + ($badafter | length)) blocks over/under-shoot their subtree"; $iok = false }
        if $iok { print "  ✓ every block re-derived from nodes.tsv — line+span land exactly on each subtree" } else { $ok = false }
    }

    print ""
    if $ok { print "VERDICT: ✓ all integrity checks pass" } else { print "VERDICT: ✗ integrity FAILED"; exit 1 }
}
