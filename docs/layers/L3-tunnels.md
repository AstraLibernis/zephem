# L3 — Reference graph / tunnels ▢ (planned)

| | |
|---|---|
| **Question** | what links to what — followable to an address? |
| **Source of truth** | parse (resolve names) → transform |
| **Coverage** | edges |
| **Status** | not started — build *after* the overlays exist |

Index: [PLAN.md](../../PLAN.md) · model + geometry: [concepts.md](../concepts.md#the-shape-of-it-positions-overlays-tunnels).

---

The linking layer. The [geometry](../concepts.md#the-shape-of-it-positions-overlays-tunnels)
(positions / overlays / tunnels) lives in concepts; this layer *builds* the tunnels.

Resolve referenced names — identifiers, import targets, alias targets, the type names
[L1](L1-L2-decls.md) surfaces — to canonical `path`s, and emit edges `from_path → to_path`
tagged by kind (**alias** / **import** / **usage**). Each resolved edge also carries the
destination's `line` (via the [index](L0-structure.md)), so following it is one O(1) jump, not a
search — a real tunnel, usually far shorter than the tree route.

Build this **after** the overlays exist, since a usage edge connects a type in the signature
layer to a definition in the map. The re-export *collapse* now lives in the map itself (see
[L5 history](L5-depth.md#history--root-caused-not-patched-2026-06-18)), so L3 is just the
linking layer, not alias cleanup.

**Verify:** every edge endpoint is a node in `nodes.tsv` (no dangling — same registration proof
as the overlays); names that cannot be resolved are recorded explicitly, never silently
dropped; edge count stable.

*Why:* turns the layer-stack into a navigable graph — "go to definition," "what uses X," "what
does Y pull in" — that the containment tree alone cannot express.
