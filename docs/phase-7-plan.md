# Phase 7 plan: finish what is there (option-level depth on the design table)

Planned 2026-10-12. Step 1 of the rollout order agreed in DIDSA-CAD `docs/roadmap.md` ("DIDSA-VR: parity gap review and rollout order"). Phase 5 and 6
(`docs/implementation-plan.md`, `docs/status.md` "2026-10-08") built the tools; this phase gives the tools the options the backend and the flat app already
have. **No backend change is needed**: every route and update schema named below already accepts the fields (checked 2026-10-12, see "Pre-checks").
Everything is VR client work, tested headless, in a software render and against a real backend; nothing here can be judged for feel without a headset.

## Pre-checks (done 2026-10-12) and what they found

1. **Can the Properties panel take more options? Yes, but it already scrolls, so it needs sections first.**
   `table_props_window.gd` is a 0.30 x 0.40 m panel (516 x 688 px) with a title, the tool tip, a "Selected" list and a `ScrollContainer` of rows. Each non-toggle
   option is one 56 px button (64 px with the gap); toggles flow side by side (150 px minimum, about three to a line). Estimated, not measured: the header takes
   roughly 200 px, so about 7 lines are visible before scrolling. Pattern (rectangular with a second direction) is already about 12 lines; Extrude is about 5 today
   and would be about 10 with the options below. The right stick scrolls the panel (`scroll_target`), so nothing is blocked, but a 10-line Extrude is a poor first
   screen. **Decision: Phase 7 starts with 7.0, collapsible sections in the option list.** This is not the layout and human-factors pass (roadmap item 8); it is the
   smallest change that keeps the first screen short.
2. **Backend routes accept everything.** `ExtrudeFeatureCreate/Update`: `thickness`, `thickness_direction` (outward / inward / symmetric), `draft_angle` (strictly inside 0 to 90),
   `draft_outward`, `profile_refs`. `ChamferFeatureCreate/Update`: `edge_options` (`{index: {face_ref?, angle?, flip}}`). `MoveFaceFeatureUpdate`: `direction_ref` + `direction_distance`
   (also `delta`). `PatternFeatureUpdate`: `skip_indices`, `orientation_mode`, `source_feature_ids`. `LoftFeatureUpdate`: `thickness`, `thin_from_closed_profile`, `guide_curve_refs`.
   `CreatePlaneFeatureUpdate`: every reference field. Rules the VR must respect or surface: a thin extrude and a draft cannot be combined, and a draft is single-profile only;
   the seed instance (index 0) cannot be skipped; each plane type takes exactly the fields in `_validate_create_plane_payload` and nothing else.
3. **Vertex picking exists but the editor has no state for it.** `topology_pick.gd` already returns `{kind: "vertex", body_id, index}` (the Mates tool uses it), but `table_editor.gd`'s
   `PICK_STATES` are edges, faces, bodies, curves and sketch. 7.3 needs a `pick_vertices` state and a `vertex_refs()` beside `face_refs()` / `edge_refs()`.
4. **Plane picking takes one plane-like.** `FeatureTool.wants_plane_pick` / `on_plane_picked` fill a single `plane_base`. Midplane needs two, so 7.3 generalises that to numbered slots.
5. **Sketch construction methods are client-side geometry.** The backend takes the finished shape (`RectangleCreate` is four corner points plus `axis_aligned`; a circle is a centre and a
   radius point), so 3-point circle, centre-corner and 3-point rectangle and the midpoint line need no new route, only the maths the flat app already does
   (`CircleConstructionMethod`, `RectangleConstructionMethod`, `LineConstructionMethod`). `point_on_ellipse` is `POST .../constraints {"type":"point_on_ellipse","point_id","ellipse_id"}`.

## Rules for the implementing session

Same as `docs/implementation-plan.md` ("Rules for the implementing session"), with these changes: develop on `ccr-c1a7db4e-ze4kxb` in both repos, small commits, push after each sub-phase,
**no pull requests**; no model name in commits or code. Do the work directly. After every VR change run the headless suite (`tests/run_all.sh`) and, for anything drawn, `tests/ci_render.sh`; run
the real-backend list (`tests/ci_e2e.sh`) after each sub-phase. Register new tests per `tests/README.md`. Update `docs/status.md`, `docs/design-table.md`, `docs/design-table-gaps.md` and the roadmap as items
close. Report plainly what ran headless, in a render, against the real backend, or not at all. Each sub-phase ends with a **GODOT GATE**: suite counts before and after, and the honest "not seen in a headset" line.

## 7.0 Panel sections (S)

Why first: 7.1, 7.2 and 7.3 all add rows. Do this before any of them.

- **Option protocol** (`features/feature_tool.gd` doc, `table_props_window.gd` `_rebuild`): an option may carry `"section": "<name>"`. Consecutive options with the same section sit under one heading button.
  A section may carry `"collapsed": true` (the default for advanced groups); the heading toggles it. Options without a section behave exactly as now, so every existing tool is unchanged.
