<!-- GENERATED from templates/root.tmpl.md by `zephem docs` — edit the template, not this file. -->
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
  `example` (a `test {}` body), `mod` (qualifiers — `extern`/`export`/`inline`/`noinline`/
  `threadlocal`/`comptime`, and `var` vs `const`), and `errmember` (the members of a named
  `error{…}` set).
- **Edges** — the typed references it makes (`has_type`, `alias`, `error_set`, `imports`,
  `delegates`), each **resolved** to a `scope` recording where its target landed — a node in
  its own container (`local`), one elsewhere (`cross`), a primitive, a module boundary, or
  unresolved.

Beside the tree, **`builtins.tsv`** covers the language's builtins (`@intCast`, `@memcpy`, …,
128 in all), taken from the compiler's own builtin table and the language reference
that ship with the toolchain, and cross-checked against each other. `zephem look intCast` and
`zephem map doc @intCast` find them like any declaration.

### Why parsing, not reflection

zephem reads source with `std.zig.Ast` rather than `@typeInfo`. Parsing never evaluates
comptime, so platform-gated and "poison" decls (e.g. `std.c.darwin`'s `assert(isDarwin())`)
are just harmless text. This is what lets it map **all** of std — a reflection walk dies on
the first un-evaluatable decl.

## Quickstart

```sh
zig build                        # → zig-out/bin/zephem (ReleaseSafe by default; -Doptimize=Debug to debug)
zephem std                       # map the active toolchain's std → data/std/extracted/
zephem map doc std.fmt.parseInt  # query the map (builds its lookup table on first use)
```

Every subcommand takes `-h`/`--help` and rejects unknown arguments. The query commands
(`look`, `map`) signal their outcome in the **exit code**, so a script or agent can tell an
answer from the absence of one:

| exit | meaning |
|---|---|
| 0 | found — results on stdout |
| 1 | ran correctly, nothing matched (stdout empty, like `grep`) |
| 2 | usage error — bad flag, missing operand, unknown subcommand |
| 3 | the map or lookup table is **unavailable** — not the same as a miss; regenerate it |

Misses and errors go to stderr; stdout carries only results. `look` keeps results short: an
error set longer than a line folds to its true member count (`error{…30 members}`); `map doc`
prints it whole. Hits from platform bindings (`std.c.*`, `std.os.*`) rank after the portable
API and are counted in the header, unless the query names the platform (`look linux mmap`).
`map doc` also shows usage taken from std's own tests: the declaration's doctest
(`test parseInt {…}`) when it has one, otherwise the shortest test in its namespace that calls
it with an argument count matching its signature, labelled with where it came from. When no single declaration matches every term (`look print stdout`), the miss
names the best hits for each term alone on stderr (`std.debug.print`, `std.Io.Writer.print` ·
`std.Io.File.stdout`). A `map doc`/`map show` miss also
names the closest real paths on stderr (`std.fmt.parseint` → `std.fmt.parseInt`); the exit code
is still 1.

**Thin names are followed to their members.** Many everyday std names are an alias or a one-line
wrapper around something else: `std.ArrayList` is `fn ArrayList(T) type`, returning
`array_list.Aligned(T, null)`, so its members live under `std.array_list.Aligned().…`. The queries
follow the `alias` and `delegates` edges the parser recorded, and print each hop:

```sh
zephem map show std.ArrayList          # std.ArrayList ─delegates→ std.array_list.Aligned, then its members
zephem map doc std.ArrayList.append    # resolves to std.array_list.Aligned().append
zephem look StringHashMap get          # alias → delegates → std.hash_map.HashMap().get
```

Each hit that is reachable under other public names lists them on a `≡` line; the lookup table
carries them in its `aka` column. Nothing is inferred: every hop is an edge from `edges.tsv`.

Needs Zig **zig 0.16.0** on `PATH` (the snapshot tracks whatever `zig` resolves to). The full
command surface is `zephem <std|depth|overlays|lookup|look|map|docs>` — details below and in
each engine's README.

**Everything zephem writes stays inside the checkout.** Both query commands (and zcanon) read
`data/lookup.tsv`, one pre-joined row per declaration, with `data/examples.tsv` and
`data/lookup.stamp` beside it. All three are derived from the map and git-ignored. `look` and
`map` rebuild them automatically (about 80 ms) when they are missing or older than the datasets,
checked against the datasets' manifests, so a query never answers from a stale index; `zephem
lookup` rebuilds them by hand. Scratch work goes to `.zig-cache/`. Deleting the zephem folder
removes all of it. (Before 2026-09-28 the index was written to `~/.config/zephem/lookup.tsv`;
that old copy is no longer read and can be deleted.) zephem finds its checkout from the
directory you run it in or, failing that, from where its binary lives, so it works from anywhere.

Cold, on a Ryzen 7 9800X3D (release build, one pinned core, benchfence-gated): `look` 4.6 ms,
`map show` 4.3 ms, `map doc`/`map find` 6.8 ms, a miss with suggestions 10–11 ms.

## The headline dataset: the full std map

`zephem std` scans the active toolchain's `std` and writes the three streams to
`data/std/extracted/`. On zig 0.16.0 that is **63,494 nodes across 340 files**
(56,088 public, 7,406 private), max nesting depth 8 — carrying 111,480
attributes and 54,666 typed edges.

```sh
awk -F'\t' '$2=="ns"' data/std/extracted/nodes.tsv                        # every std source file
grep -P '^std\.crypto\.' data/std/extracted/nodes.tsv                      # the crypto subtree
awk -F'\t' '$2=="fn"' data/std/extracted/nodes.tsv | wc -l                # public+private fn count (11,273)
awk -F'\t' '$2=="has_type" && $4=="cross"' data/std/extracted/edges.tsv   # cross-container type refs
```

### It proves itself — no external oracle

The build is **two passes that must agree**, bundled on purpose:

- **forward** (`parse/walk.zig`) reads the source into the three streams.
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
[forward]  scanning .../std.zig  (zig 0.16.0, depth 8)
           rows: 63494   files: 340   private: 7406
[index]    containers: 4042   root span: 63494   max depth: 8
[attrs]    111480 rows — doc 13721 · sig 11273 · value 19809 · example 1433
[edges]    54666 rows — resolved 48094 / unresolved 2020
[backward] re-reading the datasets — must reconcile...
VERDICT: ✓ all integrity checks pass
build_std: ✓ true (forward == backward) and recorded.
```

`data/std/PINNED` records the exact Zig version the snapshot is from. Reruns on the same
Zig are byte-identical (`git diff --exit-code` clean).

The dataset proves itself without any external oracle (above). Separately — as a coverage
sanity-check, not a correctness proof — [`docs/comparison/autodoc-vs-zephem.md`](docs/comparison/autodoc-vs-zephem.md)
lines this snapshot up against Zig's own autodoc extraction: on the shared public surface the
two reach a near-identical set, and zephem additionally carries fields, enum tags, private
decls, the edge graph, and the resolved layer. See that note for the method and figures.

### Reading it efficiently: the table of contents

The whole tree is large — too big to read linearly to answer a narrow question. But because
rows are emitted pre-order, **every subtree is a contiguous block**, so you never have to.
`data/std/derived/index.tsv` is a tiny map (4,042 containers) of `path · line · span`:
look up a module, then read exactly its block.

```sh
zephem map show std.crypto                          # just the crypto subtree, via the table of contents
sed -n '17659,+3587p' data/std/extracted/nodes.tsv   # or read the raw block (line 17659, span 3587)
```

The index self-checks: the root's span equals the whole file, and the backward check in `zephem std` re-derives
every block from `nodes.tsv` so the map can't drift.

Copy-pasteable query recipes (read one module, find by name, the kind breakdown) live with the
data they query: **[data/README.md](data/README.md)**.

## Beyond the map: the other engines, keyed to it

The shape model is the skeleton the parser emits. Deeper facts are produced by **separate
engines** and join back at the same `path`, so every row anchors to a node that exists. They
ship today, all self-verifying and byte-identical on rerun:

> This is the tour. The canonical per-dataset reference — every extractor's columns, purpose, and
> self-check — lives in the folder READMEs: [`extracted/`](data/std/extracted/) and
> [`derived/`](data/std/derived/); engine internals in [`parse/`](parse/) and [`reflect/`](reflect/).

- **`data/std/extracted/resolved.tsv`** (L5 resolved depth) — `path · kind · detail` from
  `reflect/resolve.zig`, which reflects each container in its own isolated subprocess so a poison
  decl can't kill the sweep. On zig 0.16.0: 4,042 containers swept → **2,908 resolved (15,792
  rows) / 927 genuine poison** (each recorded in `data/std/extracted/poison.tsv` with the compiler's exact
  reason); `data/std/extracted/status.tsv` is the per-container ledger. Verified by the backward check in `zephem depth`.
  *Not yet wired into `--check`* — an L5 rebuild is a full reflection sweep whose wall time is
  strongly machine-dependent (≈1 min on a 16-lane desktop, ≈13 min on a 3-core VM), so its
  reproducibility harness is a deliberately separate task (see PLAN.md).

