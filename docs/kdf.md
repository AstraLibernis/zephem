# std.crypto — kdf

A map of the key-derivation primitives in `std.crypto.kdf` for Zig 0.16. This page
adds **nothing** to the standard library — it presents what is already there in a
readable form, with every value traceable to source:

- sizes & signatures — compiler reflection → `data/primitives.tsv`
- definition site & doc-comments — scan of std source → `data/crypto_raw.csv`
- public namespace paths → `data/surface.tsv`

> **Coverage.** Complete — reflection resolved both primitives the `kdf` namespace
> exposes (cross-check `docs/surface.md`). Note: password-based KDFs (Argon2,
> scrypt, bcrypt, pbkdf2) live under `std.crypto.pwhash`, not here — see
> `docs/pwhash.md`.

## The map

prk is in **bytes**.

| primitive | public path | prk | defined in |
|---|---|--:|---|
| HkdfSha256 | `std.crypto.kdf.hkdf.HkdfSha256` | 32 | `crypto/hkdf.zig:7` |
| HkdfSha512 | `std.crypto.kdf.hkdf.HkdfSha512` | 64 | `crypto/hkdf.zig:10` |

`prk` = `prk_length` (resolved in `data/primitives.tsv`) — the length of the
pseudo-random key produced by `extract`.

## The interface

Both expose the HKDF extract-then-expand pair (no `init`/`update`/`final`). Resolved
signatures (HkdfSha256 sizes shown; HkdfSha512 uses `[64]u8`):

```
extract     ([]const u8, []const u8) [32]u8        // (salt, ikm) -> prk
expand      ([]u8, []const u8, [32]u8) void         // (out, info, prk)
extractInit ([]const u8) Hmac(Sha2x32(…,256))       // streaming extract
```

## std doc-comments (verbatim)

Both carry a doc-comment.

- **HkdfSha256** (`crypto/hkdf.zig`) — "HKDF-SHA256"
- **HkdfSha512** (`crypto/hkdf.zig`) — "HKDF-SHA512"

---

*Generated from `data/` (`primitives.tsv`, `surface.tsv`, `crypto_raw.csv`).
Zig 0.16, extracted 2026-06-17. `defined in` paths are relative to `lib/std/`.
Resolvable source links pending the pinned-commit record — see
`PLAN.md` → Traceability requirement.*