- State: the panel remembers which sections the user opened for the current tool until the tool changes. `option_ids()` still lists every option, folded or not, so tests and the editor are unaffected.
- First users: Pattern (fold "Second direction" and, for circular, "Orientation"), then the new Extrude groups in 7.1.
- Budget to hold to from here on: the **default view** of any tool fits in about 7 lines; measure the real header height in the render test and replace the estimate above.
- Tests: extend `design_table_props_panel.gd` (a section folds and unfolds; a folded option is still in `option_ids()`; pressing a folded option's id still routes); add Pattern and Extrude to `dock_panels_render.gd` and look at the pictures.
- Exit: Pattern's default view is 7 lines or fewer; nothing else changed in behaviour; suite green.

## 7.1 Extrude depth (M)

Everything is options on `extrude_tool.gd` and `PartFeatures.extrude_request`; Edit and preview follow because they already go through the same request.

| Option | Backend field | VR behaviour |
|---|---|---|
| Both sides (symmetric) | `start_distance` / `end_distance` | Client mapping only: depth `d` becomes `-d/2 .. +d/2`. Flip is ignored while it is on. |
| Thin wall | `thickness`, `thickness_direction` | Section "Thin wall": a toggle, the wall thickness (typed, mm, greater than 0) and Outward / Inward / Symmetric. |
| Draft | `draft_angle`, `draft_outward` | Section "Draft": the angle (typed, greater than 0 and less than 90) and an Outward toggle. |
| Which profiles | `profile_refs` | Only when the sketch has several outer profiles: a "Pick profiles" mode using the existing sketch-curve picks (`sketch_picks.gd`); empty means all, as now. Droppable if it fights the seed-sketch flow. |

- **Exclusions in the UI, not just the backend:** turning Thin wall on greys Draft and the other way round, with the reason in the tool tip; Draft is greyed while more than one profile would be extruded.
  The backend's 422 detail is shown in the status line for anything that still gets through.
- **Edit and PATCH:** `patch_keys()` gains `thickness`, `thickness_direction`, `draft_angle`, `draft_outward`, `profile_refs`; `load_from_row` reads them back; the PATCH must send an explicit `null` to
  turn thin wall or draft off (the update schema distinguishes omitted from null). Check that the Godot JSON writer sends `null` for a `null` Dictionary value. The Build row's summary line shows "thin 2 mm" / "draft 5 deg".
- **Preview:** the eager preview's PATCH carries the new fields.
- Tests: request building and the exclusions (`design_table_feature_tools.gd`); Edit round trip (`design_table_editing.gd`); a new real-backend `e2e_extrude_options.gd`: a symmetric 20 mm box spans -10 to 10, a thin
  wall has the expected volume (Measure), a drafted prism has a tapered side face, turning thin off by Edit restores a solid, the thin + draft conflict is refused with the backend's message. Open the saved file in the
  flat app's test harness if one can run, otherwise say it was not run (as for Phase 6).
- Exit: all four in the panel with sections, Edit and Undo / Redo work, e2e true.

## 7.2 Small tool options (M)

Four independent pieces; any order.

- **Chamfer angle and flip.** Section "Angle": On/Off, the angle (typed, degrees), Flip. Applies to every picked edge by writing `edge_options[i] = {angle, flip}` for each index (the reference face defaults to the
  lower-indexed adjacent face; `face_ref` is not sent). Per-edge overrides are later. Edit loads `edge_options` back (all equal means the simple form shows; mixed values show "per edge, edit in the flat app").
- **Move Face by direction.** A mode toggle Offset | Direction. Direction takes a fixed axis X / Y / Z or a picked sketch line (reuse `PatternTool._direction`) and a distance; sends `direction_ref` + `direction_distance`
  and no `offset_distance`. The `delta` mode stays out.
- **Pattern: skipped instances and orientation.** Section "Skip": a typed comma-separated list of instance numbers on the popup keyboard (`open_keyboard_for`), validated against count (the seed, 0, is refused; the backend
  also validates). Section "Orientation" (circular only): Rotate with pattern | Keep orientation (`orientation_mode`; the backend documents Radial-to-axis as identical to Rotate, so it is not offered). v1 is typed; tapping
  ghost instances to switch them off is a later nicety and needs a way to pick one instance out of the preview (not checked against the coarse-preview output).
- **Loft thin wall.** Section "Thin wall": thickness and the closed-profile toggle (`thickness`, `thin_from_closed_profile`); `patch_keys` and `load_from_row` extended; guide curves are **not** here (see Deferred).
- Tests: per-tool request and Edit tests as in 7.1; real-backend `e2e_options_small.gd` (an angled chamfer face, a face moved 10 mm along Y, a 5-instance pattern with instance 2 skipped has 4 bodies, a thin loft).
- Exit: each piece reachable from the panel, edited from the Build row, undone and redone.

## 7.3 Create Plane types (L)

The riskiest sub-phase: it needs a new pick state and a method switch. Do the pre-work in the first two bullets, then one type at a time, testing each before the next.

- **Pick plumbing:** a `pick_vertices` editor state (laser hit through `topology_pick.gd`, vertices only, highlighted like edges), `vertex_refs()`, and `PartFeatures.vertex_ref(body_id, index)`. Generalise `plane_base` to
  numbered plane slots (`wants_plane_pick` fills the next empty slot).
- **First check:** `plane_markers.gd` draws a made plane from the backend's origin / x / y / n; confirm with a midplane and a three-point plane that the marker and "sketch on it" work for planes that are not offsets.
- **Method switch** at the top of the panel (a toggle group): Offset (today) | Midplane | Through vertex | Normal to edge | Three points. The tool tip says what is missing for the chosen method; the Selected list shows each slot.

| Method | Backend `plane_type` | Picks |
|---|---|---|
| Midplane | `midplane` | two plane-likes (a reference plane, a flat face or a made plane); the backend rejects non-parallel pairs, show its message |
| Through vertex | `parallel_to_face_through_vertex` | one plane-like, one vertex |
| Normal to edge | `normal_to_edge_through_vertex` | one straight edge, one vertex |
| Three points | `three_points` | three vertices (`point_refs`, each `vertex_ref`) |

- **Edit:** the plane's references can be changed (the update accepts them); the type cannot (not in the update schema), so Edit opens the same method. Offset editing with a negative value is already refused by the numeric
  pad; fix it here with the Reverse toggle the create path uses.
- Tests: request building per method with the backend's exact field rules (fake backend); picks with simulated controllers (`design_table_create_plane.gd`); real-backend `e2e_create_plane_types.gd` per method (a plane
  midway between two box faces; through a corner and parallel to a face; normal to an edge at its end vertex; through three corners), each followed by a sketch on it and a 5 mm extrude.
