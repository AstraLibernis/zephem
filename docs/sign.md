# std.crypto — sign (signatures)

**Layer:** developer-facing — present in `data/surface.tsv` (primitives a developer calls directly).

A map of the digital-signature primitives in `std.crypto.sign` for Zig 0.16. This page
adds **nothing** to the standard library — it presents what is already there in a
readable form, with every value traceable to source:

- sizes & signatures — compiler reflection → `data/primitives.tsv`
- definition site & doc-comments — scan of std source → `data/crypto_raw.csv`
- public namespace paths → `data/surface.tsv`

> **Coverage.** This page covers the 3 signers for which reflection has resolved
> sizes/signatures. The `sign` namespace exposes more variants (full list in
> `docs/surface.md`) — pending resolution, not omitted by choice.

## The map

all sizes are in **bytes**.

| primitive | public path | public key | secret key | signature | defined in |
|---|---|--:|--:|--:|---|
| Ed25519 | `std.crypto.sign.Ed25519` | 32 | 64 | 64 | `crypto/25519/ed25519.zig` |
| EcdsaP256Sha256 | `std.crypto.sign.ecdsa.EcdsaP256Sha256` | 33 / 65 | 32 | 64 | `crypto/ecdsa.zig` |
| MLDSA65 | `std.crypto.sign.mldsa.MLDSA65` | 1952 | 4032 | 3309 | `crypto/ml_dsa.zig` |

Sizes are the nested types' `encoded_length` (resolved in `data/primitives.tsv`).
For `EcdsaP256Sha256` the public key is `33` compressed / `65` uncompressed (SEC1),
and the signature is `64` raw with `der_encoded_length_max = 72`. All three define
`noise_length = 32` and a `KeyPair.seed_length = 32`. `MLDSA65` additionally resolves
internal constants (`alpha`, `beta`, `gamma1`) — see `data/primitives.tsv`.

## The shape

Each signer is a top-level type with the same six nested types. Common resolved
methods:

| nested type | role | methods |
|---|---|---|
| `KeyPair` | make / hold a keypair | `generate`, `generateDeterministic`, `fromSecretKey`, `sign`, `signer` |
| `PublicKey` | encode / decode a public key | `fromBytes`, `toBytes` |
| `SecretKey` | encode / decode a secret key | `fromBytes`, `toBytes` |
| `Signature` | encode / decode + verify | `fromBytes`, `toBytes`, `verify`, `verifier` |
| `Signer` | streaming signing | `update`, `finalize` |
| `Verifier` | streaming verification | `update`, `verify` |

Per-signer additions (resolved in `data/primitives.tsv`):

- **Ed25519** — top-level `verifyBatch`; `Signature.verifyStrict`, `Verifier.verifyStrict`; `SecretKey.seed`, `SecretKey.publicKeyBytes`.
- **EcdsaP256Sha256** — `PublicKey.fromSec1` / `toCompressedSec1` / `toUncompressedSec1`; `Signature.fromDer` / `toDer`; `KeyPair.signPrehashed`, `Signature.verifyPrehashed`.
- **MLDSA65** — top-level `newKeyFromSeed`; context variants `signWithContext`, `signerWithContext`, `verifierWithContext`, `verifyWithContext`; `SecretKey.public`, `SecretKey.signer`.

## std doc-comments (verbatim)

- **Ed25519** (`crypto/25519/ed25519.zig`) — "Ed25519 (EdDSA) signatures."
- **EcdsaP256Sha256** (`crypto/ecdsa.zig`) — "ECDSA over P-256 with SHA-256."
- **MLDSA65** (`crypto/ml_dsa.zig`):

  > ML-DSA-65 (Module-Lattice-Based Digital Signature Algorithm, 65 parameter set)
  > as specified in NIST FIPS 204.
  >
  > This is a post-quantum signature scheme providing NIST security category 3,
  > which is roughly equivalent to the security of SHA-384 or AES-192.
  >
  > Key sizes:
  > - Public key: 1952 bytes
  > - Secret key: 4032 bytes
  > - Signature: 3309 bytes
  >
  > This parameter set offers higher security than ML-DSA-44 at the cost of larger
  > keys and signatures.

---

*Generated from `data/` (`primitives.tsv`, `surface.tsv`, `crypto_raw.csv`).
Zig 0.16, extracted 2026-06-17. `defined in` paths are relative to `lib/std/`.
Resolvable source links pending the pinned-commit record — see
`PLAN.md` → Traceability requirement.*
