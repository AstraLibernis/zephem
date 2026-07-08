<!-- GENERATED from templates/reflect.tmpl.md by scripts/build_arch.nu — edit the template, not this file. -->
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

These rows are **x86_64-linux-specific**: a decl gated to another target resolves as poison here.
Pinned to **zig 0.16.0** (`../data/std/PINNED`).

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

Every container in the map is swept; each is a binary outcome — it **resolved** or it's **poison**.

| dataset | purpose | shape |
|---|---|---|
| `resolved.tsv` | the resolved facts — const values, expanded generics, typed fn sigs. `kind ∈ type · const_int · const_bool · fn · const_other` | `path · kind · detail` |
| `poison.tsv` | the containers that *didn't* resolve, each with the compiler's own first error line (platform / foreign lib / `@compileError` / timeout) | `path · reason` |
| `status.tsv` | the per-container ledger — one row per attempted container; the verifier re-derives the resolved/poison split from it | `path · status · n_rows` |

On zig 0.16.0: **4,042 containers swept → 2,908 resolved (15,792 rows) / 1,134 genuine poison.**

### Planned — the same sweep, more facts

The engine is being **expanded**. The costly part is the reflection sweep itself, so new facts
ride the *same* per-container pass (reflect once, emit more) rather than adding new sweeps:

| dataset | purpose | shape |
|---|---|---|
| `errors.tsv` *(planned)* | the error-set members of each fn — what it can fail with, expanded from inferred/merged sets a parser can't see | `path · error_name` |
| `layout.tsv` *(planned)* | ABI/memory layout: `@sizeOf` / `@alignOf` per type (field `@offsetOf` a later extension) | `path · size · align` |
| `typeinfo.tsv` *(planned)* | the structured `@typeInfo` bits a type name doesn't show — pointer size/const/sentinel, enum tag+exhaustiveness, struct/union layout, int signedness/bits | `path · type_kind · attrs` |

## 3. How it works — the extraction method

**① Reflect one container per subprocess.** `resolve.zig` is a *template*: its `TARGET_PATH` /
`TARGET` / `SKIP` lines are rewritten per container by the orchestrator (`../scripts/build_depth.nu`),
compiled, and run. Its own container-`@import` means a poison decl fails *this* process only.

**② Read the type with `@typeInfo`.** For the target type it walks `@typeInfo(T).…decls`, and for
each public decl reads `@TypeOf`/`@field`/`@typeName` — emitting a resolved value (`const_int`,
`const_bool`), a resolved `@typeName` (`type`), or a typed `fn`. It descends **one** level into
non-container types (so `sha2` yields `Sha256` *and* `Sha256.digest_length = 32`), never into child
containers (they reflect on their own turn — `SKIP` prevents double-emission).

**③ Poison is contained, not hunted.** A subprocess that fails to compile is recorded as
`path · reason` with the compiler's first error line, and the sweep continues. Works-or-doesn't is
the whole verdict; a timeout gets its own honest reason (`timeout after Ns`) so it never
masquerades as a compile error.

**④ Data-parallel sweep.** The full overlay is the sweep over every container in `index.tsv` — the
same op over independent items — so it runs one lane per CPU, each in its own scratch file +
subprocess, results sorted back to target order so the bytes match a serial sweep exactly.

**⑤ Reproducible — with two volatiles normalized out.** `--check` runs two fresh sweeps and diffs
them. Anonymous-type disambiguators (`__struct_NNNN`, a semantic-analysis counter that drifts
between identical compiles) drop their digits; absolute toolchain paths in poison reasons render
relative — without this, byte-for-byte reproducibility would false-fail.

**⑥ It proves itself.** `../scripts/verify_depth.nu` re-reads the three files and reconciles them:
Σ status row-counts == resolved rows, every attempted container is real in `index.tsv`, no path
resolves twice, every poison reason is a real compiler error or a timeout.

> Reproducibility is **separate from the commit on purpose** — the sweep is SLOW (machine-dependent:
> ≈13 min on a 3-core VM, under a minute on a many-core desktop), so it is *never* wired into
> `build_std.nu`'s `--check`, which must stay fast. See [`../docs/reproducibility.md`](../docs/reproducibility.md).

## 4. The files

```
reflect/
  resolve.zig   # the per-container reflector (a template; TARGET rewritten per call)
```

One file — the reflector. The orchestration (per-container rewrite, the parallel sweep, poison
capture, the manifest) lives in `../scripts/build_depth.nu`, because it drives Zig rather than
being Zig. (`resolve.zig` left at its default `TARGET` is a runnable self-test: `zig run reflect/resolve.zig`.)

## 5. Running it

```nu
nu scripts/build_depth.nu --only std.crypto.hash.sha2   # one container (depth on demand)
nu scripts/build_depth.nu --commit                       # full sweep → extracted/ + SHA256SUMS.depth
nu scripts/build_depth.nu --check                        # prove the committed overlay rebuilds
```

---

## The other engines

- **[`../parse/`](../parse/)** — the **read-it** engine: parses `std.zig.Ast`, maps *all* of std,
  never runs the compiler. The map + its source-fact overlays (sigs, docs, fields, delegates,
  examples) are the input this engine resolves against.
- **`../derive/`** — **transforms datasets, reads no Zig.** Joins parse ⋈ reflect into the
  censuses (`consensus`, `canon`, `callcard`) and builds the `index.tsv` table of contents.
