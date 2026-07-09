<!-- GENERATED from templates/plan.tmpl.md by scripts/build_arch.nu — edit the template, not this file. -->
# zephem — Plan

**What it is.** A tool that, pointed at a Zig source root, emits pristine, queryable
**datasets** of true, direct knowledge about it — starting with the namespace tree (where
everything is, how it's shaped) and layering on deeper facts (signatures, doc-comments,
references, resolved sizes). The product is the datasets *and the pipeline that regenerates
and self-checks them*, never prose. Intended consumers: LLMs (clean tables that parse into
context) and humans using the data as a research aid. Every fact is something the compiler
or source states or computes — nothing authored.

**Two guarantees, both proven, both orthogonal.**
- **True** — every fact is extracted/computed, and the data checks itself (conservation,
  referential integrity). *Is what it says correct?*
- **Reproducible** — the same Zig version rebuilds the byte-identical snapshot, every time.
  *Will building it again give the same thing?*

**The base map is a literal, source-order mirror of Zig** — no sorting, no clustering, no
invented links. That faithfulness is the contract; see [`parse/README.md`](parse/README.md).
Anything we *make up* (purpose groupings, semantic links) is a separate, optional overlay,
never folded into the base.

---

## Direction — how we got here

1. **zcrypto** (retired) — began pointed only at `std.crypto`, via **reflection**, to learn
   crypto. A reflection walk dies on the first platform-gated decl, so it couldn't generalize.
   Whole pipeline retired & deleted (provenance: `docs/archive/README.md`).
2. **zephem** (2026-06-17) — reframed as a general extractor built on **AST parsing**
   (parse-don't-reflect): it reads source as syntax, never evaluates comptime, so it maps
   **all** of std including poison decls. The tool is the extractor, not the crypto.
3. **engine split** (2026-06-21) — split by *what each reads* into three engines: **`parse/`**
   (read source as text), **`reflect/`** (run the compiler → resolved depth), **`derive/`**
   (transform the datasets, read no Zig → index, canon). Docs cut to three (this file,
   `README.md`, `parse/README.md`); the rest retired to the archive tombstone `docs/archive/README.md`.
4. **parser stripped to one file** (2026-06-21) — the parser emitted *only* the structural
   map (`nodes.tsv`); signatures/docs and references were pulled out as "organize later" layers.
   Preserved in git history at commit `933f4a0`.
5. **the shape model** (2026-07) — the parser was rebuilt around the insight that every node has
   exactly three kinds of fact: the **Tree** (where it sits), its **Attributes** (facts it carries),
   and its **Edges** (typed references it makes). The old side-files (`sigs`/`docs`/`fields`/
   `delegates`/`examples`) collapsed into two streams — `attrs.tsv` (109,729 facts) and
   `edges.tsv` (54,667 resolved references) — keyed to `nodes.tsv` by `path`. The parser now
   **follows `@import`** (one organism), **includes private decls** (`vis`), and **resolves each
   edge's reach** in a second pass. The `n_children` conservation law is retired; integrity is now
   referential (connected tree · attrs key on nodes · edges resolve to nodes).

---

## Current status

The datasets live in [`data/std/`](data/std/) (the product), pinned to **zig 0.16.0**.
Everything below is self-verifying and byte-identical on rerun.

> This table is **status** — what's built and how much. The canonical per-dataset docs (columns,
> purpose, self-check) live once, in the folder READMEs: [`extracted/`](data/std/extracted/) (facts
> from Zig) and [`derived/`](data/std/derived/) (computed). Engine internals: [`parse/`](parse/) ·
> [`reflect/`](reflect/). Don't re-describe datasets here — link to those.

| piece | built by | status |
|---|---|---|
| **the Tree** — `nodes.tsv` | `parse/build.zig` | ✅ the spine: full std, 63,494 nodes (56,088 pub / 7,406 priv) / 340 files, depth 8; connectivity-checked |
| **Attributes** — `attrs.tsv` | `parse/build.zig` | ✅ 109,729 facts keyed by `path`: 11,273 sigs · 13,721 `///` docs · 19,809 field/const values · 63,493 locations · 1,433 test bodies; each keys onto a real node |
| **Edges** — `edges.tsv` | `parse/build.zig` | ✅ 54,667 typed refs (47,983 has_type · 2,942 alias · 2,876 error_set · 829 imports · 37 delegates), resolved to a scope; 96% of resolvable ones land on a node/primitive; local/cross verified to resolve |
| **factory descent** — `nodes.tsv` | `parse/build.zig` | ✅ single-return `fn(…) type` factories descended (members under `<fn>()`, e.g. `std.HashMap().get`); delegators record their target as a `delegates` edge |
| **examples** — `attrs.tsv` (`example`) | `parse/build.zig` | ✅ 1,433 `test {}` bodies, escaped to one row, anchored to the enclosing node |
| **table of contents** — `index.tsv` | `derive/index.zig` | ✅ contiguous-block index, 4,042 containers, self-checked both ways |
| **L5 resolved depth** — `resolved.tsv` | `reflect/resolve.zig` | ✅ 2,908 resolved / 1,134 genuine poison, zero dups |
| **consensus census** — `consensus.tsv` | `scripts/build_consensus.nu` | ✅ compares the two readers; every path tagged read+run 13,412 / run-only 2,304 / read-only 12,987; 0 blanks |
| **canon dedup/dealias** — `canon.tsv` | `scripts/build_canon.nu` | ✅ 236 paths in 100 alias/dup families (shared resolved `@typeName`); self-checked |
| **doc coverage** — `doccov.tsv` | `scripts/build_doccov.nu` | ✅ 22% of nodes documented (13,721 carry `///` docs); per-kind, self-checked vs map + docs overlay |
| **signature shapes** — `sigshape.tsv` | `scripts/build_sigshape.nu` | ✅ 11,273 signatures classed by first-param / Io / generic; self-checked vs the `sig` attrs |
| **call-card** — `callcard.tsv` | `scripts/build_callcard.nu` | ✅ sigs ⋈ resolved merge, 13,002 callables: 4,819 both / 1,729 reflect-only / 6,454 parser-only |
| **doc regeneration** | `scripts/build_arch.nu` | ✅ every markdown doc regenerated from `templates/` with live numbers from `data/std/`; byte-identical on `--check` |
| **reproducibility** | `--check` + `SHA256SUMS` | ✅ map/index instant; L5 in its own `build_depth.nu --check` (full sweep, machine-dependent) |

