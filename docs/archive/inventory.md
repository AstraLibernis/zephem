> **ARCHIVED 2026-06-17 — superseded.** Hand-authored annotated inventory; the
> per-primitive notes ("faster", "experimental", "best choice", "avoid") are
> judgement the current charter forbids. The factual list lives in the generated
> `surface.md`; resolved sizes/signatures in the per-family docs. Kept for
> provenance, per archive-don't-delete. See `PLAN.md` and `README.md`.

---

# std.crypto inventory — Zig 0.16

> **Role:** this is a *hand-authored* annotated reference — each entry with a
> plain-English note — and a peer of [`map.md`](map.md). It is intentionally not
> generated. The **machine-generated, authoritative** list and counts live in
> [`surface.md`](surface.md) (dev-facing primitives, by reflection) and
> [`structure.md`](structure.md) (full container map). If a number here and a
> generated count ever disagree, the generated one wins.

Cross-checked by hand against `/usr/lib/zig/std/crypto.zig` (Zig 0.16.0, 2026-06-17).
It lists the **top-level `crypto.*` exports** — uppercase = named primitives/types,
lowercase = sub-namespace groups. Note this is a different lens from `surface.md`'s
**134 developer-facing primitives**: the top-level count below also includes
sub-namespace groups, error sets, and config types, and excludes primitives that
live one level down (e.g. `crypto.hash.sha2.Sha256`).

---

## Stream ciphers

Encrypt a stream of bytes. No authentication — pair with a MAC or use an AEAD instead.

| name | doc |
|---|---|
| ChaCha20IETF | IETF-variant of ChaCha20, as designed for TLS (96-bit nonce) |
| ChaCha20With64BitNonce | Original ChaCha20 (64-bit nonce, faster for large data) |
| ChaCha8IETF | ChaCha20 reduced to 8 rounds — faster, experimental |
| ChaCha12IETF | ChaCha20 reduced to 12 rounds — faster, reduced security margin |
| XChaCha20IETF | XChaCha20: extended nonce (192-bit), safe for random nonce generation |
| XChaCha8IETF | XChaCha20 reduced to 8 rounds |
| XChaCha12IETF | XChaCha20 reduced to 12 rounds |
| Salsa20 | The Salsa cipher with 20 rounds (predecessor to ChaCha) |
| Salsa | Salsa cipher, parameterised (lower-level than Salsa20) |
| XSalsa20 | Salsa20 with extended nonce |
| XSalsa | XSalsa, parameterised |
| ChaCha8With64BitNonce | ChaCha20 reduced to 8 rounds, 64-bit nonce |
| ChaCha12With64BitNonce | ChaCha20 reduced to 12 rounds, 64-bit nonce |

**Which to use:** `ChaCha20IETF` for compatibility (TLS); `XChaCha20IETF` when
generating random nonces (the larger nonce space makes collisions negligible).
**Never use stream ciphers alone** — combine with Poly1305 or use an AEAD.

---

## AEAD (Authenticated Encryption with Associated Data)

Encrypt AND authenticate in one step. This is what you almost always want.
An AEAD is a stream cipher + MAC composed correctly — you can't forget the MAC.

