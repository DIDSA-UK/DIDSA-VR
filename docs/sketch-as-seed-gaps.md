# Visibility and sketch as seed: gaps for review

Accumulated while building `docs/sketch-as-seed-plan.md` (branch `visibility-model-step1`). Nothing here blocks the step it came from; each is
a decision, a limit or an unchecked assumption to review later. Newest last within a section. "Step" is the plan's section 7.

## Unverified assumptions

| # | Gap | Step | Notes |
|---|---|---|---|
| V1 | **3D curve feature type names are a guess** (`curve`, `curve_3d`, `spline_3d`, in `visibility.gd` `CURVE_TYPES`). No test makes a 3D curve, so the Curves tile may stay empty on real files. | 1 | Check DIDSA-CAD's feature type for 3D curves, add a real-backend test. |
| V2 | **Plan section 8's open question is still open:** the load rule keeps bodies, surfaces, curves and planes hidden when the file's `hidden_feature_ids` lists them. Only checked on the fake backend and one real part. | 1 | Confirm against a file saved by the flat app. |
| V3 | **Nothing has been seen in a headset.** Tile sizes, drawer placement beside the deck, text size and the at-rest sketch line weight were judged from desktop renders. | 2 to 6 | Same caveat as `design-table-gaps.md` item 1. |
| V4 | Real-backend coverage: the load rule, category buttons, auto-hide, Undo and Redo are covered by `e2e_visibility.gd` and `e2e_visibility_auto.gd`. **Not covered:** drawing sketches at rest, the Visibility drawer, the tree eyes, picking a sketch as the Extrude seed. | 3, 4, 6 | Add `e2e_sketch_seed.gd` once Revolve, Sweep and Loft are in. |

## Behaviour choices worth a second look

| # | Gap | Step | Notes |
|---|---|---|---|
| B1 | **Show all also switches on the session tiles** (Ref. planes, Origin, Dims, Constr.), so the reference planes appear when you press it. Matches the plan's "every category" wording. | 2 | Could limit Show all to feature categories. |
| B2 | **Created planes start hidden** (load rule). After making a plane in the session it stays visible until the file is reloaded. | 1, 3 | The rule only runs on load. |
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
| U2 | **Centre of gravity is a disabled placeholder** (backend feature, plan section 9). | 2 | Roadmap. |
| U3 | ~~Origin, Dims and Constr. tiles only stored their switch~~ **Closed (step 7).** Origin and axes draw on the copy, dimensions and construction lines draw on at-rest sketches. | 2, 7 | See G1 to G5. |
| U4 | **Build rows have less room** (the eye takes about 60 px), so long summaries clip earlier. | 4 | Could shrink the eye or wrap. |
| U5 | **No eyes on the Bodies list.** A body does not map back to the feature that made it. The Bodies group heading and the per-feature eyes cover it. | 4 | Plan section 5 asked for body eyes. |
| U6 | **Group headings are a strip above the list, not headings inside it**, because regrouping would break build order and rollback. | 4 | |
| U7 | **The Visibility drawer is a child of the deck**: no handle, no resize, always flush right. | 2 | Decided. |

## Sketch as seed

| # | Gap | Step | Notes |
|---|---|---|---|
| S1 | **Tint fills each closed loop on its own**, so a hole is tinted too. It is only a cue. | 6 | Subtract holes if it confuses. |
| S2 | **No "Select Other" cycle** for overlapping sketches (roadmap, plan section 9). The nearest line wins. | 6 | |
| S3 | **A picked finished sketch has no "sketched-on face"**, so a Boss fuses only with a single-body part and a Cut cuts every body. | 6 | Could infer the face from the sketch plane. |
| S4 | **Sketches on turned or flipped planes are not offered** (`_plane_for_row` returns nothing for them), the same limit as Loft and Sweep picking. | 6 | |
| S5 | ~~Only Extrude takes a picked sketch~~ **Closed.** Revolve (profile, then a line of it as the axis), Sweep (profile, then the path lines of other sketches) and Loft (sections in pick order) all take picked sketches now. | 6 | |
| S7 | **Revolve's axis can only be a line of the profile sketch.** The plan also allows a reference axis (X, Y, Z); that needs the origin and axes markers (step 7). | 6 | |
| S8 | **The axis line is not lit separately**: the whole picked sketch is lit and the axis shows only as "Axis: set" in Selected. | 6 | Light it in a second colour. |
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

## Step 7: origin and axes, dimensions, construction geometry

| # | Gap | Notes |
|---|---|---|
| G1 | **The Dims and Constr. tiles do not touch the OPEN sketch.** While you sketch, its dimensions and construction lines are always shown (hiding the line you just drew, or the value the Dimension tool needs, would break sketching). The tiles govern finished sketches drawn at rest, and Revolve's axis picking always shows construction lines. | Plan section 2 says "hidden on load" without saying which sketch; decide if the open sketch should obey too. |
| G2 | **Dimension glyphs at rest are a simplified drawing**: lines, arcs, two-barb arrowheads and a billboard value, sized as a fraction of the sketch (not the sheet's canvas scale). Reference (driven) dimensions are not drawn. | `sketch_picks.gd` `_dimension_glyphs`. |
| G3 | **Origin and axes are a marker only**: a ball, three axes and X, Y, Z labels on the part's own origin. Not pickable, so Revolve still cannot use a reference axis (S7). | |
| G4 | **Dimension glyph colour (amber) and axis colours are my choice**, matching the flat app's X red, Y green, Z blue by memory. | Check against the flat app. |
| G5 | **Centre of gravity stays a placeholder** (roadmap, backend feature). | |
