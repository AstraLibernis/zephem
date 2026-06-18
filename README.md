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
`data/std/nodes.tsv`. On Zig 0.16.0 that is **16,631 public decls across 442 files**, max
nesting depth 9.

```nu
open data/std/nodes.tsv | where kind == 'ns'                  # every std source file
open data/std/nodes.tsv | where path =~ '^std\.crypto\.'      # the crypto subtree
open data/std/nodes.tsv | where kind == 'fn' | length         # public fn count (5321)
open data/std/nodes.tsv | group-by kind | items {|k,v| {kind:$k n:($v|length)}}
```

### It proves itself — no external oracle

The build is **two passes that must agree**, bundled on purpose:

- **forward** (`src/scan.zig`) reads the source into rows.
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
           rows: 16631   files: 442   max depth: 9
[backward] re-reading nodes.tsv by parent — must reconcile...
conservation:  Σ n_children = 16630   rows − 1 = 16630   ✓
per-node:       1495 expanded containers checked            ✓
partition:      Σ kinds = 16631   rows = 16631             ✓
nsref integrity: 59 refs                                   ✓
build_std: ✓ forward and backward agree — snapshot is sound.
```

`data/std/PINNED` records the exact Zig version the snapshot is from. Reruns on the same
Zig are byte-identical (`git diff --exit-code` clean).

### Reading it efficiently: the table of contents

The whole file is ~221k tokens — too big to read linearly to answer a narrow question. But
because rows are emitted pre-order, **every subtree is a contiguous block**, so you never
have to. `data/std/index.tsv` is a tiny map (1,495 containers) of `path · line · span`: look
up a module, then read exactly its block.

```nu
let b = (open data/std/index.tsv | where path == 'std.crypto' | first)  # line 4704, span 1057
open data/std/nodes.tsv | skip ($b.line - 2) | first $b.span            # just the crypto subtree
```

The index self-checks: the root's span equals the whole file (conservation again), and
`verify_std.nu` re-derives every block's edges from `nodes.tsv` so the map can't drift.

Copy-pasteable recipes (read one module, find by name, orient, regenerate): **[USAGE.md](USAGE.md)**.

## Where it started: `std.crypto` (archived)

zephem began life (as `zcrypto`) pointed only at `std.crypto`, via **reflection** — which
resolves real byte sizes and signatures but can't generalize (a reflection walk dies on the
first platform-gated decl). That whole pipeline — tools, scripts, and datasets — is retired
under **`archive/crypto-reflection/`** (see its README). The AST scanner above replaced it as
the general tool the project is built around now.

## How it's built

**AST source parsing** (`src/scan.zig`) builds the map; `src/index.zig` builds the table of
contents; `scripts/verify_std.nu` is the backward check. Parsing (not reflection) is what lets
it map all of std without dying on poison decls. Everything is glued and queried by Nushell.
Phases and status: **[PLAN.md](PLAN.md)**.

## Toolchain

**Zig** (AST parsing) + **Nushell** (glue / query) only.

## Reference

- Zig 0.16 std source: `/usr/local/zig/lib/std/std.zig`
- Prior life: zephem began as `zcrypto`, an attempt to *learn* crypto, then a faithful map of
  it. Renamed and reframed 2026-06-17 — the tool is the extractor, not the crypto. The retired
  crypto pipeline lives in `archive/crypto-reflection/`; retired human-readable docs in
  `docs/archive/` (each has a README).
