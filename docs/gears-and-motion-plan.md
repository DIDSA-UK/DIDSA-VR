# Gears and motion mates: implementation plan (DIDSA-VR + DIDSA-CAD)

Written 2026-10-22 as the spec for an implementing session (a cheaper model working alone). The owner chose this after a review of
the vision brief, DIDSA-CAD `docs/roadmap.md` ("DIDSA-VR: parity gap review and rollout order", step 3: gears on the table) and the
brainstorm's "assembly animation" item. Outcome: gears are made on the design table in VR; gears, racks and screws can be **coupled**
by new mates so that turning one turns the others; and a **Drive** tool in VR turns a part continuously so the whole mechanism runs.

Repos: **BE** = DIDSA-CAD `backend/`, **FA** = DIDSA-CAD `client/` (Flutter flat app), **VR** = DIDSA-VR (Godot 4.7.2).
GitHub: `DIDSA-UK/DIDSA-VR`, `DIDSA-UK/DIDSA-CAD`. Both checked out side by side (`../DIDSA-CAD` from VR's root).

**Branch:** one branch, the same name in both repos: **`claude/gears-and-motion`** (created from `main` on 2026-10-22 in both repos,
after this plan was merged; every earlier branch is merged, nothing else is open). All milestones land on it, in order. Do not open a pull request unless the
owner asks for one.

## Progress

Update this table at every gate (date, test counts, commit hashes in both repos). "PAUSE" rows: stop there and report to the owner.

| # | Milestone | Repos | Status | Gate result |
|---|---|---|---|---|
| M0 | Tooling and baseline | both | Done 2026-10-22 (planning session) | see "Baseline" below |
| M1 | Gear bore (backend + flat app field) | BE, FA | Done 2026-10-22 | CAD `9066f7f`. BE core 2546 passed; BE gears 398 passed (392 + 6 new in `test_gear_bore.py`) + planetary jobs 8 passed; FA `flutter test` 2927 passed / 38 skipped (2925 + 2 new); `flutter analyze --no-fatal-infos` 192 infos, 0 errors, 0 warnings (the baseline deprecation). VR untouched. |
| M2 | Gear tools on the design table | VR | Done 2026-10-22, **PAUSE** (waiting for the owner) | VR `fb0a2ab`; CAD unchanged (`9066f7f`). `tests/ci.sh` 3462 SMOKE lines, 0 failures (3401 + 61 new in `design_table_gears`, plus one changed line in `design_table_logic`); `tests/ci_render.sh` 80 lines, 0 failures; `tests/ci_e2e.sh` 467 lines, 0 failures (449 + 18 new in `e2e_gears`, run against the restarted local backend with the M1 code). |
| M3 | Coupler mates in the backend (gear, rack and pinion, screw) | BE | Done 2026-10-22 | CAD `6d1981e`. BE core 2559 passed (2546 + 13 in `test_coupler_mates.py`); BE gears 404 (398 + 6 in `test_coupler_mates_gears.py`) + planetary jobs 8; motion vectors `--check` ok (system python). VR docs only. |
| M4 | Coupler mates in the flat app | FA | Done 2026-10-22 | CAD `19e0355`. `flutter test` 2942 passed / 38 skipped (2927 + 15 in `coupler_mate_test.dart`); `flutter analyze --no-fatal-infos` 193 infos, all the baseline `material.dart` deprecation (the new test file imports it), 0 errors / warnings. |
| M5 | Coupler mates in VR | VR | Done 2026-10-22, **PAUSE** (waiting for the owner) | VR commit `M5: ...` in the git log; CAD unchanged (`19e0355`). `tests/ci.sh` 3493 SMOKE lines, 0 failures (3462 + 31 in `gear_mates`); `tests/ci_render.sh` 80, 0 failures; `tests/ci_e2e.sh` 493, 0 failures (467 + 26 in `e2e_gear_mates`, against the local backend with the M1-M3 code). |
| M6 | Constraint model v5 (analytic coupler rows, three ports) | BE, FA, VR | Done 2026-10-22 | CAD and VR commits `M6: ...` in the git logs. Motion vectors `--check` ok (139 cases, 11 new `local_retract`); BE core 2566 passed (2559 + 7 in `test_coupler_constraint_model.py`); BE gears 463 passed (the count grew with the M1/M3 gear tests; includes the planetary jobs); FA `flutter test` 2964 passed / 38 skipped, analyze: only the baseline `material.dart` infos; VR `tests/ci.sh` 3493 SMOKE lines, 0 failures; `tests/ci_e2e.sh` 493, 0 failures (the gear e2e now reads a version-5 model). `ci_render.sh` not re-run (no rendering code touched). |
| M7 | Drive tool (VR) | VR | Done 2026-10-22, **PAUSE** (waiting for the owner) | VR commit `M7: ...` in the git log; CAD unchanged. `tests/ci.sh` 3519 SMOKE lines, 0 failures (3493 + 26 in `drive_tool`); `tests/ci_render.sh` 80, 0 failures; `tests/ci_e2e.sh` 502, 0 failures (493 + 9 in `e2e_drive`, against the local backend with the M1-M6 code). |
| M8 | Gear train demo, docs, final full run | both | Done 2026-10-22, **PAUSE** (end; waiting for the owner) | VR commit `M8: ...`, CAD commit `M8: ...`. Final full run: motion vectors `--check` ok; BE core 2566 passed; BE gears 463 passed (bevel pair and planetary jobs included); FA `flutter test` 2964 passed / 38 skipped, analyze 193 infos, all the baseline `material.dart` deprecation; VR `tests/ci.sh` 3519 SMOKE lines, `ci_render.sh` 80, `ci_e2e.sh` 508 (502 + 6 in `e2e_gear_train`), 0 failures everywhere. |
| M9 | Limit mates (stretch: only with the owner's go) | BE, FA, VR | Done 2026-10-23, **PAUSE** (waiting for the owner) | Scope note `docs/limit-mates-scope.md` (shown first; owner's go with three decisions: local per-frame stop, +-180 degrees, the demo's rack gets the limit). CAD and VR commits `M9: ...` in the git logs. Motion vectors `--check` ok (147 cases, 8 new `local_retract` limit cases); BE core and gears see CAD `docs/status.md`; BE core 2583 passed (the coupler gear files 13 more); FA `flutter test` 2995 passed / 38 skipped; VR `tests/ci.sh` 3565 SMOKE lines, 0 failures; `tests/ci_e2e.sh` 564 lines, one failure (`user_session_train`'s readout check: the crank turned the way the rack now stops at 6 mm, so the rack was not in the readout; the test now turns it the other way) and re-run clean. |

## Rules for the implementing session

1. **Do the work yourself.** No subagents. Read, edit, run and test directly.
2. **Read first** (VR): `CLAUDE.md`, `docs/status.md`, `docs/backend-api-notes.md`, `tests/README.md`, `docs/design-table.md`. (CAD):
   `CLAUDE.md` if present, `docs/width-mate-plan.md` (the last mate type added end to end: copy its shape), `docs/mate-solution-choice-plan.md`
   ("branch" and "Constraint model" parts), `docs/motion/projector-spec.md` §4b, `docs/gear-design/README.md`. Each milestone below adds
   its own reading list.
3. **The code wins.** This plan was written from reading, not running, the new code paths. When a file, function or field here does not
   match the code, follow the code, keep to the intent, and write the difference into "Implementation notes" at the bottom. Never guess a
   route or field name: `grep` for it.
4. **Copy the neighbours.** New code reads like the code around it: same naming, comment density, error shapes (`HTTPException` with a
   `{"type": ..., "message": ...}` detail as the router already does), test style (`SMOKE <text>: <bool>` lines in Godot tests, pytest
   functions in BE, `flutter_test` widgets in FA). No refactors outside what a milestone needs.
5. **Compatibility:** a file without the new fields must load and save **byte-identically** (write a new key only when it is not the
   default, the `helix_angle_degrees` / `midplane` precedent). Older clients may not understand new mate types; that is accepted, but
   the current flat app and VR must never crash on one.
6. **Units:** backend and files are millimetres and degrees; Godot shows metres (`spawn_scale` 0.001). Coupler residuals use radians
   (rotation rows) and millimetres (translation rows), see §3.3.
7. **Tests with every change.** New Godot test file: add it to `tests/run_all.sh` and a row in `tests/README.md`; live-backend tests also
   in `tests/e2e_ci_list.txt`. A Godot test that instantiates `scenes/main.tscn` sets `main.secrets_file_path` to a nonexistent file
   first and `await process_frame` after `add_child`. New pytest files: name them so `tests/conftest.py`'s marker rules put gear tests in
   the `gears` leg (read it).
8. **Gates.** Each milestone ends with its gate: run every command listed, all must pass, then commit and push both repos (§2.4), then
   fill the Progress row. A failing gate is fixed before moving on; never skip, disable or loosen a test to pass one. If a pre-existing
   test fails on untouched code, re-run it once; if it still fails, record it in the notes and tell the owner at the next PAUSE.
9. **PAUSE** means: stop, post a short report to the owner (what was built, the gate results, what could not be verified, what to try on
   the headset), and wait for their go before the next milestone.
10. **Honesty rules** (VR `CLAUDE.md`): say what you could not verify. Headless tests cannot judge feel, fake a real grip press or render for
    real. Never write "works on the headset" unless the owner says so.
11. Never commit `secrets.cfg`, `export_presets.cfg`, anything under `models/`, `__pycache__/`, or tool downloads.
12. Commit messages: short imperative subject naming the milestone (`M3: coupler mates - residual rows in the group model`), body says what
    was tested. End every commit message with the attribution lines the session's system prompt gives (if any).

## 1. Scope and decisions

### 1.1 What "motion mates" means here

The owner asked for "motion mates with gear mates folded in". This plan reads that as: mates that **couple motion** between parts rather
than placing them, plus a way to **drive** a mechanism. Recorded as a decision for the owner to confirm at the first PAUSE:

| Mate | References (in this order) | `value` | Relation it keeps while things move |
|---|---|---|---|
| **Gear** (`gear`) | A: axis of gear A; B: axis of gear B | ratio r > 0 = turns of B per turn of A (= z_A / z_B) | Δθ_B = k · r · Δθ_A |
| **Rack and pinion** (`rack_pinion`) | A: axis of the pinion; B: a straight edge along the rack | travel p > 0, mm of rack per pinion turn (= π · pitch diameter) | Δs_B = k · (p / 2π) · Δθ_A |
| **Screw** (`screw`) | A: axis of the screw; B: axis of the nut | lead L > 0, mm per turn | (Δs_B − Δs_A) = k · (L / 2π) · (Δθ_B − Δθ_A) |

`k` is +1 or −1 (the "Reverse" switch, §3.3.3). Δθ is a member's turn about the axis, Δs its travel along it, both measured from the pose
the current solve started from (§3.3.4). Hinge and slider are not new types (concentric + coincident already make them). **Limit** mates
(stop a hinge between two angles) are M9, a stretch, because they need inequality handling the solver does not have.

### 1.2 Decisions (all recorded; the owner can overturn any at a PAUSE)

- **D1. Couplers are incremental, not absolute.** They hold the relation for every *move* from an accepted pose; they never pull parts
  into a "phase". Creating a coupler mate, Enforce all, Solve and the mate preview **never move anything** because of a coupler. This is
  how mainstream CAD gear mates behave and it avoids storing an unwrapped turn count. Consequence, documented in the UI help: line the
  teeth up before making the gear mate (turn one gear by hand with the mate absent or suppressed).
- **D2. Gear chain, planetary and bevel pair features stay off the VR table** for now: each builds several gears inside ONE part, and
  mates join occurrences, so those gears could never be coupled or driven. The VR table gets single gears: spur (external and internal,
  straight, helical, herringbone), rack, and single bevel gear. A later "split bodies into parts" helper would open the rest.
- **D3. A bore on the gear** (new `bore_diameter` on `GearFeature` and `BevelGearFeature`): without it a gear has no round face to mate
  concentric to a shaft, and the VR user would need a sketch and a cut for every gear.
- **D4. Ratio and sense are filled in for you.** When `value` is left empty on create, the backend reads the tooth counts of the gear
  features in the two parts (gear, rack and pinion); the default `k` comes from the gear kinds and the geometry (§3.3.3). The screw has
  no default lead.
- **D5. Coupled motion first goes through the existing projector** (the backend `basis` already spans only the coupled motions once the
  rows are in the group model). The local retraction (flat app default, GDScript copy unused in the app) gets the coupler rows in M6;
  until then `constraint_model` is `null` for a group with a coupler, which both clients already treat as "keep projecting".
- **D6. World frame.** Δθ and Δs are measured in the assembly frame. Correct when the axes do not move during a drag (gears on a fixed
  frame, the normal case). A planetary arrangement whose carrier turns is not modelled correctly; documented limit.
- **D7. The Drive tool spins the part about the axis of the round face you pick** (or slides it along a straight edge), fed through the
  same constrained-drag path a hand drag uses; one undo step per drive.

## 2. Test tooling (M0, done in the planning session)

### 2.1 Install

From VR's root, with DIDSA-CAD at `../DIDSA-CAD`:

```
tools/setup_test_env.sh            # Godot 4.7.2, Xvfb + Mesa, micromamba + the backend conda env, Flutter master; idempotent
source /opt/tools/env.sh           # GODOT, CAD_PY, flutter on PATH (TOOLS_DIR=/opt/tools by default)
tools/start_backend.sh             # throwaway backend on 127.0.0.1:8000, writes secrets.cfg if missing; `restart` after BE edits
```

Notes found while setting this up:
- No Docker daemon in the cloud container, so the backend runs from the micromamba env, not the CI image. Same packages
  (`backend/environment.yml`).
- `micro.mamba.pm` is blocked by the sandbox proxy; the script uses the GitHub release of micromamba.
- Flutter comes from the `master` channel, as CI does (`client-verify.yml` explains why).
- `tools/motion_vectors/generate.py --check` must run under the **system** `python3` (numpy 2.x); it fails in the backend env even on
  untouched `main` (known float rounding, `docs/width-mate-plan.md` "Environment note").
- The backend keeps documents in memory per session. **Restart it after every backend code change** before VR e2e tests.
- `tests/ci_e2e.sh` uses whatever `secrets.cfg` names. Make sure it points at `127.0.0.1:8000` with the throwaway key, never the owner's server.

### 2.2 The suites

| Suite | Command (from the repo root) | Time here |
|---|---|---|
| VR headless | `tests/ci.sh` (needs `GODOT`) | ~25 min |
| VR render | `tests/ci_render.sh` (Xvfb + llvmpipe) | ~3 min |
| VR live backend | `tools/start_backend.sh` then `tests/ci_e2e.sh` | ~15 min |
| BE core | `cd backend && $CAD_PY -m pytest tests/ -q -m "not gears" -n 4 --dist=worksteal -p no:cacheprovider` | ~3 min |
| BE gears | `cd backend && $CAD_PY -m pytest tests/ -q -m "gears and not bevel_pair" -n 3 --dist=worksteal -p no:cacheprovider --ignore=tests/test_planetary_gear_jobs.py` then `$CAD_PY -m pytest tests/test_planetary_gear_jobs.py -q` | long |
| BE bevel pair | `cd backend && $CAD_PY -m pytest tests/ -q -m bevel_pair -n 3 --dist=worksteal` | very long (100-280 s per test); run only when bevel code changes |
| BE one file | `cd backend && $CAD_PY -m pytest tests/test_x.py -q` | |
| Motion vectors | `cd DIDSA-CAD && python3 tools/motion_vectors/generate.py --check` | seconds |
| FA | `cd client && flutter analyze --no-fatal-infos && flutter test` (or one file: `flutter test test/x_test.dart`) | ~5 min full |

### 2.3 Baseline (2026-10-22, `main` = VR `bd0178e`, CAD `1496c7f`, this container)

| Suite | Result |
|---|---|
| VR headless `tests/ci.sh` | 3401 SMOKE lines, 0 failures (matches `docs/status.md`) |
| VR render `tests/ci_render.sh` | 80 SMOKE lines, 0 failures |
| VR e2e `tests/ci_e2e.sh` (35 tests) | 449 SMOKE lines, 0 failures (the pairing part of `e2e_servers` is skipped without `DIDSA_E2E_PAIR_HOST`, hence 449 not 452) |
| BE core | 2546 passed |
| BE gears (without bevel pair, without the serial planetary jobs file) | 392 passed (4 min 48 s, 3 workers) |
| FA `flutter test` | 2925 passed, 38 skipped, all passed (4.5 min) |
| FA `flutter analyze` | 0 errors, 0 warnings, 192 infos, **all** the same new deprecation (`package:flutter/material.dart` deprecated in Flutter master 3.50.0-0.1.pre, revision 84abdf7372 of 2026-10-22). It exits 1 on infos: gate with `flutter analyze --no-fatal-infos` and require no new error / warning and no info other than that deprecation |
| Motion vectors `--check` | system python: pass; backend env: fails (known, above) |

### 2.4 Commit and push at a gate

```
git -C ../DIDSA-CAD add -A && git -C ../DIDSA-CAD commit -m "..." && git -C ../DIDSA-CAD push -u origin claude/gears-and-motion
git add -A && git commit -m "..." && git push -u origin claude/gears-and-motion
```
Check `git status` first: nothing from §Rules 11 may be staged. If a push fails for the network, retry up to 4 times (2, 4, 8, 16 s).

## 3. Design (normative)

### 3.1 Gear bore (M1)

- New field `bore_diameter: float = 0.0` (mm) on `GearFeature` and `BevelGearFeature` (`backend/app/document/models.py`), on their
  create / update / response schemas (`schemas.py`, `GearFeatureCreate` and its PATCH and response siblings, the same for bevel), in
  `native_format.py` (written **only when > 0**), and in the AI plan schema only if the gear step already lists every field (check; else leave it).
- Geometry (`gear.py`, `bevel.py`): after the gear solid is built (and after the root fillet), cut a through cylinder of that diameter on
  the gear's own axis (the plane's origin and normal), length = the gear's full extent along the axis plus a margin. `0.0` takes the old
  code path untouched.
