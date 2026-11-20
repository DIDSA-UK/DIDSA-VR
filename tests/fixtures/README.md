# Test fixtures

Real native files from John, for manually exercising `main.gd`'s Files-tab
"Open"/"Add" flow (`open_native_file()`/`add_component_file()`) on a real
headset or the desktop preview — headless tests generate their own
throwaway fixtures instead (see `tests/e2e_add_component.gd`), so these
exist for the interaction/feel testing headless can't cover.

- **`topology_box_cylinder.glb`** — an `assembly-mesh.glb` built by DIDSA-CAD's
  own `encode_assembly_glb` from real OCCT shapes (a 100 mm box and a 30 mm x
  100 mm cylinder, two instances, occurrences `occ_box` / `occ_cyl`), with the
  per-Body edge / vertex / face-boundary `topology` extras. Used by
  `tests/topology_pick.gd` and `tests/topology_render.gd`. Regenerate from
  `DIDSA-CAD/backend` (needs the pythonocc environment) with the snippet in
  `tests/README.md` under `topology_pick.gd`.
- **`Assy_Test_Plate.didsa`** — a single Part, no Occurrences. Open this
  first as the assembly root.
- **`Assy_test_peg_2.DIDSAprt`** — a single Part, no Occurrences. Add this
  onto the opened plate to place a real second Occurrence — this pair is
  the manual, in-VR way to build the exact multi-Occurrence structure the
  Mates tool needs (`docs/status.md`'s "Real-headset testing round 2").
- **`assy_save_test.DIDSAprt`** — already a composed two-Occurrence
  assembly (both of the above Parts placed, one `fixed`) in one file — open
  this directly for a ready-made Mates test case, no Add step needed.
  **Byte-identical to the repo root's own tracked `assembly.didsa`** (same
  file, kept here too under its more descriptive name for this set).

