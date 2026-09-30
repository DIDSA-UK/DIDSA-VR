# Constrained-drag rollout — VR side

The authoritative plan lives in the CAD repo (attach **DIDSA-UK/DIDSA-CAD** to any session that works from this file):

- `docs/constrained-drag-implementation-plan.md` — contract of record (§3), session briefs S0–S13, tracker (§7)
- `docs/constrained-drag-investigation.md` — evidence and design rationale
- `docs/constrained-drag-investigation/prototypes/` — numpy reference (`geo.py`: `project_motion`, `weighted_basis`, screw integration; `f_group_real.py`: group model)
- `docs/motion/projector-spec.md` + `docs/motion/vectors.json` — created by CAD session **S4**; the golden vectors this repo's projector must pass

This file is a **short copy for orientation only**; if it disagrees with the CAD plan, the CAD plan wins.

## Baseline (2026-09-30)

VR `main` 8933f53 has the smooth-drag round (`scripts/mates_tool.gd`: `constrain_drag`, `project_motion`, `weighted_basis`, `_sync_with_motion_model`,
150 ms re-anchor, 100 mm lever arm) talking to CAD `main` 003254a's single-occurrence `POST …/occurrences/{oid}/mate-motion`
(`transform`, `dof`, `free_twists`). Known problems (measured, see the investigation): frozen-peer solve under-reports DOF (a part can read 0 while its group is free)
and blocks chains; additive first-order integration + fixed 100 mm lever arm leave up to ~5 mm violation / 2 mm pops on curved mates under large wishes.

## Which sessions touch this repo

| Session | Repo | What |
|---|---|---|
| S5 | **VR** | consume the group-aware contract; projector v2 in GDScript (screw integration, lever arm = mesh bounding radius, blended re-anchors, acceptance test, rank-change hysteresis); persist via `commit:true`; delete `_sync_with_solve` / `_motion_supported`; stop reading the temporary v0 alias fields |
| S9 (VR half) | **VR** | doc updates (`docs/backend-api-notes.md`, `docs/status.md`) |

S5 needs CAD **S3** (endpoint + commit) and **S4** (spec + vectors) merged first. Do not start it earlier.

## Contract of record (copy of plan §3 — verify against the CAD plan before coding)

`POST /document/parts/{part_id}/occurrences/{occurrence_id}/mate-motion` — `occurrence_id` is the **grabbed** occurrence.

```jsonc
// request
{ "transform": { … RigidTransform … } | null,  // wanted pose of the grabbed occurrence (null = stored pose)
  "lever_arm": 41.2,                           // optional, mm; default = grabbed occurrence's bounding radius
  "commit": false }                            // true = also persist the solved group atomically (one undo unit)
// response
{ "converged": true,
  "dof": 5,                                    // GROUP dof (rank-based)
  "grounded": true,
  "members": [ { "occurrence_id": "occ-B", "transform": { … }, "mobility": 3 }, … ],   // order = basis column order
  "basis": [ [ /* 6·k floats, member order, [dx dy dz rx ry rz]×k, orthonormal in the weighted metric */ ], … ],
  "chart": { "kind": "se3_owner_frame", "lever_arm": 41.2 },
  "quality": { "residual_inf": 3e-10, "sigma_min": 0.31, "sigma_gap": 40.0, "max_step": 12.0, "jump": 0.7 },
  "diagnostics": { "solve_ms": 3.4 } }
```
Nothing is stored unless `commit`; fixed grabbed occurrence → 422; `converged:false` → no basis (hold the last pose, never treat as "all free").

## VR session rules

- One session, one branch, one PR; stop at the brief's exit criteria; tick the tracker row in the **CAD** plan and add a dated `docs/status.md` entry here.
- Tests: `tests/run_all.sh` (Godot headless); projector golden-vector test must load `vectors.json` from the CAD repo (copy it into `tests/fixtures/` and record the CAD commit); `tests/e2e_mates_motion.gd` runs against a real backend (see the "How this has been worked on" section of `docs/status.md` for standing one up with micromamba). If Godot or the backend can't be run, say so and list what was verified by reading only.
- Move *all* group members every frame (followers included); persist all moved members with one `commit:true` on release; one undo entry.
