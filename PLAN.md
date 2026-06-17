# zcrypto — Plan

**What this is.** A data-extraction pipeline that emits pristine, queryable **datasets**
describing exactly what `std.crypto` contains in a given Zig version. The product is the
datasets, not prose. The goal is not to explain what crypto is *for* — it is to record
what is *actually in Zig*, including detailed, cross-cutting facts that are hard to find
or not human-parsable through Zig's autodoc: resolved byte sizes and full signatures
(through aliases and generics), which primitives share an interface, and the complete
structural tree. Built by **compiler reflection**, so the data is the compiler's truth,
not a guess.

**What it is not.** Not a guide, tutorial, or crypto advice. **No hand-authored prose.**
Any human-readable view, if ever wanted, is generated from the data — never written by
hand.

---

## The product: the datasets (`data/`)

| dataset | what it answers | source |
|---|---|---|
| `primitives.tsv` | resolved sizes & signatures per primitive (depth) | reflection |
| `crypto_raw.csv` | every `pub` decl as written, and where (breadth) | text scan |
| `crypto_tree.{tsv,json}` | the full structural tree with per-container counts | reflection |
| `surface.tsv` | the developer-facing surface, labelled | reflection |
| `clusters.tsv` | containers grouped by structural shape | rules |

Schema + query cookbook: `data/README.md`.

---

## The three phases

### 1 — Data Extraction
Pull raw facts out of `std.crypto` with the compiler, not by guessing.
- `scripts/parse_crypto.nu` → text scan (breadth: every decl as written).
- `src/dump.zig` → reflection (depth: resolved const values + typed signatures).
- `src/maptree.zig` → the structural tree with per-container counts.
- `src/surface.zig` → the public, developer-facing surface.

### 2 — Data Organization
Turn raw extraction into clean, reconciled, schema'd tables.
- Normalize resolved type names; strip non-deterministic noise (anonymous
  `__struct_NNNNN` IDs) so output is byte-identical for a fixed compiler.
- Reconcile the text scan against reflection (flag text-only artifacts, e.g. KT128).
- Classify (surface labels, shape clusters).
- One documented schema per dataset.

### 3 — Dataset Creation (pristine)
Ship datasets that meet a hard quality bar. **Pristine** =
- **Deterministic** — same Zig version → byte-identical output.
- **Complete or explicitly scoped** — coverage is total, or every exclusion is recorded
  and asserted. No silent gaps (nacl and P384 were missing and have been added).
- **Self-verifying** — automated checks: every `surface.tsv` entry resolves in
  `primitives.tsv`; row counts asserted; scan ↔ reflection reconciled by script.
- **Idempotent** — `regenerate && git diff --exit-code` is clean.
- **Pinned** — tagged to the exact Zig version/commit the data was extracted from.

---

## Status

| phase | status |
|---|---|
| 1 — Extraction | ✅ text scan + 3 reflection tools (dump / maptree / surface) |
| 2 — Organization | 🟡 schema documented; determinism + reconciliation checks pending |
| 3 — Dataset (pristine) | 🟡 datasets exist; determinism / coverage / verification bar not yet met |

## Open quality work (the backlog)

- [ ] Strip anonymous `__struct_NNNNN` IDs (kills run-to-run churn — observed 2026-06-17).
- [ ] Decide & implement coverage: full public surface vs explicitly-scoped curated set.
- [ ] Close or record `error{inferred}`; record undescended `tls/Certificate`.
- [ ] Add verification checks (resolve-completeness, row counts, scan ↔ reflection).
- [ ] One-command regenerate with an idempotency diff-check.
- [ ] Record the pinned Zig version/commit.
- [ ] Trim the report scripts to emit data only (stop writing `docs/*.md`).

---

## Superseded

This project began as an explanatory guide, then a faithful map of hand-written
per-family docs. Both retired on 2026-06-17: the markdown only ever re-printed the
datasets and went stale. The datasets are the product. All prior docs — the family
pages and the rendered reports (`surface.md`, `structure.md`, `clusters.*`) — are in
`docs/archive/` (provenance, per archive-don't-delete; see `docs/archive/README.md`).

## Toolchain
Zig (reflection extraction) + Nushell (glue / query) only. Every dataset under `data/`
is regenerable and idempotent.
