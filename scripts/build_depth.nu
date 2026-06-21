#!/usr/bin/env nu
# build_depth.nu — the L5 (resolved depth) overlay, for the WHOLE map.
#
# Reflection evaluates decls, so a single platform-gated / @compileError ("poison") decl
# makes a reflecting program fail to compile. The defense is isolation: reflect ONE
# container per subprocess (reflect/resolve.zig, its TARGET lines rewritten per call). A poison
# container fails only its own process — recorded as `path · reason` — while every clean
# container resolves. The full overlay is the sweep over EVERY container in the map; the same
# unit also serves a single `--only` container (depth on demand). Poison reports itself; no
# target is hunted by hand.
#
#   resolved.tsv   path · kind · detail   (resolved const VALUES, expanded generics, typed sigs)
#   poison.tsv     path · reason          (didn't resolve: platform / foreign lib / @compileError / timeout)
#   status.tsv     path · status · n_rows (per-container ledger; the verifier re-derives from this)
#
# Binary outcome per container: it RESOLVED (works) or it's POISON (doesn't). Poison is anything
# the compiler couldn't analyze here — a Windows decl referencing kernel32 on Linux, a comptime
# @compileError — recorded with the compiler's own first error line as the reason. We don't try to
# second-guess or re-label that verdict; works-or-doesn't is the whole truth. The one non-compiler
# outcome is a timeout: it gets its own honest reason (`timeout after Ns`) so it can never
# masquerade as a compile error.
#
# REPRODUCIBILITY (separate from --commit ON PURPOSE — it is SLOW). The map (build_std.nu) is a
# parse, so its --check is instant; an L5 rebuild is a full reflection sweep, and --check runs
# TWO of them. Wall time is MACHINE-DEPENDENT and varies widely: a cold sweep measured ≈13 min
# on a 3-core VM but well under a minute on a many-core desktop (see docs/reproducibility.md for
# the timing table and why these are a relative reference, not a benchmark). So L5 reproducibility
# lives HERE, never wired into build_std.nu's --check, which must stay fast. Two volatile inputs
# are normalized out so the bytes are stable (without this, --check false-fails):
#   • anonymous-type disambiguators `__struct_NNNN` — a semantic-analysis counter that DRIFTS
#     between otherwise-identical compiles (proven: two sweeps of std.Io disagreed only here).
#     The kind marker (__struct/__enum/__union/__opaque) is stable and kept; only the digits drop.
#   • absolute toolchain paths in poison reasons (`/usr/lib/zig/std/…`, the `/tmp/.../r.zig`
#     scratch file) — rendered relative (`std/…`, `<gen>/…`), matching the map's relPath contract.
#
# PARALLELISM. The sweep is data-parallel — the same op (reflect a container) over 1,355
# independent items — so it runs one lane per available CPU (SIMD-style), detected adaptively
# via `nproc`. Each lane reflects in its OWN scratch file + subprocess, so lanes never collide;
# results are sorted back to target order before assembly, so the bytes are byte-identical to a
# serial sweep — only faster. Override the lane count with --jobs N (--jobs 1 = serial).
#
# Outputs go to --out (a scratch dir) unless --commit, which writes the overlay into data/std
# AND records data/std/SHA256SUMS.depth. `--check` then proves that snapshot rebuilds.
#
# Usage:
#   nu scripts/build_depth.nu --only std.crypto.hash.sha2     # one container (depth on demand)
#   nu scripts/build_depth.nu --filter crypto                 # every container whose path contains it
#   nu scripts/build_depth.nu --limit 50                      # first N (cheap smoke of the sweep)
#   nu scripts/build_depth.nu --commit                        # full sweep → data/std + SHA256SUMS.depth
#   nu scripts/build_depth.nu --check                         # prove the committed overlay rebuilds
#   nu scripts/build_depth.nu --commit --jobs 3               # cap parallelism (default = all CPUs)

const TEMPLATE = "reflect/resolve.zig"
const SCRATCH = "/tmp/zephem-depth"
const NAMES = ["status.tsv" "resolved.tsv" "poison.tsv"]
const MANIFEST = "data/std/SHA256SUMS.depth"

# turn a list of container paths into {parent, child} rows (child = last segment).
def insert-parent [] {
    each {|p| {parent: ($p | split row "." | drop 1 | str join "."), child: ($p | split row "." | last)} }
}

# Rewrite resolve.zig's two TARGET lines for `path`. The access chain is the path tail
# appended to @import("std") (path[3..] drops the leading "std").
# `skip` = the names of this container's DIRECT child containers (don't descend into them).
def gen [path: string, skip: list<string>] {
    # plain (non-interpolated) concat so the literal parens in @import("std") survive
    let tail = (if $path == "std" { "" } else { ($path | str substring 3..) })
    let access = ('@import("std")' + $tail)
    let skip_lit = (if ($skip | is-empty) {
        "[_][]const u8{}"
    } else {
        '[_][]const u8{ ' + ($skip | each {|n| '"' + $n + '"' } | str join ", ") + ' }'
    })
    (open --raw $TEMPLATE
        | str replace --regex '(?m)^const TARGET_PATH = .*$' $'const TARGET_PATH = "($path)";'
        | str replace --regex '(?m)^const TARGET = .*$' ('const TARGET = ' + $access + ';')
        | str replace --regex '(?m)^const SKIP = .*$' ('const SKIP = ' + $skip_lit + ';'))
}

