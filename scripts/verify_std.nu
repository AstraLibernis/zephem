#!/usr/bin/env nu
# verify_std.nu — prove the parse2 map's integrity by reading it a SECOND way.
#
# The forward pass (parse2/build.zig) emits three streams; this re-reads them and checks they
# reconcile — no external oracle, the data checks itself. A regeneration this rejects is rejected.
#
#   CONNECTED    every non-root node hangs off a real parent (the tree has no orphans)
#   PARTITION    every row is a known kind
#   INDEX        derived/index.tsv points only at real nodes, root span == total rows
#   ATTRS        every attr (doc/sig/value/loc/example) keys onto a real node
#   EDGES        every edge starts at a real node, and every RESOLVED edge (local/cross) points at
#                a real node — i.e. the link has a valid target found in the data (the B invariant)
#
# Usage:  nu scripts/verify_std.nu            # checks data/std/extracted/nodes.tsv
#         nu scripts/verify_std.nu other.tsv --partial

# Parent path. A `<fn>()` factory node's parent is the fn (drop the `()`); otherwise drop the last
# top-level segment (a `.` inside `@"…"` is part of a name, not a separator).
def parent [path: string] {
    if ($path | str ends-with "()") { return ($path | str replace --regex '\(\)$' "") }
    mut segs = []
    mut cur = ""
    mut inq = false
    for c in ($path | split chars) {
        if $inq {
            $cur = $cur + $c
            if $c == "\"" { $inq = false }
        } else if $c == "." {
            $segs = ($segs | append $cur)
            $cur = ""
        } else {
            $cur = $cur + $c
            if $c == "\"" { $inq = true }
        }
    }
    $segs = ($segs | append $cur)
    if ($segs | length) <= 1 { "" } else { $segs | drop 1 | str join "." }
}

def main [file: string = "data/std/extracted/nodes.tsv", --partial] {
    let t = (open $file)
    let n = ($t | length)
    mut ok = true
    let root = ($t | first | get path)
    let nodeset = ($t | get path | reduce --fold {} {|p, acc| $acc | upsert $p true})

    # 1. CONNECTED — every non-root node's parent is a real node.
    let orphans = ($t | where path != $root | where {|r|
        let p = (parent $r.path)
        $p != "" and ($nodeset | get -o $p) != true
    })
    print $"connected:  ($n) nodes"
    if ($orphans | length) > 0 { print $"  ✗ ($orphans | length) orphan\(s\) — parent path missing"; $orphans | first 5 | print; $ok = false } else { print "  ✓ every node hangs off a real parent" }

    # 2. PARTITION — every row a known kind.
    let known = ["ns" "nsref" "nserr" "modref" "struct" "enum" "union" "opaque" "fn" "const" "alias" "field" "tag"]
    let bad = ($t | where kind not-in $known)
    let by_kind = ($t | group-by kind | items {|k, v| {kind: $k, n: ($v | length)} } | sort-by n --reverse)
    print $"partition:  ($by_kind | length) distinct kinds"
    if ($bad | length) > 0 { print $"  ✗ ($bad | length) row\(s\) with an unknown kind"; $ok = false } else { print "  ✓ every row a known kind" }
    $by_kind | print

    # 3. INDEX — the table of contents registers on the map, root owns everything.
    if ("data/std/derived/index.tsv" | path exists) {
        let ix = (open data/std/derived/index.tsv)
        let notreal = ($ix | where {|r| ($nodeset | get -o $r.path) != true})
        print $"index:      ($ix | length) containers"
        if ($notreal | length) > 0 { print $"  ✗ ($notreal | length) index row\(s\) point at a non-node"; $ok = false } else { print "  ✓ every index entry is a real node" }
        if (($ix | get span | into int | math max) != $n) { print $"  ✗ root span != ($n) rows"; $ok = false } else { print "  ✓ root span == total rows" }
    }

    let dir = ($file | path dirname)

    # 4. ATTRS — every attr keys onto a real node; known kinds only.
    if ($"($dir)/attrs.tsv" | path exists) {
        let a = (open $"($dir)/attrs.tsv")
        let known_attr = ["doc" "sig" "value" "loc" "example"]
        let a_orphan = ($a | where {|r| ($nodeset | get -o $r.path) != true})
        let a_bad = ($a | where attr not-in $known_attr)
        print $"attrs:      ($a | length) rows"
        if ($a_orphan | length) > 0 { print $"  ✗ ($a_orphan | length) attr\(s\) key onto a missing node"; $ok = false } else { print "  ✓ every attr keys onto a real node" }
        if ($a_bad | length) > 0 { print $"  ✗ ($a_bad | length) attr\(s\) of an unknown kind"; $ok = false } else { print "  ✓ every attr a known kind (doc/sig/value/loc/example)" }
    } else if (not $partial) { print "  ✗ attrs.tsv missing beside the map"; $ok = false }

    # 5. EDGES — start at a real node; every RESOLVED edge points at a real node (the B invariant).
    if ($"($dir)/edges.tsv" | path exists) {
        let e = (open $"($dir)/edges.tsv")
        let e_orphan = ($e | where {|r| ($nodeset | get -o $r.src) != true})
        let bad_link = ($e | where scope in ["local" "cross"] | where {|r| ($nodeset | get -o $r.target) != true})
        print $"edges:      ($e | length) rows"
        if ($e_orphan | length) > 0 { print $"  ✗ ($e_orphan | length) edge\(s\) start at a missing node"; $ok = false } else { print "  ✓ every edge starts at a real node" }
        if ($bad_link | length) > 0 { print $"  ✗ ($bad_link | length) resolved edge\(s\) point at a MISSING node — a link lies"; $bad_link | first 5 | print; $ok = false } else { print "  ✓ every local/cross edge resolves to a real node — links are valid" }
    } else if (not $partial) { print "  ✗ edges.tsv missing beside the map"; $ok = false }

    print ""
    if $ok { print "VERDICT: ✓ all integrity checks pass" } else { print "VERDICT: ✗ integrity FAILED"; exit 1 }
}
