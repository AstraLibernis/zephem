# zephem

**Z**ig + **ephem**eral. A tool that extracts the structure of a Zig module — its
**containers, labels, levels, and the references between them** — and transforms it into
pristine, queryable **datasets** built for LLM consumption and static research.

The data is *ephemeral by design*: never hand-authored, always regenerated from the
compiler's own source. A committed dataset is just a pinned snapshot of a fixed Zig
version — the product is the pipeline that reproduces it, not the bytes.

## What it does

Point it at a Zig source root and it walks the whole logical namespace tree — following
`@import` edges between files and descending inline `struct`/`enum`/`union`/`opaque`
literals and type factories — emitting the **shape model**: three streams that together
describe every node, all keyed by the same dotted `path`.

```
nodes.tsv : path · kind · name · vis          the Tree     — where the node sits
attrs.tsv : path · attr · value               Attributes   — facts it carries about itself
edges.tsv : src · type · target · scope       Edges        — typed references it makes
```

- **the Tree** — the `path` and its kind encode the full containment spine, public **and**
  private (`vis`), in Zig's own source order. `kind` classifies every node: `ns` (an
  `@import`'d file) · `nsref` (a reference to a file expanded elsewhere) · `struct`/`enum`/
  `union`/`opaque` (container) · `fn` · `const` · `alias` (a re-export) · `modref` (a module
  import) · `field` · `tag`.
- **Attributes** — a node's own facts: `loc` (source location), `value` (a field/const's
  written type & default), `doc` (`///` comment), `sig` (a fn's as-written signature),
  `example` (a `test {}` body).
- **Edges** — the typed references it makes (`has_type`, `alias`, `error_set`, `imports`,
  `delegates`), each **resolved** to a `scope` recording where its target landed — a node in
  its own container (`local`), one elsewhere (`cross`), a primitive, a module boundary, or
  unresolved.

### Why parsing, not reflection

zephem reads source with `std.zig.Ast` rather than `@typeInfo`. Parsing never evaluates
comptime, so platform-gated and "poison" decls (e.g. `std.c.darwin`'s `assert(isDarwin())`)
are just harmless text. This is what lets it map **all** of std — a reflection walk dies on
the first un-evaluatable decl.

## The headline dataset: the full std map

`zephem std` scans the active toolchain's `std` and writes the three streams to
`data/std/extracted/`. On @@ZIG@@ that is **@@N_NODES@@ nodes across @@N_FILES@@ files**
(@@N_PUB@@ public, @@N_PRIV@@ private), max nesting depth @@MAXDEPTH@@ — carrying @@N_ATTRS@@
attributes and @@N_EDGES@@ typed edges.

```sh
awk -F'\t' '$2=="ns"' data/std/extracted/nodes.tsv                        # every std source file
grep -P '^std\.crypto\.' data/std/extracted/nodes.tsv                      # the crypto subtree
awk -F'\t' '$2=="fn"' data/std/extracted/nodes.tsv | wc -l                # public+private fn count (@@N_FN@@)
awk -F'\t' '$2=="has_type" && $4=="cross"' data/std/extracted/edges.tsv   # cross-container type refs
```

### It proves itself — no external oracle

The build is **two passes that must agree**, bundled on purpose:

- **forward** (`parse/build.zig`) reads the source into the three streams.
- **backward** (the backward check in `zephem std`) re-reads them *the other way* and checks the shapes
  reconcile.

There is no `n_children` count to conserve — depth and parent are read straight off each
`path`. The checks are **referential**: the Tree is **connected** (every non-root path's
parent is itself a node), the kinds **partition** (every row classified once), every
**attribute keys onto a real node**, and every **`local`/`cross` edge resolves to a real
node** — the one invariant that makes the reference graph trustworthy. If the two passes
disagree, `zephem std` exits non-zero and claims nothing.

```
$ zig build std
[forward]  scanning .../std.zig  (@@ZIG@@, depth @@MAXDEPTH@@)
           rows: @@N_NODES_RAW@@   files: @@N_FILES@@   private: @@N_PRIV_RAW@@
[index]    containers: @@N_INDEX_RAW@@   root span: @@N_NODES_RAW@@   max depth: @@MAXDEPTH@@
[attrs]    @@N_ATTRS_RAW@@ rows — doc @@A_DOC_RAW@@ · sig @@A_SIG_RAW@@ · value @@A_VAL_RAW@@ · example @@A_EX_RAW@@
[edges]    @@N_EDGES_RAW@@ rows — resolved @@E_RESOLVED_RAW@@ / unresolved @@E_UNRES_RAW@@
[backward] re-reading the datasets — must reconcile...
VERDICT: ✓ all integrity checks pass
build_std: ✓ true (forward == backward) and recorded.
```

`data/std/PINNED` records the exact Zig version the snapshot is from. Reruns on the same
Zig are byte-identical (`git diff --exit-code` clean).

The dataset proves itself without any external oracle (above). Separately — as a coverage
sanity-check, not a correctness proof — [`docs/comparison/autodoc-vs-zephem.md`](docs/comparison/autodoc-vs-zephem.md)
lines this snapshot up against Zig's own autodoc extraction (autodoc's `Walk.zig` driven
natively): on the shared public-declaration surface the two reach a near-identical set, and
zephem additionally carries fields, enum tags, private decls, the edge graph, and the
resolved layer autodoc does not emit. That note is a *dated* comparison, not a regenerated
artifact — it pins its inputs and ships the commands to re-derive every figure; autodoc's
side is not rebuilt as part of zephem.

### Reading it efficiently: the table of contents

The whole tree is large — too big to read linearly to answer a narrow question. But because
rows are emitted pre-order, **every subtree is a contiguous block**, so you never have to.
`data/std/derived/index.tsv` is a tiny map (@@N_INDEX@@ containers) of `path · line · span`:
look up a module, then read exactly its block.

```sh
zephem map show std.crypto                          # just the crypto subtree, via the table of contents
sed -n '@@CRYPTO_LINE@@,+@@CRYPTO_SPAN@@p' data/std/extracted/nodes.tsv   # or read the raw block (line @@CRYPTO_LINE@@, span @@CRYPTO_SPAN@@)
```

The index self-checks: the root's span equals the whole file, and the backward check in `zephem std` re-derives
every block from `nodes.tsv` so the map can't drift.

Copy-pasteable query recipes (read one module, find by name, the kind breakdown) live with the
data they query: **[data/README.md](data/README.md)**.

## Beyond the map: the other engines, keyed to it

The shape model is the skeleton the parser emits. Deeper facts are produced by **separate
engines** and join back at the same `path`, so every row anchors to a node that exists. Three
ship today, all self-verifying and byte-identical on rerun:

> This is the tour. The canonical per-dataset reference — every extractor's columns, purpose, and
> self-check — lives in the folder READMEs: [`extracted/`](data/std/extracted/) and
> [`derived/`](data/std/derived/); engine internals in [`parse/`](parse/) and [`reflect/`](reflect/).

- **`data/std/extracted/resolved.tsv`** (L5 resolved depth) — `path · kind · detail` from
  `reflect/resolve.zig`, which reflects each container in its own isolated subprocess so a poison
  decl can't kill the sweep. On @@ZIG@@: @@N_INDEX@@ containers swept → **@@N_RES_CONT@@ resolved (@@N_RESOLVED@@
  rows) / @@N_POISON@@ genuine poison** (each recorded in `data/std/extracted/poison.tsv` with the compiler's exact
  reason); `data/std/extracted/status.tsv` is the per-container ledger. Verified by the backward check in `zephem depth`.
  *Not yet wired into `--check`* — an L5 rebuild is a full reflection sweep whose wall time is
  strongly machine-dependent (≈1 min on a 16-lane desktop, ≈13 min on a 3-core VM), so its
  reproducibility harness is a deliberately separate task (see PLAN.md).

