# L3 — Reference graph / tunnels ✅

| | |
|---|---|
| **Question** | what links to what — followable to an address? |
| **Source of truth** | parse (resolve names against a per-file symbol table) → transform |
| **Coverage** | edges (sound, not complete — every unresolved ref recorded) |
| **Build** | `src/tunnels.zig` + `nu scripts/build_tunnels.nu` |
| **Verify** | `scripts/verify_tunnels.nu` (bundled) · rebuild proof: `build_tunnels.nu --check` |

Index: [PLAN.md](../../PLAN.md) · model + geometry: [concepts.md](../concepts.md#the-shape-of-it-positions-overlays-tunnels).

---

## What it is

The linking layer. The [geometry](../concepts.md#the-shape-of-it-positions-overlays-tunnels)
(positions / overlays / tunnels) lives in concepts; this layer *builds* the tunnels — resolving a
referenced name to the canonical logical `path` it points at, so a link is followable in one
O(1) jump, not just a name. Two datasets:

```
tunnels.tsv     from_path · kind · to_path · to_line   (resolved edges)
unresolved.tsv  from_path · kind · raw · reason         (primitive + unresolved, every ref kept)
```

Three edge kinds:
- **alias** — a re-export `pub const X = a.b.C` (from the map's `alias` detail).
- **import** — a whole-file/selective import binding (`nsref` + import-bearing aliases).
- **usage** — a type referenced in a fn signature (param / return type chains).

`to_line` carries the target's container line from [index.tsv](L0-structure.md) where the target
is a container (follow in one jump); it's blank for a leaf target, whose parent block holds it.

On Zig 0.16.0: **5,123 resolved edges** (alias 287, import 6, usage 4,830); **2,639 unresolved +
4,122 primitive** recorded. 2,971 functions carry usage edges.

## Sound, not complete

An edge is emitted resolved **only when the target path actually exists in the map** — the layer
never invents a dangling edge. Everything else is recorded explicitly (with a reason), so
resolved + unresolved partition every reference attempted; nothing is silently dropped.
Completeness can grow later (e.g. multi-hop alias-following for `Cipher.key_length`-style tails)
without ever weakening soundness.

**The resolver leans on a per-file symbol table.** The map is public-only, but Zig name
resolution leans on *private* file-level bindings (`const Allocator = std.mem.Allocator;`). So
`tunnels.zig` parses each file's root for **all** bindings (pub and private) and resolves names
against that + the map. This is what lets `std.BitStack.init(allocator: Allocator)` resolve
`Allocator` → `std.mem.Allocator`. A self-alias `const Ast = @This();` resolves to the file's own
type, not a phantom child.

**What stays unresolved is honest, often informative.** Alias resolution is ~26% (287/1,099):
the majority of unresolved aliases re-export into **private per-OS files** (`darwin`, `openbsd`,
`illumos`, `haiku`, …) that a public-only, single-platform map doesn't contain — so the
unresolved bucket is, in effect, a true map of which platform files `std.c` multiplexes over.
Bare type params (`fn f(comptime T: type, x: T)` → `T`) are correctly "not in scope" (not a
global decl). Primitives (`u8`, `void`) are tagged, not failed.

## Verified six ways

`verify_tunnels.nu` reconciles the overlay with the map a second way: **registration** (every
`to_path` is a real node — no dangling), **from-valid** (every source is a node), **address**
(every carried `to_line` matches the index), **coverage** (the alias+import edges cover *exactly*
the map's 1,099 alias + 6 nsref rows, once each — every re-export accounted, none invented),
**usage-domain** (every usage edge starts at a fn), **pristine** (no duplicate edges).

This is the cross-check the structural map couldn't do: it pressure-tests every `alias` label by
resolving it — a mislabeled alias shows up as dangling/unresolvable. (The earlier `scan.zig`
alias-vs-const tightening was driven by exactly this need.)

*Why this layer matters:* turns the layer-stack into a navigable graph — "go to definition,"
"what uses X," "what does Y pull in" — that the containment tree alone cannot express.
