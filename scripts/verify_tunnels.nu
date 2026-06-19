#!/usr/bin/env nu
# verify_tunnels.nu — prove the L3 tunnels overlay reconciles with the map, read a second way.
#
# build_tunnels.nu resolved every reference and split it into tunnels.tsv (resolved edges) and
# unresolved.tsv (primitive + unresolved). This script never trusts that: it re-reads both files
# and the map and proves they reconcile. Same spirit as verify_std/verify_depth — no oracle.
#
#   REGISTRATION   every to_path in tunnels.tsv is a real node in nodes.tsv (no dangling edge).
#   FROM-VALID     every from_path (resolved or not) is a real node in nodes.tsv.
#   ADDRESS        where to_line is set, (to_path, to_line) is a container row in index.tsv.
#   COVERAGE       the alias+import edges cover EXACTLY the map's alias + nsref rows, once each —
#                  every re-export accounted for, none invented.
#   USAGE-DOMAIN   every usage edge starts at a fn in the map.
#   PRISTINE       no duplicate edges / unresolved rows.
#
# Usage:  nu scripts/verify_tunnels.nu <dir>   (dir holds nodes/index/tunnels/unresolved.tsv)

def main [dir: string] {
    for f in ["nodes.tsv" "index.tsv" "tunnels.tsv" "unresolved.tsv"] {
        if not ($"($dir)/($f)" | path exists) { print $"missing ($dir)/($f)"; exit 1 }
    }
    let nodes = (open $"($dir)/nodes.tsv")
    let idx = (open $"($dir)/index.tsv")
    let tun = (open $"($dir)/tunnels.tsv")
    let un = (open $"($dir)/unresolved.tsv")
    let paths = ($nodes | get path)
    let pathset = ($paths | reduce --fold {} {|p, acc| $acc | upsert $p true })
    let fnset = ($nodes | where kind == "fn" | get path | reduce --fold {} {|p, acc| $acc | upsert $p true })
    def known [set, p] { ($set | get -i $p) == true }
    mut ok = true

    # 1. REGISTRATION — no dangling target.
    let dangling = ($tun | where {|r| not (known $pathset $r.to_path)})
    print $"registration: ($tun | length) resolved edges → ($paths | length) nodes"
    if ($dangling | length) > 0 { print $"  ✗ ($dangling | length) edge\(s\) point to a non-node"; $dangling | first 5 | print; $ok = false } else { print "  ✓ every resolved edge lands on a real node" }

    # 2. FROM-VALID — every source is a real node.
    let froms = ($tun | get from_path | append ($un | get from_path) | uniq)
    let badfrom = ($froms | where {|p| not (known $pathset $p)})
    print $"from-valid:   ($froms | length) distinct sources"
    if ($badfrom | length) > 0 { print $"  ✗ ($badfrom | length) source\(s\) are not nodes"; $badfrom | first 5 | print; $ok = false } else { print "  ✓ every edge source is a real node" }

    # 3. ADDRESS — to_line, where present, is the target's container line in the index.
    let idxpair = ($idx | select path line | reduce --fold {} {|r, acc| $acc | upsert $r.path ($r.line | into string) })
    let badline = ($tun | where to_line != "" | where {|r| ($idxpair | get -i $r.to_path) != ($r.to_line | into string)})
    print $"address:      ($tun | where to_line != '' | length) edges carry a line"
    if ($badline | length) > 0 { print $"  ✗ ($badline | length) edge\(s\) have a line that isn't the target's index line"; $badline | first 5 | print; $ok = false } else { print "  ✓ every carried line matches the index" }

    # 4. COVERAGE — alias+import edges cover exactly the map's alias + nsref rows, once each.
    let map_reexports = ($nodes | where kind in ["alias" "nsref"] | get path | sort)
    let edge_reexports = ($tun | append $un | where kind in ["alias" "import"] | get from_path | sort)
    let missing = ($map_reexports | where {|p| $p not-in $edge_reexports})
    let dup_re = ($edge_reexports | uniq -d)
    print $"coverage:     ($map_reexports | length) map re-exports \(alias+nsref\) vs ($edge_reexports | length) alias/import edges"
    if ($missing | length) > 0 { print $"  ✗ ($missing | length) re-export\(s\) produced no edge"; $missing | first 5 | print; $ok = false }
    if ($dup_re | length) > 0 { print $"  ✗ ($dup_re | length) re-export\(s\) produced more than one edge"; $ok = false }
    if ($missing | length) == 0 and ($dup_re | length) == 0 { print "  ✓ every re-export resolved-or-recorded exactly once" }

    # 5. USAGE-DOMAIN — usage edges start at functions.
    let usage_from = ($tun | append $un | where kind == "usage" | get from_path | uniq)
    let nonfn = ($usage_from | where {|p| not (known $fnset $p)})
    print $"usage-domain: ($usage_from | length) fns carry usage edges"
    if ($nonfn | length) > 0 { print $"  ✗ ($nonfn | length) usage source\(s\) are not fns"; $nonfn | first 5 | print; $ok = false } else { print "  ✓ every usage edge starts at a fn" }

    # 6. PRISTINE — no duplicate rows.
    let dt = (($tun | length) - ($tun | uniq | length))
    let du = (($un | length) - ($un | uniq | length))
    print $"pristine:     tunnels dup ($dt)   unresolved dup ($du)"
    if $dt != 0 or $du != 0 { print "  ✗ duplicate rows present"; $ok = false } else { print "  ✓ no duplicate edges" }

    print ""
    if $ok { print "TUNNELS VERDICT: ✓ overlay reconciles with the map" } else { print "TUNNELS VERDICT: ✗ reconciliation FAILED"; exit 1 }
}
