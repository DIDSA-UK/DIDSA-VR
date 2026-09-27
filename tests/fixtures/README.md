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
