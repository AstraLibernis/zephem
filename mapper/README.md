# zephem · the mapper

**The mapper translates a Zig module into datasets — faithfully, in Zig's own order.**

This folder is the whole tool. Point it at a Zig source root; it walks the logical
namespace tree and emits one tidy row per public declaration. The datasets it produces
are the product, and they live one level up in [`../data/std/`](../data/std/) — this
folder is only the machine that makes them.

---

## 1. Purpose — what "faithful" means here

The map is a **literal transcription of Zig's structure, in Zig's source order**. That is
the entire contract, and it is the thing to protect:

- **No sorting.** Rows come out pre-order, depth-first, children in the exact order the
  file declares them. Never alphabetised, never grouped.
- **No clustering.** The mapper does not bucket `crypto`+`hash`+`base64` into an
  "encoding" group, or `os`+`posix`+`fs` into "system". Those are *our* ideas; they are
  kept out, in [`../clusters/`](../clusters/), unwired by design.
- **No invented links.** The only relationships recorded are the ones Zig literally wrote
  (`@import` edges, `pub const X = Y.Z` aliases). Anything we *make up* later
  (semantic links, purpose groupings) is a separate overlay, never folded into the base.

The product is **ephemeral by design**: never hand-authored, always regenerable from the
compiler's own source. A committed `.tsv` is just a pinned snapshot of one Zig version
(`../data/std/PINNED` → zig 0.16.0). The product is the pipeline that reproduces it, not
the bytes.

> Why this matters: the moment the map sorts or groups, it stops being Zig and starts
> being our reading of Zig. The base map is the one artifact that must stay a pure mirror.

---

## 2. What it produces (`../data/std/`)

The spine is `nodes.tsv`; every other dataset is an **overlay** that attaches more true
facts at the same `path`, so they join cleanly.

| dataset | what it is | built by |
|---|---|---|
| `nodes.tsv` | **the map** — `path · depth · kind · name · n_children · detail`, one row per public decl, source order | `build.zig` → `walk.zig` + `visit/map.zig` |
| `decls.tsv` | L1/L2 overlay — `path · doc · sig` (a fn's as-written signature; any `///` doc) | `build.zig` → `visit/enrich.zig` |
| `index.tsv` | the table of contents — `path · line · span` per container, so any subtree is one contiguous read | `index.zig` |
| `tunnels.tsv` | L3 reference graph — resolved cross-file edges between names | `tunnels.zig` + `tunnels/` |
| `resolved.tsv` | L5 resolved depth — real values/types from reflection (the one job parsing can't do) | `resolve.zig` |

`build.zig` parses std **once** and emits the first two together. `canon.tsv` (the
read+run / run-only / read-only census) is *not* produced here — it is a downstream
Nushell join over these datasets (`../scripts/build_canon.nu`).

---

## 3. How it works

**① Parse, don't reflect.** The map is built from `std.zig.Ast` — it reads source as
syntax and *never evaluates comptime*. So platform-gated and "poison" decls
(`std.c.darwin`'s `assert(isDarwin())`) are harmless text. This is what lets it map
**all** of std; a reflection walk dies on the first un-evaluatable decl. The one
exception is `resolve.zig` (L5), which *does* reflect — each container in its own isolated
subprocess, so a poison decl can't kill the sweep.

**② One parse, many visitors.** `build.zig` parses std once; `walk.zig` is the single
parse-walk, generic over a comptime `Visitor`; `visit/map.zig` and `visit/enrich.zig` are
visitor implementations riding that one walk. They **cannot desync** — there is no second
traversal to drift from. (This replaced an older design where `scan.zig` and `enrich.zig`
were two hand-mirrored walks that had to be kept byte-identical by comment discipline.)

**③ Source-order emission.** `walk.zig` emits each decl the instant it sees it and never
sorts. Proof it is Zig's order and not ours: `std`'s children come out
`…BufSet, StaticStringMap, StaticStringMapWithEql, Deque…` — the exact non-alphabetical
sequence in `std.zig`; and `std.os` comes out `linux, plan9, uefi, wasi, emscripten,
windows`, which alphabetising would reorder.

**④ It proves itself — no external oracle.** The build is two passes that must agree:
`build.zig` emits forward; `../scripts/verify_std.nu` re-reads the datasets *from the
other end*, grouping rows by parent path. The core check is a **conservation law** —
every node except the root is exactly one node's child, so `Σ n_children == rows − 1`. A
dropped, doubled, or truncated decl breaks it and the build claims nothing.

**⑤ Reproducible.** Reruns on the same Zig are byte-identical (`--check` does two fresh
rebuilds and diffs them against the committed snapshot).

---

## 4. The files

```
mapper/
  build.zig        #  85  combined entry: parse std ONCE → nodes.tsv + decls.tsv
  walk.zig         # 309  the ONE parse-walk, generic over Visitor (emitReexport + walkMembers)
  common/
    fs.zig         #  31  dirname, relPath, parseFile
    ast.zig        # 103  parseImport, isAliasChain, findDecl, containerKindOf, countPub
    tsv.zig        #  15  col() — minimal TSV reader for the overlay tools
  visit/
    map.zig        #  22  structure visitor → nodes.tsv rows
    enrich.zig     #  97  overlay visitor → decls.tsv (doc + signature)
  index.zig        # 115  TOC over nodes.tsv → index.tsv
  tunnels.zig      # 107  L3 entry: load the map → alias/import/usage edges
  tunnels/
    resolve.zig    # 199  per-file symbol tables + reference-chain resolution
    edges.zig      #  77  emit one tagged edge; harvest type-refs from fn signatures
  resolve.zig      # 134  L5: comptime-reflect ONE container in isolation → resolved.tsv
```

**Why entries sit at the root.** `zig run` sets the module root to the run-file's
directory, so an entry file cannot `@import("../…")`. Entry points (`build`, `index`,
`tunnels`, `resolve`) stay shallow at `mapper/`; their helpers live in subdirs *below*
them (`common/`, `visit/`, `tunnels/`).

---

## 5. Running it

```nu
nu scripts/build_std.nu              # rebuild nodes.tsv + index.tsv + decls.tsv, verify, commit
nu scripts/build_std.nu --check      # prove reproducibility (two rebuilds == snapshot), write nothing
nu scripts/build_tunnels.nu [--check]# rebuild the L3 tunnels overlay
nu scripts/build_depth.nu  [--check] # rebuild the L5 resolved-depth overlay (full reflection sweep)
```

Per-dataset detail lives in [`../docs/layers/`](../docs/layers/); the shared model is
[`../docs/concepts.md`](../docs/concepts.md); the reproducibility machinery is
[`../docs/reproducibility.md`](../docs/reproducibility.md).

---

## 6. What is deliberately *not* here

- **Clustering / sorting / purpose-groupings** → [`../clusters/`](../clusters/)
  (`group.zig`, `organize.zig`). These re-cluster the map "by shape"; they are editorial,
  currently unwired, and kept out so the base map stays a faithful mirror.
- **The canonical-link census** (`canon.tsv`) → a Nushell join over the datasets, not a
  parser. It reads no `.zig` and runs no compiler.
- **Any human "why".** The mapper records what Zig *wrote*, not what it is *for*. Meaning
  is not in the files, so the mapper does not pretend to it.
