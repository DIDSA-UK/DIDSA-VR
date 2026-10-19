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

## `motion_vectors.json` — golden vectors for the free-motion projector

A **copy** of DIDSA-CAD's `docs/motion/vectors.json` (128 cases, tolerance 1e-9; constraint-model versions 3 and 4),
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
- sha256 `2f5e96a699d3bb0cf9e3cddb23debc3dc37d486c37946368b31a3c19c611bcf0`.
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

## `appearance_split.glb` — a real glb split by appearance

DIDSA-CAD's `assembly-mesh.glb` of one Part with two 10 mm boxes, the second body painted #E63946 at opacity 0.5 (a Part body
appearance), so its mesh is two indexed primitives. Used by `tests/appearance_glb.gd` and `tests/appearance_render.gd`.
Regenerate from `DIDSA-CAD/backend` with its environment:
`python /path/to/didsa-vr/tests/fixtures/make_appearance_split_glb.py /path/to/didsa-vr/tests/fixtures/appearance_split.glb`
(body ids are new each time; the tests read them from the file).
