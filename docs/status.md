# Status

Short, current status. Read this first, then the doc for whatever you are touching ([`README.md`](README.md) indexes them).
The full chronological build log (every round, bug found, and decision since September 2026) is
[`status-history/status-log.md`](status-history/status-log.md); search it by heading.

**Last reviewed:** 2026-10-14, at `main` after PR #44. **Engine:** Godot 4.7.2, Mobile renderer, OpenXR.
**Update this file whenever a capability changes state, a verification gap closes, or the test counts move.**

## The one thing to know

Everything below is **headless-, software-render- and (where stated) real-backend-verified. Almost none of it has been
felt on a real headset**, and none of it has been measured on Quest hardware (only PCVR via Virtual Desktop has been used,
in a few rounds). "Built" does not mean "good in the hand". The open verification list is the "Untested paths" section of the
[status log](status-history/status-log.md); add to it when headless work lands and remove items when the owner reports them checked.

## Capability matrix

| Area | Built | Real backend | Headset | Notes / where to read |
|---|---|---|---|---|
| Import and viewing (native `.didsa`, glTF, STEP/STL/OBJ via backend) | Yes | Yes | PCVR only | Quest load time and frame rate never measured |
| Manipulation: grip, laser select, whole-model move/turn/scale, steadiness filter, undo/redo | Yes | n/a | PCVR | |
| Locomotion: walk, snap-turn, teleport, travel-speed slider | Yes | n/a | PCVR | |
| Wrist tablet (6 x 2 home grid), popup keyboards, themes and shader effects | Yes | n/a | PCVR (signed off 2 Oct) | [`wrist-tablet-redesign-plan.md`](wrist-tablet-redesign-plan.md) |
| Tool wheel (radial quick access, Paint, tool tips on the wrist) | Yes | n/a | Not recorded; check the log | |
| Assembly tools: Mates (face/edge/corner), Colours, Sections, Measure | Yes | Yes | PCVR (several bugs found and fixed) | Constrained drag: GDScript solver ruled out on headset, see [`local-retraction-benchmark.md`](local-retraction-benchmark.md) |
| Floating windows: Tree, Browser (+PDF), Calculator, Images | Yes | Yes (browser relay end to end) | Not yet | "DIDSA-CAD as a flat window" not attempted |
| **Assembly Rooms** (clipped, resizable sub-assembly workspaces) | Yes (R0-R4) | Yes (`tests/e2e_rooms.gd`, 23 checks) | Not yet | [`assembly-rooms-scope.md`](assembly-rooms-scope.md), [`assembly-rooms-plan.md`](assembly-rooms-plan.md) |
| Sub-assembly selection, group moves, world preview (Hidden/Ghost/Preview) | Yes | Not confirmed; see the rooms plan | Not yet | PR #43; headless and render tests |
| **Design table** (sketch, constrain, features, options to Phase 7) | Yes | Yes | First session done (findings fixed) | [`design-table.md`](design-table.md), [`design-table-gaps.md`](design-table-gaps.md) |
| Passthrough / mixed reality | Wired | n/a | Not yet; standalone Quest also needs the OpenXR Vendors plugin (not included) | |
| Multiplayer / observer client | Not built | | | Idea recorded in [`vision-brief.md`](vision-brief.md) |

## Tests (as of the last recorded run)

- Headless suite (`tests/ci.sh`): **2512 checks, 0 failures** (rooms work, 13 Oct 2026). Counts rise with every feature; treat this number as a floor.
- Render tests under Xvfb + Mesa (`tests/ci_render.sh`): **42**, green.
- Live-backend end to end (`tests/ci_e2e.sh`, list in `tests/e2e_ci_list.txt`): rooms 23 of 23; the rest per that list. Needs a DIDSA-CAD backend.
- CI: `.github/workflows/headless-tests.yml` (every push and PR touching code) and `e2e-backend.yml`.

## Open items that matter most

1. **Headset time.** Quest-native load and frame-rate numbers; the feel of rooms (corner handles, drop-to-add, grab dead zone), the tool wheel, and design-table Phase 7 options.
2. **Cleartext HTTP on Android.** Use an HTTPS URL (e.g. a Cloudflare Tunnel) for the backend on Quest; a custom Gradle build to allow HTTP is not planned.
3. **Server does not guard cycles or unknown Part ids** on `POST /parts/{id}/occurrences`; the client refuses them (see [`backend-api-notes.md`](backend-api-notes.md)).
4. **Design table not built:** surfacing family, curves, gears, constrained sketch drag, sketch pattern/mirror, loft guide curves, feature mirror/pattern, extrude profile selection, dragging tree rows out, sub-assemblies on the table. Authoritative list: [`design-table.md`](design-table.md) and [`design-table-gaps.md`](design-table-gaps.md). Check them before relying on this summary; Phase 7 closed some.
5. **Multi-file assemblies** with `external_ref` and no stamped `resolved_part_id` do not auto-resolve (a server-side composition item). Manual Open/Add from the Files page works.
6. **Quest 2** has not been measured at all.
7. **No `godot-xr-tools` or addons**, deliberately, to keep measuring the bare engine. Revisit once the interaction model is proven.

## Cross-repo

Backend and flat client: `DIDSA-UK/DIDSA-CAD` (roadmap in its `docs/roadmap.md`). Mates, measure, occurrences, import-features and the
browser relay are CAD-side; the endpoints this client uses are mapped in [`backend-api-notes.md`](backend-api-notes.md).