We can say *where* anything in std is, *how* it's shaped, and its resolved depth — completely
and provably. That is the faithful skeleton, the compiler's resolved view, a consensus census
that compares the two, and a canon overlay that dedups/de-aliases. Added detail and links come
next, as separate layers.

## Remaining work

1. **L4 — examples from tests** — extract and *run* `test {}` blocks (executing verification).
   Highest value-per-effort.
2. **L6 — version diff** — what changed between Zig versions; needs a second pinned snapshot.
Each new dataset registers with a harness and ships its own backward check.

## The parser (shape model) vs organisation (derive)

The dividing line: **raw source facts → the parser; interpretation → derive.** A node's Tree,
its Attributes, and the declaration-level Edges it makes are all things the source text states
directly, so they belong in the parser. What stays *out* is genuinely editorial: the *resolved*
reference graph (following an edge to its canonical home across the whole program) and
purpose-groupings.

**In the parser now:** the Tree (`nodes.tsv`, public + private), the Attributes (`attrs.tsv` —
`loc`, `value`, `doc`, `sig`, `example`), and declaration-level Edges (`edges.tsv` — `has_type`,
`alias`, `error_set`, `imports`, `delegates`), each resolved to a `scope`. Type-factory members
are descended under `<fn>()`; `@import` is followed into one organism.

**Still to add to the parser (raw source facts):**
1. **Error-set members** — `error{…}` is captured as an `error_set` edge, but its individual
   members aren't yet emitted as their own nodes.
2. **Opaque / multi-branch factories** — a `fn(…) type` built via `@Type` or comptime branching
   is invisible to text; resolving its members needs instantiated reflection (Phase D).
3. **Modifiers** — `extern`/`export`/`inline`/`threadlocal`/`var`-vs-`const` flags as an attribute.
   (`loc` — source location — is already emitted.)

**Body-level edges — the parser's next layer (deferred):**
- **`calls` / `references`** — who calls or reads what *inside* a function body. A heavier walk
  than the declaration-level edges above; the same shape (`src · type · target · scope`), added
  once the declaration base is settled.

**True organize-later (derive — never in the parser):**
- **The resolved reference graph** — chase each edge to a single canonical path across the program.
  A relationship layer / "direction" the parser must not bake in.
- **Grouping by purpose** (clustering) — bucket the tree into themes. The most editorial; last.

## Standing items

- [ ] Point the parser at non-std roots (already root-agnostic — needs a target list).
- [ ] Decide: keep snapshots git-tracked, or gitignore them with regeneration as the contract.
- [ ] **Trim reflect waste on `()` factory containers.** The tree now includes uninstantiated
  factory containers (`<fn>()`), which `build_depth.nu` dutifully tries to reflect — they can't
  instantiate standalone, so all 207 of them land in poison. `build_depth` should **skip `()`
  targets** (their real members are Phase D: instantiate the generic, then reflect). Honest, not
  wrong — just wasted sweep time and inflated poison.

## Known hardening (from the 2026-06-19 adversarial audit)

- **Timeouts can masquerade as poison** — ✅ **fixed.** The per-container reflect timeout exits
  124; `scripts/build_depth.nu` now branches on that exit code and records a distinct
  `timeout after Ns` reason, so a speed-gated container can never be mislabelled as a real
  compile-error poison.
- **Snapshot target triple is implicit** — *still open.* `PINNED` records only the Zig version,
  but some poison and resolved rows are x86_64-linux-specific. Fix: record the host triple in
  `PINNED`; have `--check` warn if the host differs. Corroborated externally by the
  [autodoc coverage comparison](docs/comparison/autodoc-vs-zephem.md): the decls autodoc reaches
  but this snapshot omits are dominated by target-conditional `std.os`/`std.c` bindings for
  non-native platforms (uefi/windows/darwin/bsd) — the same target scoping, seen from coverage.

## External validation

- **vs. Zig autodoc** — [`docs/comparison/autodoc-vs-zephem.md`](docs/comparison/autodoc-vs-zephem.md)
  compares this snapshot to Zig's own autodoc extraction, obtained by driving autodoc's own
  `Walk.zig`/`Decl.zig` natively (only the allocator patched). On the shared public-declaration
  surface the two reach a near-identical set; on top of that zephem adds fields and enum tags as
  first-class rows plus the resolved/callcard layer autodoc has no analogue for. The note is a
  **dated** snapshot, not regenerated with the data: it records its inputs and ships the commands
  to re-derive every figure, so drift is detectable by re-running — but, per scope, autodoc's own
  numbers are not rebuilt as part of zephem.
