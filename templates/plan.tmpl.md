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
4. **parser stripped to one file** (2026-06-21) — the parser now emits *only* the structural
   map (`nodes.tsv`). Signatures/doc-comments (`decls`) and references (`tunnels`) were
   **removed from the parser** — they are *our* organisation (added detail and resolved links),
   not the faithful base. Parse all → output all; everything else is an "organize later" layer.
   Preserved in git history at commit `933f4a0`. (Signatures + docs were later re-added to the
   parser as `sigs.tsv` / `docs.tsv` — they are raw source facts only the parser can see.)

---

## Current status

The datasets live in [`data/std/`](data/std/) (the product), pinned to **@@ZIG@@**.
Everything below is self-verifying and byte-identical on rerun.

> This table is **status** — what's built and how much. The canonical per-dataset docs (columns,
> purpose, self-check) live once, in the folder READMEs: [`extracted/`](data/std/extracted/) (facts
> from Zig) and [`derived/`](data/std/derived/) (computed). Engine internals: [`parse/`](parse/) ·
> [`reflect/`](reflect/). Don't re-describe datasets here — link to those.

| piece | built by | status |
|---|---|---|
| **L0 structure map** — `nodes.tsv` | `parse/build.zig` | ✅ the parser's spine: full std, @@N_NODES@@ nodes / @@N_FILES@@ files, depth @@MAXDEPTH@@; conservation-checked |
| **signatures + docs** — `sigs.tsv` · `docs.tsv` | `parse/walk.zig` | ✅ @@N_SIGS@@ as-written fn signatures + @@N_DOCS@@ `///` docs, keyed by `path`; integrity-checked vs the map |
| **fields + tags** — `fields.tsv` | `parse/walk.zig` | ✅ @@N_FIELDS@@ struct/union fields + enum tags (`path·type·value`), 1:1 with the `field`/`tag` nodes; integrity-checked vs the map |
| **factory descent + delegates** — `nodes.tsv` · `delegates.tsv` | `parse/walk.zig` | ✅ single-return `fn(…) type` factories descended (members under `<fn>()`, e.g. `std.HashMap().get`); @@N_DELEGATES@@ delegators record their raw target; conservation-checked |
| **examples** — `examples.tsv` | `parse/walk.zig` | ✅ @@N_EXAMPLES@@ `test`/doctest usage snippets (`path·kind·name·code`); @@N_DOCTESTS@@ doctests bind by name to a decl; anchored to the map, self-checked |
| **table of contents** — `index.tsv` | `derive/index.zig` | ✅ contiguous-block index, @@N_INDEX@@ containers, self-checked both ways |
| **L5 resolved depth** — `resolved.tsv` | `reflect/resolve.zig` | ✅ @@N_RES_CONT@@ resolved / @@N_POISON@@ genuine poison, zero dups |
| **consensus census** — `consensus.tsv` | `scripts/build_consensus.nu` | ✅ compares the two readers; every path tagged read+run @@CON_RR@@ / run-only @@CON_RUNONLY@@ / read-only @@CON_READONLY@@; 0 blanks |
| **canon dedup/dealias** — `canon.tsv` | `scripts/build_canon.nu` | ✅ @@N_CANON@@ paths in @@CANON_FAMILIES@@ alias/dup families (shared resolved `@typeName`); self-checked |
| **doc coverage** — `doccov.tsv` | `scripts/build_doccov.nu` | ✅ @@DOC_PCT@@% of nodes documented (@@DOC_DOCUMENTED@@ carry `///` docs); per-kind, self-checked vs map + docs overlay |
| **signature shapes** — `sigshape.tsv` | `scripts/build_sigshape.nu` | ✅ @@N_SIGSHAPE@@ signatures classed by first-param / Io / generic; self-checked vs the signatures |
| **call-card** — `callcard.tsv` | `scripts/build_callcard.nu` | ✅ sigs ⋈ resolved merge, @@N_CALLCARD@@ callables: @@CC_BOTH@@ both / @@CC_REFLECT@@ reflect-only / @@CC_PARSER@@ parser-only |
| **cross-layer oracle** | `scripts/verify_layers.nu` | ✅ parser kinds vs **compiler** reflected kinds — 100% agree: every parser fn reflects as fn (@@CC_BOTH@@ callables), every container as type |
| **viewer** — `docs/` site | `scripts/build_arch.nu` | ✅ generated hub + per-slice pages (index/canon/consensus/doccov/sigshape/callcard), CSS-bar charts from the `.tsv`, byte-identical on `--check`; also regenerates the markdown docs |
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

## The inclusive map (parser) vs organisation (derive)

The dividing line: **raw source facts → the parser (the all-inclusive map); organisation →
derive.** Signatures and docs are raw source facts only the parser can see (derive reads no Zig;
reflect has resolved types but no names, no docs), so they belong in the parser's output — not as
a later overlay. What stays *out* of the parser is genuinely editorial: resolved cross-links and
purpose-groupings.

**In the parser now:** structure (`nodes.tsv`), as-written fn signatures (`sigs.tsv`), `///` docs
(`docs.tsv`), struct/union fields + enum tags (`fields.tsv`), type-factory members (descended
under `<fn>()`) and delegating-factory targets (`delegates.tsv`) — all keyed by `path`, all
integrity-checked.

**Still to add to the parser (raw source facts):**
1. **Fields — done for structs/unions/enums** ✅ (`fields.tsv`). *Still open:* **error-set
   members** — `error{…}` parses as a distinct node, not a container field, so its members aren't
   descended yet.
2. **Generic type factories — done for single-return + delegators** ✅ (Phase B): a `fn(…) type`
   with one top-level `return struct {…}` is descended (`std.HashMap().get`); a delegator
   (`return Other(args)`) records its raw target in `delegates.tsv`. *Still open:* **opaque**
   (`@Type`/comptime-built) and **multi-branch** factories — invisible to text; need instantiated
   reflection (Phase D).
3. **Location + modifiers** — per-decl source `file`·`line`, and `extern`/`export`/`inline`/
   `threadlocal`/`var`-vs-`const` flags. Columns on `nodes.tsv`. *(next — easy)*

**True organize-later (derive — never in the parser):**
- **References / links** (was `tunnels`) — the *resolved* reference graph (what name resolves to
   what). A relationship layer a "direction" the parser must not bake in. *(still to do — will
   read the parser's raw `delegates.tsv` targets and resolve them to canonical paths.)*
- **Grouping by purpose** (clustering) — bucket the map into themes. The most editorial; last.
- **Call-card** — ✅ **built** (`callcard.tsv`): joins the as-written signatures with the
   resolved view into one per-callable row.

## Standing items

- [ ] Point the parser at non-std roots (already root-agnostic — needs a target list).
- [ ] Decide: keep snapshots git-tracked, or gitignore them with regeneration as the contract.
- [ ] **Before the next reflect sweep**: descended factory `fn`s now carry children, so they show
  up as containers in `index.tsv` (which `build_depth.nu` reads for targets). Reflecting a *fn*
  (rather than a type) yields no members, so the sweep should **skip factory-`fn` targets** — real
  factory-member resolution is Phase D (instantiate the generic, then reflect). Not urgent (the
  reflect sweep is not rerun on a parse-only change), but must be handled before it runs again.

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
