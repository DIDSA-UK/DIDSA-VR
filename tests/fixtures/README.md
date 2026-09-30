# Test fixtures

Real native files from John, for manually exercising `main.gd`'s Files-tab
"Open"/"Add" flow (`open_native_file()`/`add_component_file()`) on a real
headset or the desktop preview — headless tests generate their own
throwaway fixtures instead (see `tests/e2e_add_component.gd`), so these
exist for the interaction/feel testing headless can't cover.

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

A **copy** of DIDSA-CAD's `docs/motion/vectors.json` (76 cases, tolerance 1e-9),
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
- sha256 `88f51929d65364d470f2504272e7bd70db4c1d7ae6dd0e4b87494e1f3e0531bb`.
- `tests/motion_vectors.gd` FAILS if a DIDSA-CAD checkout is reachable (`DIDSA_CAD_DIR`,
  else `../DIDSA-CAD`) and its `docs/motion/vectors.json` differs from this copy, so a
  regenerated file cannot be missed silently. Without a checkout it says so and runs on the copy.