- Validation (router, next to `_validate_gear_feature_payload`): `bore_diameter < 0` -> 422 `invalid_bore`; internal gear with a bore
  -> 422 `bore_on_internal_gear`; `bore_diameter >= 0.9 * root diameter` (dedendum diameter; for a bevel gear, the smallest root
  diameter at the toe) -> 422 `bore_too_large`. Find the root diameter in `gear_math` (`spur_gear_geometry(...)`) / `bevel_math`.
- The bore's cylindrical face is a normal face: concentric mates and coupler mates pick it like any hole.
- FA: a "Bore Ø" field on `client/lib/gear/gear_design_screen.dart` (External only) and `bevel_design_screen.dart`, with the existing
  `standard_value_field.dart` / validation banner pattern, sent in the create / PATCH body; `document_api_client.dart` DTOs gain the field.
  Presets (`gear_preset_store.dart`) store it (missing key reads 0).

### 3.2 Gear tools on the design table (M2)

Reading: `scripts/design_table/table_tools.gd`, `features/feature_tool.gd` (the tool interface), `features/feature_tools.gd` (the
registry), `features/revolve_tool.gd` and `features/create_plane_tool.gd` (a tool with a plane pick), `part_features.gd`,
`table_preview.gd` / `feature_preview.gd` (coarse preview), `scripts/ui/ui_icons.gd`, `tests/design_table_feature_tools.gd`,
`tests/dock_panels_render.gd`, `tests/e2e_loft_sweep.gd` (an e2e with coarse preview).

