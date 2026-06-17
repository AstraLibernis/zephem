# zcrypto — Plan

**What this is.** A faithful, navigable map of `std.crypto` as it exists in
Zig 0.16 — a wiki/help layer over the standard library. Easier to read than the
source, but saying nothing the source doesn't. An *index + readable presentation*,
not a guide.

**What it is not.** Not a tutorial, not crypto advice, not a recommendation engine.
The cryptographic *why* (why so many primitives, which to choose, what's safe to
compose) is **not written in std and not ours to invent**. Where std is silent, so
are we — and we link to the primary source instead.

---

## The charter — the rule every page obeys

An entry may contain **only**:

- name, kind, and verified public namespace path (`surface.tsv`)
- resolved signatures & sizes (compiler reflection → `primitives.tsv`)
- the definition site `file:line` in std (`crypto_raw.csv`)
- std's own doc-comment, **quoted verbatim and attributed**
- structural facts reflection proves (aliases, builders, the shared interface)

An entry may **never** contain:

- recommendations or rankings — no "fast / slow / better / default / use X over Y"
- security properties or footguns *in our voice* (length-extension, nonce reuse, …)
- any fact not traceable to std source or a cited primary spec

std's *own* warnings (e.g. MD5 "considered cryptographically broken") are reported
as **quotes in std's voice**, never restated as our advice.

### Traceability requirement (open)

A source link resolves only against a fixed commit. "Zig 0.16" must be pinned to the
exact compiler version/commit the data was extracted from, recorded once and
referenced by every page. **TODO: record the pinned commit.** Until then, pages cite
`file:line` relative to `lib/std/` and flag links as pending.

---

## Status

| phase | status |
|---|---|
| 1 — Map (inventory, mental tree) | ✅ `inventory.md`, `map.md`, `structure.md` |
| 2 — Group by std namespace | ✅ `surface.md` (std's namespaces, not our taxonomy) |
| (system) — Extraction engine | ✅ Zig reflection + Nushell glue; datasets idempotent |
| 3 — Transcribe per family | ⬜ **in progress** — `hash.md` is the template |
| 4 — Empirical (future) | ⬜ run each primitive, capture real output |
| 5 — Publish | ⬜ Codeberg, linked from zforge |

---

## Phase 3 — Transcribe (current)

One page per std namespace family, in the charter style:

- the **map table** — name · public path · sizes · definition site · std doc-comment
- the **resolved API shape** — common interface + per-type extras

…sourced entirely from `primitives.tsv` / `surface.tsv` / `crypto_raw.csv`. No prose
beyond what those sources contain. `docs/hash.md` is the reference template.

Order follows the std namespaces:
`hash → mac → aead → stream → kdf → kex/kem → sign → pwhash → curve`.

## Phase 4 — Empirical (future, not started)

A script that actually **runs** each primitive (hash a known input, etc.) and records
the real output — so the map shows not just the API but what the system literally
produces. The running system is its own source, so this stays inside the charter.
Deferred until the transcription map is complete.

---

## Superseded

The original 7-phase plan aimed to *explain* crypto — investigate footguns, write a
composition guide ("the guide nobody wrote"), add crypto lint rules. That required
authored expertise neither the files nor we can warrant, so it was retired on
**2026-06-17**. Preserved verbatim at `docs/archive/plan-v1-guide.md`. The lint-rule
idea, if ever pursued, belongs to **zforge**, not this map.

## Extraction system

Unchanged — two layers (see `data/README.md`):

- `scripts/parse_crypto.nu` → `crypto_raw.*` — text scan, full breadth inventory.
- `src/dump.zig` + `src/surface.zig` + Nushell → `primitives.*` / `surface.*` —
  compiler reflection over the curated use-set: *resolved* sizes and signatures
  through aliases/generics. What text parsing fundamentally cannot do.

Toolchain is Zig (extraction) + Nushell (glue/query) only.
