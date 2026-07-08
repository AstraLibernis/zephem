# data/ — the dataset layer

Toolchain: **Zig** does the extraction (parsing std source, reflecting it through the
compiler), **Nushell** does the glue and the querying. No Python, no duckdb — the TSV
files are the source of truth, and Nushell queries them natively.

The snapshot lives in `std/`, pinned to **@@ZIG@@** (`std/PINNED`), split into two groups
by *where each fact comes from*:

| folder | what it holds | producer | trust |
|---|---|---|---|
| **[`std/extracted/`](std/extracted/)** | literal facts read straight from Zig — the map, signatures, docs, fields/tags, and the compiler's resolved view | `parse/` + `reflect/` | if a row is wrong, **Zig** said so |
| **[`std/derived/`](std/derived/)** | joins, comparisons, and reshapes over the extracted files — TOC, consensus, canon, doc-coverage, signature shapes, call-card | `derive/` + `scripts/` | every row **traces back** to extracted rows; nothing invented |

Each folder has its own README documenting every dataset it contains (columns, counts,
and the self-check that guards it). The clean line: **extracted/ is what Zig says;
derived/ is what zephem computes from it, and can be deleted and rebuilt from extracted/
alone.**

At a glance — **@@N_NODES@@ nodes across @@N_FILES@@ files** (map), @@N_SIGS@@ signatures,
@@N_DOCS@@ docs, @@N_FIELDS@@ fields/tags, @@N_EXAMPLES@@ test/doctest examples, @@N_RES_CONT@@ containers resolved, and six
derivatives keyed back to the map at the same `path`.

## Kind policy — who owns what, and which overlay counts it

Clean lines of separation: **every fact has exactly one producer** (the parser owns
*as-written* source facts; reflect owns *resolved* facts; derive overlays only
*join/compare*, never invent a new fact). Each overlay treats the map's kinds by one
documented rule below — so a kind is never double-counted or silently dropped.

| kind / thing | owned by | in `index` | in `doccov` | in `consensus` | in `sigshape`/`callcard` |
|---|---|---|---|---|---|
| decl (`fn`/`const`/`struct`/`enum`/`union`/`opaque`/`alias`/`ns`) | parser | if `n_children>0` | ✅ all | ✅ (vs reflect) | fns only |
| **`field` / `tag`** | parser (`fields.tsv`) | no (leaves) | ✅ all | **excluded** — reflect never resolves a field as its own path | no (not callables) |
| **factory member** (`…()` path) | parser (as-written) · reflect owns *resolved* (Phase D) | if `n_children>0` | ✅ all | **excluded** — uninstantiated; nothing to resolve yet | ✅ as *parser-only* (written sig, no resolved type) |
| **delegator** (`fn` with a `delegates.tsv` row) | parser (`delegates.tsv`) | no (leaf) | ✅ all | ✅ (it's a normal `fn`) | fns only |

Rules of thumb: **`doccov`** is 1:1 with the whole map. **`consensus`** compares only
what *both* engines can name — so parser-only structural members (fields, tags,
uninstantiated factory members) are out of scope. **`callcard`/`sigshape`** are about
signatures, so factory-member fns join in (as parser-only until Phase D resolves them).
**Nothing is computed twice.**

## Regenerate

```nu
nu scripts/build_std.nu          # parse → index → verify (extracted/nodes+sigs+docs+fields+delegates, derived/index)
nu scripts/build_depth.nu --commit   # reflect sweep → extracted/{resolved,poison,status} (slow; separate)
nu scripts/build_consensus.nu    # and build_canon / build_doccov / build_sigshape / build_callcard → derived/
```

Every step is deterministic (same Zig → byte-identical) and idempotent
(`git diff --exit-code` clean), guarded by a `SHA256SUMS` manifest (main + per-slice
sidecars) and a matching `verify_*.nu`.

## Query examples (Nushell)

```nu
# every source file, one subtree, or the kind breakdown (the map is in extracted/)
open data/std/extracted/nodes.tsv | where kind == 'ns'
open data/std/extracted/nodes.tsv | where path =~ '^std\.crypto\.'
open data/std/extracted/nodes.tsv | group-by kind | items {|k,v| {kind:$k n:($v|length)}} | sort-by n -r

# jump straight to one module via the table of contents (derived/)
let b = (open data/std/derived/index.tsv | where path == 'std.mem' | first)
open data/std/extracted/nodes.tsv | skip ($b.line - 2) | first $b.span
```

Per-dataset columns, purpose, and the self-check that guards each live in the folder READMEs:
**[std/extracted/](std/extracted/)** and **[std/derived/](std/derived/)**.

## Archived

The original `std.crypto` reflection pipeline (datasets, scripts, src) was retired 2026-06-17 and
its files deleted — **no archived `.tsv` lingers to be mistaken for current data.** Provenance and
git-recovery instructions live in the archive tombstone,
[`../docs/archive/README.md`](../docs/archive/README.md).
