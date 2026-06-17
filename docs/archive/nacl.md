# std.crypto — nacl (boxes)

**Layer:** developer-facing — present in `data/surface.tsv` (primitives a developer calls directly).

A map of the NaCl "box" primitives in `std.crypto.nacl` for Zig 0.16. This page adds
**nothing** to the standard library — it presents what is already there in a readable
form, with every value traceable to source.

> **Resolved on purpose.** These three were not in the reflection use-set originally;
> they were added to `src/dump.zig` and re-resolved (2026-06-17), so the sizes and
> signatures below are compiler-resolved, not text-scanned.

> **These are compositions.** Reflection shows it directly: all three resolve to
> `salsa20.{Box,SecretBox,SealedBox}` (i.e. XSalsa20-Poly1305), and `Box`/`SealedBox`
> expose a `KeyPair` whose resolved type **is** `X25519.KeyPair`. So the boxes bundle
> key exchange + authenticated encryption into one call.

## The map

all sizes are in **bytes**.

| primitive | public path | key sizes | nonce | overhead | composes | defined in |
|---|---|---|--:|--:|---|---|
| SecretBox | `std.crypto.nacl.SecretBox` | key 32 | 24 | tag 16 | XSalsa20-Poly1305 | `crypto/salsa20.zig:438` |
| Box | `std.crypto.nacl.Box` | public 32, secret 32, shared 32 | 24 | tag 16 | X25519 + XSalsa20-Poly1305 | `crypto/salsa20.zig:472` |
| SealedBox | `std.crypto.nacl.SealedBox` | public 32, secret 32 | — | seal 48 | X25519 + XSalsa20-Poly1305 | `crypto/salsa20.zig:516` |

Sizes resolved in `data/primitives.tsv`. `SealedBox.seal_length = 48` is the total
overhead (ephemeral public key 32 + tag 16); it has no caller-supplied nonce.

## The interface

| primitive | methods |
|---|---|
| SecretBox | `seal(out, msg, nonce, key)`, `open(out, c, nonce, key)` |
| Box | `seal(out, msg, nonce, peer_public, my_secret)`, `open(...)`, `createSharedSecret`, `KeyPair` (= `X25519.KeyPair`) |
| SealedBox | `seal(io, out, msg, recipient_public)`, `open(out, c, recipient_keypair)`, `KeyPair` (= `X25519.KeyPair`) |

`open` returns `error{AuthenticationFailed,...}!void` (resolved). Exact signatures are
in `data/primitives.tsv`.

## std doc-comments (verbatim)

- **SecretBox** (`crypto/salsa20.zig`):

  > NaCl-compatible secretbox API. A secretbox contains both an encrypted message and
  > an authentication tag to verify that it hasn't been tampered with. A secret key
  > shared by all the recipients must be already known in order to use this API.
  > Nonces are 192-bit large and can safely be chosen with a random number generator.

- **Box** (`crypto/salsa20.zig`):

  > NaCl-compatible box API. […] This construction uses public-key cryptography. A
  > shared secret doesn't have to be known in advance by both parties. Instead, a
  > message is encrypted using a sender's secret key and a recipient's public key, and
  > is decrypted using the recipient's secret key and the sender's public key. Nonces
  > are 192-bit large and can safely be chosen with a random number generator.

- **SealedBox** (`crypto/salsa20.zig`):

  > libsodium-compatible sealed boxes. Sealed boxes are designed to anonymously send
  > messages to a recipient given their public key. Only the recipient can decrypt
  > these messages, using their private key. While the recipient can verify the
  > integrity of the message, it cannot verify the identity of the sender. A message
  > is encrypted using an ephemeral key pair, whose secret part is destroyed right
  > after the encryption process.

---

*Generated from `data/` (`primitives.tsv`, `surface.tsv`, `crypto_raw.csv`).
Zig 0.16, extracted 2026-06-17. `defined in` paths are relative to `lib/std/`.
Resolvable source links pending the pinned-commit record — see
`PLAN.md` → Traceability requirement.*
