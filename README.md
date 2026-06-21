# zephem

**Z**ig + **ephem**eral. A tool that extracts the structure of a Zig module — its
**containers, labels, and levels** — and transforms it into pristine, queryable
**datasets** built for LLM consumption and static research.

The data is *ephemeral by design*: never hand-authored, always regenerated from the
compiler's own source. A committed dataset is just a pinned snapshot of a fixed Zig
version — the product is the pipeline that reproduces it, not the bytes.

## What it does

Point it at a Zig source root and it walks the whole logical namespace tree — following
`@import` edges between files and descending inline `struct`/`enum`/`union`/`opaque`
literals — emitting one tidy row per public declaration:

```
path · depth · kind · name · n_children · detail
```

- **levels** — depth + the dotted `path` encode the full tree
- **labels** — `kind` classifies every decl: `ns` (an `@import`'d file) · `nsref` (a
  reference to a file already expanded elsewhere) · `nserr` (unreadable file) ·
  `struct`/`enum`/`union`/`opaque` (inline container) · `fn` · `const` · `alias`
  (a re-export like `pub const X = Y.Z`) · `modref` (import of a module, not a file)
- **n_children** — every container records how many public children it emits

### Why parsing, not reflection

zephem reads source with `std.zig.Ast` rather than `@typeInfo`. Parsing never evaluates
comptime, so platform-gated and "poison" decls (e.g. `std.c.darwin`'s `assert(isDarwin())`)
are just harmless text. This is what lets it map **all** of std — a reflection walk dies on
the first un-evaluatable decl.

## The headline dataset: the full std map

`nu scripts/build_std.nu` scans the active toolchain's `std` and writes
`data/std/nodes.tsv`. On Zig 0.16.0 that is **16,506 public decls across 310 files**, max
nesting depth 8.

```nu
open data/std/nodes.tsv | where kind == 'ns'                  # every std source file
open data/std/nodes.tsv | where path =~ '^std\.crypto\.'      # the crypto subtree
open data/std/nodes.tsv | where kind == 'fn' | length         # public fn count (5377)
open data/std/nodes.tsv | group-by kind | items {|k,v| {kind:$k n:($v|length)}}
```

### It proves itself — no external oracle

The build is **two passes that must agree**, bundled on purpose:

- **forward** (`parse/build.zig`) reads the source into rows.
- **backward** (`scripts/verify_std.nu`) re-reads `nodes.tsv` *from the other end* —
  grouping rows by parent path — and checks the tree reconciles.

The core check is a **conservation law**: every node except the root is exactly one node's
child, so `Σ n_children == (rows − 1)`. A dropped, double-counted, or truncated decl breaks
it. The verifier also checks per-node child counts, kind partition (every row classified
once), and `nsref` integrity (every reference points at a file expanded somewhere). If the
two passes disagree, `build_std.nu` exits non-zero and claims nothing.

```
$ nu scripts/build_std.nu
[forward]  scanning .../std.zig  (zig 0.16.0, depth 24)
           rows: 16506   files: 310   max depth: 8
[index]    containers: 1355   root span: 16506
[backward] re-reading the datasets — must reconcile...
conservation:  Σ n_children = 16505   rows − 1 = 16505   ✓
per-node:       1355 expanded containers checked           ✓
partition:      Σ kinds = 16506   rows = 16506             ✓
nsref integrity: 6 refs                                    ✓
build_std: ✓ true (forward == backward) and recorded.
```

`data/std/PINNED` records the exact Zig version the snapshot is from. Reruns on the same
Zig are byte-identical (`git diff --exit-code` clean).

### Reading it efficiently: the table of contents

The whole file is ~221k tokens — too big to read linearly to answer a narrow question. But
because rows are emitted pre-order, **every subtree is a contiguous block**, so you never
have to. `data/std/index.tsv` is a tiny map (1,355 containers) of `path · line · span`: look
up a module, then read exactly its block.

```nu
let b = (open data/std/index.tsv | where path == 'std.crypto' | first)  # line 4676, span 1086
open data/std/nodes.tsv | skip ($b.line - 2) | first $b.span            # just the crypto subtree
```

The index self-checks: the root's span equals the whole file (conservation again), and
`verify_std.nu` re-derives every block's edges from `nodes.tsv` so the map can't drift.

Copy-pasteable recipes (read one module, find by name, orient, regenerate) are parked in
**[docs/archive/USAGE.md](docs/archive/USAGE.md)** pending a rewrite.

## Beyond the map: the other engines, keyed to it

The map is the skeleton — and the *only* thing the parser emits. Deeper facts are produced by
**separate engines** and join back at the same `path`, so every row anchors to a node that
exists. Two ship today, both self-verifying and byte-identical on rerun:

- **`data/std/resolved.tsv`** (L5 resolved depth) — `path · kind · detail` from
  `reflect/resolve.zig`, which reflects each container in its own isolated subprocess so a poison
  decl can't kill the sweep. On Zig 0.16.0: 1,355 containers swept → **1,324 resolved (15,720
  rows) / 31 genuine poison** (each recorded in `data/std/poison.tsv` with the compiler's exact
  reason); `data/std/status.tsv` is the per-container ledger. Verified by `scripts/verify_depth.nu`.
  *Not yet wired into `--check`* — an L5 rebuild is a full reflection sweep whose wall time is
  strongly machine-dependent (≈1 min on a 16-lane desktop, ≈13 min on a 3-core VM), so its
  reproducibility harness is a deliberately separate task (see PLAN.md).

