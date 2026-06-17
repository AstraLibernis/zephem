# std.crypto — kem (key encapsulation)

**Layer:** developer-facing — present in `data/surface.tsv` (primitives a developer calls directly).

A map of the key-encapsulation primitives in `std.crypto.kem` for Zig 0.16. This page
adds **nothing** to the standard library — it presents what is already there in a
readable form, with every value traceable to source:

- sizes & signatures — compiler reflection → `data/primitives.tsv`
- definition site & doc-comments — scan of std source → `data/crypto_raw.csv`
- public namespace paths → `data/surface.tsv`

> **Coverage.** This page covers the 2 KEMs for which reflection has resolved
> sizes/signatures. The `kem` namespace exposes more variants (full list in
> `docs/surface.md`) — pending resolution, not omitted by choice.

## The map

all sizes are in **bytes**. "—" means the size is not in the resolved set.

| primitive | public path | public key | secret key | ciphertext | shared | defined in |
|---|---|--:|--:|--:|--:|---|
| MLKem768 | `std.crypto.kem.ml_kem.MLKem768` | 1184 | 2400 | 1088 | 32 | `crypto/ml_kem.zig:181` |
| MlKem768X25519 | `std.crypto.kem.hybrid.MlKem768X25519` | 1216 | 32 | — | — | `crypto/hybrid_kem.zig:29` |

Public/secret-key sizes are the nested types' `encoded_length`; `ciphertext` /
`shared` are the top-level `ciphertext_length` / `shared_length` (resolved in
`data/primitives.tsv`). `MLKem768` also resolves `seed_length = 64` and
`encaps_seed_length = 32`.

## The shape

Each KEM is a top-level type with three nested types. Resolved methods:

| nested type | role | methods |
|---|---|---|
| `KeyPair` | make a keypair | `generate`, `generateDeterministic` |
| `PublicKey` | encapsulate → (ciphertext, shared secret) | `encaps`, `encapsDeterministic`, `fromBytes`, `toBytes` |
| `SecretKey` | decapsulate ciphertext → shared secret | `decaps`, `fromBytes`, `toBytes` |

The interface is `encaps` (on the public key) / `decaps` (on the secret key) — the
key-encapsulation pattern, distinct from the other families' verbs.

## std doc-comments (verbatim)

`MLKem768` ships no doc-comment in std.

- **MlKem768X25519** (`crypto/hybrid_kem.zig`) — "ML-KEM-768 combined with X25519 (Curve25519) aka X-Wing. Targets approximately 128-bit post-quantum security level."

---

*Generated from `data/` (`primitives.tsv`, `surface.tsv`, `crypto_raw.csv`).
Zig 0.16, extracted 2026-06-17. `defined in` paths are relative to `lib/std/`.
Resolvable source links pending the pinned-commit record — see
`PLAN.md` → Traceability requirement.*
