extends Node
## On-headset (or any device) timing of the GDScript local retraction: scenes/bench_local_retraction.tscn. ONE call of every case per rendered
## frame (so it shares the frame with the real render loop and the thermal state is realistic), a summary printed every REPORT_EVERY seconds
## (`adb logcat -s godot` on a Quest; the console elsewhere) and shown on a Label3D in front of you. Runs DURATION seconds.
## One entry per frame, round-robin (k=1, k=2, k=3, the projector; `--all` adds the k=5 and k=8 rows, which are slow and drop the frame rate).
## Options (Godot user args, after `--`): --duration=180  --report=15  --all
## Not part of the app: see docs/local-retraction-benchmark.md.

const Bench := preload("res://scripts/local_retraction_bench.gd")

var duration := 180.0
var report_every := 15.0
var bench
var elapsed := 0.0
var since_report := 0.0
var include_large := false
var warm_frames := 120
var frame_ms := 0.0
var label: Label3D


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--duration="):
			duration = float(a.substr(11))
		elif a.begins_with("--report="):
			report_every = float(a.substr(9))
		elif a == "--all":
			include_large = true
	# OpenXR when a headset is there (the same start-up as main.gd); otherwise a flat window
	var xr := XRServer.find_interface("OpenXR")
	if xr != null and xr.initialize():
		get_viewport().use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var cam := XRCamera3D.new() if get_viewport().use_xr else Camera3D.new()
	var origin := XROrigin3D.new()
	add_child(origin)
	origin.add_child(cam)
	cam.current = true
	label = Label3D.new()
	label.font_size = 28
	label.pixel_size = 0.0012
	label.position = Vector3(0, 1.5, -1.6)
	label.modulate = Color(1, 1, 0.6)
	add_child(label)
	bench = Bench.new()
	if not bench.setup(include_large):
		label.text = "benchmark setup failed (fixture missing from the export? add *.json to the export filter)"
		print("SMOKE BENCH FAILED: setup (is tests/fixtures/motion_vectors.json in the export?)")
		set_process(false)
		return
	print("SMOKE BENCH start: ", Engine.get_version_info()["string"], " on ", OS.get_name(), " ", OS.get_processor_name(), " xr=", get_viewport().use_xr, " duration=", duration, " s")
	label.text = "warming up..."


func _process(delta: float) -> void:
	bench.run_next()
	frame_ms = maxf(frame_ms * 0.95, delta * 1000.0)
	if warm_frames > 0:
		warm_frames -= 1
		if warm_frames == 0:
			bench.clear()
		return
	elapsed += delta
	since_report += delta
	if since_report >= report_every:
		since_report = 0.0
		var lines: Array = bench.report("t=%03.0fs " % elapsed)
		for l in lines:
			print(l)
		print("SMOKE BENCH frame interval now ~", snappedf(delta * 1000.0, 0.01), " ms (", snappedf(1.0 / maxf(delta, 1e-6), 0.1), " fps)")
		label.text = "local retraction, GDScript (%d s)\n" % int(elapsed) + "\n".join(lines.map(func(l): return str(l).replace("SMOKE BENCH ", "")))
	if elapsed >= duration:
		for l in bench.report("FINAL "):
			print(l)
		print("SMOKE BENCH done")
		set_process(false)
		label.text += "\nDONE"
		if DisplayServer.get_name() == "headless":
			get_tree().quit()
