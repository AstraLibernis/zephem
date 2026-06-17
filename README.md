# zcrypto

A practical guide to `std.crypto` in Zig 0.16 — what's in there, what each
primitive is for, how they compose safely, and minimal working examples.

The only prior deep guide is Frank Denis's "A tour of std.crypto in Zig 0.7.0"
(November 2020). It's authoritative but 6 years old and assumes crypto expertise.
This fills the gap: current (0.16), readable, explains the *why* not just the *what*.

## Structure

```
docs/           — the guide (one file per category of primitive)
examples/       — minimal working Zig code, one file per primitive
src/            — any supporting Zig utilities
```

## Primitives covered (in progress)

| category | primitives | status |
|---|---|---|
| Stream ciphers | ChaCha20, XChaCha20, Salsa20 | — |
| AEAD | ChaCha20-Poly1305, AES-GCM, AEGIS | — |
| Hashing | Blake3, SHA-256, SHA-512, SHA-3 | — |
| MACs | Poly1305, HMAC, GHASH | — |
| Key exchange | X25519 | — |
| Signatures | Ed25519 | — |
| Password hashing | Argon2 | — |
| Utilities | timingSafeEql, random | — |

## The composition rule

The most important thing std.crypto doesn't document: **which primitives belong
together.** A stream cipher alone encrypts but doesn't authenticate. Using the wrong
combination is worse than not encrypting. The docs here explain the correct pairings.

## Reference

- Frank Denis, "A tour of std.crypto in Zig 0.7.0" (2020): https://www.youtube.com/watch?v=9t6Y7KoCvyk
- Zig 0.16 std source: `lib/std/crypto.zig` in the Zig installation
- zig.guide crypto page: https://zig.guide/standard-library/crypto/
