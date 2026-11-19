# Parity follow-ups: investigation (2026-11-19)

Investigation, not fixes: what is left after the "dimensions and constraints at parity" plan
([`dimension-constraint-parity-plan.md`](dimension-constraint-parity-plan.md), section 10 and the tracker's handoffs), checked against the code on
`main` in both repos (DIDSA-VR `c7a2926`, DIDSA-CAD `5c4468f`). Each item is confirmed or refuted from the code, with its cause, how a user
would see it, a fix size (**S** under ~200 changed lines, **M** ~200-700, **L** above) and a recommendation. The fixes are grouped into follow-up
sessions F1-F8 at the end, written like the plan's section 6. No code was changed.

**How it was checked.** Code read on `main` (citations are `file:line` on those commits; DIDSA-CAD paths are prefixed `CAD`). Run here:
headless Godot 4.7.2 probes (the breadcrumb text, the Properties panel's layout, redraw timings), a local DIDSA-CAD backend from `main` (a
mid-size sketch built through the routes; what the solver reports for redundant constraints; `tests/e2e_references.gd` against `main` and
against a backend from 2026-11-11; the full `tests/ci_e2e.sh` list), `tests/session_marks_presenter.gd` 12 times, and (after the owner's answers) VR's `PointDrag` on shapes made through the real backend. Nothing was run on a
headset or in the flat app's UI. "Read" below means checked by reading only.

## Decisions (owner's answers, 2026-11-19: all answered)

| # | Question | Answer |
|---|---|---|
| 1 | **B1** Stick ownership while previewing a dimension | **(c), accepted**: whenever a preview is live and the laser is on the sheet, except when Orbit lock is off and a hand grips |
| 2 | **B2** Where the number pad opens after a drop | **(c), accepted**: at its dock, with a leader line from the pad to the frozen label |
| 3 | **B3** The drag projector's as-built behaviours | **Fix the straight-chain stall** (CAD first, then VR). The 9e-4 mm shortfall and the 0.2-0.5 mm arm offset stay (the offset may improve as a side effect; it is not a target) |
| 4 | **A1** Where sketch names live | **(a), accepted**: the backend numbers each entity and dimension at creation and keeps the number (scheme in A1) |
| 5 | **A2** The selection drawer in a sketch | **(b), accepted**: breadcrumb and X only; the Properties panel is the one panel |
| 6 | **C4** An ellipse axis dimension: semi or full value | **A toggle in both apps, like Radius / Diameter**: "Show full axis" / "Show semi-axis" on a selected axis dimension; the editor shows and accepts the value on show (design in C4) |
| 7 | **C3** Shape drags | **Build now** (the owner asked why not; measured here: VR's shape drags drift today, see C3) |
| 8 | **C6** Per-entity constraint colours in VR | **(a), accepted**: DIDSA-CAD writes the flat app's calculation (`dof_analysis.dart`) as a spec with test vectors; VR re-implements it from the spec (as the drag projector was done) and colours each entity |
| 9 | **D1** VR's e2e job | **(b), accepted**: also on push to `main` (same paths) and weekly |
| 10 | (new, from 6) Is the Radius / Diameter and semi / full choice saved? | **Yes, accepted**: saved in the dimension's label record (the `PUT .../label` that saves its placement, a `show` field), read and written by both apps, so it survives a reload and both apps show a dimension the same way |

## Summary

| Item | Confirmed? | User impact | Fix size | Recommendation | Session |
|---|---|---|---|---|---|
| A1 Unreadable sketch names | **Yes**: VR shows `Line <uuid>`; both apps pass id-bearing backend errors through; the flat app numbers by position and appends the solver's developer text to take-back messages | High: every sketch selection in VR | Backend M, flat S, VR S | Backend-assigned numbers (decision 4); readable messages | F4, F5 |
| A2 Options in one panel | **Yes, partly**: Prev / Next / Back duplicate the kind buttons, B and the pad's Cancel; the 5-kind cap drops nothing today (the catalogue's maximum is 5) but would hide a sixth silently; the "nine buttons wide" row does not exist (it wraps), but **3 of a line's 4 kind labels are clipped** | High: the lit kind cannot be read | M | One panel, grouped, no paging, no Prev / Next / Back | F2 |
| B1 Stick only with no grip | Confirmed as built; with Orbit lock on (the default) the stick does nothing to the part in a sketch anyway | Low-medium: cycling stops while the other hand holds the table | S | Decision 1 (c) | F2 |
| B2 Pad at its dock | Confirmed as built | Medium: the eye leaves the label to type | S for (c) | Decision 2 (c) | F2 |
| B3 Projector behaviours | Confirmed (pinned by the vectors) | (a) none visible; (b) a straight dimensioned chain cannot be dragged at all, and VR then says "Point moved."; (c) the end lands 0.2-0.5 mm off | CAD M, VR S | Fix the stall only (decision 3) | F6, F7 |
| C1 Redraw cost | **Yes, and worse than estimated**: `_refresh_view` 38 ms median on this PC for a 121-point sketch (rebuild alone 21 ms; 2.8 ms with labels hidden); it runs on every accepted drag frame and every hover change | High on a Quest: a few redraws a second while dragging | M | Reuse labels, one dimension pass, move only what moved during a drag | F3 |
| C2 Drop sends the last accepted frame | Confirmed; also no busy guard at the press, and "Point moved." when nothing moved | Low-medium | S | One synchronous solve at release if the last wish was not run; refuse a press while busy | F3 |
| C3 Lines / shapes do not drag well; spline tangent unsupported | Confirmed; the flat app has a rigid line drag and closed-form shape proposals. **Measured: in VR a circle's centre drag resizes it, a rim drag moves its centre, a polygon vertex drag moves its centre, a rectangle corner drag moves the opposite corner** | Medium-high | Line S-M; shapes CAD S-M + VR M | Build both now (decision 7) | F6, F8 |
| C4 Ellipse axes | Confirmed: an elliptical arc's axis saves no placement and a flat-app placement is read as none; the flat app's ribbon edits the half of what its canvas shows | Low | VR S-M, flat S-M | Draw the arc's axis radially; a semi / full toggle in both apps (decision 6) | F5, F4 |
| C5 Existing dimension retyped | Confirmed for the two-line angle, point-to-line and line-to-line distance (the flat app updates those in place) | Medium: a refusal or a stacked duplicate | S | Patch the existing one, as the flat app does | F5 |
| C6 Whole-sketch tint | Confirmed | Medium: no hint which line still needs a dimension | CAD S-M, VR M | Port from a CAD spec (decision 8) | F6, F7 |
| C7 `hand` hit sizes | Confirmed: guesses, nothing switches to them | None today | - | Leave until hand tracking; measure then | - |
| C8 Flat take-back checks | Real solver checked here: a redundant but consistent constraint **converges** (`result_code` 5) and is kept by both apps; an inconsistent one fails and the failed list names it. CAD CI ran the full `flutter test` on `main`: green | Low | S | Pin the solver's answers in backend tests | F4 |
| D1 CI on `main` | Headless, render and CAD client / store jobs green; **VR's e2e job never ran on the merge** (PRs and by hand only); run here: two stale S4 assertions, the known flaky outage line, and **a checker blind spot** (SMOKE lines cut to 200 characters before checking hide a long label's `false`) | Medium | S | Fix the stale lines and the cut; run e2e on push to `main` | F1 |
| D2 `e2e_references` | Reproduced (corner moves 30 mm on the sheet, test expects 15) with today's backend and one from 2026-11-11: **the test is wrong, not the code** | None for users | S | Compare with the corner's real new place | F1 |
| D3 `session_marks_presenter` | Not reproduced (12 runs, 4 in parallel); the log keeps only SMOKE lines, so a silent run's cause is lost | Test noise | S | Keep the tail of a silent test's output | F1 |
| D4 Stale branches | Nothing to delete that is not on `main` | None | - | List below | - |
| D5 Copied fixtures | All seven copies equal DIDSA-CAD `main` today; **CI never compares them** (no CAD checkout) | Drift goes unnoticed | S | Check out DIDSA-CAD in the headless job | F1 |

---

## A. The owner's observations

### A1. Sketch entities have long, non-human-readable names

**Confirmed.** A sketch selection is `{kind, id}` with no label (`scripts/design_table/sketch_session.gd:2226`, `table_editor.gd:806-814`), so
`selection_breadcrumbs.gd:29-30` falls back to the id: run headless, a line reads `Line 9b1f3c2e-4d5a-4e6f-8a7b-0c1d2e3f4a5b` (the drawer
clips it, `selection_drawer.gd:173-174`, so the user sees a cut-off UUID). A dimension or constraint reads just `Dimension` / `Constraint`
(`selection_breadcrumbs.gd:31-32`) and the sketch rung is always `Sketch` (`table_editor.gd:829-830`).

Where an id or machine text can reach a person:

| Where | VR | Flat app |
|---|---|---|
| Breadcrumb / selected list | `Line <uuid>` (above) | `Line 2` by position (CAD `client/lib/sketch/sketch_controller.dart:10213-10247`, shown in `sketch_ribbon.dart:715`) |
| Status line / error messages | Backend `detail` passed through verbatim (`cad_api.gd:114-125`) by every "Couldn't ...: %s" (`sketch_session.gd:497, 515, 814, 1343, 1563`, delete `2106-2122`); a structured detail shows its `type` word (`cad_api.gd:121`) | `errorMessage = error.message` (`sketch_controller.dart:7863, 8530, 8540`) |
| Backend texts that carry ids | trim / extend / split ("line <uuid> - it is an edge of polygon <uuid>", CAD `backend/app/sketch/models.py:2407-2600`), offset (`:3462, 3533, 3584`), "Point is still referenced by line <uuid>" (`:4223-4267`, 400 from `router.py:885-891`), rim point (`:4719`), reference dimensions (`reference_dimensions.py:22-39`), sketch file (`router.py:797`) | same |
| Take-back message | plain words (`sketch_session.gd:814-819`) | **appends the solver's developer `detail`** in brackets (`sketch_controller.dart:3258-3260`, set at `:3168`): "(Solve did not fully converge. blamed_constraint_ids names the most-recently-added constraint by convention only ...)" (CAD `solver.py:1554-1561`) |
| Options row, undo labels, tablet pages, feature tree, dimension and reference-dimension labels | no ids (values and fixed words) | no ids |

Which VR flows can actually trigger each id-bearing backend text was read, not run (VR guards many: the delete cascade removes constraints first).

**Does a human name exist?** The backend has none: every entity id is `uuid4` (CAD `models.py:1329` and on) and no entity or constraint carries a
name or number. The flat app's `Line 2` is the entity's position in its kind's map, "stable for this session only" by its own doc comment:
deleting Line 2 renames Line 3 to Line 2, an undo of a delete re-creates the entity at the end under a new number, and two apps (or a live
session's observers) disagree whenever their views differ. The order itself is the backend's dict insertion order (read; not checked across a
save and reopen).

**Recommended scheme (decision 4: backend).** The backend gives each new sketch entity a per-sketch, per-kind number at creation and stores it
(`number`, never reused, gaps after a delete, as SOLIDWORKS' `Line7`): **`Line 3`, `Point 12`, `Circle 2`, `Arc 1`, `Ellipse 1`, `Spline 1`,
`Text 1`**; the origin is **`Origin`**; a part reference point is **`Part corner 2`** / **`Hole centre 1`**. Dimensions share one counter,
**`D4`**, shown with their kind and value (`D4 Length 40`); reference dimensions **`(D5)`**; relations by type, **`Coincident 2`**. Old
sketches get numbers on load in their stored order (so the flat app's current labels are what they get). Create routes accept an optional
`number` so an undo that re-creates restores the old name. Backend error texts use the names. Both apps read `number` (falling back to
their position rule on an older backend). Why the backend: it is the only state both apps and a live session's observers share, it survives
a reload, and the error texts can use it. The client-only rule (b) costs S per app but renumbers on every delete. Sizes: backend M, flat S,
VR S. The flat app's bracketed solver detail is dropped in the same session (S).

### A2. The options row should be one panel

**Partly confirmed.** The Dimension tool's list (`table_editor.gd:2432-2448`) does not render as one row: the editor's options go to the
Properties panel (`design_table.gd:206`, `table_props_window.gd:122-205`), a 0.30 x 0.40 m panel (516 x 688 px, `:42-43`) that wraps toggles as
110 px chips (`CHIP_WIDTH`, `:17`, `:231`) and pairs other buttons two to a line, with a vertical scroll. Laid out headless with a line's
options (4 kinds, All at once, Prev, Next, Back): 4 lines, 194 of 494 px used, and **"Horizontal length", "Vertical length" and "Angle to
horizontal" clipped** in their 115 px chips (text 112-147 px, `clip_text`, `:225`); for a point and a circle, "Minimum distance" is clipped.
So the user cannot read which kind is lit. (S7's "up to nine buttons wide" assumed the old deck row.)

- **Prev / Next** (`:2443-2445`) duplicate the kind buttons: a press on a kind already chooses it (`on_option` `dk:`, `:2606-2613`), which is
  the hand-ready mirror of the stick. **Back** (`:2446-2447`) duplicates B and, at the pad stage, the pad's own Cancel (handled at
  `table_editor.gd:2353-2355`); with a pick held, a pull on the picked entity already lets it go (S4).
- **The 5-kind cap** (`:2438`, `MENU_SLOTS - 1`): the catalogue's largest entry has 5 options (point / circle and the curve pairs), so nothing is
  dropped today, but a sixth would vanish without a "More".
- **Paging elsewhere** is a leftover of the old row: the Select menu is cut into pages of 5 + "More n/m" (`_menu_options`, `:2562-2569`;
  `sketch_selection.gd:170-178`) although the panel has room for every item (a line's whole menu of ten is five lines, ~250 px). The same menu
  is shown a second time in the selection drawer as 4 actions + More (`table_editor.gd:847-848`, `selection_drawer.gd:26`).

Every option context in the sketcher:

| Context | Options (most) | Fits today? |
|---|---|---|
| Dimension tool | up to 5 kinds + All at once (+ Prev, Next, Back) | wraps; labels clipped |
| Select, entities picked | dimension candidates (up to 5, or the pinned block's reference kinds), relations (up to ~7), Merge, Fix, Unfix, Construction / Solid, Delete, Clear (`sketch_selection.gd:76-98`) | paged 5 + More here, 4 + More in the drawer |
| Select, a dimension / glyph picked | Edit value, Show diameter / radius, Other side (S6), Delete, Clear (`sketch_selection.gd:102-118`) | yes |
| Reference repair | Fix n reference(s), Keep moved ones / Skip, Stop fixing | yes |
| Drawing tools | line (2-3), circle (2), rectangle (3), polygon (3), spline (1), text (4), offset (2) (`table_editor.gd:2536-2558`) | yes |
| Part Fix mode | Apply fix, Clear, Cancel | yes |

**Recommended design.** The Properties panel is the one panel. Each context is a short list of **groups**, each under a caption (the panel
already supports `group` captions and `wide`, `table_props_window.gd:12-14`):
- Dimension tool: **KIND**, one exclusive toggle per kind, **two to a line** at half width (~237 px: every catalogue label fits, the widest is
  148 px), the previewed kind lit; **SHOW**: "All candidates" toggle. No Prev / Next / Back.
- Select: **DIMENSIONS** (the candidates with their values), **RELATIONS**, **EDIT** (Fix / Unfix, Construction, Delete, Clear). No paging; the
  scroll stays as the last resort.
- A picked dimension: **EDIT** as today.
In a sketch the drawer keeps the breadcrumb and X only (decision 5). Reuse: `tablet_pages.gd:414` `_choice_row` (a titled exclusive group with
`per_row`) is the pattern for KIND; `table_props_window.gd` needs a "half-width toggles" layout (or `per_row`) beside its chips. Hand-ready
holds: every stick action has its button (a kind button is the step), B's has the pad's Cancel and a second pull. If hand tracking lands
without a cancel gesture, a fixed "Cancel" in the panel's footer (not a row item that comes and goes) is the place for it. Size M (editor
lists, panel layout, `sketch_selection` groups, tests: `design_table_intents.gd` checks the buttons S7 added, `design_table_props_panel.gd`,
`design_table_dimension_preview.gd`).

## B. Owner decisions still open

### B1. The stick cycles kinds only while no hand grips the table

As built: `dimension_preview.gd:107-110` (`preview_live and laser_on_sheet and not gripped`), called from `table_manip.gd:234`. What the
stick does otherwise in a sketch: with **Orbit lock on (the default, `design_table.gd:127`)** nothing to the part (`table_manip.gd:240`,
`sketch_locked()` `design_table.gd:809-811`), so the grip rule protects nothing in the default case and only stops cycling while the other
hand holds the table; with Orbit lock off the stick turns the part, and the rule gives it back to turning while gripping.
- (a) keep: no change; cycling stops whenever either hand grips.
- (b) drop the grip test: simplest; with Orbit lock off a grip no longer turns the part by stick while previewing on the sheet.
- (c) `preview_live and laser_on_sheet and (part_locked or not gripped)`: cycling works while holding the table in the default mode, and
  nothing is lost when Orbit lock is off. **Recommended**, S (one condition and its tests).

### B2. The number pad opens at its dock, not at the dropped label

As built: `_drop_dimension` opens the pad through `design_table.open_keyboard` at its V-8 dock (`table_editor.gd:2376-2392`,
`design_table.gd:534-541`); the frozen label stays drawn on the sheet.
- (a) dock: one place for every typed value (V-8), never covers the sketch; the eye and laser travel from the label to the dock, and the pad's
  title names the kind but not which label.
- (b) at the label (the plan's wording, and the flat app's inline editor): no travel; the pad would cover the geometry being dimensioned, needs
  its own placement near the sheet edges and a second anchoring mode for the keyboard used by one caller.
- (c) dock plus a leader line from the pad to the frozen label (and the label lit): keeps V-8, answers "which one am I typing". **Recommended**, S.

### B3. The sketch drag projector's three as-built behaviours

CAD `docs/motion/sketch-projector-spec.md` 7.4 and 12; reproduced exactly by VR's port (S9).
- **(a) Curved walks stop up to ~9e-4 mm short** (`omega` never grows back after a rejection). 9e-4 mm is under a micron: invisible at any
  zoom the table allows, and the drop's backend solve is exact. **Not a flaw a user notices; leave it.**
- **(b) A nearly straight dimensioned chain does not move** (`scene-chain-20-nearly-straight`: every step infeasible after the correctors, the
  start is a singular configuration). Real: the user grabs the end of a straight run of dimensioned lines and nothing follows. In VR it is
  worse than in the flat app (read, not run): the drop then has nothing to send (`point_drag.gd:142` `moved()` empty), `drop_points` returns ok
  (`sketch_session.gd:3799-3802`) and the editor says **"Point moved."** with the confirm buzz (`table_editor.gd:2041-2043`).
- **(c) The arm near full reach ends 0.2-0.5 mm off its axis** (`scene-arm-followers`, `scene-arm-wall`): the end lags the laser sideways by
  that much and the drop (anchored) keeps it there. Visible only zoomed in; drags are not precise operations; it shares (b)'s cause (the walk
  stalling at a singular start) so a fix for (b) is expected to cover it.
- **Cost:** CAD first: the Dart projector's walk (a perturbation or second-order step when the start is singular and every step is rejected;
  optionally `omega` regrowth for (a)), the vectors regenerated (`tools/sketch_vectors/export.sh`), the spec's 7.4 / 12 rewritten: M (~300 lines
  plus regenerated JSON). Then VR: port the same change to `scripts/motion/sketch_projector.gd`, copy the vectors: S (~100 lines plus JSON).
  The "Point moved." message is a VR fix on its own (F3).
- **Owner (2026-11-19): fix the stall (b) only.** (a) and (c) stay as built; if the stall fix also improves (c), the regenerated vectors show it.

## C. Follow-ups the sessions left

### C1. Drag performance and the whole-sketch redraw

**Confirmed, and the redraw dominates.** Measured headless on this container (Xeon 2.3 GHz, Godot 4.7.2, dummy renderer, so no GPU upload or
draw cost is in these numbers) on a sketch built through the real backend: 10 dimensioned rectangles with a circle each and a 20-point
dimensioned chain (121 points, 79 lines, 10 circles, 169 constraints; 39 dimensions and 110 glyphs drawn):

| Call | Median | Max |
|---|---|---|
| `session.dimension_items()` / `constraint_items()` | 0.4 / 0.5 ms | 0.9 / 0.7 ms |
| `view.rebuild()` | 21.5 ms | 40.7 ms |
| `view.rebuild()` with dimensions and glyphs hidden | 2.8 ms | 3.5 ms |
| `editor._refresh_view()` (what each accepted drag frame calls) | **38.4 ms** | 49.5 ms |
| the same on a 4-line rectangle | 0.07 ms | 0.15 ms |

Cause: every rebuild frees and re-creates every dimension and glyph `Label3D` (`sketch_view.gd:897-911`, `:930`, `:961`), about 0.13 ms per
label here; and `_refresh_view` does it **twice** (`rebuild` ends with `_rebuild_dimensions`, `sketch_view.gd:668`, then `show_ghosts` runs it
again, `:1043-1045`; `table_editor.gd:1834-1836`). It runs on every accepted drag frame (`_point_drag_move`, `table_editor.gd:2000-2028`), on
every hover change of the inferred target (`:521-524`) and of a label (`set_annotation_hover`, `sketch_view.gd:1031-1040`, rebuild +
dimensions again). The projector itself is ~0.5 ms a frame for small groups, 10-11 ms for a 20-point group (S10), off the main thread.

**Quest estimate (not measured):** GDScript on a Quest 3 core is typically 2-4x slower than this container, so ~75-150 ms per accepted frame
for this sketch: the drawing updates a handful of times a second during a drag and the headset drops frames on the main thread while it does;
a hover crossing entities hitches the same way. A small sketch is unaffected.

**Recommendation (F3, M):** keep the `Label3D`s and update their text and transform in place (a pool keyed by constraint id); one dimension
pass per `_refresh_view`; during a drag rebuild the geometry mesh (2.8 ms here, cheaper with only the moved entities) and move only the labels
of dimensions that touch a moved point; on a hover change relight without rebuilding labels. Keep the mid-size sketch as a test fixture (the
state and export of a real backend) with a timing line, so the gain is measured the same way.

### C2. The drop sends the last accepted frame; a busy session at the drop

**Confirmed.** `PointDrag.finish()` waits for the task in flight and returns the last accepted positions (`point_drag.gd:135-150`); a wish newer
than that task's (the laser's last frames) is never solved, so the point lands where the laser was one or more frames before release. While
`session.busy` (`sketch_session.gd:3803-3806`) the drop restores every point and returns no message, so the editor gives the error buzz and
says nothing (`table_editor.gd:2044-2047`). Nothing stops a press while busy: `PointDrag.begin` and `_begin_point_hold` do not check it
(`point_drag.gd:60-68`, `table_editor.gd:1993-2014`); the flat app's `beginPointDrag` refuses when busy (CAD `sketch_controller.dart:7535`).
Busy is likely right after a previous drop (its `solve-and-refresh` in flight), i.e. two quick drags. Read, not run.

**Recommendation (F3, S):** in `finish()`, if the latest wish was not run, run one synchronous call from the last accepted frame (a one-off
~0.5 ms, ~10-20 ms for a 20-point group, at release); refuse a press while busy with a status line; say "Point moved." only when something moved
(else "That point can't move that way.", which also covers B3 (b)).

### C3. Lines and whole shapes do not drag; a spline tangent is `unsupported`

**Confirmed.** `intent_drag_begin` starts a point hold only for a point hit (`table_editor.gd:2096-2101`). The flat app has a rigid line drag
(`beginLineDrag`, both ends translate, the drop's solve settles the rest; CAD `sketch_controller.dart:8380-8410`, `:8401`) and, for the seven
closed-form shapes, a proposal per frame clamped by the constraints (CAD `docs/sketch-drag-hybrid.md`). A spline tangency makes the group
`unsupported` in both apps (the flat app then goes to the network each frame; VR moves nothing and lets the drop's solve place it).
- **Line drag**: S-M in VR (the projector already takes several anchors: both ends with the same offset).
- **Shape drags: measured, they are wrong today.** VR passes the projector no provisional sizes (`point_drag.gd` sets neither `provisional`
  nor `stiff`), so a shape's own size constraints are skipped and the minimum-norm step spreads the motion over the shape's other points.
  Shapes made through the routes VR's tools use (a local backend from DIDSA-CAD `main`), each point dragged 10 mm right and 5 mm up through
  `PointDrag` (synchronous, the editor's own call), with no user constraint on any of them:

  | Drag | What else moved | The flat app's proposal |
  |---|---|---|
  | circle centre | rim (5.16, -1.87): the circle changes size and turns | the whole circle translates |
  | circle rim | **centre (4.65, 0.83)** | the centre stays, the radius changes |
  | rectangle centre | every corner (10, 5): translates | translates |
  | rectangle corner | **opposite corner (-1.11, -0.56)**: it grows about its middle | the opposite corner stays (CAD `sketch_controller.dart:7254-7262`) |
  | polygon centre | every vertex (10, 5): translates | translates |
  | polygon vertex | **centre (4.62, 2.31)** | the centre stays (CAD `docs/sketch-drag-hybrid.md`: "a vertex/rim drag never moves the centre") |
  | slot end centre | the other centre (0.17, 0.87) | (not checked) |

  So a user resizing a hole by its rim sees the hole wander. The fix is the flat app's hybrid: a closed-form proposal per shape family
  (circle, arc, ellipse, ellipse arc, rectangle, polygon, slot) gives every point of the shape a target and switches the shape's
  provisional sizes on at the proposal's values; the projector, which already takes `provisional` and `stiff`, clamps it to the user's
  constraints. The proposals live in the flat app's Dart (`_closedForm*Geometry`, CAD `sketch_controller.dart:6513-7262`), so, as with the
  projector, DIDSA-CAD first writes them into the spec with vectors (S-M, F6) and VR implements them from that (M, F8). Nothing blocks
  building it now; the earlier "wait" was for evidence, which this is. Also missing in VR: the flat app's pre-grab rule that a fully
  constrained point refuses the grab (VR refuses only pinned points).
- **Spline tangent**: wait for DIDSA-CAD's own spline-tangency residual (`docs/sketch-drag-projector.md` item 6), then VR copies the vectors
  and ports one residual (S).

### C4. Ellipse axes

**Confirmed.** An elliptical arc's axis candidates are drawn as linear centre-to-tip and marked `place_unsaved` (`sketch_session.gd:2650-2665`),
so a drop saves no placement (`:3874`); after a reload or in the flat app the label goes back to the automatic place. The other way, the flat
app saves `{angle, leg}` (placement kind `radius`, `tests/fixtures/sketch_label_placement_cases.json`), which VR's linear reader treats as no
placement (`_linear_place`, `sketch_session.gd:2997-3001`): drawn at VR's automatic place. A full ellipse's axis: VR's pad shows the drawn
value (80) and stores half; the flat app draws 80 (CAD `sketch_canvas.dart:3082-3090`) but its ribbon pre-fills and writes the stored 40
(`sketch_controller.dart:11382`, `sketch_ribbon.dart:866`): the flat app disagrees with itself. Read, not run in the flat UI.

**Owner (decision 6): a toggle, like Radius / Diameter.** Design, the same in both apps:
- A selected ellipse axis dimension offers **"Show full axis"** / **"Show semi-axis"** (VR: the EDIT group of the Properties panel, beside
  "Show diameter"; flat: the ribbon, where its R / diameter switch is). The stored value is always the semi-axis, as now; the choice is a way of
  reading it, exactly as diameter is of a radius.
- Semi-axis: drawn centre to tip, the stored value. Full axis: drawn tip to tip, twice the value. The editor (VR's pad, the flat ribbon)
  shows and accepts **the value on show** and stores half when the full axis is shown.
- A new dimension shows what was chosen when it was made (`majorradius` / `minorradius` = semi, `majordiameter` / `minordiameter` = full, as
  the flat app already does for a circle, `sketch_controller.dart:16670`); one with no saved choice shows the full axis (what both apps draw today).
- An elliptical arc's axis gets the same toggle with the radius-style layout (semi: centre to the arc's tip, radial placement kind `radius`;
  full: the circle-diameter style), so its placement is saved and the flat app's is read (S, F5).
- Placement: the `ellipse_axis` kind `{offset, along}` is read on whichever line is drawn.
- The choice is saved (decision 10): a `show` field in the label record, for this toggle and for Radius / Diameter, in both apps.
Sizes: flat S-M (F4), VR S-M (F5).

### C5. Typing an existing angle, point-to-line or distance-to-circle dimension again

**Confirmed for the kinds the flat app updates in place.** VR patches an existing dimension only for point pairs (`_distance_apply`,
`sketch_session.gd:3732-3741`), circle sizes (`:2597-2598`), arc length (`:2604`) and ellipse axes (`:2647-2648`). The flat app also reuses an
existing **point-to-line** distance, **two-line angle** and **line-to-line** distance (CAD `sketch_controller.dart:16450, 16478, 16524`; point pairs
`:16609`). For the part D kinds (angle to horizontal, three-point angle, min / max, tangent / far) neither app reuses one, so they are at
parity. In VR a second constraint is made: with a different value the sketch stops converging and it is taken back with "can't satisfy"
(`_taken_back`, `sketch_session.gd:786-797`); with the same value the solver accepts it (C8) and two labels sit on top of each other.
**Recommendation:** the same three lookups in `_ghosts_raw`'s apply (S, F5).

### C6. Whole-sketch tint vs per-entity colours

**Confirmed.** VR tints object lines `FULL_COLOUR` only when the whole sketch is fully constrained (`sketch_view.gd:42`, `:556`); the flat
app colours each line / circle / arc from `dof_analysis.dart` (659 lines, a union-find rigidity count; used at `sketch_canvas.dart:4627-4631`).
In a half-done VR sketch nothing says which line still needs a dimension. **Recommendation (decision 8):** as with the projector, DIDSA-CAD
writes a short spec and exported vectors from `dof_analysis.dart`'s tests (S-M), VR writes `scripts/design_table/sketch_rigidity.gd` from the
spec and colours per entity (M). A backend answer would be one implementation but a round trip per edit, and the flat app already has its own.

### C7. The `hand` hit sizes are guesses

**Confirmed.** `input_source.gd:9-12` (hand = ~1.7x pick, 1.5x ghost); `set_input_source` (`table_editor.gd:445`) is called only by
`tests/design_table_intents.gd:283-288`. No user impact today. **Recommendation:** no session; when hand tracking lands, a spike on the owner's
headset measures the pinch ray's shake and sets the numbers.

### C8. The flat app's take-back against the real backend

Run here against a local backend from DIDSA-CAD `main` (`solve-and-refresh` after each step):

| Case | `converged` | `result_code` | failed ids | Both apps |
|---|---|---|---|---|
| a second Horizontal on the same line | true | 0 | [] | kept |
| the same distance twice (two free points) | true | 5 | [] | kept (stacked labels) |
| Horizontal + horizontal distance + aligned distance of the same length | true | 5 | [] | kept |
| distance 10, then 12 between the same points | **false** | 1 | [the 12] | taken back, the failed list names it |

So a redundant but consistent constraint is accepted (py-slvs "redundant, okay") and neither app takes it back (VR `sketch_session.gd:786-797`;
flat `sketch_controller.dart:3242-3248` read the same flags). One oddity: in the duplicate-distance case the reported DOF fell from 3 to 1; in
the others it stayed right, and a false "fully constrained" was not reproduced. DIDSA-CAD's "Client - build and test" workflow ran the full
`flutter test` and `flutter analyze` on `main` at `5c4468f` (after the S1 follow-up) and passed. Still not run: the drawing-path take-back for
anything but the inferred Horizontal, in either app's real UI. **Recommendation:** pin these four answers in a backend test (S, F4), since both
apps' take-back depends on them.

## D. Test health and repo hygiene

### D1. CI on `main` after the merge

| Repo | Workflow (run) | Result |
|---|---|---|
| DIDSA-VR | Headless tests #352 on `c7a2926`: jobs `headless` and `render` | success, success (render is `continue-on-error`, it passed) |
| DIDSA-VR | E2E against the real backend | **did not run**: it triggers on pull requests and by hand only (`.github/workflows/e2e-backend.yml:6-24`); the parity work went to `main` without a PR. Last run 2026-11-14: failure. |
| DIDSA-CAD | Client - build and test #1318 on `5c4468f` (full `flutter test`, `analyze`, debug APK) | success |
| DIDSA-CAD | Client - project store end to end #21 | success |
| DIDSA-CAD | Backend - build and test #1064 on `952530f` (#385; no backend change since) | success |

The full e2e list run here instead (`tests/ci_e2e.sh`, all 66 tests of `tests/e2e_ci_list.txt`, against a backend, project store and hub
from DIDSA-CAD `main`): **960 SMOKE lines, 3 reported failures, and one more the checker cannot see**:
- `e2e_design_table.gd:152` "the Dimension tool offers the circle's radius": stale since S4 (a circle lists Diameter first, so `ghosts[0]` is
  the diameter, 8).
- `e2e_references_lost.gd:166` "offers radius 3 as a driven candidate": stale since S4 (a pinned arc now offers the `pinned` block's three
  reference kinds; the log shows `[radius 3, diameter 6, arcLength 4.71]`, the test wants two).
- `e2e_cloud_outage` "kept the chunks it had across the restart": the known flaky line (`docs/status.md:41`), not parity work.
- `e2e_references` (D2) prints `false 30.0` but is **not reported**: `ci_e2e.sh:83` (and `run_all.sh:26` for the headless suite) cut every
  SMOKE line to 200 characters before `tests/check_smoke.py` reads it, and this label is longer than that, so its value is cut off. **Any check
  whose label is ~195+ characters can never fail CI.** In this run's 960 e2e lines it hides this one false; in `tests/*.gd` 16 `print("SMOKE ...`
  sites have a label of 190+ characters (a static count; `_check()`-style labels not counted). The parity sessions' "0 failures" in `ci.sh` are
  subject to the same hole.

So the parity work left two stale e2e assertions that nobody saw because the e2e job did not run, and the checker has a blind spot.

### D2. `tests/e2e_references.gd`: "the pinned corner followed the part"

**Reproduced, and the test's expectation is wrong.** Against today's backend and against one from 2026-11-11 (`9535099`) the corner moves
**30.0 mm** on the sheet; the test wants 15 (`tests/e2e_references.gd:158`), on the assumption that "the sketch's plane is centred on the face".
It is not: a sketch on a face sits on a Plane feature whose origin is OCCT's plane location for that face (CAD
`backend/app/document/create_plane.py:191-207`), not the face's centre; for this box that origin stays put when the box is widened (measured:
the corner moves the full 30 mm on the sheet). The corner moved 30 mm in the world, so 30 mm on the sheet is the correct follow; the dimension holds and nothing is flagged (the
test's other nine lines are true). **Fix (F1, S):** compare the pinned point with the corner's new position as the sheet sees it after the
refresh, not a fixed 15.

### D3. `session_marks_presenter` printed no SMOKE lines once

**Not reproduced:** 12 runs (three rounds of four in parallel, with `run_all.sh`'s environment), 19 SMOKE lines each, 6.3-6.8 s. The test uses
the in-process fake hub and fake backend (no ports, sockets or hub process: `tests/fake_session_hub.gd:4`), and its waits are real-time timers
(`create_timer`). It missed twice in full `ci.sh` runs (S3, S5; `docs/status.md:121, 127`). "No SMOKE lines at all" means it stopped before its
first check, i.e. inside `main.tscn`'s start-up or `host_session()` (`tests/session_marks_presenter.gd:33-46`), or was killed by `run_all.sh`'s
300 s `timeout`; the cause cannot be read because `run_all.sh` keeps only SMOKE lines (`tests/run_all.sh:26-27`) and not the exit code.
**Recommendation (F1, S):** when a test prints no SMOKE line or exits non-zero, `run_all.sh` prints its exit code (124 = timed out) and the last
30 lines of its output; the test prints a SMOKE line before `host_session()` returns ("hosting started").

### D4. Remote branches

| Repo | Branch | Tip | On `main`? |
|---|---|---|---|
| DIDSA-VR | `ccr-be4859df-3jil9a` | `c7a2926` | = `main` (the parity sessions' branch) |
| DIDSA-VR | `ccr-2bc2669f-8244ey` | `82b846d` | yes, an ancestor of `main` (the parity scope and plan) |
| DIDSA-CAD | `ccr-be4859df-3jil9a` | `5c4468f` | = `main` |

No squash-merged branches remain; every branch's content is on `main`. Plus this document's branch, `ccr-30fb030e-pts96i` (DIDSA-VR, not
merged). Nothing deleted.

### D5. Copied fixtures

VR keeps copies of seven DIDSA-CAD files; each test compares its copy with `../DIDSA-CAD` (or `DIDSA_CAD_DIR`) when a checkout is there and
passes with "no source" when not (e.g. `tests/sketch_projector_vectors.gd:28-32, 85`, `tests/sketch_dimension_catalogue.gd:199-203`). Compared
here with DIDSA-CAD `main`: `sketch_vectors.json`, `sketch_dimension_catalogue.json`, `sketch_label_placement_cases.json`,
`motion_vectors.json`, `appearance_vectors.json`, `file_lookup_vectors.json`, `scene_vectors.json`: **all equal**. CI does not compare them:
the headless job checks out only DIDSA-VR (`.github/workflows/headless-tests.yml`), and the e2e job, which does check out DIDSA-CAD, runs only
the e2e list. A change on the CAD side is never seen by VR's CI. **Recommendation (F1, S):** the headless job checks out DIDSA-CAD `main`
(public, no token) into `../DIDSA-CAD`, so the `same` checks fail on drift; a weekly scheduled run catches CAD-side changes between VR pushes;
`tests/fixtures/README.md` gets one copy command per file.

---

## Proposed sessions

Same rules as the plan's section 4 (one repo, one branch, one PR, ~1 500 changed lines with tests at most, stop and split at a green
checkpoint; tracker row with a handoff and headset checklist; a dated `docs/status.md` entry; never "works on the headset"). Reading budget as
in section 4. Sizes are lower bounds (the parity sessions ran high).

### F1 - VR: test health and CI (VR, S)
Read: D1, D2, D3, D5 above; `tests/README.md`; `tests/run_all.sh`, `tests/ci_e2e.sh`, the two workflows.
Tasks: `e2e_references.gd` compares with the corner's new sheet position (D2); the stale e2e lines found in D1 (`e2e_design_table.gd:152`: a
circle now offers Diameter first; `e2e_references_lost.gd:166`: a pinned arc now offers three reference kinds, arc length included) and any
other the full list shows; `run_all.sh` and `ci_e2e.sh` hand `check_smoke.py` whole SMOKE lines (cut only what is echoed to the console),
then whatever the uncut headless and e2e runs newly show as false is fixed or baselined with a reason; `run_all.sh` prints the exit code and output tail of a silent test (D3) and `session_marks_presenter.gd` a first line
before hosting; the headless job checks out DIDSA-CAD (D5) and a weekly schedule; the e2e job also on push to `main` (decision 9).
Exit: `tests/ci.sh` green with uncut lines; `tests/ci_e2e.sh` against DIDSA-CAD `main` with no `false` (the flaky outage line excepted or fixed); one local run with a deliberately edited fixture copy
fails the `same` check.

### F2 - VR: one options panel (VR, M)
Needs decisions 1, 2, 5. Read: A2, B1, B2; `table_editor.gd` (`_dimension_options`, `_menu_options`, `on_option`'s `dk*`, `intent_step`,
`_drop_dimension`), `table_props_window.gd`, `sketch_selection.gd` (`options`, `annotation_options`, `page`), `dimension_preview.gd`
(`owns_stick`), `selection_drawer.gd`, `tablet_pages.gd` `_choice_row`.
Tasks: the grouped panel of A2 (KIND two to a line, SHOW, DIMENSIONS / RELATIONS / EDIT; no paging; no Prev / Next / Back; `MENU_SLOTS` gone
from the sketch paths); the drawer in a sketch shows the breadcrumb only (decision 5); B1 as decided; B2 as decided (leader to the frozen label).
Tests: a layout test that no option label is clipped for every catalogue entry's options and the longest Select menu (measure text against
the button, as this investigation did); `design_table_intents.gd` updated (the buttons it checked are gone; the kind buttons are the hand path);
stick ownership with a grip in both Orbit lock modes.
Exit: those pass; `ci.sh` green. Headset checklist: the KIND group read at arm's length; reaching every option without scrolling.

### F3 - VR: redraw cost and the drop (VR, M)
Read: C1, C2, B3 (b)'s message; `sketch_view.gd` (`rebuild`, `_rebuild_dimensions`, `show_ghosts`, `set_annotation_hover`, `_label_on_sheet`),
`table_editor.gd` (`_refresh_view`, `_point_drag_move`, `_end_point_hold`, `_begin_point_hold`), `point_drag.gd`, `sketch_session.gd`
`drop_points`.
Tasks: label pool updated in place; one dimension pass per refresh; during a drag only the moved geometry and the labels of dimensions that touch
moved points; hover relights without rebuilding labels; C2's final synchronous call, busy refusal, honest drop message. A fixture
`tests/fixtures/sketch_midsize_state.json` (+ export) from a real backend (the sketch of C1) and a timing test.
Exit: on that fixture `_refresh_view` at least 5x faster than 38 ms on the same machine class, a drag frame's redraw under 3 ms; the S10 tests
and `ci.sh` green; e2e drop lands at the release point. Headset checklist: a drag on a 40-dimension sketch (frames behind the laser).

### F4 - CAD: names, messages and the solver's answers (CAD backend + client, M)
Needs decisions 4, 6 and 10. Read: A1, C4, C8.
Tasks: backend `number` per entity / dimension / relation as in A1 (assigned at creation, kept, optional on create for undo, back-filled on
load in stored order), in every response and export; backend error texts use names instead of ids; flat app: `selectionLabel` reads
`number` (position rule as fallback), the take-back message drops the bracketed solver detail, the semi / full axis toggle of C4 in the ribbon (the editor edits the value on show);
the backend keeps a `show` field in the label record (decision 10) and the flat app saves and reads both toggles there; backend
tests pinning C8's four answers.
Exit: backend tests and the full `flutter test` + `flutter analyze lib` green; a reload keeps names; a delete leaves the others' names alone;
the toggle round-trips (show full, edit 80, stored 40) and a reload keeps both toggles' choice.

### F5 - VR: dimension edits at parity and names (VR, M)
Needs F4 (for names) and F2 (shared files). Read: A1, C4, C5; `sketch_session.gd` (`_ghosts_raw`, `_dimension_item`, `_distance_apply`,
`confirm_ghost`), `selection_breadcrumbs.gd`, `cad_api.gd` `error_text`.
Tasks: names from `number` in the breadcrumb, the status line and the sketch rung (the open sketch's feature name); C5's three in-place
updates; C4's semi / full toggle (EDIT group, the pad edits the value on show, the saved `show` choice read and written, Radius / Diameter included) and the
elliptical arc's radial axis with its placement saved and the flat app's placement read.
Exit: logic tests; e2e: retype an existing angle and point-to-line distance (one constraint, new value), an elliptical arc's placed axis read
back, a backend name shown in the breadcrumb. Headset checklist: breadcrumb readable.

### F6 - CAD: projector stall, shape proposals and the rigidity contract (CAD docs + client tests, M-L)
Read: B3, C3, C6; `docs/motion/sketch-projector-spec.md`, `docs/sketch-drag-hybrid.md`, `client/lib/sketch/projector/sketch_projector.dart`,
`sketch_controller.dart` (`_closedForm*Geometry`, `_runHybridDragFrame`), `dof_analysis.dart` and its tests.
Tasks: (1) the singular-start fix in the Dart projector (B3 b only), vectors regenerated, spec 7.4 / 12 rewritten; (2) a spec section for the
seven shape proposals (which point is grabbed, every shape point's target, which provisional sizes switch on and at what value, the pre-grab
rule) and exported vectors from the hybrid-drag tests; (3) `docs/sketch-rigidity-spec.md` and
`docs/sketch-rigidity-vectors.json` from `dof_analysis.dart`'s cases. Every export with `--check`.
Exit: `scene-chain-20-nearly-straight` moves; the exports reproducible; full `flutter test` green. Stop and split at (1) | (2) | (3) if it
overflows (the JSON does not count towards the size).

### F7 - VR: projector follow-up and per-entity colours (VR, M)
Needs F6 (1) and (3), and F3. Read: F6's handoff and specs only (VR code is written from the spec). Tasks: port the stall fix, copy the vectors;
`sketch_rigidity.gd` from the spec, per-entity colours in `sketch_view.gd`. Exit: all vectors pass; rigidity vectors pass; `ci.sh` green.
Headset checklist: per-entity green on the slab and a white part.

### F8 - VR: line and shape drags (VR, M)
Needs F3 and F6 (2). Read: C3, F6's shape-proposal spec section; `point_drag.gd`, `table_editor.gd` (`intent_drag_begin`, the point hold).
Tasks: a trigger-hold on a line drags both ends through the projector (two anchors, one offset); a shape point's drag takes the proposal
(every shape point's target, provisional sizes on at the proposal's values) clamped by the projector; the pre-grab rule; drop as for points.
Tests: the shape-proposal vectors; the seven drags of C3's table reach the flat app's answers (centre stays on a rim / vertex drag, the
opposite corner stays, a centre drag translates); e2e: drag, drop, stored points, Undo.
Exit: those pass; `ci.sh` green. Headset checklist: grabbing a line rather than its end with a shaking laser; resizing a hole by its rim.

### Order, model and effort

```
F1 (VR, any time; first, so every later session has working e2e and fixture checks)
VR lane (shares table_editor.gd / sketch_session.gd): F2 -> F3 -> F5 (after F4) -> F8 (after F6 (2)) -> F7 (after F6)
CAD lane: F4 -> F6
```

| Session | Model | Effort | Env pieces | Why |
|---|---|---|---|---|
| F1 | Sonnet | medium | `godot backend` (+ the store and hub requirements for `ci_e2e.sh`) | Named test and CI fixes; causes found here. |
| F2 | Sonnet | high | `godot` | UI layout to a design given here; the clipping test decides it. Opus if the owner's decisions 1, 2 or 5 change the design. |
| F3 | Sonnet | high | `godot backend` | Performance work with a measured target; threading already in place. |
| F4 | Sonnet | high | CAD: backend env + Flutter | A contract change (names) across backend and client, decided here. |
| F5 | Sonnet | medium | `godot backend` | Named changes against F4's contract. |
| F6 | Opus | high | CAD: Flutter | Numerical change in the projector and new spec sections others port from (as S8). |
| F7 | Sonnet | high | `godot` | Port from specs, vectors decide; rerun on Opus from the last green checkpoint if it stops twice on one failure (section 9's rule). |
| F8 | Sonnet | high | `godot backend` | Seven proposal families from a spec on S10's machinery; the vectors decide. |

Not given a session: C7 (wait for hand tracking), the spline-tangent residual (DIDSA-CAD's own item first).

## Checked only by reading

- Which VR flows can raise each id-bearing backend message (A1); the backend's entity order across a save and reopen.
- The flat app's behaviour in its UI (A1 labels, the take-back message text on screen, C4's ribbon value, C5's in-place updates).
- C2's busy case and the late final wish (no test drives them); C3's flat-app line and shape drags (VR's shape drags were run).
- B1's "nothing is lost" (from `table_manip.gd`; the feel is a headset question).
- The Quest estimate in C1 (a scaling factor, not a measurement); the redraw numbers exclude GPU work.
- D3's cause (not reproduced).
