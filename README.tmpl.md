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
`data/std/nodes.tsv`. On @@ZIG@@ that is **@@N_NODES@@ public decls across @@N_FILES@@ files**, max
nesting depth @@MAXDEPTH@@.

```nu
open data/std/nodes.tsv | where kind == 'ns'                  # every std source file
open data/std/nodes.tsv | where path =~ '^std\.crypto\.'      # the crypto subtree
open data/std/nodes.tsv | where kind == 'fn' | length         # public fn count (@@N_FN@@)
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
[forward]  scanning .../std.zig  (@@ZIG@@, depth 24)
           rows: @@N_NODES_RAW@@   files: @@N_FILES@@   max depth: @@MAXDEPTH@@
[index]    containers: @@N_INDEX_RAW@@   root span: @@N_NODES_RAW@@
[backward] re-reading the datasets — must reconcile...
conservation:  Σ n_children = @@N_EDGES_RAW@@   rows − 1 = @@N_EDGES_RAW@@   ✓
per-node:       @@N_INDEX_RAW@@ expanded containers checked           ✓
partition:      Σ kinds = @@N_NODES_RAW@@   rows = @@N_NODES_RAW@@             ✓
nsref integrity: @@N_NSREF@@ refs                                    ✓
build_std: ✓ true (forward == backward) and recorded.
```

`data/std/PINNED` records the exact Zig version the snapshot is from. Reruns on the same
Zig are byte-identical (`git diff --exit-code` clean).

### Reading it efficiently: the table of contents

The whole file is ~221k tokens — too big to read linearly to answer a narrow question. But
because rows are emitted pre-order, **every subtree is a contiguous block**, so you never
have to. `data/std/index.tsv` is a tiny map (@@N_INDEX@@ containers) of `path · line · span`: look
up a module, then read exactly its block.

```nu
let b = (open data/std/index.tsv | where path == 'std.crypto' | first)  # line @@CRYPTO_LINE@@, span @@CRYPTO_SPAN@@
open data/std/nodes.tsv | skip ($b.line - 2) | first $b.span            # just the crypto subtree
```

The index self-checks: the root's span equals the whole file (conservation again), and
`verify_std.nu` re-derives every block's edges from `nodes.tsv` so the map can't drift.

Copy-pasteable recipes (read one module, find by name, orient, regenerate) are parked in
**[docs/archive/USAGE.md](docs/archive/USAGE.md)** pending a rewrite.

## Beyond the map: the other engines, keyed to it

The map is the skeleton — and the *only* thing the parser emits. Deeper facts are produced by
**separate engines** and join back at the same `path`, so every row anchors to a node that
exists. Three ship today, all self-verifying and byte-identical on rerun:

- **`data/std/resolved.tsv`** (L5 resolved depth) — `path · kind · detail` from
  `reflect/resolve.zig`, which reflects each container in its own isolated subprocess so a poison
  decl can't kill the sweep. On @@ZIG@@: @@N_INDEX@@ containers swept → **@@N_RES_CONT@@ resolved (@@N_RESOLVED@@
  rows) / @@N_POISON@@ genuine poison** (each recorded in `data/std/poison.tsv` with the compiler's exact
  reason); `data/std/status.tsv` is the per-container ledger. Verified by `scripts/verify_depth.nu`.
  *Not yet wired into `--check`* — an L5 rebuild is a full reflection sweep whose wall time is
  strongly machine-dependent (≈1 min on a 16-lane desktop, ≈13 min on a 3-core VM), so its
  reproducibility harness is a deliberately separate task (see PLAN.md).

