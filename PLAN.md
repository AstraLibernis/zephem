<!-- GENERATED from templates/plan.tmpl.md by `zephem docs` — edit the template, not this file. -->
# zephem — Plan

**What it is.** A complete, self-checking map of the Zig standard library you actually have
installed (and, via `zephem deps`, your project's packages), regenerated from the toolchain's
own source. Its purpose is to let an LLM (or a person) **look std APIs up instead of
recalling them**: `zephem look` / `zephem map` answer from the map, and zcanon checks every
std call against it. Underneath, the map is built as pristine, queryable **datasets**, starting
with the namespace tree and layering on signatures, doc-comments, references and resolved
types, each regenerated and self-checked by the pipeline. The datasets are the foundation,
never prose; the map built on them is the product. Every fact is something the compiler
or source states or computes, nothing authored.

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
   `delegates`/`examples`) collapsed into two streams — `attrs.tsv` (111,480 facts) and
   `edges.tsv` (54,666 resolved references) — keyed to `nodes.tsv` by `path`. The parser now
   **follows `@import`** (one organism), **includes private decls** (`vis`), and **resolves each
   edge's reach** in a second pass. The `n_children` conservation law is retired; integrity is now
   referential (connected tree · attrs key on nodes · edges resolve to nodes).
6. **pure-Zig toolchain** (2026-07-16, v0.2.0) — the orchestration/query/doc-gen glue, previously
   Nushell, was ported to Zig and the 22 `.nu` deleted. A real `build.zig` + single `zephem` binary
   (subcommands `std`/`depth`/`overlays`/`docs`/`lookup`/`look`/`map`/`test`) now builds everything;
   the three engines stay in place (`parse/walk.zig`, `reflect/resolve.zig`, `derive/index.zig`).
   The port fixed a latent Nushell bug: `open` CSV-strips quotes from real values (`"test"` → `test`),
   so the Zig reader is *more* faithful. No behaviour change to the datasets otherwise.
7. **depth trim + batch experiment** (2026-07-17, v0.3.0) — `zephem depth` now **skips** the 207
   uninstantiated `<fn>()` factory containers (a new `skipped` status; poison deflated 1134→927,
   resolved unchanged). Also *tried and reverted* batching many containers per `zig run` — measured
   SLOWER at the time; superseded by item 9. See "Performance" below.
8. **three quick-win facts** (2026-07-17, v0.4.0) — added the `mod` attribute (extern/export/inline/
   noinline/threadlocal/comptime + `var`-vs-`const` — a mutable global was previously indistinguishable
   from a const), the `errmember` attribute (named `error{…}` set members), and the **host triple** in
   `PINNED`. All additive attrs / a PINNED line → nodes/edges/index + the reflect layer unchanged.
9. **batched sweep** (2026-09-28, v0.6.0) — `zephem depth` probes containers ~50 per object file
   (analysis only) to find the ones that fail, then reflects the clean ones ~50 per binary. Output
   is byte-identical to the one-container-per-process sweep (kept as `--solo`), and a full sweep
   went from 146–241 s to 16.5 s ± 0.1 s cold. The same work found that zephem's own generated source
   broke on quoted identifiers (`@"PE32+"`), so 4 containers had been recorded as compiler poison;
   they now resolve.
10. **dependency maps** (2026-09-28, v0.6.0) — `zephem deps <project>` maps the modules a project's
   packages export (read from `build.zig.zon` / `build.zig`, never run), each self-checked into
   `data/deps/`; `look`/`map` search them next to std. Also: deprecated aliases are marked on the
   `≡` line, and the README leads with what zephem is for.
11. **the map is the product** (2026-09-26 → 09-29, v0.6.0) — the bundled skill is removed (zcanon
   owns agent usage); the lookup table lives inside the repo and `map` searches it in place,
   rebaking a stale index; builtins are mapped; queries follow alias/delegates edges and suggest
   the nearest name on a miss; Windows builds; ReleaseSafe by default; code relicensed to
   GPL-3.0-or-later (the datasets stay MIT).

---

## Current status

The datasets live in [`data/std/`](data/std/) (the foundation the map is built from), pinned to **zig 0.16.0**.
Everything below is self-verifying and byte-identical on rerun.

