# derived/ — computed from the extracted data

Everything here is **produced by zephem** from the literal facts in
[`../extracted/`](../extracted/) — joins, comparisons, and reshapes. The rule is
strict: **derive never invents a fact.** Every row here traces back to one or more
`extracted/` rows, and each derivative is self-checking against its inputs. Delete this
whole folder and it rebuilds from `extracted/` alone.

Pinned to **@@ZIG@@** (`../PINNED`).

---

### `index.tsv` — the table of contents (where to look)
Built by `derive/index.zig` from `extracted/nodes.tsv`. One row per container, recording
where its block lives in the map. Columns: `path · line · span · depth · kind · n_children`.
Because `nodes.tsv` is pre-order DFS, every subtree is a *contiguous* run of rows — so
`line` (1-based, header-aware) + `span` (subtree size) pin the exact block, letting a
consumer read one module in a single ranged read instead of scanning @@N_NODES_RAW@@ rows.
**@@N_INDEX@@ containers.**

```sh
zephem map show std.crypto.aead   # exactly that subtree, via the table of contents
```

Self-checked both ways: `index.zig` asserts root span == total rows and every span ==
1 + Σ child spans before writing; the backward check in `zephem std` re-derives each block's boundary from
`nodes.tsv` depths and confirms `line`+`span` land on each subtree.

### `consensus.tsv` — the read-vs-run census
`path · origin · owner`, from `zephem overlays` over `nodes.tsv` (text view) and
`resolved.tsv` (reflected view). Rather than force the two to match 1:1 and call every
non-match a miss, it **compares** them and tags every path by which witness sees it:
`read+run` (both agree — @@CON_RR@@), `run-only` (only when reflected, e.g. a generic
member like `Sha256.digest_length` — @@CON_RUNONLY@@), `read-only` (text read it but it
can't run here: poison, or the `std` root — @@CON_READONLY@@). One row per path in
`nodes ∪ resolved` (@@N_CONSENSUS@@), **zero blanks**. Verified by `zephem overlays --check`.

### `canon.tsv` — dedup / dealias families
`path · canon`, from `zephem overlays` over `resolved.tsv` alone. The compiler resolves
every type to a canonical `@typeName`, so two paths that name the *same* underlying type
collide on it. This surfaces exactly those collisions — **@@N_CANON@@ paths in
@@CANON_FAMILIES@@ families** (each `canon` shared by ≥ 2 paths). Verified by
`zephem overlays --check` (every family complete and backed by `resolved.tsv`).

### `doccov.tsv` — documentation coverage
`path · kind · documented`, from `zephem overlays` over `nodes.tsv` (every node) joined
against the `doc` attributes (`attrs.tsv` where `attr == doc` — which paths carry a `///`
doc). 1:1 with the whole map. On @@ZIG@@: **@@DOC_PCT@@% documented** (@@DOC_DOCUMENTED@@
nodes). Verified by `zephem overlays --check`.

### `sigshape.tsv` — signature shapes
`path · first_param · io · generic`, from `zephem overlays` over the `sig` attributes
(`attrs.tsv` where `attr == sig`). Classes each signature by first-param kind
(`self`/`none`/`allocator`/`other`), whether it threads `Io`, and whether it's generic
(`comptime`/`anytype`). **@@N_SIGSHAPE@@ fns**, every field a closed set. Verified by
`zephem overlays --check`.

### `callcard.tsv` — as-written ⋈ resolved
`path · witness · sig · resolved`, from `zephem overlays` — the merge of the `sig`
attributes (as-written) and `resolved.tsv` (typed) on a normalized path. One row per
callable (@@N_CALLCARD@@): `both` (@@CC_BOTH@@ — the resolved column fills in real types
where the source said `@This()`/`Self`), `reflect-only` (@@CC_REFLECT@@), `parser-only`
(@@CC_PARSER@@ — a private or uninstantiated-factory fn the compiler couldn't build here,
no resolved type). Verified by `zephem overlays --check`.

---

All six are deterministic (same `extracted/` → byte-identical) with a `--check` mode
that rebuilds and compares against a committed `SHA256SUMS.<slice>` sidecar. See
[`../../README.md`](../../README.md) for the kind-policy table (who owns what, and which
derivative counts each kind).
