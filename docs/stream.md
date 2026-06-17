# std.crypto — stream

**Layer:** developer-facing — present in `data/surface.tsv` (primitives a developer calls directly).

A map of the stream-cipher primitives in `std.crypto.stream` for Zig 0.16. This page
adds **nothing** to the standard library — it presents what is already there in a
readable form, with every value traceable to source:

- sizes & signatures — compiler reflection → `data/primitives.tsv`
- definition site & doc-comments — scan of std source → `data/crypto_raw.csv`
- public namespace paths → `data/surface.tsv`

> **Coverage.** This page covers the 3 primitives for which reflection has resolved
> sizes/signatures. The `stream` namespace exposes more variants (full list in
> `docs/surface.md`) — pending resolution, not omitted by choice.

## The map

key / nonce / block are in **bytes**. "—" means the size is not in the resolved set.

| primitive | public path | key | nonce | block | defined in |
|---|---|--:|--:|--:|---|
| ChaCha20IETF | `std.crypto.stream.chacha.ChaCha20IETF` | 32 | 12 | 64 | `crypto/chacha20.zig` |
| XChaCha20IETF | `std.crypto.stream.chacha.XChaCha20IETF` | 32 | 24 | 64 | `crypto/chacha20.zig` |
| Salsa20 | `std.crypto.stream.salsa.Salsa20` | 32 | 8 | — | `crypto/salsa20.zig` |

`key`/`nonce`/`block` = `key_length`/`nonce_length`/`block_length` (resolved in
`data/primitives.tsv`).

## The interface

All 3 expose `xor` (encrypt = decrypt for a stream cipher). ChaCha20IETF and
XChaCha20IETF additionally expose `stream`. Resolved signatures:

```
ChaCha20IETF.xor    ([]u8, []const u8, u32, [32]u8, [12]u8) void
ChaCha20IETF.stream ([]u8, u32, [32]u8, [12]u8) void
XChaCha20IETF.xor   ([]u8, []const u8, u32, [32]u8, [24]u8) void
XChaCha20IETF.stream([]u8, u32, [32]u8, [24]u8) void
Salsa20.xor         ([]u8, []const u8, u64, [32]u8, [8]u8) void
```

Resolved difference: the counter argument is `u32` for the ChaCha variants and
`u64` for Salsa20.

## std doc-comments (verbatim)

All 3 carry a doc-comment.

- **ChaCha20IETF** (`crypto/chacha20.zig`) — "IETF-variant of the ChaCha20 stream cipher, as designed for TLS."
- **XChaCha20IETF** (`crypto/chacha20.zig`) — "XChaCha20 (nonce-extended version of the IETF ChaCha20 variant) stream cipher"
- **Salsa20** (`crypto/salsa20.zig`) — "The Salsa cipher with 20 rounds."

---

*Generated from `data/` (`primitives.tsv`, `surface.tsv`, `crypto_raw.csv`).
Zig 0.16, extracted 2026-06-17. `defined in` paths are relative to `lib/std/`.
Resolvable source links pending the pinned-commit record — see
`PLAN.md` → Traceability requirement.*