> This table is **status** — what's built and how much. The canonical per-dataset docs (columns,
> purpose, self-check) live once, in the folder READMEs: [`extracted/`](data/std/extracted/) (facts
> from Zig) and [`derived/`](data/std/derived/) (computed). Engine internals: [`parse/`](parse/) ·
> [`reflect/`](reflect/). Don't re-describe datasets here — link to those.

| piece | built by | status |
|---|---|---|
| **the Tree** — `nodes.tsv` | `parse/walk.zig` | ✅ the spine: full std, 63,494 nodes (56,088 pub / 7,406 priv) / 340 files, depth 8; connectivity-checked |
| **Attributes** — `attrs.tsv` | `parse/walk.zig` | ✅ 111,480 facts keyed by `path`: 11,273 sigs · 13,721 `///` docs · 19,809 field/const values · 63,493 locations · 1,433 test bodies · 1,257 modifiers · 494 error members; each keys onto a real node |
| **Edges** — `edges.tsv` | `parse/walk.zig` | ✅ 54,666 typed refs (47,983 has_type · 2,942 alias · 2,876 error_set · 828 imports · 37 delegates), resolved to a scope; 96% of resolvable ones land on a node/primitive; local/cross verified to resolve |
| **factory descent** — `nodes.tsv` | `parse/walk.zig` | ✅ single-return `fn(…) type` factories descended (members under `<fn>()`, e.g. `std.hash_map.HashMap().get`); delegators record their target as a `delegates` edge |
| **examples** — `attrs.tsv` (`example`) | `parse/walk.zig` | ✅ 1,433 `test {}` bodies, escaped to one row, anchored to the enclosing node |
| **table of contents** — `index.tsv` | `derive/index.zig` | ✅ contiguous-block index, 4,042 containers, self-checked both ways |
| **L5 resolved depth** — `resolved.tsv` | `reflect/resolve.zig` | ✅ 2,912 resolved / 923 genuine poison, zero dups |
| **consensus census** — `consensus.tsv` | `zephem overlays` | ✅ compares the two readers; every path tagged read+run 13,416 / run-only 2,304 / read-only 12,983; 0 blanks |
| **canon dedup/dealias** — `canon.tsv` | `zephem overlays` | ✅ 236 paths in 100 alias/dup families (shared resolved `@typeName`); self-checked |
| **doc coverage** — `doccov.tsv` | `zephem overlays` | ✅ 22% of nodes documented (13,721 carry `///` docs); per-kind, self-checked vs map + docs overlay |
| **signature shapes** — `sigshape.tsv` | `zephem overlays` | ✅ 11,273 signatures classed by first-param / Io / generic; self-checked vs the `sig` attrs |
| **call-card** — `callcard.tsv` | `zephem overlays` | ✅ sigs ⋈ resolved merge, 13,002 callables: 4,819 both / 1,729 reflect-only / 6,454 parser-only |
| **doc regeneration** | `zephem docs` | ✅ every markdown doc regenerated from `templates/` with live numbers from `data/std/`; byte-identical on `--check` |
| **reproducibility** | `--check` + `SHA256SUMS` | ✅ map/index instant; L5 in its own `zephem depth --check` (full sweep, machine-dependent) |

We can say *where* anything in std is, *how* it's shaped, and its resolved depth — completely
and provably. That is the faithful skeleton, the compiler's resolved view, a consensus census
that compares the two, and a canon overlay that dedups/de-aliases. Added detail and links come
next, as separate layers.

## Remaining work

**Guiding constraint — map, don't author.** Every fact is extracted from Zig or computed from what
was extracted; zephem never *writes* content. Usage examples come from the std authors' own `test {}`
blocks — we harvest them, never generate them. Where an API has no demonstration in std, that gap is
reported *as data* (an example-coverage overlay), never filled: writing a missing example is the
developer's job, and a fabricated row would carry false authority and break the "if a row is wrong,
Zig said so" contract.

1. **L4 — usage examples, harvested + cross-linked.** The 1,433 `test {}` bodies are already
   captured (`attrs`, `example`), each anchored to its enclosing node. Two steps make them a real
   usage layer, no authoring:
   - **run them** (executing verification — a captured test that no longer compiles is stale signal);
   - **cross-link** each test to *every* public decl it exercises (needs the body-level edges below),
     so one `test sha256` documents `init`/`update`/`final` at once — multiplying coverage far past the
     raw test count over the ~10.6k public-fn+type API surface.
