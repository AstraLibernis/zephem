# Using the std map

Two files, produced together by `nu scripts/build_std.nu`:

| file | what it is | size |
|---|---|---|
| `data/std/nodes.tsv` | the full map — one row per public decl in std | ~16.6k rows / ~221k tokens |
| `data/std/index.tsv` | the table of contents — where each container's block lives | ~1.5k rows / ~5k tokens |

The point: **never read `nodes.tsv` whole.** Read the small `index.tsv`, find what you want,
then pull only that block. Every subtree is a contiguous run of rows, so a block is just
`[line, line + span)`.

## Columns

`nodes.tsv` — `path · depth · kind · name · n_children · detail`
`index.tsv` — `path · line · span · depth · kind · n_children`  (containers only)

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

## From any tool (not just Nushell)

`index.tsv` gives a line range, so any line-addressable reader works:
- editor / `Read`: open `nodes.tsv` at `offset = line`, `limit = span`
- `sed -n "${line},$((line+span-1))p" data/std/nodes.tsv`

## Regenerate

After a Zig upgrade (or to rebuild from scratch):
```nu
nu scripts/build_std.nu          # scan → index → verify; refuses to ship if they disagree
```
Output is deterministic (byte-identical on the same Zig) and the version is pinned in
`data/std/PINNED`. See **[README.md](README.md)** for how the self-verification works.
