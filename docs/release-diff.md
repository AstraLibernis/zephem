# Release diff — what to compare when a new Zig lands

zephem's purpose is one honest dataset of Zig's std that a model can read instead of
recalling. A new Zig release changes that dataset, and the point of keeping one frozen map
per version (`data/versions/<zig-version>/`, see the README) is that the change is a direct
comparison, not a memory. This is the standing list of what that comparison covers, where
each item comes from, and whether `zephem diff` reports it yet.

Procedure for a new release: install the Zig, then `zig build std`, `zig build depth --
--commit`, `zig build overlays`, `zig build lookup`, `zig build docs`, `zig build snapshot`;
then `zephem diff <previous> <new>`. If the extractor (`parse/`) or the reflection template
(`reflect/resolve.zig`) does not compile with the new Zig, `zephem std` / `zephem depth` stop
and say so: extend `parse/compat.zig` (or the template) so it builds on every supported release.

After a change to the extractor or the template, regenerate every version folder, oldest first
and the current Zig last (so `data/std` ends on it): for each, `ZIG=<that zig> zephem std`,
`zephem depth --commit`, `zephem overlays`, `zephem snapshot`; then `zephem lookup` and
`zephem docs`. Every folder is then made by the same extractor, and the diff shows std's
changes, not the extractor's.

## Exact facts — read from the datasets, never inferred

| # | change | source | why a model needs it | `zephem diff` |
|---|---|---|---|---|
| 1 | **removed** declaration (path in old, not in new) | `extracted/nodes.tsv` | hard break: the code will not compile | yes |
| 2 | **added** declaration | `extracted/nodes.tsv` | the replacement is usually here | yes |
| 3 | **signature changed** — split by failure mode: parameter count · parameter *order* with the same types (compiles, wrong result; `containsAtLeastScalar` in 0.17) · parameter or return type · error set | `extracted/attrs.tsv` (`sig`) | each fails differently; the order case is the one that compiles | yes — classified arity · order · types · return_type · error_set · names · sig_dropped · sig_gained (`detail` column); whitespace / trailing-comma reflow is not a change |
| 4 | **kind changed** (const → enum, fn → alias, decl ↔ field) | `extracted/nodes.tsv` | the same name is a different thing | yes |
| 5 | **visibility changed** (pub → private) | `extracted/nodes.tsv` | a removal in practice | yes |
| 6 | **deprecated** — newly marked, un-marked, or marked-then-removed, with the replacement the doc names | `extracted/attrs.tsv` (`doc`) | zsnag R011 reads this; the diff lists newly / lifted / deprecated-then-removed | yes |
| 7 | **enum tag sets** (`Debug` → `debug`), summarised per enum | `extracted/nodes.tsv` (`tag`) | otherwise fifty removals and fifty additions | yes |
| 8 | **builtins** added, removed, signature or doc changed | `extracted/builtins.tsv` | `@splat` grew a job; `@bitCast` lost one | yes (added / removed / re-signed / same signature with new langref text) |
| 9 | **resolved values** that changed (a `max_path_bytes`) | `extracted/resolved.tsv` | code that hard-codes the old value is silently wrong | yes (const_int / const_bool) |
| 10 | **alias / delegation targets** (what `std.ArrayList` resolves to now) | `extracted/edges.tsv` (`alias`, `delegates`) | member lookups follow these hops | yes — for declarations on both sides: retargeted (`target_moved` when the old → new target is itself an inferred move), gained (the name became an alias; its definition now lives at the target), lost. An alias written through an import (`std.Build.Configuration.…`) resolves to its node (it used to be cut to the bare `std`, hiding ~1,240 aliases per version) |
| 11 | **doc text changed, signature unchanged** — count it; flag docs that gain "no longer" / "now" | `extracted/attrs.tsv` (`doc`) | the only signal for a semantics change | yes — counted; flagged rows listed (`doc_changed … hint`) |

## Inferences — always labelled as such

| # | change | method | why | `zephem diff` |
|---|---|---|---|---|
| 12 | **moved** declaration | a removed and an added one with the same name, kind and signature, unique on both sides; a declaration **without** a signature (field, container, const) additionally needs support: its parent is itself a move to the new parent, two or more of its children already moved into the new path, two or more candidates move between the same two parents, or the two parents share two or more other lost/gained members by name and kind (a unique name alone produced ~3% coincidences in the 0.16 → 0.17 audit; the parent-only rule then lost 12 true moves, which the last two clauses recover) | turns 0.17's `std.builtin` → `std.lang` block into a rename table, read from the diff when porting | yes — `--tsv` rows `moved · inferred` |

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
- The exact diff is complete on its own. Everything below row 11 is readability, not
  correctness.