2. **Example-coverage overlay** (derive) — which of the public API surface has a demonstrated usage
   and which doesn't. `doccov` for *examples*. Surfaces the honest gap; does not fill it.
3. **L6 — version diff** — what changed between Zig versions; needs a second pinned snapshot.

Each new dataset registers with a harness and ships its own backward check.

## The parser (shape model) vs organisation (derive)

The dividing line: **raw source facts → the parser; interpretation → derive.** A node's Tree,
its Attributes, and the declaration-level Edges it makes are all things the source text states
directly, so they belong in the parser. What stays *out* is genuinely editorial: the *resolved*
reference graph (following an edge to its canonical home across the whole program) and
purpose-groupings.

**In the parser now:** the Tree (`nodes.tsv`, public + private), the Attributes (`attrs.tsv` —
`loc`, `value`, `doc`, `sig`, `example`, `mod`, `errmember`), and declaration-level Edges (`edges.tsv` — `has_type`,
`alias`, `error_set`, `imports`, `delegates`), each resolved to a `scope`. Type-factory members
are descended under `<fn>()`; `@import` is followed into one organism.

**Still to add to the parser (raw source facts):**
1. **Opaque / multi-branch factories** — a `fn(…) type` built via `@Type` or comptime branching
   is invisible to text; resolving its members needs instantiated reflection (Phase D).
2. **Facts still captured only as opaque text** — parameter names ⋈ types ⋈ defaults, and pointer
   decorations (sentinel/const/volatile/align, optionality) sit inside the raw `sig` string or are
   stripped by `extractBase` to a base identifier; decomposing them into queryable facts is the
   next parse-side depth (see the audit's extraction-depth findings).

(Shipped in v0.4.0: **modifiers** → the `mod` attr; **error-set members** → the `errmember` attr.)

**Body-level edges — the parser's next layer (deferred) — the *usage graph*:**
- **`calls` / `references`** — who calls or reads what *inside* a function body. A heavier walk
  than the declaration-level edges above; the same shape (`src · type · target · scope`), added
  once the declaration base is settled. This is the piece that answers **"how is X used, and with
  what?"** — composition across decls, which per-decl reflection (isolated, one container per
  process) structurally cannot see. It's also what lets L4 cross-link each test to the APIs it
  exercises.

**True organize-later (derive — never in the parser):**
- **The resolved reference graph** — chase each edge to a single canonical path across the program.
  A relationship layer / "direction" the parser must not bake in.
- **Grouping by purpose** (clustering) — bucket the tree into themes. The most editorial; last.

## Standing items

- [x] **Point the parser at non-std roots** — ✅ **done (2026-09-28): `zephem deps`.** The target
  list is read from the project: `build.zig.zon` dependencies (transitive, local paths included),
  located in `zig-pkg/<hash>/`, and each package's `build.zig` `addModule` calls. Parse layer only;
  the reflect layer stays std-only.
- [ ] Decide: keep snapshots git-tracked, or gitignore them with regeneration as the contract.
- [x] **Trim reflect waste on `()` factory containers** — ✅ **done** (2026-07-17). An
  uninstantiated `<fn>()` factory can't reflect standalone, so all 207 of them
  used to land in poison; `zephem depth` now **skips them structurally** (a new `skipped` status),
  deflating poison to genuine compile-failures only. Provably safe — no `()` container ever
  resolves. Their real members are Phase D (instantiate the generic, then reflect).

## Performance — what makes the L5 sweep faster, and what doesn't

The sweep reflects **4042 containers**. Measured cold (benchfence, release build, one
pinned core, the compiler cache wiped before every sample): a `zig run` of one container costs
**169 ms**, and **~140 ms of that is analysing std's startup code** (`start.zig`,
`std.process.Init`, `Io`) before it reaches the container; a container that fails to compile still
costs 144 ms. The per-container reflection itself is small: **5.0 ms per container** when 50 share
one binary, with byte-identical rows. So the old one-process-per-container sweep was paying that
fixed cost 4,000 times — and adding lanes did not help (8, 16 and 24 lanes all measured the same:
the CPU was already full).