- Risk: vertex picking only considers the hit face's own boundary and prefers the nearer of edge and vertex, so aiming at a corner has to be on a face close to it. Fine for a first version; flag it for the headset session.
- Exit: the four methods make planes that render and take a sketch.

## 7.4 Sketch construction methods and `point_on_ellipse` (M)

- **Methods** (options row of the tool, like the flat app's construction-method bar): Circle: centre-radius | three points on the circle (circumcircle computed client-side, created as a centre and a radius point);
  Rectangle: two corners | centre-corner | three points (a rotated rectangle: `axis_aligned: false`, four corner points computed from the three taps); Line: end-to-end | midpoint (first tap is the centre, the second one end, the other end mirrored).
  Snapping, references and undo behave as for the existing methods; each method is one Undo step.
- **`point_on_ellipse`:** add to Select's menu when exactly one point and one ellipse are selected, mirroring the flat app's `pointOnEllipse` entry; glyph in `CONSTRAINT_GLYPHS`.
- Tests: pure geometry for the three computed shapes (a circle through three known points, a rotated rectangle of known size), `sketch_session.gd` calls against the fake backend, `e2e_sketch_select.gd` extended with the new menu
  entry against the real constraint schema, and a picture test for the rotated rectangle.
- Exit: each method draws, dimensions and extrudes; a point can be held on an ellipse.

## Order, sizes and gates

Sizes: 7.0 S, 7.1 M, 7.2 M, 7.3 L, 7.4 M. 7.4 can run any time after 7.0. Suggested order is 7.0, 7.1, 7.2, 7.3, 7.4, because 7.1 and 7.2 are what everyday parts need soonest and 7.3 benefits from having had the
sections for a while. After 7.4: **GODOT GATE E** (full headless suite, `ci_render.sh`, the whole `ci_e2e.sh`), then update `docs/design-table-gaps.md` (item 7 and G8), `docs/design-table.md` (the deck table's "Not built yet" column),
`docs/status.md` and the roadmap.

## Deferred out of Phase 7 (now in roadmap step 4, "Sketch ergonomics and picks")

These need picking or preview work that Phase 7 does not build, so they were moved rather than squeezed in:

- **Mirror and Pattern of features** (`source_feature_ids`): a "pick a feature" mode in the Build tree and the viewport.
- **Loft guide curves** (`guide_curve_refs`): picking guide curves from sketches or edges, and showing them.
- **Create Plane from sketch things:** `normal_to_line_at_point`, `normal_to_curve_at_point` (a sketch line or arc plus a sketch point), `normal_to_curve_feature_at_parameter` (a helix or intersection curve, so after the curves work), and sketch points in `three_points`.
- **Pattern ghost-tap** to skip instances; **per-edge** chamfer overrides; **Move Face by `delta`** and **Move Body rotation**.

## Not in scope

Anything needing the headset to decide (panel layout and colour, roadmap item 8; the 250 ms chord, ring size and so on), sub-assemblies, gears, surfacing, Inspect and export. Those are steps 2, 3, 5 and 6 of the rollout order.