- **`data/std/consensus.tsv`** (the consensus census) — `path · origin · owner` from
  `scripts/build_consensus.nu`. Rather than force the text view (`nodes.tsv`) and the reflected view
  (`resolved.tsv`) to match 1:1 and call every non-match a "miss", it **compares** them and tags
  **every** path by which witness can see it: `read+run` (both independently agree — @@CON_RR@@),
  `run-only` (only exists when reflected — a generic/alias member like `Sha256.digest_length` —
  @@CON_RUNONLY@@), `read-only` (text read it but it can't run here: poison, or the `std` root — @@CON_READONLY@@). The
  two single-witness buckets **are** the differences; the agreement is independent evidence. One row
  per path in `nodes ∪ resolved` (@@N_CONSENSUS@@), **zero blanks**, enforced by `scripts/verify_consensus.nu`
  and deterministic (`--check`).

- **`data/std/canon.tsv`** (dedup / dealias) — `path · canon` from `scripts/build_canon.nu`. The
  compiler resolves every type to a canonical `@typeName`, so two paths that name the *same*
  underlying type collide on it. This overlay surfaces exactly those collisions — **@@N_CANON@@ paths in @@CANON_FAMILIES@@
  alias/dup families** (e.g. `std.BufMap` and `std.buf_map.BufMap` → `buf_map.BufMap`) — while
  excluding primitive / error-set / anonymous identities that collide by accident, not by aliasing.
  Reads `resolved.tsv` alone; verified by `scripts/verify_canon.nu`, deterministic (`--check`).

The deferred "organize later" layers (references/links, grouping by purpose) and the roadmap for
the remaining work (L4 runnable test examples, L6 version diff) live in **[PLAN.md](PLAN.md)**.

## Browse it: the generated viewer

**[`docs/architecture.html`](docs/architecture.html)** is a generated site — a hub plus one page
per derivative under **`docs/views/`** (index, canon, consensus). Each slice charts its primary
drivers and differences (containers by depth, alias family sizes, the read-only ◀ both ▶ run-only
split, poison ranked by compiler error) and links to the raw `.tsv`. Nothing is hand-authored:
`scripts/build_arch.nu` injects every number, chart, and row from `data/std/` on each build, the
charts are plain CSS bars (no JS — works straight off the filesystem), and the findings update the
moment the data does. `build_arch.nu --check` proves every page rebuilds byte-identical. The same
script also regenerates this README and the other markdown docs from `.tmpl.md` templates, so their
numbers can't drift either.

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
  single generic walk (`parse/walk.zig`) → the **map** (`nodes.tsv`: paths, names, kinds,
  child-counts, files, source order) plus the raw source facts only a parser can see:
  as-written **fn signatures** (`sigs.tsv`, @@N_SIGS@@) and **`///` docs** (`docs.tsv`, @@N_DOCS@@), both
  keyed by `path`. It reads source as text and never runs the compiler, which is what lets it map
  all of std without dying on poison decls.
- **[`reflect/`](reflect/)** — the **run-it** engine. `reflect/resolve.zig` does the one job
  parsing can't — subprocess-isolated reflection for the L5 resolved-depth overlay
  (`resolved.tsv`). Resolves real values; dies on poison, by nature.
- **[`derive/`](derive/)** — the **transform** engine. Reads no Zig at all, only the datasets
  above, each as its own single-purpose overlay: `derive/index.zig` builds the table of contents
  (`index.tsv`) over the map; `scripts/build_canon.nu` dedups/de-aliases resolved types into
  alias/dup families (`canon.tsv`); and `scripts/build_consensus.nu` compares parse vs reflect,
  tagging where the two readers agree or differ (`consensus.tsv`).

The backward checks (`scripts/verify_*.nu`) and all glue/query are Nushell. The dividing line:
**raw source facts go in the parser** (structure, signatures, docs — and next, fields +
location/modifiers); **organisation is deferred to derive** — **references/links** between names
and **grouping** the map by purpose, never mixed into the parse. Phases and status:
**[PLAN.md](PLAN.md)**.

## Toolchain

**Zig** (AST parsing) + **Nushell** (glue / query) only.

## Reference

- Zig std source: the active toolchain's `std`, located via `zig env` (its `.std_dir`);
  `build_std.nu` reads it from there, so the snapshot tracks whatever Zig is on `PATH`.
- Prior life: zephem began as `zcrypto`, an attempt to *learn* crypto, then a faithful map of
  it. Renamed and reframed 2026-06-17 — the tool is the extractor, not the crypto. The retired
  crypto pipeline lives in `archive/crypto-reflection/`; retired human-readable docs in
  `docs/archive/` (each has a README).
