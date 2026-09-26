# Headless tests

Godot scripts that exercise the interaction code without a headset, GPU or
backend. They print `SMOKE ...` lines rather than pass/fail, so compare
against the expected values below. `run_all.sh` runs the lot and fails on any
script or parse error.

```
GODOT=/path/to/godot tests/run_all.sh        # from the project root
"$GODOT" --headless --path . --script res://tests/grab_and_scale.gd    # one test
```

**Safety:** any test that instantiates `scenes/main.tscn` must first set
`main.secrets_file_path` to a nonexistent file (as `tablet_scene.gd` does),
otherwise `main.gd` reads the real `secrets.cfg` and POSTs to the configured
backend. Also `await process_frame` after `add_child(main)` before looking up
its nodes (its `_ready` is deferred).

**What headless can't do:** fake a real grip press (call the routine directly,
e.g. `two_hand_model._update_one_hand(hand, pos)`), render for real, or judge
feel. Say what you couldn't verify.

| Test | Expect |
|---|---|
| `steadiness_filter.gd` | held-still shake ~2.0 mm (Off) falling to ~0.64 / 0.40 / 0.28 mm (Light/Medium/Strong); lag on a slow 2 cm/s move stays ~1 mm |
| `sensitivity.gd` | one-hand drag gain x1.00 to 0.6 m radius, x2.5 at 1.5 m, x5 at 3 m, capped x15; nudge 0.03 m/s at 5 cm, 0.60 at 1 m, 3.0 at 5 m, 8.0 at 30 m |
| `two_hand_rotation.gd` | model Y axis after yaw then tilt is ~(0, 0.7071, 0.7071) and matches the "expected" line (an old bug gave (-0.71, 0.5, 0.5)) |
| `grab_and_scale.gd` | every boolean line `true`; grab-point distance `0.0`; both scale lines `x1.331` |
| `tablet_scene.gd` | tablet stays closed when only looked at or shot 15 cm off; opens on the bullseye; second pull within 0.4 s ignored; Files lists and loads the generated `.glb` (1 part); Fit gives diag/2 = 0.5; modes toggle off; Strong sets cutoff 0.8; shadows/resolution/MSAA levers apply; panel renders only while open |
| `gpu_timing.gd` | *needs a GPU + window, not `--headless`.* On the dev laptop's RTX 4080 the scene at 4128x2208 was ~1.4 ms GPU (0.4 ms with shadows and MSAA off) |
