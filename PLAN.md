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
   Whole pipeline archived under `archive/crypto-reflection/`.
2. **zephem** (2026-06-17) — reframed as a general extractor built on **AST parsing**
   (parse-don't-reflect): it reads source as syntax, never evaluates comptime, so it maps
   **all** of std including poison decls. The tool is the extractor, not the crypto.
3. **engine split** (2026-06-21) — split by *what each reads* into three engines: **`parse/`**
   (read source as text), **`reflect/`** (run the compiler → resolved depth), **`derive/`**
   (transform the datasets, read no Zig → index, canon). Docs cut to three (this file,
   `README.md`, `parse/README.md`); the rest parked in `docs/archive/` for rewrite.
4. **parser stripped to one file** (2026-06-21) — the parser now emits *only* the structural
   map (`nodes.tsv`). Signatures/doc-comments (`decls`) and references (`tunnels`) were
   **removed from the parser** — they are *our* organisation (added detail and resolved links),
   not the faithful base. Parse all → output all; everything else is an "organize later" layer.
   Preserved in git history at commit `933f4a0`.

---

## Current status

The datasets live in [`data/std/`](data/std/) (the product), pinned to **zig 0.16.0**.
Everything below is self-verifying and byte-identical on rerun.

| piece | built by | status |
|---|---|---|
| **L0 structure map** — `nodes.tsv` | `parse/build.zig` | ✅ the parser's one output: full std, 16,506 decls / 310 files, depth 8; conservation-checked |
| **table of contents** — `index.tsv` | `derive/index.zig` | ✅ contiguous-block index, 1,355 containers, self-checked both ways |
| **L5 resolved depth** — `resolved.tsv` | `reflect/resolve.zig` | ✅ 1,324 resolved / 31 genuine poison, zero dups |
| **consensus census** — `consensus.tsv` | `scripts/build_consensus.nu` | ✅ compares the two readers; every path tagged read+run 13,424 / run-only 2,296 / read-only 3,082; 0 blanks |
| **canon dedup/dealias** — `canon.tsv` | `scripts/build_canon.nu` | ✅ 236 paths in 100 alias/dup families (shared resolved `@typeName`); self-checked |
| **cross-layer oracle** | `scripts/verify_layers.nu` | ✅ parser kinds vs **compiler** reflected kinds: fn⟹fn 4,823/4,823, container⟹type 2,375/2,375 |
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

## Organize-later layers (on top of the faithful map, never in the parser)

The parser emits only the structural map. These are *our* organisation, added back each as its
own separate layer once the base is settled — all preserved in git history at commit `933f4a0`:

1. **Signatures + doc-comments** (was `decls`) — each fn's as-written signature and any `///`,
   keyed to the map by `path`. Added detail, not structure.
2. **References / links** (was `tunnels`) — the resolved reference graph (what name resolves to
   what). A relationship layer — a "direction" the parser must not bake in.
3. **Grouping by purpose** (clustering) — bucket the map into themes. The most editorial of the
   three; deliberately last.

## Standing items

- [ ] Point the parser at non-std roots (already root-agnostic — needs a target list).
- [ ] Decide: keep snapshots git-tracked, or gitignore them with regeneration as the contract.

## Known hardening (from the 2026-06-19 adversarial audit)

Two cross-machine soundness items still open (full backlog parked in
`docs/archive/` history):

- **Timeouts can masquerade as poison** — the per-container reflect timeout exits 124 into the
  same branch as a real compile error, so `resolved.tsv` is silently speed-gated. Fix: fail-loud
  on 124; assert no `exit N` reason survives in `poison.tsv`.
- **Snapshot target triple is implicit** — `PINNED` records only `zig 0.16.0`, but some poison
  and resolved rows are x86_64-linux-specific. Fix: record the host triple in `PINNED`; have
  `--check` warn if the host differs.