| name | doc |
|---|---|
| ChaCha20Poly1305 | ChaCha20 + Poly1305, designed for TLS. The standard choice. |
| XChaCha20Poly1305 | XChaCha20 + Poly1305, extended nonce. Good for random nonces. |
| ChaCha8Poly1305 | Reduced rounds — faster, experimental |
| ChaCha12Poly1305 | Reduced rounds — faster, experimental |
| XChaCha8Poly1305 | Extended nonce, reduced rounds |
| XChaCha12Poly1305 | Extended nonce, reduced rounds |
| XSalsa20Poly1305 | Salsa20 + Poly1305 (NaCl/libsodium heritage) |
| Aegis128L | AEGIS-128L, 128-bit tag. Very fast on modern hardware with AES-NI. |
| Aegis128L_256 | AEGIS-128L, 256-bit tag |
| Aegis256 | AEGIS-256, 128-bit tag, 256-bit key |
| Aegis256_256 | AEGIS-256, 256-bit tag |
| Aegis128X2 | AEGIS-128X2, 128-bit tag (SIMD variant) |
| Aegis128X4 | AEGIS-128X4, 128-bit tag (wide SIMD) |
| Aegis256X2 | AEGIS-256X2 (SIMD variant) |
| Aegis256X4 | AEGIS-256X4 (wide SIMD) |
| AsconAead128 | Ascon-AEAD128 — NIST SP 800-232, lightweight/IoT focused |
| Aes128Gcm | AES-128-GCM — standard AEAD, TLS-compatible |
| Aes256Gcm | AES-256-GCM |
| Aes128GcmSiv | AES-128-GCM-SIV — nonce-misuse resistant |
| Aes256GcmSiv | AES-256-GCM-SIV — nonce-misuse resistant |
| Aes128Ocb | AES-128-OCB — fast, patent-cleared (RFC 7253) |
| Aes256Ocb | AES-256-OCB |
| Aes128Siv | AES-128-SIV — deterministic, nonce-misuse resistant |
| Aes256Siv | AES-256-SIV |
| Aes128Ccm16 | AES-128-CCM, 16-byte tag (IoT/embedded, RFC 3610) |
| Aes128Ccm8 | AES-128-CCM, 8-byte tag |
| Aes128Ccm0 | AES-128-CCM*, no authentication (encryption-only — avoid) |
| Aes256Ccm16 | AES-256-CCM, 16-byte tag |
| Aes256Ccm8 | AES-256-CCM, 8-byte tag |
| Aes256Ccm0 | AES-256-CCM*, no authentication (avoid) |
| IsapA128A | ISAP — hardened against side-channel attacks |

**Which to use:** `ChaCha20Poly1305` is the safe default (standard, well-understood).
`Aegis128L` is fastest if you have AES-NI hardware. Avoid the `Ccm0` variants
(no authentication). `AsconAead128` for constrained/IoT environments.

---

## Hashing

One-way transformation. No key. Used for integrity, not secrecy.

| name | doc |
|---|---|
| Blake3 | BLAKE3 — fast, modern, 256-bit digest. The current best choice. |
| KT128 | KangarooTwelve — fast tree-hashing, 128-bit security |
| KT256 | KangarooTwelve — 256-bit security variant |
| AsconHash256 | Ascon-Hash256 — NIST SP 800-232, lightweight |
| AsconXof128 | Ascon-XOF128 — extendable output function |
| AsconCxof128 | Ascon-CXOF128 — customizable XOF |
| Md5 | MD5 — **broken for security use**. Legacy/compatibility only. |
| Sha1 | SHA-1 — **broken for security**. Legacy/compatibility only. |
| Ascon | Ascon permutation — low-level building block for Ascon family |

**Note:** SHA-256, SHA-512, SHA-3 are in sub-namespaces (crypto.hash.sha2, etc.),
not top-level — see the sub-namespaces section.

**Which to use:** `Blake3` for new code. SHA-256 for interoperability (TLS, certificates).
Never MD5 for security purposes.

---

## MACs (Message Authentication Codes)

Keyed hash — proves a message came from someone with the key and wasn't modified.
A MAC alone provides authentication but not secrecy (message is still visible).

| name | doc |
|---|---|
| Ghash | GHASH — universal hash for AES-GCM. Usually used internally. |
| Polyval | POLYVAL — similar to GHASH, used in AES-GCM-SIV |
| Poly1305 | Poly1305 MAC — authenticate a message with a one-time key |
| CbcMacAes128 | CBC-MAC with AES-128 (FIPS 113) |
| CmacAes128 | CMAC with AES-128 (RFC 4493) |
HkdfSha256 and HkdfSha512 are KDFs (below), not MACs, despite using HMAC internally.

---

## KDF (Key Derivation Functions)

Turn a shared secret or password into a cryptographic key.

| name | doc |
|---|---|
| HkdfSha256 | HKDF with SHA-256 — derive keys from existing key material |
| HkdfSha512 | HKDF with SHA-512 |

---

## Password hashing

Like hashing, but intentionally slow and memory-hard to resist brute force.
**Do not use a regular hash (Blake3, SHA-256) to hash passwords** — use these.