- **`data/std/derived/consensus.tsv`** (the consensus census) — `path · origin · owner` from
  `zephem overlays`. Rather than force the text view (`nodes.tsv`) and the reflected view
  (`resolved.tsv`) to match 1:1 and call every non-match a "miss", it **compares** them and tags
  **every** path by which witness can see it: `read+run` (both independently agree — 13,412),
  `run-only` (only exists when reflected — a generic/alias member like `Sha256.digest_length` —
  2,304), `read-only` (text read it but it can't run here: poison, private, or the `std`
  root — 12,987). The two single-witness buckets **are** the differences; the agreement
  is independent evidence. One row per path in `nodes ∪ resolved` (28,703), **zero blanks**,
  enforced by `zephem overlays --check` and deterministic (`--check`).

- **`data/std/derived/canon.tsv`** (dedup / dealias) — `path · canon` from `zephem overlays`. The
  compiler resolves every type to a canonical `@typeName`, so two paths that name the *same*
  underlying type collide on it. This overlay surfaces exactly those collisions — **236 paths in 100
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
[`docs/archive/README.md`](docs/archive/README.md); recover any file from git history). The
AST parser above replaced it as the general tool the project is built around now — renamed and
reframed **2026-06-17**, the tool is the extractor, not the crypto.

## How it's built

