# std.crypto — kex (key exchange)

**Layer:** developer-facing — present in `data/surface.tsv` (primitives a developer calls directly).

A map of the key-exchange primitives in `std.crypto` for Zig 0.16. This page adds
**nothing** to the standard library — it presents what is already there in a
readable form, with every value traceable to source:

- sizes & signatures — compiler reflection → `data/primitives.tsv`
- definition site & doc-comments — scan of std source → `data/crypto_raw.csv`
- public namespace paths → `data/surface.tsv`

> **Namespace note.** std does not use a `kex` namespace. The Diffie-Hellman key
> exchange lives at `std.crypto.dh`. Post-quantum / hybrid key encapsulation (ML-KEM
> and friends) lives separately under `std.crypto.kem` — not covered on this page.

> **Coverage.** `X25519` is the only primitive reflection has resolved under `dh`,
> and the only one `dh` exposes (cross-check `docs/surface.md`).

## The map

all sizes are in **bytes**.

| primitive | public path | public | secret | shared | seed | defined in |
|---|---|--:|--:|--:|--:|---|
| X25519 | `std.crypto.dh.X25519` | 32 | 32 | 32 | 32 | `crypto/25519/x25519.zig` |

sizes = `public_length` / `secret_length` / `shared_length` / `seed_length`
(resolved in `data/primitives.tsv`).

## The interface

`X25519` exposes free functions; key generation lives on the nested
`X25519.KeyPair` type. Resolved signatures:

```
X25519.scalarmult           ([32]u8, [32]u8) error{IdentityElement}![32]u8
X25519.recoverPublicKey     ([32]u8) error{IdentityElement}![32]u8
X25519.publicKeyFromEd25519 (Ed25519.PublicKey) error{IdentityElement,InvalidEncoding}![32]u8

X25519.KeyPair.generate              (Io) X25519.KeyPair
X25519.KeyPair.generateDeterministic ([32]u8) error{IdentityElement}!X25519.KeyPair
X25519.KeyPair.fromEd25519           (Ed25519.KeyPair) error{IdentityElement,InvalidEncoding}!X25519.KeyPair
```

## std doc-comments (verbatim)

- **X25519** (`crypto/25519/x25519.zig`) — "X25519 DH function."

---

*Generated from `data/` (`primitives.tsv`, `surface.tsv`, `crypto_raw.csv`).
Zig 0.16, extracted 2026-06-17. `defined in` paths are relative to `lib/std/`.
Resolvable source links pending the pinned-commit record — see
`PLAN.md` → Traceability requirement.*
