extends SceneTree
## user://graphics.cfg (scripts/graphics_overrides.gd): the graphics switches read at startup so a headset fault can be bisected without a rebuild
## (docs/quest-first-run-fixes.md B2). Full scene (main.tscn, no backend) with the landing on: every key applied (MSAA, VRS, the landing's sky, fog, glow
## and rockets, which are then not even loaded), the switches holding when the landing is entered again, a missing file changing nothing, and a file with
## nonsense values clamped. Foveation needs a headset: here it is only checked that asking for it does nothing and says so.
## Run: "$GODOT" --headless --path . --script res://tests/graphics_overrides.gd

const CFG := "user://graphics_overrides_test.cfg"
const SETTINGS := "user://settings_graphics_overrides_test.cfg"

var main


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(count: int = 3) -> void:
	for i in count:
		await process_frame


func make_main() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg" # no backend => no network
	main.landing_enabled = true
	root.add_child(main)
	await frames(1)
	main.get_node("XROrigin3D/XRCamera3D").position = Vector3(0.0, 1.6, 0.0)
	await frames(3)


func write_cfg(text: String) -> void:
	var f := FileAccess.open(CFG, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _initialize() -> void:
	OS.set_environment("DIDSA_SETTINGS_PATH", SETTINGS)
	OS.set_environment("DIDSA_GRAPHICS_PATH", CFG)
	DirAccess.remove_absolute(SETTINGS)
	DirAccess.remove_absolute(CFG)

	# --- no file: the defaults ----------------------------------------------------------------------------------------------
	await make_main()
	var env: Environment = main.get_node("WorldEnvironment").environment
	check("no graphics.cfg: MSAA 4x (the project's msaa_3d = 2), VRS off, the night sky, fog, glow and the rockets as built", main.get_viewport().msaa_3d == Viewport.MSAA_4X and main.get_viewport().vrs_mode == Viewport.VRS_DISABLED and env.background_mode == Environment.BG_SKY and env.fog_enabled and main.landing._halo.visible and main.landing.garden.visible)
	main.queue_free()
	await frames(2)

	# --- every key --------------------------------------------------------------------------------------------------------------
	write_cfg('[graphics]\nfoveation=0\nvrs="xr"\nmsaa=0\nsky="plain"\nfog=false\nrockets=false\nglow=false\n')
	await make_main()
	env = main.get_node("WorldEnvironment").environment
	check("MSAA off", main.get_viewport().msaa_3d == Viewport.MSAA_DISABLED)
	check("VRS from the headset's foveation map", main.get_viewport().vrs_mode == Viewport.VRS_XR)
	check("the landing's sky a flat colour and its fog off", env.background_mode == Environment.BG_COLOR and not env.fog_enabled)
	check("the logo's glow off", not main.landing._halo.visible)
	check("the rockets off and not even loaded", not main.landing.garden.visible and not main.landing.garden.is_built)
	check("no headset: foveation is left alone and reads -1", main.foveation_level() == -1)
	main.go_home()
	await frames(2)
	check("...and all of it holds when the landing is entered again", env.background_mode == Environment.BG_COLOR and not env.fog_enabled and not main.landing._halo.visible and not main.landing.garden.visible)
	main.landing.launcher.show_page("graphics")
	await frames(1)
	var rockets: Button = null
	for b in main.landing.launcher._body.find_children("*", "Button", true, false):
		if (b as Button).text.begins_with("Rockets"):
			rockets = b
	check("the Graphics check page starts from what the file set (Rockets: off)", rockets != null and not rockets.button_pressed)
	rockets.button_pressed = true
	var waited := 0
	while not main.landing.garden.is_built and waited < 600: # one rocket a frame
		await process_frame
		waited += 1
	check("...and turning the rockets on there loads them", main.landing.garden.visible and main.landing.garden.is_built)
	main.queue_free()
	await frames(2)

	# --- nonsense values are clamped, unknown keys ignored -----------------------------------------------------------------------
	write_cfg('[graphics]\nmsaa=9\nsky="purple"\nbogus=1\n')
	await make_main()
	env = main.get_node("WorldEnvironment").environment
	check("msaa=9 is clamped to 4x, sky=\"purple\" means the shader, an unknown key is ignored", main.get_viewport().msaa_3d == Viewport.MSAA_4X and env.background_mode == Environment.BG_SKY)
	main.queue_free()
	await frames(2)

	DirAccess.remove_absolute(SETTINGS)
	DirAccess.remove_absolute(CFG)
	print("SMOKE PASSED")
	quit()
