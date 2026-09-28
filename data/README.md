<!-- GENERATED from templates/data.tmpl.md by `zephem docs` — edit the template, not this file. -->
# data/ — the dataset layer

Toolchain: **Zig, end to end.** The three engines extract (parsing std source, reflecting it
through the compiler); the `src/` layer does the glue and the querying (the `zephem` binary).
No Nushell, no Python, no duckdb — the TSV files are the source of truth, queried by
`zephem look`/`map` (or any tool: they're plain TSV).

The snapshot lives in `std/`, pinned to **zig 0.16.0** (`std/PINNED`), split into two groups
by *where each fact comes from*:

| folder | what it holds | producer | trust |
|---|---|---|---|
| **[`std/extracted/`](std/extracted/)** | literal facts read straight from Zig — the parser's shape model (tree, attributes, edges) and the compiler's resolved view | `parse/` + `reflect/` | if a row is wrong, **Zig** said so |
| **[`std/derived/`](std/derived/)** | joins, comparisons, and reshapes over the extracted files — TOC, consensus, canon, doc-coverage, signature shapes, call-card | `derive/` + `src/` | every row **traces back** to extracted rows; nothing invented |

Each folder has its own README documenting every dataset it contains (columns, counts,
and the self-check that guards it). The clean line: **extracted/ is what Zig says;
derived/ is what zephem computes from it, and can be deleted and rebuilt from extracted/
alone.**

At a glance — the parser's shape model is **63,494 nodes across 340 files**
(the tree), **111,480 attributes** (13,721 docs, 11,273 sigs, 19,809 values,
63,493 locations, 1,433 test bodies, 1,257 modifiers, 494 error members),
and **54,666 typed edges**; reflect adds
2,912 containers resolved, and six derivatives key back to the tree at the same `path`.

## Kind policy — who owns what, and which overlay counts it

Clean lines of separation: **every fact has exactly one producer** (the parser owns
*as-written* source facts; reflect owns *resolved* facts; derive overlays only
*join/compare*, never invent a new fact). Each overlay treats the map's kinds by one
documented rule below — so a kind is never double-counted or silently dropped.

| kind / thing | owned by | in `index` | in `doccov` | in `consensus` | in `sigshape`/`callcard` |
|---|---|---|---|---|---|
| decl (`fn`/`const`/`struct`/`enum`/`union`/`opaque`/`alias`/`ns`; namespace refs `nsref`/`modref`/`nserr` follow the same tree rules) | parser (tree) | if it has children | ✅ all | ✅ (vs reflect) | fns only |
| **`field` / `tag`** | parser (tree; type/value in `attrs`) | no (leaves) | ✅ all | **excluded** — reflect never resolves a field as its own path | no (not callables) |
| **factory member** (`…()` path) | parser (as-written) · reflect owns *resolved* (Phase D) | if it has children | ✅ all | **excluded** — uninstantiated; nothing to resolve yet | ✅ as *parser-only* (written sig, no resolved type) |
| **private decl** (`vis == priv`) | parser (tree) | if it has children | ✅ all | `read-only` unless reflect built it too | fns only |
| **delegator** (`fn` with a `delegates` edge) | parser (`edges`) | no (leaf) | ✅ all | ✅ (it's a normal `fn`) | fns only |

Rules of thumb: **`doccov`** is 1:1 with the whole tree. **`consensus`** compares only
what *both* engines can name — so parser-only structural members (fields, tags,
uninstantiated factory members) are out of scope. **`callcard`/`sigshape`** are about
signatures, so factory-member and private fns join in (as parser-only where the compiler
couldn't build them). **Nothing is computed twice.**

## Dependency maps (`data/deps/`, git-ignored)

`zephem deps <project>` writes one map per module a project's packages export:
`deps/<package-hash>/<module>/` holds `extracted/{nodes,attrs,edges}.tsv`, `derived/index.tsv`, a
`SHA256SUMS`, and a `SOURCE` recording the package, its hash or path, the module's root file and
the Zig version. Same columns as std's files; no reflection layer. The lookup table includes every
map present, and rebakes itself when one is added, replaced or removed.

## Regenerate

```sh
zig build std                # parse → index → verify (extracted/{nodes,attrs,edges}, derived/index)
zephem depth --commit        # reflect sweep → extracted/{resolved,poison,status} (slow; separate)
zig build overlays           # canon / consensus / doccov / sigshape / callcard → derived/
```

Every step is deterministic (same Zig → byte-identical) and idempotent
(`git diff --exit-code` clean), guarded by a `SHA256SUMS` manifest (main + per-slice
sidecars), each with its own `--check` rebuild proof.

## Query examples

```sh
# search or browse the map with the zephem binary
zephem map show std.crypto        # one subtree, straight from the table of contents
zephem look parse int             # keyword search over name/path/sig/doc/resolved type

# the datasets are plain TSV — query with any tool
awk -F'\t' '$2=="ns"' data/std/extracted/nodes.tsv                                          # every source file
awk -F'\t' '{c[$2]++} END{for (k in c) print c[k], k}' data/std/extracted/nodes.tsv | sort -rn   # kind breakdown
```

Per-dataset columns, purpose, and the self-check that guards each live in the folder READMEs:
**[std/extracted/](std/extracted/)** and **[std/derived/](std/derived/)**.

## Archived

The original `std.crypto` reflection pipeline (datasets, scripts, src) was retired 2026-06-17 and
its files deleted — **no archived `.tsv` lingers to be mistaken for current data.** Provenance and
git-recovery instructions live in the archive tombstone,
[`../docs/archive/README.md`](../docs/archive/README.md).

## License of the datasets

The datasets under `std/` are extracted from the Zig standard library and contain its
declarations, signatures and doc comments, which are MIT-licensed (Expat, Copyright (c) Zig
contributors; see [`ZIG-LICENSE`](ZIG-LICENSE)). The datasets, including the columns zephem derives,
are released under the same MIT terms. zephem's code is GPL-3.0-or-later; the datasets are not.
