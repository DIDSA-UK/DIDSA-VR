# Local nearest-point retraction: is the GDScript port cheap enough for the headset?

Context: DIDSA-CAD `docs/motion/projector-spec.md` §4b (F1b) lets a client solve the mates itself every frame instead of only
projecting along the linearised free motion. The flat app (Dart) does this by default; VR still uses the projector
(`scripts/motion/free_motion_projector.gd`). `scripts/motion/local_retraction.gd` is a line-for-line port (checked against the same
golden vectors to 1e-9 in `tests/local_retraction.gd`). It is **not wired into `mates_tool.gd`**: whether it should be depends on the
cost on the Quest, which only a headset can tell. This is that measurement.

## Numbers so far (desktop, NOT the headset)

Godot 4.7.2 headless on an x86 server (Xeon 2.1 GHz, 4 threads), 2000 warm calls per case, one full `frame()` per call (3-8 trust-region
iterations + polish + acceptance residual, analytic Jacobians):

| case | members | residual rows | mean | p95 | max |
|---|---|---|---|---|---|
| bolt in a fixed plate | 1 | 10 | 1.0 ms | 1.1 ms | 1.7 ms |
| floating bolt + plate | 2 | 10 | 0.95 ms | 1.05 ms | 1.7 ms |
| row of 3 boxes (synthetic) | 3 | ~20 | 2.6 ms | 2.9 ms | 4.8 ms |
| row of 5 boxes (above the limit) | 5 | 36 | 8.0 ms | 8.7 ms | 14 ms |
| row of 8 boxes (above the limit) | 8 | 60 | 25 ms | 28 ms | 45 ms |
| *the projector's frame (what VR pays today)* | 3 | 5 basis rows | 0.10 ms | 0.13 ms | 0.24 ms |

For comparison the Dart port costs 0.07 ms (k=1-2), 0.9 ms (k=5), 3 ms (k=8): GDScript is ~15x slower. A 90 Hz frame is 11.1 ms.
**Expectation, not a measurement:** a Quest 3's mobile CPU runs GDScript no faster than this Xeon, so the Quest figures should be
the same or worse. On those numbers k=1-2 would eat ~10 % of the frame and k=3 ~25 % or more.

## Result on the headset (Quest 3, 2 Oct 2026): NO-GO for the GDScript solver

Debug APK of `scenes/bench_local_retraction.tscn`, flat (non-XR) Android build run as a 2D app on a Quest 3 (Adreno 740, Godot 4.7.2,
Vulkan Forward Mobile), headset worn for the full 180 s, one `frame()` per rendered frame in round-robin. FINAL rows (microseconds):

| case | n | mean | p50 | p95 | p99 | max |
|---|---|---|---|---|---|---|
| k=1 bolt in plate | 3377 | 2545 | 2485 | **3112** | 3447 | 6397 |
| k=2 floating bolt | 3376 | 2533 | 2480 | **3096** | 3414 | 5929 |
| k=3 row of 3 boxes | 3376 | 6970 | 6966 | **7794** | 8317 | 13447 |
| *projector frame (today)* | 3376 | 370 | 343 | 555 | 699 | 3003 |

- Against the decision rule (p95 <= 1.5 ms ship, 1.5-3 ms not worth it, > 3 ms no): **k=1-2 are at ~3.1 ms (no), k=3 at ~7.8 ms with a
  13 ms worst case (no, more than a whole 90 Hz frame).**
- The Quest ran this ~2.5x slower than the desktop Xeon for the solver (1.0 -> 2.5 ms, 2.6 -> 7.0 ms) and ~3.7x slower for the projector
  (0.10 -> 0.37 ms). The solver costs ~7x the projector at k=1-2 and ~19x at k=3.
- No thermal drift: the k=1 mean moved 2409 -> 2545 us (+5 %) over three minutes.
- The reported frame interval was 11.1 ms (90 fps) at the start and end and 13.9 ms (72 fps) from about 30 s to 150 s; I cannot say from this
  run whether that was the system's refresh/thermal management or this app, so it is an observation, not a finding.
- Caveat: a flat 2D app, so the stereo render load of a real VR session is absent; if anything these numbers are kind to the headset.

**Can it be made cheap enough?** Not by tuning. Two iterations instead of three converge on every scene for 1-3 mm hand steps (the hinge 28/30 at
3 mm), which saves only about a quarter of the cost (the polish step, the acceptance residual and the interpreter overhead remain), so
~3.1 ms -> ~2.3 ms at best against a 1.5 ms target; k=3 would still be ~5 ms. Reaching the budget would need a different implementation
(native code / GDExtension, or a threaded solve one frame late), which is not justified for a polish feature.

