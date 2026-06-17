# zcrypto

Pristine, queryable **datasets** of exactly what `std.crypto` contains in Zig 0.16.

Not a guide. The goal is not to explain what crypto is *for* — it is to record what is
*actually in Zig*, including detailed, cross-cutting facts that Zig's autodoc doesn't
surface well: resolved byte sizes and full signatures (through aliases and generics),
which primitives share an interface, and the complete structural tree. Built by compiler
reflection, so the data is the compiler's truth, not a guess.

## The datasets (`data/`)

| dataset | answers |
|---|---|
| `primitives.tsv` | resolved sizes & signatures per primitive (depth) |
| `crypto_raw.csv` | every `pub` decl as written, and where (breadth) |
| `crypto_tree.{tsv,json}` | the full structural tree with per-container counts |
| `surface.tsv` | the developer-facing surface, labelled |
| `clusters.tsv` | containers grouped by structural shape |

Query with Nushell — schema + cookbook in **[data/README.md](data/README.md)**:

```nu
# every key/nonce/tag/digest size, by family
open data/primitives.tsv | where kind == 'const_int' and ($it.decl | str ends-with 'length')

# the full resolved API of one primitive
open data/primitives.tsv | where primitive == 'ChaCha20Poly1305'

# confirm every AEAD shares the same encrypt shape
open data/primitives.tsv | where family == 'aead' and decl == 'encrypt'
```

## How it's built

Zig reflection (the compiler resolves the real types) + a text scan for breadth, glued
by Nushell. Three phases — extraction, organization, dataset creation — described in
**[PLAN.md](PLAN.md)**. Every dataset is regenerable and idempotent.

## Quality bar

Datasets aim to be **deterministic** (byte-identical per Zig version), **complete or
explicitly scoped**, **self-verifying**, and **pinned** to a Zig commit. See PLAN.md.

## Toolchain

**Zig** (reflection extraction) + **Nushell** (glue / query) only.

## Reference

- Zig 0.16 std source: `lib/std/crypto.zig`
- Prior human-readable docs (retired): `docs/archive/` (see its README)
