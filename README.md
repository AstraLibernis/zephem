# zcrypto

A practical guide to `std.crypto` in Zig 0.16 — what's in there, what each
primitive is for, how they compose safely, and minimal working examples.

The only prior deep guide is Frank Denis's "A tour of std.crypto in Zig 0.7.0"
(November 2020). It's authoritative but 6 years old and assumes crypto expertise.
This fills the gap: current (0.16), readable, explains the *why* not just the *what*.

## Structure

```
docs/map.md         — start here: mental model, families, quick-decision guide
docs/inventory.md   — full flat listing of all 154 named primitives
docs/              — one file per family (in progress)
examples/          — minimal working Zig code, one file per primitive
src/               — any supporting Zig utilities
```

## All 154 named primitives — Zig 0.16

Generated from `zfact --dump --module crypto`. Grouped by family.
Status: `—` = not yet documented, `✓` = guide + example exists.

### Stream ciphers (9)
| name | what it is | status |
|---|---|---|
| ChaCha20IETF | ChaCha20, IETF variant (96-bit nonce), TLS-compatible | — |
| ChaCha20With64BitNonce | ChaCha20, original 64-bit nonce | — |
| ChaCha8IETF | ChaCha20 reduced to 8 rounds (experimental) | — |
| ChaCha12IETF | ChaCha20 reduced to 12 rounds | — |
| XChaCha20IETF | ChaCha20 with extended 192-bit nonce | — |
| XChaCha8IETF | XChaCha20 reduced to 8 rounds | — |
| XChaCha12IETF | XChaCha20 reduced to 12 rounds | — |
| Salsa20 | Salsa cipher, 20 rounds (predecessor to ChaCha) | — |
| XSalsa20 | Salsa20 with extended nonce | — |

### AEAD — Authenticated Encryption with Associated Data (24)
| name | what it is | status |
|---|---|---|
| ChaCha20Poly1305 | ChaCha20 + Poly1305. The standard choice. | — |
| XChaCha20Poly1305 | XChaCha20 + Poly1305, extended nonce | — |
| ChaCha8Poly1305 | Reduced rounds variant | — |
| ChaCha12Poly1305 | Reduced rounds variant | — |
| XChaCha8Poly1305 | Extended nonce, reduced rounds | — |
| XChaCha12Poly1305 | Extended nonce, reduced rounds | — |
| XSalsa20Poly1305 | Salsa20 + Poly1305 (NaCl heritage) | — |
| Aegis128L | AEGIS-128L, 128-bit tag. Fast with AES-NI. | — |
| Aegis128L_256 | AEGIS-128L, 256-bit tag | — |
| Aegis128X2 | AEGIS-128X2, SIMD variant | — |
| Aegis128X2_256 | AEGIS-128X2, 256-bit tag | — |
| Aegis128X4 | AEGIS-128X4, wide SIMD variant | — |
| Aegis128X4_256 | AEGIS-128X4, 256-bit tag | — |
| Aegis256 | AEGIS-256, 128-bit tag, 256-bit key | — |
| Aegis256_256 | AEGIS-256, 256-bit tag | — |
| Aegis256X2 | AEGIS-256X2, SIMD variant | — |
| Aegis256X2_256 | AEGIS-256X2, 256-bit tag | — |
| Aegis256X4 | AEGIS-256X4, wide SIMD variant | — |
| Aegis256X4_256 | AEGIS-256X4, 256-bit tag | — |
| AsconAead128 | Ascon-AEAD128, NIST SP 800-232, lightweight/IoT | — |
| Aes128Ccm16 | AES-128-CCM, 16-byte tag (IoT/embedded) | — |
| Aes128Ccm8 | AES-128-CCM, 8-byte tag | — |
| Aes256Ccm16 | AES-256-CCM, 16-byte tag | — |
| Aes256Ccm8 | AES-256-CCM, 8-byte tag | — |

