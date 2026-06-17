#!/usr/bin/env python3
"""
parse_crypto.py — read every .zig file under std/crypto, extract every public
declaration exactly as written in source, and write the result to DuckDB +
CSV. No interpretation, no sorting, no labelling — just what the files say.

Output:
  data/crypto_raw.duckdb    — queryable DuckDB database
  data/crypto_raw.csv       — flat spreadsheet, one row per declaration

Columns:
  file          relative path from std/crypto root (e.g. "chacha20.zig")
  line          line number (1-indexed)
  name          the declared identifier
  kind          const / fn / var / type / enum / struct (from the pub keyword line)
  is_import     true if the declaration is just `= @import(...)`
  is_reexport   true if declared inside crypto.zig (the top-level namespace file)
  signature     the full first line of the declaration (trimmed)
  doc           doc comment lines joined, immediately preceding the declaration
"""

import os, re, csv, duckdb
from pathlib import Path

CRYPTO_ROOT = Path("/usr/lib/zig/std/crypto")
OUT_DIR     = Path("/home/astralibernis/projects/zcrypto/data")
OUT_DB      = OUT_DIR / "crypto_raw.duckdb"
OUT_CSV     = OUT_DIR / "crypto_raw.csv"

OUT_DIR.mkdir(exist_ok=True)

# Match any `pub` declaration line
PUB_RE = re.compile(
    r'^(\s*)pub\s+(const|fn|var|type|usingnamespace)\s+(\w+)'
)
# Detect @import on the same line
IMPORT_RE = re.compile(r'=\s*@import\s*\(')

def extract_declarations(filepath: Path, crypto_root: Path):
    rel = str(filepath.relative_to(crypto_root))
    is_reexport_file = (filepath.name == "crypto.zig" and filepath.parent == crypto_root.parent)

    rows = []
    try:
        lines = filepath.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception as e:
        print(f"  SKIP {rel}: {e}")
        return rows

    doc_buf = []
    for i, line in enumerate(lines):
        stripped = line.strip()

        # accumulate doc comments
        if stripped.startswith("///"):
            doc_buf.append(stripped.lstrip("/").strip())
            continue

        m = PUB_RE.match(line)
        if m:
            indent   = len(m.group(1))
            kind     = m.group(2)
            name     = m.group(3)
            sig      = stripped
            is_imp   = bool(IMPORT_RE.search(line))
            rows.append({
                "file":        rel,
                "line":        i + 1,
                "indent":      indent,
                "name":        name,
                "kind":        kind,
                "is_import":   is_imp,
                "is_reexport": is_reexport_file,
                "signature":   sig[:300],
                "doc":         " | ".join(doc_buf)[:500],
            })
            doc_buf = []
            continue

        # non-doc, non-pub line — clear doc buffer
        if stripped and not stripped.startswith("//"):
            doc_buf = []

    return rows


def main():
    # also include the top-level crypto.zig (one level up from the crypto/ dir)
    files = sorted(CRYPTO_ROOT.rglob("*.zig"))
    top   = CRYPTO_ROOT.parent / "crypto.zig"
    if top.exists():
        files = [top] + list(files)

    all_rows = []
    for f in files:
        rows = extract_declarations(f, CRYPTO_ROOT.parent)
        all_rows.extend(rows)
        print(f"  {f.relative_to(CRYPTO_ROOT.parent)}: {len(rows)} decls")

    print(f"\ntotal declarations extracted: {len(all_rows)}")

    # write CSV
    fields = ["file","line","indent","name","kind","is_import","is_reexport","signature","doc"]
    with open(OUT_CSV, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        w.writerows(all_rows)
    print(f"CSV written: {OUT_CSV}")

    # write DuckDB
    if OUT_DB.exists():
        OUT_DB.unlink()
    con = duckdb.connect(str(OUT_DB))
    con.execute(f"CREATE TABLE crypto_raw AS SELECT * FROM read_csv_auto('{OUT_CSV}')")
    count = con.execute("SELECT count(*) FROM crypto_raw").fetchone()[0]
    print(f"DuckDB written: {OUT_DB}  ({count} rows)")

    # quick sanity queries
    print("\n--- top-level crypto.zig pub declarations ---")
    rows = con.execute("""
        SELECT name, kind, is_import, left(signature,60) AS sig
        FROM crypto_raw
        WHERE file = 'crypto.zig'
        ORDER BY line
    """).fetchall()
    for r in rows:
        flag = " [import]" if r[2] else ""
        print(f"  {r[1]:8s}  {r[0]:30s}{flag}  {r[3]}")

    print("\n--- declaration counts by file (top 15) ---")
    rows = con.execute("""
        SELECT file, count(*) AS decls
        FROM crypto_raw
        WHERE file != 'crypto.zig'
        GROUP BY file ORDER BY decls DESC LIMIT 15
    """).fetchall()
    for r in rows:
        print(f"  {r[1]:5d}  {r[0]}")

    print("\n--- kind breakdown ---")
    rows = con.execute("""
        SELECT kind, count(*) FROM crypto_raw GROUP BY kind ORDER BY count(*) DESC
    """).fetchall()
    for r in rows:
        print(f"  {r[0]:15s} {r[1]}")

    con.close()


if __name__ == "__main__":
    main()
