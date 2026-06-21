# zephem · parse — the faithful reader

**`parse/` reads Zig as *text* and translates it into datasets — faithfully, in Zig's own
source order.** It is one of three extraction engines; the other two are described at the
bottom. The datasets it produces are the product and live one level up in
[`../data/std/`](../data/std/).

This is the **read-it** engine: it parses `std.zig.Ast` and **never runs the compiler**, so
platform-gated and "poison" decls are just harmless text. That is what lets it map **all** of
std — a reflection walk dies on the first un-evaluatable decl. (Running the compiler is the
job of the sibling [`../reflect/`](../reflect/) engine.)

---

## 1. Purpose — what "faithful" means

The map is a **literal transcription of Zig's structure, in Zig's source order**. That is the
whole contract, and the thing to protect:

- **No sorting.** Rows come out pre-order, depth-first, children in the exact order the file
  declares them. Never alphabetised, never grouped.
- **No clustering.** `parse/` does not bucket `crypto`+`hash` into "encoding" or `os`+`fs` into
  "system". Those are *our* ideas; they are deferred to a later phase (after `../derive/`),
  never folded into the faithful base.
- **No invented links.** The only relationships recorded are the ones Zig literally wrote
  (`@import` edges, `pub const X = Y.Z` aliases).

The product is **ephemeral by design**: never hand-authored, always regenerable from source,
pinned to one Zig version (`../data/std/PINNED` → zig 0.16.0). The product is the pipeline that
reproduces it, not the bytes.

> The moment the map sorts or groups, it stops being Zig and starts being our reading of Zig.
> The base map is the one artifact that must stay a pure mirror.

## 2. What it produces (`../data/std/`)

The spine is `nodes.tsv`; the others are **overlays** keyed to it by `path`, so they join cleanly.

| dataset | what it is | built by |
|---|---|---|
| `nodes.tsv` | **the map** — `path · depth · kind · name · n_children · detail`, one row per public decl, source order | `build.zig` → `walk.zig` + `visit/map.zig` |
| `decls.tsv` | L1/L2 overlay — `path · doc · sig` (a fn's as-written signature; any `///` doc) | `build.zig` → `visit/enrich.zig` |
| `tunnels.tsv` | L3 reference graph — resolved cross-file edges between names | `tunnels.zig` + `tunnels/` |

`build.zig` parses std **once** and emits the first two together.

## 3. How it works

**① Parse, don't reflect.** Built from `std.zig.Ast` — reads source as syntax, never evaluates
comptime. Sees all of std; dies on nothing.

**② One parse, many visitors.** `build.zig` parses once; `walk.zig` is the single parse-walk,
generic over a comptime `Visitor`; `visit/map.zig` and `visit/enrich.zig` ride that one walk
and **cannot desync** — there is no second traversal to drift from.

**③ Source-order emission.** `walk.zig` emits each decl the instant it sees it and never sorts.
Proof it is Zig's order: `std`'s children come out `…BufSet, StaticStringMap,
StaticStringMapWithEql, Deque…` — the exact non-alphabetical sequence in `std.zig`.

**④ It proves itself.** `build.zig` emits forward; `../scripts/verify_std.nu` re-reads the
datasets from the other end (grouping rows by parent path). The core check is a **conservation
law** — every node except the root is exactly one node's child, so `Σ n_children == rows − 1`.
A dropped, doubled, or truncated decl breaks it and the build claims nothing.

**⑤ Reproducible.** `--check` does two fresh rebuilds and diffs them against the committed snapshot.

## 4. The files

```
parse/
  build.zig        #  85  ENTRY: parse std ONCE → nodes.tsv + decls.tsv
  walk.zig         # 309  the ONE parse-walk, generic over Visitor
  common/
    fs.zig         #  31  dirname, relPath, parseFile
    ast.zig        # 103  parseImport, isAliasChain, findDecl, containerKindOf, countPub
    tsv.zig        #  15  col() — minimal TSV reader
  visit/
    map.zig        #  22  structure visitor → nodes.tsv rows
    enrich.zig     #  97  overlay visitor → decls.tsv (doc + signature)
  tunnels.zig      # 107  ENTRY: load the map → alias/import/usage edges
  tunnels/
    resolve.zig    # 199  per-file symbol tables + reference-chain resolution
    edges.zig      #  77  emit one tagged edge; harvest type-refs from fn signatures
```

Entry files (`build`, `tunnels`) sit at `parse/` root; their helpers live in subdirs below
them, because `zig run` sets the module root to the entry's directory and an entry cannot
`@import("../…")`.

## 5. Running it

```nu
nu scripts/build_std.nu [--check]       # nodes.tsv + decls.tsv (+ index via derive/)
nu scripts/build_tunnels.nu [--check]   # tunnels.tsv
```

---

## The other two engines

`parse/` is the **read-it** engine. The full extractor is three:

- **[`../reflect/`](../reflect/)** — the **run-it** engine. `resolve.zig` reflects each
  container in an isolated subprocess to resolve real values/types the parser can't know
  (generic expansions, resolved sizes) → `resolved.tsv` (L5). Dies on poison, by nature.
- **`../derive/`** — **transforms datasets, reads no Zig.** `index.zig` builds the table of
  contents (`index.tsv`) over `nodes.tsv`. (`../scripts/build_canon.nu` is a deriver too —
  the provenance census `canon.tsv`, a join of `nodes` + `resolved`.)

Read-it sees everything but resolves nothing; run-it resolves everything but dies on poison;
derive joins their outputs. See [`../README.md`](../README.md) for the whole picture.
