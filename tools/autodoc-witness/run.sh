#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The autodoc witness: checks the live map (data/std/) against Zig's own autodoc extractor
# and an independent source lister, neither of which shares code with zephem.
#
#   tools/autodoc-witness/run.sh <out-dir>      (ZIG=<zig binary> to pick the compiler)
#
# Outputs in <out-dir>:
#   mapcheck.tsv    every map decl path looked up with autodoc's own Decl.find
#   reachcheck.tsv  every decl autodoc's UI reaches, matched to a map node by file:line
#   src.tsv         every member decl of every container in the source (srcdecls.zig)
#   all.tsv reach.tsv find.tsv map.tsv  the raw inputs to the two classifiers
#
# Walk.zig and Decl.zig are copied from the compiler's lib/docs/wasm at run time (not vendored)
# and patched twice: the wasm allocator becomes page_allocator, and a bare `return;` in
# Decl.zig, which autodoc reads as `.node` and panics on in safe builds, is read as
# `.opt_node.unwrap()`.
set -e
[ $# -eq 1 ] || { echo "usage: $0 <out-dir>" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
D=$(cd "$here/../../data/std/extracted" && pwd)
ZIG=${ZIG:-zig}
LIB=$("$ZIG" env | awk -F'"' '/\.lib_dir =/{print $2; exit}')
[ -d "$LIB/docs/wasm" ] || { echo "no autodoc sources under $LIB/docs/wasm" >&2; exit 1; }
mkdir -p "$1"
cd "$1"

cp "$here"/autodoc_dump.zig "$here"/srcdecls.zig .
cp "$LIB"/docs/wasm/Walk.zig "$LIB"/docs/wasm/Decl.zig .
sed -i 's/const gpa = std.heap.wasm_allocator;/const gpa = std.heap.page_allocator;/' Walk.zig Decl.zig
sed -i 's/return ast.nodeData(stmt).node;/return ast.nodeData(stmt).opt_node.unwrap();/' Decl.zig
grep -q 'std.heap.page_allocator' Walk.zig && grep -q 'nodeData(stmt).opt_node.unwrap()' Decl.zig || { echo "a Walk.zig/Decl.zig patch did not apply" >&2; exit 1; }
"$ZIG" build-exe -OReleaseSafe autodoc_dump.zig -femit-bin=autodoc_dump
"$ZIG" build-exe -OReleaseSafe srcdecls.zig -femit-bin=srcdecls

# map.tsv: path kind name vis file:line, from the live map
awk -F'\t' 'NR==FNR{if($2=="loc")loc[$1]=$3;next} FNR>1{print $1"\t"$2"\t"$3"\t"$4"\t"(($1 in loc)?loc[$1]:"-")}' "$D/attrs.tsv" "$D/nodes.tsv" > map.tsv
awk -F'\t' '$2!="field"&&$2!="tag"{print $1}' map.tsv > map_decl_paths.txt
./autodoc_dump "$LIB/std" all.tsv reach.tsv map_decl_paths.txt find.tsv 2>&1 | grep -v '^warning' || true
./srcdecls "$LIB/std" > src.tsv
awk -f "$here/classify_map.awk" map.tsv find.tsv > mapcheck.tsv
awk -f "$here/classify_reach.awk" all.tsv map.tsv reach.tsv > reachcheck.tsv

echo "mapcheck (shape, ancestry, result):"
awk -F'\t' '{print $5, ($4?"pubchain":"privchain"), $6}' mapcheck.tsv | sort | uniq -c | sort -rn
echo "reachcheck (result):"
cut -f7 reachcheck.tsv | sort | uniq -c | sort -rn
