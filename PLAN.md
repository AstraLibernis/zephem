# zephem — Plan

**What this is.** A data-extraction and transformation tool that, pointed at a Zig source
root, emits pristine, queryable **datasets** describing its **containers, labels, and
levels** — the namespace tree, every public decl classified, and per-container counts. The
product is the datasets *and the pipeline that regenerates them*, never prose.

The intended consumers are LLMs (tidy tables that parse cleanly into context) and humans
using the data as a static research aid.

**Ephemeral by design.** Datasets are derived, regenerable artifacts — never hand-authored.
Any committed dataset is a *pinned snapshot* of one Zig version, a cache of compiler/source
truth, not a canonical hand-maintained source. The invariant: `regenerate && git diff
--exit-code` is clean for a fixed compiler.

**What it is not.** Not a guide, tutorial, or domain advice. **No hand-authored prose.** Any
human-readable view, if ever wanted, is generated from the data — never written by hand.

---

## The method: parse, don't reflect

The general extractor reads source with `std.zig.Ast` instead of walking `@typeInfo`.
Parsing never triggers comptime, so platform-gated and "poison" decls (e.g. `std.c.darwin`'s
`assert(isDarwin())`) are harmless text. **This is the decision that makes mapping all of std
possible** — a reflection walk dies on the first un-evaluatable decl. Reflection is kept only
where it earns its keep (resolved sizes/signatures the source text can't give — the crypto
`depth` layer).

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

On Zig 0.16.0: **16,631 decls / 442 files / max depth 9.** Version pinned in `data/std/PINNED`.

### Self-verifying: read it forwards, read it backwards

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

### Reading it efficiently: `data/std/index.tsv`

`nodes.tsv` is ~221k tokens — too big to read whole for a narrow question. But pre-order DFS
makes every subtree a **contiguous block**, so `src/index.zig` emits a tiny table of contents
(`path · line · span · depth · kind · n_children`, 1,495 containers). Look up a module, read
exactly its `[line, line+span)` rows — pure arithmetic, no scan. The index self-checks (root
span == total rows; span == 1 + Σ child spans) and `verify_std.nu` re-derives every block's
boundary from `nodes.tsv` depths so the map can never drift from the data.

---

## The pristine bar

Every shipped dataset must be:

- **Deterministic** — same Zig version → byte-identical output.
- **Complete or explicitly scoped** — coverage is total, or every exclusion is recorded. No
  silent gaps.
- **Self-verifying** — automated checks built into regeneration (the conservation bundle +
  the index re-derivation above).
- **Idempotent** — `regenerate && git diff --exit-code` is clean.
- **Pinned** — tagged to the exact Zig version the data was extracted from.

---

## Status

| piece | status |
|---|---|
| **std map** (`scan.zig` + bundle) | ✅ full std mapped, self-verifying, deterministic, pinned |
| **table of contents** (`index.zig`) | ✅ contiguous-block index, self-checked both ways |
| crypto reflection pipeline | 🗄️ archived → `archive/crypto-reflection/` (superseded by the scanner) |

## Backlog

- [ ] Point the AST scanner at non-std roots (it is already root-agnostic — needs a config /
      target list to make other modules first-class).
- [ ] Decide: keep committed snapshots tracked, or move generated data to gitignored build
      output with regeneration as the contract.
- [ ] (If ever revived) bring the archived crypto reflection datasets to the pristine bar —
      they resolve byte sizes / signatures the source scan can't.

---

## Superseded

Began as `zcrypto`: first an explanatory guide, then a faithful map of hand-written
per-family docs, then "the datasets are the product." Renamed to **zephem** and reframed on
2026-06-17 — from *learning crypto* to *a general Zig structure-extraction tool*. The pivot
to **AST parsing** (over reflection) followed, making the full-std map the headline product;
the original crypto reflection pipeline was archived to `archive/crypto-reflection/`. Retired
markdown lives in `docs/archive/` (provenance, per archive-don't-delete).

## Toolchain
Zig (AST parsing) + Nushell (glue / query) only. Every dataset under `data/` is regenerable
and idempotent.
