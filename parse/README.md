<!-- GENERATED from templates/parse.tmpl.md by `zephem docs` — edit the template, not this file. -->
# zephem · parse — the faithful reader

**`parse/` reads Zig as *text* and emits the shape model — three streams keyed by `path`.**
One walk, parse all → output all. It is one of three engines; the other two are at the bottom.
The streams it produces are the product and live one level up in [`../data/std/extracted/`](../data/std/extracted/).

This is the **read-it** engine: it parses `std.zig.Ast` and **never runs the compiler**, so
platform-gated and "poison" decls are just harmless text. That is what lets it map **all** of
std — a reflection walk dies on the first un-evaluatable decl. (Running the compiler is the
job of the sibling [`../reflect/`](../reflect/) engine.)

---

## 1. The shape model — three streams, one walk

Every node in a Zig source tree has exactly three kinds of fact about it, so the parser emits
exactly three streams:

```
nodes.tsv : path · kind · name · vis          the Tree     — where the node sits
attrs.tsv : path · attr · value               Attributes   — facts the node carries about itself
edges.tsv : src · type · target · scope       Edges        — typed references it makes to other nodes
```

- **Tree** is fixed: one containment spine, one row per node, Zig's own source order (never
  sorted, never grouped). Public **and** private decls, tagged `vis`. Depth and parent are read
  off the dotted `path` — there is no `n_children` count to drift.
- **Attributes** are open-ended in kind but bounded per node: `loc`, `value`, `doc`, `sig`,
  `example`, `mod` (qualifiers), `errmember` (error-set members). Sparse — a row exists only
  where the fact is present.
- **Edges** are open-ended in count (a node may make many): `has_type`, `alias`, `error_set`,
  `imports`, `delegates` — each **resolved** to a `scope` recording where its target landed.

> The moment the Tree sorts or groups, it stops being Zig and starts being our reading of Zig.
> The Tree stays a pure mirror; interpretation lives in the derive layer on top.

The product is **ephemeral by design**: never hand-authored, always regenerable from source,
pinned to one Zig version (`../data/std/PINNED` → zig 0.16.0). The product is the pipeline that
reproduces it, not the bytes.

## 2. What it produces (`../data/std/extracted/`)

| stream | shape | what it is |
|---|---|---|
| `nodes.tsv` | Tree | 63,494 nodes (56,088 pub / 7,406 priv), incl. fields, tags, and factory members (`<fn>()`) |
| `attrs.tsv` | Attributes | 111,480 facts — 13,721 docs · 11,273 sigs · 19,809 values · 63,493 locations · 1,433 test bodies · 1,257 modifiers · 494 error members |
| `edges.tsv` | Edges | 54,666 typed references, 96% of the resolvable ones landing on a node/primitive |

(The `index.tsv` table of contents is built *from* the Tree by the [`../derive/`](../derive/)
engine, not by the parser. Per-column detail lives in the folder README:
[`extracted/`](../data/std/extracted/).)

## 3. How it works

**① Parse, don't reflect.** Built from `std.zig.Ast` — reads source as syntax, never evaluates
comptime. Sees all of std; dies on nothing.

**② One organism walk.** `walk.zig` follows `@import` edges from the root, expanding each file
once, so the whole reachable namespace is one tree. It **descends type factories** — a `fn(…) type`
with one top-level `return struct {…}` gets its produced type's members mapped under `<fn>()` (so
`std.hash_map.HashMap().get` exists) — and places each **selective re-export** (`pub const X = @import("f").Sel`)
at a single canonical home under the alias, so a member is never duplicated.

**③ Two-phase edge resolution.** Phase 1 walks the whole tree, emitting nodes and recording every
raw edge. Phase 2 resolves each edge's target against the completed node set — chasing alias chains,
recognizing generic parameters and inline literals, and marking the reach as `local`, `cross`,
`primitive`, `module`, `generic`, `inline`, or `unresolved`. The invariant it upholds: **every
`local`/`cross` edge points at a real node** (one canonical home per member, aliases carry a
resolvable link rather than a copy).

**④ Source-order emission.** The Tree comes out in the exact order the files declare things —
`std`'s children emerge `…BufSet, StaticStringMap, StaticStringMapWithEql, Deque…`, the
non-alphabetical sequence in `std.zig`.

**⑤ It proves itself.** `walk.zig` emits forward; the backward check in `zephem std` re-reads the three
streams the other way and checks they reconcile: the Tree is **connected** (every non-root path's
parent is a node), the kinds **partition**, every **attr keys onto a real node**, and every
**`local`/`cross` edge resolves to a real node**. A dropped, doubled, or dangling row breaks a
check and the build claims nothing.

**⑥ Reproducible.** `--check` does a fresh rebuild and diffs it against the committed snapshot.

## 4. The file

```
parse/
  walk.zig       # follow @import from the root ONCE, walk the organism, resolve edges
               #        → nodes.tsv (Tree) · attrs.tsv (Attributes) · edges.tsv (Edges)
```

One flat file — one walk, one two-phase resolver, three writers. `walk.zig` is imported as the
`parse` module and driven in-process by `zephem std` (its `run()` fn is the entry point); there is
no `zig run` handoff.

## 5. Running it

```sh
zig build std        # or: zephem std [--check]  — rebuild the three streams (+ the TOC), verify, record
```

---

## The other engines, and what's deferred

`parse/` is the **read-it** engine. On top of the shape model:

- **[`../reflect/`](../reflect/)** — the **run-it** engine. `resolve.zig` reflects each
  container in an isolated subprocess to resolve real values/types → `resolved.tsv` (L5).
- **`../derive/`** — **transforms datasets, reads no Zig.** `index.zig` builds the TOC
  (`index.tsv`); the `src/` overlays (`zephem overlays`) join Tree ⋈ reflect into the census
  (`consensus.tsv`, `canon.tsv`, `callcard.tsv`, …).

**Deferred edges** (preserved in git history, added back as their own layer once the base is
settled): **body-level `calls` and `references`** — who calls/reads what inside a function body,
a heavier walk than the declaration-level edges the parser emits today.
