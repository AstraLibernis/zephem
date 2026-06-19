# L0 — Structure (the full std map) ✅

| | |
|---|---|
| **Question** | where is every public decl, and how is it shaped? |
| **Source of truth** | parse (`std.zig.Ast`) |
| **Coverage** | total |
| **Build** | `nu scripts/build_std.nu` → `data/std/nodes.tsv` + `index.tsv` |
| **Verify** | `scripts/verify_std.nu` (bundled into the build) |

Index: [PLAN.md](../../PLAN.md) · model: [concepts.md](../concepts.md) · proof: [reproducibility.md](../reproducibility.md).

---

## The headline product: the full std map

`nu scripts/build_std.nu` → `data/std/nodes.tsv`, one row per public decl:

```
path · depth · kind · name · n_children · detail
```

- `kind ∈ ns` (an `@import`'d file, expanded) · `nsref` (reference to a file already
  expanded elsewhere — keeps shared imports like `std` from recursing forever) · `nserr`
  (unreadable file) · `struct`/`enum`/`union`/`opaque` (inline container) · `fn` · `const` ·
  `alias` (re-export) · `modref` (module import, not a file we own).
- `n_children` = public decls a container emits as direct children (0 for leaves / nsref /
  nserr). This is what makes the data self-verifying.
- `detail` = std-relative file path (ns/nsref) · param count (fn) · module name (modref).

On Zig 0.16.0: **16,506 decls / 310 files / max depth 8.** Version pinned in `data/std/PINNED`.
(These are the *collapsed-map* figures — the selective re-export fix in `bcf1ce3` folded mislabeled
namespace imports into their resolved targets, lowering the file and depth counts from the pre-collapse
16,631 / 442 / 9.)

---

## Self-verifying: read it forwards, read it backwards

`build_std.nu` bundles two passes that must agree, or it exits non-zero and claims nothing:

- **forward** — `src/scan.zig` parses source → emits rows.
- **backward** — `scripts/verify_std.nu` re-reads the rows grouped by parent path.

Checks (no external tool, no oracle — the data checks itself):

| check | invariant |
|---|---|
| **conservation** | `Σ n_children == rows − 1` (every non-root node is one node's child) |
| **per-node** | for each expanded container, observed children == recorded `n_children` |
| **partition** | `Σ rows-per-kind == total rows` (no unclassified leftovers) |
| **nsref integrity** | every `nsref.detail` file is an expanded `ns.detail` somewhere |

A dropped, double-counted, or truncated decl breaks conservation *and* per-node. This is the
"triangulation from inside the data" the project wanted instead of an external cross-check.

---

## Reading it efficiently: `data/std/index.tsv`

`nodes.tsv` is ~221k tokens — too big to read whole for a narrow question. But pre-order DFS
makes every subtree a **contiguous block**, so `src/index.zig` emits a tiny table of contents
(`path · line · span · depth · kind · n_children`, 1,355 containers). Look up a module, read
exactly its `[line, line+span)` rows — pure arithmetic, no scan. The index self-checks (root
span == total rows; span == 1 + Σ child spans) and `verify_std.nu` re-derives every block's
boundary from `nodes.tsv` depths so the map can never drift from the data.

This contiguous-block address is also what makes [tunnels](L3-tunnels.md) O(1) to follow.
