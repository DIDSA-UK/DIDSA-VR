# DIDSA VR documentation

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
