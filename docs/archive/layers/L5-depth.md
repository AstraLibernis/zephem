# L5 — Resolved depth ✅

| | |
|---|---|
| **Question** | the real size / expanded generic / concrete type — what parsing can't compute |
| **Source of truth** | reflect (the compiler), per-container, isolated |
| **Coverage** | full sweep (every container in the map) |
| **Build** | `src/resolve.zig` + `nu scripts/build_depth.nu --commit` |
| **Verify** | `scripts/verify_depth.nu` (bundled) · rebuild proof: `build_depth.nu --check` |

Index: [PLAN.md](../../PLAN.md) · model: [concepts.md](../concepts.md) · rebuild proof + timings: [reproducibility.md](../reproducibility.md#the-l5-reproducibility-story-the-hard-case).

---

## What it is

`resolve.zig` reflects **one container per isolated subprocess**, emitting resolved const
values (the real `key_length = 32`), expanded aliases/generics, and fully-typed signatures
with error sets. Per-process isolation contains the poison-decl death that killed blanket
reflection — so `build_depth.nu` sweeps **every** container in the map, not a hand-picked few
(the same `--only` unit still serves depth-on-demand for one path). Four outputs, all keyed to
the [map](L0-structure.md):

```
resolved.tsv   path · kind · detail   (resolved const VALUES, expanded generics, typed sigs)
redirects.tsv  path · redirect_to     (a dead-end alias: its parent IS the real one)
poison.tsv     path · reason          (genuinely unresolvable: platform / foreign lib / @compileError)
status.tsv     path · status · n_rows (per-container ledger; the verifier re-derives from this)
```

A path can dead-end two ways. **Poison** is real: the compiler can't analyze it here (a Windows
decl referencing kernel32 on Linux, a comptime `@compileError`). A **redirect** is not a failure
— it's a redundant alias path (`…Blake3.Blake3`) whose last segment isn't a member because the
parent already IS that type; the canonical path resolves on its own turn, so we just record the
redirect.

On Zig 0.16.0: **1,355 containers swept → 1,324 resolved (15,720 rows) / 0 redirect / 31 genuine
poison**, all checks green, zero duplicates (15,720 distinct == 15,720 rows).

## Verified two ways

`verify_depth.nu` re-reads the buckets and reconciles with the map: **partition** (each
container in exactly one bucket), **conservation** (Σ recorded `n_rows` == resolved rows),
**registration** (every attempted path is a real container), **no-data-lost** (every redirect
target is itself a container), **pristine** (no path resolves to two conflicting facts), and
**coverage** (`--full`: every container was attempted).

## Parallelism

The sweep is data-parallel — one op (reflect a container) over 1,355 independent items — so it
runs **one lane per available CPU** (`nproc`, override `--jobs`; `--jobs 1` = serial). Each lane
reflects in its **own** scratch file (`r-<i>.zig`) so lanes never collide, and results are
sorted back to target order before assembly, so output is **byte-identical to a serial sweep**
(proven across `--jobs` 1/3/6). See [reproducibility.md](../reproducibility.md#timings--relative-reference-only-not-a-benchmark)
for why the cache, not the lanes, is the real speed lever.

## History — root-caused, not patched (2026-06-18)

The first sweep on the *old* map showed 1,338 / 61 / 96 with 69 duplicate rows and 74
doubled-alias "poison" (`X25519.X25519.KeyPair`). Rather than add an alias bucket + dedup
downstream, we fixed the cause in `scan.zig`/`enrich.zig`: a selective re-export
`@import("f").X` was being mislabeled a namespace import and walked into as a file. Collapsing it
(A *becomes* what the selector resolves to) removed the doubled paths and the duplicate reads at
the source. The remaining 31 poison are all genuine (platform-conditional, integer overflow,
reached-unreachable, foreign-lib) — each carries the compiler's exact reason.

The reproducibility wiring (normalization of the volatile `__struct_NNNN` disambiguators +
relative poison paths, the `SHA256SUMS.depth` manifest, and `--check`) landed 2026-06-19 — full
story in [reproducibility.md](../reproducibility.md#the-l5-reproducibility-story-the-hard-case).

*Why this layer matters:* it stops the LLM hallucinating sizes/types once it has drilled to a
specific primitive.