> Note: `Aes128Ccm0` and `Aes256Ccm0` have no authentication — avoid them.
> AES-GCM lives in `crypto.aead.aes_gcm.*` (sub-namespace, not top-level).

### MACs — Message Authentication Codes (4)
| name | what it is | status |
|---|---|---|
| Ghash | GHASH universal hash — used internally by AES-GCM | — |
| Polyval | POLYVAL — used internally by AES-GCM-SIV | — |
| CbcMacAes128 | CBC-MAC with AES-128 (FIPS 113) | — |
| CmacAes128 | CMAC with AES-128 (RFC 4493) | — |

> Note: Poly1305 and HMAC are functions (`fn`), not consts.
> They live in `crypto.auth.*`.

### Hashing (7)
| name | what it is | status |
|---|---|---|
| Blake3 | BLAKE3 — fast, modern, 256-bit. Use this for new code. | — |
| KT128 | KangarooTwelve, tree-hashing, 128-bit security | — |
| KT256 | KangarooTwelve, 256-bit security | — |
| AsconHash256 | Ascon-Hash256, NIST SP 800-232, lightweight | — |
| AsconXof128 | Ascon extendable output function | — |
| AsconCxof128 | Ascon customizable XOF | — |
| Md5 | MD5 — **broken for security**. Legacy/compatibility only. | — |

> Note: SHA-256, SHA-512, SHA-3, BLAKE2 live in `crypto.hash.*` sub-namespaces.

### KDF — Key Derivation Functions (2)
| name | what it is | status |
|---|---|---|
| HkdfSha256 | HKDF with SHA-256 — derive keys from shared secrets | — |
| HkdfSha512 | HKDF with SHA-512 | — |

### Key exchange — high-level (3)
| name | what it is | status |
|---|---|---|
| Box | NaCl-compatible box: X25519 + XSalsa20Poly1305 composed | — |
| SealedBox | Anonymous sender version of Box | — |
| SecretBox | Symmetric secretbox — single shared key, no key exchange | — |

> Note: Raw X25519 lives in `crypto.25519.*` sub-namespace.

### Signatures — Digital (11)
| name | what it is | status |
|---|---|---|
| EcdsaP256Sha256 | ECDSA over P-256 with SHA-256. Standard in TLS/X.509. | — |
| EcdsaP256Sha3_256 | ECDSA over P-256 with SHA3-256 | — |
| EcdsaP384Sha384 | ECDSA over P-384 with SHA-384 | — |
| EcdsaP384Sha3_384 | ECDSA over P-384 with SHA3-384 | — |
| EcdsaSecp256k1Sha256 | ECDSA over Secp256k1 (Bitcoin/Ethereum curve) | — |
| EcdsaSecp256k1Sha256oSha256 | Bitcoin signature system | — |
| MLDSA44 | ML-DSA-44 — post-quantum signature, NIST 2024 standard | — |
| MLDSA65 | ML-DSA-65 — post-quantum signature | — |
| MLDSA87 | ML-DSA-87 — post-quantum signature | — |
| PKCS1v1_5Signature | RSA-PKCS1-v1_5 (RFC 3447) — legacy RSA | — |
| PSSSignature | RSA-PSS (RFC 3447) — modern RSA signatures | — |

> Note: Ed25519 (most common modern signature) lives in `crypto.sign.Ed25519`.

### Post-quantum / Hybrid KEM (3)
| name | what it is | status |
|---|---|---|
| MlKem768X25519 | ML-KEM-768 + X25519 (X-Wing). ~128-bit post-quantum. | — |
| MlKem768P256 | ML-KEM-768 + P-256. ~128-bit post-quantum. | — |
| MlKem1024P384 | ML-KEM-1024 + P-384. ~192-bit post-quantum. | — |

