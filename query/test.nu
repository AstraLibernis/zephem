#!/usr/bin/env nu
# test.nu — zephem query-layer smoke battery. Asserts std facts through the two lookup
# tools: zlook (SIMD search over the baked lookup table, via its build-if-stale wrapper)
# and zmap (reads the extracted TSVs directly). Run against the installed Zig's map.
#   nu query/test.nu
let here  = $env.FILE_PWD
let zlook = ($here | path join zlook.nu)
let zmap  = ($here | path join zmap.nu)
let zdata = ($env.ZEPHEM_DATA? | default ($here | path dirname | path join data std))
mut fail = 0

def run [args: list<string>] {
    let r = (^nu ...$args | complete)
    [$r.stdout, $r.stderr] | str join
}

if not ($zdata | path join extracted nodes.tsv | path exists) {
    print $"SKIP: zephem map not at ($zdata) — run nu scripts/build_std.nu"; exit 0
}

# --- build the lookup table if absent (zlook's input) ---
let lookup = ($env.ZEPHEM_LOOKUP? | default ($env.HOME | path join .config zephem lookup.tsv))
if not ($lookup | path exists) {
    print "building lookup.tsv ..."
    ^nu ($here | path join build_lookup.nu)
}

# --- zlook: keyword lookup over the baked lookup table ---
let zcases = [
    ["factory member path"        ["HashMap" "get"]  "HashMap().get"]
    ["factory member signature"   ["HashMap" "get"]  "fn get("]
    ["resolved error-set search"  ["OutOfMemory"]    "OutOfMemory"]
    ["delegation target shown"    ["AutoHashMap"]    "⇒"]
]
for c in $zcases {
    let o = (run ([$zlook] ++ $c.1))
    if ($o | str contains $c.2) { print $"PASS: ($c.0)" } else { print $"FAIL: ($c.0) \(expected substring: ($c.2))"; $fail = 1 }
}

# --- zmap reader (the case the old embedding search failed) ---
let pi = (run [$zmap find parse int --limit 5])
if ($pi | str contains "std.fmt.parseInt") { print "PASS: zmap find surfaces fmt.parseInt" } else { print "FAIL: zmap find did not surface fmt.parseInt"; $fail = 1 }
let ct = (run [$zmap find "constant time" --limit 8])
if ($ct | str contains "timing_safe") { print "PASS: zmap find surfaces timing_safe" } else { print "FAIL: zmap find did not surface timing_safe"; $fail = 1 }

if $fail == 0 { print "--- all passed ---" } else { print "--- failures present ---"; exit 1 }
