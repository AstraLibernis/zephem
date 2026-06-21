# L6 — Version diff ▢ (planned)

| | |
|---|---|
| **Question** | what changed between Zig versions? |
| **Source of truth** | transform two pinned snapshots |
| **Coverage** | total |
| **Status** | not started — needs a second pinned snapshot to be interesting |

Index: [PLAN.md](../../PLAN.md) · model: [concepts.md](../concepts.md).

---

Diff two pinned snapshots → added / removed / changed decls: a true changelog, computed not
guessed. This is the real payoff of [ephemeral-by-design](../reproducibility.md) — every
committed snapshot is a pinned version, so the diff between two of them is fact.

**Verify:** the diff is invertible — applying it to the old snapshot reproduces the new one
exactly.

*Why:* migration help grounded in fact, not recollection.