- **`data/std/derived/consensus.tsv`** (the consensus census) — `path · origin · owner` from
  `zephem overlays`. Rather than force the text view (`nodes.tsv`) and the reflected view
  (`resolved.tsv`) to match 1:1 and call every non-match a "miss", it **compares** them and tags
  **every** path by which witness can see it: `read+run` (both independently agree — @@CON_RR@@),
  `run-only` (only exists when reflected — a generic/alias member like `Sha256.digest_length` —
  @@CON_RUNONLY@@), `read-only` (text read it but it can't run here: poison, private, or the `std`
  root — @@CON_READONLY@@). The two single-witness buckets **are** the differences; the agreement
  is independent evidence. One row per path in `nodes ∪ resolved` (@@N_CONSENSUS@@), **zero blanks**,
  enforced by `zephem overlays --check` and deterministic (`--check`).

- **`data/std/derived/canon.tsv`** (dedup / dealias) — `path · canon` from `zephem overlays`. The
  compiler resolves every type to a canonical `@typeName`, so two paths that name the *same*
  underlying type collide on it. This overlay surfaces exactly those collisions — **@@N_CANON@@ paths in @@CANON_FAMILIES@@
  alias/dup families** (e.g. `std.BufMap` and `std.buf_map.BufMap` → `buf_map.BufMap`) — while
  excluding primitive / error-set / anonymous identities that collide by accident, not by aliasing.
  Reads `resolved.tsv` alone; verified by `zephem overlays --check`, deterministic (`--check`).

The deferred edge layers (body-level `calls`/`references`) and the roadmap for the remaining
work (L4 runnable test examples, L6 version diff) live in **[PLAN.md](PLAN.md)**.

## Documentation map — where to look

