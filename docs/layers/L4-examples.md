# L4 — Examples from tests ▢ (planned)

| | |
|---|---|
| **Question** | how is it actually used — *and does it run?* |
| **Source of truth** | parse + **execute** (`zig test`) |
| **Coverage** | where tests exist |
| **Status** | not started — highest value-per-effort of the remaining layers |

Index: [PLAN.md](../../PLAN.md) · model: [concepts.md](../concepts.md).

---

Extract `test "..." {}` blocks and which decls they exercise, keyed to the
[map](L0-structure.md).

**Verify (the strong one):** run `zig test` and record pass/fail — the knowledge doesn't just
*claim*, it *executes green*. This is the best kind of backward check: the fact is verified by
running it, not by counting.

*Why:* real, compiling, passing usage is the highest-grade knowledge an LLM can be handed.
