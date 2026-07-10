---
name: zephem
description: >-
  Use whenever writing, editing, or reviewing Zig (.zig) code and you need a real
  standard-library API — a name, signature, resolved type, error set, struct field, or
  enum tag. Your training knowledge of Zig's fast-moving std is likely stale; zephem
  grounds every std API in a complete, self-verified, regenerable map of the ACTUAL std
  via two lookup tools (zlook, zmap). Reach for it before writing any std call. For the
  common LLM Zig *mistakes* (removed builtins, footguns) and the post-edit check, the
  companion `zcanon` skill covers that.
---

# Looking up Zig's std with zephem

Your memory of Zig's standard library is probably out of date — Zig changes fast and its
std churns. **Do not write std signatures from memory.** Verify against the **zephem map**
— a complete, self-verified, *regenerable* snapshot of the actual std — first. Replace
recall with ground truth.

The query tools **self-locate** — each script finds zephem's data from its own path, so they
work no matter where the repo is cloned, with no env var required. The commands below refer to
the repo as **`$ZEPHEM_HOME`**; set it once to your clone (e.g. `export ZEPHEM_HOME=/path/to/zephem`)
so these invocations run verbatim from any directory. The query tools are two commands:

- **`zlook`** — SIMD-fast keyword search over a baked lookup table, one shot. Also searches
  the **resolved type/error-set** (e.g. find every fn that returns `OutOfMemory`). Run it
  through its wrapper, which compiles the binary once and reuses it:
  ```sh
  nu $ZEPHEM_HOME/query/zlook.nu parse int          # AND of all terms, structured hits
  nu $ZEPHEM_HOME/query/zlook.nu OutOfMemory        # find fns by resolved error set
  nu $ZEPHEM_HOME/query/zlook.nu HashMap get        # a factory member: Type().method
  ```
  (First call compiles `query/zlook.zig` → `~/.config/zephem/zlook` (~1s); every later call
  is the raw binary, single-digit ms. It needs the lookup table — build it once with
  `nu $ZEPHEM_HOME/query/build_lookup.nu`.)
- **`zmap`** — the Nushell equivalent that reads zephem's TSVs directly (no lookup table to
  build); best for browsing a subtree or one exact decl:
  ```sh
  nu $ZEPHEM_HOME/query/zmap.nu find "constant time"   # quote a multi-word term
  nu $ZEPHEM_HOME/query/zmap.nu show std.fmt           # list a whole module/subtree
  nu $ZEPHEM_HOME/query/zmap.nu doc std.fmt.parseInt   # signature + doc for one path
  ```

## Before you write a std API call

1. **Don't know the name?** Search the **complete, verified std map** by keyword. This is
   deterministic — every literal match across all names/signatures/docs is returned, ranked
   name-first (no fuzzy model, no missed answers). **YOU are the semantic layer:** pick the
   mechanism words you'd expect in std's own names/docs ("delimiter", "alloc", "parse",
   "hash"), search, and if nothing lands, rethink the wording and search again. Use
   `zmap show <module>` when you know the neighborhood but not the exact name.

   Hits tagged **`[priv]`** are private decls — real, but *not* callable at the path shown
   from outside their source file (e.g. an internal `const Allocator = std.mem.Allocator`).
   They're demoted below the public API and reported separately, never hidden; don't write a
   call against a `[priv]` path.

2. **Know the name? Look it up** for its exact signature, resolved type, doc, fields/tags,
   and factory members. The map carries everything needed to write the call — the as-written
   signature, the compiler-resolved type/error-set, a struct's field types, an enum's tags,
   and the members a `fn(…) type` factory produces (pathed `Type().method`). Prefer the most
   efficient variant it surfaces (`appendAssumeCapacity` after `ensureTotalCapacity`), not
   just the first thing that compiles.

**The map is the single source of std truth** — no live-lookup fallback, by design (a
shallow fallback would be *less* accurate, defeating the point). It is a **regenerable**
snapshot pinned to a Zig version, so it's authoritative, not a guess. If it's stale — its
`PINNED` zig differs from your installed zig, and the tools warn you — **regenerate it**,
never fall back to memory:
```sh
cd $ZEPHEM_HOME && nu scripts/build_std.nu    # rebuild the map (self-verifies)
nu $ZEPHEM_HOME/query/build_lookup.nu         # refresh zlook's index from it
```

## What this skill does NOT do

It keeps your std API usage current and accurate. It does **not** check your logic, flag the
common Zig footguns, or run the post-edit check — the companion **`zcanon`** skill owns those
(removed builtins like `usingnamespace`, `catch unreachable`, acquire/release pairing, plus
the `zhook` PostToolUse `zig ast-check` + `zsnag` run on every `.zig` edit). The compiler and
tests are the real safety net — compile and run tests before claiming code works.
