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
| U3 | **Tiles for Origin and axes, Sketch dimensions and Construction geometry only store their switch.** They draw nothing until step 7. | 2, 7 | Step 7. |
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
| S5 | **Only Extrude takes a picked sketch so far.** Revolve, Sweep and Loft still need the open sketch or line picking. | 6 | In progress. |
| S6 | The hover highlight for a sketch line lights that one line; the **picked** sketch lights all its lines in the pick colour. | 6 | |

## Test and tooling notes

| # | Gap | Notes |
|---|---|---|
| T1 | `fake_cad.gd` gained an opt-in `track_rows` mode (rows follow POST and DELETE). Existing tests do not use it. | |
| T2 | Running a design-table test by hand without `DIDSA_SETTINGS_PATH=user://settings_test.cfg` saves a slab size that fails the next run of `design_table_scene.gd`; `run_all.sh` sets it. | Worth a line in `tests/README.md`. |
| T3 | `e2e_build_tree.gd` had to expect the auto-hidden sketch in the hidden list. Other e2e tests that assert the exact hidden list would need the same. | Only `e2e_design_table.gd` sets one by hand; it passes. |
