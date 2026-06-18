# Using the std map

Three files, produced together by `nu scripts/build_std.nu`:

| file | what it is | size |
|---|---|---|
| `data/std/nodes.tsv` | the full map — one row per public decl in std | ~16.6k rows / ~221k tokens |
| `data/std/index.tsv` | the table of contents — where each container's block lives | ~1.5k rows / ~5k tokens |
| `data/std/decls.tsv` | overlay — signature (L1) + doc-comment (L2) per decl, keyed by `path` | ~7.1k rows |

The point: **never read `nodes.tsv` whole.** Read the small `index.tsv`, find what you want,
then pull only that block. Every subtree is a contiguous run of rows, so a block is just
`[line, line + span)`.

## Columns

`nodes.tsv` — `path · depth · kind · name · n_children · detail`
`index.tsv` — `path · line · span · depth · kind · n_children`  (containers only)
`decls.tsv` — `path · doc · sig`  (sparse: a row per fn, plus any documented decl; `doc` lines joined with literal `\n`)

`kind`: `ns` (an @import'd file) · `nsref` (ref to a file expanded elsewhere) · `nserr`
(unreadable) · `struct`/`enum`/`union`/`opaque` (inline container) · `fn` · `const` ·
`alias` (re-export) · `modref` (module import). `line` is the 1-based file line in
`nodes.tsv` (header is line 1). `span` counts the subtree including the node itself.

## Recipes (Nushell)

**1 — Read one module, nothing else.** Look it up, pull its block.
```nu
let b = (open data/std/index.tsv | where path == 'std.crypto.aead' | first)
open data/std/nodes.tsv | skip ($b.line - 2) | first $b.span
# (skip line-2: one for the header, one because skip is 0-based)
```

**2 — Find where something is, by name.** Search the index, not the whole file.
```nu
open data/std/index.tsv | where path =~ 'crypto'        # every crypto-ish container + its block
open data/std/index.tsv | where kind == 'ns'            # every source file (442)
open data/std/index.tsv | sort-by span -r | first 15    # the biggest subtrees (where the bulk is)
```

**3 — Orient before drilling.** What lives directly under a module, and how big is each?
```nu
open data/std/index.tsv | where depth == 1 | select path span n_children | sort-by span -r
```

**4 — Query the full map directly** (when you do want to scan a column, not a subtree).
```nu
open data/std/nodes.tsv | where kind == 'fn' and name == 'parse'     # every pub fn named parse
open data/std/nodes.tsv | where path =~ '^std\.mem\.' and kind == 'fn'
```

**5 — Read *down* the stack: signature + doc for each fn in a module.** Join the overlay.
```nu
let nodes = (open data/std/nodes.tsv)
let decls = (open data/std/decls.tsv)
$nodes | where kind == 'fn' and ($it.path | str starts-with 'std.BitStack.')
  | select path | join $decls path | select path sig doc
```

**6 — The undocumented public API** (holes in the doc overlay).
```nu
let documented = (open data/std/decls.tsv | where doc != '' | get path)
open data/std/nodes.tsv | where kind == 'fn' and ($it.path not-in $documented) | get path
```

## From any tool (not just Nushell)

`index.tsv` gives a line range, so any line-addressable reader works:
- editor / `Read`: open `nodes.tsv` at `offset = line`, `limit = span`
- `sed -n "${line},$((line+span-1))p" data/std/nodes.tsv`

## Regenerate & prove

After a Zig upgrade (or to rebuild from scratch):
```nu
nu scripts/build_std.nu          # scan → index → enrich → verify; refuses to ship if they disagree
nu scripts/build_std.nu --check  # prove the committed snapshot rebuilds byte-for-byte
```
Output is deterministic (byte-identical on the same Zig); the version is pinned in
`data/std/PINNED`, and a `sha256sum -c`-compatible manifest is written to `data/std/SHA256SUMS`
(so `sha256sum -c data/std/SHA256SUMS` works too). `--check` proves rebuildability three ways
— intrinsic (two fresh builds agree), regression (rebuild reproduces the manifest), integrity
(the snapshot matches its manifest). See **[README.md](README.md)** for the self-verification.
