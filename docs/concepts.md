# zephem — Concepts

The shared model behind every layer. Read this once; the per-layer docs assume it.
Index: [PLAN.md](../PLAN.md).

---

## The method: parse, don't reflect

The general extractor reads source with `std.zig.Ast` instead of walking `@typeInfo`.
Parsing never triggers comptime, so platform-gated and "poison" decls (e.g. `std.c.darwin`'s
`assert(isDarwin())`) are harmless text. **This is the decision that makes mapping all of std
possible** — a reflection walk dies on the first un-evaluatable decl. Reflection still earns
its keep for the few facts source text can't give (resolved sizes, expanded generics) — and
because each container is reflected **in its own isolated subprocess**, a poison decl kills
only its own process, so we sweep *every* container in the map, not a hand-picked few. The
isolation unit is one container, which doubles as "depth on demand" for a single `--only`
target — but the shipped L5 overlay is the full-corpus sweep. See [L5](layers/L5-depth.md).

---

## The pristine bar

Every shipped dataset must clear both guarantees:

**True**
- **Complete or explicitly scoped** — coverage is total, or every exclusion is recorded. No
  silent gaps.
- **Self-verifying** — automated checks built into regeneration (the conservation bundle +
  the index re-derivation; each new layer adds its own backward check).

**Reproducible**
- **Deterministic** — same Zig version → byte-identical output, with every source of
  run-to-run variance designed out (see [reproducibility.md](reproducibility.md)).
- **Idempotent & checked** — regeneration is *proven* identical, not assumed.
- **Robust / non-breaking** — a regeneration never crashes; new inputs (a Zig upgrade) yield
  a valid snapshot with additive, diffable changes.
- **Pinned** — tagged to the exact Zig version the data was extracted from.

---

## The principle: true / direct knowledge, in layers

zephem only ships facts that are **extracted or computed** from the compiler's source or the
compiler itself — never authored, inferred, or interpreted. The map proved the model; the
rest is the same model applied to progressively deeper facts. Think of it as layers, each
a separate dataset keyed to the map by `path`:

| layer | the question it answers | source of truth | coverage | doc |
|---|---|---|---|---|
| **L0 structure** ✅ | where is it, how is it shaped | parse (AST) | total | [L0](layers/L0-structure.md) |
| **L1 signatures-as-written** ✅ | what does this fn take / return / error | parse (AST) | total | [L1-L2](layers/L1-L2-decls.md) |
| **L2 doc-comments** ✅ | what do std's authors say it is | parse (`///`) | total | [L1-L2](layers/L1-L2-decls.md) |
| **L3 references / tunnels** ✅ | what links to what (followable to an address) | parse (resolve names) | edges | [L3](layers/L3-tunnels.md) |
| **L4 examples (tests)** ▢ | how is it actually used, *and does it run* | parse + **execute** | where tests exist | [L4](layers/L4-examples.md) |
| **L5 resolved depth** ✅ | the real size / expanded generic / concrete type | reflect (per-container, isolated) | full sweep | [L5](layers/L5-depth.md) |
| **L6 version diff** ▢ | what changed between Zig versions | transform two snapshots | total | [L6](layers/L6-version-diff.md) |

Two hard rules keep every layer honest:
1. **Keyed to the map.** Every row in every layer references a `path` that exists in
   `nodes.tsv` — so layers compose, and a dangling key is a caught error (referential
   integrity is just conservation again).
2. **Self-verifying.** No layer ships without a backward check (count reconciliation,
   referential integrity, reversibility, or — best of all — *executing* the fact).

**Build the overlays first, link them last.** The attribute layers (L1/L2, L5) fill positions
and can land in any order. Linking (L3) comes *after*, because a tunnel weaves *between* layers
— a usage edge runs from a type name living in the L1 signature layer to a definition in the
map, so the things a tunnel connects must already exist before it can be resolved and verified.
Lay the planes, then drill the wormholes.

---

## The shape of it: positions, overlays, tunnels

The layers aren't a flat stack — they form a navigable structure with three kinds of geometry:

- **Positions (the x/y).** The containment tree. Every decl has a coordinate (`path`), and the
  index turns that into a literal address (`line`, `span`). This is the ground plane.
- **Overlays (the stack at a position).** L1 / L2 / L5 attach more facts *at the same
  coordinate* — read "straight down" through them (a join on `path`) to get everything known
  about one decl. Overlays are **sparse**: signatures only at functions, docs only where a
  `///` exists. Perfectly registered, partially filled — the *holes* are themselves useful
  (the gaps in the doc overlay = every undocumented public decl).
- **Tunnels (the Z-links across positions).** L3. Not data *at* a position — *links between*
  them. They are the connective tissue that turns the overlay-stack into a graph.

**Tunnels resolve to addresses, not just names.** A reference is only a tunnel if you can
*follow* it: each link resolves a referenced name to a canonical `path`, and through the index
to a `line` — so traversing it is one O(1) jump, no scan. We already emit embryonic tunnels
the map leaves dangling — `nsref` (→ a file expanded elsewhere), `modref` (→ a module),
`alias` (→ a canonical definition) — plus every type name in an L1 signature (→ its
definition). Resolving those targets is what makes them traversable.

**A tunnel is usually shorter than the tree route.** Tree distance is "climb to the common
ancestor, descend the far side" — many hops; a resolved edge is one. Std is *built* from these
shortcuts: the root re-exports deep definitions under short names (`std.ArrayList` → wherever
it really lives), which our `alias` kind already captures. Resolving them makes std's own
shortcut wiring explicit and followable — effectively "go to definition" as a data lookup.

---

## Toolchain

Zig (AST parsing) + Nushell (glue / query) only. Every dataset under `data/` is regenerable
and idempotent.

---

## Superseded — how zephem got here

Began as `zcrypto`: first an explanatory guide, then a faithful map of hand-written
per-family docs, then "the datasets are the product." Renamed to **zephem** and reframed on
2026-06-17 — from *learning crypto* to *a general Zig structure-extraction tool*. The pivot
to **AST parsing** (over reflection) followed, making the full-std map the headline product;
the original crypto reflection pipeline was archived to `archive/crypto-reflection/` (its
technique revived, scoped, as L5). Retired markdown lives in `docs/archive/` (provenance, per
archive-don't-delete).
