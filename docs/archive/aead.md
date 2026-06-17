# std.crypto — aead

**Layer:** developer-facing — present in `data/surface.tsv` (primitives a developer calls directly).

A map of the AEAD (authenticated encryption with associated data) primitives in
`std.crypto.aead` for Zig 0.16. This page adds **nothing** to the standard library —
it presents what is already there in a readable form, with every value traceable to
source:

- sizes & signatures — compiler reflection → `data/primitives.tsv`
- definition site & doc-comments — scan of std source → `data/crypto_raw.csv`
- public namespace paths → `data/surface.tsv`

> **Coverage.** This page covers the 9 primitives for which reflection has resolved
> sizes/signatures. The `aead` namespace exposes more variants (full list in
> `docs/surface.md`) — pending resolution, not omitted by choice.

> **Template note.** Unlike `hash.md`/`mac.md`, doc-comments are listed in their own
> section below rather than inline, because some are multi-paragraph. Structural
> facts stay in the table.

## The map

key / nonce / tag are in **bytes**.

| primitive | public path | key | nonce | tag | defined in |
|---|---|--:|--:|--:|---|
| Aegis128L | `std.crypto.aead.aegis.Aegis128L` | 16 | 16 | 16 | `crypto/aegis.zig` |
| Aegis256 | `std.crypto.aead.aegis.Aegis256` | 32 | 32 | 16 | `crypto/aegis.zig` |
| Aes128Gcm | `std.crypto.aead.aes_gcm.Aes128Gcm` | 16 | 12 | 16 | `crypto/aes_gcm.zig` |
| Aes256Gcm | `std.crypto.aead.aes_gcm.Aes256Gcm` | 32 | 12 | 16 | `crypto/aes_gcm.zig` |
| Aes256GcmSiv | `std.crypto.aead.aes_gcm_siv.Aes256GcmSiv` | 32 | 12 | 16 | `crypto/aes_gcm_siv.zig` |
| AsconAead128 | `std.crypto.aead.ascon.AsconAead128` | 16 | 16 | 16 | `crypto/ascon.zig` |
| ChaCha20Poly1305 | `std.crypto.aead.chacha_poly.ChaCha20Poly1305` | 32 | 12 | 16 | `crypto/chacha20.zig` |
| XChaCha20Poly1305 | `std.crypto.aead.chacha_poly.XChaCha20Poly1305` | 32 | 24 | 16 | `crypto/chacha20.zig` |
| IsapA128A | `std.crypto.aead.isap.IsapA128A` | 16 | 16 | 16 | `crypto/isap.zig:21` |

`key`/`nonce`/`tag` = `key_length`/`nonce_length`/`tag_length` (resolved in
`data/primitives.tsv`). Aegis128L, Aegis256 and AsconAead128 additionally resolve a
`block_length` (32, 16, 16 respectively).

## The common interface

Reflection shows all 9 types expose exactly two entry points — no `init`/`update`,
no streaming. Resolved shape (sizes shown for ChaCha20Poly1305; per-type sizes per
the table above):

```
encrypt(c: []u8, tag: *[16]u8, m: []const u8, ad: []const u8,
        npub: [12]u8, key: [32]u8) void
decrypt(m: []u8, c: []const u8, tag: [16]u8, ad: []const u8,
        npub: [12]u8, key: [32]u8) error{AuthenticationFailed}!void
```

`decrypt` returns `error{AuthenticationFailed}!void` (resolved). This is the
`encrypt`/`decrypt` shape — distinct from the hash family's `hash` and the mac
family's `create`.

## std doc-comments (verbatim)

The 3 primitives without an entry (`Aes128Gcm`, `Aes256Gcm`, `Aes256GcmSiv`) ship
no doc-comment in std.

- **Aegis128L** (`crypto/aegis.zig`) — "AEGIS-128L with a 128 bit tag"
- **Aegis256** (`crypto/aegis.zig`) — "AEGIS-256 with a 128 bit tag"
- **AsconAead128** (`crypto/ascon.zig`) — "Ascon-AEAD128 as specified in NIST SP 800-232 Section 4"
- **ChaCha20Poly1305** (`crypto/chacha20.zig`) — "ChaCha20-Poly1305 authenticated cipher, as designed for TLS"
- **XChaCha20Poly1305** (`crypto/chacha20.zig`) — "XChaCha20-Poly1305 authenticated cipher"
- **IsapA128A** (`crypto/isap.zig`):

  > ISAPv2 is an authenticated encryption system hardened against side channels and fault attacks.
  > https://csrc.nist.gov/CSRC/media/Projects/lightweight-cryptography/documents/round-2/spec-doc-rnd2/isap-spec-round2.pdf
  >
  > Note that ISAP is not suitable for high-performance applications.
  >
  > However:
  > - if allowing physical access to the device is part of your threat model,
  > - or if you need resistance against microcode/hardware-level side channel attacks,
  > - or if software-induced fault attacks such as rowhammer are a concern,
  >
  > then you may consider ISAP for highly sensitive data.

---

*Generated from `data/` (`primitives.tsv`, `surface.tsv`, `crypto_raw.csv`).
Zig 0.16, extracted 2026-06-17. `defined in` paths are relative to `lib/std/`.
Resolvable source links pending the pinned-commit record — see
`PLAN.md` → Traceability requirement.*
