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

## Primitives

std.crypto (Zig 0.16) has **154 named primitives** across **10 families**, plus
sub-namespaces holding key things like Ed25519, X25519, SHA-256, and Argon2.

→ **[docs/inventory.md](docs/inventory.md)** — the complete list, every primitive
grouped by family, with a status column tracking what's been documented.

→ **[docs/map.md](docs/map.md)** — the mental model: how the families relate,
which primitives compose correctly, and a quick-decision guide.

---

## The composition rule

The most important thing std.crypto doesn't document: **which primitives belong
together.** A stream cipher alone encrypts but doesn't authenticate. Using the wrong
combination is worse than not encrypting. See `docs/map.md` and (coming) `docs/composition.md`.

## Reference

- Frank Denis, "A tour of std.crypto in Zig 0.7.0" (2020): https://www.youtube.com/watch?v=9t6Y7KoCvyk
- Zig 0.16 std source: `lib/std/crypto.zig` in the Zig installation
- zig.guide crypto page: https://zig.guide/standard-library/crypto/
