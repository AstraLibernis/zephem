# derived/ — computed from the extracted data

Everything here is **produced by zephem** from the literal facts in
[`../extracted/`](../extracted/) — joins, comparisons, and reshapes. The rule is
strict: **derive never invents a fact.** Every row here traces back to one or more
`extracted/` rows, and each derivative is self-checking against its inputs. Delete this
whole folder and it rebuilds from `extracted/` alone.

Pinned to **zig 0.16.0** (`../PINNED`).

---

### `index.tsv` — the table of contents (where to look)
Built by `derive/index.zig` from `extracted/nodes.tsv`. One row per container, recording
where its block lives in the map. Columns: `path · line · span · depth · kind · n_children`.
Because `nodes.tsv` is pre-order DFS, every subtree is a *contiguous* run of rows — so
`line` (1-based, header-aware) + `span` (subtree size) pin the exact block, letting a
consumer read one module in a single ranged read instead of scanning 48499 rows.
**2,966 containers.**

```nu
let b = (open data/std/derived/index.tsv | where path == 'std.crypto.aead' | first)
open data/std/extracted/nodes.tsv | skip ($b.line - 2) | first $b.span   # exactly that subtree
```

Self-checked both ways: `index.zig` asserts root span == total rows and every span ==
1 + Σ child spans before writing; `verify_std.nu` re-derives each block's boundary from
`nodes.tsv` depths and confirms `line`+`span` land on each subtree.

### `consensus.tsv` — the read-vs-run census
`path · origin · owner`, from `build_consensus.nu` over `nodes.tsv` (text view) and
`resolved.tsv` (reflected view). Rather than force the two to match 1:1 and call every
non-match a miss, it **compares** them and tags every path by which witness sees it:
`read+run` (both agree — 13,424), `run-only` (only when reflected, e.g. a generic
member like `Sha256.digest_length` — 2,296), `read-only` (text read it but it
can't run here: poison, or the `std` root — 3,082). One row per path in
`nodes ∪ resolved` (18,802), **zero blanks**. Verified by `verify_consensus.nu`.

### `canon.tsv` — dedup / dealias families
`path · canon`, from `build_canon.nu` over `resolved.tsv` alone. The compiler resolves
every type to a canonical `@typeName`, so two paths that name the *same* underlying type
collide on it. This surfaces exactly those collisions — **236 paths in
100 families** (each `canon` shared by ≥ 2 paths). Verified by
`verify_canon.nu` (every family complete and backed by `resolved.tsv`).

### `doccov.tsv` — documentation coverage
`path · kind · documented`, from `build_doccov.nu` over `nodes.tsv` (every node) joined
against `docs.tsv` (which paths carry a `///` doc). 1:1 with the whole map. On zig 0.16.0:
**24% documented** (11,610 nodes). Verified by `verify_doccov.nu`.

### `sigshape.tsv` — signature shapes
`path · first_param · io · generic`, from `build_sigshape.nu` over `sigs.tsv` alone.
Classes each signature by first-param kind (`self`/`none`/`allocator`/`other`), whether
it threads `Io`, and whether it's generic (`comptime`/`anytype`). **6,163 fns**,
every field a closed set. Verified by `verify_sigshape.nu`.

### `callcard.tsv` — as-written ⋈ resolved
`path · witness · sig · resolved`, from `build_callcard.nu` — the merge of `sigs.tsv`
(as-written) and `resolved.tsv` (typed) on a normalized path. One row per callable
(7,885): `both` (4,823 — the resolved column fills in real types where the
source said `@This()`/`Self`), `reflect-only` (1,722), `parser-only`
(1,340 — e.g. an uninstantiated factory member, no resolved type yet). Verified
by `verify_callcard.nu`.

---

All six are deterministic (same `extracted/` → byte-identical) with a `--check` mode
that rebuilds and compares against a committed `SHA256SUMS.<slice>` sidecar. See
[`../README.md`](../README.md) for the kind-policy table (who owns what, and which
derivative counts each kind).
