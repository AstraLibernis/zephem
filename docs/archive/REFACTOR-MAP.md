# Refactor Map — scan · enrich · tunnels

First pass: **where everything sits today**, what is duplicated, and the modular
target. No code moved yet — this is the map we refactor against.

## 1. Files today

| file | lines | role | output |
|------|------:|------|--------|
| `src/scan.zig`    | 374 | parse-walk std → structure tree | `nodes.tsv` (path·depth·kind·name·n_children·detail) |
| `src/enrich.zig`  | 341 | parse-walk std → doc/sig overlay | `decls.tsv` (path·doc·sig) |
| `src/tunnels.zig` | 425 | consume `nodes.tsv`, resolve references | tunnel stream (from·kind·status·to_or_raw·reason) |
| `src/resolve.zig` | 134 | **comptime reflect** one container (L5) | `path·kind·detail` — *separate concern, untouched* |
| `src/index.zig`   | 115 | build TOC over `nodes.tsv` (L4) | `path·line·span·depth·kind·n_children` — *separate concern* |

`scan` + `enrich` + `tunnels` = the three being combined. `resolve`/`index` are
downstream consumers and stay as-is for now.

## 2. Decl inventory (line ranges)

### scan.zig
- `Ctx` 44–53 · `dirname` 55–58 · `relPath` 62–66
- `ImportRef`/`parseImport` 73–92 · `isAliasChain` 100–114 · `findDecl` 117–132
- `parseFile` 137–142 · `countPub` 146–159 · `ContainerKind`/`containerKindOf` 161–173
- `emitReexport` 180–250 · `walkMembers` 253–339 · `main` 341–374

### enrich.zig
- `Ctx` 32–38 · `dirname` 40–43 · `ImportRef`/`parseImport` 47–65 · `findDecl` 67–82
- `parseFile` 84–89 · `ContainerKind`/`containerKindOf` 91–103
- `docFirst` 106–112 · `writeDoc` 115–133 · `fnSigSource` 136–144 · `writeSig` 146–162 · `emitDocRow` 165–170
- `emitReexport` 175–238 · `walkMembers` 240–312 · `main` 314–341

### tunnels.zig
- `Target` 35–42 · `Ctx` 44–52 · `dirname` 54–57 · `relPath` 59–63
- `isPrimitive` 66–80 · `isAliasChain` 82–96 · `ImportRef`/`parseImport` 98–115 · `parseFile` 117–120
- `symsOf` 124–175 · `Res` 177–182 · `has` 184–186 · `resolve` 189–255 · `fileOf` 258–265
- `emitEdge` 267–274 · `emitTypeRefs` 279–306 · `walkUsage` 309–331 · `col` 333–342 · `main` 344–425

## 3. Duplication matrix (the "more work than needed")

Shared primitives, copy-pasted across files:

| primitive | scan | enrich | tunnels | notes |
|-----------|:---:|:---:|:---:|-------|
| `dirname`            | 55 | 40 | 54 | identical |
| `relPath`            | 62 | —  | 59 | identical (scan/tunnels) |
| `ImportRef`          | 73 | 47 | 98 | identical |
| `parseImport`        | 75 | 49 | 100| scan==enrich; tunnels adds `isAliasChain(sel)` guard |
| `isAliasChain`       | 100| —  | 82 | identical |
| `findDecl`           | 117| 67 | —  | identical |
| `parseFile`          | 137| 84 | 117| identical (modulo error path) |
| `ContainerKind`/`containerKindOf` | 161 | 91 | — | identical |
| `countPub`           | 146| —  | —  | scan only |
| `col` (TSV reader)   | —  | —  | 333| index.zig re-implements inline |

**The real burden — lock-step traversal.** `scan.emitReexport`/`walkMembers` and
`enrich.emitReexport`/`walkMembers` are the *same* tree walk emitted twice, and
the code comments demand they stay byte-identical in control flow
("MUST mirror its control flow exactly so the collapsed tree … matches"). Any
change to import-collapse or container descent must be made in **two** places or
the overlay desyncs from the map. That is the duplication to kill.

`tunnels` does **not** share this walk — it re-parses files for a pub+private
symbol table (`symsOf`) and walks fn signatures (`walkUsage`). It only shares the
leaf primitives above.

## 4. Implemented layout (as built)

One traversal, many visitors. `build.zig` parses std **once**; the walk drives a
comptime-generic `Visitor`; `map` and `enrich` are visitor implementations that
can no longer desync. `tunnels` keeps its own walk but draws from the shared
primitives. Entry-point mains live at the `src/` root (not a `tools/` subdir):
`zig run` sets the module root to the run-file's directory, so an entry below
`src/` cannot `@import("../…")`. Helpers live in subdirs; entries stay shallow.

```
src/
  build.zig        #  85  combined entry: parse std once → nodes.tsv + decls.tsv
  walk.zig         # 309  the ONE walkMembers + emitReexport, generic over Visitor
  tunnels.zig      # 107  tunnels entry: load map → alias/import/usage edges
  common/
    fs.zig         #  31  dirname, relPath, parseFile
    ast.zig        # 103  ImportRef, parseImport(+guard), isAliasChain, findDecl,
                   #      ContainerKind/containerKindOf, countPub
    tsv.zig        #  15  col() reader
  visit/
    map.zig        #  22  structure visitor → nodes.tsv rows
    enrich.zig     #  97  overlay visitor (docFirst/writeDoc/fnSig/writeSig)
                   #      Node carries ds_ast/ds_tok/proto so enrich reads doc/sig
                   #      off the same walk the map rides
  tunnels/
    resolve.zig    # 199  Target, Res, Ctx, isPrimitive, symsOf, has, resolve, fileOf
    edges.zig      #  77  emitEdge, emitTypeRefs, walkUsage
  index.zig        # 115  unchanged (L4 TOC)
  resolve.zig      # 134  unchanged (L5 comptime reflection)
```

Deleted: `src/scan.zig`, `src/enrich.zig` (folded into `build.zig` + `walk` +
`visit/`). `build_std.nu` now runs `build.zig` once instead of `scan` + `enrich`
(two full re-parses of std → one). `build_tunnels.nu` is unchanged.

## 5. Decisions taken

1. **Visitor shape** — comptime-generic `anytype` (zero-cost, monomorphized).
2. **Combine** — one binary (`build.zig`) emits both datasets in a single parse.
3. **`parseImport`** — unified with the stricter `isAliasChain(sel)` guard.

## 6. Verification

Every dataset reproduces the committed snapshot **byte-for-byte** (std PINNED at
zig 0.16.0, depth 24):

- `nu scripts/build_std.nu --check` → nodes / index / decls ✓
- `nu scripts/build_tunnels.nu --check` → tunnels / unresolved ✓
- full `build_std.nu` + `build_tunnels.nu` backward verifiers (conservation law,
  overlay registration, nsref integrity, no-dup edges) all ✓

`walk.zig` (309) is the one module over the 200-line guideline: `walkMembers` and
`emitReexport` are a single mutually-recursive algorithm (~50 of those lines are
header doc). Splitting them would force a circular cross-file import for no
readability gain — left whole on purpose.