**Decision:** keep the projector in VR. The solver port stays in the repository, tested against the golden vectors and NOT wired into
`mates_tool.gd`; the backend's anchors are already the weighted-nearest point (DIDSA-CAD F1b), which removes most of the curved-mate
disagreement VR would see between anchors. Revisit only if VR shows a real curved-mate problem in use.

## Decision rule

Wire the local retraction into the VR drag only for the member counts that pass, on the headset, with the app warm (3 minutes):

| on-headset p95 of one `frame()` | verdict |
|---|---|
| <= 1.5 ms (about 13 % of a 90 Hz frame) and max <= 4 ms | ship for this k (`MAX_MEMBERS` = that k, behind an app setting, default off first) |
| 1.5 - 3 ms | not worth it: keep the projector; revisit with a cheaper solver (sparse rows, fewer iterations) |
| > 3 ms | no |

Whatever the verdict, VR stays correct: the projector is the fallback and the only path above `MAX_MEMBERS` (= 3; from version 8 these are rigid-set leads, see the M2 section at the end).

## Run it on the headset (about 20 minutes)

1. **Desktop first** (2 minutes), to confirm the port and get the reference: `GODOT=/path/to/godot-4.7.2 tests/run_all.sh` (all clean) or just
   `"$GODOT" --headless --path . --script res://tests/local_retraction.gd` (expect `SMOKE PASSED`) and
   `"$GODOT" --headless --path . --script res://tests/bench_local_retraction.gd` (the table above, on your machine).
2. **Build a benchmark APK.** In the editor: Project Settings -> Application -> Run -> *Main Scene* = `res://scenes/bench_local_retraction.tscn`
   (**revert it afterwards**). Project -> Export -> Android (as README section 4: OpenXR on, hand tracking off). In the preset's *Resources*
   tab add `*.json` to "Filters to export non-resource files" (the benchmark reads `tests/fixtures/motion_vectors.json`). Export a **debug APK**.
3. `adb install -r bench.apk`. Open a second terminal: `adb logcat -c && adb logcat -s godot`.
4. Put the headset on and launch it. A yellow text panel floats in front of you; the same lines go to logcat every 15 s. It runs **180 s**
   (the first 2 s are warm-up and are discarded) and prints `FINAL` lines and `SMOKE BENCH done`. Keep it running the whole time: the
   XR2 chip throttles when warm, so the late `t=1xx s` lines are the honest ones. It does one `frame()` per rendered frame in round-robin
   (k=1, k=2, k=3, projector), so it also shows what that does to the frame rate (`frame interval now ~ ... ms` lines).
   Add `--all` to the launch arguments only if you also want the k=5/k=8 rows; they make the app run at a few fps.
5. Send me (or paste into `docs/status.md`) the `FINAL` lines and the headset model / firmware. The row for each k against the table above is
   the verdict.
6. Optional second look, once someone wires the solver into `mates_tool.gd` behind a setting: the existing `stat_motion` counters
   (`projection_us_total`, `projection_us_max`) in a real constrained drag, compared with the projector alone.

## What this does NOT settle

The drag on the headset also depends on network round trips (anchors), hand tracking and rendering; this isolates only the solver's CPU
cost. A GDScript solver could be made cheaper (sparse rows, reusing the factorisation, fewer iterations on small wishes): not attempted
because on the desktop numbers the unoptimised port is already ~10x the projector for k=1-2.

## Addendum, 23 Oct: the gear train (limit mates, M9)

The VR drag was going to run the nearest-point solve per frame for groups with a limit mate. Measured on the gear train demo's real constraint model (pinion, gear, rack, crank: 4 members, 42 rows, `Local.try_parse(model, 8)`, a desktop, headless): **11.7 ms per `frame()` with no limit held and 69 ms with one held** (the active-set rounds run the retraction two to four times). Far over a headset frame (11 ms) before the Quest's slower CPU is counted. So VR does not run it for such groups: the drag keeps the limit-blind projection and stops it at the limit with a bisection on the limit values (`MatesTool._limit_stop`, 0.8 ms for the same four members, only while a limit is violated). See `limit-mates-scope.md`.

## M2 (13 Nov 2026): the reduced models (constraint model version 8), and what to run on the headset

Context: DIDSA-CAD `docs/mates-storage-sessions-plan-2026-11-12.md`, M1 and M2. Since M1 the backend merges the members its mates lock together
into one body per rigid set, and the constraint model it exports (version 8) has one member per set (the "lead"), the rest as constant
offsets (`rigid_sets`). A 10-part chain is now one lead with no rows (floating) or 16 rows (held to the ground), instead of 10 members and 144
rows. `local_retraction.gd` reads version 8 (the set metric, the followers posed from their leads: `has_sets()`, `follower_ids()`,
`expand_followers()`, and `frame()` returns `followers` / `local_followers`); all `local-rigid-*` vectors pass to 1e-9
(`tests/local_retraction.gd`). `tests/fixtures/m0_reduced_models.json` holds the exported models of the 22 M0 scene variants.

