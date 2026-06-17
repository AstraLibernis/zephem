# std.crypto — pwhash (password hashing)

**Layer:** developer-facing — present in `data/surface.tsv` (the functions a developer calls directly).

A map of the password-hashing functions in `std.crypto.pwhash` for Zig 0.16. This page
adds **nothing** to the standard library — it presents what is already there in a
readable form, with every value traceable to source.

> **Different shape.** Unlike the other families, `pwhash` exposes **free functions**
> grouped by algorithm, not instantiable primitive types. So this page is a *function
> catalog*, not a size table. Verified by cross-checking the free-fn list in
> `data/surface.tsv` (14 functions) against the resolved signatures in
> `data/primitives.tsv` — they match.

## The catalog

| algorithm | function | role | source |
|---|---|---|---|
| **argon2** | `kdf` | derive raw key bytes | `crypto/argon2.zig` |
| | `strHash` | hash → self-describing PHC string (for storage) | |
| | `strVerify` | check a password against a PHC string | |
| **scrypt** | `kdf` | derive raw key bytes | `crypto/scrypt.zig` |
| | `strHash` / `strHashWithSalt` | hash → PHC string | |
| | `strVerify` | check a password against a PHC string | |
| **bcrypt** | `bcrypt` | raw bcrypt hash | `crypto/bcrypt.zig` |
| | `strHash` / `strHashWithSalt` | hash → PHC string | |
| | `strVerify` | check a password against a PHC string | |
| | `pbkdf` / `opensshKdf` | bcrypt-based key derivation | |
| **(top-level)** | `pbkdf2` | PBKDF2 key derivation | `crypto/pbkdf2.zig` |

Two recurring roles: the `str*` functions store and verify passwords (PHC-format
strings); the `kdf` / `pbkdf` / `pbkdf2` functions derive raw key bytes. Full resolved
signatures — including allocator/`Io` parameters and the (large) error sets — are in
`data/primitives.tsv`.

## std doc-comments (verbatim)

The `argon2` and `scrypt` namespaces carry no top-level doc-comment. Two notable ones:

- **bcrypt** (`crypto/bcrypt.zig`):

  > Compute a hash of a password using 2^rounds_log rounds of the bcrypt key
  > stretching function. bcrypt is a computationally expensive and cache-hard
  > function, explicitly designed to slow down exhaustive searches.
  >
  > The function returns the hash as a `dk_length` byte array, that doesn't include
  > anything besides the hash output.
  >
  > This function was designed for password storage, not for key derivation. For key
  > derivation, use `bcrypt.pbkdf()` or `bcrypt.opensshKdf()` instead.

- **pbkdf2** (`crypto/pbkdf2.zig`):

  > Apply PBKDF2 to generate a key from a password. PBKDF2 is defined in RFC 2898,
  > and is a recommendation of NIST SP 800-132. […] rounds: Iteration count. Must be
  > greater than 0. Common values range from 1,000 to 100,000. […] Prf: Pseudo-random
  > function to use. A common choice is `std.crypto.auth.hmac.sha2.HmacSha256`.

---

*Generated from `data/` (`primitives.tsv`, `surface.tsv`, `crypto_raw.csv`).
Zig 0.16, extracted 2026-06-17. `source` paths are relative to `lib/std/`.
Resolvable source links pending the pinned-commit record — see
`PLAN.md` → Traceability requirement.*
