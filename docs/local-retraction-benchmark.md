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

## Decision rule

Wire the local retraction into the VR drag only for the member counts that pass, on the headset, with the app warm (3 minutes):

| on-headset p95 of one `frame()` | verdict |
|---|---|
| <= 1.5 ms (about 13 % of a 90 Hz frame) and max <= 4 ms | ship for this k (`MAX_MEMBERS` = that k, behind an app setting, default off first) |
| 1.5 - 3 ms | not worth it: keep the projector; revisit with a cheaper solver (sparse rows, fewer iterations) |
| > 3 ms | no |

Whatever the verdict, VR stays correct: the projector is the fallback and the only path above `MAX_MEMBERS` (= 3).

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
