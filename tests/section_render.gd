extends SceneTree
## NEEDS A REAL RENDER, not --headless (same class of exception as
## gpu_timing.gd) — confirms shaders/section_clip.gdshader, driven by the
## real section_tool.gd wrap/reconcile pipeline (not a stand-in shader),
## genuinely DISCARDS fragments on the excluded side rather than just fading
## them, and that Flip genuinely swaps which side survives. Everything else
## about this tool (grab math, undo, the wrap/unwrap bookkeeping) is pure
## logic and covered headless by tests/section_tool.gd — this is the one
## thing that needs pixels.
##
## Unlike gpu_timing.gd (written for John's own machine, which has a real
## GPU — "add --rendering-driver vulkan"), this cloud sandbox has no GPU or
## display at all. Xvfb + Mesa's llvmpipe (software rendering) stands in for
## both, confirmed working during this session for exactly this kind of
## check. Run:
##   xvfb-run -a "$GODOT" --path . --script res://tests/section_render.gd
## (no --headless — Godot needs a real windowing/rendering context, even a
## virtual one; --headless forces the dummy driver, which accepts shader
## code without ever actually running it — see this session's own spike
## that first surfaced that distinction).

const SectionTool := preload("res://scripts/section_tool.gd")


func _initialize() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(64, 64)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)

	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.0
	world_env.environment = env
	viewport.add_child(world_env)

	var camera := Camera3D.new()
	camera.current = true
	camera.position = Vector3(0, 0, 5)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 10.0
	viewport.add_child(camera)

	# shaders/section_clip.gdshader hardcodes METALLIC=1.0/ROUGHNESS=1.0 (the
	# glTF spec's own default, matching what mesh_export.py actually bakes —
	# see that shader's own docstring) — a fully metallic, fully rough
	# surface has near-zero diffuse response and needs a real light with
	# specular content to read as anything but dark under flat ambient alone,
	# unlike the plain unshaded material this session's earlier spike used.
	var light := DirectionalLight3D.new()
	light.light_energy = 3.0
	light.rotation_degrees = Vector3(-40, -30, 0)
	viewport.add_child(light)

	var part := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(8, 8, 0.01) # a thin wall in the XY plane spanning x=-4..4, straddling a plane at x=0
	part.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1)
	box.surface_set_material(0, mat)
	viewport.add_child(part)

	var tool := SectionTool.new()
	root.add_child(tool)
	await process_frame # tool must be inside the tree before its gizmo's global_transform works — see tests/section_tool.gd's own note on this
	tool.set_active(true, null) # gizmo spawns at a fixed fallback pose (no camera given) — see section_tool.gd's _place_in_front_of()

	# Aim the gizmo so its "kept" direction (local -Z) points along world +X,
	# splitting the box's own x=-4..4 span at x=0 — Basis.looking_at(dir, up)
	# is exactly "-Z points toward dir".
	tool.gizmo().global_transform = Transform3D(Basis.looking_at(Vector3(1, 0, 0), Vector3.UP), Vector3.ZERO)
	tool.reconcile([part]) # wraps `part` with the real shaders/section_clip.gdshader, preserving its white albedo

	# --- the wrapped shader with clipping explicitly off still shows both sides
	RenderingServer.global_shader_parameter_set("section_enabled", false)
	for i in 4:
		await process_frame
	var img_off_explicit: Image = viewport.get_texture().get_image()
	var lit_left := img_off_explicit.get_pixel(10, 32)
	var lit_right := img_off_explicit.get_pixel(54, 32)
	print("calibration — lit pixel values: left=", lit_left, " right=", lit_right) # ~0.84 measured (metallic=1/roughness=1 under one directional light) — 0.3 below gives clear margin over the 0.0 background
	print("SMOKE wrapped-but-disabled shows both sides: ", lit_left.r > 0.3 and lit_right.r > 0.3)

	# --- re-enabled (set_flipped() is a convenient way back to a full
	# _update_global_plane() call without duplicating its logic here)
	tool.set_flipped(false)
	for i in 4:
		await process_frame
	var img_clip: Image = viewport.get_texture().get_image()
	var left := img_clip.get_pixel(10, 32) # world x < 0 — excluded
	var right := img_clip.get_pixel(54, 32) # world x > 0 — kept
	print("SMOKE clipped: excluded side (x<0) goes to background: ", left.r < 0.1)
	print("SMOKE clipped: kept side (x>0) stays lit: ", right.r > 0.3)

	# --- Flip swaps which side survives, without moving the gizmo
	tool.set_flipped(true)
	for i in 4:
		await process_frame
	var img_flipped: Image = viewport.get_texture().get_image()
	print("SMOKE flip swaps which side is kept: ", img_flipped.get_pixel(10, 32).r > 0.3 and img_flipped.get_pixel(54, 32).r < 0.1)

	# --- turning the tool off unwraps back to the original plain material —
	# both sides visible again, confirming _unwrap_all() actually restores
	# the part's real appearance, not just that clipping stops
	tool.set_active(false)
	for i in 4:
		await process_frame
	var img_restored: Image = viewport.get_texture().get_image()
	print("SMOKE deactivating restores the original material — both sides lit: ", img_restored.get_pixel(10, 32).r > 0.3 and img_restored.get_pixel(54, 32).r > 0.3)

	part.free()
	tool.free()
	quit()
