# zephem · parse — the faithful reader

**`parse/` reads Zig as *text* and outputs ONE file: the structural map, in Zig's own source
order.** Parse all → output all. It is one of three engines; the other two are at the bottom.
The map it produces is the product and lives one level up in [`../data/std/`](../data/std/).

This is the **read-it** engine: it parses `std.zig.Ast` and **never runs the compiler**, so
platform-gated and "poison" decls are just harmless text. That is what lets it map **all** of
std — a reflection walk dies on the first un-evaluatable decl. (Running the compiler is the
job of the sibling [`../reflect/`](../reflect/) engine.)

---

## 1. Purpose — one literal file, nothing added

The map is a **literal transcription of Zig's structure, in Zig's source order** — and *only*
the structure. One row per public declaration:

```
path · depth · kind · name · n_children · detail
```

That is the whole contract, and the thing to protect:

- **No sorting.** Rows come out pre-order, depth-first, children in the exact order the file
  declares them. Never alphabetised, never grouped.
- **No relationships, no "directions".** The parser records *what is declared and where* —
  not what resolves to what. Reference/link resolution is a separate layer, never the parser's.
- **No extra detail.** Not signatures, not doc-comments, not resolved values. Just the names,
  kinds, child-counts, and files. *"I don't need every line of code — the name of the file in
  the order Zig gives it."*

Everything beyond the bare map — signatures, docs, references, grouping — is deliberately a
**separate "organize later" layer**, never folded into the parser. We parse faithfully first
and organise on top afterwards.

The product is **ephemeral by design**: never hand-authored, always regenerable from source,
pinned to one Zig version (`../data/std/PINNED` → @@ZIG@@). The product is the pipeline that
reproduces it, not the bytes.

> The moment the map sorts, groups, or resolves a link, it stops being Zig and starts being
> our reading of Zig. The base map is the one artifact that must stay a pure mirror.

## 2. What it produces (`../data/std/`)

| dataset | what it is | built by |
|---|---|---|
| `nodes.tsv` | **the map** — `path · depth · kind · name · n_children · detail`, one row per public decl, field, or enum tag, source order | `build.zig` → `walk.zig` |

One engine, one file. The parser also emits three raw-source-fact side outputs keyed by the same
`path` — `sigs.tsv` (@@N_SIGS@@ as-written fn signatures), `docs.tsv` (@@N_DOCS@@ `///` docs), and
`fields.tsv` (@@N_FIELDS@@ struct/union fields + enum tags, as `path · type · value`).
(The `index.tsv` table of contents is built *from* this map by the [`../derive/`](../derive/)
engine, not by the parser.)

## 3. How it works

**① Parse, don't reflect.** Built from `std.zig.Ast` — reads source as syntax, never evaluates
comptime. Sees all of std; dies on nothing.

**② One walk, one writer.** `build.zig` parses the root once and runs the walk (`walk.zig`),
which writes each public decl straight out as a TSV row. One traversal, one output — no visitor
indirection, no second stream to drift from.

**③ Source-order emission.** `walk.zig` emits each decl the instant it sees it and never sorts.
Proof it is Zig's order: `std`'s children come out `…BufSet, StaticStringMap,
StaticStringMapWithEql, Deque…` — the exact non-alphabetical sequence in `std.zig`.

**④ It proves itself.** `build.zig` emits forward; `../scripts/verify_std.nu` re-reads the map
from the other end (grouping rows by parent path). The core check is a **conservation law** —
every node except the root is exactly one node's child, so `Σ n_children == rows − 1`. A
dropped, doubled, or truncated decl breaks it and the build claims nothing.

**⑤ Reproducible.** `--check` does two fresh rebuilds and diffs them against the committed snapshot.

## 4. The files

```
parse/
  build.zig    # @@LC_BUILD@@  ENTRY: parse a root ONCE, run the walk → nodes.tsv
  walk.zig     # @@LC_WALK@@  the parse-walk + the row writer (Node, Kind, walkMembers, emitReexport)
  ast.zig      # @@LC_AST@@  read primitives: dirname/relPath/parseFile + parseImport/isAliasChain/
               #      findDecl/countPub/containerKindOf
```

Three flat files — one entry, one traversal, one primitives module. (`build` must sit at
`parse/` root: `zig run` makes the entry's directory the module root, and an entry cannot
`@import("../…")`.)

## 5. Running it

```nu
nu scripts/build_std.nu [--check]    # rebuild the map (+ its TOC via derive/), verify, record
```

---

## The other engines, and what's deferred

`parse/` is the **read-it** engine. The faithful base is just the map. On top of it:

- **[`../reflect/`](../reflect/)** — the **run-it** engine. `resolve.zig` reflects each
  container in an isolated subprocess to resolve real values/types → `resolved.tsv` (L5).
- **`../derive/`** — **transforms datasets, reads no Zig.** `index.zig` builds the TOC
  (`index.tsv`); `../scripts/build_canon.nu` joins parse ⋈ reflect into the census (`canon.tsv`).

**Organize later** (deliberately *not* in the parser; preserved in git history):
**references / links** between names, and **grouping** the map by purpose. Each is *our*
organisation laid on top — added back as its own layer once the faithful base is settled,
never mixed into the parse.
