# data/ — the extraction & map layer

Toolchain: **Zig** does the extraction (it needs the real compiler/types), **Nushell**
does the glue and the querying. No Python, no duckdb — the CSV/TSV/JSON files are the
source of truth, and Nushell queries them natively.

## Datasets

### `crypto_raw.csv` — text inventory (breadth)
`scripts/parse_crypto.nu`: a regex scan of every `.zig` under `/usr/lib/zig/std/crypto`,
one row per `pub` declaration exactly as written. ~1932 rows. Answers *what exists,
where*. Cannot resolve aliases/generics.

### `primitives.tsv` — resolved use-surface (depth)
`src/dump.zig` + `scripts/build_primitives.nu`: the **compiler** reflects over a curated
list of the primitives you actually instantiate, giving resolved byte sizes and fully
typed signatures (incl. error sets) through every alias and generic. ~518 rows.
Columns: `family · primitive · decl · kind · detail`.
Known gap: inferred error sets show as `error{inferred}` (not exposed via `@typeName`).

### `crypto_tree.{tsv,json}` — structural map (no interpretation)
`src/maptree.zig` + `scripts/build_tree.nu`: every container in the public tree with
exact counts — `n_decls / n_fields / n_types / n_fns / n_consts`. 400 containers.
The `.json` is the same data nested by path. Rendered human-readable in
`docs/structure.md`. (codecs/tls/Certificate are recorded but not descended — their
ASN.1/DER writer decls break reflection.)

### `clusters.tsv` — shape clusters
`scripts/cluster_shapes.nu`: each container's shape cluster (math / scheme / namespace /
config / stateful / ops / other), by explicit rules. Visual in `docs/clusters.svg`.

### `surface.tsv` — developer-facing surface
`src/surface.zig` + `scripts/build_surface.nu`: reflection over the public namespaces
labelling each decl PRIMITIVE / BUILDER / free-fn / namespace — what a dev reaches for,
without the math/protocol machinery. 134 primitives across families. Report in
`docs/surface.md`.

## Regenerate

```nu
nu scripts/parse_crypto.nu       # text inventory  → crypto_raw.csv
nu scripts/build_primitives.nu   # resolved surface → primitives.tsv   (needs zig)
nu scripts/build_tree.nu         # structural map   → crypto_tree.* + docs/structure.md
nu scripts/cluster_shapes.nu     # shape clusters   → clusters.tsv + docs/clusters.{svg,md}
nu scripts/build_surface.nu      # dev-facing list  → surface.tsv + docs/surface.md  (needs zig)
```

Everything above is generated and idempotent. (The former hand-authored
`docs/inventory.md` and `docs/map.md` were archived 2026-06-17 under the map-only
charter — see `docs/archive/`.)

## Query examples (Nushell)

```nu
# every key/nonce/tag/digest size, by family
open data/primitives.tsv | where kind == 'const_int' and ($it.decl | str ends-with 'length')

# the full usable API of one primitive
open data/primitives.tsv | where primitive == 'ChaCha20Poly1305'

# confirm every AEAD shares the same encrypt shape
open data/primitives.tsv | where family == 'aead' and decl == 'encrypt'

# structural map: the pure namespaces (hold only sub-types)
open data/crypto_tree.tsv | where n_fns == 0 and n_consts == 0 and n_types > 0
```
