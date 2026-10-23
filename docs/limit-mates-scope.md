# Limit mates (M9): scope note

Status: **proposed, awaiting the owner's approval. Nothing is built.** Expands §3.6 of `gears-and-motion-plan.md`.

## What a user gets

- A **Limit** mate keeps a distance or an angle between two bounds instead of at one value. The part moves freely inside the range and stops at the ends.
- Examples: a rack that slides along its plate but stops at both ends (the gear-train demo's rack slides off its plate today); a hinge lid that opens 0° to 110°; a drawer with 0 to 200 mm travel.
- Limits are not drive targets. They only bound the motion, so they do not change what the Drive tool does inside the range.

## Mate data

- Two new mate types: `limit_distance` (references like `distance`) and `limit_angle` (references like `angle`).
- New optional fields `limit_min` and `limit_max` (mm, or degrees for the angle), either may be absent (one-sided). `limit_min <= limit_max` is validated; both absent is rejected.
- Files and API without limit mates are byte-identical to today. Old clients meeting a limit mate treat it as an unknown type (shown as unsupported, never silently solved as an equality).
- Native `.didsa` and the REST mate schema gain the two fields only on these types. The constraint-model version stays 5 for groups without limits.

## Solver (backend, `solve_group`)

1. Solve the group without the limit mates (as now).
2. Evaluate each limit. A violated limit becomes an equality at its nearest bound.
3. Re-solve with those equalities and re-check. At most 3 rounds. A limit that was active and whose wish pulls back inside the range is released next round.
4. Which limits are active is decided from the wish (the dragged target), not from the previous pose, so releasing is automatic.
5. The motion basis (`analyze_model`) is built with the active limits, so the drag direction stops at the bound.
6. Mate health: a limit counts as satisfied when inside the range, and "at limit" is reported as information, not as a conflict. A range that conflicts with other mates (min above the reachable range) reports like any other infeasible mate.
7. `export_constraint_model` (version 6 when a group has limits) exports each limit as a row with its min/max, value and Jacobian, like a distance or angle row. Clients run the same active-set rule locally every frame (project, clamp violated limits to their bound as equalities, re-project, at most 3 rounds, small hysteresis so the set does not chatter at the bound) and only ask the server on release, which stays authoritative. No per-frame round trips. Groups without limits keep version 5 and are byte-identical.

## Flat app (DIDSA-CAD, Flutter)

- Mate panel: Limit appears next to Distance and Angle with a Min and a Max field (either may be blank). The usual preview and Confirm.
- The mate list shows `Limit: 0 to 120 mm`. "At limit" gets a small badge while the part is held at an end.
- The drag keeps using the server solve for these groups (a short round trip, no local retraction), so the part stops at the bound, not past it.

## VR app (DIDSA-VR)

- Mates tool: a Limit entry with the same pick flow as Distance or Angle, then a Min/Max entry on the tablet's mate page (the existing numeric entry).
- Drag and Drive: the part stops at the bound. The existing "can't go further" message is reused, with "at limit" in the Drive readout.
- Wheel: nothing new on the ring (Limit sits under Mates).
- Demo: the gear train rack gets a travel limit at both ends.

## Tests

- Backend: schema round trip and old-file byte identity, validation, solver cases (inside range untouched, push past max stops at max, pull back releases, two limits on one group, limit plus coupler, limit conflicting with a fixed mate), constraint-model export returns `None`, mate health.
- Flat app: panel creates and edits a limit, list text, drag stops at bound (fake server), widget tests.
- VR: headless unit tests with a fake server, a user-session style test for the rack (drag past each end), and a live e2e added to `tests/e2e_ci_list.txt`.
- Gate as for M6 to M8: both headless suites, analyzers, render gate where UI changed, live e2e against a local backend.

## Decisions (settled by the owner)

1. Smooth motion is a requirement: limits are exported to the clients and handled locally each frame (above); the server confirms on release.
2. Angle limits use the signed angle about the hinge axis, -180° to 180°.
3. The limit is added to the shipped gear-train demo file.

## Not verified / risks

- The inequality handling is an active-set heuristic. Ranges where two limits fight each other or a limit sits on a coupler's driven side may need more rounds than 3 and would report infeasible.
- Headless tests cannot judge how the stop feels in the headset.
