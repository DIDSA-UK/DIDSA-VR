# DIDSA Design Tools VR documentation

Start with [`status.md`](status.md) (what is built, what is verified, what is open). The top-level [`../README.md`](../README.md) covers setup and controls.

## Reference (kept current)

| Doc | What it is |
|---|---|
| [`status.md`](status.md) | Short current status and capability matrix. |
| [`backend-api-notes.md`](backend-api-notes.md) | The DIDSA-CAD endpoints this client depends on, with checked behaviour and gotchas. |
| [`design-table.md`](design-table.md) | The design table: how it works, what is built, performance, what is not built. |
| [`vision-brief.md`](vision-brief.md) | Product vision, interaction model, open decisions (point-in-time export of a live document; it can drift). |
| [`../tests/README.md`](../tests/README.md) | What each test checks and what to expect. |

## Features and scope

| Doc | What it is |
|---|---|
| [`assembly-rooms-scope.md`](assembly-rooms-scope.md) | Assembly Rooms: decisions and scope. |
| [`assembly-rooms-plan.md`](assembly-rooms-plan.md) | Assembly Rooms: build plan R0-R4 and what each phase found. |
| [`scope-modelling-depth.md`](scope-modelling-depth.md) | Design table modelling depth (scoping pass, 2026-10-08). |
| [`scope-references-and-dimensioning.md`](scope-references-and-dimensioning.md) | Design table references and dimensioning (scoping pass). |
| [`design-table-brief.md`](design-table-brief.md) | The original design-table requirements brief (not live-synced). |
| [`android-build.md`](android-build.md) | Building the standalone Quest APK (step L0): the OpenXR Vendors plugin, the export preset, passthrough, the first-run checklist for the headset. |
| [`test-report-30-oct-plan.md`](test-report-30-oct-plan.md) | The owner's test of the 30 Oct 2026 build (4 Nov): storage folder, empty room / table start buttons, mate highlight, sketch sheet at the front edge, selectable sketch dimensions and constraints with hover everywhere, and selection-first contextual options with breadcrumbs on the design table. A plan, not built. |
| [`feature-tree-review-2026-11-11.md`](feature-tree-review-2026-11-11.md) | Review of the VR client's trees (world, design table, none in rooms) and the plan to make them CAD trees: state icons, selection both ways with a cue in the world, a bottom action bar, one component for world / rooms / table (phases T1-T3). A plan, not built. |
| [`vr-feedback-2026-11-11-plan.md`](vr-feedback-2026-11-11-plan.md) | The owner's VR test notes of 11 Nov 2026: fixed-parent grab message, relaxed-mate grab drift, paint lag (a load race), mate preview skipping the pose sync, Fix / Float on the wheel, Relax fix mates. Packages are built one PR at a time; each package's state is in the plan's Progress notes. |
| [`quest-first-run-fixes.md`](quest-first-run-fixes.md) | The owner's first native Quest 3 run (21 Oct 2026): five bugs (monolith laser reach, sky flicker looking up, Open going to the tablet, the unsaved-changes prompt on demos, black passthrough), their traced causes and the fix plan. |
| [`servers.md`](servers.md) | Servers: `servers.cfg`, the Servers page, switching, address rules, pre-loading with `adb push`, scanning a QR code. |
| [`limit-mates-scope.md`](limit-mates-scope.md) | Limit mates (gears-and-motion M9): the scope note shown before building, and what the code does differently (as built). |
| [`gears-and-motion-plan.md`](gears-and-motion-plan.md) | Next work (2026-10-22): gear tools on the design table, coupler mates (gear, rack and pinion, screw) in both apps and the backend, the Drive tool; milestones M1-M9 with test gates, test tooling and the baseline. |
| DIDSA-CAD [`docs/point-merge-and-vr-sketcher-plan.md`](https://github.com/DIDSA-UK/DIDSA-CAD/blob/main/docs/point-merge-and-vr-sketcher-plan.md) | Plan (2026-10-29, not built): point Merge (backend and flat app), and the design-table sketcher catching up: origin welding and unheld snaps fixed, the line end resolved where the ghost shows it, inferred relationships, alignment guides, Merge in Select (steps V1-V5). Lives in DIDSA-CAD because the backend half is there. |
| [`landing-scope.md`](landing-scope.md) | The landing (first screen): launcher, QR server pairing, tips, 3D logo, demo models (scope, 2026-10-20; L1 to L3, the offline demo, built; servers and QR not). |

## Gaps and live trackers

| Doc | What it is |
|---|---|
| [`design-table-gaps.md`](design-table-gaps.md) | Known design-table gaps and what became of each. |
| [`sketch-as-seed-gaps.md`](sketch-as-seed-gaps.md) | Open decisions and unchecked assumptions from the sketch-as-seed work. |
| [`constrained-drag-rollout.md`](constrained-drag-rollout.md) | VR side of the constrained-drag rollout (plan lives in DIDSA-CAD). |

## History and closed plans

Kept for the reasoning behind decisions; do not treat as current.

| Doc | What it is |
|---|---|
| [`status-history/status-log.md`](status-history/status-log.md) | The full chronological build log (formerly `status.md`). |
| [`wrist-tablet-redesign-plan.md`](wrist-tablet-redesign-plan.md) | Tablet, window and keyboard redesign (built, signed off). |
| [`phase-7-plan.md`](phase-7-plan.md) | Phase 7: option-level depth on the design table (built). |
| [`implementation-plan.md`](implementation-plan.md) | Phases 5-6: references, dimensioning and modelling depth. |
| [`sketch-as-seed-plan.md`](sketch-as-seed-plan.md) | Sketch as seed and the Visibility tool. |
| [`handover-references-overhaul.md`](handover-references-overhaul.md) | Handover for the references overhaul (2026-10-06). |
| [`local-retraction-benchmark.md`](local-retraction-benchmark.md) | Headset benchmark: GDScript nearest-point retraction (no-go for wiring). |

## Conventions

- Plans say what is built and what is not; when a phase lands, update its plan, then [`status.md`](status.md), then [`../CHANGELOG.md`](../CHANGELOG.md).
- State what was verified and how (headless, software render, real backend, headset). Never imply headset verification that did not happen.
- Docs that cite `docs/status.md` sections by name (for example "Milestone 3" or "Untested paths") mean the heading in [`status-history/status-log.md`](status-history/status-log.md).