The extractor is **three engines**, split by *what each reads*:

- **[`parse/`](parse/)** — the **read-it** engine (documented in full at
  [parse/README.md](parse/README.md)). `parse/walk.zig` follows `@import` from the root **once**
  and walks the whole organism in a single pass → the **shape model**: the Tree (`nodes.tsv`),
  the Attributes (`attrs.tsv` — 11,273 signatures, 13,721 `///` docs, 19,809 field/const
  values, 63,493 locations, 1,433 test bodies, 1,257 modifiers, 494 error
  members), and the Edges (`edges.tsv` — 54,666
  typed references, resolved to a scope). It **descends type factories** (a `fn(…) type` with one
  `return struct {…}` gets its members under `<fn>()`, e.g. `std.hash_map.HashMap().get`) and gives each
  selective re-export a single canonical home. It reads source as text and never runs the compiler,
  which is what lets it map all of std without dying on poison decls.
- **[`reflect/`](reflect/)** — the **run-it** engine. `reflect/resolve.zig` does the one job
  parsing can't — subprocess-isolated reflection for the L5 resolved-depth overlay
  (`resolved.tsv`). Resolves real values; dies on poison, by nature.
- **[`derive/`](derive/)** — the **transform** layer. Reads no Zig at all, only the datasets
  above. The directory holds one engine, `derive/index.zig`, which builds the table of contents
  (`index.tsv`) over the Tree. The other overlays are the `zephem overlays` subcommand (in `src/`):
  `canon.tsv` dedups/de-aliases resolved types into alias/dup families, `consensus.tsv` compares
  parse vs reflect, plus the coverage/signature overlays.

The backward checks, overlays, glue, and query are all Zig (in `src/`, driven by the `zephem`
binary). The dividing line:
**raw source facts go in the parser** (the tree, attributes, and declaration-level edges);
**organisation is deferred to derive** (resolved cross-link graphs, purpose-groupings), and
**body-level edges** (`calls`/`references`) are the parser's next layer. Phases and status:
**[PLAN.md](PLAN.md)**.

## Toolchain

**Zig, end to end.** The three engines above plus the `src/` layer (orchestration, relational
joins, overlays, query, doc generation), built by `zig build` and run as the `zephem` binary.
No Nushell, no Python, no duckdb.

## Reference

- Zig std source: the active toolchain's `std`, located via `zig env` (its `.std_dir`);
  `zephem std` reads it from there, so the snapshot tracks whatever Zig is on `PATH`.
- Prior life: see [Where it started](#where-it-started-stdcrypto-archived) above — the `zcrypto`
  origin and the archive tombstone.

## License

GPL-3.0-or-later · Copyright (C) 2026 AstraLibernis

zephem is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See `LICENSE`.

**Exception: the datasets.** Everything under `data/std/` is extracted from the Zig standard library, which is MIT-licensed (Expat, Copyright (c) Zig contributors; see [`data/ZIG-LICENSE`](data/ZIG-LICENSE)). The datasets are released under the same MIT terms, so they can be used anywhere the Zig source can.

Versions up to and including commit `95e1ed8` were released under the MIT License; copies obtained under those terms keep them.

Contributions are welcome under the [Developer Certificate of Origin](https://developercertificate.org/): sign off each commit with `git commit -s`. You keep the copyright on your contribution.
