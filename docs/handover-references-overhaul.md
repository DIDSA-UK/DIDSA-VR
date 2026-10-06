# Handover: overhauling how sketches reference upstream geometry

Written 2026-10-06 at the end of a long session, for the sessions that pick this up. Read `docs/design-table-gaps.md` ("Open items at a glance" first), then this.
Two repos are involved: **DIDSA-CAD** (backend + the flat Flutter client) and **DIDSA-VR** (Godot, the design table). Branches: develop on the branch each session's
system prompt names; do not open PRs unless asked.

## Where things stand

* **VR (done, merged):** the part's own vertices and straight edges, projected onto the sketch plane, are reference geometry (`scripts/design_table/part_references.gd`).
  Any tool snaps to a corner; Select, Dimension and the constraint tools pick a corner or a straight edge; `sketch_session.gd: ensure_reference` makes the pinned point
  (`POST .../convert-entities/vertex`, idempotent) or pinned construction line on demand, so there is no convert / fix / construction step. Nothing is offered between two
  pinned things. Tests: `tests/design_table_references.gd` (fake backend), `tests/e2e_references.gd` (real backend, local only), `tests/references_render.gd` (a picture).
* **VR (done, merged):** the sketch window is fixed in the world and the part and its sketch slide / zoom together under it (1/50x to 200x), the drawing clipped to it.
* **Backend (probed; fixed since by Session A, see "Session A result" below - the text in this bullet is the state when the handover was written):** `Sketch.external_references` is `body_id` + a raw OCCT vertex index. Edits that keep the topology are followed; a topology-changing
  upstream edit renumbers vertices and the reference silently binds to a different corner with `has_lost_reference` false (5 of 7 probes). Evidence and the wanted behaviour:
  `DIDSA-CAD/backend/tests/test_reference_follows_upstream_topology_change.py` (2 passing, 4 xfail) and `DIDSA-CAD/docs/roadmap.md` "Reference drift" (Findings 2026-10-06).
* **Flat app (not changed when this was written; done by Session A, see below):** still the explicit flow: Dimension mode shows ghost body vertices / edges you pick (`pickReferenceGhostVertex` / `pickReferenceGhostEdge` in
  `client/lib/sketch/sketch_controller.dart`), plus a separate Convert mode (`SketchMode.convert`, `sketch_convert_bar.dart`) with Offset / Pattern each their own mode.

## Why SolidWorks feels seamless (the target), and what DIDSA lacks

1. **Implicit references:** any edge or vertex aimed at while sketching is used directly; no mode, no convert / fix / construction. (VR has this now; the flat app does not.)
2. **Persistent identity:** a face / edge keeps its identity through rebuilds because identity comes from the feature history, with geometric matching as a fallback, so
   downstream sketches and dimensions follow. (DIDSA has only raw indices: the gap above.)
3. **Loud, recoverable failure:** a reference that cannot be found is flagged (dangling dimension, rebuild error) and can be re-attached, never silently moved.

## Session A result (2026-10-06, DIDSA-CAD branch `ccr-c5e04801-z93yio`)

Backend fixed (all four probes pass) and the flat app done; full account in `DIDSA-CAD/docs/reference-identity-design.md` and the 2026-10-06 entry of `DIDSA-CAD/docs/status.md`. What Session B needs:

* **No route changed shape**, so `sketch_session.gd: ensure_reference` (`convert-entities/vertex` / `edge`, idempotent) is untouched and still correct. One behaviour change: the creation routes now resolve the vertex against the Sketch's **causal snapshot**
  (the Part as it stood after the features *before* that Sketch), exactly as the refresh always did. For the last feature in the history this is identical; for a reopened earlier sketch the glb the VR client takes vertex
  indices from must therefore be fetched with the matching `rollback_excluded_feature_ids` (item 3 above), or the index names a different corner than the backend binds.
