# std.crypto — mac

A map of the message-authentication primitives in `std.crypto` for Zig 0.16. This
page adds **nothing** to the standard library — it presents what is already there in
a readable form, with every value traceable to source:

- sizes & signatures — compiler reflection → `data/primitives.tsv`
- definition site & doc-comments — scan of std source → `data/crypto_raw.csv`
- public namespace paths → `data/surface.tsv`

> **Namespace note.** std does not place these under a single `mac` namespace. It
> splits them across `std.crypto.auth` (HMAC and other keyed MACs) and
> `std.crypto.onetimeauth` (Poly1305, GHASH). The `path` column below shows which.

> **Coverage.** This page covers the 4 primitives for which reflection has resolved
> sizes/signatures. The `auth` and `onetimeauth` namespaces expose more variants
> (full list in `docs/surface.md`) — pending resolution, not omitted by choice.

## The map

tag / key / block are in **bytes**. "—" means std ships no doc-comment, or the size
is not in the resolved set.

| primitive | public path | tag | key | block | defined in | std doc-comment (verbatim) |
|---|---|--:|--:|--:|---|---|
| HmacSha256 | `std.crypto.auth.hmac.sha2.HmacSha256` | 32 | 32 | — | `crypto/hmac.zig:11` | — |
| HmacSha512 | `std.crypto.auth.hmac.sha2.HmacSha512` | 64 | 64 | — | `crypto/hmac.zig:13` | — |
| Poly1305 | `std.crypto.onetimeauth.Poly1305` | 16 | 32 | 16 | `crypto/poly1305.zig` | — |
| Ghash | `std.crypto.onetimeauth.Ghash` | 16 | 16 | 16 | `crypto/ghash_polyval.zig:15` | "GHASH is a universal hash function that uses multiplication by a fixed parameter within a Galois field. It is not a general purpose hash function - The key must be secret, unpredictable and never reused. GHASH is typically used to compute the authentication tag in the AES-GCM construction." |

`tag` = `mac_length`, `key` = `key_length`, `block` = `block_length` (resolved names
in `data/primitives.tsv`). `HmacSha256` and `HmacSha512` additionally define
`key_length_min = 0` (resolved).

## The common interface

Reflection shows all 4 types expose the same four entry points (resolved shapes,
from `data/primitives.tsv`):

```
init(key) Self                  // keyed init
update(*Self, []const u8) void
final(*Self, out) void
create(out, msg, key) void      // one-shot
```

Note the one-shot here is `create` (keyed), where the hash family used `hash`.

Some types expose additional resolved methods:

| primitive(s) | additional methods |
|---|---|
| Poly1305 | `pad` |
| Ghash | `pad`, `initForBlockCount` |

Exact per-type signatures are in `data/primitives.tsv`.

---

*Generated from `data/` (`primitives.tsv`, `surface.tsv`, `crypto_raw.csv`).
Zig 0.16, extracted 2026-06-17. `defined in` paths are relative to `lib/std/`.
Resolvable source links pending the pinned-commit record — see
`PLAN.md` → Traceability requirement.*