# The active toolchain's std dir — the absolute prefix we strip from poison reasons so the
# overlay is location-independent. `zig env` emits ZON, not JSON; pull the path out.
def std-dir [] {
    ^zig env | lines | parse -r '\.std_dir = "(?<p>[^"]+)"' | get p.0
}

# Strip the volatile anonymous-type disambiguator digits (see header). Kind marker kept.
# Covers every anonymous-type kind Zig assigns a counter to: struct/union/enum AND opaque
# (opaque drifts identically across machines — e.g. `Handle__opaque_34566` vs `__opaque_34608`).
def norm-row [] {
    str replace --regex --all '__(struct|union|enum|opaque)_[0-9]+' '__${1}'
}

# sha256 of each overlay file in `dir`, as a {name: hash} record (raw bytes — no parsing).
def hashes [dir: string] {
    $NAMES | reduce --fold {} {|n, acc| $acc | insert $n (open --raw $"($dir)/($n)" | hash sha256) }
}

# Available CPUs — `nproc` (honors cgroup/affinity limits), falling back to the logical count.
# This is the adaptive lane count: the sweep is data-parallel (same op, many containers), so we
# run one lane per CPU, SIMD-style. Override with --jobs.
def ncpu [] {
    let r = (do { ^nproc } | complete)
    if $r.exit_code == 0 { $r.stdout | str trim | into int } else { sys cpu | length }
}

# Reflect ONE container `path` (index `i`) — the per-lane unit of work. Each lane writes its
# OWN scratch file (r-<i>.zig) so concurrent lanes never collide on the shared template output.
# Returns a tagged record carrying `i`, so the caller can restore target order after the
# parallel pass (concurrency loses the serial loop's free ordering).
def reflect-one [i: int, path: string, skip: list<string>, timeout: int, std_dir: string] {
    let rfile = $"($SCRATCH)/r-($i).zig"
    (gen $path $skip) | save -f $rfile
    let r = (do { ^timeout $"($timeout)s" zig run $rfile } | complete)
    if $r.exit_code == 0 {
        # WORKS — the compiler resolved it. Record the rows.
        let rows = ($r.stdout | lines | skip 1 | where ($it | is-not-empty) | each {|x| $x | norm-row })
        {i: $i, srow: $"($path)\tresolved\t($rows | length)", rows: $rows, prow: null}
    } else {
        # DOESN'T — poison. A timeout (exit 124) is the one non-compiler case: tag it honestly so
        # it can never masquerade as a compile error (the old `exit 124` mislabel). Otherwise the
        # reason is the compiler's own first `error:` line; absolute toolchain paths and the
        # per-lane scratch file are rendered relative so it's reproducible and lane-independent:
        # /usr/lib/zig/std/… → std/…, …/r-<i>.zig → <gen>.
        let reason = (if $r.exit_code == 124 {
            $"timeout after ($timeout)s"
        } else {
            let err = ($r.stderr | lines | where ($it =~ 'error:') | first)
            ($err | default ($r.stderr | lines | where ($it | str trim | is-not-empty) | first | default $"exit ($r.exit_code)")
                | str trim
                | str replace --regex --all '/tmp/zephem-depth/r-[0-9]+\.zig' '<gen>'
                | str replace --all $"($std_dir)/" "std/")
        })
        {i: $i, srow: $"($path)\tpoison\t0", rows: [], prow: $"($path)\t($reason)"}
    }
}

# Sweep `targets` across `jobs` parallel lanes, writing the four overlay TSVs into `outdir`. The
# SINGLE build path, shared by the partial sweep, --commit, and --check, so they cannot diverge.
# Determinism is preserved by sorting results back to input order before assembly — so the bytes
# match the old serial sweep exactly, only faster. Returns the counts.
def sweep [targets: list<string>, outdir: string, timeout: int, idx: any, std_dir: string, jobs: int] {
    mkdir $outdir
    mkdir $SCRATCH
    # direct child containers per parent — the SKIP set each container hands to resolve.zig.
    let kids = ($idx | get path | insert-parent | group-by parent)
    let results = ($targets | enumerate | par-each --threads $jobs {|row|
        let krow = ($kids | get -i $row.item | default [])
        let skip = (if ($krow | is-empty) { [] } else { $krow | get child })
        reflect-one $row.index $row.item $skip $timeout $std_dir
    } | sort-by i)   # restore target order — bytes must match the serial sweep

    let status = ($results | get srow)
    let resolved = ($results | get rows | flatten)
    let poison = ($results | where prow != null | get prow)

    (["path\tstatus\tn_rows"] | append $status | str join "\n") + "\n" | save -f $"($outdir)/status.tsv"
    (["path\tkind\tdetail"] | append $resolved | str join "\n") + "\n" | save -f $"($outdir)/resolved.tsv"
    (["path\treason"] | append $poison | str join "\n") + "\n" | save -f $"($outdir)/poison.tsv"
    {resolved: ($resolved | length), poison: ($poison | length), attempted: ($targets | length)}
}

