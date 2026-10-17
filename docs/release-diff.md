# Release diff — what to compare when a new Zig lands

zephem's purpose is one honest dataset of Zig's std that a model can read instead of
recalling. A new Zig release changes that dataset, and the point of keeping one frozen map
per version (`data/versions/<zig-version>/`, see the README) is that the change is a direct
comparison, not a memory. This is the standing list of what that comparison covers, where
each item comes from, and whether `zephem diff` reports it yet.

Procedure for a new release: install the Zig, then `zig build std`, `zig build depth --
--commit`, `zig build overlays`, `zig build lookup`, `zig build docs`, `zig build snapshot`;
then `zephem diff <previous> <new>`.

## Exact facts — read from the datasets, never inferred

| # | change | source | why a model needs it | `zephem diff` |
|---|---|---|---|---|
| 1 | **removed** declaration (path in old, not in new) | `extracted/nodes.tsv` | hard break: the code will not compile | yes |
| 2 | **added** declaration | `extracted/nodes.tsv` | the replacement is usually here | yes |
| 3 | **signature changed** — split by failure mode: parameter count · parameter *order* with the same types (compiles, wrong result; `containsAtLeastScalar` in 0.17) · parameter or return type · error set | `extracted/attrs.tsv` (`sig`) | each fails differently; the order case is the one that compiles | yes — classified arity · order · types · return_type · error_set · names (`detail` column) |
| 4 | **kind changed** (const → enum, fn → alias, decl ↔ field) | `extracted/nodes.tsv` | the same name is a different thing | yes |
| 5 | **visibility changed** (pub → private) | `extracted/nodes.tsv` | a removal in practice | yes |
| 6 | **deprecated** — newly marked, un-marked, or marked-then-removed, with the replacement the doc names | `extracted/attrs.tsv` (`doc`) | zsnag R011 reads this; the diff lists newly / lifted / deprecated-then-removed | yes |
| 7 | **enum tag sets** (`Debug` → `debug`), summarised per enum | `extracted/nodes.tsv` (`tag`) | otherwise fifty removals and fifty additions | yes |
| 8 | **builtins** added, removed, signature or doc changed | `extracted/builtins.tsv` | `@splat` grew a job; `@bitCast` lost one | yes (added / removed / re-signed; doc-only changes not yet) |
| 9 | **resolved values** that changed (a `max_path_bytes`) | `extracted/resolved.tsv` | code that hard-codes the old value is silently wrong | yes (const_int / const_bool) |
| 10 | **alias / delegation targets** (what `std.ArrayList` resolves to now) | `extracted/edges.tsv` | member lookups follow these hops | next |
| 11 | **doc text changed, signature unchanged** — count it; flag docs that gain "no longer" / "now" | `extracted/attrs.tsv` (`doc`) | the only signal for a semantics change | yes — counted; flagged rows listed (`doc_changed … hint`) |

## Inferences — always labelled as such

| # | change | method | why | `zephem diff` |
|---|---|---|---|---|
| 12 | **moved** declaration | a removed and an added one with the same name, kind and signature (a different path); never on signature alone | turns 0.17's `std.builtin` → `std.lang` block into a rename table zsnag can quote ("moved to … in 0.17") | yes — `--tsv` rows `moved · inferred` |

## Outside the map — curated, marked as such

| # | change | source | why | where |
|---|---|---|---|---|
| 13 | **language changes** — operators and syntax (`**` → `@splat`, `void{}`, `errdefer \|err\|`) | the release notes, by hand | the map covers builtins, not grammar | `data/versions/<v>/LANGUAGE.md`, appended to the report under a CURATED heading; never in `--tsv` |

## Rules

- Every reported line carries its provenance: **extracted** (rows 1–11), **inferred** (12) or
  **curated** (13). An inference is never rewritten into a fact to look certain.
- The TSV form (`zephem diff --tsv`) is the machine-facing output with stable columns
  (`change · provenance · path · kind_old · kind_new · old · new · detail`); the report is a view over it.
  New columns are appended, never reordered.
- The exact diff is complete on its own. Everything below row 11 is readability and
  zsnag's benefit, not correctness.
