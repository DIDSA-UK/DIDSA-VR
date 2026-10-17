# Changelog

Newest first. Dates are 2026. Labels (Milestone, Phase, R-number) are the ones used in older docs and commit messages.
"Verified" means headless, software-render or real-backend tests unless a headset is named. Headset testing is ongoing and informal and is not recorded per feature here. See `docs/status.md`.

## Unreleased (`main`, 14 Oct)

- **Headset bug report, 17 Oct, second round** (three items, headless-tested; none checked on the headset yet):
  - **Tool wheel faces the head**: the ring now points its face at the eyes, tipped back as well as turned (it used to follow the head's yaw only, so with the hand low or out to the side it was seen at a slant), and keeps facing the head while it is up. Hand travel is read in the ring's own tipped plane.
  - **Mates in multi-level assemblies** (Table Assy: Leg + Table Top with Frame > Frame > Frame A / B): Enforce all now re-applies the mates of every sub-assembly, deepest first, then the root's, and puts nested parts back where the stored tree places them. It used to try to solve a mate's path reference (`outer/inner/part`) as if it were a top-level occurrence, which the backend 404s: the "Couldn't satisfy every mate" error. A path reference now marks its top-level occurrence as mated. A part that its sub-assembly's mates hold can no longer be moved on its own while mates are enforced (it moved on screen only and broke them); the same goes for a sub-assembly inside another that its parent's mates hold; the top-level sub-assembly can still be taken as a whole, and Relax all mates frees them. A mate naming a part that isn't in the assembly says so.
  - **Room resize follows the laser**: a corner taken with the laser now follows the laser's end at the distance it was taken from; it used to follow the hand's own movement 1:1, so from across the room it barely moved.
- **Headset bug report, 17 Oct** (six items, all headless-tested; none checked on the headset yet):
  - **Measure**: the in-world dimension now follows the model when it is moved, turned or scaled (it was redrawn only on a new pick or result).
  - **Tool wheel**: opens centred on the hand (it was drawn 45 cm above it) at two thirds of its old size; hand travel shrinks with it, so the cursor stays on the wedges. Rendering it showed the wrist hint panel, hanging off the hand, then hid 50-98% of the wedges round the one pointed at, so while the ring is up the panel now docks under the ring (below the Clear tool pill, in the ring's plane) and goes back to the wrist when it closes; measured 0% covered in `tests/wheel_hint_render.gd`.
  - **Multi-file assemblies**: Open, Add and the startup file now fold in every file an occurrence references (`scripts/native_compose.gd`, a port of the flat app's composer), finding a file under any native extension and letter case (`Frame_A.DIDSAprt` written, `Frame_A.didsa` on disk). Unresolved references are named on the status line.
  - **Paint**: a shot that can't colour a part (the assembly's own content, a backend refusal, a colour still saving) now says why on the wrist and status line instead of only buzzing, and the laser lights the part it will paint. The likely cause of "nothing happens" was the assembly loading without its occurrences (the item above), leaving only root content, which has no colour in the backend's model.
  - **Open with unsaved changes**: the Files page now offers Discard and open, Save then open, or Cancel (it used to refuse and ask for the same action again within a few seconds).
  - **Checked against a live DIDSA-CAD backend** (`tests/e2e_bug_report.gd`, 20 checks), which found three more things, now fixed: the composer re-typed whole-number floats (`20.0` became `20`), so the backend re-minted an already-loaded Part as a new copy when the same file was added again (the composer now keeps every number's text exactly); a bundle file whose occurrences already name Parts inside it was reported as having missing files; and a file added into an empty room (a New room) was not placed or named, because the backend grounds the first part of an empty Part and refuses to move it (it is now placed unfixed and grounded again).
  - **Rooms tile**: New room (makes an empty "Sub-assembly N" Part on the root and summons a room for it), then a grid of open rooms, each with a rendered thumbnail, Bring to me (a minimised room comes back full size) and Close. Delete selected part moved to View > Visibility; the table part's world-preview button moved to Settings > Design table.
- **Constraint model v4 in `local_retraction.gd`** (DIDSA-CAD #303, `docs/motion/projector-spec.md` 4b "Version 4"): accepts model versions 3 and 4. A side may carry `pair` (the second face of a Width / Symmetric mid-plane over two members); its world plane is the average of the two origins with the side's own normal, plus 3 "faces stay parallel" rows per pair. A `pair` in a version-3 model, a bad pair member or a pair without a plane returns null (keep projecting). Passes all 52 `local_retract` golden vectors (17 new `local-width-*`) to 1e-9; new parse tests and a pair-vs-plain cost line in `tests/local_retraction.gd`. The GDScript solver is still not used in the app (ruled out on the headset, `docs/local-retraction-benchmark.md`); this copy is for parity. Not verified on a headset.
- **Wheel parity for Width / Symmetric**: for these mate types the wheel's Clear wedge becomes **Undo pick** (takes back the last face; the ring keeps its five wedges), choosing Width opens the keyboard for the optional offset from the centre, and the greyed Create / Flip hints say "Pick the four faces first" / "Pick the three faces first". Next solution, Allow rotation and Minimal movement remain tablet-only.
- **Symmetric mate** (DIDSA-CAD `docs/width-mate-plan.md`, W5), faces only: pick two faces on two parts and a face of the mirror plane on a third; the two faces end up equally far from it, on its two sides (a left and a right bracket either side of a centre part). It is a plain coincident mate of a mid-plane and that face, so nothing new exists in the document. Type "Symmetric" on the tablet and the wheel's type ring (the pick flow is on the tablet). Not for points or axes (they would need a three-reference mate). Not verified on a headset.
- **Width mate** (DIDSA-CAD `docs/width-mate-plan.md`, W3): a "Width" mate type on the tablet and the tool wheel. Pick the two faces of a gap (one part or two) and the two faces of the part(s) to centre in it (2, 3 or 4 parts in all); the pairs light in two colours, a pair that is not parallel is refused as soon as it is complete, Undo pick takes back the last face, an optional offset from the centre uses the Set value button. Sent as a coincident or distance mate whose references are mid-planes; nothing is created in the scene or the document for the mid-plane. `mate_health.gd` follows Width faces through an edit and reports faces that stopped being parallel. Not verified on a headset.
- **Mates: choosing the solution** (mate plan Phases 1-4, #46; backend in DIDSA-CAD #300): a ghost for every moved part, atomic create/edit, a mate's Aligned/Anti-aligned and side stored on the mate, a confirm step when a new mate needs an earlier mate's other branch, Flip / Next solution controls on the tablet, the hinge swing sense (constraint model v3 in `local_retraction.gd`), and a guard against negative or non-numeric mate values. Not ghosted: sub-assembly leaves. Next solution has no wheel wedge.
- **Rooms tile** on the tablet home screen, which is now a 6 x 2 grid; Rooms sits before Assemble (#43).
- **Sub-assembly selection**: grip latch with a dead zone, trigger cycling, laser breadcrumb, group moves saved on the sub-assembly occurrence (#43).
- **World preview** for rooms and the design table: Hidden / Ghost / Preview, push, tether, fly to world (R4, #43). Group drop copies a sub-assembly into a room.
- Docs: phone/Cardboard observer client idea added to the vision brief (#44).
- Project renamed from "DIDSA VR Spike" to "DIDSA Design Tools VR" (a placeholder name); docs and README restructured.

## 13 Oct: Assembly Rooms R0-R3 (#42)

- R0: room box clip (third clip in `clip_common.gdshaderinc`), registry, clip-aware picking.
- R1: open a Part in a clipped room from the Assembly Tree; `RoomManager`, placement, Max rooms setting.
- R2: room parts grabbable, mate-aware, per-room two-hand model; `tests/e2e_rooms.gd` against a live backend.
- R3: summon by laser, glass walls shader, eight corner handles and move bar, console with pedestal, minimise/restore, tablet Rooms page, drop-to-add with cycle guard, tree Delete naming the mates that go with the part.

## 12 Oct: Phase 7 (#41) and tool wheel (#40)

- Phase 7: option-level depth on the design table: denser two-column properties panel; Extrude (both sides, thin wall, draft); Chamfer angle and flip; Move Face by axis; Pattern skip and orientation; Loft thin wall; Create Plane variants; sketch construction methods.
- Tool wheel: radial quick-access menu, Paint, Clear pill, wrist tool tips.

## 8-10 Oct: Phases 5-6

- References, dimensioning and modelling depth on the design table; Visibility model and sketch-as-seed (Extrude, Revolve, Sweep, Loft from a finished sketch). See `docs/implementation-plan.md`, `docs/sketch-as-seed-plan.md`.

## 3 Oct: Milestone 2, the design table

- Tilted console with part, build tree and tool deck; sketch, constrain and feature tools; save as `.didsa`; first headset session fixes. See `docs/design-table.md`.

## 2 Oct: UI redesign and constrained drag

- Redesigned wrist tablet, window chrome and popup keyboard (signed off after PCVR testing; old tablet removed). Mates and Measure pick edges and vertices. Constrained-drag headset benchmark: GDScript solver not wired (`docs/local-retraction-benchmark.md`).

## 28-30 Sep: Milestones 3-4 and headset rounds

- Floating windows (Assembly Tree, Calculator, Image Viewer, Browser and PDF via the browser relay), assembly tools (Mates, Colours, Sections, Measure), Open/Add files, environments and passthrough, travel-speed slider, resizable windows, full keyboard, smooth mated drag. Several real-headset bug rounds.

## 26 Sep and earlier: Milestones 0-1

- Repo created 26 Sep. glTF assembly endpoint, Godot chosen as the engine, import and viewport, four manipulation modes, wrist tablet, undo/redo, STEP/STL/OBJ import.