- **`data/std/canon.tsv`** (the canonical-link census) — `path · origin · owner · owner_canon ·
  note` from `scripts/build_canon.nu`. Instead of forcing the text view (`nodes.tsv`) and the
  reflected view (`resolved.tsv`) to match 1:1 and calling every non-match a "miss", it tags **every**
  path by what can actually see it: `read+run` (both agree — 13,424), `run-only` (only exists when
  reflected — a generic/alias member like `Sha256.digest_length` — 2,296), `read-only` (text read it
  but it can't run here: poison, or the `std` root — 3,082). One row per path in `nodes ∪ resolved`
  (18,802), each made-member linked to its canonical owner; **zero blanks**, enforced by
  `scripts/verify_canon.nu` and deterministic (`--check`). This is the layer that makes "nothing is
  missing" a *checked* property rather than a claim.

The deferred "organize later" layers (signatures + doc-comments, references/links, grouping by
purpose) and the roadmap for the remaining work (L4 runnable test examples, L6 version diff)
live in **[PLAN.md](PLAN.md)**.

## Where it started: `std.crypto` (archived)

zephem began life (as `zcrypto`) pointed only at `std.crypto`, via **reflection** — which
resolves real byte sizes and signatures but can't generalize (a reflection walk dies on the
first platform-gated decl). That whole pipeline — tools, scripts, and datasets — is retired
under **`archive/crypto-reflection/`** (see its README). The AST scanner above replaced it as
the general tool the project is built around now.

## How it's built

The extractor is **three engines**, split by *what each reads*:

- **[`parse/`](parse/)** — the **read-it** engine (documented in full at
  [parse/README.md](parse/README.md)). `parse/build.zig` parses std **once** and drives a
  single generic walk (`parse/walk.zig`) over the structure visitor → **one file**, `nodes.tsv`
  (the map). Parse all → output all: just paths, names, kinds, child-counts, files, in source
  order. It reads source as text and never runs the compiler, which is what lets it map all of
  std without dying on poison decls.
- **[`reflect/`](reflect/)** — the **run-it** engine. `reflect/resolve.zig` does the one job
  parsing can't — subprocess-isolated reflection for the L5 resolved-depth overlay
  (`resolved.tsv`). Resolves real values; dies on poison, by nature.
- **[`derive/`](derive/)** — the **transform** engine. Reads no Zig at all, only the datasets
  above: `derive/index.zig` builds the table of contents (`index.tsv`) over the map, and
  `scripts/build_canon.nu` joins parse vs reflect into the provenance census (`canon.tsv`).

The backward checks (`scripts/verify_*.nu`) and all glue/query are Nushell. Three things are
**deliberately deferred to "organize later"** layers — *our* organisation laid on the faithful
base, never mixed into the parse: **signatures + doc-comments**, **references/links** between
names, and **grouping** the map by purpose. Phases and status: **[PLAN.md](PLAN.md)**.

## Toolchain

**Zig** (AST parsing) + **Nushell** (glue / query) only.

## Reference

- Zig 0.16 std source: `/usr/local/zig/lib/std/std.zig`
- Prior life: zephem began as `zcrypto`, an attempt to *learn* crypto, then a faithful map of
  it. Renamed and reframed 2026-06-17 — the tool is the extractor, not the crypto. The retired
  crypto pipeline lives in `archive/crypto-reflection/`; retired human-readable docs in
  `docs/archive/` (each has a README).