* **For item 4 (show lost / moved in the editor)** the sketch feature in `GET /document/parts/{id}/features` now carries `has_lost_reference`, `lost_reference_point_ids`, `moved_reference_point_ids` ("potentially moved": bound on weaker
  evidence), `followed_reference_point_ids` (informational: re-found at a new index) and `reference_reasons` (`point id -> consumed_by_<feature id> | ambiguous | no_match | body_missing | nearest_of_identical_vertices | unique_fingerprint_far | ...`).
  Per-reference detail: `GET /document/parts/{id}/features/sketch/{feature id}/external-references` -> `[{point_id, body_id, vertex_index, status ok|followed|potentially_moved|lost, reason, method, candidates}]` (`candidates` = the vertex indices an ambiguous
  reference could be). Re-attach = `POST .../external-references/{point id}/reattach {body_id, vertex_index}` (the Point id, and every line / dimension on it, is kept); keep = `POST .../external-references/{point id}/confirm`.
  An edge reference is two vertex references, so re-attaching an edge is two calls (the flat app does it one corner at a time).
* The e2e test the item asks for (move the fillet to another edge; the reference follows or is flagged) is `DIDSA-CAD/backend/tests/test_reference_identity.py::test_moving_the_fillet_to_any_edge_follows_the_corner_or_flags_it_lost` in pytest form;
  the VR version only needs to drive the same PATCH `.../fillet-features/{id}` and read the sketch feature.
* The flat app's rule "nothing is offered between two pinned things" is implemented as in VR (a Point is pinned if it is a body reference, a Fix, or the origin).

## Session A: DIDSA-CAD, backend first, then the flat app (the prompt, kept for the record)

Prompt to paste:

