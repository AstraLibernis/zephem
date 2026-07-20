# extracted/ — literal facts from Zig

Everything here is a **fact read straight out of Zig** — either from the source text
(the `parse/` engine) or from the compiler's own resolution (the `reflect/` engine).
zephem does not interpret, join, or reshape any of it. If a row here is wrong, Zig
said so; nothing in this folder is zephem's opinion.

The transforms that combine or reshape these files live one level over in
[`../derived/`](../derived/).

Pinned to **@@ZIG@@** (`../PINNED`); a target-specific subset (see `resolved`/`poison`
below) is **@@TARGET@@** (the host recorded in `../PINNED`).

---

## From the parser (`parse/`) — the shape model

One walk over the source (`std.zig.Ast`, so comptime is never evaluated — platform-gated
and "poison" decls are just harmless text, which is what lets the parser map **all** of
std) emits **three streams**, the three shapes every node has:

- **the Tree** — where a node sits (`nodes.tsv`)
- its **Attributes** — the facts a node carries about itself (`attrs.tsv`)
- its **Edges** — the typed references a node makes to other nodes (`edges.tsv`)

All three key on the same dotted `path`, so they re-join without a lookup table.

### `nodes.tsv` — the Tree (the headline dataset)
The whole `std` namespace tree, one row per node. A node is a declaration (public **or**
private), a struct/union **field**, an enum **tag**, or a **type-factory member** (a member
of the type a `fn(…) type` returns, pathed under `<fn>()` — e.g. `std.MultiArrayList().append`;
the `()` marks "instantiate first"). **@@N_NODES@@ rows** (@@N_PUB@@ pub / @@N_PRIV@@ priv)
across **@@N_FILES@@ files**, max depth **@@MAXDEPTH@@**.
Columns: `path · kind · name · vis`  (`vis ∈ pub · priv`).
`kind ∈ ns · nsref · nserr · modref · struct · enum · union · opaque · fn · const · alias · field · tag`.

Emitted pre-order, depth-first, in Zig's own source order — never sorted, never grouped.
Because it's pre-order, **every subtree is a contiguous block** (that's what `../derived/index.tsv`
indexes). The tree carries no `n_children` column: a node's depth and parent are read straight
off its `path`, and the verifier reconciles the tree by that — every non-root path's parent is
itself a node.

### `attrs.tsv` — Attributes (a node's own facts)
`path · attr · value`. Sparse: a row exists only where the fact is present. **@@N_ATTRS@@ rows**
across seven attributes:

| attr | value | count |
|---|---|---|
| `loc` | source location `file:line` (root-relative, machine-independent) | @@N_LOC@@ |
| `value` | a `field`/`tag`'s written type & default, or a `const`'s literal | @@N_VALUES@@ |
| `doc` | the decl's `///` doc-comment, whitespace-collapsed | @@N_DOCS@@ |
| `sig` | a `fn`'s as-written signature (`fn` keyword through return type, body excluded) | @@N_SIGS@@ |
| `example` | a `test {}` body verbatim (tabs/newlines escaped so it stays one row) | @@N_EXAMPLES@@ |
| `mod` | a decl's qualifiers — `extern`/`export`/`inline`/`noinline`/`threadlocal`/`comptime`/`var` (sparse; `var` distinguishes a mutable global from a `const`) | @@N_MOD@@ |
| `errmember` | a member of a named `error{…}` set (one row per member) | @@N_ERRMEMBER@@ |

### `edges.tsv` — Edges (typed references, resolved)
`src · type · target · scope`. Every reference a declaration makes, **with its reach resolved**
in a second pass against the walked node set. **@@N_EDGES@@ edges**, five types:

| type | count | what it links |
|---|---|---|
| `has_type` | @@N_HASTYPE@@ | a fn param/return or field → the type it names |
| `alias` | @@N_ALIASEDGE@@ | a re-export (`pub const X = Y.Z`) → what it points at |
| `error_set` | @@N_ERRSET@@ | an `error{…}` / error-union → its members |
| `imports` | @@N_IMPORTS@@ | an `@import` alias → the file/module it names |
| `delegates` | @@N_DELEGATES@@ | a forwarding factory (`fn X() type { return Y(args); }`) → its target |

`scope` records **where the target landed** — the one invariant worth protecting is that a
`local`/`cross` edge always points at a real node:

| scope | count | meaning |
|---|---|---|
| `primitive` | @@E_PRIM@@ | a language builtin (`i32`, `usize`, `type`, …) |
| `local` | @@E_LOCAL@@ | a node inside `src`'s own container (incl. `@This()`) |
| `cross` | @@E_CROSS@@ | a node elsewhere in the tree |
| `module` | @@E_MODULE@@ | an `@import` alias / a file or module boundary |
| `unresolved` | @@E_UNRES@@ | couldn't place it (comptime-built, exotic) |
| `inline` | @@E_INLINE@@ | an inline `struct{…}`/`enum{…}` literal target |
| `generic` | @@E_GENERIC@@ | a comptime type parameter in scope |

**@@E_RESOLVED@@ of @@N_EDGES@@ edges (@@E_RESOLVED_PCT@@% of the resolvable ones)** land on a
node, primitive, or generic param; @@E_UNRES@@ stay unresolved.

the backward check in `zephem std` proves the shapes reconcile: every non-root path's **parent is a node** (the tree
is connected), every **attr keys onto a real node**, and every **`local`/`cross` edge resolves to
a real node** — the links are valid.

---

## From reflection (`reflect/`) — what the compiler resolves

`reflect/resolve.zig` reflects each container in its **own isolated subprocess**, so a
poison decl can't kill the sweep. This is the compiler's resolved view — real types,
expanded generics, evaluated const values — the one thing a pure parser cannot see.
These rows are **@@TARGET@@-specific**: a decl gated to another target resolves as
poison here.

### `resolved.tsv` — resolved depth
`path · kind · detail`. Resolved const values, expanded generics, typed signatures.
On @@ZIG@@: **@@N_RES_CONT@@ containers resolved (@@N_RESOLVED@@ rows).**

### `poison.tsv` — what didn't resolve
`path · reason`. Decls that failed to resolve, each with the compiler's exact reason
(platform / foreign lib / `@compileError` / timeout). **@@N_POISON@@ genuine poison.**
The tree now includes private decls (many platform/foreign-lib) and uninstantiated `()`
factory containers, so poison is higher than the pub-only parser's was — each is an honest
"the compiler couldn't build this here", not a miss.

### `status.tsv` — the per-container ledger
`path · status · n_rows`. One row per container the sweep attempted; the verifier
re-derives the buckets from this and reconciles them against `resolved`/`poison`.

Verified by the backward check in `zephem depth` (conservation, registration vs the map, no duplicates).
The reflect sweep's wall time is machine-dependent (≈1 min on a 16-lane desktop,
≈13 min on a 3-core VM), so its rebuild harness is a separate task from `zephem std`'s
`--check` (see `PLAN.md`).
