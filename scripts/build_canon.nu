#!/usr/bin/env nu
# build_canon.nu — the canon overlay: DEDUP / DEALIAS. One job, one input.
#
# The compiler resolves every type to a canonical @typeName (alias and generic already expanded;
# see reflect/resolve.zig). So two different source PATHS that name the SAME underlying type
# resolve to the SAME @typeName. This overlay surfaces exactly those collisions — the alias/dup
# families — and nothing else. It reads ONE file, resolved.tsv, and holds no opinion beyond
# "same resolved identity = same thing".
#
#   canon.tsv   path · canon     (canon = the shared @typeName; every canon appears on >= 2 paths)
#
# A family is one canon value and the >= 2 paths that resolve to it — `std.BufMap` and
# `std.buf_map.BufMap` both → `buf_map.BufMap`; six paths all → `crypto.25519.scalar`. Sorted by
# canon then path, so each family is a contiguous block. Two kinds of collision both count:
#   • re-export ALIAS    — one decl reached by two names (`Sha256`, the file that defines it)
#   • structural DUP     — distinct decls of an identical composite type (`[32]u8`, a digest)
#
# Three identity classes are EXCLUDED as noise — they collide by accident, not by aliasing:
#   • bare primitives (u32, usize, bool, …)   — every program is full of them; sharing is trivial
#   • anonymous error sets (`error{…}`)        — collide only when structurally identical; huge cells
#   • anonymous types (`__struct/__enum/…`)    — the reproducibility-normalized marker would merge
#                                                unrelated anon types into one bogus family
#
# Pure, deterministic, self-checking. Writes data/std/canon.tsv + SHA256SUMS.canon; --check rebuilds.
#
# Usage:  nu scripts/build_canon.nu [--dir data/std]
#         nu scripts/build_canon.nu --check

const MANIFEST = "data/std/SHA256SUMS.canon"

# A nominal/relocatable identity worth deduping — excludes bare primitives, error sets, anon markers.
def nominal [id: string] {
    not (($id | str starts-with "error{")
      or ($id =~ '__(struct|enum|union|opaque)')
      or ($id =~ '^(void|anyopaque|anyerror|anyframe|bool|type|noreturn|comptime_int|comptime_float|isize|usize|[uif][0-9]+|c_[a-z]+)$'))
}

# Derive the dedup/dealias families from resolved.tsv alone.
def derive [dir: string] {
    if not ($"($dir)/resolved.tsv" | path exists) { print $"missing ($dir)/resolved.tsv"; exit 1 }
    let types = (open $"($dir)/resolved.tsv" | where kind == "type" | where {|r| nominal $r.detail})
    # keep only identities shared by >= 2 paths — those, and only those, are the families.
    let shared = ($types | group-by detail | items {|id, rows| if ($rows | length) > 1 { $id } else { null } } | compact)
    let sset = ($shared | reduce --fold {} {|s, acc| $acc | upsert $s true })
    $types | where {|r| ($sset | get -o $r.detail) == true}
        | each {|r| {path: $r.path, canon: $r.detail} }
        | sort-by canon path
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
    let families = ($rows | get canon | uniq | length)
    print $"[canon] ($rows | length) aliased/duplicated paths in ($families) families → ($dir)/canon.tsv"
    print "── largest families ──"
    $rows | group-by canon | items {|k, v| {canon: $k, n: ($v | length)}} | sort-by n --reverse | first 5 | print
    let h = ($rows | to tsv | hash sha256)
    $"($h)  data/std/canon.tsv\n" | save -f $MANIFEST
    print $"[canon] manifest → ($MANIFEST)  \(run --check to prove it rebuilds\)"
}