> You are continuing work on DIDSA-CAD (backend `backend/`, Flutter client `client/`). Read `DIDSA-VR/docs/handover-references-overhaul.md` (the DIDSA-VR repo may need adding with
> `add_repo`; if not reachable, `docs/roadmap.md` "Reference drift" in this repo has the findings), then `docs/roadmap.md` "Reference drift", `docs/sketcher-overhaul-scope.md`
> Phases 4.3 / 9, `backend/app/sketch/models.py` (`ExternalVertexReference`, `Sketch.external_references`, `add_or_reuse_external_vertex_reference`),
> `backend/app/document/create_plane.py` (`refresh_external_references`, `resolve_external_vertex_position`), `backend/app/document/router.py` (the external-references and
> convert-entities routes, `has_lost_reference`), and `backend/tests/test_reference_follows_upstream_topology_change.py`.
>
> Goal: overhaul how a Sketch references upstream geometry so that downstream sketches follow upstream edits the way SolidWorks's do, and never silently move.
> 1. **Backend.** Make the 4 xfail tests in `test_reference_follows_upstream_topology_change.py` pass (remove the xfail marker when they do). Design first, in `docs/`: (a) store a geometric
>    signature with every external reference at creation (vertex position in the Body frame, for edges midpoint + direction, plus the adjacent-face normals / vertex valence as a
>    topological fingerprint) and re-validate on every refresh in `refresh_external_references`; (b) when the index no longer matches, re-find the entity by signature (nearest within a
>    tolerance relative to the Body's bounding diagonal, unique match only); (c) where possible use OCCT history (`BRepAlgoAPI_*::Modified()/Generated()/IsDeleted()`) through the feature
>    pipeline so a fillet / cut reports what became of each input vertex / edge / face; (d) if neither finds it unambiguously, set `has_lost_reference` (never rebind silently) and expose
>    which point ids. Apply the same to `SubShapeRef` consumers that have the same weakness (Create Plane `face_refs`, Pattern / Mirror refs) only if cheap; otherwise list them.
>    Persist the signature in the native format (`native_format.py`) with a backward-compatible default. Add pytest for: each topology-changing edit in the probe, a reference whose entity is
>    genuinely deleted (flagged), an ambiguous match (flagged), save / load round trip, and no regression of the parametric cases.
> 2. **Flat app.** Make referencing implicit, like the DIDSA-VR design table: in any sketch tool, aiming at a body vertex or edge (shown as the ghost geometry) snaps / picks it and makes the
>    reference on demand with the existing `convert-entities/vertex` (idempotent) route, so the user never enters Convert mode, then fixes or marks construction, then dimensions. Keep Convert mode
>    for making real geometry. Show a lost-reference flag clearly on the sketch and in the feature tree, with a way to re-attach (pick the replacement vertex / edge) and a "potentially moved" state
>    if you add a signature-drift warning. Reuse the VR rules: nothing is offered between two pinned things; an edge is two pinned points plus a construction line, reused if present.
> 3. Keep both clients compatible with the same backend routes; if a route changes, change the VR session (`DIDSA-VR/scripts/design_table/sketch_session.gd: ensure_reference`) in the same piece of work or note it in `DIDSA-VR/docs/handover-references-overhaul.md`.
>
> Workflow: the sandbox has no Flutter SDK unless you install one; backend tests run in the micromamba env (`/opt/sdks/micromamba_root/envs/didsa-backend/bin/python -m pytest`; see `docs/status.md`
> "How this has been worked on"). Do the work yourself rather than delegating. Commit with the required trailers, push only to your designated branch, do not open a PR unless asked, keep
> `docs/status.md` and `docs/roadmap.md` current. Report what you could not verify (anything needing the Flutter app on a device).

## Session B: DIDSA-VR, finishing the design table side

Prompt to paste (can run in parallel with A for items 1-3; item 4 needs A's backend):

> You are continuing work on DIDSA-VR (Godot 4.7, the design table). Read `docs/handover-references-overhaul.md`, then `docs/design-table-gaps.md` ("Open items at a glance"), `docs/design-table.md`
> (Using it, Sketch mode and the grips), and the end of `docs/status.md`. A throwaway local backend for the real-backend tests: from `DIDSA-CAD/backend`,
> `CAD_API_KEY=throwaway-test-key /opt/sdks/micromamba_root/envs/didsa-backend/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000`, and a gitignored `secrets.cfg` (url
> `http://127.0.0.1:8000`, key `throwaway-test-key`). Godot is not in the repo: download Godot 4.7.2 headless/linux into your scratchpad (see `docs/status.md` "How this has been worked on");
> run the suite with `GODOT=... tests/run_all.sh` and set `DIDSA_SETTINGS_PATH=user://settings_test.cfg` for single tests.
>
> Do, in order:
> 1. **Clip the part to the sketch window.** While a sketch is open the part (and its edge overlay lines) should be clipped to a box: the window rectangle in the sketch plane, with a depth of
>    a few tens of centimetres either side, so that zooming to 200x does not fill the room. The section tool already replaces materials with `shaders/section_clip.gdshader` using global uniforms;
>    generalise that (or add a second clip) rather than inventing a parallel system; keep colours (`colour_tool.gd`), view modes (`edge_overlay.gd`, wireframe via `layers`) and the hover / selection
>    overlays working. Test with a render (`tests/sketch_style_render.gd` pictures) and headless asserts on the uniforms.
> 2. **More reference kinds**, in `part_references.gd` / `sketch_session.gd` / `snap_resolver.gd`: circular edges (a hole or boss: pick the circle to dimension its radius / diameter and to snap to its
>    centre; the backend's `convert-entities/edge` returns an Arc for a coplanar circular edge, its centre point is not associative in v1: check `convert_body_edge` in
>    `DIDSA-CAD/backend/app/document/router.py` and ask for backend help in the handover note if a pinned centre needs a backend change), an edge's midpoint and the nearest point along an edge
>    as snaps (a point on a pinned line, with a point-on-line constraint), and a driven (reference-only) dimension between two pinned things.
> 3. **References for the cases that are refused today**: a part with something hidden or rolled back, and a reopened sketch that is not the last feature. The backend resolves references at the
>    sketch's place in the feature history, so fetch the glb with the matching `rollback_excluded_feature_ids` (the Build tree has the machinery) and use that topology for the references.
> 4. **After Session A's backend lands:** show `has_lost_reference` and any "moved" state on the sketch in the editor (a warning in the status line and on the sketch's Build row, with a way to
>    re-pick the replacement corner), and add an e2e test (`tests/e2e_references.gd` is the model) that moves the fillet to another edge and checks the reference follows or is flagged.
> 5. Then update `docs/design-table-gaps.md` (the "Open items at a glance" table is the one list; keep it true), `docs/design-table.md`, `docs/status.md` and `tests/README.md`.
>
> Workflow: do the work yourself rather than delegating. Commit with the required trailers, push only to your designated branch, do not open a PR unless asked. Nothing here has been seen in a
> headset: say so, and leave the numbers that depend on feel (`REF_*`, window size, zoom range) as named constants.
