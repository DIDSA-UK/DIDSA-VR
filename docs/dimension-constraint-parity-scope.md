# Scope: dimensions and constraints at parity with the flat app (design table)

Scoping pass, 2026-11-18; the owner's decisions are recorded below (same day). Nothing here is built. The owner's goal: VR dimensions and constraints should match the flat app in **workflow,
capability and completeness**, so that from now on the two move together. It has to work with the Quest controllers now and leave room for
hand tracking later.

**Read first:** DIDSA-CAD `docs/bug-report-2026-11-18-plan.md` (part A: the flat app's dimension flow; part D: the six new dimension types and
the "Notes from the implementation" of both), [`design-table.md`](design-table.md) ("Using it", step 4: how the VR sketcher works today) and
[`scope-references-and-dimensioning.md`](scope-references-and-dimensioning.md) (driven dimensions, references).

## Where the two stand

Worked out from the code (VR `scripts/design_table/sketch_session.gd`, `sketch_selection.gd`, `dimension_layout.gd`, `table_editor.gd`; flat
`client/lib/sketch/sketch_controller.dart`, `dimension_types.dart`, `sketch_canvas.dart`), not from a headset.

### Constraints (relations)

Already close. VR's Select menu is a port of the flat app's selection matrix (`sketch_selection.gd`, from `availableConstraintOptions`).

| Item | Flat app | VR | Gap |
|---|---|---|---|
| Horizontal, Vertical, Parallel, Perpendicular, Equal, Collinear, Concentric, Equal radius, Tangent (line-curve, arc-arc sharing an end), Coincident, On line, Midpoint, On curve, On ellipse, Merge | yes | yes | none found |
| Fix | yes | yes | |
| **Unfix** | ribbon chip | no (Delete on the Fix glyph only) | VR |
| Inferred relations while drawing | yes | yes (adapted: "woken" lines instead of every line) | deliberate difference, keep |
| Glyphs drawn and selectable | every type | the types in `CONSTRAINT_GLYPHS` | check each type is listed (`spline_tangent`, `curve_tangent`, the new D types are dimensions, not glyphs) |
| Picking a glyph lights what it holds | yes | partly (hover) | check |
| **A constraint the sketch cannot satisfy** | kept, the solver's failed list turns the geometry red | **taken straight back out** with a message | **policy differs: decision 1** |
| **Constraint state colours** (fully constrained / under / over) | yes (`isFullyConstrained`, failed-constraint points red) | none; `dof` and `converged` are read and never shown | VR |

### Dimensions

