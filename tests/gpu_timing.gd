extends SceneTree
## NEEDS A GPU AND A WINDOW (not --headless): renders main.tscn in a 4128x2208 SubViewport and prints GPU ms with shadows/MSAA on and off.
## Run: "$GODOT" --headless --path . --script res://tests/gpu_timing.gd  (drop --headless, add --rendering-driver vulkan --disable-vsync)
# Render the real scene at roughly headset resolution (both eyes' pixels) and time it.
var sv: SubViewport
var main
var results := []

func frames(n: int) -> void:
	for i in n: await process_frame

func sample(label: String) -> void:
	await frames(20)
	var rid := sv.get_viewport_rid()
	var gpu := 0.0; var cpu := 0.0; var wall := 0.0
	var n := 120
	var t0 := Time.get_ticks_usec()
	for i in n:
		await process_frame
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(rid)
	wall = (Time.get_ticks_usec() - t0) / 1000.0 / n
	print("SMOKE %-34s gpu %5.2f ms   cpu-render %5.2f ms   wall/frame %5.2f ms (%3.0f fps)" % [label, gpu / n, cpu / n, wall, 1000.0 / wall])

func _initialize() -> void:
	Engine.max_fps = 0
	sv = SubViewport.new()
	sv.size = Vector2i(4128, 2208)          # 2 eyes x 2064x2208 (Quest 3 native per-eye)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.msaa_3d = Viewport.MSAA_2X
	root.add_child(sv)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"   # no backend, no network
	sv.add_child(main)
	await frames(30)
	RenderingServer.viewport_set_measure_render_time(sv.get_viewport_rid(), true)
	print("SMOKE adapter: ", RenderingServer.get_video_adapter_name(), "  rendering method: ", ProjectSettings.get_setting("rendering/renderer/rendering_method"))
	await sample("as shipped (shadows on, MSAA 2x)")
	main.set_shadows(false)
	await sample("shadows off")
	main.set_shadows(true)
	sv.msaa_3d = Viewport.MSAA_DISABLED
	await sample("MSAA off")
	main.set_shadows(false)
	await sample("shadows off + MSAA off")
	quit()
