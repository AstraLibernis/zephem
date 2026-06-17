# data/ — the extraction layer

Two datasets, two different methods. Phase 3 docs are written *from these*, not by
hand-reading std source.

## `crypto_raw.{csv,duckdb}` — the text inventory (breadth)

Produced by `scripts/parse_crypto.py`: a regex scan of every `.zig` file under
`/usr/lib/zig/std/crypto`. One row per `pub` declaration, exactly as written in
source — name, kind, file, line, the declaration line, doc comment. 1932 rows.

Use it for: *what exists and where*. It is the complete map. It cannot resolve
aliases or generics — `ChaCha20Poly1305 = ChaChaPoly(...)` shows only the alias line.

## `primitives.{tsv,duckdb}` — the resolved use-surface (depth)

Produced by `scripts/build_primitives.py`, which runs `src/dump.zig` — a Zig program
that imports std.crypto and reflects over a curated list of the primitives you
actually instantiate. Because the **compiler** resolves the types, this gives the
real API through every alias and generic: concrete byte sizes and fully-typed
function signatures, including error sets. ~518 rows.

Columns: `family · primitive · decl · kind · detail`
- `kind` ∈ {const_int, fn, type, const_other}
- `detail` = the integer value (const_int), the resolved signature (fn), or the
  type name (type / const_other)
- nested usage types are dotted: `Ed25519.KeyPair`, `Ed25519.Signature`

Known gap: Zig does not expose *inferred* error sets via `@typeName`, so a few
signatures show `error{inferred}` rather than the resolved set.

## Regenerate

```sh
python3 scripts/parse_crypto.py        # text inventory
python3 scripts/build_primitives.py    # resolved use-surface (needs zig on PATH)
```

## Example queries (duckdb)

```sql
-- every key/nonce/tag/digest size, by family
SELECT family, primitive, decl, detail FROM primitives
WHERE kind='const_int' AND decl LIKE '%length%' ORDER BY 1,2,3;

-- the full usable API of one primitive
SELECT decl, kind, detail FROM primitives WHERE primitive='ChaCha20Poly1305';

-- confirm every AEAD shares the same encrypt shape
SELECT primitive, detail FROM primitives WHERE family='aead' AND decl='encrypt';
```
