# Visibility and sketch as seed: gaps for review

Accumulated while building `docs/sketch-as-seed-plan.md` (branch `visibility-model-step1`). Nothing here blocks the step it came from; each is
a decision, a limit or an unchecked assumption to review later. Newest last within a section. "Step" is the plan's section 7.

## Unverified assumptions

| # | Gap | Step | Notes |
|---|---|---|---|
| V1 | **3D curve feature type names are a guess** (`curve`, `curve_3d`, `spline_3d`, in `visibility.gd` `CURVE_TYPES`). | 1 | **Roadmap:** 3D curves do not exist yet. Verify the type name and the Curves tile after they roll out (see "Roadmap" below). |
| V2 | **Plan section 8's open question is still open:** the load rule keeps bodies, surfaces, curves and planes hidden when the file's `hidden_feature_ids` lists them. Only checked on the fake backend and one real part. | 1 | Confirm against a file saved by the flat app. |
| V3 | **Nothing has been seen in a headset.** Tile sizes, drawer placement beside the deck, text size and the at-rest sketch line weight were judged from desktop renders. | 2 to 6 | Same caveat as `design-table-gaps.md` item 1. |
| V4 | Real-backend coverage: the load rule, category buttons, auto-hide, Undo and Redo are covered by `e2e_visibility.gd` and `e2e_visibility_auto.gd`. **Not covered:** drawing sketches at rest, the Visibility drawer, the tree eyes, picking a sketch as the Extrude seed. | 3, 4, 6 | Add `e2e_sketch_seed.gd` once Revolve, Sweep and Loft are in. |

## Behaviour choices worth a second look

| # | Gap | Step | Notes |
|---|---|---|---|
| B1 | **Show all also switches on the session tiles** (Ref. planes, Origin, Dims, Constr.), so the reference planes and the origin axes appear when you press it; **Hide all** also hides the open sketch's dimensions and constraints. Matches the plan's "every category" wording. | 2 | Could limit Show all to feature categories. |
| B2 | ~~Created planes started hidden~~ **Closed.** The load rule now keeps planes as the file had them (visible unless the file lists them); only seed sketches are hidden on load. | 1, 3 | |
| B3 | **Other sketches are not drawn inside an open sketch** (the sheet is the drawing) nor while curves are picked (the picking lines replace them). | 3 | Could draw them faintly in the 3D view. |
| B4 | **Rolled-back features:** category counts skip them, and a sketch hidden by a rolled-back feature shows again. Features that were hidden by hand stay hidden while rolled back. | 1, 5 | Matches the plan. |
| B5 | **Auto-hide records are session only.** After a reload the load rule rebuilds them from the feature rows, so a sketch the user showed by hand is hidden again on the next file load. | 5 | By design (plan section 2). |
| B6 | **Edit shows the seed sketches only for tool-edited features** (Loft, Sweep, Revolve...). Extrude and Fillet edit by typing a number and have no tool, so their seeds stay hidden while you edit. | 5 | Model-level `edit_begun` is tested; the editor hook is not exercised by a test. |
| B7 | **Pattern direction sketches are not auto-hidden**, as decided. | 5 | Decided. |
| B8 | **Redo of a feature hides the sketch again** even if you had shown it after the Undo (Redo is a new Apply). | 5 | Probably right; say if not. |

## UI limits

| # | Gap | Step | Notes |
|---|---|---|---|
| U1 | **Drawer is a fixed 4 by 3 grid with abbreviated names** ("Dims", "Constr.", "CofG"). Two cells are empty. | 2 | Names were shortened to fit the deck's text size. |
| U2 | **Centre of gravity is a disabled placeholder** (backend feature, plan section 9). | 2 | **Roadmap:** test after it rolls out (see "Roadmap" below). |
| U3 | ~~Origin, Dims and Constr. tiles only stored their switch~~ **Closed (step 7, as corrected).** Origin and axes draw on the copy; Dims and Constr. (dimensions and constraints) govern the open sketch only. | 2, 7 | See G1 to G5. |
| U4 | **Build rows have less room** (the eye takes about 60 px), so long summaries clip earlier. | 4 | Could shrink the eye or wrap. |
| U5 | **No eyes on the Bodies list.** A body does not map back to the feature that made it. The Bodies group heading and the per-feature eyes cover it. | 4 | Plan section 5 asked for body eyes. |
| U6 | **Group headings are a strip above the list, not headings inside it**, because regrouping would break build order and rollback. | 4 | |
| U7 | **The Visibility drawer is a child of the deck**: no handle, no resize, always flush right. | 2 | Decided. |

## Sketch as seed

