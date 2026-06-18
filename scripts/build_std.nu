#!/usr/bin/env nu
# build_std.nu — regenerate the full-std map AND prove it, as one operation.
#
# Two passes that must agree:
#   FORWARD  (read it)            src/scan.zig parses every std source file and
#                                 writes one row per public decl into nodes.tsv.
#   BACKWARD (read it backwards)  scripts/verify_std.nu reads nodes.tsv from the
#                                 other end — grouping rows by parent — and checks
#                                 the tree reconciles (the conservation law et al).
#
# They are bundled on purpose: a regeneration that the backward read rejects is
# not a regeneration. If the two passes ever disagree, this exits non-zero and
# leaves nothing claimed as good.
#
# Deterministic (same Zig -> identical bytes), idempotent (`git diff --exit-code`
# clean), non-breaking (pure parsing never dies on poison decls).
#
# Usage:  nu scripts/build_std.nu            # uses the active `zig`'s std
#         nu scripts/build_std.nu --depth 24

def main [--depth: int = 24] {
    # `zig env` emits ZON (.{ .std_dir = "..." }), not JSON — pull the path out.
    let std_dir = (^zig env | lines | parse -r '\.std_dir = "(?<p>[^"]+)"' | get p.0)
    let root = $"($std_dir)/std.zig"
    let zver = (^zig version | str trim)

    # ---- FORWARD: read the source into data ----------------------------------
    print $"[forward]  scanning ($root)  \(zig ($zver), depth ($depth)\)"
    let rows = (^zig run src/scan.zig -- $root ($depth | into string) | into string)
    $rows | save -f data/std/nodes.tsv
    $"zig ($zver)\n" | save -f data/std/PINNED   # pin the exact version this snapshot is from

    let t = (open data/std/nodes.tsv)
    print $"           rows: (($t | length))   files: (($t | where kind == 'ns' | length))   max depth: (($t | get depth | math max))"

    # ---- INDEX: the table of contents (path -> line, span) -------------------
    print "[index]    building line/span table of contents..."
    let idx = (^zig run src/index.zig -- data/std/nodes.tsv | into string)
    $idx | save -f data/std/index.tsv
    let it = (open data/std/index.tsv)
    print $"           containers: (($it | length))   root span: (($it | get span | math max))"

    # ---- ENRICH: the L1 (signatures) + L2 (doc-comments) overlay -------------
    print "[enrich]   extracting signatures (L1) + doc-comments (L2)..."
    let dec = (^zig run src/enrich.zig -- $root ($depth | into string) | into string)
    $dec | save -f data/std/decls.tsv
    let dt = (open data/std/decls.tsv)
    print $"           decl rows: (($dt | length))   with sig: (($dt | where sig != '' | length))   with doc: (($dt | where doc != '' | length))"

    # ---- BACKWARD: read the data the other way; it must agree ----------------
    print "[backward] re-reading nodes.tsv by parent — must reconcile..."
    let v = (^nu scripts/verify_std.nu data/std/nodes.tsv | complete)
    print $v.stdout
    if $v.exit_code != 0 {
        print "build_std: ✗ forward and backward DISAGREE — snapshot rejected."
        exit 1
    }
    print "build_std: ✓ forward and backward agree — snapshot is sound."
}