**These are gitignored nowhere near `models/`, on purpose** — `models/*` is
excluded from the repo (real CAD files usually shouldn't be committed;
see that folder's own `.gitkeep` comment in `.gitignore`), so a file only
living here is invisible to `list_model_files()`/the Files tab. To actually
use one from inside VR, copy (not move — keep this copy for next time) it
into `models/` next to `project.godot` (or `user://models` on-device, e.g.
via `adb push`), then it'll show up in the wrist tablet's Files tab like
any other local model.

## Copied from DIDSA-CAD: the seven files CI compares

Seven files here are byte-for-byte copies of DIDSA-CAD's `main`. Each one's test compares its copy with the DIDSA-CAD checkout (env
`DIDSA_CAD_DIR`, else `../DIDSA-CAD`) and fails with `DIFFERENT` when they differ; with no checkout it prints `no source` and passes. CI
(`.github/workflows/headless-tests.yml`) checks DIDSA-CAD `main` out into `didsa-cad/` and sets `DIDSA_CAD_DIR`, on every push and weekly, so
CAD-side drift fails there. After a change lands on DIDSA-CAD `main`, refresh the copy (from DIDSA-VR's root, DIDSA-CAD next to it) and rerun that test:

| Copy here | Copy command | Test |
|---|---|---|
| `sketch_vectors.json` | `cp ../DIDSA-CAD/docs/motion/sketch-vectors.json tests/fixtures/sketch_vectors.json` | `sketch_projector_vectors` |
| `sketch_shape_vectors.json` | `cp ../DIDSA-CAD/docs/motion/sketch-shape-vectors.json tests/fixtures/sketch_shape_vectors.json` | `sketch_shape_vectors` |
| `sketch_dimension_catalogue.json` | `cp ../DIDSA-CAD/docs/sketch-dimension-catalogue.json tests/fixtures/sketch_dimension_catalogue.json` | `sketch_dimension_catalogue` |
| `sketch_label_placement_cases.json` | `cp ../DIDSA-CAD/docs/sketch-label-placement-cases.json tests/fixtures/sketch_label_placement_cases.json` | `sketch_label_placement` |
| `motion_vectors.json` | `cp ../DIDSA-CAD/docs/motion/vectors.json tests/fixtures/motion_vectors.json` | `motion_vectors` |
| `appearance_vectors.json` | `cp ../DIDSA-CAD/docs/appearance/vectors.json tests/fixtures/appearance_vectors.json` | `appearance_vectors` |
| `file_lookup_vectors.json` | `cp ../DIDSA-CAD/docs/file-lookup/vectors.json tests/fixtures/file_lookup_vectors.json` | `file_lookup_vectors` |
| `scene_vectors.json` | `cp ../DIDSA-CAD/docs/scenes/vectors.json tests/fixtures/scene_vectors.json` | `scene_vectors` |

A change to one of these files is made in DIDSA-CAD first and merged there; VR's copy follows (a VR branch that copies an unmerged CAD file fails
the headless job until the CAD change is on `main`).

## `motion_vectors.json` — golden vectors for the free-motion projector

A **copy** of DIDSA-CAD's `docs/motion/vectors.json` (159 cases, tolerance 1e-9; constraint-model versions 3 to 8),
the normative test data for `scripts/motion/*.gd` (and for the Dart port in
DIDSA-CAD `client/lib/motion/`). `tests/motion_vectors.gd` runs every kind in it.
Do not edit it here: regenerate it in DIDSA-CAD (`python tools/motion_vectors/generate.py`)
and copy it over.

- Copied from DIDSA-CAD branch `ccr-de7668e3-4japt0` (constrained-drag S6), generator
  fixed so the swing sequence's nearest anchors are stored data (`nearest_anchor_theta_deg`)
  the constants block keeps `gram_schmidt_drop_absolute` = 1e-12, and the wish is the exact `screw_log` (new `screw_log` kind + six on-manifold `project` cases); that change is
  not in CAD `main` until S6's PR merges. Before it, an older file (same 61 case ids)
  is on CAD `main` at `1fca1db` (61 cases) and its swing case cannot be reproduced to 1e-9 by any
  independent port.
- Re-copied for DIDSA-CAD's mate-branch model (`docs/mate-solution-choice-plan.md`, Phase 2): constraint-model version 2, 13 new `local_retract` cases (31 now) for the
  branch-specific residuals; the 18 older ones were re-expressed with the branch of their mates.
- Re-copied for an ANGLE about a hinge (`docs/mate-solution-choice-plan.md`): constraint-model version 3 (`hinge_direction` on a side, one more ANGLE row), 4 new `local_retract` cases (35 now).
- Re-copied for constraint model v4 (a side's `pair`, Width / Symmetric over moving parts), DIDSA-CAD branch `claude/constraint-model-v4` at `d6b303c` (PR #303): 17 new `local-width-*` cases (52 `local_retract`), `local_pair_model_version` constant.
- Re-copied for constraint model v7 (a side's `follow`: pattern copies that follow their source), DIDSA-CAD branch `ccr-8db48425-oxdljy` (S1 of `pattern-followers-smoothness-plan.md`): 8 new `local-follow-*` cases (79 `local_retract`), `local_follow_model_version` constant.
- Re-copied for constraint model v8 (rigid sets, DIDSA-CAD M1), DIDSA-CAD `main` at `c39efdf` (M2 changes nothing in the vectors): 4 new `local-rigid-*` cases (83 `local_retract`, `followers` / `local_followers` in their expected), `local_rigid_model_version` constant.
- sha256 `5b30ee3bd3b3fd7439d861450721371a4c5854ef2f62cdd606c70ed0697cf4da`.
- `tests/motion_vectors.gd` FAILS if a DIDSA-CAD checkout is reachable (`DIDSA_CAD_DIR`,
  else `../DIDSA-CAD`) and its `docs/motion/vectors.json` differs from this copy, so a
  regenerated file cannot be missed silently. Without a checkout it says so and runs on the copy.
- **`block_60x40x20.step`** — a 60 x 40 x 20 mm box written with pythonocc's STEP writer (`BRepPrimAPI_MakeBox(60, 40, 20)` through `STEPControl_Writer`, from
  `DIDSA-CAD/backend`'s environment). An IMPORTED part with no sketch or feature history, for the Modify tools in `tests/e2e_modify.gd`.

## `appearance_vectors.json` — golden vectors for the Appearance tool's rule

A **copy** of DIDSA-CAD's `docs/appearance/vectors.json` (57 cases), written by `tools/appearance_vectors/generate.py` from the
reference rule `backend/app/document/appearance.py`. `tests/appearance_vectors.gd` checks `scripts/appearance/appearance_rule.gd`
against it, and fails if the copy differs from a reachable DIDSA-CAD checkout. Refresh: copy the file over from DIDSA-CAD
(branch `claude/appearance-and-scenes` until it merges).

## `file_lookup_vectors.json` — golden vectors for finding moved files

A **copy** of DIDSA-CAD's `docs/file-lookup/vectors.json` (16 cases), written by `tools/file_lookup_vectors/generate.py` from the
reference rule `backend/app/document/file_lookup.py`. `tests/file_lookup_vectors.gd` checks `scripts/file_lookup.gd` against it, and
fails if the copy differs from a reachable DIDSA-CAD checkout. Refresh: copy the file over from DIDSA-CAD (branch
`claude/appearance-and-scenes` until it merges).

## `appearance_split.glb` — a real glb split by appearance

DIDSA-CAD's `assembly-mesh.glb` of one Part with two 10 mm boxes, the second body painted #E63946 at opacity 0.5 (a Part body
appearance), so its mesh is two indexed primitives. Used by `tests/appearance_glb.gd` and `tests/appearance_render.gd`.
Regenerate from `DIDSA-CAD/backend` with its environment:
`python /path/to/didsa-vr/tests/fixtures/make_appearance_split_glb.py /path/to/didsa-vr/tests/fixtures/appearance_split.glb`
(body ids are new each time; the tests read them from the file).

## `m0_reduced_models.json` — the reduced constraint models of DIDSA-CAD's M0 scaling scenes

A **copy** of DIDSA-CAD's `client/test/data/m0_reduced_models.json`, written by `backend/tests/export_m0_reduced_models.py` (`cd backend && CAD_API_KEY=test-api-key python -m tests.export_m0_reduced_models ../client/test/data/m0_reduced_models.json`):
for each of the 22 M0 scene variants (chain, bolted chain, frame, linkage; floating and with the base fixed) the version-8 constraint model `solve_group` exports (the members are the rigid-set leads), the leads' stored poses and a wish
(the grabbed part 5 mm along x and 5 degrees about z away), lever arm 100 mm. Used by `tests/local_retraction.gd` (every model parses, converges in one frame) and by the benchmark
(`tests/bench_local_retraction.gd`, `scenes/bench_local_retraction.tscn`: `docs/local-retraction-benchmark.md`). Regenerate it in DIDSA-CAD and copy it over; do not edit it here.

## `pattern_copy_pose_vectors.json` — golden vectors for a pattern copy's pose

A **copy** of DIDSA-CAD's `backend/tests/data/pattern_copy_pose_vectors.json` (= `client/test/fixtures/pattern_copy_pose_vectors.json`): 50 cases (every pattern kind x five source poses), the pose of each live copy
as the BACKEND's `assembly.pattern_copy_pose` gives it, tolerance 1e-9, for `scripts/motion/pattern_copy_pose.gd` (`tests/pattern_copy_pose.gd`). Do not edit it here: regenerate it in DIDSA-CAD
(`cd backend && python ../tools/motion_vectors/pattern_copy_pose_vectors.py`, with the backend's python: the backend is the reference) and copy it over.

## From a real backend, not copied from DIDSA-CAD: `sketch_midsize_state.json`

The answers of a local DIDSA-CAD backend for the sketch of parity follow-ups C1 (10 dimensioned rectangles with a circle each and a 20-point dimensioned chain):
`state` (`POST .../solve-and-refresh`), `export` (`GET .../export`) and the origin's point id. Used by `tests/sketch_midsize_redraw.gd`. Made by
`tests/helpers/make_sketch_midsize_fixture.gd` (the VR session's own taps and dimensions against a running backend, `secrets.cfg` pointing at it); the ids are the
backend's UUIDs, so a rebuild changes every id but not the shape of the sketch. Nothing compares it with DIDSA-CAD: it is a snapshot, not a mirror.
