<!-- GENERATED from templates/extracted.tmpl.md by `zephem docs` — edit the template, not this file. -->
# extracted/ — literal facts from Zig

Everything here is a **fact read straight out of Zig** — either from the source text
(the `parse/` engine) or from the compiler's own resolution (the `reflect/` engine).
zephem does not interpret, join, or reshape any of it. If a row here is wrong, Zig
said so; nothing in this folder is zephem's opinion.

The transforms that combine or reshape these files live one level over in
[`../derived/`](../derived/).

Pinned to **zig 0.17.0** (`../PINNED`); a target-specific subset (see `resolved`/`poison`
below) is **x86_64-linux** (the host recorded in `../PINNED`).

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
the `()` marks "instantiate first"). Two more node shapes keep what has no access path of its
own: a **variant** — one arm of a const chosen per platform or option (`switch (native_os) {…}`,
`if (cond) A else B`), pathed `<const>.[<label>]` like a tuple field's `[0]` (e.g.
`std.c.IPPROTO.[macos].TCP`; the label is the prong's tags, its `when` attr the full condition)
— and a **file node** `<owner>.@"f.zig"` (private), holding the rest of a file that std reaches
only through `@import("f.zig").Sel` (its private helpers and tests; `Sel` itself is at its
re-export path, and resolves its names in this file). **86,046 rows** (77,266 pub / 8,780 priv)
across **484 files**, max depth **8**.
Columns: `path · kind · name · vis`  (`vis ∈ pub · priv`).
`kind ∈ ns · nsref · nserr · modref · struct · enum · union · opaque · fn · const · alias · field · tag`.

Emitted pre-order, depth-first, in Zig's own source order — never sorted, never grouped.
Because it's pre-order, **every subtree is a contiguous block** (that's what `../derived/index.tsv`
indexes). The tree carries no `n_children` column: a node's depth and parent are read straight
off its `path`, and the verifier reconciles the tree by that — every non-root path's parent is
itself a node.

### `attrs.tsv` — Attributes (a node's own facts)
`path · attr · value`. Sparse: a row exists only where the fact is present. **185,369 rows**
across nine attributes:

| attr | value | count |
|---|---|---|
| `loc` | source location `file:line` (root-relative, machine-independent) | 86,045 |
| `value` | a `field`'s default, or a `const`'s initializer as written (whitespace-collapsed, never shortened) | 44,093 |
| `when` | a variant's condition: its switch prong's values (`.linux, .emscripten`, `else`) or its `if` condition | 2,487 |
| `type` | the type as written on a `field`, or on a `const`/`var` declared `: T` (the `has_type` edge keeps only the name it references: `?*Node` → `Node`) | 20,911 |
| `doc` | the decl's `///` doc-comment, whitespace-collapsed; a file's namespace adds the file's own `//!` doc | 15,618 |
| `sig` | a `fn`'s as-written signature (`fn` keyword through return type, body excluded) | 12,421 |
| `example` | a `test {}` body verbatim (tabs/newlines escaped so it stays one row) | 1,927 |
| `mod` | a decl's qualifiers — `extern` (with its library: `extern "c"`)/`export`/`inline`/`noinline`/`threadlocal`/`comptime`/`var` (sparse; `var` distinguishes a mutable global from a `const`) | 1,376 |
| `errmember` | a member of a named `error{…}` set (one row per member) | 491 |

### `edges.tsv` — Edges (typed references, resolved)
`src · type · target · scope`. Every reference a declaration makes, **with its reach resolved**
in a second pass against the walked node set. **71,692 edges**, six types:

| type | count | what it links |
|---|---|---|
| `has_type` | 60,256 | a fn param/return, a field, or a `const`/`var` declared `: T` → the type it names (an array → its element) |
| `alias` | 5,536 | a re-export (`pub const X = Y.Z`) → what it points at |
| `error_set` | 4,086 | an `error{…}` / error-union → its members; `A || B` gives one edge per operand |
| `imports` | 1,025 | an `@import` alias → the file/module it names |
| `delegates` | 31 | a forwarding factory (`fn X() type { return Y(args); }`) → its target |
| `instantiates` | 758 | a `const` built by a call (`Sha256 = Sha2x32(…)`) → the fn it calls |

