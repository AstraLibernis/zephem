# How the data flows (the whole picture, on one page)

zephem can *feel* like many files rotating over the same thing. They don't. There is **one
source**, read **two ways**, producing **two spines** plus a few overlays, reconciled by **one
join**. Every arrow points one direction — it's a star, not a loop.

## The shape

```mermaid
flowchart TD
  SRC["ZIG STD SOURCE\n270 .zig files"]

  SRC --> TEXT["① READ IT AS TEXT\nparse the AST · never runs · sees ALL of std"]
  SRC --> COMP["② RUN THE COMPILER\nreflect · runs it · dies on 'poison' decls"]

  %% text side
  TEXT --> scan[scan.zig]
  TEXT --> enrich[enrich.zig]
  TEXT --> tunnels[tunnels.zig]
  scan --> nodes[("nodes.tsv\n16,506\nTHE MAP — spine")]
  enrich --> decls[("decls.tsv\n7,143\nsigs + docs (overlay)")]
  tunnels --> tun[("tunnels.tsv\n5,123\nlinks between names (overlay)")]
  nodes --> index[index.zig] --> idx[("index.tsv\n1,355\nnav cache OF the map")]

  %% compiler side
  COMP --> resolve[resolve.zig]
  resolve --> resolved[("resolved.tsv\n15,720\nreal values, generics expanded — 2nd spine")]
  resolve --> poison[("poison.tsv\n31\ncouldn't run here (ledger)")]

  %% the one join
  nodes --> canon[["canon.tsv\n18,802 — the JOIN\nreads no source, runs no compiler"]]
  resolved --> canon
  poison --> canon

  canon --> b1["read+run · 13,424\ntext & compiler agree"]
  canon --> b2["run-only · 2,296\ncompiler MADE it (generic members)"]
  canon --> b3["read-only · 3,082\ntext saw it, compiler can't run it here"]

  classDef spine fill:#1f6f43,stroke:#0b3,color:#fff,font-weight:bold;
  classDef join fill:#274b8f,stroke:#5af,color:#fff,font-weight:bold;
  class nodes,resolved spine;
  class canon join;
```

## Same thing in plain text (if mermaid doesn't render)

```
                          ZIG STD SOURCE  ·  270 .zig files
                                     │
                  the only two ways to learn anything about it
                                     │
            ┌────────────────────────┴────────────────────────┐
     ① READ IT AS TEXT                                 ② RUN THE COMPILER
     parse the AST — never runs it,                    runs it, so it dies on
     so it sees ALL of std                             un-runnable ("poison") decls
            │                                                  │
     ┌──────┼──────────┬───────────┐                          │
     ▼      ▼          ▼           ▼                       resolve.zig
   scan   enrich    tunnels      index                        │
     │      │          │           │                   ┌──────┴──────┐
     ▼      ▼          ▼           ▼                    ▼             ▼
  [nodes] decls    tunnels     index               [resolved]     poison
   16,506  7,143    5,123       1,355                15,720          31
   THE MAP sigs+    links       nav-cache            real values   couldn't
  (spine)  docs     between     OF the map           generics      run here
                    names       (derived)            expanded
           (overlays, keyed to the map by `path`)    (2nd spine)
           │                                                │
           └──────── two spines + poison meet in ───────────┘
                          exactly ONE place
                                  ▼
                            [ canon.tsv ]  18,802   ← a JOIN, not a new reader
                                  │
                  ┌───────────────┼────────────────┐
                  ▼               ▼                 ▼
              read+run        run-only          read-only
              13,424          2,296             3,082
              both agree      compiler made it  text-only / poison
```

## How to read it

- **Two readers, two spines.** `scan.zig` reads the *text* → `nodes.tsv` (the map). `resolve.zig`
  *runs the compiler* → `resolved.tsv` (resolved values). Everything else hangs off these two.
- **Overlays are extra facts on the same spine**, keyed by `path` so they join cleanly: `decls`
  (signatures/docs), `tunnels` (link edges), `index` (a navigation cache derived from the map).
  They are *not* re-collections of the map — each is a different fact.
- **`canon.tsv` is a view, not a collector.** It opens `nodes` + `resolved` + `poison` and labels
  every name by which reader can see it. It reads no `.zig` and runs no compiler.

## "Are we rotating over the same data?" — the honest answer

No circle exists in the data — every arrow points down. The repetition you can *feel* is real but
lives in two specific places, and neither is the data model:

1. **The source is parsed three times** (scan / enrich / tunnels) — but for three *different* facts
   (structure / signatures / link-edges). Same book, three different questions.
2. **Many checks reconcile the same two spines** (`verify_*` + `canon`). These are *verifications*,
   not new data — they prove the pile agrees with itself. That's where it feels circular.

So the surface area is in the number of **checks**, not in the flow. If we wanted to shrink it, the
one real redundancy is that `verify_layers.nu`'s coverage-delta section now overlaps `canon.tsv`
(canon *persists* the classification verify_layers computed on the fly) — that section can be
retired and pointed at canon.
