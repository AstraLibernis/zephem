# extracted/ — literal facts from Zig

Everything here is a **fact read straight out of Zig** — either from the source text
(the `parse/` engine) or from the compiler's own resolution (the `reflect/` engine).
zephem does not interpret, join, or reshape any of it. If a row here is wrong, Zig
said so; nothing in this folder is zephem's opinion.

The transforms that combine or reshape these files live one level over in
[`../derived/`](../derived/).

Pinned to **zig 0.16.0** (`../PINNED`); a target-specific subset (see `resolved`/`poison`
below) is x86_64-linux.

---

## From the parser (`parse/`) — source as text

Read with `std.zig.Ast`, so comptime is never evaluated: platform-gated and "poison"
decls are just harmless text, which is what lets the parser map **all** of std.

### `nodes.tsv` — the full std map (the headline dataset)
The whole `std` namespace tree. One row per public decl, struct/union **field**, enum
**tag**, or **type-factory member** (a member of the type a `fn(…) type` returns,
pathed under `<fn>()` — e.g. `std.ArrayList().append`; the `()` marks "instantiate
first"). **48,499 rows / 310 files / max depth 9.**
Columns: `path · depth · kind · name · n_children · detail`.
`kind ∈ ns · nsref · nserr · struct · enum · union · opaque · fn · const · alias · modref · field · tag`.

Self-verifying: `build_std.nu` runs a **forward** pass (parse) and a **backward** pass
(`verify_std.nu`, re-reading rows grouped by parent) that must agree. Core invariant:
the conservation law `Σ n_children == rows − 1`; the verifier also checks per-node
child counts, kind partition, and `nsref` integrity. Disagreement → non-zero exit.

### `sigs.tsv` — as-written signatures
`path · sig`. `sig` is a function's signature from the `fn` keyword through the return
type (body excluded), whitespace-collapsed. One row per public `fn` (incl. re-exports).
**6,163 signatures.**

### `docs.tsv` — `///` doc-comments
`path · doc`. The decl's doc-comment text, whitespace-collapsed. A row exists only for
documented decls (any kind). **11,610 docs.**

### `fields.tsv` — field types & tag values
`path · type · value`. The payload of every `field`/`tag` node: a struct/union field's
written type (and default), or an enum tag's value. 1:1 with the `field`/`tag` rows in
`nodes.tsv`. **31,048 fields/tags.**

### `delegates.tsv` — factory forwarding
`path · target`. A *delegating* factory (`fn X(…) type { return Y(args); }`) and the raw
call it forwards to, so a factory we don't descend isn't a dead end. The target is
source text, **unresolved** (resolving it to a path is a derived-layer job).
**32 delegators** (e.g. `std.ArrayList → array_list.Aligned(T, null)`).

### `examples.tsv` — usage from tests & doctests
`path · kind · name · code`. Every `test` declaration in std, as a real, compilable usage
example. `kind = doctest` for a `test <identifier>` — bound by name to the decl it documents,
so `path` joins straight onto that node (`test parseInt` in `fmt.zig` → `std.fmt.parseInt`);
`kind = test` for a `test "…"` / anonymous test, whose `path` is the enclosing namespace.
`code` is the whole `test … {}` source with tabs/newlines escaped (`\t`/`\n`) so a multi-line
snippet stays on one row. On zig 0.16.0: **1,284 examples** (411 doctests bound
to a decl). A doctest may name a *private* decl, so its `path` won't always be in the pub map —
but its parent namespace always is.

`verify_std.nu` proves these overlays *register* on the map: every `sigs`/`docs` path is
a real node, paths are unique, the signature set equals the map's function set, and every
example anchors to the map (its owner or the owner's parent is a real node).

---

## From reflection (`reflect/`) — what the compiler resolves

`reflect/resolve.zig` reflects each container in its **own isolated subprocess**, so a
poison decl can't kill the sweep. This is the compiler's resolved view — real types,
expanded generics, evaluated const values — the one thing a pure parser cannot see.
These rows are **x86_64-linux-specific**: a decl gated to another target resolves as
poison here.

### `resolved.tsv` — resolved depth
`path · kind · detail`. Resolved const values, expanded generics, typed signatures.
On zig 0.16.0: **1,324 containers resolved (15,720 rows).**

### `poison.tsv` — what didn't resolve
`path · reason`. Decls that failed to resolve, each with the compiler's exact reason
(platform / foreign lib / `@compileError` / timeout). **31 genuine poison.**

### `status.tsv` — the per-container ledger
`path · status · n_rows`. One row per container the sweep attempted; the verifier
re-derives the buckets from this and reconciles them against `resolved`/`poison`.

Verified by `verify_depth.nu` (conservation, registration vs the map, no duplicates).
The reflect sweep's wall time is machine-dependent (≈1 min on a 16-lane desktop,
≈13 min on a 3-core VM), so its rebuild harness is a separate task from `build_std`'s
`--check` (see `PLAN.md`).