- **Deck:** a fourth group on the Feature tab in `table_tools.gd` `FEATURE_GROUPS`: `["gears", "Gears", <a new colour, e.g. Color(0.55, 0.85, 0.45)>,
  ["gear", "rack", "bevel_gear"]]`; entries in `FEATURE_TOOLS` (`["gear", "Gear", "tool_gear"]`, `["rack", "Rack", "tool_rack"]`,
  `["bevel_gear", "Bevel", "tool_bevel_gear"]`); `HINTS` for each; three line-art icons in `ui_icons.gd` in the same 48-unit SVG style.
- **`features/gear_tool.gd`** (registered in `feature_tools.gd`):
  - options (two-column dock, the Phase 7 layout): Kind External / Internal; Module; Teeth; Face width; Pressure angle (cycles 20 /
    14.5 / 25); Helix angle (0 = straight); Herringbone (toggle, disabled at helix 0); Bore Ø (External only; 0 = none); Outer Ø (Internal
    only, required); Backlash; Root fillet; Profile shift (Auto, or a typed value). Numbers are typed on the popup keyboard, the way
    Extrude's depth is (copy that code path). Defaults: External, module 2, 20 teeth, face width 10, 20°, straight, bore 8.
  - plane: `wants_plane_pick()` true; `on_plane_picked` stores the plane spec; none picked = the part's XY plane (`plane_ref` omitted, the
    backend's default). The dock shows which plane is used.
  - readout line under the options, from `POST /document/gear/preview` (check the prefix in `gears_routes.py` and `backend-api-notes.md`;
    debounce like other live calls): pitch Ø, tip Ø, root Ø, and "Centre distance to a gear of N teeth: m·(z + N)/2" with N = the same
    teeth by default (a keyboard field "Mate teeth" changes N). This is how the user knows where to put the shaft holes.
  - `preview_mode()` "coarse", `preview_route()` `/parts/%s/gear-features/coarse-preview`; `request()` -> route
    `/parts/%s/gear-features`, Boss, `target_body_ids` [] (a new body).
- **`features/rack_tool.gd`**: module, teeth, face width, pressure angle, backing height (Auto / value), backlash, plane pick. No
  coarse-preview route exists for racks: `preview_mode()` "eager" (create, PATCH while options change, Cancel deletes), as other eager tools do.
- **`features/bevel_gear_tool.gd`**: module, teeth, face width, pitch cone angle (a "Mate teeth" helper fills it for a 90° pair:
  atan(z / z_mate)), pressure angle, spiral angle (0 = straight) and hand, bore Ø. Coarse preview `/parts/%s/bevel-gear-features/coarse-preview`.
- **Edit:** the Build tree's Edit on a gear / rack / bevel feature opens the same tool filled with its values and PATCHes
  (`/parts/%s/gear-features/{id}` etc.). Find how Edit works for an existing tool (grep `build_tree.gd` and `table_editor.gd` for the
  edit path of e.g. revolve) and follow it. Long builds: helical gears can take seconds; show the existing "building" state.
