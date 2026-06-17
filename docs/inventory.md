# std.crypto inventory — Zig 0.16

Generated from `zfact --dump --module crypto`. Total: 1,258 symbols across all
sub-namespaces; 154 named top-level primitives (uppercase consts = the usable APIs).

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
| XSalsa20 | Salsa20 with extended nonce |

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
| CbcMacAes128 | CBC-MAC with AES-128 (FIPS 113) |
| CmacAes128 | CMAC with AES-128 (RFC 4493) |

**Note:** Poly1305 is a function (fn), not a const — it's in the `fn` symbols.
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
| Box | NaCl-compatible box API — X25519 + XSalsa20-Poly1305 composed |
| SealedBox | Anonymous sender version of Box (no sender authentication) |
| SecretBox | Symmetric secretbox — single shared key (no key exchange) |

**Note:** X25519 itself (the raw key exchange primitive) lives in `crypto.25519`.

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

**Note:** Ed25519 (the most common modern signature) lives in `crypto.sign.Ed25519`,
not top-level. The KeyPair/PublicKey/SecretKey/Signature types appear multiple times
(once per signature family).

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

## Summary counts (Phase 1 complete)

| family | count |
|---|---|
| AEAD | 24 |
| Stream ciphers | 9 |
| Signatures | 11 |
| Post-quantum KEM | 3 |
| Password hashing types | 6 |
| Hashing | 7 |
| MACs | 4 |
| KDF | 2 |
| Key exchange (high-level) | 3 |
| Error types | 9 |
| Sub-namespaces (to explore) | 5 |