| # | Gap | Step | Notes |
|---|---|---|---|
| S1 | ~~Tint filled holes~~ **Closed.** The tint subtracts holes (`SketchPicks.fill_polygons`). | 6 | |
| S2 | **No "Select Other" cycle** for overlapping sketches (roadmap, plan section 9). The nearest line wins. | 6 | |
| S3 | ~~No sketched-on face~~ **Replaced by picked targets.** With a sketch picked in the viewport, a Targets button picks the bodies (none, one or many): none is a new body for a Boss and every body for a Cut; New body still wins. **Gap:** the open-sketch flow keeps the automatic behaviour (sketched-on face, or the only body). | 6 | |
| S4 | **Sketches on turned or flipped planes are not offered** (`_plane_for_row` returns nothing for them), the same limit as Loft and Sweep picking. | 6 | |
| S5 | ~~Only Extrude takes a picked sketch~~ **Closed.** Revolve (profile, then a line of it as the axis), Sweep (profile, then the path lines of other sketches) and Loft (sections in pick order) all take picked sketches now. | 6 | |
| S7 | ~~Revolve's axis cannot be a reference axis~~ **Decided: left as it is.** The axis is any visible sketch's line (a construction line counts). To spin about X, Y or Z the user puts a line on that axis in a sketch (DIDSA-CAD's `axis_ref` takes a sketch line only). The origin axes stay a visual marker. | 6, 7 | Decided with John 2026-10-09. |
| S8 | ~~The axis line is not lit separately~~ **Closed.** The picked axis line is lit with the profile. | 6 | |
| S9 | **Sweep: the profile cannot be changed without choosing Sweep again** (the editor is in path picking). A "Back to profile" option is missing. | 6 | |
| S10 | **Sweep's path is still picked line by line** (as before), not as a whole sketch. | 6 | Could take a sketch as the path in one pull. |
| S11 | **Loft and Sweep with a sketch open keep the old picking** (Loft ignores an open sketch; Sweep uses it as the profile), and **a Build row's Edit keeps line picking** for both. | 6 | By design: the open-sketch flow and Edit are unchanged. |
| S12 | **Existing tests changed for Loft:** `design_table_loft_sweep.gd` expects `pick_sketch` on activation and `e2e_loft_sweep.gd` picks sections with sketch picks. `e2e_loft_sweep.gd` passed on CI after the change; `e2e_visibility.gd` used the old Loft picking too and was fixed the same way. | 6 | |
| S6 | The hover highlight for a sketch line lights that one line; the **picked** sketch lights all its lines in the pick colour. | 6 | |

## Test and tooling notes

| # | Gap | Notes |
|---|---|---|
| T1 | `fake_cad.gd` gained an opt-in `track_rows` mode (rows follow POST and DELETE). Existing tests do not use it. | |
| T2 | Running a design-table test by hand without `DIDSA_SETTINGS_PATH=user://settings_test.cfg` saves a slab size that fails the next run of `design_table_scene.gd`; `run_all.sh` sets it. | Worth a line in `tests/README.md`. |
| T3 | `e2e_build_tree.gd` had to expect the auto-hidden sketch in the hidden list. Other e2e tests that assert the exact hidden list would need the same. | Only `e2e_design_table.gd` sets one by hand; it passes. |

## Step 7: origin and axes, dimensions, constraints (as corrected)

| # | Gap | Notes |
|---|---|---|
| G1 | **Dims and Constr. are two tiles, both on by default, and they govern the OPEN sketch only.** Dimensions and constraints never show on a finished sketch at rest. Hide all turns them off in the open sketch too. | Decided with John 2026-10-09. |
| G2 | **The Dimension tool's own candidate values always show** (they are its interface), whatever the Dims tile says. | |
| G3 | **Constraint glyphs are new**: the sheet drew none before. They are plain letters beside what they hold (H, V, //, \|_, =, co, (o), on, M, T, F), stacked when an entity has several. Coincident points get none (the shared point is the glyph), and only the constraint types the session already creates are covered. | `sketch_session.gd` `constraint_items`, `sketch_view.gd`. Letters were chosen so they never miss a glyph in the font. |
| G4 | **Origin and axes are a marker only** (a ball, X, Y, Z axes and labels on the part's origin), not pickable (S7). | |
| G5 | **Axis colours are my choice** (X red, Y green, Z blue, from memory of the flat app). | Check against the flat app. |
| G6 | **Construction lines are ordinary lines for visibility**: drawn and offered at rest like the rest; the earlier construction tile and filter were removed. | |

## Roadmap (verify when shipped)

| Item | What to verify when it ships |
|---|---|
| **3D curves** | The backend's feature type name (the guess in `visibility.gd` `CURVE_TYPES`), that the Curves tile counts and hides them, and a real-backend test that makes one. |
| **Centre of gravity** (all clients, backend mass properties) | Enable the CofG tile, a marker and readout, and test it against the real backend. |
