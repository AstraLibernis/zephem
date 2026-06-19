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
| **L3 tunnels** | what links to what (followable) | ▢ planned | [L3-tunnels](docs/layers/L3-tunnels.md) |
| **L4 examples** | how it's used, *and does it run* | ▢ planned | [L4-examples](docs/layers/L4-examples.md) |
| **L5 resolved depth** | real size / expanded generic / type | ✅ done | [L5-depth](docs/layers/L5-depth.md) |
| **L6 version diff** | what changed between Zig versions | ▢ planned | [L6-version-diff](docs/layers/L6-version-diff.md) |

## Status at a glance

| piece | status |
|---|---|
| **std map** (`scan.zig` + bundle) | ✅ full std mapped, self-verifying, deterministic, pinned (16,506 decls / 310 files) |
| **table of contents** (`index.zig`) | ✅ contiguous-block index, self-checked both ways (1,355 containers) |
| **decls overlay** (`enrich.zig`, L1+L2) | ✅ 7,143 rows; sig coverage == map's fn set (5,377 ⇔ 5,377) |
| **depth overlay** (`resolve.zig` + `build_depth.nu`, L5) | ✅ full-corpus sweep, verify-✓ (1,324 resolved / 0 redirect / 31 poison; zero dups) |
| **reproducibility** (`--check` + `SHA256SUMS`) | ✅ map + decls in `build_std.nu --check` (instant); **L5 in its own `build_depth.nu --check`** (separate — full sweep ≈13 min cold / ≈76 s warm). See [reproducibility](docs/reproducibility.md). |
| crypto reflection pipeline | 🗄️ archived → `archive/crypto-reflection/` (technique revived as L5) |

We can now say *where* anything in std is, *how it is shaped*, what it's called and documented
as, and its resolved depth — completely and provably. That is the skeleton plus its first three
overlays.

## Remaining work, in order

1. **[L4 — examples from tests](docs/layers/L4-examples.md)** — extract + *run* `test {}` blocks
   (executing verification); highest value-per-effort.
2. **[L3 — tunnels](docs/layers/L3-tunnels.md)** — resolve references to addresses; build after
   the overlays exist.
3. **[L6 — version diff](docs/layers/L6-version-diff.md)** — needs a second pinned snapshot.

Each new dataset registers with a harness and ships its own backward check (see
[reproducibility](docs/reproducibility.md)).

## Standing items

- [ ] Point the scanner at non-std roots (already root-agnostic — needs a target list).
- [ ] Decide: keep snapshots git-tracked, or gitignore them with regeneration as the contract.
