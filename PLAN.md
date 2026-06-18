# zephem — Plan

**What this is.** A data-extraction, transformation, and verification tool that, pointed at a
Zig source root, emits pristine, queryable **datasets** of **true, direct knowledge** about
it — starting with the namespace tree (where everything is, how it's shaped) and layering on
progressively deeper facts (signatures, the authors' own doc-comments, references, runnable
examples, resolved sizes, version diffs). The product is the datasets *and the pipeline that
regenerates and self-checks them*, never prose.

The intended consumers are LLMs (tidy tables that parse cleanly into context, so the model
works from extracted fact instead of recollection) and humans using the data as a research
aid. Every fact is something the compiler or source states or computes — nothing authored.

**Ephemeral by design.** Datasets are derived, regenerable artifacts — never hand-authored.
Any committed dataset is a *pinned snapshot* of one Zig version, a cache of compiler/source
truth, not a canonical hand-maintained source. This is why **reproducibility is a co-equal
goal, not a nicety**: a snapshot you cannot provably rebuild is just hand-authored data with
extra steps. The product is as much *the act of regenerating identically* as the bytes
themselves.

**Two guarantees, both proven, both orthogonal.** Gathering the data is only half the job:

- **True** — every fact is extracted/computed, and the data checks itself (conservation,
  referential integrity, executing examples). *Is what it says correct?*
- **Reproducible** — the same Zig version rebuilds the byte-identical snapshot, every time,
  without breaking. *Will building it again give the same thing?*

Data can be internally consistent yet nondeterministic, or deterministic yet wrong. zephem
asserts **both**, mechanically, on every run — see *Reproducibility* below.

**What it is not.** Not a guide, tutorial, or domain advice. **No hand-authored prose.** Any
human-readable view, if ever wanted, is generated from the data — never written by hand.

---

## The method: parse, don't reflect

The general extractor reads source with `std.zig.Ast` instead of walking `@typeInfo`.
Parsing never triggers comptime, so platform-gated and "poison" decls (e.g. `std.c.darwin`'s
`assert(isDarwin())`) are harmless text. **This is the decision that makes mapping all of std
possible** — a reflection walk dies on the first un-evaluatable decl. Reflection still earns
its keep for the few facts source text can't give (resolved sizes, expanded generics) — but
only **on demand, scoped to one module** the map points us at, never as a blanket walk. See
the *depth* layer in the roadmap.

---

## The headline product: the full std map

`nu scripts/build_std.nu` → `data/std/nodes.tsv`, one row per public decl:

```
path · depth · kind · name · n_children · detail
```

- `kind ∈ ns` (an `@import`'d file, expanded) · `nsref` (reference to a file already
  expanded elsewhere — keeps shared imports like `std` from recursing forever) · `nserr`
  (unreadable file) · `struct`/`enum`/`union`/`opaque` (inline container) · `fn` · `const` ·
  `alias` (re-export) · `modref` (module import, not a file we own).
- `n_children` = public decls a container emits as direct children (0 for leaves / nsref /
  nserr). This is what makes the data self-verifying.
- `detail` = std-relative file path (ns/nsref) · param count (fn) · module name (modref).

On Zig 0.16.0: **16,631 decls / 442 files / max depth 9.** Version pinned in `data/std/PINNED`.

### Self-verifying: read it forwards, read it backwards

`build_std.nu` bundles two passes that must agree, or it exits non-zero and claims nothing:

- **forward** — `src/scan.zig` parses source → emits rows.
- **backward** — `scripts/verify_std.nu` re-reads the rows grouped by parent path.

Checks (no external tool, no oracle — the data checks itself):

| check | invariant |
|---|---|
| **conservation** | `Σ n_children == rows − 1` (every non-root node is one node's child) |
| **per-node** | for each expanded container, observed children == recorded `n_children` |
| **partition** | `Σ rows-per-kind == total rows` (no unclassified leftovers) |
| **nsref integrity** | every `nsref.detail` file is an expanded `ns.detail` somewhere |

A dropped, double-counted, or truncated decl breaks conservation *and* per-node. This is the
"triangulation from inside the data" the project wanted instead of an external cross-check.

### Reading it efficiently: `data/std/index.tsv`

`nodes.tsv` is ~221k tokens — too big to read whole for a narrow question. But pre-order DFS
makes every subtree a **contiguous block**, so `src/index.zig` emits a tiny table of contents
(`path · line · span · depth · kind · n_children`, 1,495 containers). Look up a module, read
exactly its `[line, line+span)` rows — pure arithmetic, no scan. The index self-checks (root
span == total rows; span == 1 + Σ child spans) and `verify_std.nu` re-derives every block's
boundary from `nodes.tsv` depths so the map can never drift from the data.

---

## The pristine bar

Every shipped dataset must clear both guarantees:

**True**
- **Complete or explicitly scoped** — coverage is total, or every exclusion is recorded. No
  silent gaps.
- **Self-verifying** — automated checks built into regeneration (the conservation bundle +
  the index re-derivation above; each new layer adds its own backward check).

**Reproducible**
- **Deterministic** — same Zig version → byte-identical output, with every source of
  run-to-run variance designed out (see below).
- **Idempotent & checked** — regeneration is *proven* identical, not assumed.
- **Robust / non-breaking** — a regeneration never crashes; new inputs (a Zig upgrade) yield
  a valid snapshot with additive, diffable changes.
- **Pinned** — tagged to the exact Zig version the data was extracted from.

---

## Reproducibility — provably rebuildable

"Build it again, prove you got the same thing." This is enforced machinery, not an aspiration.

**Determinism contract — the variance we design out.** Output is reproducible only because
every non-deterministic input is eliminated by construction:

| source of churn | how it's killed |
|---|---|
| hashmap / dir iteration order | rows emitted in **source order** (pre-order DFS), never map order |
| absolute toolchain paths | paths rendered **relative to the module root** (`relPath`) |
| timestamps / PIDs / RNG | none ever written into a dataset |
| anonymous comptime IDs (`__struct_NNNNN`) | N/A — we parse, we don't reflect (this churn killed the old crypto pipeline) |

**Idempotency guard — the proof.** A `--check` mode regenerates and asserts the result is
**byte-identical**, two independent ways:
1. *Intrinsic* — build twice in one run, compare hashes. Proves the **process** is
   deterministic, needs no baseline.
2. *Regression* — compare against the committed snapshot (recorded `SHA256SUMS` /
   `git diff --exit-code`). Proves today's code + Zig still reproduces the **recorded** truth.

A drift in either fails the build loudly. This generalizes across *all* layers as they land —
one reproducibility harness regenerates every dataset and asserts no drift, so "provably build
over and over" holds for the whole corpus, not just the map.

**Robust regeneration.** Parsing-not-reflection means no input kills the run: an unreadable
file becomes an `nserr` row, a moved file a different path — the snapshot is always *valid*,
and a Zig upgrade produces an additive, diffable delta (which L6 version-diff then renders).

---

## Status — Part 1 (structure) is done

| piece | status |
|---|---|
| **std map** (`scan.zig` + bundle) | ✅ full std mapped, self-verifying, deterministic, pinned |
| **table of contents** (`index.zig`) | ✅ contiguous-block index, self-checked both ways |
| crypto reflection pipeline | 🗄️ archived → `archive/crypto-reflection/` (the on-demand depth layer revives its technique) |

We can now say *where* anything in std is and *how it is shaped*, completely and provably.
That is the skeleton. Everything below adds flesh to it — deeper true facts, one layer at a
time, each held to the same pristine bar.

---

## The principle: true / direct knowledge, in layers

zephem only ships facts that are **extracted or computed** from the compiler's source or the
compiler itself — never authored, inferred, or interpreted. The map proved the model; the
roadmap is the same model applied to progressively deeper facts. Think of it as layers, each
a separate dataset keyed to the map by `path`:

| layer | the question it answers | source of truth | coverage |
|---|---|---|---|
| **L0 structure** ✅ | where is it, how is it shaped | parse (AST) | total |
| **L1 signatures-as-written** | what does this fn take / return / error | parse (AST) | total |
| **L2 doc-comments** | what do std's authors say it is | parse (`///`) | total |
| **L3 references / tunnels** | what links to what (followable to an address) | parse (resolve names) | edges |
| **L4 examples (tests)** | how is it actually used, *and does it run* | parse + **execute** | where tests exist |
| **L5 resolved depth** | the real size / expanded generic / concrete type | reflect, on demand | targeted |
| **L6 version diff** | what changed between Zig versions | transform two snapshots | total |

Two hard rules keep every layer honest:
1. **Keyed to the map.** Every row in every layer references a `path` that exists in
   `nodes.tsv` — so layers compose, and a dangling key is a caught error (referential
   integrity is just conservation again).
2. **Self-verifying.** No layer ships without a backward check (count reconciliation,
   referential integrity, reversibility, or — best of all — *executing* the fact).

### The shape of it: positions, overlays, tunnels

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
`alias` (→ a canonical definition) — plus, once L1 lands, every type name in a signature
(→ its definition). Resolving those targets is what makes them traversable.

**A tunnel is usually shorter than the tree route.** Tree distance is "climb to the common
ancestor, descend the far side" — many hops; a resolved edge is one. Std is *built* from these
shortcuts: the root re-exports deep definitions under short names (`std.ArrayList` → wherever
it really lives), which our `alias` kind already captures. Resolving them makes std's own
shortcut wiring explicit and followable — effectively "go to definition" as a data lookup.

Link types to record (all `from_path → to_path`, both endpoints in the map, so it
self-verifies the same way): **alias tunnel** (re-export), **import tunnel** (nsref/modref),
**usage edge** (a type/fn referenced in a signature or body).

---

## Roadmap (extraction · transformation · verification)

Ordered by value-per-effort; each is an independent dataset, none blocks another — except the
foundational item below, which every layer plugs into.

**Build the overlays first, link them last.** The attribute layers (L1/L2, and L5 on demand)
fill positions and can land in any order. Linking (L3) comes *after*, because a tunnel weaves
*between* layers — a usage edge runs from a type name living in the L1 signature layer to a
definition in the map, so the things a tunnel connects must already exist before it can be
resolved and verified. Lay the planes, then drill the wormholes.

### 0 — Reproducibility harness (foundational, buildable now) · verification
Make "provably rebuildable" a checked invariant. Add a `--check` mode to the build that
(a) regenerates and compares byte-for-byte against a second run (intrinsic idempotency) and
(b) compares against a committed `SHA256SUMS` manifest (regression). Wire it so every present
and future dataset registers with one harness — `verify` then proves *true* and *reproducible*
in a single pass. **Verify:** the check is its own proof; a non-zero exit on any drift.
*Why:* without this, idempotency is a claim we re-test by hand each time — exactly the manual
step the project exists to remove. This is the second half of the mission, not a chore.

### 1 — Depth, on demand (L5) · extraction
A `resolve <path>` step that reflects **one module** the map points at, emitting resolved
const values (the real `key_length = 32`), expanded aliases/generics, and fully-typed
signatures with error sets. Scoping to a single module sidesteps the poison-decl death that
killed blanket reflection. **Verify:** every leaf in the subtree is either resolved or
explicitly recorded unresolvable — the two counts must reconcile with the map's subtree.
*Why:* stops the LLM hallucinating sizes/types once it has drilled to a specific primitive.

### 2 — Doc-comments (L2) · extraction
Extract `///` comments per decl into a companion dataset keyed by `path`. This is the std
authors' own documentation — direct truth, not our prose, fully within charter. **Verify:**
every doc block attaches to exactly one existing node; doc'd-decl count is stable. *Why:*
cheap, total, and enormously useful — the official "what is this" inline with the map.

### 3 — Signatures-as-written (L1) · extraction
Upgrade `fn` rows from a bare param count to the as-written signature (param names + types,
return type, error union) straight from the AST — no reflection. **Verify:** the parsed
param count must equal the existing `n` already in the map (cross-check against L0). *Why:*
answers most signature questions without paying for reflection; L5 only for the resolved form.

### 4 — Examples from tests (L4) · extraction + verification
Extract `test "..." {}` blocks and which decls they exercise. **Verify (the strong one):**
run `zig test` and record pass/fail — the knowledge doesn't just *claim*, it *executes green*.
*Why:* real, compiling, passing usage is the highest-grade knowledge an LLM can be handed.

### 5 — Reference graph / tunnels (L3) · extraction → transformation
The linking layer (see *positions, overlays, tunnels* above). Resolve referenced names —
identifiers, import targets, alias targets, the type names L1 surfaces — to canonical `path`s,
and emit edges `from_path → to_path` tagged by kind (**alias** / **import** / **usage**).
Each resolved edge also carries the destination's `line` (via the index), so following it is
one O(1) jump, not a search — a real tunnel, usually far shorter than the tree route. Build
this *after* the overlays exist, since a usage edge connects a type in the signature layer to
a definition in the map. **Verify:** every edge endpoint is a node in `nodes.tsv` (no dangling
— same registration proof as the overlays); names that cannot be resolved are recorded
explicitly, never silently dropped; edge count stable. *Why:* turns the layer-stack into a
navigable graph — "go to definition," "what uses X," "what does Y pull in" — that the
containment tree alone cannot express.

### 6 — Version diff (L6) · transformation
Diff two pinned snapshots → added / removed / changed decls: a true changelog, computed not
guessed. **Verify:** the diff is invertible — applying it to the old snapshot reproduces the
new one exactly. *Why:* migration help grounded in fact; the real payoff of ephemeral-by-design.

### Standing items
- [ ] Point the scanner at non-std roots (already root-agnostic — needs a target list).
- [ ] Decide: keep snapshots git-tracked, or gitignore them with regeneration as the contract.

---

## Superseded

Began as `zcrypto`: first an explanatory guide, then a faithful map of hand-written
per-family docs, then "the datasets are the product." Renamed to **zephem** and reframed on
2026-06-17 — from *learning crypto* to *a general Zig structure-extraction tool*. The pivot
to **AST parsing** (over reflection) followed, making the full-std map the headline product;
the original crypto reflection pipeline was archived to `archive/crypto-reflection/`. Retired
markdown lives in `docs/archive/` (provenance, per archive-don't-delete).

## Toolchain
Zig (AST parsing) + Nushell (glue / query) only. Every dataset under `data/` is regenerable
and idempotent.
