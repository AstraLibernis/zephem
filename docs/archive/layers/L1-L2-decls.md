# L1 + L2 — Signatures-as-written + Doc-comments ✅

| | |
|---|---|
| **Questions** | L1: what does this fn take / return / error? · L2: what do std's authors say it is? |
| **Source of truth** | parse (`std.zig.Ast`; L2 reads `///`) |
| **Coverage** | total (sparse overlay — a row only where there's something to say) |
| **Build** | `src/enrich.zig` → `data/std/decls.tsv` (`path · doc · sig`) |
| **Verify** | `scripts/verify_std.nu` |

Index: [PLAN.md](../../PLAN.md) · model: [concepts.md](../concepts.md) · proof: [reproducibility.md](../reproducibility.md).

---

Shipped together as one overlay, keyed to the [map](L0-structure.md):

- `doc` = the decl's `///` lines verbatim (the std authors' own words).
- `sig` = a `fn`'s as-written signature `fn name(params) ret`.

A **sparse** overlay — a row only where there's something to say (every fn, plus any documented
decl). It's an *overlay* in the [positions/overlays/tunnels](../concepts.md#the-shape-of-it-positions-overlays-tunnels)
sense: more facts attached at an existing `path`, read "straight down" by joining on `path`.
The holes are useful — the gaps in the doc overlay are exactly every undocumented public decl.

On Zig 0.16.0: **7,143 rows (5,377 signatures, 4,167 docs).**

**Verified** by `verify_std.nu`: every overlay path exists in the map (registration), paths are
unique, and no signature is lost between the map and the overlay (5,377 signatures cover the
map's 5,377 functions). Note this is a *parser-internal loss check*, not a correctness proof —
`scan.zig` (map) and `enrich.zig` (overlay) apply the same fn-gate, so their agreement is
guaranteed by construction and would survive a shared blind spot. Whether the function set is
*actually right* is tested independently in [`verify_layers.nu`](../../scripts/verify_layers.nu),
which joins the parser's kinds against the **compiler's** reflected kinds. Byte-identical reruns.

Once these signatures exist, every type name in a signature is a candidate
[tunnel](L3-tunnels.md) endpoint (→ its definition).