| Selection | Flat app options (default first) | VR candidates today | Gap |
|---|---|---|---|
| 1 line | Length, Horizontal length, Vertical length, **Angle to horizontal** | Length | H / V length, angle to horizontal |
| 1 circle | **Diameter**, Radius | Radius, Diameter | default order |
| 1 arc | Radius, Diameter, **Arc length** | Radius, Diameter | arc length |
| 1 ellipse / elliptical arc | Major / minor radius and diameters | Major / minor radius | diameters |
| 2 points | by cursor: Aligned / Horizontal / Vertical | all three at once | the cursor rule (part of the workflow, below) |
| 3 points (vertex first) | **Angle** (sector by cursor) | none (a third pick restarts) | all |
| point + line | **Perpendicular**, H / V / Aligned to the nearer end | Distance (perpendicular) | H / V / aligned |
| 2 parallel lines | Distance | Distance | none |
| 2 other lines | Angle, **sector by cursor** (quadrant saved) | Angle, nearest rule only | the sector |
| point + circle / arc | Centre distance (by cursor), **Minimum, Maximum** | none (Select offers On curve only) | all |
| line + circle / arc | Perpendicular from centre, **Tangent, Far side** | none | all |
| 2 circles / arcs | Centre distance (by cursor), **Minimum** (when apart), **Maximum** | none | all |
| two pinned things | nothing (reference dimensions from the bar's own chips) | a **reference dimension** offered in their place | VR ahead here (decision 4) |

Bold: part D types, which VR cannot draw, select, edit or delete today (its `dimension_value` returns not-ok for them; its delete cascade
does remove them with their geometry).

| Behaviour | Flat app | VR | Gap |
|---|---|---|---|
| How a dimension is placed | one preview at the cursor, laid out by the label-drag rules; the drawer switches the kind; a click on empty canvas drops it and opens the editor | every candidate floats on the sheet at once; point at one, pull the trigger, number pad | **workflow: the main piece** |
| Label position | where the user dropped or dragged it, saved on the backend (`PUT .../constraints/{id}/label`), the same in the 2D and 3D views | laid out automatically every time (`dimension_layout.gd`: the side with room); the saved placement is ignored and never written | VR (and a placement made in VR does not reach the flat app) |
| Moving a label | drag it | not possible | VR |
| Which side of an angle | the cursor's sector, saved as `quadrant` | the nearest rule; a saved quadrant is ignored when drawing | VR |
| Edit an existing value | ribbon value editor | double pull, number pad | none for the old types; VR lacks the D types |
| Radius / diameter of an existing circle dimension | toggle | no | VR |
| Reference (driven) dimensions | made from the Dimension bar; drawn in brackets | offered automatically between pinned things; drawn in brackets | flat lacks the D kinds (`arc_length`, `horizontal_angle`, `point_angle`, `min_distance`, `max_distance`) in its bar; VR draws D kinds wrongly or not at all (`_ref_dim_key` falls back to linear) |
| Dragging sketch points (feeling what is free) | the client-side projector, every constraint type modelled | **not built** ("constrained sketch drag", `design-table.md`) | VR, large |

## What "move with parity" needs

Today each client has its own copy of "what a selection can be dimensioned / constrained as" (Dart in the flat app, a GDScript port in
VR), so they drift: part D landed in one and not the other. Three ways to keep them together:

| | A: shared catalogue + tests in both (recommended) | B: the backend answers "options for this selection" | C: keep two copies, review by hand |
|---|---|---|---|
| What | One data file in DIDSA-CAD (`docs/sketch-dimension-catalogue.json`): per selection shape, the option keys, labels, default and conditions. Each client keeps its own code; a test in each repo asserts its table equals the file | `POST .../dimension-options` with the picks | as now |
| Drift caught | at test time, in whichever repo moves second | never drifts | by luck |
| Latency | none | a round trip on every pick (VR's laser picks would feel it) | none |
| Licence | data only, nothing copied between Apache / AGPL code | fine | fine |

A also holds the **labels**, so the two apps call things the same. A new type then means: backend, the catalogue, both clients - and the
catalogue test fails in the client that has not caught up.

## The VR workflow, for controllers and later hands

The flat app's flow mapped onto what the design table already does. Each action is written as an **intent** (select, cancel, choose next /
previous, adjust, drag), not a button, so hand tracking can map onto it later.

| Step | Flat app | VR with controllers | VR with hands (later) |
|---|---|---|---|
| Pick | click / tap entities | laser + trigger (as now); a third Point is kept when the first two are Points | aim ray + pinch |
| Preview | one dimension at the cursor | one dimension with its label **at the laser's hit on the sheet**, laid out by the same placement rules as the flat app (port the resolver maths from the plan, not the code) | same, aim ray |
| Choose the kind | drawer chips (the cursor picks for two points) | the **options row** lists the kinds with the current one lit (the row already exists, 6 slots + More); **right stick left / right** cycles them while a preview is live and the laser is on the sheet (the stick already belongs to what the laser is on); the two-point cursor rule as in the flat app | poke the options row (no stick) |
| Angle side | cursor sector, sticky near the lines | laser sector, the same sticky rule | same |
| Drop | click on empty canvas | trigger on empty sheet: freezes kind, placement and side, opens the number pad at the label | pinch on empty sheet |
| Value | type | number pad (as now); optional later: stick up / down nudges by the grid step | number pad by poke |
| Cancel a step | Esc / right-click | **B** (one step back: pad to preview, preview to picking) | a palm-up or deck button (hands have no B) |
| Move a label | drag | hold the trigger on the label and drag (as the table's resize handles do); saved | pinch-hold and drag |
| Edit / delete existing | select, ribbon | as now (double pull, options row) plus radius / diameter switch | poke |

Rules for hand readiness (cheap now, expensive to retrofit): every stick action also has a button on the options row or deck; no
two-button chords in the sketcher; hit areas for labels and glyphs sized for a ray that shakes more than a controller's (the existing
`GHOST_RADIUS`, `GLYPH_HIT_MM` become per-input constants); the intent layer lives in one place in `table_editor.gd` so a hand source plugs in
beside the controller. Hand tracking itself is **not part of this scope**: the owner put it on the DIDSA-CAD roadmap as a roll-out for the
whole VR client (`docs/roadmap.md`, "DIDSA-VR: next-work candidates"), since every tool needs it, not only the sketcher. The hands column above
is what that roll-out should find already in place here.

## Pieces

Sizes as in the other scopes (S = a session or less, M = a few sessions, L = a project).

| ID | Piece | Repo | Size | Needs |
|---|---|---|---|---|
| P0 | **Catalogue.** `sketch-dimension-catalogue.json` from the flat app's table as built; a test in each client that its options match it (VR's will fail until P2: mark the known gaps expected-fail with a reason, and tick them off) | CAD + flat + VR | S | |
| P1 | **See and touch everything.** Draw every constraint and dimension type the backend can send (the six D types; honour a saved label placement and an angle's quadrant), make each selectable, editable (value; quadrant where it has one) and deletable; reference dimensions of every kind drawn correctly; constraint-state colours (fully / under / over) and the DOF on the status line; a haptic tick when the sketch becomes fully constrained (as mates do). Flat side: the D kinds in its reference-dimension bar, and a reference dimension offered where a driving one cannot be made (decision 4) | VR (+ flat, small) | M | |
| P2 | **Options parity.** Every row of the table above, in the catalogue's order and defaults, including the third Point pick and the D types; create through the routes the flat app uses | VR | M | P0 |
| P3 | **Workflow.** Preview at the laser (the default; every-candidate-at-once kept as an option, decision 3), kind choice on the options row and the stick, drop with the trigger, placement and side frozen, saved with the dimension; label drag for existing dimensions; B steps back; radius / diameter switch | VR | M-L | P1, P2 |
| P4 | **Relations and state.** Unfix; every glyph type listed and lighting what it holds; the one conflict rule of decision 1 (the flat app takes a refused constraint back out; VR shows later conflicts red) | VR + flat | S-M | |
| P5 | **Hand readiness.** The intent layer; every stick action mirrored by a button; per-input hit sizes. No hand tracking yet | VR | S-M | P3 |
| P6 | **Constrained sketch drag** in VR: a GDScript port of the flat app's projector (decision 2), re-written from its maths and the drag contract, not copied, the way the mates projector (`scripts/motion/`) was; a residual for every constraint type the flat projector models; golden cases shared with the flat app's `sketch_projector_test.dart` as data | VR | L | P1 |

Order: P0, P1, P2, P3, P4, P5, then P6 (it can start after P1; it needs no part of the workflow). Hand tracking: see the roadmap (above).
P1 alone removes the "invisible dimension" problem from part D.

The deck's options row may be replaced by the docked properties panel (DIDSA-CAD roadmap, DIDSA-VR item 8). P2 and P3 put the kinds wherever the
tool's options live at the time; nothing here depends on it being the six-slot row.

## Tests

- P0: the catalogue test in both clients (the flat one passes at once; VR's lists its expected gaps).
- P1-P4: headless VR tests per type (drawn item, value, edit, delete, placement round trip through the backend, quadrant), extending
  `tests/design_table_logic.gd` and the live-backend e2e set (`tests/e2e_ci_list.txt`); a render test (`tests/sketch_style_render.gd`) for the
  new layouts; one e2e that makes a dimension in the flat app's shape (through the routes), opens it in VR, moves its label in VR, and checks
  the placement the backend now holds.
- Not testable headless: how preview-at-the-laser, the stick cycling and label dragging feel; hand input at all. Each phase ends with a
  checklist for the owner's headset, as live sessions did.

## Decisions (owner, 2026-11-18)

1. **Conflicting constraint: one rule in both apps.** A constraint the sketch cannot take is taken straight back out, with the reason on the
   status line (VR's behaviour; the flat app moves to it). A conflict that appears later (an edited value, a moved reference) is kept and shown
   red, as the flat app does today, and VR shows it the same way. Flat-app work: P4.
2. **Constrained sketch drag: port the projector** to GDScript for the better feel (P6), not a backend solve per step.
3. **Both placement styles.** One dimension previewed at the laser is the default (parity); VR's every-candidate-at-once stays as an option
   on the options row, for when you already know which you want.
4. **Reference dimensions between pinned things: the flat app follows VR**, offering a reference dimension where a driving one cannot be
   made (flat-app work in P1).
5. **The catalogue lives in DIDSA-CAD `docs/`** (`docs/sketch-dimension-catalogue.json`), as proposed above. A backend check of requests
   against it can come later if wanted.
6. **Hand tracking** goes on the roadmap as a whole-client roll-out, not here (P5 keeps the sketcher ready for it).

## Risks

- Label placement in sketch units means VR and the flat app show the same position; VR's automatic "side with room" layout goes for any
  dimension the user has placed. Check that an unplaced dimension still uses VR's layout (better than the flat default in VR) or decide one rule.
- The options row has six slots; a point + circle pick has five options (three centre distances, Minimum, Maximum) plus Fix / Delete /
  Clear. Paging ("More") works but is slower; the stick cycle matters more than it looks.
- The right stick and A / B already have owners: while the table is **engaged** (a hand on the part, `table_manip.gd` `drive_input`) they
  move the part; otherwise the stick snap-turns, teleports or scrolls the panel the laser is on, and B closes the selection drawer
  (`table_editor.gd` `_on_right_pressed`). Cycling kinds and B-as-back must only act while the laser is on the sheet with a preview live and
  the table not engaged; B stepping back fits the drawer's existing "B closes it" rule.
- Part D's helper-point types can fail to converge on large value jumps (only arc length reseeds); VR's take-back would then refuse a value
  the flat app accepts. Check with the backend before P2.
