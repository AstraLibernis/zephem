# zcrypto — Plan

**Goal:** A practical, current guide to `std.crypto` in Zig 0.16. Not a reimplementation
of the primitives — an exploration, map, and working reference for how to use them
correctly. The gap we're filling: Frank Denis's tour is from 2020 (Zig 0.7.0) and
assumes crypto expertise. This guide explains the *why*, shows correct composition,
and catches footguns.

**Audience:** A Zig developer who wants to use crypto in their project but doesn't
know what's available or how the pieces fit together.

---

## Phase 1 — Map: what's in std.crypto

**Goal:** A complete inventory of every symbol in std.crypto for Zig 0.16.
No explanations yet — just *what exists*.

Steps:
- [ ] Run `zfact --dump --module crypto` to extract every symbol from std.crypto
- [ ] List all symbols: name, kind (fn / type / const), file, signature
- [ ] Record the raw list in `docs/inventory.md`

**Deliverable:** `docs/inventory.md` — the full flat list, unfiltered.

---

## Phase 2 — Group: organize by family

**Goal:** Take the flat inventory and sort it into meaningful categories.
Understand what *family* each symbol belongs to and why.

Families (expected — confirm against inventory):
- **Stream ciphers** — ChaCha20, XChaCha20, Salsa20, XSalsa20
- **AEAD** (Authenticated Encryption with Associated Data) — ChaCha20Poly1305, AES-GCM, AEGIS
- **Hashing** — Blake3, SHA-256, SHA-512, SHA-3, MD5 (legacy)
- **MACs** (Message Authentication Codes) — Poly1305, HMAC, GHASH
- **Key exchange** — X25519 (Diffie-Hellman on Curve25519)
- **Signatures** — Ed25519
- **Password hashing** — Argon2, scrypt, bcrypt
- **Elliptic curves** — Curve25519, Edwards25519, Ristretto255
- **Utilities** — timingSafeEql, random, encoding helpers

Steps:
- [ ] Assign each symbol from Phase 1 to a family
- [ ] Note symbols that don't fit neatly — they'll need extra explanation
- [ ] For each family: one-paragraph plain-English explanation of what this family *does*
      and when you'd reach for it
- [ ] Update `docs/inventory.md` with groupings

**Deliverable:** `docs/inventory.md` updated with family groupings + family descriptions.

---

## Phase 3 — Investigate: understand each family deeply

**Goal:** For each family, understand the *internals* well enough to explain them.
Use zfact to read signatures, read the std source, understand what each parameter
means and what happens if you use it wrong.

For each family:
- [ ] Read the std.crypto source for that family (via zfact or directly)
- [ ] Identify: what are the inputs? What are the outputs? What are the danger zones?
- [ ] Write a short explanation in `docs/<family>.md`:
      - What this is for (one paragraph)
      - The key concepts (nonce, key, tag, etc.) defined plainly
      - What it pairs with (composition notes)
      - What goes wrong if misused (the footguns)

Order of investigation (start simple, build toward composition):
1. Hashing — simplest, no key, no state. Blake3 first.
2. MACs — like hashing but keyed. Poly1305.
3. Stream ciphers — ChaCha20. The user already has context here.
4. AEAD — ChaCha20-Poly1305. This is where stream + MAC compose.
5. Key exchange — X25519. How two parties agree on a key.
6. Signatures — Ed25519. How you prove identity.
7. Password hashing — Argon2. How you store passwords.
8. Elliptic curves — deeper math, investigate last.

**Deliverable:** `docs/<family>.md` for each family — plain-English explanation,
key concepts, composition notes, footguns.

---

## Phase 4 — Examples: working code per primitive

**Goal:** One minimal, correct, compilable Zig example per primitive.
Not a tutorial — a working snippet showing the simplest correct usage.

For each primitive:
- [ ] Write `examples/<primitive>.zig` — minimal correct usage
- [ ] It must compile and run: `zig run examples/<primitive>.zig`
- [ ] Include a comment showing what the output means
- [ ] Deliberately trigger the footgun in a commented-out block (so the reader
      sees *why* it's wrong, not just that it's wrong)

Examples to build (in order, matching Phase 3):
1. `examples/blake3.zig` — hash a string, print the hex digest
2. `examples/poly1305.zig` — MAC a message, verify it
3. `examples/chacha20.zig` — encrypt + decrypt a message
4. `examples/chacha20poly1305.zig` — AEAD: encrypt + authenticate + decrypt
5. `examples/x25519.zig` — key exchange: Alice + Bob derive the same secret
6. `examples/ed25519.zig` — sign a message, verify the signature
7. `examples/argon2.zig` — hash a password, verify it
8. `examples/secure_channel.zig` — compose X25519 + ChaCha20-Poly1305 + Ed25519
   into a minimal secure channel (the capstone example)