| doc | for | who |
|---|---|---|
| **[README.md](README.md)** (this) | what/why, quickstart | everyone — start here |
| **[PLAN.md](PLAN.md)** | status + roadmap | maintainers |
| **[parse/README.md](parse/README.md)** · **[reflect/README.md](reflect/README.md)** | how each engine works | contributors |
| **[data/README.md](data/README.md)** | the data layer + query recipes | users of the datasets |
| **[data/std/extracted/README.md](data/std/extracted/README.md)** · **[derived/README.md](data/std/derived/README.md)** | per-dataset reference (columns, purpose, self-check) | anyone consuming a `.tsv` |
| **[docs/reproducibility.md](docs/reproducibility.md)** | the determinism / `--check` contract | maintainers |
| **[docs/comparison/autodoc-vs-zephem.md](docs/comparison/autodoc-vs-zephem.md)** | how coverage compares to Zig's own autodoc | curious |
| **[docs/archive/README.md](docs/archive/README.md)** | tombstone — retired work, *historical only* | provenance |

Rule of thumb: **datasets are described once, in the folder READMEs; engines once, in `parse/` +
`reflect/`.** Everything else links to those rather than re-describing them.

## How the docs stay current

`zephem docs` regenerates every markdown doc from the sources in
[`templates/`](templates/), injecting each number live from `data/std/` — so the docs can't drift
from the data, and `zephem docs --check` proves each one rebuilds byte-identical.

## Where it started: `std.crypto` (archived)

zephem began life (as `zcrypto`) pointed only at `std.crypto`, via **reflection** — which
resolves real byte sizes and signatures but can't generalize (a reflection walk dies on the
first platform-gated decl). That whole pipeline — tools, scripts, and datasets — is retired
(deleted, with provenance in the archive tombstone
[`docs/archive/README.md`](docs/archive/README.md)). The AST parser above replaced it as
the general tool the project is built around now.

## How it's built

The extractor is **three engines**, split by *what each reads*:

- **[`parse/`](parse/)** — the **read-it** engine (documented in full at
  [parse/README.md](parse/README.md)). `parse/build.zig` follows `@import` from the root **once**
  and walks the whole organism in a single pass → the **shape model**: the Tree (`nodes.tsv`),
  the Attributes (`attrs.tsv` — @@N_SIGS@@ signatures, @@N_DOCS@@ `///` docs, @@N_VALUES@@ field/const
  values, @@N_LOC@@ locations, @@N_EXAMPLES@@ test bodies), and the Edges (`edges.tsv` — @@N_EDGES@@
  typed references, resolved to a scope). It **descends type factories** (a `fn(…) type` with one
  `return struct {…}` gets its members under `<fn>()`, e.g. `std.HashMap().get`) and gives each
  selective re-export a single canonical home. It reads source as text and never runs the compiler,
  which is what lets it map all of std without dying on poison decls.
- **[`reflect/`](reflect/)** — the **run-it** engine. `reflect/resolve.zig` does the one job
  parsing can't — subprocess-isolated reflection for the L5 resolved-depth overlay
  (`resolved.tsv`). Resolves real values; dies on poison, by nature.
- **[`derive/`](derive/)** — the **transform** engine. Reads no Zig at all, only the datasets
  above, each as its own single-purpose overlay: `derive/index.zig` builds the table of contents
  (`index.tsv`) over the Tree; `zephem overlays` dedups/de-aliases resolved types into
  alias/dup families (`canon.tsv`); and `zephem overlays` compares parse vs reflect,
  tagging where the two readers agree or differ (`consensus.tsv`).

The backward checks, overlays, glue, and query are all Zig (in `src/`, driven by the `zephem`
binary). The dividing line:
**raw source facts go in the parser** (the tree, attributes, and declaration-level edges);
**organisation is deferred to derive** (resolved cross-link graphs, purpose-groupings), and
**body-level edges** (`calls`/`references`) are the parser's next layer. Phases and status:
**[PLAN.md](PLAN.md)**.

## Toolchain

**Zig, end to end.** Three engines — `parse/` (AST parsing), `reflect/` (compiler reflection),
`derive/` (transforms) — plus the `src/` layer (orchestration, relational joins, overlays, query,
doc generation). Built by `zig build`, run as the `zephem` binary. No Nushell, no Python, no duckdb.

## Reference

- Zig std source: the active toolchain's `std`, located via `zig env` (its `.std_dir`);
  `zephem std` reads it from there, so the snapshot tracks whatever Zig is on `PATH`.
- Prior life: zephem began as `zcrypto`, an attempt to *learn* crypto, then a faithful map of
  it. Renamed and reframed 2026-06-17 — the tool is the extractor, not the crypto. The retired
  crypto pipeline and the retired human-readable docs were deleted and folded into one provenance
  note, [`docs/archive/README.md`](docs/archive/README.md) (recover any file from git history).
