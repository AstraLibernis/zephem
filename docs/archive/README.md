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

### Refactor-era architecture docs (archived 2026-06-21)

Superseded when the extractor was folded into `mapper/` (one parse, many visitors) and
the live "how it works" moved to [`../../mapper/README.md`](../../mapper/README.md). These
describe the old `src/scan.zig` + `src/enrich.zig` two-walk layout, which no longer exists.

- `REFACTOR-MAP.md` — the working map for the scan+enrich → `build.zig`+`walk.zig` refactor.
  Its job (plan the move) is done; kept for provenance of *why* the merge happened.
- `DATAFLOW.md`, `dataflow.html` — the whole-pipeline "star, not a loop" diagram, with the
  pre-refactor node names (`scan.zig`/`enrich.zig`). The mapper's flow now lives in
  `mapper/README.md §3`.

### Docs cleared for rewrite (archived 2026-06-21)

The live doc set was deliberately cut to three: the top `README.md`, the summarized `PLAN.md`,
and `mapper/README.md`. These older docs are accurate-in-spirit but pre-date the `mapper/` +
`clusters/` split and carry more detail than the new direction wants; **kept verbatim as the
source material for a future rewrite**, not maintained.

- `USAGE.md` — copy-pasteable query recipes (read one module, find by name, regenerate).
- `concepts.md` — the shared model (parse-don't-reflect, the pristine bar, the layer principle).
- `reproducibility.md` — the determinism contract and the `--check` harness story + timings.
- `layers/` — the per-dataset reference pages (L0 structure, L1/L2 decls, L3 tunnels,
  L4 examples [planned], L5 depth, L6 version-diff [planned]).
