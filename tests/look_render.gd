extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + llvmpipe, same recipe as
## tests/section_render.gd):
##   xvfb-run -a "$GODOT" --path . --script res://tests/look_render.gd
##
## Real-headset feedback: in the Light and Dark scenes the models were nearly
## the background colour — the backend's parts are pure white and each scene
## used different light energies (see environment_manager.gd, which now shares
## one lighting rig across Light/Dark/Mid). This loads a real
## backend glb (tests/fixtures/real_assembly_mesh.glb: baseColorFactor only,
## no metallic/roughness) through main.gd's real _show_model(), renders each
## scene, and checks the part is clearly distinguishable from the background
## and looks the same grey in all three. Also checks the Light scene's floor
## grid is charcoal and the others white. Set LOOK_RENDER_DIR to also save a
## PNG per scene for eyeballing.
##
## CAVEAT: project.godot uses the "mobile" (Vulkan) renderer, but this sandbox
## can only render through Mesa llvmpipe's OpenGL (compatibility) path, whose
## lighting/tonemapping isn't identical — the direct-lit face of a white part
## saturates to 1.0 here. So the pixel checks are a smoke test, not a
## calibration of the headset look; the deterministic guarantee is the shared
## lighting rig asserted below (same ambient + sun in every scene).

var main


func _luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _load_glb() -> PackedByteArray:
	## A real assembly-mesh.glb fetched from a real backend (assembly.didsa,
	## the repo's own tracked file) — baseColorFactor only, no metallic/
	## roughness, exactly what mesh_export.py produces.
	return FileAccess.get_file_as_bytes("res://tests/fixtures/real_assembly_mesh.glb")


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	for i in 4:
		await process_frame
	for child in main.get_children():
		if child is Camera3D and not (child is XRCamera3D):
			child.global_position = main.spawn_position + Vector3(0.25, 0.2, 0.45)
			child.look_at(main.spawn_position, Vector3.UP)
	var ok: bool = main._show_model(_load_glb(), "", 0.001)
	print("SMOKE loaded the test cube: ", ok)
	var env_mgr: WorldEnvironment = main.get_node("WorldEnvironment")
	var grid: ShaderMaterial = main.get_node("Ground/MeshInstance3D").mesh.material
	var part_luma := {}
	var sun: DirectionalLight3D = main.get_node("DirectionalLight3D")
	var rigs := {}
	for scene_name in ["Light", "Dark", "Mid"]:
		env_mgr.set_scene(scene_name)
		for i in 6:
			await process_frame
		var img: Image = root.get_texture().get_image()
		var bg := img.get_pixel(4, 4)
		var w := img.get_width()
		var h := img.get_height()
		# main.gd's desktop camera looks straight at the model, so the middle of
		# the frame is on the cube — the same pixel in every scene, so the
		# "same grey" comparison below isn't biased by which face got picked.
		var best_luma := _luma(img.get_pixel(w / 2, h / 2))
		var best := absf(best_luma - _luma(bg))
		part_luma[scene_name] = best_luma
		rigs[scene_name] = [sun.light_energy, sun.light_color, env_mgr.environment.ambient_light_energy, env_mgr.environment.ambient_light_color]
		print("calibration — ", scene_name, ": bg luma ", snappedf(_luma(bg), 0.001), ", part luma ", snappedf(best_luma, 0.001), ", contrast ", snappedf(best, 0.001))
		print("SMOKE ", scene_name, ": the part is clearly distinguishable from the background: ", best > 0.12)
		var dir := OS.get_environment("LOOK_RENDER_DIR")
		if dir != "":
			img.save_png(dir.path_join("look_%s.png" % scene_name))
		var line_color: Color = grid.get_shader_parameter("line_color")
		if scene_name == "Light":
			print("SMOKE Light: floor grid is charcoal: ", _luma(line_color) < 0.35)
		else:
			print("SMOKE ", scene_name, ": floor grid is white: ", _luma(line_color) > 0.9)
	print("SMOKE Light/Dark/Mid share one lighting rig (sun + ambient identical): ", rigs["Light"] == rigs["Mid"] and rigs["Dark"] == rigs["Mid"])
	print("SMOKE the part reads the same grey in all three scenes (within 0.08 luma): ",
		absf(part_luma["Light"] - part_luma["Mid"]) < 0.08 and absf(part_luma["Dark"] - part_luma["Mid"]) < 0.08)
	quit()
