# docs/archive — tombstone (historical only)

> **Nothing here is current, and nothing here is data.** This folder holds a single note about
> retired work, kept for provenance. The live project is the datasets under
> [`../../data/std/`](../../data/std/) and the docs linked from the root
> [`README.md`](../../README.md). If a tool or a person is looking for current data or docs, it is
> **not here** — do not read anything under this path as active.

The documents and datasets that used to live here (and under `archive/crypto-reflection/`) were
**deleted** to keep the tree clean. They are preserved in **git history** — recover any of them with:

```sh
git log --all --oneline -- <path>      # find the commit
git show <sha>:<path>                   # print the old file
```

## What was here, and why it's gone

zephem began as **zcrypto**, aimed only at `std.crypto`, and went through three framings before the
current source-AST extractor. Each left docs or data behind:

| retired | what it was | superseded by |
|---|---|---|
| crypto guide pages — `aead.md` `hash.md` `kdf.md` `kem.md` `kex.md` `mac.md` `nacl.md` `pwhash.md` `sign.md` `stream.md` | hand-written per-primitive explainers | (dropped — required crypto expertise the source can't warrant) |
| `map.md` `structure.md` `concepts.md` `inventory.md` `surface.md` `clusters.*` | early design / model docs | the engine READMEs — [`parse/`](../../parse/) · [`reflect/`](../../reflect/) |
| `layers/L0–L6` | the old "layer" model | the parse / reflect / derive engines |
| `plan-v1-guide.md` `REFACTOR-MAP.md` | old plans | [`../../PLAN.md`](../../PLAN.md) |
| `USAGE.md` `DATAFLOW.md` `dataflow.html` | query / dataflow guides | [`../../data/README.md`](../../data/README.md) |
| **`archive/crypto-reflection/`** — data + scripts + src (`primitives.tsv`, `crypto_tree.*`, `surface.tsv`, `crypto_raw.csv`, …) | the retired reflection-only crypto pipeline and its datasets | the general AST extractor. **Its `.tsv`/`.csv`/`.json` were NOT current data and are now deleted.** |

Retired 2026-06-17; the reproducibility contract was promoted out to
[`../reproducibility.md`](../reproducibility.md); everything else folded to this single note 2026-07-08.