**Desktop, NOT the headset** (Godot 4.7.2 headless, Xeon 2.1 GHz, 4 threads, 1000 warm calls per case, one full `frame()` per call; run
`"$GODOT" --headless --path . --script res://tests/bench_local_retraction.gd -- --calls=1000`):

| case | leads (followers) | rows | mean | p95 | max |
|---|---|---|---|---|---|
| k=1 bolt in plate (October's row) | 1 | 10 | 1.05 ms | 1.53 ms | 3.0 ms |
| k=3 row of 3 boxes (October's row) | 3 | ~20 | 2.86 ms | 4.16 ms | 7.9 ms |
| **v8 chain-10 floating** | 1 (9) | 0 | **0.43 ms** | **0.65 ms** | 2.5 ms |
| **v8 chain-10 fixed** (base fixed) | 1 (8) | 16 | 2.22 ms | 3.22 ms | 5.9 ms |
| **v8 frame-10 fixed** | 1 (8) | 12 | 1.72 ms | 2.46 ms | 5.0 ms |
| v8 linkage fixed (`--all`) | 3 (20) | 40 | 11.2 ms | 16.1 ms | 34 ms |
| v8 linkage floating (`--all`) | 4 (20) | 40 | 14.8 ms | 21.6 ms | 46 ms |
| v8 chain-5-bolts fixed (`--all`) | 7 (3) | 76 | 68 ms | 99 ms | 226 ms |
| *the projector's frame (what VR pays today)* | 3 | 5 basis rows | 0.12 ms | 0.19 ms | 0.35 ms |

How to read it: the followers add little (a lead with nine followers and no rows costs 0.43 ms: the set metric is a sum over the followers, evaluated
in closed form: `projector-spec.md` §4b "Clients"; the literal 6x6 products measured 1.93 ms for the same case), the rows dominate (16 rows:
five times more). In October the Quest ran this solver about **2.5 times slower than this desktop** and measured k=1 at 3.1 ms p95, a no-go against the
rule below. **Expectation, not a measurement:** the same ratio puts the rows-free case (a floating group, however many parts) at about 1.6 ms p95 on the Quest,
just over the rule, and every case with rows (a group held to the ground: 12 to 16 rows, 6 to 8 ms) well over it. `MAX_MEMBERS` (3) and `MAX_ROWS` (64) are
not raised: the solve is not run per frame in the app, so they gate nothing today, and these numbers give no case for loosening them.

**Whether to run the GDScript solve per frame on the headset is the owner's decision after a Quest run. Nothing in the app enables it.**
The limit stop (`MatesTool._limit_stop`) reads a version-8 model since M2 (a group with a limit and a set had no stop before: `tests/limit_mates_v8.gd`);
it does not run the solve (about 0.5 ms for a lead and a follower).

### What to run (about 20 minutes, the same steps as above with one change)

1. Desktop first: `GODOT=/path/to/godot-4.7.2 tests/run_all.sh` (or `"$GODOT" --headless --path . --script res://tests/local_retraction.gd`, expect `SMOKE PASSED`).
2. Build the benchmark APK exactly as under "Run it on the headset" (Main Scene = `res://scenes/bench_local_retraction.tscn`, reverted afterwards; Android preset; the
   *Resources* filter `*.json` in "Filters to export non-resource files" now has to carry **two** files: `tests/fixtures/motion_vectors.json` and `tests/fixtures/m0_reduced_models.json`; a
   debug APK). If the label says "benchmark setup failed", the second file is missing from the export.
3. `adb install -r bench.apk`, `adb logcat -c && adb logcat -s godot`, put the headset on and leave it running the full **180 s** (the late `t=1xx s` lines are the honest ones: the chip
   throttles). It does one `frame()` per rendered frame in round-robin over seven entries (k=1, k=2, k=3, **v8 chain-10 floating, v8 chain-10 fixed, v8 frame-10 fixed**, the projector), so each is
   sampled every seventh frame. Do **not** add `--all` (it adds the linkage and the bolted chain, which take 10 to 70 ms and make the app crawl).
4. Send the `FINAL` lines and the headset model / firmware. The rows that matter are the three `v8 ...` ones; the rest are the October rows for comparison.
5. The rule (unchanged): **p95 at most 1.5 ms and max at most 4 ms** for a case = it may be wired for groups of that shape, behind an app setting, default off first; 1.5 to 3 ms = not worth it; above 3 ms = no.
   Likely outcome by the extrapolation above: `v8 chain-10 floating` borderline, the other two a no.
6. If a case passes, the wiring is a separate change (where `mates_tool.gd` shows the frame: `_frame_poses`), to be made on the owner's say, with `expand_followers()` for the followers.

Not settled by this: the Quest figures for the reduced models (none were measured), the stereo render load (the October run was a flat 2D app), and the network round trips.
