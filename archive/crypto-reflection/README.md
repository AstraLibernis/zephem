# archive/crypto-reflection

The original `std.crypto` extraction pipeline, retired 2026-06-17 (archive-don't-delete).
Nothing here is maintained. The live project is the general std map under `data/std/`
(see `../../README.md` and `../../USAGE.md`).

## Why it's archived

zephem began (as `zcrypto`) pointed only at `std.crypto`, extracting it via **reflection**
(`@typeInfo`). That worked for one curated module but does not generalize: a reflection walk
evaluates decls, so it dies on the first platform-gated / poison decl (e.g. `std.c.darwin`'s
`assert(isDarwin())`). The project pivoted to **parsing source** with `std.zig.Ast`, which
maps *all* of std, and that became the product. This crypto pipeline is the superseded
predecessor — kept for provenance and as a reference for the reflection approach (resolved
byte sizes and signatures through generics, which the source scan does not compute).

## Contents

**Tools (`src/`)** — Zig, reflection-based:
- `dump.zig` — reflects a curated primitive list → resolved sizes & typed signatures (depth).
- `maptree.zig` — the crypto container tree with per-container counts (levels).
- `surface.zig` — the public developer-facing surface, labelled (labels).

**Scripts (`scripts/`)** — Nushell glue:
- `build_primitives.nu` → `primitives.tsv`   (needs zig)
- `build_tree.nu` → `crypto_tree.{tsv,json}`
- `build_surface.nu` → `surface.tsv`          (needs zig)
- `cluster_shapes.nu` → `clusters.tsv`        (rules over the tree)
- `parse_crypto.nu` → `crypto_raw.csv`        (regex text scan, breadth)

**Datasets (`data/`)** — point-in-time snapshots produced by the above (Zig 0.16.0).

## Regenerating (if ever needed)

Paths are relative to the repo root, so run from there. Note these were never brought to the
self-verifying / idempotent bar the std map meets, and `build_*` scripts reference the old
`src/` and `data/` locations — adjust paths to `archive/crypto-reflection/...` first.

## Related

Retired crypto *documentation* (per-family map pages, rendered snapshots) lives separately in
`../../docs/archive/` — see its README.
