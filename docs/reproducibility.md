# zephem — Reproducibility

"Build it again, prove you got the same thing." This is enforced machinery, not an aspiration.
Index: [PLAN.md](../PLAN.md) · model: [concepts.md](concepts.md).

Datasets are **ephemeral by design** — derived, regenerable, never hand-authored. A committed
snapshot is a *pinned cache* of compiler/source truth for one Zig version. So a snapshot you
cannot provably rebuild is just hand-authored data with extra steps: reproducibility is a
**co-equal goal**, asserted mechanically on every run.

---

## Determinism contract — the variance we design out

Output is reproducible only because every non-deterministic input is eliminated by construction:

| source of churn | how it's killed |
|---|---|
| hashmap / dir iteration order | rows emitted in **source order** (pre-order DFS), never map order |
| absolute toolchain paths | rendered **relative to the module root** (`relPath`); in L5 poison reasons, `/usr/lib/zig/std/…` → `std/…` and the scratch `r-<i>.zig` → `<gen>` |
| timestamps / PIDs / RNG | none ever written into a dataset |
| anonymous comptime IDs (`__struct_NNNNN`) | the parse-based layers (L0–L2) never touch them; **L5 reflection does** — the digits drift between identical compiles, so `norm-row` strips them while keeping the stable `__struct`/`__enum`/`__union` marker (this same churn killed the old crypto pipeline) |

---

## Idempotency guard — the proof

A `--check` mode regenerates and asserts the result is **byte-identical**, three ways:

1. **Intrinsic** — two independent fresh rebuilds in one run are byte-identical. Proves the
   *process* is deterministic; needs no baseline.
2. **Regression** — a fresh rebuild reproduces the committed manifest (`SHA256SUMS`). Proves
   today's code + Zig still reproduces the **recorded** truth.
3. **Integrity** — the on-disk snapshot still matches its own manifest. Catches silent
   hand-edits.

A drift in any fails the build loudly. A shared single build path (`regen` in `build_std.nu`,
`sweep` in `build_depth.nu`) guarantees the normal build and `--check` cannot diverge.

**Robust regeneration.** Parsing-not-reflection means no input kills the parse layers: an
unreadable file becomes an `nserr` row, a moved file a different path — the snapshot is always
*valid*, and a Zig upgrade produces an additive, diffable delta (which [L6](layers/L6-version-diff.md)
renders).

---

## Three harnesses — fast parses, slow depth (kept separate on purpose)

- **Map + decls (parse): `nu scripts/build_std.nu --check`** — instant. Every build writes
  `data/std/SHA256SUMS` (a `sha256sum -c`-compatible manifest, hashed in pure Nushell) over the
  parse-based datasets; `--check` proves the three guarantees per dataset and exits non-zero on
  any drift. New parse datasets register by adding their name to one `NAMES` list.

- **Tunnels (parse + resolve): `nu scripts/build_tunnels.nu --check`** — also fast (a parse).
  Records `data/std/SHA256SUMS.tunnels` over `tunnels.tsv` + `unresolved.tsv` and proves the same
  three ways. See [L3](layers/L3-tunnels.md).

- **Depth (reflection): `nu scripts/build_depth.nu --check`** — slow, and deliberately **not**
  wired into `build_std.nu`. `--commit` records `data/std/SHA256SUMS.depth` over the four L5
  files (`status/resolved/redirects/poison.tsv`); `--check` proves the same three ways. It lives
  apart because the map is a parse (instant) while an L5 rebuild is a full reflection sweep —
  mixing them would wreck the fast map check. See [L5](layers/L5-depth.md) for the layer itself.

---

## The L5 reproducibility story (the hard case)

**Why L5 needed extra work.** The parse layers are deterministic for free (source order, no
comptime). Reflection is not: `@typeName` of an anonymous type carries a compiler-assigned
disambiguator (`E__enum_5797`) that is a *semantic-analysis sequence number*, and it **drifts
between otherwise-identical compiles**.

**Proven, then fixed (2026-06-19).** A control test — two sweeps of `std.Io` on identical
source — disagreed *only* on those counters (`E__enum_5797` vs `5796`,
`timespec__struct_14744` vs `14760`). Left raw, the intrinsic check would have false-failed on
day one. `norm-row` strips the volatile digits (keeping `…timespec__struct`); the same pass
relativizes absolute toolchain/scratch paths in poison reasons. After normalization the same
two-sweep test is byte-identical. A full cold sweep then a warm sweep reproduced the committed
snapshot byte-for-byte across all four files, with zero duplicate rows (15,720 distinct ==
15,720).

**The cache is part of the story, not cheating.** Zig's cache is content-addressed: a hit
returns exactly the bytes a fresh compile would. So a warm rebuild that *fails* to reproduce
the manifest is a **meaningful signal** — Zig version changed, source changed, or genuine
nondeterminism — not noise. And the disambiguator drift only surfaces on cache *misses* (cold
first build, post-upgrade, a different machine), which is precisely the case the normalization
protects: cache makes local re-runs fast and trivially identical; normalization makes the
snapshot reproducible when the cache can't save you.

### Timings — *relative reference only, not a benchmark*

*(fedora-KDE Hyper-V VM, 6 vCPU = 3 physical + SMT, no GPU; Zig 0.16.0, full std = 1,355
containers; 2026-06-19)*

| sweep | wall time |
|---|---|
| full L5 sweep, **cold** (empty cache) | ≈ **782 s** (~13 min) |
| full L5 sweep, **warm** (cache populated) | ≈ **76 s** (~1.3 min) |

The **cache is the ~10× lever, not parallelism.** Each `zig run` is already internally
multithreaded and saturates the 3 physical cores, so the data-parallel lanes (one per CPU via
`nproc`) measured only ≈1.3× on cold and ~nothing warm. Lanes are kept because they're free and
byte-identical (proven across `--jobs` 1/3/6), and they shave the genuinely-cold builds. The
practical consequence: `--check`'s second sweep hits the cache the first populated, so it is far
cheaper than two cold sweeps.
