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
| [`dimension-constraint-parity-scope.md`](dimension-constraint-parity-scope.md) | Design table dimensions and constraints at parity with the flat app (scoping pass, 2026-11-18): the gap tables, a shared option catalogue, the controller workflow (hand-ready; hand tracking itself is on the roadmap), pieces P0-P6 and the owner's decisions. Built by the plan's sessions (2026-11-19). |
| [`dimension-constraint-parity-plan.md`](dimension-constraint-parity-plan.md) | Its build plan for coding sessions: the gate (after DIDSA-CAD's 2026-11-18 bug-report plan), defaults, the catalogue and placement contract, sessions S0-S10 (CAD and VR) with briefs and exit criteria, tracker, session prompt, model per session, open items. All sessions done 2026-11-19. |
| [`parity-followups-investigation.md`](parity-followups-investigation.md) | After the parity plan (2026-11-19): every open item and owner observation checked against the code (unreadable sketch names, the options panel, the stick and pad decisions, the projector's as-built behaviours, the redraw cost of a drag, ellipse axes, retyped dimensions, per-entity colours, test health and CI), with the owner's decisions in one list and follow-up sessions F1-F8. Investigation only, no code changed. |
| [`design-table-brief.md`](design-table-brief.md) | The original design-table requirements brief (not live-synced). |
| [`android-build.md`](android-build.md) | Building the standalone Quest APK (step L0): the OpenXR Vendors plugin, the export preset, passthrough, the first-run checklist for the headset. |
| [`test-report-30-oct-plan.md`](test-report-30-oct-plan.md) | The owner's test of the 30 Oct 2026 build (4 Nov): storage folder, empty room / table start buttons, mate highlight, sketch sheet at the front edge, selectable sketch dimensions and constraints with hover everywhere, and selection-first contextual options with breadcrumbs on the design table. A plan, not built. |
| [`feature-tree-review-2026-11-11.md`](feature-tree-review-2026-11-11.md) | Review of the VR client's trees (world, design table, none in rooms) and the plan to make them CAD trees: state icons, selection both ways with a cue in the world, a bottom action bar, one component for world / rooms / table (phases T1-T3). T1 built (headless). Extended across both clients by DIDSA-CAD `docs/assembly-tree-overhaul-scope.md` (20 Nov). |
| [`vr-feedback-2026-11-11-plan.md`](vr-feedback-2026-11-11-plan.md) | The owner's VR test notes of 11 Nov 2026: fixed-parent grab message, relaxed-mate grab drift, paint lag (a load race), mate preview skipping the pose sync, Fix / Float on the wheel, Relax fix mates. Packages are built one PR at a time; each package's state is in the plan's Progress notes. |
| [`quest-first-run-fixes.md`](quest-first-run-fixes.md) | The owner's first native Quest 3 run (21 Oct 2026): five bugs (monolith laser reach, sky flicker looking up, Open going to the tablet, the unsaved-changes prompt on demos, black passthrough), their traced causes and the fix plan. |
| [`server-projects.md`](server-projects.md) | Server projects (S3): the mirror folder per project on the project store, the private sync state, the sync rules and conflict choices, where each screen is, what differs from the scope, what is not verified, and what DIDSA-CAD's pairing screen must write (`p`, `pk`). |
| [`servers.md`](servers.md) | Servers: `servers.cfg`, the Servers page, switching, address rules, pre-loading with `adb push`, scanning a QR code. |
| [`limit-mates-scope.md`](limit-mates-scope.md) | Limit mates (gears-and-motion M9): the scope note shown before building, and what the code does differently (as built). |
| [`gears-and-motion-plan.md`](gears-and-motion-plan.md) | Next work (2026-10-22): gear tools on the design table, coupler mates (gear, rack and pinion, screw) in both apps and the backend, the Drive tool; milestones M1-M9 with test gates, test tooling and the baseline. |
| DIDSA-CAD [`docs/point-merge-and-vr-sketcher-plan.md`](https://github.com/DIDSA-UK/DIDSA-CAD/blob/main/docs/point-merge-and-vr-sketcher-plan.md) | Plan (2026-10-29, not built): point Merge (backend and flat app), and the design-table sketcher catching up: origin welding and unheld snaps fixed, the line end resolved where the ghost shows it, inferred relationships, alignment guides, Merge in Select (steps V1-V5). Lives in DIDSA-CAD because the backend half is there. |
| [`landing-scope.md`](landing-scope.md) | The landing (first screen): launcher, QR server pairing, tips, 3D logo, demo models (scope, 2026-10-20; L1 to L3, the offline demo, built; servers and QR not). |
| [`live-sessions.md`](live-sessions.md) | Live sessions P2a, P2b and P4 (2026-11-18): Host Session and Join Session, how the hub is found, what an observer cannot do, the people (avatars, Go to / Follow / Gather) and the observer tools (drone cursor, own-view edits, Share / Ping / Look here / Raise hand, Reset my view), and **exact two-device steps** for each to check it by hand. Built and tested headless and against a real backend and hub; **not run on a headset**. |
| [`main-gd-split-audit.md`](main-gd-split-audit.md) | Live sessions P0 (2026-11-18): `main.gd` counted by what each line is for (viewing, Quest input, editing, files, shell), why the viewing lines cannot be lifted out as they are, and what a view-only (phone) build must not load. Read only; nothing built. |
| [`live-sessions-spikes.md`](live-sessions-spikes.md) | Live sessions P0 (2026-11-18): the voice (Opus add-on, D9) and Cardboard spikes as runnable plans for the owner's Quest and phone, with pass / fail numbers. **Voice run by the owner on 2026-11-24 (Quest 3, Galaxy S26 Ultra; V4 on the Quest and V9 still open); Cardboard not run.** The protocol is DIDSA-CAD `docs/live-sessions-scope.md`. |

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
| [`local-retraction-benchmark.md`](local-retraction-benchmark.md) | Headset benchmark: GDScript nearest-point retraction (no-go for wiring); M2: the reduced version-8 models, desktop numbers and what to run on the Quest. |

## Conventions

- Plans say what is built and what is not; when a phase lands, update its plan, then [`status.md`](status.md), then [`../CHANGELOG.md`](../CHANGELOG.md).
- State what was verified and how (headless, software render, real backend, headset). Never imply headset verification that did not happen.
- Docs that cite `docs/status.md` sections by name (for example "Milestone 3" or "Untested paths") mean the heading in [`status-history/status-log.md`](status-history/status-log.md).
