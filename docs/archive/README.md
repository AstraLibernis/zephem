# docs/archive

Retired documents, kept for provenance (archive-don't-delete). Nothing here is
maintained; the live project is the datasets under `data/` (see `../../PLAN.md`).

## Why these are archived

zcrypto went through three framings before settling:

1. **Explanatory guide** — explain what each primitive is for, how to compose safely,
   footguns. Retired: it required authored crypto expertise neither the std source nor
   we can warrant (the "why" is not in the files).
2. **Faithful map** — hand-written per-family pages that state only what's traceable.
   Retired 2026-06-17: the markdown only ever re-printed the datasets and goes stale the
   moment Zig changes. The data is the original; prose is a lossy photocopy.
3. **Data-extraction pipeline** (current) — the datasets are the product. See `PLAN.md`.

## Contents

- `plan-v1-guide.md` — the original 7-phase explanatory plan (framing 1).
- `map.md`, `inventory.md` — hand-authored mental model + annotated inventory (framing 1;
  carry judgement the later charter forbids).
- `hash.md`, `mac.md`, `aead.md`, `stream.md`, `kdf.md`, `kex.md`, `sign.md`, `kem.md`,
  `pwhash.md`, `nacl.md` — the per-family map pages (framing 2). Each is a human-verified
  assertion of what the datasets contain, so they double as **verification fixtures** for
  the pipeline.
- `surface.md`, `structure.md`, `clusters.md`, `clusters.svg` — rendered snapshots of the
  generated datasets (point-in-time; regenerate from `data/` instead of reading these).
