#!/usr/bin/env nu
# build_sigshape.nu — the signature-shape census: classify each fn's as-written signature.
#
# sigs.tsv holds 5,377 fn signatures verbatim. Read flat they're just strings; this overlay
# decomposes each into a few structural facts so std's API ergonomics become groupable. One job.
#
#   sigshape.tsv   path · first_param · io · generic
#
#   first_param  none       no parameters
#                self       receiver-style — first param named self/this (a method)
#                allocator  first param is an Allocator
#                other      anything else (a free function over its args)
#   io           yes if the signature references Io (the 0.16 Io-threading convention)
#   generic      yes if it has a comptime/anytype parameter
#
# Reads sigs.tsv alone, one row per signature, every field a closed set. Self-checking. Writes
# data/std/derived/sigshape.tsv + SHA256SUMS.sigshape; --check rebuilds byte-identical.
#
# Usage:  nu scripts/build_sigshape.nu [--dir data/std]
#         nu scripts/build_sigshape.nu --check

const MANIFEST = "data/std/SHA256SUMS.sigshape"

# The substring inside the FIRST balanced (...) group — i.e. the parameter list.
def param-list [sig: string] {
    mut depth = 0
    mut started = false
    mut out = []
    for c in ($sig | split chars) {
        if $c == "(" {
            if not $started { $started = true; $depth = 1; continue }
            $depth = $depth + 1
        } else if $c == ")" {
            $depth = $depth - 1
            if $depth == 0 { break }
        }
        if $started { $out = ($out | append $c) }
    }
    $out | str join
}

# The first top-level parameter: split the list on depth-0 commas, keep the first.
def first-of [plist: string] {
    mut depth = 0
    mut out = []
    for c in ($plist | split chars) {
        if $c in ["(" "[" "{"] { $depth = $depth + 1 }
        if $c in [")" "]" "}"] { $depth = $depth - 1 }
        if ($c == ",") and ($depth == 0) { break }
        $out = ($out | append $c)
    }
    $out | str join | str trim
}

def classify [sig: string] {
    let plist = (param-list $sig)
    let fp = (first-of $plist)
    let first_param = (if ($plist | str trim) == "" {
            "none"
        } else {
            let name = ($fp | split row ":" | first | str trim)
            if $name in ["self" "this"] { "self" } else if ($fp | str contains "Allocator") { "allocator" } else { "other" }
        })
    {
        first_param: $first_param,
        io: (if ($sig | str contains "Io") { "yes" } else { "no" }),
        generic: (if (($plist | str contains "comptime ") or ($plist | str contains "anytype")) { "yes" } else { "no" }),
    }
}

def derive [dir: string] {
    if not ($"($dir)/extracted/sigs.tsv" | path exists) { print $"missing ($dir)/extracted/sigs.tsv"; exit 1 }
    open $"($dir)/extracted/sigs.tsv" | each {|r|
        let c = (classify $r.sig)
        {path: $r.path, first_param: $c.first_param, io: $c.io, generic: $c.generic}
    } | sort-by path
}

def main [--dir: string = "data/std", --check] {
    if $check {
        if not ($MANIFEST | path exists) { print $"[sigshape check] no ($MANIFEST) — build first"; exit 1 }
        let fresh = (derive $dir | to tsv)
        let want = (open $MANIFEST | lines | first | parse -r '(?<hash>\S+)' | get hash.0)
        let got = ($fresh | hash sha256)
        if $got == $want { print $"[sigshape check] ✓ rebuilds byte-identical \(($got)\)" } else {
            print $"[sigshape check] ✗ DRIFT — manifest ($want) vs rebuild ($got)"; exit 1
        }
        return
    }
    let rows = (derive $dir)
    $rows | to tsv | save -f $"($dir)/derived/sigshape.tsv"
    let n = ($rows | length)
    print $"[sigshape] ($n) fns → ($dir)/derived/sigshape.tsv"
    print "  first parameter:"
    $rows | group-by first_param | items {|k, v| {first_param: $k, n: ($v | length)}} | sort-by n --reverse | print
    print $"  Io-threading: ($rows | where io == 'yes' | length)   generic \(comptime/anytype\): ($rows | where generic == 'yes' | length)"
    let h = ($rows | to tsv | hash sha256)
    $"($h)  data/std/derived/sigshape.tsv\n" | save -f $MANIFEST
    print $"[sigshape] manifest → ($MANIFEST)  \(run --check to prove it rebuilds\)"
}
