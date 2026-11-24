extends SceneTree
## The P0 Cardboard spike scene (scripts/spikes/cardboard_spike.gd, docs/live-sessions-spikes.md "Spike C") runs headless: it loads
## the demo rocket through the app's glb path, walks its steps and reports frame statistics. Frame rates here mean nothing (no GPU, no
## phone); the test guards the code, not the numbers. Also checks FrameStats' arithmetic.

const FrameStats := preload("res://scripts/spikes/frame_stats.gd")


func _initialize() -> void:
	var s := FrameStats.new()
	for i in 95:
		s.add(0.010)
	for i in 4:
		s.add(0.020)
	s.add(0.050)
	var sum := s.summary()
	print("SMOKE frame stats: 100 frames: ", sum["frames"] == 100)
	print("SMOKE frame stats: p95 is the 95th of 100: ", is_equal_approx(sum["p95_ms"], 10.0))
	print("SMOKE frame stats: worst 50 ms, 1% over 33 ms: ", is_equal_approx(sum["worst_ms"], 50.0) and is_equal_approx(sum["over_33ms_pct"], 1.0))
	print("SMOKE frame stats: passes the 60 fps bar: ", FrameStats.passes_60(sum))
	s.add(0.050)
	print("SMOKE frame stats: 2 of 101 over 33 ms fails it: ", not FrameStats.passes_60(s.summary()))
	print("SMOKE frame stats: empty is not a pass: ", not FrameStats.passes_60(FrameStats.new().summary()))

	var spike: Node3D = load("res://scenes/spikes/cardboard_spike.tscn").instantiate()
	root.add_child(spike)
	await process_frame
	print("SMOKE spike: setup screen shown: ", spike.setup_ui.visible)
	spike.load_demo("light")
	print("SMOKE spike: demo rocket loaded through the glb path: ", spike.models.has("light") and str(spike.models["light"]["summary"]).contains("parts"))
	spike.start_run()
	await process_frame
	print("SMOKE spike: first step is C2: ", spike.step_index == 0 and spike.last_report.begins_with("step C2"))
	print("SMOKE spike: the model is in the scene: ", spike.assembly_root.get_child_count() == 1)
	print("SMOKE spike: own stereo by default: two eye viewports shown, the main viewport's 3D off, use_xr off: ",
		spike.own_stereo and spike._eyes.size() == 2 and spike._stereo_layer.visible and spike.get_viewport().disable_3d and not spike.get_viewport().use_xr)
	var left: Camera3D = spike._eyes[0]["camera"]
	var right: Camera3D = spike._eyes[1]["camera"]
	var head: Transform3D = spike.xr_camera.global_transform
	spike._follow_head() # on a device frame_pre_draw does this; headless never draws
	var gap := right.global_position.distance_to(left.global_position)
	print("SMOKE spike: the eye cameras sit the eye spacing apart about the head: ", is_equal_approx(gap, spike.lens["iod"] * 0.01)
		and (left.global_position + right.global_position).distance_to(head.origin * 2.0) < 0.0001)
	print("SMOKE spike: the eye frustums lean apart, mirrored (set_for_hmd): ",
		left.frustum_offset.x == -right.frustum_offset.x and left.frustum_offset.x != 0.0 and is_equal_approx(left.size, right.size))
	var vp_size: Vector2i = (spike._eyes[0]["viewport"] as SubViewport).size
	var screen: Vector2i = spike._screen_size()
	print("SMOKE spike: each eye renders half the screen times the oversample: ", vp_size == Vector2i(int(screen.x * 0.5 * 1.5), int(screen.y * 1.5)))
	for i in 5:
		await process_frame
	spike.report()
	print("SMOKE spike: report has the step and frame stats: ", spike.last_report.begins_with("C2 ") and spike.last_report.contains("fps"))
	while spike.step_index != 5:
		spike.next_step()
	print("SMOKE spike: C8 is magic window (the window camera is current): ", spike.window_camera.current)
	print("SMOKE spike: magic window hides the eyes and turns the main viewport's 3D back on: ", not spike._stereo_layer.visible and not spike.get_viewport().disable_3d)
	spike.next_step()
	print("SMOKE spike: C5 drift step: ", spike.STEPS[spike.step_index]["id"] == "C5")
	spike.next_step()
	print("SMOKE spike: after the last step the setup screen is back: ", spike.step_index == -1 and spike.setup_ui.visible)
	print("SMOKE spike: the setup screen lists the run's results: ", spike._setup_text.text.contains("RESULTS") and spike._setup_text.text.contains("C2 "))
	quit()