def main [--only: string, --filter: string, --list: string, --limit: int = 0, --timeout: int = 90, --jobs: int = 0, --out: string = "/tmp/zephem-depth/out", --commit, --check] {
    let idx = (open data/std/index.tsv)
    let std_dir = (std-dir)
    let jobs = (if $jobs > 0 { $jobs } else { (ncpu) })   # adaptive: one lane per available CPU

    if $check {
        # ---- REPRODUCIBLE: prove the committed overlay rebuilds, byte-for-byte. SLOW. ----
        # Two full fresh reflection sweeps; wall time is machine-dependent (≈13 min cold on a
        # 3-core VM, under a minute on a many-core desktop). Deliberately NOT part of
        # build_std.nu --check, which is a fast parse and must stay fast.
        if not ($MANIFEST | path exists) { print $"[L5 check] no ($MANIFEST) — run --commit first"; exit 1 }
        print $"[L5 check] proving the depth overlay rebuilds — two full reflection sweeps, ($jobs) lanes each"
        let targets = ($idx | get path)
        let committed = (hashes "data/std")          # what's on disk now (before touching it)
        let manifest = (open $MANIFEST | lines
            | parse -r '(?<hash>\S+)\s+data/std/(?<name>\S+)'
            | reduce --fold {} {|r, acc| $acc | insert $r.name $r.hash })
        sweep $targets "/tmp/zephem-depth-check/a" $timeout $idx $std_dir $jobs   # two independent rebuilds
        sweep $targets "/tmp/zephem-depth-check/b" $timeout $idx $std_dir $jobs
        let a = (hashes "/tmp/zephem-depth-check/a")
        let b = (hashes "/tmp/zephem-depth-check/b")
        mut ok = true
        for n in $NAMES {
            let intrinsic = (($a | get $n) == ($b | get $n))                  # build twice -> same bytes
            let regression = (($a | get $n) == ($manifest | get -i $n))       # rebuild -> recorded truth
            let integrity = (($committed | get $n) == ($manifest | get -i $n)) # on-disk -> its manifest
            if (not $intrinsic) or (not $regression) or (not $integrity) { $ok = false }
            let mi = (if $intrinsic { "✓" } else { "✗ DRIFT" })
            let mr = (if $regression { "✓" } else { "✗ DRIFT" })
            let mg = (if $integrity { "✓" } else { "✗ DRIFT" })
            print $"  ($n): intrinsic ($mi)   reproduces-manifest ($mr)   on-disk-matches-manifest ($mg)"
        }
        rm -rf /tmp/zephem-depth-check
        if $ok {
            print "L5 reproducible: ✓ two fresh rebuilds agree, reproduce the manifest, and the snapshot matches it"
        } else {
            print "L5 reproducible: ✗ DRIFT — see above; the overlay is NOT provably rebuildable"
            exit 1
        }
        return
    }

    mut targets = (
        if ($only | is-not-empty) { [$only] }
        else if ($list | is-not-empty) { open $list | lines | where ($it | str trim | is-not-empty) }
        else if ($filter | is-not-empty) { $idx | get path | where ($it | str contains $filter) }
        else { $idx | get path }
    )
    if $limit > 0 { $targets = ($targets | first $limit) }
    let outdir = (if $commit { "data/std" } else { $out })

    print $"[L5] reflecting ($targets | length) container\(s\) — ($jobs) parallel lanes, ($timeout)s timeout each, poison isolated per process"
    let c = (sweep $targets $outdir $timeout $idx $std_dir $jobs)

    print $"[L5] resolved: (($c.attempted) - ($c.poison)) containers, ($c.resolved) rows   poison: ($c.poison)   attempted: ($c.attempted)"
    print $"[L5] → ($outdir)/{status,resolved,poison}.tsv"
    if $c.poison > 0 and $c.poison <= 20 {
        print "[L5] poison (path · reason):"
        open $"($outdir)/poison.tsv" | each {|p| print $"   ($p.path)\t($p.reason)" } | ignore
    }

    # ---- verification: re-read the buckets a SECOND way and reconcile with the map ----
    print "[L5] verifying — reading the overlay back the other way..."
    let vargs = (if $commit { [$outdir "--full"] } else { [$outdir] })
    let v = (do { ^nu scripts/verify_depth.nu ...$vargs } | complete)
    print $v.stdout
    if $v.exit_code != 0 { print "build_depth: ✗ overlay rejected by verify_depth"; exit 1 }

    # ---- REPRODUCIBLE: on --commit, record the L5 manifest (sha256sum -c compatible) ----
    if $commit {
        let m = ($NAMES | each {|n|
            let h = (open --raw $"data/std/($n)" | hash sha256)
            $"($h)  data/std/($n)"
        } | str join "\n")
        $"($m)\n" | save -f $MANIFEST
        print $"[L5] manifest → ($MANIFEST)  \(run --check to prove it rebuilds — SLOW, machine-dependent\)"
    }
}
