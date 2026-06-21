#!/usr/bin/env nu
# build_tunnels.nu — the L3 (reference graph / tunnels) overlay.
#
# mapper/tunnels.zig resolves every reference (alias re-exports, import bindings, and the type
# names in fn signatures) to the canonical logical `path` it points at, parsing each file's root
# for pub AND private bindings so private import aliases (`const Allocator = std.mem.Allocator`)
# resolve. It emits one tagged stream:
#
#   from_path · kind · status · to_or_raw · reason
#     status=resolved   to_or_raw = a to_path GUARANTEED present in nodes.tsv
#     status=primitive  to_or_raw = a built-in (u8, void, …) — resolves to nothing by design
#     status=unresolved to_or_raw = the raw ref, reason = why (recorded, never dropped)
#
# This script splits that into two datasets and attaches each edge's destination line:
#
#   tunnels.tsv     from_path · kind · to_path · to_line   (resolved edges; to_line from index.tsv
#                   when the target is a container, "" for a leaf — its parent block holds it)
#   unresolved.tsv  from_path · kind · raw · reason         (primitive + unresolved, every ref kept)
#
# SOUND, not complete: the layer never invents an edge — an endpoint is always a real node.
# Reproducible: tunnels.zig is a pure parse, so the output is deterministic; --check proves it.
#
# Usage:
#   nu scripts/build_tunnels.nu            # build + verify + manifest
#   nu scripts/build_tunnels.nu --check    # prove the committed overlay rebuilds

const NAMES = ["tunnels.tsv" "unresolved.tsv"]
const MANIFEST = "data/std/SHA256SUMS.tunnels"

def std-root [] {
    let std_dir = (^zig env | lines | parse -r '\.std_dir = "(?<p>[^"]+)"' | get p.0)
    $"($std_dir)/std.zig"
}

# Resolve references and write tunnels.tsv + unresolved.tsv into `outdir`. The single build
# path, shared by the normal build and --check, so they cannot diverge.
def regen [root: string, outdir: string] {
    mkdir $outdir
    let raw = (^zig run mapper/tunnels.zig -- $root data/std/nodes.tsv | from tsv)
    # container → line, for attaching a followable address to resolved edges.
    let idx = (open data/std/index.tsv | select path line)

    let resolved = ($raw | where status == "resolved"
        | select from_path kind to_or_raw | rename --column {to_or_raw: to_path}
        | join --left $idx to_path path
        | select from_path kind to_path line | rename --column {line: to_line}
        | update to_line {|r| $r.to_line | default "" })
    # non-edges, each kept with a clear category in `reason`:
    #   primitive            — a built-in (u8, void)
    #   internal: <target>   — a real "pub → private" link (the public ref reaches into private
    #                          internals we don't map); informative, not a gap
    #   <specific reason>    — a genuine unresolved gap (multi-hop tail, type param, …)
    let other = ($raw | where status != "resolved"
        | select from_path kind to_or_raw status reason
        | each {|r| {from_path: $r.from_path, kind: $r.kind, raw: $r.to_or_raw,
                     reason: (if $r.status == "primitive" { "primitive"
                              } else if $r.status == "internal" { $"internal: ($r.reason)"
                              } else { $r.reason })} })

    # dedup: a signature may name the same type twice — one graph edge, not two.
    $resolved | uniq | to tsv | save -f $"($outdir)/tunnels.tsv"
    $other | uniq | to tsv | save -f $"($outdir)/unresolved.tsv"
}

def hashes [dir: string] {
    $NAMES | reduce --fold {} {|n, acc| $acc | insert $n (open --raw $"($dir)/($n)" | hash sha256) }
}

def main [--check] {
    let root = (std-root)

    if $check {
        if not ($MANIFEST | path exists) { print $"[tunnels check] no ($MANIFEST) — build first"; exit 1 }
        print "[tunnels check] proving the overlay rebuilds (intrinsic + regression + integrity)"
        let committed = (hashes "data/std")
        let manifest = (open $MANIFEST | lines | parse -r '(?<hash>\S+)\s+data/std/(?<name>\S+)'
            | reduce --fold {} {|r, acc| $acc | insert $r.name $r.hash })
        regen $root "/tmp/zephem-tunnels/a"
        regen $root "/tmp/zephem-tunnels/b"
        let a = (hashes "/tmp/zephem-tunnels/a")
        let b = (hashes "/tmp/zephem-tunnels/b")
        mut ok = true
        for n in $NAMES {
            let intrinsic = (($a | get $n) == ($b | get $n))
            let regression = (($a | get $n) == ($manifest | get -i $n))
            let integrity = (($committed | get $n) == ($manifest | get -i $n))
            if (not $intrinsic) or (not $regression) or (not $integrity) { $ok = false }
            print $"  ($n): intrinsic (if $intrinsic {'✓'} else {'✗'})   reproduces-manifest (if $regression {'✓'} else {'✗'})   on-disk-matches-manifest (if $integrity {'✓'} else {'✗'})"
        }
        rm -rf /tmp/zephem-tunnels
        if $ok { print "tunnels reproducible: ✓" } else { print "tunnels reproducible: ✗ DRIFT"; exit 1 }
        return
    }

    print $"[L3] resolving references in ($root)"
    regen $root "data/std"

    let t = (open data/std/tunnels.tsv)
    let u = (open data/std/unresolved.tsv)
    let by_kind = ($t | group-by kind | items {|k, rows| $"($k) ($rows | length)" } | str join "  ")
    print $"[L3] tunnels: (($t | length)) resolved edges   \(($by_kind)\)"
    let prim = ($u | where reason == "primitive" | length)
    let intl = ($u | where reason =~ '^internal' | length)
    let gap = (($u | length) - $prim - $intl)
    print $"[L3] recorded non-edges: ($intl) internal \(pub→private\)   ($prim) primitive   ($gap) genuine gaps"

    print "[L3] verifying — reading the overlay back against the map..."
    let v = (do { ^nu scripts/verify_tunnels.nu data/std } | complete)
    print $v.stdout
    if $v.exit_code != 0 { print "build_tunnels: ✗ overlay rejected by verify_tunnels"; exit 1 }

    let m = ($NAMES | each {|n| let h = (open --raw $"data/std/($n)" | hash sha256); $"($h)  data/std/($n)" } | str join "\n")
    $"($m)\n" | save -f $MANIFEST
    print $"[L3] manifest → ($MANIFEST)  \(run --check to prove it rebuilds\)"
}
