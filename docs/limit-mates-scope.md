# Limit mates (M9): scope note

Status: **built on 2026-10-23 (owner's go, with the three decisions below); see "As built" at the end for where the code differs from this note.** Expands §3.6 of `gears-and-motion-plan.md`.

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

## As built (2026-10-23)

What is described above is what the code does, except:

- **No hysteresis, no state.** The clients rebuild the held set on every frame (retract with none held, hold what is violated, retract again from the same start and wish), so a limit is released the moment the wish stops pushing past it and nothing can chatter. The earlier plan for a hysteresis band was dropped.
- **A converged result with a limit held is accepted without the distance guard.** The limit-blind projector (the guard's fallback) would show the part going through the stop, so comparing the answer with it would reject exactly the right answer.
- **Version 6 is a superset** of 3 to 5 (a group with a limit may also hold couplers, with their `anchor`s, and pairs).
- **The sign of a limit_distance** is `(P_a - P_b) . N` with N the unit normal of B's plane (A's when B has none), references never swapped: the number is the same however a solve orients the pair. The mate list and the panels show "Now 20 mm" so a range is typed against where the parts are. A limit_angle is the signed angle from A's direction to B's about the hinge, the hinge being a concentric mate between the same two parts (as for an Angle; without one the backend answers 422 `limit_angle_needs_hinge`).
- **Creating a limit never solves** (`?solve=` is ignored): it places nothing. A part that is already outside the range is brought to the nearest bound by the next solve or drag.
- **VR does not run the nearest-point solve per frame.** The GDScript port (`local_retraction.gd`, 71 golden vectors to 1e-9 including every limit case) is correct but, on the gear train demo (four members, 42 rows), costs 12 ms a frame without a limit held and 69 ms with one, on a desktop; a headset cannot spare that. So the VR drag keeps the limit-blind projection and stops it where a limit ends: the displacement from the anchor's poses (a screw per member, the projector's own chart) is scaled back by the largest fraction that keeps every limit inside its range (16 bisection steps on the limit values, no derivatives; 0.8 ms for the four-member train on a desktop). Exact for a rack or a hinge (one free motion); a diagonal drag into a stop slows down uniformly instead of sliding along it as the flat app's retraction does.
- **The Drive tool's wish does not wind up past a stop.** Its wish accumulates without bound (a hand that never lets go); held on past a stop for a second or two it ran half a turn beyond, where a pose reads as being on the other side (the rack jumped to its far end). While a limit holds the part, the wish stays one step past the displayed pose; reversing the stick moves it back on the first frame.
- **Hand drags** past a stop have the same half-turn wrap if the hand goes more than half a turn beyond it; not handled.
- **Not done:** the angle limit in the flat app's and VR's UI was only unit-tested (the live backend e2e is the distance limit on the demo's rack and the hinge in `test_limit_mates.py`); no "at limit" cue other than the flat app's "Stopped at its limit." on release, VR's release message and the Drive readout's "at its limit"; nothing seen on a headset.