**Deliverable:** `examples/` folder with one working `.zig` file per primitive.

---

## Phase 5 — Composition: the guide nobody wrote

**Goal:** Explain how primitives fit together into real secure systems.
This is the most valuable part — the part Frank Denis's talk didn't cover for learners.

Steps:
- [ ] Write `docs/composition.md`:
      - The layered model: encrypt → authenticate → exchange keys → verify identity
      - What "AEAD" means and why you almost always want it over a raw stream cipher
      - The correct stack for: "I want to encrypt a message" (AEAD alone)
      - The correct stack for: "I want a secure channel between two parties"
        (X25519 key exchange → AEAD for the session)
      - The correct stack for: "I want to prove who sent this"
        (Ed25519 signatures + AEAD)
      - Common wrong combinations and *why* they're wrong
- [ ] Write `docs/footguns.md`:
      - Nonce reuse — what it is, why it's catastrophic
      - Unauthenticated encryption — encrypting without a MAC
      - Timing-unsafe comparison — use `timingSafeEql` not `eql`
      - Raw key bytes as a key — use a KDF (Key Derivation Function)
      - Using MD5/SHA1 for security — they're broken for this purpose

**Deliverable:** `docs/composition.md` and `docs/footguns.md`

---

## Phase 6 — zsnag rules: catch footguns automatically

**Goal:** Add crypto-specific rules to zsnag (in zforge) so the most dangerous
mistakes get flagged automatically on any .zig file that uses std.crypto.

Rules to add:
- [ ] **R011** — ChaCha20 used without Poly1305 (unauthenticated encryption)
- [ ] **R012** — `std.mem.eql` used to compare keys/hashes (timing-unsafe; use `timingSafeEql`)
- [ ] **R013** — hardcoded nonce (all-zero nonce is a common mistake; flag it)

Steps:
- [ ] Add rules to `zforge/src/zsnag.zig`
- [ ] Add test fixtures to `zforge/test_fixtures/`
- [ ] Update `zforge/skill/SKILL.md` with the new rules
- [ ] Run zforge's test suite to confirm 19/19 + new tests pass

**Deliverable:** 3 new zsnag rules in zforge, tested and committed.

---

## Phase 7 — Publish

**Goal:** Ship it. Create the Codeberg repo, push, make it findable.

Steps:
- [ ] Create `AstraLibernis/zcrypto` on Codeberg
- [ ] Push main branch
- [ ] Add a link from zforge's README to zcrypto (related tools)
- [ ] Post to Ziggit as a community resource

**Deliverable:** Live on Codeberg, linked from zforge.

---

## The extraction system (the engine for Phase 3+)

Hand-reading std source per primitive does not scale to ~180 symbols. So the data
is extracted by script, two layers (see `data/README.md`):

- **`scripts/parse_crypto.nu` → `crypto_raw.*`** — text scan, full breadth inventory.
- **`src/dump.zig` + `scripts/build_primitives.nu` → `primitives.*`** — compiler
  reflection over the curated "use" set, giving *resolved* sizes and signatures
  through aliases/generics. This is what text parsing fundamentally cannot do.

Toolchain is Zig (extraction) + Nushell (glue/query) only — no Python, no duckdb.
Phase 3 docs are written by querying `primitives.tsv` in Nushell, not by re-reading
source (e.g. `open data/primitives.tsv | where primitive == 'ChaCha20Poly1305'`).

## Current status

| phase | status |
|---|---|
| 1 — Map | ✅ inventory.md + map.md (179 top-level exports, cross-checked) |
| 2 — Group | ✅ families assigned in inventory.md |
| (system) — Extraction | ✅ reflection dumper + clean datasets (518 resolved rows) |
| 3 — Investigate | ⬜ next — data-driven per-family docs |
| 4 — Examples | not started |
| 5 — Composition | not started |
| 6 — zsnag rules | not started |
| 7 — Publish | not started |

**Start here:** Phase 3 — write `docs/<family>.md` per family, sourced from
`primitives.tsv` (query in Nushell). Order: hash → mac → stream → aead → kdf → kex/kem → sign →
pwhash → curve. Inventory correction to fold in: `KT128`/`KT256` and
`MlKem768X25519` are **not** top-level exports (text-parse artifacts); real path
is `crypto.kem.hybrid.MlKem768X25519`, and KT is not cleanly exposed via std.crypto.
