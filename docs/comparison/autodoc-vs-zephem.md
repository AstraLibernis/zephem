# zephem vs. Zig autodoc — coverage comparison

A point-in-time measurement of what zephem's `std` snapshot captures relative to
Zig's own `autodoc` extraction. This is a **dated audit note**, not a regenerated
artifact: the numbers are pinned to the run below and are not expected to
auto-update.

> **Post-audit drift (as of the shape-model refactor).** This note describes the
> `5dcdc17` snapshot, whose model differs from current HEAD: `nodes.tsv` was then
> **pub-only** and fields lived in a separate `fields.tsv`. The current model includes
> **private** decls (a `vis` column) and folds fields/tags into `nodes.tsv` with facts in
> `attrs.tsv`/`edges.tsv` (no `fields.tsv`). So every figure and the [Reproduction](#reproduction)
> commands below are historical: re-run them on current HEAD and the counts will differ, and the
> `cut -f1 nodes.tsv` step now includes private rows (no longer apples-to-apples without a
> `vis == pub` filter). Left frozen on purpose — to regenerate against current data is a new audit.

| | |
|---|---|
| Measured | 2026-07-07 |
| Zig | 0.16.0 |
| Host triple | x86_64-linux (Hyper-V VM, no GPU) |
| zephem snapshot | `data/std/` at commit `5dcdc17` — `nodes.tsv`, 48,499 rows |
| autodoc source | `/usr/lib/zig/docs/wasm/{Walk,Decl}.zig` from the Zig 0.16.0 install |

Both tools are compared on their **public** declaration surface: zephem's
`nodes.tsv` is pub-only (see `README.md`), and autodoc was walked with
`include_private = false`, so this is an apples-to-apples decl comparison.

---

## How the two sets were obtained

**autodoc.** autodoc does not persist a symbol list. Its browser bundle ships the
std source as a tarball plus a WebAssembly parser (`Walk.zig` + `Decl.zig`) that
re-derives everything in-page on each view. To get its exact reachable set, the
harness at [`autodoc_dump.zig`](./autodoc_dump.zig) drives **autodoc's own
`Walk.zig` and `Decl.zig`** natively — the only change is the allocator
(`std.heap.wasm_allocator` → `std.heap.page_allocator`); the walk logic is
unmodified. It loads every `std/*.zig` file, then BFS-walks the reachable pub-decl
tree exactly as the UI does (`namespace_members` with `include_private = false`,
descending through aliases and type-functions), emitting one fully-qualified name
per decl.

**zephem.** The `path` column of the committed `data/std/extracted/nodes.tsv`.

Both sets are compared as sorted, de-duplicated FQN lists. See
[Reproduction](#reproduction) for the exact commands.

---

## Scorecard

| Metric | Count |
|---|---:|
| **zephem** `nodes.tsv` rows (total) | **48,499** |
| &nbsp;&nbsp;— enum tags | 21,535 |
| &nbsp;&nbsp;— fields | 9,513 |
| &nbsp;&nbsp;— decl-like (fn / const / struct / enum / union / opaque / alias / ns / nsref) | 17,451 |
| **autodoc** reachable pub decls | **18,410** |
| &nbsp;&nbsp;— (out of total decls incl. private) | 35,830 |
| Shared decl paths (after generic-notation normalization) | 15,271 |
| autodoc-only paths | 3,139 |
| zephem-only paths | 33,228 |

Two counts are compared here that measure **different things**, so read them on the
right axis:

- On the **declaration** axis (fn / const / type / alias / namespace), the two tools
  reach a near-identical surface: autodoc 18,410 vs zephem 17,451, with **15,271
  shared**. autodoc's decl walk does *not* emit fields or enum members as their own
  entries — it renders them inside a container's page but they are not navigable,
  queryable rows.
- zephem additionally records **21,535 enum tags** and **9,513 fields** as
  first-class rows. This is the bulk of the 33,228 zephem-only paths and the main
  reason zephem's snapshot has 2.6× the row count. A query like "every field of type
  `usize` in std" is answerable from zephem's `fields.tsv`; autodoc exposes no such
  index.

Beyond node count, zephem also emits layers that autodoc has no analogue for,
because autodoc is a pure AST walk and never runs the compiler: `resolved.tsv`
(compiler-resolved types), `callcard.tsv` (as-written ⋈ resolved), `sigshape.tsv`,
`doccov.tsv`, `consensus.tsv`, `canon.tsv`. These are not counted above.

---

## What the 3,139 autodoc-only paths actually are

Set-differencing found 3,946 paths in autodoc but not in zephem. 807 of those were
purely a **notation** difference: autodoc writes `Aligned.growCapacity` where zephem
writes `Aligned().growCapacity` to mark a generic type-function instantiation.
Normalizing that (`sed 's/()//g'` on zephem's paths) leaves **3,139** genuine
autodoc-only paths. Grouped by second-level namespace:

| Area | Count | Explanation |
|---|---:|---|
| `std.os` | 1,548 | Platform bindings — uefi 585, windows 510, linux 327, emscripten 81, wasi 45 |
| `std.crypto` | 773 | Re-export path differences (see below) |
| `std.c` | 534 | libc bindings across platforms (darwin / openbsd / illumos / windows / …) |
| tail (`multi_array_list`, `deque`, `priority_queue`, `meta`, …) | ~284 | Mix of naming and deep generic members |

These are **not** knowledge autodoc has and zephem lacks. They fall into two
mechanisms:

### 1. Target-conditional platform bindings (~1,500+)

`std.os.uefi` (585), `std.os.windows` (510), `wasi` (45), `emscripten` (81), and the
non-linux `std.c` variants (`darwin` / `openbsd` / `illumos` / …, 285) only exist in
source for *other* compile targets. autodoc is target-blind — it walks the AST and
never evaluates `switch (native_os)`, so it shows the **union of every platform**.
zephem maps the **native resolved view** (x86_64-linux), so these are absent by
design.

This corroborates a scope limit already tracked in `PLAN.md` under "Known
hardening": *"Snapshot target triple is implicit — PINNED records only the Zig
version, but some poison and resolved rows are x86_64-linux-specific."* The
platform-binding delta is the same target-scoping surfacing on the coverage side.

### 2. Re-export path canonicalization (most of `std.crypto`, tails)

The same declaration reached by a different import path. autodoc names by the decl's
**file location**; zephem names by the **canonical namespace** that `crypto.zig`
re-exports it under. A sample of 8 crypto entries:

| autodoc path (file-based) | zephem path (canonical) |
|---|---|
| `crypto.25519.edwards25519.Edwards25519.rejectNonCanonical` | `crypto.ecc.Edwards25519.rejectNonCanonical` |
| `crypto.bcrypt.bcrypt` | `crypto.pwhash.bcrypt.bcrypt` |
| `crypto.hkdf.HkdfSha512` | `crypto.kdf.hkdf.HkdfSha512` |
| `crypto.pcurves.p384.P384.random` | `crypto.ecc.P384.random` |

7 of the 8 sampled were the identical decl under zephem's tidier path; 1
(`ml_kem.d00.Kyber512`) was not located and may be a genuine residue. The sample was
not exhaustive, so a small number of true gaps cannot be ruled out — but the
dominant mechanism in this bucket is path choice, not missing knowledge.

---

## Where autodoc's raw reach is genuinely broader

One axis, and it follows directly from mechanism #1: because autodoc never evaluates
target conditionals, it surfaces the **cross-platform union** of `std.os` / `std.c`
bindings (~1,500 symbol names for uefi / windows / darwin / bsd that do not compile
on the native target). If zephem were ever wanted as a cross-platform symbol
catalog, that is a scope decision — map several targets and merge — not a capability
autodoc has that zephem's pipeline cannot produce. For everything that actually
builds on the snapshot's host triple, zephem is both broader (fields + tags) and
deeper (resolved types) than autodoc's own extraction.

---

## Method limitations

Stated so the numbers are not over-read in either direction:

- **autodoc's count is a slight under-count.** autodoc's `get_type_fn_return_type_fn`
  panics on some type-function nodes in this std (`access of union field 'node'
  while field 'opt_node' is active` — a latent bug in `Decl.zig`). The harness omits
  the "type-fn returning a type-fn" descent hop to avoid it, so a small number of
  deeply-nested generic members autodoc would show are not in its 18,410. Direction:
  this makes autodoc's number conservative-low, i.e. it does not inflate zephem's
  relative standing.
- **Generic-notation normalization** (`s/()//g` on zephem paths) assumes the `()`
  marker is the only systematic notation difference. It is unambiguous in this data
  but is a normalization, not an exact match.
- **Single host triple.** The platform-binding delta is specific to
  x86_64-linux; a different host would shift which `std.os` / `std.c` subtrees land
  in the resolved view.

---

## Reproduction

From a checkout with `data/std/extracted/nodes.tsv` present and Zig 0.16.0 installed:

```sh
cd docs/comparison
ZWASM="$(zig env | sed -n 's/.*\.lib_dir = "\([^"]*\)".*/\1/p')/docs/wasm"

# autodoc's own walker, patched only to use a native allocator
cp "$ZWASM"/Walk.zig "$ZWASM"/Decl.zig .
sed -i 's/const gpa = std.heap.wasm_allocator;/const gpa = std.heap.page_allocator;/' Walk.zig Decl.zig

# emit autodoc's reachable pub-decl set (stderr prints the summary line)
zig run autodoc_dump.zig 2>/dev/null | sort -u > autodoc.txt

# zephem's node paths, and a copy with generic () notation normalized
cut -f1 ../../data/std/extracted/nodes.tsv | tail -n +2 | sort -u > zephem.txt
sed 's/()//g' zephem.txt | sort -u > zephem_norm.txt

# the three set sizes
comm -12 autodoc.txt zephem_norm.txt | wc -l   # shared
comm -23 autodoc.txt zephem_norm.txt | wc -l   # autodoc-only (3,139)
comm -13 autodoc.txt zephem_norm.txt | wc -l   # zephem-only
```

`Walk.zig` and `Decl.zig` are copied from the local Zig install at run time (they
are Zig's own MIT-licensed autodoc sources) and are not vendored into this repo.
Only [`autodoc_dump.zig`](./autodoc_dump.zig), the driver, is committed here.
