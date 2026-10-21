<!-- GENERATED from templates/reflect.tmpl.md by `zephem docs` — edit the template, not this file. -->
# zephem · reflect — the run-it engine

**`reflect/` asks the *compiler* what the parser can't see.** Where [`../parse/`](../parse/)
reads Zig as text (total coverage, never runs it), `reflect/` *evaluates* declarations to
capture their resolved truth — real constant values, expanded generics/aliases, fully-typed
signatures with error sets. It is one of three engines; its outputs live one level up in
[`../data/std/extracted/`](../data/std/extracted/), keyed to the map by the same `path`.

Reflecting evaluates decls, so a platform-gated or `@compileError` ("poison") decl makes a
reflecting program *fail to compile*. That single fact shapes the whole engine: **reflect one
container per subprocess**, so a poison decl kills only its own process and the sweep marches on.
This is the exact opposite trade-off from the parser — depth over totality, bought with isolation.

These rows are **x86_64-linux-specific** (the host recorded in `../data/std/PINNED`): a decl gated
to another target resolves as poison here. Pinned to **zig 0.17.0**.

---

## 1. Purpose — the facts parsing cannot compute

The parser records *what is declared and where*. Reflection records *what it resolves to*:

- **constant VALUES** — the real `Sha256.digest_length = 32`, not the source expression.
- **expanded types** — a generic/alias resolved to its canonical `@typeName`.
- **typed signatures** — a function's fully-resolved type, error set included.

One row per resolved public decl, keyed by the map's `path`:

```
path · kind · detail
```

## 2. What it produces (`../data/std/extracted/`)

Every container in the map is swept, with one of five outcomes — it **resolved**; it is
**partial** (some of its decls fail on their own: they are found by analysing the decls in
halves, and the rest are reflected); it's **poison** (the container itself fails); it's
**private** (reachable only through a private decl, so not reflectable from outside its file);
or it's **skipped** (an uninstantiated `()` factory: no type args, so there is nothing to reflect
yet; a `[…]` switch/if variant: one platform's arm, while the const itself is reflected for this
target, as a decl of its parent; or a private `@"f.zig"` file node, which no expression reaches).

| dataset | purpose | shape |
|---|---|---|
| `resolved.tsv` | the resolved facts — const values, expanded generics, typed fn sigs. `kind ∈ type · const_int · const_bool · fn · const_other` | `path · kind · detail` |
| `poison.tsv` | what *didn't* resolve — a poison container, or a failing decl of a partial one — each with the compiler's own first error line (platform / foreign lib / libc / `@compileError` / timeout) | `path · reason` |
| `status.tsv` | the per-container ledger — one row per attempted container; the verifier re-derives the five buckets from it | `path · status · n_rows` |

On zig 0.17.0: **6,428 containers swept → 3,157 resolved + 18 partial (21,429 rows) / 17 poison + 893 failing decls / 913 private / 2,323 skipped.**

### Planned — the same sweep, more facts

The engine is being **expanded**. The costly part is the reflection sweep itself, so new facts
ride the *same* per-container pass (reflect once, emit more) rather than adding new sweeps:

| dataset | purpose | shape |
|---|---|---|
| `errors.tsv` *(planned)* | the error-set members of each fn — what it can fail with, expanded from inferred/merged sets a parser can't see | `path · error_name` |
| `layout.tsv` *(planned)* | ABI/memory layout: `@sizeOf` / `@alignOf` per type (field `@offsetOf` a later extension) | `path · size · align` |
| `typeinfo.tsv` *(planned)* | the structured `@typeInfo` bits a type name doesn't show — pointer size/const/sentinel, enum tag+exhaustiveness, struct/union layout, int signedness/bits | `path · type_kind · attrs` |

## 3. How it works — the extraction method

**① Batches, with a solo base case.** `resolve.zig` is a *template*. `zephem depth` reuses its
reflection helpers in generated files: first ~50 `export fn` probes per object file, analysis only,
to find the containers that fail (each failing probe reports its own error, attributed by line
range; a batch with an error inside std is split in half); then ~50 clean containers per binary,
each introduced by a `#zephem-target` line. Any batch that cannot be settled splits down to one
container, handled the original way: the template's `TARGET_PATH` / `TARGET` / `SKIP` lines
rewritten for it, compiled and run alone (`--solo` runs every container that way). Both paths
produce byte-identical datasets.

**② Read the type with `@typeInfo`.** For the target type it walks `@typeInfo(T).…decls`, and for
each public decl reads `@TypeOf`/`@field`/`@typeName` — emitting a resolved value (`const_int`,
`const_bool`), a resolved `@typeName` (`type`), or a typed `fn`. It descends **one** level into
non-container types (so `sha2` yields `Sha256` *and* `Sha256.digest_length = 32`), never into child
containers (they reflect on their own turn — `SKIP` prevents double-emission).

**③ Poison is contained, not hunted.** A subprocess that fails to compile is recorded as
`path · reason` with the compiler's first error line, and the sweep continues. Works-or-doesn't is
the whole verdict; a timeout gets its own honest reason (`timeout after Ns`) so it never
masquerades as a compile error.

**④ Data-parallel sweep.** The batches are independent, so they run one lane per CPU, each in its
own scratch file + subprocess; results are placed back in target order, so the bytes match a serial
sweep exactly.

**⑤ Reproducible — with two volatiles normalized out.** `--check` runs two fresh sweeps and diffs
them. Anonymous-type disambiguators (`__struct_NNNN`, a semantic-analysis counter that drifts
between identical compiles) drop their digits; absolute toolchain paths in poison reasons render
relative, and a location inside the generated file drops its line and column (`<gen>: error: …`,
which also makes a batched reason equal the solo one) — without this, byte-for-byte
reproducibility would false-fail.

**⑥ It proves itself.** the backward check in `zephem depth` re-reads the three files and reconciles them:
Σ status row-counts == resolved rows, every attempted container is real in `index.tsv`, no path
resolves twice, every poison reason is a real compiler error or a timeout.

> Reproducibility is **separate from the commit on purpose** — a sweep compiles every container
> (about 61 s cold for the full sweep, the rescue included; the old one-per-process sweep took minutes), so it is *never* wired into
> `zephem std`'s `--check`, which must stay fast. See [`../docs/reproducibility.md`](../docs/reproducibility.md).

## 4. The files

```
reflect/
  resolve.zig   # the per-container reflector (a template; TARGET rewritten per call)
```

One file — the reflector. The orchestration (per-container rewrite, the parallel sweep, poison
capture, the manifest) lives in `zephem depth`, because it drives Zig rather than
being Zig. (`resolve.zig` left at its default `TARGET` is a runnable self-test: `zig run reflect/resolve.zig`.)

## 5. Running it

```sh
zephem depth --only std.crypto.hash.sha2   # one container (depth on demand)
zephem depth --commit                       # full sweep → extracted/ + SHA256SUMS.depth
zephem depth --check                        # prove the committed overlay rebuilds
```

---

## The other engines

- **[`../parse/`](../parse/)** — the **read-it** engine: parses `std.zig.Ast`, maps *all* of std,
  never runs the compiler. The map + its source-fact overlays (sigs, docs, fields, delegates,
  examples) are the input this engine resolves against.
- **`../derive/`** — **transforms datasets, reads no Zig.** Joins parse ⋈ reflect into the
  censuses (`consensus`, `canon`, `callcard`) and builds the `index.tsv` table of contents.
