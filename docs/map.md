# std.crypto — The Map

This is the mental model. Before reading any of the detailed docs, read this page.
It answers: *what exists, how the pieces relate, and what you actually reach for.*

---

## The three jobs crypto does

Every primitive in std.crypto does one of three jobs:

```
SECRECY      — hide the content of a message
INTEGRITY    — prove the message wasn't tampered with
IDENTITY     — prove who sent the message
```

No single primitive does all three. **Combining them correctly is the whole skill.**

---

## The building blocks

These are the raw primitives. They do one job each.

```
┌─────────────────────────────────────────────────────────────┐
│  STREAM CIPHERS          (secrecy only)                     │
│                                                             │
│  ChaCha20IETF            the standard, TLS-compatible       │
│  XChaCha20IETF           extended nonce, good for files     │
│  Salsa20 / XSalsa20      older, still solid                 │
│                                                             │
│  These encrypt. They do NOT prove the message is intact.    │
│  Never use them alone — use an AEAD (see below).            │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  HASHES                  (integrity, no key)                │
│                                                             │
│  Blake3                  fast, modern, use this             │
│  SHA-256 / SHA-512       in crypto.hash.sha2.*              │
│  SHA-3 family            in crypto.hash.sha3.*              │
│  MD5                     BROKEN — legacy only               │
│                                                             │
│  Anyone can compute a hash. No secret involved.             │
│  Use for: checksums, content addressing, not authentication.│
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  MACs                    (integrity + shared key)           │
│                                                             │
│  Poly1305                the standard MAC for ChaCha20      │
│  GHASH / Polyval         used internally by AES-GCM         │
│  HMAC                    hash-based MAC, in crypto.auth.*   │
│                                                             │
│  A MAC proves the message came from someone with the key.   │
│  No secrecy — the message is still readable.                │
└─────────────────────────────────────────────────────────────┘
```

---

## The composed primitives (what you actually use)

These combine building blocks correctly, so you don't have to.

```
┌─────────────────────────────────────────────────────────────┐
│  AEAD                    (secrecy + integrity, one step)    │
│                                                             │
│  ChaCha20Poly1305        stream cipher + MAC. Use this.     │
│  XChaCha20Poly1305       extended nonce variant             │
│  Aegis128L               fastest on hardware with AES-NI    │
│  Aegis256                256-bit key variant                │
│  AsconAead128            lightweight, IoT/embedded          │
│  AES-GCM                 in crypto.aead.aes_gcm.*           │
│                                                             │
│  AEAD = Authenticated Encryption with Associated Data.      │
│  It encrypts AND authenticates in a single operation.       │
│  If in doubt: ChaCha20Poly1305.                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  HIGH-LEVEL BOXES        (NaCl/libsodium API)               │
│                                                             │
│  SecretBox               encrypt with a shared key          │
│  Box                     encrypt between two key pairs      │
│  SealedBox               anonymous sender version of Box    │
│                                                             │
│  These compose X25519 + XSalsa20Poly1305 for you.           │
│  Easiest to use correctly if you want the libsodium model.  │
└─────────────────────────────────────────────────────────────┘
```

---

## The key primitives (how two parties agree on a secret)

```
┌─────────────────────────────────────────────────────────────┐
│  KEY EXCHANGE                                               │
│                                                             │
│  X25519               in crypto.25519.*                     │
│                                                             │
│  Alice and Bob each have a keypair. They exchange public    │
│  keys. Both compute the same shared secret from the other's │
│  public key + their own private key. An eavesdropper cannot.│
│                                                             │
│  Output: a shared secret. Feed that into HKDF to get a key.│
│  Then use the key with an AEAD to encrypt.                  │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  KEY DERIVATION (KDF)                                       │
│                                                             │
│  HkdfSha256 / HkdfSha512                                    │
│                                                             │
│  Turn a shared secret (from X25519) into a proper key.      │
│  Also: derive multiple keys from one master secret.         │
│  Never use raw key material directly — always derive.       │
└─────────────────────────────────────────────────────────────┘
```

---

## The identity primitives (proving who you are)