- The diff is read, not wired in: zsnag and `look`/`map` work from the current version's map
  only. When a change between versions has to be understood, consult `zephem diff`.

## Verification — a second witness, every time

`tools/verify-diff.py <old> <new>` (`zig build verify-diff -- 0.16.0 0.17.0`) recomputes every
quantity above from the raw TSVs in Python, sharing no code with `src/diff.zig`, runs the binary's
`--tsv` and human output, and demands **set equality per finding type** (not equal counts: the
same 2,270 removed paths, the same 458 (from, to, support) move triples, the same path → hint
map for doc changes). It then checks the identities that are true by construction and would
expose a row counted twice or not at all:

| | identity |
|---|---|
| I1 | \|pub(old)\| = \|removed\| + \|both, pub in old\| |
| I2 | \|pub(new)\| = \|added\| + \|both, pub in new\| |
| I3/I4 | removed listed = \|removed\| − \|removed tags\| − \|moves\|; same for added |
| I5 | moves are a bijection: \|{from}\| = \|{to}\| = \|moves\|, from ⊆ removed, to ⊆ added |
| I6 | Σ per-module tallies = (\|removed\|, \|changed\|, \|added\|) |
| I7 | Σ signature classes = \|changed with two differing normalised sigs\|; sig_dropped = old sig only; blank = same sig |
| I8 | Σ over enums (tags removed + added) = \|removed tags\| + \|added tags\| |
| I9 | newly-deprecated ∩ un-deprecated = ∅; deprecated-then-removed ⊆ removed |
| I10 | every manifest entry in both version folders verifies by sha256 |
| I11 | aliased declarations: \|in old\| = retargeted + lost + unchanged; \|in new\| = retargeted + gained + unchanged |

The script exits 1 on any disagreement; a mutation check (a wrapper that drops one TSV row) makes
it fail, so a green run is not vacuous. It is the standing procedure after every regenerate:
`snapshot`, then `verify-diff <previous> <new>`. The script is written by the same author as the
tool, so it guards against implementation slips, not against a shared misreading of the data;
that is what the blind audits below were for.

## Audit record

- **2026-10-16, 0.16.0 → 0.17.0, blind re-computation from the raw TSVs by an independent agent
  (own scripts, source read last).** Confirmed row by row: removed / changed / added sets, the
  478 move pairs, 4,447 tags over 259 enums, 149 deprecations, 28 builtins, 11 values, 182 doc
  changes with 1 flagged, snapshot integrity against `data/std/` and against git, TSV shape and
  the report/TSV count agreement. Refuted and fixed the same day: 2 "changed" rows were
  whitespace-only reflow (signatures are now compared normalised; `names` requires a name to
  differ); 31 fn → alias/const rows had an empty `detail` (now `sig_dropped`); the header's
  move count was wrong under `--only`/`--module` (now counted in scope); ~13 of 478 moves (3%)
  were coincidences between sig-less declarations with a unique name (moves now need parent
  support, row 12); 17 builtins with new langref text and the same signature were silent (now
  `builtin_doc_changed`). Also hardened: depth counters saturate on an unmatched closer;
  duplicate paths in `resolved.tsv` are read once.
- **Follow-up, same day, same auditor, on the fixes:** all five confirmed; the normaliser was
  shown never to merge signatures that differ in a token (29 multi-spelling classes, 0 token
  differences); the stricter move rule lost 12 true moves (precision 452/452, recall −12:
  `Type.Struct.is_tuple`, `HashMapUnmanaged().Header.capacity`, `ArrayBitSet().last_item_mask`,
  `Endormorphism.SplitScalar`, …). Fixed by two more support clauses (upward: children vouch
  for their container; shared members by name and kind between the two parents, not counting
  the candidate itself — counting it re-admitted 3 coincidences). Net: 458 moves; all 14 known
  coincidences absent; the 6 "certain" lost moves recovered (`Type.Struct.is_tuple`,
  `StructField.Attributes.@"comptime"`, `Header.capacity`, `ArrayBitSet().last_item_mask`,
  `Endormorphism.SplitScalar`, `ArmCpuinfoImpl.CoreInfo.implementer`); 6 the auditor rated
  "likely" or with no vouching neighbour stay listed as removed + added
  (`Fn.Param.Attributes.@"noalias"`, `Serializer.Options.whitespace`, `ArmCpuinfoImpl.have_fields`,
  `PrefixedArtifact.artifact`, `Cache.File.Stat`, `PkgConfigPkg.desc`) — the honest default when
  nothing but a name connects two paths.
