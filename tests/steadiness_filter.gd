extends SceneTree
## Simulated 9 Hz / 1.5 mm hand tremor through the One Euro filter at each steadiness level: held-still shake vs lag on a slow and a fast move.
## Run: "$GODOT" --headless --path . --script res://tests/steadiness_filter.gd  (see tests/README.md)
const OneEuro := preload("res://scripts/one_euro.gd")
const NAMES := ["Off", "Light", "Medium", "Strong"]
const CUT := [0.0, 3.0, 1.5, 0.8]

func tremor(t: float, rng: RandomNumberGenerator) -> Vector3:
	# ~1.5 mm hand tremor at 9 Hz plus 0.5 mm broadband noise, on all axes
	return Vector3(sin(t * TAU * 9.0), sin(t * TAU * 9.0 + 2.0), sin(t * TAU * 9.0 + 4.0)) * 0.0015 \
		+ Vector3(rng.randfn(0, 0.0005), rng.randfn(0, 0.0005), rng.randfn(0, 0.0005))

func rms(a: Array) -> float:
	var s := 0.0
	for v in a: s += v * v
	return sqrt(s / a.size())

func _initialize() -> void:
	var dt := 1.0 / 90.0
	print("SMOKE level    | held-still shake (mm rms) | lag on slow 2 cm/s move (mm) | lag on fast 1 m/s move (mm)")
	for level in 4:
		var rng := RandomNumberGenerator.new(); rng.seed = 7
		var f := OneEuro.new()
		f.min_cutoff = maxf(CUT[level], 0.01); f.beta = 10.0
		var t := 0.0
		var pos := Vector3.ZERO
		# 1) held still for 3 s
		var errs := []
		for i in 270:
			t += dt
			var raw := tremor(t, rng)
			var out := raw if level == 0 else f.filter(raw, dt)
			if i > 90: errs.append(out.length())   # after settling
		var shake := rms(errs) * 1000.0
		# 2) slow deliberate move: 2 cm/s for 2 s (4 cm), steady-state lag = raw - out
		f.reset(Vector3.ZERO)
		var slow_lags := []
		for i in 180:
			t += dt
			var truth := Vector3(0.02 * (i * dt), 0, 0)
			var raw := truth + tremor(t, rng)
			var out := raw if level == 0 else f.filter(raw, dt)
			if i > 90: slow_lags.append((truth - out).x)
		var slow_lag := 0.0
		for v in slow_lags: slow_lag += v
		slow_lag = slow_lag / slow_lags.size() * 1000.0
		# 3) fast move: 1 m/s for 0.5 s
		f.reset(Vector3.ZERO)
		var fast_lags := []
		for i in 45:
			t += dt
			var truth := Vector3(1.0 * (i * dt), 0, 0)
			var raw := truth + tremor(t, rng)
			var out := raw if level == 0 else f.filter(raw, dt)
			if i > 20: fast_lags.append((truth - out).x)
		var fast_lag := 0.0
		for v in fast_lags: fast_lag += v
		fast_lag = fast_lag / fast_lags.size() * 1000.0
		print("SMOKE %-8s | %25.2f | %28.1f | %27.1f" % [NAMES[level], shake, slow_lag, fast_lag])

	# A held single part (grip) goes through the same filter now (previously
	# only whole-model moves did — see controller.gd's _update_held_part()).
	# Same tremor, fed through the real grab path this time, not the raw filter.
	print("SMOKE --- held-part shake (grip), same 9 Hz tremor, through controller.gd for real")
	var world := Node3D.new(); root.add_child(world)
	var origin := XROrigin3D.new(); world.add_child(origin)
	var l := XRController3D.new(); l.set_script(load("res://scripts/controller.gd")); origin.add_child(l)
	var assembly := Node3D.new(); assembly.add_to_group("assembly_root"); world.add_child(assembly)
	var part := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = Vector3(0.1, 0.1, 0.1)
	part.mesh = bm; assembly.add_child(part); part.position = Vector3(0, 1, -1); part.add_to_group("grabbable_parts")
	await process_frame

	for level in [0, 2]: # Off vs Medium
		var rng := RandomNumberGenerator.new(); rng.seed = 7
		l.position = Vector3(0, 1, -1)
		part.position = Vector3(0, 1, -1) # reset: the previous level's run leaves it at its last (unfiltered, for Off) tremor sample
		l.set_steadiness(level)
		l._try_grab()
		var t := 0.0
		var errs: Array = []
		for i in 270:
			t += dt
			l.position = Vector3(0, 1, -1) + tremor(t, rng)
			l._update_held_part(dt)
			if i > 90: errs.append(part.global_position.distance_to(Vector3(0, 1, -1)))
		l._try_release()
		print("SMOKE %-8s held-part shake (mm rms): %.2f" % [NAMES[level], rms(errs) * 1000.0])
	quit()
