# lib.nu — shared glue for zephem's query layer.
# The query tools (zlook / zmap / build_lookup) read zephem's own datasets and must
# refuse to serve facts from a map that no longer matches the installed Zig. These three
# helpers are that freshness gate. They moved here from zcanon: whoever owns the data
# owns the query layer over it.

# Installed Zig's std dir + version (the source of truth — never snapshot it).
export def zig-env [] {
    let out = (^zig env | str join)
    {
        std: ($out | parse --regex '\.std_dir\s*=\s*"(?<v>[^"]+)"' | get v.0)
        ver: ($out | parse --regex '\.version\s*=\s*"(?<v>[^"]+)"' | get v.0)
    }
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
