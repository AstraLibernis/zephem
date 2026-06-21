# zephem — Plan (index)

**What this is.** A data-extraction, transformation, and verification tool that, pointed at a
Zig source root, emits pristine, queryable **datasets** of **true, direct knowledge** about
it — starting with the namespace tree (where everything is, how it's shaped) and layering on
progressively deeper facts (signatures, the authors' own doc-comments, references, runnable
examples, resolved sizes, version diffs). The product is the datasets *and the pipeline that
regenerates and self-checks them*, never prose.

The intended consumers are LLMs (tidy tables that parse cleanly into context, so the model
works from extracted fact instead of recollection) and humans using the data as a research
aid. Every fact is something the compiler or source states or computes — nothing authored.

**Two guarantees, both proven, both orthogonal.**
- **True** — every fact is extracted/computed, and the data checks itself (conservation,
  referential integrity, executing examples). *Is what it says correct?*
- **Reproducible** — the same Zig version rebuilds the byte-identical snapshot, every time,
  without breaking. *Will building it again give the same thing?*

Data can be internally consistent yet nondeterministic, or deterministic yet wrong. zephem
asserts **both**, mechanically, on every run.

**What it is not.** Not a guide, tutorial, or domain advice. **No hand-authored prose.** Any
human-readable view, if ever wanted, is generated from the data — never written by hand.

---

## Read next

- **[docs/concepts.md](docs/concepts.md)** — the shared model: parse-don't-reflect, the
  pristine bar, the layer principle, the positions/overlays/tunnels geometry, toolchain, history.
- **[docs/reproducibility.md](docs/reproducibility.md)** — the determinism contract, the
  `--check` harnesses, and the L5 reproducibility story + timings.

## Layers

Each layer is a separate dataset keyed to the map by `path` — see [concepts](docs/concepts.md#the-principle-true--direct-knowledge-in-layers).

| layer | what it answers | status | doc |
|---|---|---|---|
| **L0 structure** | where is it, how is it shaped | ✅ done | [L0-structure](docs/layers/L0-structure.md) |
| **L1+L2 decls** | fn signatures + authors' doc-comments | ✅ done | [L1-L2-decls](docs/layers/L1-L2-decls.md) |
| **L3 tunnels** | what links to what (followable) | ✅ done | [L3-tunnels](docs/layers/L3-tunnels.md) |
| **L4 examples** | how it's used, *and does it run* | ▢ planned | [L4-examples](docs/layers/L4-examples.md) |
| **L5 resolved depth** | real size / expanded generic / type | ✅ done | [L5-depth](docs/layers/L5-depth.md) |
| **L6 version diff** | what changed between Zig versions | ▢ planned | [L6-version-diff](docs/layers/L6-version-diff.md) |

## Status at a glance

| piece | status |
|---|---|
| **std map** (`scan.zig` + bundle) | ✅ full std mapped, self-verifying, deterministic, pinned (16,506 decls / 310 files) |
| **table of contents** (`index.zig`) | ✅ contiguous-block index, self-checked both ways (1,355 containers) |
| **decls overlay** (`enrich.zig`, L1+L2) | ✅ 7,143 rows; no signature lost vs map fns (5,377 cover 5,377 — parser-internal loss check) |
| **cross-layer agreement** (`verify_layers.nu`) | ✅ parser kinds vs **compiler** reflected kinds — the independent oracle. fn⟹fn 4,823/4,823, container⟹type 2,375/2,375; coverage deltas classified (alias re-home / behind const·generic / poison) → **0 truly missing, 0 unexplained**; observability-only (reports, no gate) |
| **depth overlay** (`resolve.zig` + `build_depth.nu`, L5) | ✅ full-corpus sweep, verify-✓ (1,324 resolved / 0 redirect / 31 poison; zero dups) |
| **tunnels overlay** (`tunnels.zig` + `build_tunnels.nu`, L3) | ✅ 5,123 resolved edges (alias/import/usage), verify-✓ 6 ways; sound (no dangling), unresolved recorded |
| **canon overlay** (`build_canon.nu` + `verify_canon.nu`) | ✅ full census of every path tagged by provenance — `read+run` 13,424 / `run-only` 2,296 / `read-only` 3,082 (3,081 poison + 1 root). **0 blanks**, all 2,296 made-members linked to their canonical owner (`@typeName`), verify-✓ 5 ways; deterministic (`--check`). Replaces "force 1:1, flag deltas" with a total partition |
| **reproducibility** (`--check` + `SHA256SUMS`) | ✅ map + decls in `build_std.nu --check` (instant); **L5 in its own `build_depth.nu --check`** (separate — full sweep, machine-dependent: ≈13 min cold / ≈76 s warm on a 3-core VM, under a minute on a many-core desktop); **L3 in `build_tunnels.nu --check`** (parse, instant). See [reproducibility](docs/reproducibility.md). |
| crypto reflection pipeline | 🗄️ archived → `archive/crypto-reflection/` (technique revived as L5) |

We can now say *where* anything in std is, *how it is shaped*, what it's called and documented
as, its resolved depth, and *what links to what* — completely and provably. That is the skeleton,
three attribute overlays, and the graph that connects them.

## Audit trail

Independent per-step audit run so the ✅ claims above are checked, not asserted. Re-run the
harnesses (`verify_std.nu`, `verify_tunnels.nu`, `verify_depth.nu`, and the three `--check`
modes) to reproduce.

- **2026-06-19** — every done-claim verified against the data and the project's own harnesses:
  all headline counts exact (16,506 decls / 310 files · 1,355 containers · 7,143 decls with
  5,377 ⇔ 5,377 sig bijection · 5,123 tunnel edges, no dangling · 1,324/0/31 depth, zero dups);
  `verify_*` all green; planned/standing items honestly stated (L4 & L6 genuinely absent,
  scanner is root-agnostic, snapshots are git-tracked). **Two reproducibility bugs found and
  fixed:** (1) L5 was not byte-reproducible across machines — `norm-row` stripped
  `__struct/__union/__enum` disambiguator digits but not `__opaque`, so 112 `resolved.tsv` lines
  drifted on a different host; regex now covers `opaque`, snapshot regenerated, `--check` green.
  (2) `build_depth.nu --commit` always exited 1 after writing — a `(run …)` literal inside a
  nushell `$"…"` string parsed as a command call; parens escaped. All three layers (`build_std`,
  `build_tunnels`, `build_depth`) now pass `--check`. Sweep timings are machine-dependent (see
  [reproducibility](docs/reproducibility.md)).
- **2026-06-19** — four-lens adversarial audit (efficiency · reproducibility · soundness ·
  organization) for weak spots and refinements; findings recorded in the **Refinement backlog**
  at the end of this file.
- **2026-06-20** — backlog **#3 fixed** (the tautology). Added `scripts/verify_layers.nu`: an
  independent cross-layer oracle joining the parser's kinds (`nodes.tsv`, `scan.zig`) against the
  **compiler's** reflected kinds (`resolved.tsv`) — separate machinery, so agreement is evidence,
  not construction. Provable invariants clean (fn⟹fn 4,819/4,819, container⟹type 2,373/2,373);
  the genuinely circular `sig⇔fn` claim in `verify_std.nu` §6 was relabeled a parser-internal
  loss check (correctness now ↦ `verify_layers.nu`), and docs (README, L1-L2) corrected to match.
  The new check **surfaced what the tautology could not**: 1,527 compiler-fns the parser never
  emitted, recorded as deltas (observability-only by design).
- **2026-06-20** — that 1,527 bucket **triaged to zero genuine loss**, and `verify_layers.nu`
  taught to classify rather than dump. Two reconciliations the parser/compiler views need by
  design: (a) **keyword quoting** — the parser is source-faithful (`@"type"`), the compiler
  reflects the bare name (`type`); paths now compared quote-normalized (resolved the 4 phantom
  deltas that appeared in *both* directions). (b) **type bindings** — each unmatched compiler-fn
  is bucketed by what the parser calls its parent: `alias`/`nsref` → re-home (713), `const`/
  generic → behind a binding the parser doesn't descend into (810), a real container the parser
  descended into → GENUINE miss. Result: **713 + 810, 0 GENUINE, 0 truly-absent**; reverse
  direction 554 parser-fns unresolved, **all** under poison containers. The "blind spot" was a
  classifier artifact, not an emitter gap — the parser loses nothing it is designed to see.
  (Standing nit: L5 `resolve.zig` emits bare keyword names while the map keeps `@"type"` — a
  4-row path-key inconsistency in the overlay's "keyed by path" contract; fixable in the emitter
  but needs an L5 regen, so deferred. The cross-check normalizes around it meanwhile.)
- **2026-06-20** — **standing nit closed at the source.** `resolve.zig` now keyword-quotes member
  names it emits (`quoteId`: quote iff `!std.zig.isValidId(name) or std.zig.primitives.isPrimitive(name)`),
  so the overlay's path keys are byte-identical to the map's source-faithful keys instead of being
  reconciled after the fact. L5 regenerated (`build_depth.nu --commit`, ≈1 min on the 9800X3D):
  1,324 resolved / 31 poison unchanged, 15,720 rows, `verify_depth` green, `SHA256SUMS.depth`
  rewritten. `resolved.tsv` now carries **55** correctly-quoted path keys (reserved words `@"and"`/
  `@"else"`/`@"type"`, primitive-shadowing `@"void"`, numeric CPU ids `@"440"`/`@"i386"`). The 4
  keyword fn cases (`section_64.@"type"`, `WipFunction.@"switch"`/`@"unreachable"`,
  `builtins.@"unreachable"`) now match the parser key for key — verified by re-running
  `verify_layers.nu`: fn⟹fn **4,823/4,823**, container⟹type **2,375/2,375**, no over-quoting (the
  `isPrimitive` rule did not spuriously quote any legitimate bare name), parser-fn delta 1,527→1,523
  (= 713 alias/ns re-home + 810 behind const·generic). The normalization in `verify_layers.nu` stays
  as a belt-and-suspenders, but is no longer load-bearing.
- **2026-06-20** — **the canon overlay** (`build_canon.nu` → `data/std/canon.tsv`, gated by
  `verify_canon.nu`). Reframes the whole parser-vs-compiler question from "force the two views to
  match 1:1, flag every non-match as a miss" to a **total partition by provenance**. Two yes/no
  questions — *can text read it?* (in `nodes.tsv`) · *can the command make it here?* (in
  `resolved.tsv`) — give a 2×2 whose three populated cells are the `origin` tag on every path:
  `read+run` (matched 1:1, agreement = evidence) 13,424 · `run-only` (only exists when reflected:
  generic/alias members) 2,296 · `read-only` (text read it, can't run here: poison or the `std`
  root) 3,082. The empty fourth cell (neither layer sees it) is the proof the partition is total;
  the census 18,802 = |nodes ∪ resolved| closes both ways. Each row carries `owner` (the readable
  doorway/container it hangs off) and `owner_canon` (that owner's de-aliased `@typeName`, so
  `Sha256.digest_length` shows it lives on `crypto.sha2.Sha2x32(...)`). **Result the user asked for:
  0 blanks, every one of the 2,296 made-members linked to a canonical owner — no path left as
  "missing," none "assumed."** `verify_canon.nu` enforces it 5 ways (partition = membership;
  zero-blank; owner is a real node; every made-member's `owner_canon` matches its owner's resolved
  `@typeName`; every read-only is root-or-poison with the recorded reason). Pure deterministic
  derivation of committed files; `--check` proves byte-identical rebuild (`SHA256SUMS.canon`).

## Remaining work, in order

1. **[L4 — examples from tests](docs/layers/L4-examples.md)** — extract + *run* `test {}` blocks
   (executing verification); highest value-per-effort.
2. **[L6 — version diff](docs/layers/L6-version-diff.md)** — needs a second pinned snapshot.

L3 completeness follow-up (optional): multi-hop alias-following would resolve the
`Cipher.key_length`-style tails now in the unresolved bucket — a pure completeness gain, never a
soundness change.

Each new dataset registers with a harness and ships its own backward check (see
[reproducibility](docs/reproducibility.md)).

## Standing items

- [ ] Point the scanner at non-std roots (already root-agnostic — needs a target list).
- [ ] Decide: keep snapshots git-tracked, or gitignore them with regeneration as the contract.

## Refinement backlog (adversarial audit, 2026-06-19)

Weak spots surfaced by a four-lens adversarial pass (efficiency · reproducibility · soundness ·
organization). Severity / whether the issue was **reproduced** vs **reasoned** / fix / effort.
Two unifying themes: (a) implicit single-machine assumptions in a project that promises
"rebuilds identically anywhere" — same root cause as the `__opaque` bug; (b) the project not yet
fully practicing its own "self-verifying / every fact computed / no hand-authored prose" thesis.

| # | sev | finding | fix | effort |
|---|---|---|---|---|
| 1 | 🔴 high · **reproduced** | **Timeouts silently become poison.** Per-container 30 s reflect timeout: a slow host exits 124 and falls into the *same* poison branch as a real compile error (reason `exit 124`), so the poison set — and `resolved.tsv` — is silently speed-gated and drifts cross-machine. `build_depth.nu:114,127-128`. Committed poison is clean today (0/31 timeouts) only because it was built on fast boxes. | Fail-loud on exit 124 (don't demote to poison); assert "no `exit N` reason in poison.tsv" in `verify_depth.nu`. Optional `elapsed` column in `status.tsv` for margin visibility. | low |
| 2 | 🔴 high · confirmed | **Snapshot is implicitly x86_64-linux but unlabeled.** `PINNED` records only `zig 0.16.0`. 13/31 poison are target-foreign; 5 resolved rows carry `.x86_64_win` callconv. Rebuild on another arch → drift, no signal. | Record the target triple in `PINNED` (`zig env`); have `--check` warn/fail if the host triple differs. | low |
| 3 | 🟠 high · **demonstrated live** · ✅ **FIXED 2026-06-20** | **The "two-way" check for L0/L1/L2 is a tautology.** `enrich.zig` is a near-verbatim copy of `scan.zig` (same `findDecl`/`containerKindOf`/fn gate), so the 5,377 ⇔ 5,377 sig⇔fn bijection is two copies of one walk agreeing. A comptime-block container with a `pub fn` was dropped by **both** walks with every check green. Conservation only conserves what was emitted. | **Done:** `scripts/verify_layers.nu` joins `resolved.kind` (compiler) ↔ `nodes.kind` (parser): fn⟹fn 4,819/4,819 ✓, container⟹type 2,373/2,373 ✓; const/alias reported; `grep 'pub fn'` source anchor added. The bijection in `verify_std.nu` §6 was relabeled a parser-internal *loss* check (not a correctness proof). **It immediately found — then explained — what the tautology was blind to:** 1,527 compiler-fns the parser didn't emit, triaged to **0 genuine loss** — 713 alias/ns re-homes (`std.DynamicBitSet.*`), 810 behind const/generic type bindings (parse-don't-reflect), 4 keyword-quoting artifacts (`@"type"` vs `type`, reconciled by normalization). Classifier buckets by parent-kind; flags GENUINE only when the parser descended into the container. Observability-only per design. | ~1–2 h |
| 4 | 🟡 med · **measured** | **Compile-cache persistence > parallelism.** Cold L5 sweep 117.7 s vs warm 3.3 s — ~114 s of "cold" is Zig *recompiling*, not reflecting. Warm state survives only via 1,355 path-stable `r-<i>.zig` files in volatile `/tmp/zephem-depth`; a reboot restores the 117 s cost. par-each gave ~16×, cache persistence ~35×. (Note: a runtime-parameterized binary is impossible — reflection targets must be comptime-known; the per-container subprocess design is forced.) | Move scratch to a persistent / content-addressed cache (e.g. gitignored `data/.cache/depth/`, filename keyed by substituted-source hash). | low |
| 5 | 🟡 med · confirmed | **Triplicate proof logic.** `hashes`, manifest-parse, the intrinsic/regression/integrity loop, and `std-root`/`std-dir` are copy-pasted across all three `build_*.nu` (~90 lines). **Both bugs fixed on 2026-06-19 lived in this duplicated block** — the next fix needs applying 3×. Adding a layer is an ~8-site edit (L4/L6 imminent). | Factor `scripts/lib/manifest.nu` (`hashes`/`read-manifest`/`write-manifest`/`std-dir`/`prove-rebuild`); consider a `layers.nu` registry so a new layer is one record. | med |
| 6 | 🟡 med · confirmed | **Hand-authored counts drift** — headline numbers restated in ~7 doc places, violating the "no hand-authored prose / every fact computed" thesis. Live drift: `README.md:111` & `USAGE.md:92` still say "~45 min" (missed when the 2026-06-19 timing-wording fix updated only PLAN/`reproducibility.md`/the script). | Generate `data/std/STATS.tsv` (computed) and have docs cite it; fix the two stale "45 min". | low–med |
| 7 | 🟢 low · confirmed | `status.tsv` is fully derivable from `index`+`resolved`+`poison`; `redirects.tsv` is committed empty (+ a manifest slot); `SCRATCH` const vs the hardcoded `/tmp/zephem-depth` literal inside the `norm-row` regex (`build_depth.nu:130`) can silently drift; `norm-row`'s denylist `(struct\|union\|enum\|opaque)` is whack-a-mole — generalize to `__([a-z]+)_[0-9]+ → __$1` to pre-empt the next `__opaque`-class drift. | small, independent cleanups | low each |

Suggested first bundle (cheap, high-confidence cross-machine hardening, continuous with the
`__opaque` fix): **#1 + #2 + the #7 denylist→allowlist regex + the #6 stale "45 min"**.