`scope` records **where the target landed** — the one invariant worth protecting is that a
`local`/`cross` edge always points at a real node:

| scope | count | meaning |
|---|---|---|
| `primitive` | 30,045 | a language builtin (`i32`, `usize`, `type`, …) |
| `local` | 18,579 | a node inside `src`'s own container (incl. `@This()`) |
| `cross` | 18,349 | a node elsewhere in the tree |
| `module` | 1,101 | outside the tree: an `@import` itself, or a path into a module that is not walked, kept whole (`builtin.os.tag`) |
| `unresolved` | 1,416 | couldn't place it (comptime-built, exotic) |
| `inline` | 913 | an inline `struct{…}`/`enum{…}` literal target |
| `generic` | 1,289 | a comptime type parameter in scope |

**68,262 of 71,692 edges (98% of the resolvable ones)** land on a
node, primitive, or generic param; 1,416 stay unresolved.

the backward check in `zephem std` proves the shapes reconcile: every non-root path's **parent is a node** (the tree
is connected), every **attr keys onto a real node**, and every **`local`/`cross` edge resolves to
a real node** — the links are valid.

### `builtins.tsv` — the builtins (`@intCast`, `@memcpy`, …)
`name · params · sig · doc · example`. Builtins are not std declarations, so the walk never
sees them, yet they change between releases as much as std does. `parse/langref.zig` reads two
witnesses that ship with the active toolchain: the compiler's own table
(`std/zig/BuiltinFn.zig`, which decides what **exists** and each builtin's arity, `var` when
variadic) and the language reference (`doc/langref.html`, for the signature, prose and first
example). 128 builtins: 124 documented, 19 with an example,
and 4 the compiler has but langref does not document (their `sig`/`doc` stay
empty; that absence is the fact).

**Self-check:** the extraction fails if langref documents a builtin the compiler lacks, or if a
documented signature's parameter count disagrees with the compiler's. The backward check re-reads
the file: every row `@`-named once, an arity, and each signature a call of its own builtin.

---

## From reflection (`reflect/`) — what the compiler resolves

`reflect/resolve.zig` reflects each container in its **own isolated subprocess**, so a
poison decl can't kill the sweep. This is the compiler's resolved view — real types,
expanded generics, evaluated const values — the one thing a pure parser cannot see.
These rows are **x86_64-linux-specific**: a decl gated to another target resolves as
poison here.

### `resolved.tsv` — resolved depth
`path · kind · detail`. Resolved const values, expanded generics, typed signatures.
On zig 0.17.0: **3,162 containers resolved and 18 partly resolved (21,527 rows).**

### `poison.tsv` — what didn't resolve
`path · reason`, each with the compiler's exact first error line (platform / foreign lib /
libc / `@compileError` / timeout). Two kinds of row: a **container** that fails as a whole
(15), and a **decl** of a `partial` container (893) — reflecting
evaluates every decl of a container in one compile, so one bad decl used to blank the rest;
the sweep now finds the decls that fail on their own and reflects the others. Each is an
honest "the compiler couldn't build this here", not a miss.

### `status.tsv` — the per-container ledger
`path · status · n_rows`. One row per container the sweep attempted, with one of five
statuses: `resolved` (3,162), `partial` (18 — some decls failed on their
own), `poison` (15), `private` (920 — reachable only through a private
decl, so not reflectable from outside its file: a fact about the path, not a failure) and
`skipped` (1,844 — no Zig expression reaches it: an uninstantiated `()` factory, a `[…]` variant, a private `@"f.zig"` file node; or a switch-built `const` that is a container only through its variants, reflected as a decl of its parent). The verifier re-derives the buckets
from this and reconciles them against `resolved`/`poison`.

Verified by the backward check in `zephem depth` (conservation, registration vs the map, no duplicates).
The reflect sweep compiles every container (about 61 s cold for the full sweep, the rescue included; docs/reproducibility.md), so its rebuild harness is
`zephem depth --check`, separate from `zephem std`'s `--check` (see `PLAN.md`).
