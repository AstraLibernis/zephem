#!/usr/bin/env python3
"""
build_primitives.py — run the reflection dumper, clean the resolved signatures,
and write the "use" dataset.

Unlike parse_crypto.py (which text-scrapes every decl in std/crypto), this drives
src/dump.zig: the *compiler* resolves each curated primitive's real API through
aliases and generics, so we get actual byte sizes and fully-typed signatures.
This script just tidies the type names for human reading and loads duckdb.

Output:
  data/primitives.tsv      — family / primitive / decl / kind / detail
  data/primitives.duckdb   — same, queryable

Run: python3 scripts/build_primitives.py
"""

import re, subprocess, csv, io
from pathlib import Path

ROOT   = Path(__file__).resolve().parent.parent
DUMP   = ROOT / "src" / "dump.zig"
OUT_TSV = ROOT / "data" / "primitives.tsv"
OUT_DB  = ROOT / "data" / "primitives.duckdb"

# Strip module-path prefixes: any run of lowercase/digit dotted segments after
# `crypto.` is a namespace path; the Capitalized tail is the type we want to keep.
#   crypto.25519.ed25519.Ed25519.KeyPair -> Ed25519.KeyPair
#   crypto.sha2.Sha2x32(.{...},256)       -> Sha2x32(.{...},256)
PATH_RE = re.compile(r"crypto\.(?:[a-z0-9_]+\.)+")
# Collapse anonymous numeric struct literals (SHA-2/SHA-3 IV constants).
IV_RE = re.compile(r"\.\{[\s\d,]+\}")
# Collapse the unresolved inferred-error-set reflection blob.
INFERR_RE = re.compile(
    r'@typeInfo\(@typeInfo\(@TypeOf\([^()]*\)\)\.@"fn"\.return_type\.\?\)\.error_union\.error_set'
)

def clean(detail: str) -> str:
    detail = INFERR_RE.sub("error{inferred}", detail)
    detail = IV_RE.sub("…", detail)
    detail = PATH_RE.sub("", detail)
    return detail

def main():
    raw = subprocess.run(
        ["zig", "run", str(DUMP)],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout

    rows = list(csv.DictReader(io.StringIO(raw), delimiter="\t"))
    for r in rows:
        r["detail"] = clean(r["detail"])

    fields = ["family", "primitive", "decl", "kind", "detail"]
    with open(OUT_TSV, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, delimiter="\t")
        w.writeheader()
        w.writerows(rows)
    print(f"TSV written: {OUT_TSV}  ({len(rows)} rows)")

    try:
        import duckdb
    except ImportError:
        print("duckdb not installed — skipping .duckdb (TSV is the source of truth)")
        return
    if OUT_DB.exists():
        OUT_DB.unlink()
    con = duckdb.connect(str(OUT_DB))
    con.execute(
        f"CREATE TABLE primitives AS "
        f"SELECT * FROM read_csv_auto('{OUT_TSV}', delim='\t', header=true)"
    )
    n = con.execute("SELECT count(*) FROM primitives").fetchone()[0]
    print(f"DuckDB written: {OUT_DB}  ({n} rows)")
    print("\n--- sizes that matter (const_int) by family ---")
    for fam, prim, decl, val in con.execute("""
        SELECT family, primitive, decl, detail FROM primitives
        WHERE kind='const_int' AND decl LIKE '%length%'
        ORDER BY family, primitive, decl
    """).fetchall():
        print(f"  {fam:7s} {prim:18s} {decl:16s} = {val}")
    con.close()

if __name__ == "__main__":
    main()
