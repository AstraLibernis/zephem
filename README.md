# zcrypto

A faithful map of `std.crypto` as it exists in Zig 0.16 — a wiki over the standard
library. It presents what std already contains in a readable, navigable form and adds
**nothing**: no advice, no recommendations, no security claims of its own. Every value
traces to std source or to a generated dataset under `data/`. Where std is silent, so
is this map.

See **[PLAN.md](PLAN.md)** for the charter — the rule every page obeys.

## Families

std splits crypto across namespaces, in two layers.

### Developer-facing — primitives you call directly

| family | std namespace | page |
|---|---|---|
| hashing | `std.crypto.hash` | [hash](docs/hash.md) |
| message auth (MAC) | `std.crypto.auth`, `std.crypto.onetimeauth` | [mac](docs/mac.md) |
| AEAD | `std.crypto.aead` | [aead](docs/aead.md) |
| stream ciphers | `std.crypto.stream` | [stream](docs/stream.md) |
| key derivation | `std.crypto.kdf` | [kdf](docs/kdf.md) |
| key exchange | `std.crypto.dh` | [kex](docs/kex.md) |
| signatures | `std.crypto.sign` | _pending_ |
| key encapsulation | `std.crypto.kem` | _pending_ |
| password hashing | `std.crypto.pwhash` | _pending_ |
| NaCl boxes | `std.crypto.nacl` | _pending_ |

### Building blocks (machinery) — what the above are made of

std exposes these publicly, but the surface analysis (`data/surface.tsv`) classes them
as internal — you rarely call them directly.

| family | std namespace | page |
|---|---|---|
| elliptic curves | `std.crypto.ecc` | _pending_ |

## Datasets — the source of truth

Two kinds of extraction: a **text scan** for breadth, **compiler reflection** for depth.
Full detail in **[data/README.md](data/README.md)**.

```
data/crypto_raw.csv   text scan   — every pub decl as written      (~1932 rows)
data/primitives.tsv   reflection  — resolved sizes & signatures     (~518 rows)
data/crypto_tree.*    reflection  — structural tree, 400 containers
data/surface.tsv      reflection  — the developer-facing surface    (134 primitives)
data/clusters.tsv     rules       — containers grouped by shape
```

Generated reports: **[surface.md](docs/surface.md)** (dev-facing surface),
**[structure.md](docs/structure.md)** (full tree), **[clusters.md](docs/clusters.md)**.

## Toolchain

**Zig** (reflection-based extraction) + **Nushell** (glue and querying) only. Every
dataset under `data/` is regenerable and idempotent.

## Reference

- Zig 0.16 std source: `lib/std/crypto.zig`
- Frank Denis, "A tour of std.crypto in Zig 0.7.0" (2020) — the prior guide, now dated:
  https://www.youtube.com/watch?v=9t6Y7KoCvyk