| name | doc |
|---|---|
| Params (Argon2) | Argon2 parameters — memory, iterations, parallelism |
| Mode (Argon2) | Argon2 type: Argon2d, Argon2i, Argon2id |
| HashOptions | Options for password hashing (Argon2 / scrypt / bcrypt) |
| VerifyOptions | Options for password verification |

**Note:** The actual `argon2`, `scrypt`, `bcrypt` functions live in sub-namespaces.
The top-level only exports their parameter types.

---

## Key exchange

Two parties derive the same shared secret without ever sending the secret itself.

| name | notes |
|---|---|
| X25519 | Diffie-Hellman key exchange on Curve25519 — the standard choice |
| Curve25519 | Low-level Curve25519 point operations |
| Edwards25519 | Edwards-curve form of Curve25519 (used by Ed25519 internally) |
| Ristretto255 | Prime-order group built on Curve25519 (avoids cofactor pitfalls) |
| P256 | NIST P-256 elliptic curve key exchange |
| P384 | NIST P-384 elliptic curve key exchange |
| Secp256k1 | Secp256k1 curve (Bitcoin/Ethereum key exchange) |
| Box | NaCl-compatible box API — X25519 + XSalsa20-Poly1305 composed |
| SealedBox | Anonymous sender version of Box (no sender authentication) |
| SecretBox | Symmetric secretbox — single shared key (no key exchange) |

---

## Signatures (Digital)

Prove a message was signed by someone with a specific private key.
Authentication, not secrecy — the message is still visible.

| name | doc |
|---|---|
| EcdsaP256Sha256 | ECDSA over P-256 with SHA-256 — standard in TLS/X.509 |
| EcdsaP256Sha3_256 | ECDSA over P-256 with SHA3-256 |
| EcdsaP384Sha384 | ECDSA over P-384 with SHA-384 |
| EcdsaP384Sha3_384 | ECDSA over P-384 with SHA3-384 |
| EcdsaSecp256k1Sha256 | ECDSA over Secp256k1 — Bitcoin/Ethereum curve |
| EcdsaSecp256k1Sha256oSha256 | Bitcoin signature system |
| MLDSA44 | ML-DSA-44 — post-quantum signature (NIST standard) |
| MLDSA65 | ML-DSA-65 — post-quantum signature |
| MLDSA87 | ML-DSA-87 — post-quantum signature |
| PKCS1v1_5Signature | RSA-PKCS1-v1_5 (RFC 3447) — legacy |
| PSSSignature | RSA-PSS (RFC 3447) — modern RSA signatures |

| Ed25519 | Edwards-curve Digital Signature Algorithm — the modern standard |

**Note:** Ed25519 is a top-level export (confirmed against source). The
KeyPair/PublicKey/SecretKey/Signature types appear multiple times (once per family).

---

## Post-quantum / Hybrid KEM

Key encapsulation mechanisms — the post-quantum replacement for key exchange.

| name | doc |
|---|---|
| MlKem768X25519 | ML-KEM-768 + X25519 (X-Wing) — hybrid, ~128-bit post-quantum security |
| MlKem768P256 | ML-KEM-768 + P-256 — hybrid, ~128-bit |
| MlKem1024P384 | ML-KEM-1024 + P-384 — hybrid, ~192-bit |

**Note:** These are hybrid schemes — they combine classical (X25519/P-256) with
post-quantum (ML-KEM) for defense-in-depth during the transition period.

---

## Configuration / utilities

| name | what it is |
|---|---|
| SideChannelsMitigations | Enum controlling side-channel countermeasure level (none / medium / full) |
| Certificate | X.509 certificate parsing — used by TLS |

---

## Error types

| name | meaning |
|---|---|
| AuthenticationError | MAC verification failed |
| SignatureVerificationError | Signature doesn't verify |
| PasswordVerificationError | Password doesn't match the hash |
| EncodingError | Encoded input cannot be decoded |
| NonCanonicalError | Encoded input is not in canonical form |
| WeakParametersError | Parameters would be insecure |
| WeakPublicKeyError | Public key would be insecure |
| KeyMismatchError | Public and secret key are incompatible |
| IdentityElementError | Finite field op returned the identity element |

---

## Sub-namespaces (not covered above)

These families live in sub-namespaces and need a separate inventory pass:

