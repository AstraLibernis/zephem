#!/usr/bin/env python3
"""
build_tree.py — run the structural mapper and turn its flat rows into a nested
JSON tree, then report first-pass anomalies (the "strange/unique things" we sort
for once the whole map exists).

No interpretation of what anything *is* — only structure and exact counts.

Output:
  data/crypto_tree.tsv    — flat: path/depth/kind/n_decls/n_fields/n_types/n_fns/n_consts
  data/crypto_tree.json   — same data nested by path

Run: python3 scripts/build_tree.py
"""

import subprocess, csv, io, json
from pathlib import Path

ROOT    = Path(__file__).resolve().parent.parent
MAP     = ROOT / "src" / "maptree.zig"
OUT_TSV = ROOT / "data" / "crypto_tree.tsv"
OUT_JSON = ROOT / "data" / "crypto_tree.json"

INTC = ("n_decls", "n_fields", "n_types", "n_fns", "n_consts")

def main():
    raw = subprocess.run(["zig", "run", str(MAP)], cwd=ROOT,
                         capture_output=True, text=True, check=True).stdout
    rows = list(csv.DictReader(io.StringIO(raw), delimiter="\t"))
    for r in rows:
        r["depth"] = int(r["depth"])
        for k in INTC:
            r[k] = int(r[k])

    OUT_TSV.write_text(raw)
    print(f"TSV written: {OUT_TSV}  ({len(rows)} containers)")

    # nest by dotted path
    tree = {}
    index = {}
    for r in sorted(rows, key=lambda x: x["depth"]):
        node = {"kind": r["kind"], **{k: r[k] for k in INTC}, "children": {}}
        index[r["path"]] = node
        if "." not in r["path"][len("crypto"):]:  # root
            tree[r["path"]] = node
            continue
        parent_path = r["path"].rsplit(".", 1)[0]
        name = r["path"].rsplit(".", 1)[1]
        parent = index.get(parent_path)
        (parent["children"] if parent else tree)[name] = node
    OUT_JSON.write_text(json.dumps(tree, indent=2))
    print(f"JSON written: {OUT_JSON}")

    # ---- first-pass anomaly sort ----
    print(f"\n=== totals ===")
    print(f"  containers mapped: {len(rows)}")
    print(f"  total decls across tree: {sum(r['n_decls'] for r in rows)}")
    by_kind = {}
    for r in rows:
        by_kind[r["kind"]] = by_kind.get(r["kind"], 0) + 1
    print(f"  by kind: {by_kind}")

    print(f"\n=== widest containers (most direct decls) ===")
    for r in sorted(rows, key=lambda x: -x["n_decls"])[:10]:
        print(f"  {r['n_decls']:4d} decls  {r['path']}")

    print(f"\n=== data-only containers (fields, no decls — enums/structs of values) ===")
    for r in rows:
        if r["n_fields"] > 0 and r["n_decls"] == 0:
            print(f"  {r['kind']:6s} {r['n_fields']} fields  {r['path']}")

    print(f"\n=== leaf functions at unusual spots (fn-bearing namespaces) ===")
    for r in rows:
        if r["n_fns"] > 0 and r["n_types"] > 0 and r["depth"] <= 1:
            print(f"  {r['path']}: {r['n_fns']} fn, {r['n_types']} types, {r['n_consts']} const")

    print(f"\n=== deepest paths ===")
    for r in sorted(rows, key=lambda x: -x["depth"])[:8]:
        print(f"  d{r['depth']}  {r['path']}")

if __name__ == "__main__":
    main()