```
┌─────────────────────────────────────────────────────────────┐
│  DIGITAL SIGNATURES                                         │
│                                                             │
│  Ed25519              in crypto.sign.Ed25519 (sub-namespace)│
│  ECDSA-P256-SHA256    EcdsaP256Sha256 (TLS certificates)    │
│  ML-DSA               MLDSA44 / MLDSA65 / MLDSA87          │
│                       (post-quantum, NIST standard 2024)    │
│                                                             │
│  Sign with private key. Verify with public key.             │
│  Proves identity. Does NOT hide the message.                │
│  For signing: Ed25519. For certificates (TLS): ECDSA-P256.  │
│  For post-quantum safety: ML-DSA.                           │
└─────────────────────────────────────────────────────────────┘
```

---

## The password primitives

```
┌─────────────────────────────────────────────────────────────┐
│  PASSWORD HASHING                                           │
│                                                             │
│  Argon2               in crypto.pwhash.argon2.*             │
│  scrypt               in crypto.pwhash.scrypt.*             │
│  bcrypt               in crypto.pwhash.bcrypt.*             │
│                                                             │
│  Intentionally slow + memory-hard. Makes brute force costly.│
│  NEVER use Blake3/SHA-256 to store passwords — use Argon2.  │
│  Argon2id is the current recommendation.                    │
└─────────────────────────────────────────────────────────────┘
```

---

## The post-quantum layer

```
┌─────────────────────────────────────────────────────────────┐
│  POST-QUANTUM / HYBRID KEM                                  │
│                                                             │
│  MlKem768X25519       ML-KEM-768 + X25519 (X-Wing)          │
│  MlKem768P256         ML-KEM-768 + P-256                    │
│  MlKem1024P384        ML-KEM-1024 + P-384                   │
│                                                             │
│  These replace X25519 for key exchange against a future     │
│  quantum computer. The hybrid versions run both classical   │
│  and post-quantum so you're safe either way.                │
│  New code that needs long-term key exchange: use X-Wing.    │
└─────────────────────────────────────────────────────────────┘
```

---

## The sub-namespaces (not top-level)

Important things buried one level deeper:

| namespace | what's there |
|---|---|
| `crypto.25519` | X25519 key exchange, Ed25519 signatures, Curve25519 math |
| `crypto.aes` | AES block cipher, AES-GCM, AES-OCB |
| `crypto.hash.*` | SHA-256, SHA-512, SHA-3, BLAKE2 |
| `crypto.auth.*` | HMAC, standalone Poly1305 |
| `crypto.pwhash.*` | Argon2, scrypt, bcrypt |
| `crypto.sign.*` | Ed25519 (the most-used modern signature scheme) |
| `crypto.pcurves` | P-256, P-384, Secp256k1 (elliptic curve math) |
| `crypto.codecs` | ASN.1/DER encoding |
| `crypto.tls` | TLS helpers |

---

## Quick-decision guide

> **"I want to encrypt a message with a shared key"**
> → `ChaCha20Poly1305.encrypt()`

> **"I want to encrypt between two people who've never met"**
> → X25519 key exchange → HKDF → `ChaCha20Poly1305.encrypt()`
> → or just use `Box` (NaCl-style, does all of this for you)

> **"I want to prove I signed a message"**
> → Ed25519 (`crypto.sign.Ed25519`)

> **"I want to hash a file for integrity checking"**
> → `Blake3.hash()`

> **"I want to store a user's password"**
> → Argon2id (`crypto.pwhash.argon2`)

> **"I want to hash a password but I have very little memory"**
> → scrypt or bcrypt

> **"I'm building something that needs to survive quantum computers"**
> → `MlKem768X25519` for key exchange, `MLDSA65` for signatures

---

## The danger zones

These are the mistakes the map is designed to prevent:

| mistake | consequence | correct |
|---|---|---|
| Stream cipher without a MAC | attacker flips bits undetected | use AEAD |
| Reusing a nonce with the same key | key is recoverable | generate fresh nonce every time |
| `std.mem.eql` to compare keys | timing attack leaks the key | `std.crypto.utils.timingSafeEql` |
| Blake3 to hash a password | brute-forceable in seconds | Argon2id |
| Raw X25519 output as a key | biased key material | X25519 → HKDF → key |
| MD5 for security | collision attacks exist | Blake3 or SHA-256 |

---

*Sources: generated from `zfact --dump --module crypto` on Zig 0.16.0, 2026-06-17.
All symbol names confirmed against installed std. See `docs/inventory.md` for the full
flat listing.*
