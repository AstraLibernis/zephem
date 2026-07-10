# lib.nu — shared glue for zephem's query layer.
# The query tools (zlook / zmap / build_lookup) read zephem's own datasets and must
# refuse to serve facts from a map that no longer matches the installed Zig. These three
# helpers are that freshness gate. They moved here from zcanon: whoever owns the data
# owns the query layer over it.

# Installed Zig's version (the source of truth — never snapshot it).
export def zig-env [] {
    let out = (^zig env | str join)
    { ver: ($out | parse --regex '\.version\s*=\s*"(?<v>[^"]+)"' | get v.0) }
}

# zephem's repo root, self-located from this file (query/lib.nu → repo root).
# `path self` only runs at parse time, so we capture it once into a const here and
# every helper derives from it — the tools work wherever the repo is cloned, with no
# install path baked in and no env var required.
const ZEPHEM_ROOT = (path self | path dirname | path dirname)

# Default data dir for zephem's datasets ($ZEPHEM_DATA overrides). Derived from the
# self-located repo root above, so the default map location lives in exactly one place.
export def zephem-dir [] { $env.ZEPHEM_DATA? | default ($ZEPHEM_ROOT | path join data std) }

# long-form attrs → a narrow {path, <col>} table for one attr, deduped 1:1 on path.
export def attr-col [attrs: table, name: string, col: string] {
    $attrs | where attr == $name | select path value | rename --column {value: $col} | uniq-by path
}

# ---- map freshness --------------------------------------------------------
# The map is derived from ONE std snapshot; zephem stamps that version in
# data/std/PINNED (e.g. "zig 0.16.0"). Staleness therefore reduces to a version
# compare — no hashing or mtimes. Return the pinned version ("0.16.0"), or null
# if the stamp is missing/absent.
export def zephem-pinned [dir: string] {
    let p = ($dir | path join PINNED)
    if ($p | path exists) { (open --raw $p | str trim | str replace 'zig ' '') } else { null }
}

# One-line staleness check: pinned map version vs the installed zig. Returns a
# human warning string when they differ (or the stamp is missing), else "".
# The map is the SOLE source of truth — there is no live fallback — so on a version
# mismatch the fix is to REGENERATE the map, never to trust memory. Callers decide
# severity: reading WARNS; building the baked lookup table (read later without the
# datasets present) should refuse.
export def zephem-staleness [dir: string] {
    let pinned = (zephem-pinned $dir)
    let live = (try { (zig-env).ver } catch { null })
    if ($pinned == null) {
        $"⚠ zephem map at ($dir) has no PINNED stamp — cannot verify it matches your zig; regenerate it with `nu scripts/build_std.nu`."
    } else if (($live != null) and ($pinned != $live)) {
        $"⚠ zephem map is pinned to zig ($pinned) but you're on ($live) — map may be stale; discovered facts could be wrong. Regenerate the map: `nu scripts/build_std.nu` then `nu query/build_lookup.nu`."
    } else { "" }
}

# Default path for the baked lookup table zlook reads ($ZEPHEM_LOOKUP overrides).
# Shared so the location lives in one place: build_lookup writes it, zlook reads it.
export def lookup-path [] { $env.ZEPHEM_LOOKUP? | default ([$env.HOME ".config" zephem lookup.tsv] | path join) }

# The dataset files build_lookup joins into the baked lookup — the lookup's inputs.
# One list so the build's existence-check and the read's staleness-check can't drift.
export def lookup-inputs [] {
    ["extracted/nodes.tsv" "extracted/attrs.tsv" "extracted/edges.tsv"
     "extracted/resolved.tsv" "derived/index.tsv" "derived/canon.tsv"]
}

# ---- lookup freshness (baked index vs the streams it was built from) -------
# zlook reads a BAKED lookup.tsv, not the streams. If the streams are regenerated
# afterward WITHOUT rebuilding the lookup, the index is stale — but zephem-staleness
# (a zig-version compare) can't see it: the version is unchanged. This catches that
# gap by mtime — is the baked lookup older than any stream it derives from?
# Best-effort: if the datasets aren't present (the portable-lookup case the build
# warns about), we can't check, so stay silent. Returns a warning string when the
# lookup predates an input, else "".
export def lookup-staleness [lookup: string, dir: string] {
    if not ($lookup | path exists) { return "" }
    let inputs = ((lookup-inputs) | each {|f| $dir | path join $f } | where {|p| $p | path exists })
    if ($inputs | is-empty) { return "" }
    let lookup_m = (ls $lookup | get 0.modified | into int)
    let newest   = ($inputs | each {|p| ls $p | get 0.modified | into int } | math max)
    if $newest > $lookup_m {
        $"⚠ zephem lookup.tsv is older than its source streams — the baked index is STALE \(zlook may miss or misreport symbols\). Rebuild it: `nu query/build_lookup.nu`."
    } else { "" }
}
