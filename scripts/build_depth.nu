#!/usr/bin/env nu
# build_depth.nu — the L5 (resolved depth) overlay.
#
# Reflection evaluates decls, so a single platform-gated / @compileError ("poison") decl
# makes a reflecting program fail to compile. The defense is isolation: reflect ONE
# container per subprocess (src/resolve.zig, its TARGET lines rewritten per call). A poison
# container fails only its own process — recorded as `path · reason` — while every clean
# container resolves. Run the whole map and the poison reports itself; no target is hunted
# by hand. Depth on demand for one container, the full overlay for the sweep — same unit.
#
#   resolved.tsv   path · kind · detail   (resolved const VALUES, expanded generics, typed sigs)
#   redirects.tsv  path · redirect_to     (a dead-end alias: its parent IS the real one)
#   poison.tsv     path · reason          (genuinely unresolvable: platform / foreign lib / @compileError)
#
# A path can dead-end two ways. POISON is real: the compiler can't analyze it here (a Windows
# decl referencing kernel32 on Linux, a comptime @compileError). A REDIRECT is not a failure of
# the container — it's a redundant alias path (`…Blake3.Blake3`) whose last segment isn't a member
# because the parent already IS that type. We do NOT point backwards and resolve it there; the
# canonical path is its own container and resolves on its own turn. We just record the redirect.
#
# Outputs go to --out (a scratch dir) unless --commit, which writes the overlay into data/std.
#
# Usage:
#   nu scripts/build_depth.nu --only std.crypto.hash.sha2     # one container (depth on demand)
#   nu scripts/build_depth.nu --filter crypto                 # every container whose path contains it
#   nu scripts/build_depth.nu --limit 50                      # first N (cheap smoke of the sweep)
#   nu scripts/build_depth.nu --commit                        # full sweep → data/std/{resolved,poison}.tsv

const TEMPLATE = "src/resolve.zig"
const SCRATCH = "/tmp/zephem-depth"

# Rewrite resolve.zig's two TARGET lines for `path`. The access chain is the path tail
# appended to @import("std") (path[3..] drops the leading "std").
def gen [path: string] {
    # plain (non-interpolated) concat so the literal parens in @import("std") survive
    let tail = (if $path == "std" { "" } else { ($path | str substring 3..) })
    let access = ('@import("std")' + $tail)
    (open --raw $TEMPLATE
        | str replace --regex '(?m)^const TARGET_PATH = .*$' $'const TARGET_PATH = "($path)";'
        | str replace --regex '(?m)^const TARGET = .*$' ('const TARGET = ' + $access + ';'))
}

def main [--only: string, --filter: string, --limit: int = 0, --timeout: int = 30, --out: string = "/tmp/zephem-depth/out", --commit] {
    let idx = (open data/std/index.tsv)
    mut targets = (
        if ($only | is-not-empty) { [$only] }
        else if ($filter | is-not-empty) { $idx | get path | where ($it | str contains $filter) }
        else { $idx | get path }
    )
    if $limit > 0 { $targets = ($targets | first $limit) }
    let outdir = (if $commit { "data/std" } else { $out })
    mkdir $outdir
    mkdir $SCRATCH

    print $"[L5] reflecting ($targets | length) container\(s\) — ($timeout)s timeout each, poison isolated per process"
    mut resolved = []
    mut poison = []
    mut redirect = []
    mut status = []   # per-container ledger: path · status · n_rows (the verifier re-derives from this)
    for path in $targets {
        (gen $path) | save -f $"($SCRATCH)/r.zig"
        let r = (do { ^timeout $"($timeout)s" zig run $"($SCRATCH)/r.zig" } | complete)
        if $r.exit_code == 0 {
            let rows = ($r.stdout | lines | skip 1 | where ($it | is-not-empty))
            $resolved = ($resolved | append $rows)
            $status = ($status | append $"($path)\tresolved\t($rows | length)")
        } else if ($r.stderr | str contains "has no member named") {
            # dead-end alias: the last segment duplicates a parent that already IS the type.
            # Don't point backwards — record the redirect to the canonical (parent) path.
            let canonical = ($path | split row "." | drop 1 | str join ".")
            $redirect = ($redirect | append $"($path)\t($canonical)")
            $status = ($status | append $"($path)\tredirect\t0")
        } else {
            # genuine poison. First compiler `error:` line is the reason; fall back to stderr / exit.
            let err = ($r.stderr | lines | where ($it =~ 'error:') | first)
            let reason = ($err | default ($r.stderr | lines | where ($it | str trim | is-not-empty) | first | default $"exit ($r.exit_code)"))
            $poison = ($poison | append $"($path)\t($reason | str trim)")
            $status = ($status | append $"($path)\tpoison\t0")
        }
    }

    let n_poison = ($poison | length)
    let n_redirect = ($redirect | length)
    let n_ok = (($targets | length) - $n_poison - $n_redirect)
    (["path\tstatus\tn_rows"] | append $status | str join "\n") + "\n" | save -f $"($outdir)/status.tsv"
    (["path\tkind\tdetail"] | append $resolved | str join "\n") + "\n" | save -f $"($outdir)/resolved.tsv"
    (["path\tredirect_to"] | append $redirect | str join "\n") + "\n" | save -f $"($outdir)/redirects.tsv"
    (["path\treason"] | append $poison | str join "\n") + "\n" | save -f $"($outdir)/poison.tsv"

    print $"[L5] resolved: ($n_ok) containers, ($resolved | length) rows   redirect: ($n_redirect)   poison: ($n_poison)   attempted: ($targets | length)"
    print $"[L5] → ($outdir)/{status,resolved,redirects,poison}.tsv"
    if $n_redirect > 0 and $n_redirect <= 20 {
        print "[L5] alias redirects (path → use instead):"
        $redirect | each {|x| print $"   ($x)" } | ignore
    }
    if $n_poison > 0 and $n_poison <= 20 {
        print "[L5] poison (path · reason):"
        $poison | each {|p| print $"   ($p)" } | ignore
    }

    # ---- verification: re-read the buckets a SECOND way and reconcile with the map ----
    print "[L5] verifying — reading the overlay back the other way..."
    let vargs = (if $commit { [$outdir "--full"] } else { [$outdir] })
    let v = (do { ^nu scripts/verify_depth.nu ...$vargs } | complete)
    print $v.stdout
    if $v.exit_code != 0 { print "build_depth: ✗ overlay rejected by verify_depth"; exit 1 }
}