- ✅ **Probe-then-run batching** (2026-09-28, `src/depth.zig`) — ~50 containers per object file,
  analysis only (`build-obj -fno-emit-bin`), finds the failing ones: an error inside the generated
  file is attributed to its container by line range; an error inside std (which can be shared and
  reported once) makes the batch split in half. The clean containers are then reflected ~50 per
  binary, each introduced by a marker line. Any batch that still fails (a link-only error, a
  timeout) splits in half down to the solo path, so the solo path is the base case of both.
  Proven byte-identical to `--solo` over the full sweep (all three files), and `--check` passes.
  **about 16.5 s ± 0.1 s cold for the full sweep on a Ryzen 7 9800X3D (16 threads; hyperfine, 10 runs, compiler cache wiped before each)**; the solo sweep took 146–241 s on the same machine (2 runs).
  Of the batched time, ~⅔ is the probe phase — mostly batches split because of std-located errors.
- ✅ **The `()` skip** (above) removes the guaranteed-fail compiles. Small, correct.
- ◐ **Peel std-error culprits instead of halving** — the probe phase's remaining cost. Tried
  2026-09-28 and backed out untested: the first version lost the reference trace when a `note:`
  line sat between an error and its trace, and re-probed the same batch forever.
- ✗ **Batching blindly** (2026-07-17) — every batch held a failing container (~23% fail), so every
  batch bisected and paid solo cost plus the failed recompiles. Probing first is what fixed it.
- ✗ **Reporting the rows through `@compileError`** (no binary at all) — slower: comptime string
  formatting in the interpreter (992 ms vs 351 ms on the largest container).
- ✗ **`-fstrip` / `-fsingle-threaded`** — ~40% cheaper, but they change `builtin` values and so
  change the reflected data (`std.debug` reflects differently). Rejected: the map describes a
  normal build.
- ◐ **Incremental dev mode** (reuse prior verdicts, re-reflect only changed containers) — a large
  win for iteration, but *not* the reproducible build, which must ask the compiler cold. Not built.

## Known hardening (from the 2026-06-19 adversarial audit)

- **Generated source broke on quoted identifiers** — ✅ **fixed (2026-09-28).** A path like
  `std.coff.OptionalHeader.@"PE32+"` was pasted raw into a string literal and the SKIP list, a syntax
  error recorded as compiler poison for 4 containers. Paths are now escaped Zig strings and SKIP
  entries bare names (what `@typeInfo` compares against).
- **Poison reasons carried the generated file's line numbers** — ✅ **fixed (2026-09-28).**
  `<gen>:29:55` became `<gen>:32:55` when a licence header was added to the template, breaking
  `depth --check` with no change in what was poisoned. They now read `<gen>: error: …`.
- **Timeouts can masquerade as poison** — ✅ **fixed.** The per-container reflect timeout exits
  124; `zephem depth` now branches on that exit code and records a distinct
  `timeout after Ns` reason, so a speed-gated container can never be mislabelled as a real
  compile-error poison.
- **Snapshot target triple is implicit** — ✅ **fixed (v0.4.0).** `PINNED` now records the host
  triple (`zig <ver>` + `target <triple>`); `staleness` warns on a host mismatch, not just a
  version one. Some poison/resolved rows are x86_64-linux-specific, and the stamp now says so.
  Corroborated externally by the [autodoc coverage comparison](docs/comparison/autodoc-vs-zephem.md):
  the decls autodoc reaches but this snapshot omits are dominated by target-conditional
  `std.os`/`std.c` bindings for non-native platforms (uefi/windows/darwin/bsd) — the same target
  scoping, seen from coverage.

## External validation

- **vs. Zig autodoc** — [`docs/comparison/autodoc-vs-zephem.md`](docs/comparison/autodoc-vs-zephem.md)
  compares this snapshot to Zig's own autodoc extraction, obtained by driving autodoc's own
  `Walk.zig`/`Decl.zig` natively (only the allocator patched). On the shared public-declaration
  surface the two reach a near-identical set; on top of that zephem adds fields and enum tags as
  first-class rows plus the resolved/callcard layer autodoc has no analogue for. The note is a
  **dated** snapshot, not regenerated with the data: it records its inputs and ships the commands
  to re-derive every figure, so drift is detectable by re-running — but, per scope, autodoc's own
  numbers are not rebuilt as part of zephem.
