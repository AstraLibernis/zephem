# data/ — the extraction & map layer

Toolchain: **Zig** does the extraction (parsing std source), **Nushell** does the glue and
the querying. No Python, no duckdb — the TSV files are the source of truth, and Nushell
queries them natively.

## Datasets

### `std/nodes.tsv` — the full std map (the headline dataset)
`parse/build.zig` + `parse/walk.zig` (driven by `scripts/build_std.nu`): the whole `std`
namespace tree, built by **parsing source** (`std.zig.Ast`), not reflection — so it never
dies on platform-gated / poison decls and maps *all* of std. One row per public decl.
**47,319 rows / 310 files / max depth 9** on zig 0.16.0 (version pinned in `std/PINNED`).
Columns: `path · depth · kind · name · n_children · detail`.
`kind ∈ ns · nsref · nserr · struct · enum · union · opaque · fn · const · alias · modref`.

Self-verifying: `build_std.nu` runs a **forward** pass (parse) and a **backward** pass
(`scripts/verify_std.nu`, which re-reads the rows grouped by parent) that must agree. The
core invariant is the conservation law `Σ n_children == rows − 1`; the verifier also checks
per-node child counts, kind partition, and `nsref` integrity. Disagreement → non-zero exit,
nothing claimed.

### `std/index.tsv` — the table of contents (where to look)
`derive/index.zig` (run inside `build_std.nu`): one row per container, recording where its
block lives in `nodes.tsv`. Columns: `path · line · span · depth · kind · n_children`.
Because `nodes.tsv` is pre-order DFS, every subtree is a *contiguous* run of rows — so
`line` (1-based file line, header-aware) + `span` (subtree size) pin the exact block.
Read a whole module in one ranged read instead of scanning 47319 rows:

```nu
let b = (open data/std/index.tsv | where path == 'std.crypto.aead' | first)
open data/std/nodes.tsv | skip ($b.line - 2) | first $b.span   # exactly that subtree
```

Self-checked both ways: `index.zig` asserts root span == total rows and every span ==
1 + Σ child spans before writing; `verify_std.nu` then re-derives each block's boundary
straight from `nodes.tsv` depths and confirms `line`+`span` land exactly on each subtree.

Full recipes: **[../docs/archive/USAGE.md](../docs/archive/USAGE.md)**.

### `std/sigs.tsv` + `std/docs.tsv` — signatures & doc-comments (parser side outputs)
`parse/walk.zig` (run inside `build_std.nu`): two sparse overlays keyed by `path`, adding the
raw source facts the bare map omits — both emitted by the parser, since only a parser can see
them.

- **`sigs.tsv`** — `path · sig`. `sig` is a function's as-written signature, from the `fn`
  keyword through the return type (body excluded), whitespace-collapsed to one line. One row
  per public `fn` (including re-exported fns). On zig 0.16.0: **5,377 signatures**.
- **`docs.tsv`** — `path · doc`. `doc` is the decl's `///` doc-comment text, whitespace-collapsed
  to one line. A row exists only for documented decls (any kind). On zig 0.16.0: **10,972 docs**.

Join either to `nodes.tsv` by `path` to "read down" the stack — every fn under a module with
its signature:

```nu
let nodes = (open data/std/nodes.tsv)
let sigs = (open data/std/sigs.tsv)
$nodes | where kind == 'fn' and ($it.path | str starts-with 'std.BitStack.')
  | select path | join $sigs path | select path sig
```

`verify_std.nu` proves the overlays *register* on the map: every `sigs` path is a real `fn`
node and every `docs` path is a real node, paths are unique in each, and the set of signatures
equals exactly the map's set of functions.

## Regenerate

```nu
nu scripts/build_std.nu          # parse → index → verify; refuses to ship if they disagree
```

Deterministic (same Zig → byte-identical) and idempotent (`git diff --exit-code` clean).

## Query examples (Nushell)

```nu
# every source file, one subtree, or the kind breakdown
open data/std/nodes.tsv | where kind == 'ns'
open data/std/nodes.tsv | where path =~ '^std\.crypto\.'
open data/std/nodes.tsv | group-by kind | items {|k,v| {kind:$k n:($v|length)}} | sort-by n -r

# jump straight to one module via the table of contents
let b = (open data/std/index.tsv | where path == 'std.mem' | first)
open data/std/nodes.tsv | skip ($b.line - 2) | first $b.span
```

## Archived

The original `std.crypto` reflection pipeline and its datasets (`primitives.tsv`,
`crypto_tree.{tsv,json}`, `surface.tsv`, `clusters.tsv`, `crypto_raw.csv`) were retired
2026-06-17 to **`../archive/crypto-reflection/`** (see its README). Retired crypto
*docs* live in `../docs/archive/`.