| namespace | symbols | what's in there |
|---|---|---|
| crypto.25519 | 169 | Curve25519, X25519, Ed25519, scalar arithmetic |
| crypto.aes | 162 | AES block cipher, AES-GCM, AES-OCB |
| crypto.pcurves | 98 | P-256, P-384, Secp256k1 curve operations |
| crypto.codecs | 30 | ASN.1/DER encoding, Base64 (crypto variant) |
| crypto.tls | 3 | TLS-specific helpers |

---

## Sub-namespaces (lowercase exports — groups, not individual primitives)

These are the namespace groups. Their contents are accessed as `crypto.<ns>.*`.

| name | what's inside |
|---|---|
| `aead` | AEAD cipher sub-namespace |
| `aegis` | AEGIS cipher family |
| `aes` | AES block cipher primitives |
| `aes_ccm` | AES-CCM modes |
| `aes_gcm` | AES-GCM |
| `aes_gcm_siv` | AES-GCM-SIV |
| `aes_ocb` | AES-OCB |
| `aes_siv` | AES-SIV |
| `argon2` | Argon2 password hashing |
| `ascon` | Ascon family |
| `auth` | MACs: HMAC, Poly1305 |
| `bcrypt` | bcrypt password hashing |
| `blake2` | BLAKE2 hash family |
| `cbc_mac` | CBC-MAC |
| `chacha` | ChaCha stream ciphers (low-level) |
| `chacha_poly` | ChaCha-Poly1305 AEAD (low-level) |
| `cmac` | CMAC |
| `codecs` | ASN.1/DER, Base64 (crypto variant) |
| `composition` | Hash composition utilities |
| `core` | Core building blocks |
| `dh` | Diffie-Hellman |
| `ecc` | Elliptic curve cryptography |
| `ecdsa` | ECDSA low-level |
| `errors` | Error type definitions |
| `ff` | Finite field arithmetic |
| `hash` | SHA-256, SHA-512, SHA-3, BLAKE2 |
| `hkdf` | HKDF key derivation |
| `hmac` | HMAC |
| `hybrid` | Hybrid KEM |
| `isap` | ISAP authenticated encryption |
| `kdf` | Key derivation functions |
| `keccak` | Keccak permutation |
| `kem` | Key encapsulation |
| `kyber_d00` | Kyber (draft, pre-standard ML-KEM) |
| `ml_kem` | ML-KEM (NIST standard) |
| `mldsa` | ML-DSA (NIST standard) |
| `modes` | Block cipher modes |
| `nacl` | NaCl/libsodium-compatible API |
| `onetimeauth` | One-time authentication |
| `pbkdf2` | PBKDF2 key derivation |
| `phc_format` | PHC string format (password hash encoding) |
| `pwhash` | Password hashing (Argon2, scrypt, bcrypt) |
| `salsa` | Salsa stream ciphers (low-level) |
| `salsa_poly` | Salsa-Poly1305 (low-level) |
| `scrypt` | scrypt password hashing |
| `sha2` | SHA-256, SHA-512 family |
| `sha3` | SHA-3 family |
| `sign` | Digital signatures (Ed25519, ECDSA) |
| `siphash` | SipHash (non-crypto, fast hash for hash maps) |
| `stream` | Stream ciphers (low-level) |
| `timing_safe` | Timing-safe comparison utilities |
| `tls` | TLS helpers |

---

## Summary (cross-checked against source 2026-06-17)

These are **top-level-only** counts (what `crypto.<family>` exports directly), so they
differ from `surface.md` — e.g. Hashing shows 9 here (Blake3, Md5, …) but `surface.md`
reports 43 because it also reaches `crypto.hash.sha2.*`, `sha3.*`, `blake2.*`. For the
authoritative dev-facing counts, use `surface.md`.

| family | named exports |
|---|---|
| AEAD | 33 (inc. AES-GCM/OCB/SIV variants) |
| Stream ciphers | 12 |
| Key exchange + curves | 10 |
| Signatures | 12 (inc. Ed25519) |
| Post-quantum KEM | 3 |
| Hashing | 9 |
| MACs | 5 |
| KDF | 2 |
| Password hashing types | 4 |
| Configuration / utilities | 2 |
| Error types | 9 |
| Sub-namespaces (lowercase) | 53 |
