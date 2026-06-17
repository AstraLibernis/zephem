# std.crypto — hash

A map of the hash primitives in `std.crypto.hash` for Zig 0.16. This page adds
**nothing** to the standard library — it presents what is already there in a
readable form, with every value traceable to source:

- sizes & signatures — compiler reflection → `data/primitives.tsv`
- definition site & doc-comments — scan of std source → `data/crypto_raw.csv`
- public namespace paths → `data/surface.tsv`

> **Coverage.** This page covers the 13 primitives for which reflection has
> resolved sizes/signatures. The `hash` namespace exposes more variants
> (full list in `docs/surface.md`) — they are pending resolution, not omitted
> by choice.

## The map

digest / block are in **bytes**. "—" means std ships no doc-comment for that type.

| primitive | public path | digest | block | defined in | std doc-comment (verbatim) |
|---|---|--:|--:|---|---|
| Blake3 | `std.crypto.hash.Blake3` | 32 | 64 | `crypto/blake3.zig:952` | "BLAKE3 is a cryptographic hash function that produces a 256-bit digest by default but also supports extendable output." |
| Md5 | `std.crypto.hash.Md5` | 16 | 64 | `crypto/md5.zig:30` | "The MD5 function is now considered cryptographically broken. Namely, it is trivial to find multiple inputs producing the same hash. For a fast-performing, cryptographically secure hash function, see SHA512/256, BLAKE2 or BLAKE3." |
| Sha1 | `std.crypto.hash.Sha1` | 20 | 64 | `crypto/sha1.zig` | — |
| Sha256 | `std.crypto.hash.sha2.Sha256` | 32 | 64 | `crypto/sha2.zig:23` | — |
| Sha384 | `std.crypto.hash.sha2.Sha384` | 48 | 128 | `crypto/sha2.zig:24` | — |
| Sha512 | `std.crypto.hash.sha2.Sha512` | 64 | 128 | `crypto/sha2.zig:25` | — |
| Sha3_256 | `std.crypto.hash.sha3.Sha3_256` | 32 | 136 | `crypto/sha3.zig:12` | — |
| Sha3_512 | `std.crypto.hash.sha3.Sha3_512` | 64 | 72 | `crypto/sha3.zig:14` | — |
| Shake128 | `std.crypto.hash.sha3.Shake128` | 32 | 168 | `crypto/sha3.zig:19` | — |
| Shake256 | `std.crypto.hash.sha3.Shake256` | 64 | 136 | `crypto/sha3.zig:20` | — |
| Blake2b256 | `std.crypto.hash.blake2.Blake2b256` | 32 | 128 | `crypto/blake2.zig:453` | — |
| Blake2s256 | `std.crypto.hash.blake2.Blake2s256` | 32 | 64 | `crypto/blake2.zig:33` | — |
| AsconHash256 | `std.crypto.hash.ascon.AsconHash256` | 32 | 8 | `crypto/ascon.zig:587` | "Ascon-Hash256 as specified in NIST SP 800-232 Section 5" |

## The common interface

Reflection shows all 13 types expose the same four entry points (resolved shapes,
from `data/primitives.tsv`):

```
init(Options) Self
update(*Self, []const u8) void
final(*Self, out) void
hash([]const u8, out, Options) void
```

Some types expose additional resolved methods:

| primitive(s) | additional methods |
|---|---|
| Blake3 | `initKdf`, `hashParallel`, `finalizeSeek`, `reset` |
| Sha256, Sha384, Sha512, Sha1 | `peek`, `finalResult` |
| Shake128, Shake256 | `squeeze`, `fillBlock` |
| Md5 | `hashResult` |

One resolved-signature difference recorded by reflection: Blake3's `hash` writes
into a `[]u8` slice (`out` is a slice), while the SHA-2 types' `hash` writes into a
fixed `*[N]u8` pointer sized to the digest. Exact per-type signatures are in
`data/primitives.tsv`.

---

*Generated from `data/` (`primitives.tsv`, `surface.tsv`, `crypto_raw.csv`).
Zig 0.16, extracted 2026-06-17. `defined in` paths are relative to `lib/std/`.
Resolvable source links pending the pinned-commit record — see
`PLAN.md` → Traceability requirement.*