### Password hashing — types (6)
| name | what it is | status |
|---|---|---|
| Mode | Argon2 type: Argon2d / Argon2i / Argon2id | — |
| Params (Argon2) | Argon2 parameters: memory, iterations, parallelism | — |
| Params (scrypt) | scrypt parameters | — |
| Params (bcrypt) | bcrypt parameters | — |
| HashOptions | Options for password hashing (all three schemes) | — |
| VerifyOptions | Options for password verification | — |

> Note: The actual `argon2`, `scrypt`, `bcrypt` functions live in `crypto.pwhash.*`.

### MACs — AEGIS variants (12)
| name | what it is | status |
|---|---|---|
| Aegis128LMac | AEGIS-128L MAC, 256-bit tags | — |
| Aegis128LMac_128 | AEGIS-128L MAC, 128-bit tags | — |
| Aegis128X2Mac | AEGIS-128X2 MAC, 256-bit tags | — |
| Aegis128X2Mac_128 | AEGIS-128X2 MAC, 128-bit tags | — |
| Aegis128X4Mac | AEGIS-128X4 MAC, 256-bit tags | — |
| Aegis128X4Mac_128 | AEGIS-128X4 MAC, 128-bit tags | — |
| Aegis256Mac | AEGIS-256 MAC, 256-bit tags | — |
| Aegis256Mac_128 | AEGIS-256 MAC, 128-bit tags | — |
| Aegis256X2Mac | AEGIS-256X2 MAC, 256-bit tags | — |
| Aegis256X2Mac_128 | AEGIS-256X2 MAC, 128-bit tags | — |
| Aegis256X4Mac | AEGIS-256X4 MAC, 256-bit tags | — |
| Aegis256X4Mac_128 | AEGIS-256X4 MAC, 128-bit tags | — |

### IsAP (1)
| name | what it is | status |
|---|---|---|
| IsapA128A | ISAP — authenticated encryption hardened against side-channel attacks | — |

### Error types (9)
| name | meaning |
|---|---|
| AuthenticationError | MAC verification failed |
| SignatureVerificationError | Signature doesn't verify |
| PasswordVerificationError | Password doesn't match hash |
| EncodingError | Encoded input cannot be decoded |
| NonCanonicalError | Encoded input not in canonical form |
| WeakParametersError | Parameters would be insecure |
| WeakPublicKeyError | Public key would be insecure |
| KeyMismatchError | Public and secret key are incompatible |
| IdentityElementError | Finite field op returned identity element |

---

## Sub-namespaces (not covered above — Phase 2)

Important things buried one level deeper:

| namespace | symbols | key primitives |
|---|---|---|
| `crypto.25519` | 169 | **X25519** key exchange, **Ed25519** signatures, Curve25519 |
| `crypto.aes` | 162 | AES block cipher, **AES-GCM**, AES-OCB |
| `crypto.hash.*` | — | **SHA-256**, **SHA-512**, SHA-3, BLAKE2 |
| `crypto.auth.*` | — | **HMAC**, standalone **Poly1305** |
| `crypto.pwhash.*` | — | **Argon2**, **scrypt**, **bcrypt** |
| `crypto.sign.*` | — | **Ed25519** |
| `crypto.pcurves` | 98 | P-256, P-384, Secp256k1 math |
| `crypto.codecs` | 30 | ASN.1/DER, Base64 (crypto variant) |
| `crypto.tls` | 3 | TLS-specific helpers |

---

## The composition rule

The most important thing std.crypto doesn't document: **which primitives belong
together.** A stream cipher alone encrypts but doesn't authenticate. Using the wrong
combination is worse than not encrypting. See `docs/map.md` and (coming) `docs/composition.md`.

## Reference

- Frank Denis, "A tour of std.crypto in Zig 0.7.0" (2020): https://www.youtube.com/watch?v=9t6Y7KoCvyk
- Zig 0.16 std source: `lib/std/crypto.zig` in the Zig installation
- zig.guide crypto page: https://zig.guide/standard-library/crypto/
