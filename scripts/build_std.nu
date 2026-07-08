#!/usr/bin/env nu
# build_std.nu — regenerate the full-std datasets, prove them, and prove they rebuild.
#
# Two guarantees, both enforced here:
#
#   TRUE         FORWARD  (parse/build.zig) extracts the structural map in one pass;
#                derive/index.zig builds its table of contents.
#                BACKWARD (scripts/verify_std.nu) re-reads them the other way — by parent,
#                by depth, by join — and checks everything reconciles. A regeneration the
#                backward read rejects is not a regeneration: exits non-zero, claims nothing.
#
#   REPRODUCIBLE Every build writes data/std/SHA256SUMS (a sha256sum-compatible manifest of
#                the datasets). `--check` proves rebuildability three ways: two fresh builds
#                are byte-identical (intrinsic determinism), they reproduce the committed
#                manifest (regression), and the on-disk snapshot still matches its manifest
#                (integrity). Any drift fails loudly.
#
# Deterministic (same Zig -> identical bytes), non-breaking (pure parsing never dies on
# poison decls). Pure Nushell hashing — no external tools.
#
# Usage:  nu scripts/build_std.nu              # rebuild + verify + write manifest
#         nu scripts/build_std.nu --depth 24
#         nu scripts/build_std.nu --check       # prove the committed snapshot rebuilds

const NAMES = ["extracted/nodes.tsv" "extracted/attrs.tsv" "extracted/edges.tsv" "derived/index.tsv"]

# The active toolchain's std root. `zig env` emits ZON, not JSON — pull the path out.
def std-root [] {
    let std_dir = (^zig env | lines | parse -r '\.std_dir = "(?<p>[^"]+)"' | get p.0)
    $"($std_dir)/std.zig"
}

# Regenerate the datasets into `outdir`, saved identically to the committed snapshot (so
# hashes are comparable). The single source of build truth, shared by the normal build and
# --check, so they cannot diverge.
def regen [root: string, outdir: string] {
    mkdir $"($outdir)/extracted" $"($outdir)/derived"
    # parse2 walks std once → the tree (nodes), the node's own facts (attrs), and its typed,
    # resolved edges (edges). derive builds the table of contents from the tree.
    ^zig run parse2/build.zig -- $root $"($outdir)/extracted/nodes.tsv" $"($outdir)/extracted/edges.tsv" $"($outdir)/extracted/attrs.tsv"
    (^zig run derive/index.zig -- $"($outdir)/extracted/nodes.tsv" | into string) | save -f $"($outdir)/derived/index.tsv"
}

# sha256 of each dataset in `dir`, as a {name: hash} record (raw bytes — no parsing).
def hashes [dir: string] {
    $NAMES | reduce --fold {} {|n, acc| $acc | insert $n (open --raw $"($dir)/($n)" | hash sha256) }
}

def main [--depth: int = 24, --check] {
    let root = (std-root)
    let zver = (^zig version | str trim)

    if $check {
        # ---- REPRODUCIBLE: prove the committed snapshot rebuilds, byte-for-byte ----
        print $"[check]    proving reproducibility  \(zig ($zver), depth ($depth)\)"
        let committed = (hashes "data/std")          # what's on disk now (before touching it)
        let manifest = (open data/std/SHA256SUMS | lines
            | parse -r '(?<hash>\S+)\s+data/std/(?<name>\S+)'
            | reduce --fold {} {|r, acc| $acc | insert $r.name $r.hash })
        regen $root "/tmp/zephem-check/a"     # two independent fresh rebuilds
        regen $root "/tmp/zephem-check/b"
        let a = (hashes "/tmp/zephem-check/a")
        let b = (hashes "/tmp/zephem-check/b")
        mut ok = true
        for n in $NAMES {
            let intrinsic = (($a | get $n) == ($b | get $n))                 # build twice -> same bytes
            let regression = (($a | get $n) == ($manifest | get $n))         # rebuild -> recorded truth
            let integrity = (($committed | get $n) == ($manifest | get $n))  # on-disk -> its manifest
            if (not $intrinsic) or (not $regression) or (not $integrity) { $ok = false }
            let mi = (if $intrinsic { "✓" } else { "✗ DRIFT" })
            let mr = (if $regression { "✓" } else { "✗ DRIFT" })
            let mg = (if $integrity { "✓" } else { "✗ DRIFT" })
            print $"  ($n): intrinsic ($mi)   reproduces-manifest ($mr)   on-disk-matches-manifest ($mg)"
        }
        rm -rf /tmp/zephem-check
        if $ok {
            print "reproducible: ✓ two fresh rebuilds agree, reproduce the manifest, and the snapshot matches it"
        } else {
            print "reproducible: ✗ DRIFT — see above; the snapshot is NOT provably rebuildable"
            exit 1
        }
        return
    }

    # ---- TRUE (forward): regenerate the datasets -----------------------------
    print $"[forward]  scanning ($root)  \(zig ($zver), depth ($depth)\)"
    regen $root "data/std"
    $"zig ($zver)\n" | save -f data/std/PINNED   # pin the exact version this snapshot is from

    let t = (open data/std/extracted/nodes.tsv)
    print $"           rows: (($t | length))   files: (($t | where kind == 'ns' | length))   private: (($t | where vis == 'priv' | length))"
    let it = (open data/std/derived/index.tsv)
    print $"[index]    containers: (($it | length))   root span: (($it | get span | math max))   max depth: (($it | get depth | math max))"
    let attrs = (open data/std/extracted/attrs.tsv)
    let edges = (open data/std/extracted/edges.tsv)
    print $"[attrs]    (($attrs | length)) rows — doc (($attrs | where attr == 'doc' | length)) · sig (($attrs | where attr == 'sig' | length)) · value (($attrs | where attr == 'value' | length)) · example (($attrs | where attr == 'example' | length))"
    print $"[edges]    (($edges | length)) rows — resolved (($edges | where scope in ['local' 'cross' 'primitive' 'generic'] | length)) / unresolved (($edges | where scope == 'unresolved' | length))"

    # ---- TRUE (backward): read the data the other way; it must agree ---------
    print "[backward] re-reading the datasets — must reconcile..."
    let v = (^nu scripts/verify_std.nu data/std/extracted/nodes.tsv | complete)
    print $v.stdout
    if $v.exit_code != 0 {
        print "build_std: ✗ forward and backward DISAGREE — snapshot rejected."
        exit 1
    }

    # ---- REPRODUCIBLE: record the manifest (sha256sum -c compatible) ----------
    let manifest = ($NAMES | each {|n|
        let h = (open --raw $"data/std/($n)" | hash sha256)
        $"($h)  data/std/($n)"
    } | str join "\n")
    $"($manifest)\n" | save -f data/std/SHA256SUMS
    print "build_std: ✓ true (forward == backward) and recorded — run with --check to prove it rebuilds."
}