- **Undo / Redo:** the same as other features (redo covers features).
- **Tests:** `tests/design_table_gears.gd` (headless, fake HTTP like the other `design_table_*` tests: deck shows the group and tools;
  options and their enabling rules; request bodies exactly as above for each kind; plane pick; readout parsing; edit fills the options);
  `tests/e2e_gears.gd` (live backend: new part, make an external gear with a bore, an internal gear, a rack and a bevel gear; each makes a
  body with triangles; Edit changes the teeth and the body changes; the gear's bore face is found by a concentric pick of the mates
  tool's face picking helper, or at least the mesh has a cylindrical face); add the three tools to `tests/dock_panels_render.gd`.

### 3.3 Coupler mates (M3 backend, M4 flat app, M5 VR, M6 constraint model)

#### 3.3.1 Data and wire

- `MateType` (`models.py`) gains `GEAR = "gear"`, `RACK_PINION = "rack_pinion"`, `SCREW = "screw"`. Add a module constant
  `COUPLER_TYPES = (MateType.GEAR, MateType.RACK_PINION, MateType.SCREW)` and use it everywhere below instead of repeating the list.
- `Mate.value` holds r / p / L (§1.1), always > 0. `Mate.secondary_flip` holds the sense: **`False` -> k = −1, `True` -> k = +1**,
  `None` on create means "fill in the default" (§3.3.3) and is never stored as `None` for a coupler. `alignment` stays `None`;
  `allow_rotation` is ignored; `flipped` stays False. `branch_source` is "auto" for a default sense and "user" when the request set it.
- `MateCreate.type` (`schemas.py`) Literal gains the three names; `MateResponse` already carries `value` and `secondary_flip`.
- `native_format.py`: nothing new to write (`type`, `value`, `secondary_flip` are already written); check `_mate_from_dict` accepts the
  new types and does not apply the DISTANCE / ANGLE legacy rules to them.
- AI plan schema (`ai_plan_schemas.py`, `ai_plan.py`): leave unchanged (an AI plan cannot make a coupler); note it in the docs.

#### 3.3.2 Validation on create / PATCH (`router.py`, next to `_validate_mate_create` / `_validate_mate_entity_ref`)

- Exactly two references, on two different top-level occurrences (or one may be the root's own geometry, `occurrence_id == ""`).
- Each reference must resolve to an **axis** (a cylindrical face, a circular edge or a straight edge: what CONCENTRIC accepts today, see
  `_resolve_local_geometry`) except rack and pinion's B, which must be a **straight edge or a planar face's in-plane direction**: accept a
  straight edge only in v1 (422 `rack_reference_not_straight_edge` otherwise). Wrong kind -> the existing `_unsupported_mate_geometry`
  422 shape.
- `value`: `None` allowed for gear and rack and pinion (auto, §3.3.3), required for screw (422 `screw_lead_required`); when given,
  `value > 0` and finite (422 `invalid_coupler_value`).
- A midplane reference on a coupler -> 422 (reuse the existing midplane-type check).
- PATCH may change `value` (> 0), `secondary_flip` (sets `branch_source` "user") and `suppressed`; changing `type` or references is not
  supported (the existing PATCH rules for other types: follow them).

#### 3.3.3 Defaults (create only, when the request leaves them empty)

Resolve each reference's part (the leaf part under the occurrence path; reuse `_target_part_and_transform` / the helpers the solver
uses) and its **tooth features**: the non-suppressed `GearFeature`, `BevelGearFeature` and `RackFeature`s in that part. Exactly one
tooth feature per side is needed for an auto value; otherwise 422 `gear_ratio_required` ("Type the ratio: the part has no gear, or
several").

- **Gear ratio:** r = z_A / z_B (tooth counts).
- **Rack travel:** p = π × pitch diameter of A's gear. Take the pitch diameter from `gear_math` (the same function the gear build and
  `/gear/preview` use, so helical gears get their transverse pitch diameter); B's part should hold a `RackFeature` with the same module
  (if not, still allowed: no check in v1).
- **Gear sense:** d_A, d_B = the world axis directions of the two references at the stored poses (the resolved `direction` placed in
  world, as `mate_world_geometries` gives them). If |d_A · d_B| > 0.9 (parallel axes): c = sign(d_A · d_B); when both tooth features are
  external, k = −c (they turn opposite ways in the world); when one is internal (an internal `GearFeature`), k = +c. Non-parallel axes
  (bevel): k = −1. No tooth features (typed ratio): use the external rule.
- **Rack sense:** n = the vector from A's axis point to B's edge midpoint, made perpendicular to d_A and normalised; the rack moves along
  t = d_A × n for a positive turn of A; k = sign(t · d_B) (d_B = B's resolved edge direction in world); if |t · d_B| < 0.5 use k = +1.
- **Screw sense:** k = +1 (right-hand thread). The UI calls the switch "Left-hand" for the screw, "Reverse" for the others.

#### 3.3.4 The residual (the heart of it)

The group model (`backend/app/document/assembly_group.py`, `GroupModel`) evaluates residuals at candidate poses; `model.base_transforms`
are the poses the solve started from (the stored poses, or the client's `reference` poses: `solve_group` replaces them, see its warm-start
lines). A coupler's rows compare a candidate pose with that base:

For a member with base pose (R₀, t₀) and candidate pose (R, t), and a world unit axis d (taken at the **base** pose):

- **Turn about d.** Q = R · R₀ᵀ as a unit quaternion (w, v) with w ≥ 0 (negate it if w < 0). Δθ = 2 · atan2(v · d, w) ∈ [−π, π]
  (the twist part of a swing-twist split). A frozen side (fixed occurrence, root geometry) has Δθ = 0.
- **Travel along d.** For the side's point p (its axis point, or a straight edge's midpoint) in the member's local frame:
  Δs = ((R · p + t) − (R₀ · p + t₀)) · d. Frozen: 0.

Rows (one each):

- gear: `Δθ_B − k · r · Δθ_A` (radians)
- rack and pinion: `Δs_B − k · (p / 2π) · Δθ_A` (mm), with Δs_B along B's edge direction d_B
- screw: `(Δs_B − Δs_A) − k · (L / 2π) · (Δθ_B − Δθ_A)` (mm), all four along / about **A's** axis d_A

Here A and B are **the mate's references in stored order**. `build_group_model` may swap a mate's sides (`swapped`: "reference 1 is the
mover", see `resolve_oriented_branch`): keep the swap flag per side, or do not swap couplers at all; the tests in M3 must include a group
where reference 2 is grabbed.

At the base pose every coupler row is 0, so (D1) a solve that only re-satisfies other mates never sees a coupler pull. The Δθ wrap is
safe because a single solve's steps are capped (`ROT_CAP`) and clients re-anchor every ~150 ms; a wish more than ~170° away from the base
in one request is not supported (the VR Drive tool caps its speed, §3.5).

**Where the rows go:**

- `GroupModel.residual`: for a coupler mate, append `_coupler_rows(mate, a, b, placed)` instead of `_mate_residual_vector(...)`.
- `build_group_model`: skip the branch resolution (`resolve_oriented_branch`) and the final "unsupported geometry" check
  (`if not _mate_residual_vector(...)`) for couplers; validate their geometry with the coupler's own rule instead (each side resolves
  to a direction, and a point when it needs Δs).
- **Consumer audit** (do it first and write the list into the notes, as `docs/width-mate-plan.md` W1 did): every reader of mates or
  of `_mate_residual_vector`: `rg "_mate_residual_vector|_mate_residual_satisfied|_add_mate_constraints|_applicable_mates|branch_fields|resolve_branch|search_branch_changes|branch_options|branch_alternatives|constraint_status|hinge_swing_state|_seed_poses|_predicted_seed|preview_mate_solve|mate_world_geometries" backend/app`.
  Expected outcome per reader: py-slvs paths (`assembly_solver._add_mate_constraints`, `_applicable_mates`, the single-occurrence
  fallback seed) skip couplers; branch machinery returns "no branch" for them; `_mate_residual_satisfied` treats them as satisfied;
  `constraint_status` (mate health) reports them ok; `_seed_poses` ignores them; preview of a new coupler mate returns the current poses
  unchanged; `discover_component` keeps them (they join two gears into one group: that is the point).
- `GroupModel.jacobian`: `export_constraint_model` returns `None` for a coupler (its type is not in `SUPPORTED_TYPES`), so the
  central-difference fallback is used. Correct, slower; M6 makes it analytic.
- `analyze_model` / basis / `dof`: unchanged; the coupler rows remove one freedom each, so two gears on fixed shafts give DOF 1.

#### 3.3.5 Constraint model v5 (M6)

- `constraint_model.py`: `COUPLER_MODEL_VERSION = 5`, emitted only when the model has a coupler (else the old 3 / 4, unchanged files and
  vectors). A coupler entry carries `type`, `value`, `k` (+1 / −1), and per side: `member`, optional `frozen`, `axis_origin`/`point`,
  `direction` (local, as today) plus **`anchor`**: the side member's base pose `{"r": 3x3, "t": 3}`. `SUPPORTED_TYPES` gains the three.
- `ConstraintModel.residual` evaluates the rows of §3.3.4 with analytic Jacobians in the existing chart (`t += δt`, `R = exp(ω) R`):
  - turn: with Q = R · R₀ᵀ = (w, v), w ≥ 0, a = v · d, the gradient of Δθ with respect to ω is
    `g = (w² d + w (v × d) + a v) / (w² + a²)` (at Q = identity this is d); with respect to δt it is 0. (Checked numerically in the
    planning session: 200 random poses up to ±170°, worst relative error 2e-9 against central differences.)
  - travel: with q = R · p (the rotated local point), ∂Δs/∂δt = d and ∂Δs/∂ω = q × d.
  - **A test must check both against central differences** (1e-6 relative) at random poses, including near Δθ = ±150°.
- `tools/motion_vectors/generate.py`: add `local_retract` cases with a gear pair (1:2, both on fixed shafts), a rack and pinion, and a
  screw; regenerate `docs/motion/vectors.json`; `--check` passes under system python. Update `docs/motion/projector-spec.md` §4b with the
  v5 entry shape and the two gradient formulas.
- **Dart** `client/lib/motion/local_retraction.dart`: parse version 5 and the coupler entries, same rows and gradients; its test runs the
  new vectors. **GDScript** `scripts/motion/local_retraction.gd`: the same; copy the regenerated vectors to
  `tests/fixtures/motion_vectors.json` and record the CAD commit in the test header, as before. (The GDScript solver stays unused in
  the app: `docs/local-retraction-benchmark.md`.)

### 3.4 Flat app (M4)

Reading: `client/lib/viewport3d/mate_panel.dart`, `width_pick.dart`, `part_screen.dart` (mate flows), `assembly_tree_panel.dart`,
`api/document_api_client.dart` (`MateDto`), `motion/constrained_drag_session.dart`, `test/mate_panel_test.dart`, `test/width_mate_test.dart`.

- `kMateTypes` gains `gear`, `rack_pinion`, `screw` with labels "Gear", "Rack and pinion", "Screw"; picks are two axis picks like
  Concentric (rack: an axis then a straight edge); the value field is "Ratio (B turns per A turn)" / "Travel per turn (mm)" /
  "Lead (mm per turn)", empty allowed for gear and rack ("Auto from the teeth"); the branch toggle reads "Reverse" (screw: "Left-hand").
- The mate list / tree shows the type, value and sense; edit changes value and Reverse; delete as usual.
- Drag: nothing to change for M4 (`constraint_model` is null -> projection); check by a test that a gear-coupled anchor without a model
  keeps projecting.
- Tests: `client/test/coupler_mate_test.dart` (panel flow, payloads, edit, labels, a DTO round trip with each new type).

### 3.5 VR (M5 mates tool, M7 Drive)

Reading: `scripts/mates_tool.gd` (types, picks, `build_create_payload`, `update_mate`, anchors), `scripts/ui/tablet_pages.gd` (the
Mates page), `scripts/ui/wheel_flows.gd` (the wheel's Mates ring and type ring), `scripts/design_table/mate_health.gd`,
`scripts/topology_pick.gd` / `laser_pick.gd` (what a pick knows about a face or edge), `tests/width_mate.gd`, `tests/mates_tool.gd`,
`tests/fake_mates_tool.gd`, `tests/e2e_mates_motion.gd`, `tests/data/make_rooms_fixture.py`.

**M5, the mates tool:**
- `MATE_TYPES` gains `gear`, `rack_pinion`, `screw`; labels as the flat app. Two picks; each must be an axis kind (round face, circular
  edge, straight edge; rack's second: a straight edge), with the existing per-type pick hints on the wheel. Value: the keyboard, with an
  empty entry meaning Auto (gear, rack); the hint says so. "Reverse" / "Left-hand" uses the existing secondary-flip toggle and label
  machinery (`toggle_secondary_flip`, `branch_text`). No ghost preview for couplers (nothing moves): the preview call is skipped and the
  status line says "Turning one will turn the other".
- Mate list on the tablet: type, value ("1 : 2.00", "62.8 mm per turn", "lead 2 mm"), Reverse; edit value and Reverse via `update_mate`.
- `mate_health.gd`: couplers show as healthy unless the backend says otherwise.
- Dragging: unchanged code; the backend basis couples the motion. Turning a gear by hand (grip and twist) turns its partner.
- Fixture: `tests/data/make_gear_fixture.py`, run against the live backend (`tools/start_backend.sh` first), writes
  `tests/data/gear_pair.didsa`: a plate (fixed) with two holes 60 mm apart; gear A (module 2, 20 teeth, bore 8) and gear B (module 2, 40
  teeth, bore 8) in their own parts; each gear concentric to its hole and coincident face to the plate; **no** gear mate (the tests make
  it). Use the backend's routes (create parts, features, occurrences, mates; export native) and write with Python's json (see
  `make_rooms_fixture.py` for why not Godot). Centre distance check: m (z_A + z_B) / 2 = 60 mm.
- Tests: `tests/gear_mates.gd` (headless with the fake backend: types on the tablet and the wheel, pick validation, payloads incl. empty
  value, Reverse toggling, list labels); `tests/e2e_gear_mates.gd` (live: open the fixture with `DIDSA_NO_LANDING=1`, create the gear mate
  with an empty value, read back r = 0.5 and the k that §3.3.3 gives for the two resolved axis directions (do not assume they point the
  same way: OCCT may orient either cylinder's axis either way); a `mate-motion` request with gear A turned 90° about the world plate
  normal returns B turned 45° ± 0.5° **the opposite way about the same world normal**, both still on their holes; commit and reload: poses kept;
  Reverse flips the sense; a rack-and-pinion and a screw case on simple blocks in the same file or a second fixture).

**M7, the Drive tool** (`scripts/drive_tool.gd`, a tool like `measure_tool.gd`):
- On the tablet's Assemble page and as a wedge on the wheel's Mates ring ("Drive").
- Pick: laser + trigger on a **round face or circular edge** (drive axis = its axis, spin) or a **straight edge** (slide along it). Not
  an axis kind -> "Pick a round face to turn it, or a straight edge to slide it". Fixed part -> the existing locked message.
- Run: thumbstick X (dead zone 0.15) sets speed, −1..1 -> −30..30 rpm (slide: −50..50 mm/s); A toggles "keep running" at the current
  speed; B stops. Each frame the wished pose = the part's current displayed pose turned about (or moved along) the world drive axis by
  speed × delta, passed to `mates_tool.constrain_drag(part, wished_global)` exactly as a hand drag does (read how a drag begins and
  ends: `has_drag`, `constrain_drag`, `end_drag`); stopping calls `end_drag` (one commit, one undo step). Cap: 60 rpm.
- Readout on the wrist / status line: the driven part's rpm and, for every other member that turns, its name and rpm (from the frame-to-frame
  rotation of its node about its own turning axis; sign relative to the drive axis), e.g. "Gear A 30 rpm · Gear B −15 rpm".
  Nothing moves -> "Held: nothing can turn" (DOF 0 from the first anchor).
- Tests: `tests/drive_tool.gd` (headless with the fake mates tool: pick rules, stick to speed mapping, cap, wish generation per frame,
  one `end_drag` per run, readout text); `tests/e2e_drive.gd` (live, gear fixture with the gear mate: drive A at 30 rpm for 60 simulated
  frames at 90 Hz -> A turned 120° ± 2°, B 60° ± 2° the opposite way in the world, one undo entry, poses committed).

### 3.6 Limit mates (M9, stretch, needs the owner's go)

Types `limit_angle` (two axis-and-direction references like an ANGLE about a hinge) and `limit_distance` (like DISTANCE), with new fields
`limit_min` / `limit_max`. Inequalities in `solve_group`: solve without them; any violated limit joins as an equality at its nearest bound;
re-solve; at most 3 rounds; the basis is built with the active limits. Clients need nothing new (the basis stops at the bound; a re-anchor
frees it when the wish pulls away). Write its own short scope note before building.

**Built 2026-10-23: see `docs/limit-mates-scope.md` (scope note, then "As built") and "M9 notes" below.** (Differences from this paragraph: the clients keep no state between frames, so there is no hysteresis; the model is version 6, a superset of 3 to 5; VR stops the projection instead of running the nearest-point solve per frame.)

## 4. Milestones

Each milestone: reading list (above, §3.x), tasks in order, gate. "Gate" commands are those of §2.2.

### M1 Gear bore (BE, FA)
1. BE: fields, schemas, native format (only when > 0), geometry cut, validation (§3.1).
2. BE tests: `backend/tests/test_gear_bore.py` (gears marker): an external gear with bore 8 has a cylindrical face of radius 4 on the
   axis and its volume drops by π·4²·face width (1e-3 relative); bore 0 builds byte-identical mesh / volume to before; native round trip;
   a file without the key loads as 0 and saves without it; the three 422s; a helical gear with a bore; a bevel gear with a bore.
3. FA: field on both screens, DTOs, presets; test in the existing gear screen tests (find them: `rg -l GearDesignScreen client/test`).
4. **Gate:** BE core, BE gears; `flutter analyze --no-fatal-infos` + `flutter test` (full). Commit, push (CAD only).

### M2 Gear tools on the design table (VR) -> **PAUSE**
1. Deck group, icons, hints. 2. `gear_tool.gd`. 3. `rack_tool.gd`. 4. `bevel_gear_tool.gd`. 5. Edit from the Build tree. 6. Tests (§3.2).
7. Docs: `docs/design-table.md` (tool list; move "gears" out of "Not built"), `docs/design-table-gaps.md` item 7, `docs/status.md`
   capability row and test counts, `CHANGELOG.md`, `tests/README.md` rows.
8. **Gate:** `tools/start_backend.sh restart`; VR headless (count rises, 0 failures), VR render, VR e2e (all 36+). Commit, push (VR; CAD too
   if anything changed). **PAUSE**: report; ask the owner to try the gear tool on the headset (layout, reading the readout, build time of a
   helical gear on a Quest-connected backend).

### M3 Coupler mates in the backend (BE)
1. Consumer audit (§3.3.4), written into the notes.
2. Model, schema, validation, defaults (§3.3.1-3.3.3).
3. Residual rows and the group-model changes (§3.3.4).
4. Tests, new file `backend/tests/test_coupler_mates.py` (not a gears-marker file unless it builds gear features; if it does, split the
   gear-feature cases into `test_coupler_mates_gears.py` so the markers stay right):
   - create / list / PATCH / delete each type; every 422 of §3.3.2; native round trip (and an old file still byte-identical);
   - auto ratio from two gear parts (20 and 40 teeth -> 0.5), auto rack travel (π × 40 for module 2, 20 teeth), default senses
     (external pair parallel same-direction axes -> k = −1; an internal + external pair -> k = +1; flipped axis direction -> the sign follows);
   - creating a coupler moves nothing; Enforce all / Solve with a coupler present moves nothing a coupler-free file would not;
   - `mate-motion`: plate fixed, A and B concentric to holes, gear mate r = 0.5 with its default sense: DOF 1; wish A +90° about the
     world plate normal -> B turned 45° the opposite way about that normal (0.1° tolerance; measure in world terms, since either
     cylinder's resolved axis may point either way), B's axis still on its hole; the same with **B grabbed** (+60° on B -> A −120°); with `reference` poses from a
     previous anchor (warm start) after a total turn of 400° in 150 ms-sized steps -> B has turned −200° in total (the unwrap works);
   - rack: pinion +360° -> rack moved p mm along its edge; screw: nut +720° about a fixed screw with lead 2 -> nut moved 4 mm (right-hand
     sign);
   - the central-difference Jacobian is used (`export_constraint_model` is `None` with a coupler) and the group still converges;
   - DOF / `constraint_status` for a coupler group.
5. Docs: CAD `docs/status.md` dated entry, `docs/roadmap.md` rollout step 3 progress line, VR `docs/backend-api-notes.md` (the new types,
   value meanings, sense, the 422s).
6. **Gate:** BE core, BE gears, motion vectors `--check` (system python; unchanged so far). Commit, push (CAD; VR docs).

### M4 Coupler mates in the flat app (FA)
1. `MateDto` and the panel (§3.4). 2. Tree / list labels. 3. Tests. 4. Docs: CAD `docs/status.md`.
5. **Gate:** `flutter analyze --no-fatal-infos` (no new error / warning, §2.3), `flutter test` (full). Commit, push.

### M5 Coupler mates in VR -> **PAUSE**
1. Fixture script and `gear_pair.didsa` (§3.5). 2. Mates tool types, picks, value, Reverse, labels, health. 3. Wheel entries. 4. Tests.
5. Docs: `docs/status.md` (capability row, counts), `CHANGELOG.md`, `tests/README.md`, `docs/backend-api-notes.md` if anything changed.
6. **Gate:** restart backend; VR headless, VR render, VR e2e (incl. `e2e_gear_mates`); BE core. Commit, push both. **PAUSE**: report; ask the
   owner to open the fixture (or their own gears) on the headset, make the gear mate and turn a gear by hand: does the partner follow
   smoothly through the projector, is the sense right, do the teeth stay meshed?

### M6 Constraint model v5 (BE, FA, VR)
1. BE `constraint_model.py` v5 (§3.3.5) and the analytic Jacobian; `GroupModel.jacobian` now takes the analytic path for couplers;
   tests in `backend/tests/test_constraint_model.py` (export shape, version 5 only with a coupler, gradients vs. central differences,
   backend `sqp_nearest` on a gear pair lands on the relation).
2. Generator cases, regenerate `vectors.json`, spec §4b text.
3. Dart parser and rows; `client/test/local_retraction_test.dart` runs the new cases.
4. GDScript parser and rows; fixture copy; `tests/local_retraction.gd` and `tests/motion_vectors.gd` run the new cases.
5. **Gate:** motion vectors `--check` (system python), BE core, BE gears, `flutter test` (full), VR headless, VR e2e. Commit, push both.

### M7 Drive tool (VR) -> **PAUSE**
1. `drive_tool.gd`, tablet entry, wheel wedge (§3.5). 2. Readout. 3. Tests. 4. Docs (`status.md`, `CHANGELOG.md`, `tests/README.md`,
   README's feature list).
5. **Gate:** restart backend; VR headless, VR render, VR e2e. Commit, push. **PAUSE**: report; ask the owner to drive the gear pair on
   the headset (speed feel, readout, does a 30 rpm drive stay smooth over Wi-Fi to the backend, frame rate).

### M8 Gear train demo, docs, final run -> **PAUSE (end)**
1. `demo/assemblies/gear_train/Gear_train.didsa`: plate, a 20-tooth pinion driving a 40-tooth gear, a rack driven by the pinion, all
   mated, made by a script next to the fixture script (same approach), with a crank handle on the pinion. Row in `demo/README.md`;
   offered with the other demo assemblies on the landing (find where `plate_and_peg` is listed: `rg -n plate_and_peg scripts`).
2. Docs pass, both repos: VR `docs/status.md` (capability rows, open items, counts), `README.md`, `docs/README.md` index, `CHANGELOG.md`
   (map M1-M8 to dates), `docs/design-table.md`; CAD `docs/roadmap.md` (rollout step 3 done; brainstorm "Gear Design in VR" and "assembly
   animation" updated), CAD `docs/status.md`. This plan's Progress table complete.
3. **Gate (full):** every suite of §2.2 including BE bevel pair if M1 touched bevel code (it does: the bore). Commit, push both.
   **PAUSE**: final report with every count, what was verified where, and what only the headset can tell.

## 5a. Future motion features (not in this plan)

Recorded 2026-10-22 so they are not lost; **none is to be built in M1-M9**. Each needs the owner's go and its own short scope first.

| Feature | What it does | How it would fit |
|---|---|---|
| Belt / pulley, chain / sprocket | Two pulleys turn the same way at a diameter (or teeth) ratio | A gear mate with the other default sense; its own type for the right default and labels |
| Worm and wheel | Worm starts / wheel teeth, axes at right angles | A gear mate between non-parallel axes (already allowed); its own type for the auto ratio |
| Linear-to-linear coupler | Lever, rope over a pulley, hydraulic pair: one slides x, the other k·x | Coupler row with two travel terms |
| Generic rotation coupler | Any two turns at a set ratio, no teeth | The gear mate without tooth counts |
| Angle limit | A hinge that stops between two angles (door, lid) | With the distance limit, M9's active set |
| Path / slot mate | A point stays on a curve or edge of another part (pin in a curved slot, roller on a track) | New equality residual: point-to-curve distance and tangent from OCCT edges, plus the constraint model in three ports |
| Slot ends | Travel limits at each end of a path mate | Path mate plus M9's limits |
| Cam and follower | The follower stays in contact with a turning cam profile | A path mate whose curve turns with the cam |
| Universal joint | Two shafts at an angle joined by a cross | Possible today with concentric + angle mates on a cross part; a dedicated mate is convenience |
| Contact / collision, springs, dampers, torque motors, Geneva drives, ratchets | Dynamics and intermittent motion | Need a physics or contact solver: a separate project (a motion study) |

## 5. Risks and open questions (for the owner)

- **Sense stability.** The default sense uses the resolved axis direction of a picked face. If OCCT resolves a cylinder's axis the other
  way after a rebuild, the stored k would now mean the opposite rotation. M3 tests a native round trip and a feature rebuild; if that fails,
  store the sense relative to the world directions at creation instead and note it.
- **Teeth phase (D1).** Gears do not line their teeth up on their own. If that annoys in use, a later "Mesh teeth" button can turn gear B
  about its axis to the nearest meshing phase (it knows both gear features), once.
- **Network round trips.** The coupled drag and Drive both live on the projector and re-anchors; a slow backend link shows up as lag, not
  as error. Measured only on the headset.
- **Planetary carriers (D6)** and gear chains / planetaries inside one part (D2) are out of scope.
- **Older apps.** A file with a coupler mate opened by an older backend fails to import (unknown mate type); current apps read it.

## 6. Kick-off prompt for the implementing session

> You are implementing `docs/gears-and-motion-plan.md` in DIDSA-VR (with DIDSA-CAD checked out next to it as `../DIDSA-CAD`), on the
> branch `claude/gears-and-motion` in both repos. Read the plan's "Rules for the implementing session" and follow them exactly. Run
> `tools/setup_test_env.sh`, `source /opt/tools/env.sh` and `tools/start_backend.sh`, then start at the first milestone whose Progress row is
> not Done. Work task by task, run the milestone's gate, commit and push both repos, fill in the Progress row, and stop at every PAUSE with
> a short report. When the code disagrees with the plan, follow the code and write the difference under "Implementation notes".

## Implementation notes

(The implementing session writes here: the consumer audit of M3, every place the code differed from this plan, and anything left unverified.)

### Baseline note (planning session, 2026-10-22)

- All baseline rows in §2.3 were run in the planning session's container with the tools from `tools/setup_test_env.sh`. Not run there:
  BE bevel pair (very long) and `tests/test_planetary_gear_jobs.py` (serial). Flutter master moves daily: if `flutter analyze` shows new
  kinds of infos on untouched code, that is the channel, not this work; note it and compare against `main`.

### M1 notes (2026-10-22)

- **422 shape.** The plan says `{"type", "message"}`; the gear code uses `{"type", "detail"}` (`_invalid_gear_parameters`), so the three bore
  errors (`invalid_bore`, `bore_on_internal_gear`, `bore_too_large`) use `{"type": ..., "detail": ...}`. Clients should read `detail`.
- **Where the checks live.** Not in `_validate_gear_feature_payload` (the root diameter needs the resolved geometry): `validate_bore` in
  `gear.py` is called from `resolve_gear_from_bodies`, the coarse resolver, and (bevel) `resolve_bevel_gear_from_bodies` and its coarse
  resolver. `cut_axial_bore` is shared by the spur and bevel builders. Root diameter is `2 * dedendum_radius` (spur) and
  `2 * inner_cone_distance * sin(root_cone_angle)` at the toe (bevel).
- **Coarse preview gets the bore too** (a cheap cut on the stand-in cylinder / cone), so the VR coarse preview in M2 shows the hole. The
  coarse path with `bore_diameter == 0` is unchanged.
- **Native format.** `bore_diameter` is written only when > 0 and read with default 0.0, so a file without a bore is byte-identical.
- **AI plan schema** was not touched (it does not list gear fields).
- **FA.** The Bore diameter field is in `gear_design_screen.dart` (External only, blank = none) and `bevel_design_screen.dart` (single gear and
  crown modes). Presets store it under `boreDiameter` (a missing key loads as blank). Edit mode reads `bore_diameter` back from the PATCH response.
- **Not run:** BE bevel pair suite (`-m bevel_pair`, very long). `bevel.py` changed only by an added bore branch that is skipped at 0 and
  an import of `validate_bore` / `cut_axial_bore` from `gear.py`; the bevel *pair* path does not call `resolve_bevel_gear_from_bodies`.
  `test_bevel_gear_feature.py` ran in the gears leg. Worth running once at the end (M8).
- **Not verified:** no hand check of the bore in the flat app UI (widget tests only). The motion-vector check is not part of M1's gate and was not run.

### M2 notes (2026-10-22)

- **Where the settings live.** The three tools keep their numbers in the editor's `options` dict under their own prefixes (`g_`, `r_`, `b_`, so `type_option` / `option_typed` work on them), put there on first use by `features/gear_common.gd` (`ensure`) rather than in the editor's literal. They are kept between uses on purpose (the next gear starts from the last one); a test that wants defaults resets them (`e2e_gears.gd` `reset_gear`).
- **Editor changes (all small).** `table_editor.gd`: `NONNEGATIVE_OPTIONS` (bore, fillet, backlash, rack backing, spiral may be 0 but not negative), `g_helix` / `g_shift` in `SIGNED_OPTIONS` (a helix must stay under 90 degrees), whole-tooth and cone <= 90 checks in `option_typed`, and one awaited hook `preview_aux(ed)` (new in `feature_tool.gd`, a no-op by default) called at the start of each preview run: the Gear tool uses it for the cheap `/document/gear/preview` readout (pitch, tip and root diameters), cached per set of numbers.
- **Readout position.** The two readout lines sit directly under External / Internal (the panel scrolls, and the lines would otherwise be below the fold with Apply).
- **Plane pick.** As in Split: a pull on a plane, a made plane or a flat face while the tool is active is the gear's plane (`plane_ref`); with none picked no `plane_ref` is sent (the backend's XY). Choosing the tool again forgets the pick. A Build row's `plane_ref` (nulls dropped; a plain XY plane reads back as none) is loaded on Edit.
- **Edit.** Gear, Rack and Bevel all `edits_in_tool`. The PATCH leaves out `gear_type` / `rack_type` / `bevel_type` and `target_body_ids`. An explicit profile shift cannot be turned back into Auto by a PATCH (the backend limit already noted in `GearFeatureUpdate`); Auto is simply not sent. A rack is an eager preview, so while one is being edited nothing is previewed (like every eager tool).
- **Backend messages.** `PartFeatures._plain` says the three bore refusals in words (`bore_too_large` and so on); the status line otherwise showed the raw type.
- **Build row summaries** (second line): `External 20 teeth, module 2, bore 8`, `Internal 60 teeth, module 1.5, herringbone 15 deg`, rack `10 teeth, module 2`, bevel `20 teeth, module 2, cone 45 deg`.
- **Not done / not verified.** The `.uid` files for the new scripts are not committed (the headless runs do not create them; Godot writes them when the editor opens the project). Nothing was tried in a headset: the panel layout was only looked at in the llvmpipe dock render (`tests/dock_panels_render.gd` now also shoots the three tools). The coarse previews (gear with and without a bore, bevel) and a helical gear with a bore were run against the real backend; a spiral bevel and a herringbone gear were not, and build times on a Quest are unknown. The shaft-hole advice is the readout only: no hole is cut for the user.
- **Try on the headset:** Feature > Gears: make a 20-tooth gear with the default 8 mm bore, read the centre distance, Edit it to 24 teeth, make a second gear and a rack beside it on another plane (pull on the plane first), try Helix 15 and Herringbone, Internal (the Outer value fills itself), and a bevel pair with Mate teeth + Cone from mate.

### M3 notes (2026-10-22)

**Consumer audit** (every reader of mates / `_mate_residual_vector` in `backend/app`, and what a coupler does there):
- `assembly_group.GroupModel.residual`: the only place couplers get rows (`_coupler_rows`); `_mate_residual_vector` is never called for one.
- `assembly_group.build_group_model`: no swap, no branch resolution (`model.branches[id] = (None, secondary_flip)`), final check is "an axis on each side".
- `assembly_group._seed_poses` (both loops), `branch_options` (and so `search_branch_changes` and `branch_alternatives`): skip couplers. `mate_branch_controls` says `("secondary_flip",)`.
- `assembly_group.validate_mate_geometry`, `mate_with_flipped_alias`: return early for a coupler (`coupler.prepare_coupler` validates instead).
- `assembly_solver._applicable_mates`: skips couplers, so the py-slvs single-occurrence solve (`/solve` fallback seed, `solve_occurrence_from_guess`) and `_mate_residual_satisfied` never see one.
- `constraint_model.export_constraint_model`: `None` for a group with a coupler (not in `SUPPORTED_TYPES`): the Jacobian is central differences; `constraint_model` is null in `mate-motion` (D5).
- `discover_component` / `constraint_status` / `analyze_model`: unchanged and correct (the coupler joins the two shafts into one group, DOF 1; no over-constraint reported).
- `router`: `create_mate` (prepare_coupler instead of geometry validation + branch fields), `update_mate` (`_update_coupler`: value / secondary_flip / suppressed, no solve), `preview_mate_solve_endpoint` (current pose + `coupler_value`, new field), occurrence delete cascade (by `mate_tops`, unchanged). `ai_plan.py`: a coupler step is refused (`invalid_step_payload`). `native_format`: nothing needed (`type`, `value`, `secondary_flip`, `branch_source` already written; `_mate_from_dict` has no legacy rule for the new types).

**Differences from the plan**
- A straight edge's resolved point is a point on its line (`axis_origin`), not its midpoint; the travel row uses it (any point on the line gives the same travel for a pure slide).
- 422 bodies are `{"type", "detail"}` (the code's shape), as for M1.
- A concave face (a ring gear's inside) can report its axis the other way round, so the default sense of an internal + external pair depends on the picked faces' axis signs (`k = c`, c the sign of the axes' dot product); the test measures the axes instead of assuming. The residual is right either way.
- The preview answer has a new field `coupler_value` so a panel can show the auto ratio.
- `test_coupler_mates.py` uses shaft cylinders concentric to hole plates (plates fixed), which gives each shaft one spin; a rack and a nut plate stand in for the rack and the screw.

**Not verified:** the analytic model (M6) and the clients are untouched. Large single-request turns (over about 170 degrees from the anchor) are not supported by design; the unwrap was tested with 40-degree steps (400 degrees total) and 90-degree steps for the screw (two turns).

### M4 notes (2026-10-22)

- The sense control is **relative**: "Reverse" / "Left-hand" is checked when the sense differs from the one the backend chose by default (new mate: the preview's `resolved.secondary_flip` when the user has not chosen; edit: the sense the mate had when the dialog opened). The raw `secondary_flip` is not shown because it depends on which way each axis points. M5 should do the same.
- The preview returns the ratio / travel the mate would take (`coupler_value`); the panel shows it as "Auto: ..." while the value field is empty.
- The mate row shows only the value ("1 : 2", "62.832 mm per turn", "lead 2 mm"); no sense word (same reason).
- Not done: the panel does not restrict picks to axis kinds (a wrong pick shows the backend's 422); the plan's "drag keeps projecting without a model" check is covered by the existing `constrained_drag_local_test.dart` (`sendModel: false`), not duplicated.
- Not verified: on a device / emulator (widget tests only).

### M5 notes (2026-10-22)

- **Picks.** `TopologyPick.axis_kind(part, entity)` reads the backend's `face_kinds` / `edge_kinds`; `MatesTool.coupler_rejection(type, slot, kind)` refuses what is not an axis (flat face, corner, odd curve) and, for rack and pinion's second pick, anything but a straight edge, before anything is sent. A part with no kinds (older backend) passes and the backend has the last word.
- **Value.** `mate_value` 0 is Auto for gear and rack and pinion (no `value` is sent: the backend reads the teeth); a screw needs its lead (`can_create()` is false and the status line says so). The value is forgotten when the type changes to or from a coupler. `parse_value(type, text, allow_auto)`: couplers above zero; empty = Auto only for a new gear / rack and pinion (an edit has no Auto).
- **Sense.** The control reads Reverse / Left-hand and is relative to the default sense the preview resolved (`_flip_base`; `flip_is_on()`), as in the flat app; the raw `secondary_flip` is still what is sent (a toggle sends the opposite of the shown raw value). The list rows show the value text and a Reverse action, no raw sense.
- **Preview.** Still called for a coupler (it brings the Auto value and the default sense), but no ghost is drawn; the status line says "Turning one part will turn the other (1 : 2, from the teeth)...".
- **Tablet / wheel.** The 10 mate types are wrapped five to a line on the Mates page (one line of ten widened the page and broke `tests/tablet.gd`); the wheel's type ring has ten wedges (`tests/tool_wheel.gd` updated). Choosing Screw on the wheel opens the keyboard for the lead; gear and rack and pinion take no value there (Auto; type one on the tablet).
- **Fixture.** `tests/data/make_gear_fixture.py` (urllib against the running backend, then the native export; run it again after a backend change that alters the file) wrote `tests/data/gear_pair.didsa`: a plate (fixed) with two holes 60 mm apart, a 20-tooth and a 40-tooth gear (module 2, bore 8), each concentric to its hole and flat on the plate, no gear mate. The rack and pinion and the screw are only **made** in the e2e (the plate's straight edge stands in for the rack; two bores for the screw): their motion is tested in the backend (`test_coupler_mates.py`). A rack-and-pinion with a real rack feature on the table is not in the fixture.
- **Test lesson.** An edit of a mate (`update_mate`) saves the driven part's SHOWN pose first; a test that moves parts through the API must adopt the backend poses on screen first (`_adopt_backend_poses`), or the edit moves them back.
- **Not done / not verified.** Dragging a gear by hand in the viewport is not tested end to end here (the code path is unchanged; M7's Drive tool is the way to turn one). Nothing was seen in a headset: how the Reverse button reads, the prompt text, the ten-type ring.
- **Try on the headset:** open `tests/data/gear_pair.didsa` (or make two gears on the design table, put them in an assembly), Assemble > Mates, type Gear, pick one gear's bore then the other's, read the prompt ("1 : 2"), Create, then grip-twist one gear: the other should turn (the backend couples the motion); Reverse on the mates list flips the direction.

### M6 notes (2026-10-22)

- **Anchors.** A coupler measures a member's MOVE from the pose the solve started from, so a version-5 member side carries `anchor {r, t}` and a coupler mate `k` (+1 / -1). The rows are only good within about 170 degrees of the anchor; a client replaces the anchors with the accepted poses at every accepted anchor (`LocalRetractor.setAnchors`, called from `ConstrainedDragSession._accept`; `set_anchors` in `local_retraction.gd`; the backend's `GroupModel.jacobian` passes fresh anchors itself).
- **Rows and gradients.** As in `projector-spec.md` §4b (gear, rack_pinion, screw); the turn gradient is `(w^2 d + w (v x d) + a v) / (w^2 + a^2)` on the rotation part, the travel gradient is `d` on translation and `q x d` on rotation.
- **GDScript.** `local_retraction.gd` reads version 5 and matches all 63 `local_retract` vectors and its own central-difference Jacobian check. The tests that said "version 3/4" or used `gear` as the unknown mate type now expect 5 for a coupler and use `weld`. The GDScript solver is still unused by the app (ruled out on the headset earlier), so no drag path changed.
- **Not done / not verified.** Nothing here has been run in a headset; the Dart session wiring is covered by the vectors and the full suite, not by a dedicated drag test with a gear pair.

### M7 notes (2026-10-22)

- **Where it lives.** `scripts/drive_tool.gd` (a Node like `measure_tool.gd`, `main.drive_tool`). `controller.gd` gets `drive_tool_active` / `drive_tool`: the trigger picks an axis (`_try_pick_drive_axis`, the same laser entity a mate pick takes), and the RIGHT hand (the wheel hand) feeds the stick and A / B each physics frame; the tool ticks in its own `_physics_process` (one tick per frame whichever hand fed). While a part is picked the right stick belongs to the tool (`is_manipulating`).
- **Axis.** From the part's topology meta: a circular edge's circle through three polyline points (centre, normal), a round face through its circular boundary edge, a straight edge's end points. The axis is taken in the world when a run starts and held for the run.
- **Wish.** Each frame: `mates_tool.desired_global(part)` (the drag's accumulated wish, not the lagging displayed pose; the plan said "current displayed pose") turned about the axis, or moved along it (mm of the part's own units x its scale), then `constrain_drag`; the returned pose is shown. A part with no mates, a grounded one and an unmanaged one are refused at the pick.
- **Wheel.** The plan said "a wedge on the Mates ring"; the Mates ring has six wedges with Clear straight down above the pill, so a seventh would have moved it. Drive is a root-ring tool instead. **First built as an eleventh wedge; rendered head-on (23 Oct) the narrower tiles crowded the labels ("Summon table" ran into the hub), so Shoot hide moved into the Visibility sub-wheel and Drive took its place: the ring is ten wedges again, in the same positions.** Its own ring is All tools / Stop / Tablet.
- **Readout.** Rates come from the frame-to-frame rotation of each member node (`mates_tool.drag_member_nodes`), signed against the drive axis, smoothed (0.15 per frame); the names are the nodes' names (what the other messages use), not the part names ("Mesh2 30 rpm · Mesh3 -15 rpm" in the e2e). "Held: nothing can turn." comes from `take_stuck_notice`.
- **Test lesson.** A test that makes its own ticks must switch the tool's `_physics_process` off, or the real physics frames tick it with no input and stop the run.
- **Not done / not verified.** Nothing seen on a headset: stick feel and dead zone, whether 30 rpm over Wi-Fi to the backend is smooth, frame rate with several followers, the wheel wedge position, the readout on the wrist. Dragging by hand and Drive are not combined (both would use the same drag state).
- **Try on the headset:** open `tests/data/gear_pair.didsa`, make the gear mate (Assemble > Mates > Gear, pick the two bores), switch Mates off, then Drive (tablet Assemble > Drive, or the wheel's Drive wedge): point at gear A's bore and pull the trigger, push the right stick sideways. Gear B should turn the other way at half the speed. Try A (keeps running), B (stops), full stick against half stick, and watch whether the motion stays smooth.

### M8 notes (2026-10-22)

- **Demo.** One file, `demo/assemblies/gear_train/Gear_train.didsa` (all parts embedded, like `gear_pair.didsa`), made by `tests/data/make_gear_train_demo.py` against a running backend. Parts: plate (fixed), pinion (20 teeth), gear (40 teeth), rack (10 teeth, module 2) with a fixed guide block, a crank handle (a bar with a hole). The plan said "a crank handle on the pinion": the crank is a separate part, concentric with the pinion's bore and flat on its top, and a 1 : 1 gear mate makes it turn with the pinion. The backend's default sense for two gears is the opposite way round in the world, so the script reverses it for the crank (a first run without that turned the crank against the pinion).
- **A trap for tests.** A pose's `rotation_axis` turns a part about its own origin. The crank's origin is its corner, not the hole, so a wish that only changes the angle moves the hole off the pinion's axis and the solver answers with a compromise (30 degrees of 90). `e2e_gear_train.gd` turns the origin round the pinion's axis as well. The Drive tool is not affected: it turns about the picked axis.
- **Not matched.** The teeth of the pinion, the gear and the rack are not phased to mesh, and nothing checks interference; the demo is for the motion, not the picture.
- **Landing.** `scripts/landing/demo_catalog.gd` lists it third under Demo assemblies (`tests/landing.gd` now expects three).
- **Docs pass.** VR: `docs/status.md`, `README.md`, `CHANGELOG.md`, `tests/README.md`, `demo/README.md`, `docs/landing-scope.md`; CAD: `docs/roadmap.md`, `docs/status.md`. `docs/design-table.md` was done in M2.
- **Only the headset can tell.** Everything in the M2, M5 and M7 "Try on the headset" lists; how the gear train looks and feels at 1:1; whether the Drive tool stays smooth over Wi-Fi.

### User-session testing (2026-10-23)

Both apps were run and driven with simulated input as a CAD user would: the flat app (Linux desktop build under Xvfb, xdotool clicks, typing and drags, screenshots) and the VR app (the real scene with two fake OpenXR hand trackers, so presses, stick pushes and hand poses go through the real controller code: `tests/helpers/vr_user.gd`, `tests/user_session_gears.gd`, `tests/user_session_train.gd`; both also run in `ci_e2e.sh`). Found and fixed:

- **VR names.** The Drive readout and many mates messages used the glb's node names ("Mesh2"). `MatesTool.part_label` now gives the occurrence's name, else the Part's name, else its file's base name (at most 18 characters), and nothing at all when none is readable ("Mesh 1", ids). Drive reads "Gear A (20 teeth) 30 rpm · Gear B (40 teeth) -15 rpm"; with no names it is just the numbers; a refusal names the part or says "This part".
- **A laser on a bore picked the wrong thing.** The pick snaps to the round face's seam line or a corner, and the seam is a straight edge 4 mm off the axis: a Gear mate made on it would turn about the wrong line. For a coupler's turning side (and for Drive) a snapped straight edge or corner of a round face is now the round face; a circular edge stays; the rack's straight edge is untouched.
- **Drive.** The readout also lists parts that slide (the rack, mm/s); a hand gripping a part stops a run and the pushed stick must come to rest before it drives again (two writers on one drag); with Relax mates on, Drive says so instead of "no mates"; the wheel's Flip wedge reads Reverse / Left-hand for a coupler.
- **Flat app.** The gear preview now draws the bore; a pick in the mate panel and Measure reads as its component ("Plate - Face #4", not "Body (component)" for both); a typed Move / Rotate that the mates only let part way through says so ("Moved as far as its mates allow ... 59.0 degrees short").
- **Demo and fixture files.** The flat app opens a multi-part file on its first part, and the root assembly was last (it opened as just the plate); the root is now first. Occurrences have display names (the tree read "Component 3").
- **Not wrong, but worth knowing.** A pose's rotation turns a part about its own origin, so a numeric 90 degrees on the crank (origin at its corner) gets about 31 (flat app Rotate panel); a rack slides off the plate (no travel limits then; the demo's rack has them since M9); at 1:1 the laser snaps to a small bore's seam, the model has to be scaled up first (two-hand spread); picks on a flat face with Screw selected are accepted by the flat app until Confirm (the backend's 422 explains); the flat app's mate panel covers most of a 720-pixel-high window.
- **Not done / not verified.** The tablet's pages were only looked at as pictures (no laser clicks on the tablet); a Screw's lead by the keyboard was not typed; headset feel as before. The three render checks for see-through glass (`room_walls_render`, `appearance_render`, `appearance_clip_render`) fail on a clean checkout of the previous commit too, after the Mesa Vulkan drivers were installed for the flat-app run: an environment change in this session's container, not these changes.
- **UI check from head-on renders (23 Oct).** The first pictures sent for review were taken from a poor angle (the tablet almost edge-on, the wheel cropped); rendered square to each panel: the tablet pages are fine (the Drive page is sparse: a hint, a Stop bar and the status line), the eleven-wedge ring was crowded (fixed above), and the Mates page showed Allow rotation / Minimal movement for the coupler types, which mean nothing for them (now hidden). Still true and not changed: the active-tool badge floats where the wheel's centre is and shows through it; the wedge widths look uneven only because the ring faces the head, not the camera.
- **Wheel pass (23 Oct, second look).** Rendered whole and square to the ring: icons and names are now centred on each tile's area centroid (they sat 10-15 mm towards the ring's axis on the diagonal tiles); the Appearance tile is only 71 mm wide at the height of its name and "Appearance" is 76 mm even at the smallest size, so the wedge reads **Look** (tablet and prompt keep Appearance) and its icon is a shaded sphere with a glint (the spray gun is gone, tips and tablet use the same icon); the Section prompt said "Wheel: Flip" but the Section ring was the root ring: it now has All tools and Flip.
- **Wheel names and layout (23 Oct, owner's review).** Visibility is **Show / Hide** (a menu: Isolate part, Invert, the Hide tool - the old Shoot hide, Show all); the Look rename was reverted to **Appearance**, which needs a wide tile, so the root ring is now Mates, Measure, Summon table, Section, Drive, Appearance (straight down), Show / Hide, Undo, Scenes, Home (the long names on the wide tiles); the hovered tile's one-line description shows in the panel under the ring: Appearance "Control the appearance of the models", Scenes "Temporarily change part positions and visibility", Show / Hide "Show / hide parts". The Scenes ring has its entry and exit (layout C of three mock-ups): Start scene (green, filled; Relax mates), the saved scenes, Abandon (red, filled; Return parts, asks first if unsaved), Update, Save new; the old Default wedge is gone.

### M9 notes (2026-10-23)

The scope note is `docs/limit-mates-scope.md` (with an "As built" section); the rules are in CAD's `docs/motion/projector-spec.md` §4b (version 6). In short:

- **Mate and solver.** `limit_distance` / `limit_angle` with `limit_min` / `limit_max`; an inequality: no row unless held. `solve_group` solves without the limits, holds the violated ones at the nearest bound, solves again (at most three more times). Constraint model version 6 only when a group holds a limit. A generator case set, the backend, Dart and GDScript all agree on the 8 new golden vectors (a held limit, released the next frame, a hinge, accepted without the distance guard).
- **Flat app.** Add Mate and the Edit dialog have Minimum / Maximum (either may be empty), "Now ..." from the preview, no Minimal movement checkbox for a limit; the tree row shows the range and where the parts are; a drag stops at the bound with no round trip (Dart `LocalRetractor` active-set rounds); "Stopped at its limit." on release.
- **VR.** `limit_distance` / `limit_angle` after the couplers in `MATE_TYPES`, the tablet type choice and the wheel's Type ring (12 wedges now); Set value asks Minimum then Maximum on the keyboard (empty = no bound); the tablet row shows the range and "now", with a Range action; the drag stops at the bound by scaling the projection back (see the scope note: the nearest-point solve is too slow in GDScript for the demo's four-member group); the Drive tool's readout adds "at its limit" and its wish does not wind up past a stop; the release message says "... stopped at its limit." The gear train demo has the rack's limit (40 mm one way, 6 mm the other: the rack starts near the right end of its travel and always meets the pinion).
- **Live checks.** `tests/e2e_gear_train.gd` (the crank turned the way the rack has room for gets all 31.4 mm; the other way the rack stops at 6 mm and the pinion and gear stop with it) and `tests/e2e_limit.gd` (the Drive tool at full stick through the real drag loop: every frame at or inside the stop, no frame moves the rack more than 1.5 mm, flagged and read out as at its limit, the stored poses are the stopped ones, one undo step, and the way back leaves the stop on the first frame).
- **A bug the live test found.** The first version let the Drive tool's wish run on past the stop; a second or two later the wish was more than half a turn from the stopped pose, a pose is read modulo a turn, and the rack jumped 46 mm to its far end. See the scope note.
- **Not verified.** Anything on the headset: how the stop feels, whether the stop cost (0.8 ms on a desktop, only while a limit holds the part) is fine on the Quest. The angle limit was not driven in either UI.

