<!-- GENERATED from templates/extracted.tmpl.md by `zephem docs` — edit the template, not this file. -->
# extracted/ — literal facts from Zig

Everything here is a **fact read straight out of Zig** — either from the source text
(the `parse/` engine) or from the compiler's own resolution (the `reflect/` engine).
zephem does not interpret, join, or reshape any of it. If a row here is wrong, Zig
said so; nothing in this folder is zephem's opinion.

The transforms that combine or reshape these files live one level over in
[`../derived/`](../derived/).

Pinned to **zig 0.16.0** (`../PINNED`); a target-specific subset (see `resolved`/`poison`
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
the `()` marks "instantiate first"). **63,494 rows** (56,088 pub / 7,406 priv)
across **340 files**, max depth **8**.
Columns: `path · kind · name · vis`  (`vis ∈ pub · priv`).
`kind ∈ ns · nsref · nserr · modref · struct · enum · union · opaque · fn · const · alias · field · tag`.

Emitted pre-order, depth-first, in Zig's own source order — never sorted, never grouped.
Because it's pre-order, **every subtree is a contiguous block** (that's what `../derived/index.tsv`
indexes). The tree carries no `n_children` column: a node's depth and parent are read straight
off its `path`, and the verifier reconciles the tree by that — every non-root path's parent is
itself a node.

### `attrs.tsv` — Attributes (a node's own facts)
`path · attr · value`. Sparse: a row exists only where the fact is present. **111,480 rows**
across seven attributes:

| attr | value | count |
|---|---|---|
| `loc` | source location `file:line` (root-relative, machine-independent) | 63,493 |
| `value` | a `field`/`tag`'s written type & default, or a `const`'s literal | 19,809 |
| `doc` | the decl's `///` doc-comment, whitespace-collapsed | 13,721 |
| `sig` | a `fn`'s as-written signature (`fn` keyword through return type, body excluded) | 11,273 |
| `example` | a `test {}` body verbatim (tabs/newlines escaped so it stays one row) | 1,433 |
| `mod` | a decl's qualifiers — `extern`/`export`/`inline`/`noinline`/`threadlocal`/`comptime`/`var` (sparse; `var` distinguishes a mutable global from a `const`) | 1,257 |
| `errmember` | a member of a named `error{…}` set (one row per member) | 494 |

### `edges.tsv` — Edges (typed references, resolved)
`src · type · target · scope`. Every reference a declaration makes, **with its reach resolved**
in a second pass against the walked node set. **54,666 edges**, five types:

| type | count | what it links |
|---|---|---|
| `has_type` | 47,983 | a fn param/return or field → the type it names |
| `alias` | 2,942 | a re-export (`pub const X = Y.Z`) → what it points at |
| `error_set` | 2,876 | an `error{…}` / error-union → its members |
| `imports` | 828 | an `@import` alias → the file/module it names |
| `delegates` | 37 | a forwarding factory (`fn X() type { return Y(args); }`) → its target |

`scope` records **where the target landed** — the one invariant worth protecting is that a
`local`/`cross` edge always points at a real node:

| scope | count | meaning |
|---|---|---|
| `primitive` | 21,486 | a language builtin (`i32`, `usize`, `type`, …) |
| `local` | 16,538 | a node inside `src`'s own container (incl. `@This()`) |
| `cross` | 9,497 | a node elsewhere in the tree |
| `module` | 4,013 | an `@import` alias / a file or module boundary |
| `unresolved` | 2,020 | couldn't place it (comptime-built, exotic) |
| `inline` | 539 | an inline `struct{…}`/`enum{…}` literal target |
| `generic` | 573 | a comptime type parameter in scope |

**48,094 of 54,666 edges (96% of the resolvable ones)** land on a
node, primitive, or generic param; 2,020 stay unresolved.

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
On zig 0.16.0: **2,912 containers resolved (15,796 rows).**

### `poison.tsv` — what didn't resolve
`path · reason`. Decls that failed to resolve, each with the compiler's exact reason
(platform / foreign lib / `@compileError` / timeout). **923 genuine poison.**
The tree now includes private decls (many platform/foreign-lib) and uninstantiated `()`
factory containers, so poison is higher than the pub-only parser's was — each is an honest
"the compiler couldn't build this here", not a miss.

### `status.tsv` — the per-container ledger
`path · status · n_rows`. One row per container the sweep attempted; the verifier
re-derives the buckets from this and reconciles them against `resolved`/`poison`.

Verified by the backward check in `zephem depth` (conservation, registration vs the map, no duplicates).
The reflect sweep compiles every container (about 16.5 s ± 0.1 s cold for the full sweep on a Ryzen 7 9800X3D (16 threads; hyperfine, 10 runs, compiler cache wiped before each)), so its rebuild harness is
`zephem depth --check`, separate from `zephem std`'s `--check` (see `PLAN.md`).
