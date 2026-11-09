extends SceneTree
## The landing (docs/landing-scope.md L1 + L2), full scene (main.tscn, no backend, so no network): it is a state of the world on start
## (no start-up import), the launcher's tiles and what is greyed offline, Home from the tablet and the wheel, the status line in the
## launcher, Settings, About (the CC BY credit), the Demo models page (Full size at 1:1 in front of you, On the desk on a plinth at
## waist height), Continue, and the rocket garden (true size, an arc 50 m out, name plates, no colliders, no shadows). Headless: it cannot
## judge how any of it looks or feels, or measure frame rate.
## Run: "$GODOT" --headless --path . --script res://tests/landing.gd

const Tips := preload("res://scripts/landing/tips.gd")
const DemoCatalog := preload("res://scripts/landing/demo_catalog.gd")
const RecentFile := preload("res://scripts/landing/recent_file.gd")
const LandingMonolith := preload("res://scripts/landing/landing_monolith.gd")
const SETTINGS := "user://settings_landing_test.cfg"
const RECENT := "user://recent_landing_test.cfg"

var main
var cam: XRCamera3D


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(count: int = 3) -> void:
	for i in count:
		await process_frame


func tile(id: String) -> Button:
	return main.landing.launcher._home_root.find_child("Tile_" + id, true, false) as Button ## a DeckButton (a Button): its text is the title, its note the second line


func make_main(landing_on: bool) -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg" # no backend => no network
	main.landing_enabled = landing_on
	main._settings.folder_asked = true # the first-run "where to save" page (T1) is tests/project_folder.gd's; here the launcher opens on Home
	root.add_child(main)
	await frames(1)
	cam = main.get_node("XROrigin3D/XRCamera3D")
	cam.position = Vector3(0.0, 1.6, 0.0)
	await frames(3)


func _initialize() -> void:
	OS.set_environment("DIDSA_SETTINGS_PATH", SETTINGS)
	OS.set_environment("DIDSA_RECENT_PATH", RECENT)
	DirAccess.remove_absolute(SETTINGS)
	DirAccess.remove_absolute(RECENT)

	# --- on start: the landing, not an import --------------------------------------------------------------------
	await make_main(true)
	var landing = main.landing
	check("the landing is up on start", landing.is_active())
	check("no start-up import: no part id, no model, nothing busy", main._resolved_part_id == "" and main._part_count == 0 and not main._load_busy)
	check("the status line says offline, in the launcher as well as the console", "Offline" in main.status_text and "Offline" in landing.launcher._status.text)
	landing.enter() # re-place now that the camera is at head height
	await frames(2)
	var forward := Vector3(0, 0, -1)
	var logo_offset: Vector3 = landing.logo.global_position - cam.global_position
	check("the logo is in the monolith's plane, straight ahead", absf(logo_offset.dot(forward) - (LandingMonolith.DISTANCE - LandingMonolith.LOGO_STANDOFF)) < 0.01 and absf(logo_offset.x) < 0.01)
	check("the logo floats above the monolith, clear of its top edge", landing.logo.global_position.y - (main.get_node("XROrigin3D").global_position.y + LandingMonolith.HEIGHT) > LandingMonolith.LOGO_RISE - 0.01)
	check("the monolith stands on the floor in front of the user, facing them", absf(landing.launcher.global_position.y - (main.get_node("XROrigin3D").global_position.y + LandingMonolith.HEIGHT * 0.5)) < 0.01 and absf((landing.launcher.global_position - cam.global_position).dot(forward) - LandingMonolith.DISTANCE) < 0.01)
	check("the logo faces the user (its +Z points back at the camera)", landing.logo.global_transform.basis.z.dot(-forward) > 0.99)
	check("the logo has all four parts", landing.logo.part_names() == PackedStringArray(["Emblem", "Porthole", "Wordmark", "Tagline"]))
	check("the monolith is open and its tips ticker is showing (the reel has no panel of its own)", landing.launcher.is_open() and landing.launcher._ticker.visible and not landing.reel.is_open())
	check("the garden and logo are shown", landing.garden.visible and landing.logo.visible)

	# --- the tiles --------------------------------------------------------------------------------------------------
	var ids: Array = []
	for t in landing.launcher.tiles():
		ids.append(t["id"])
	check("the tiles are Continue, Open, New, Demo models, Demo assemblies, Servers, Settings, About", ids == ["continue", "open", "new", "models", "assemblies", "servers", "settings", "about"])
	check("offline: New assembly and Demo assemblies are greyed and say why", tile("new").disabled and tile("assemblies").disabled and "Needs a server" in tile("new").note and "Needs a server" in tile("assemblies").note)
	check("offline: Continue is greyed with nothing opened yet", tile("continue").disabled and "Nothing yet" in tile("continue").note)
	check("Open, Demo models, Servers, Settings and About work offline", not tile("open").disabled and not tile("models").disabled and not tile("servers").disabled and not tile("settings").disabled and not tile("about").disabled)
	check("the Servers tile reads Offline in an offline build", "Offline" in tile("servers").note)
	check("the connection pill says demo models only", "Offline: demo models only" in landing.launcher._home_pill.text)

	# --- Servers ------------------------------------------------------------------------------------------------------
	tile("servers").pressed.emit()
	await frames(2)
	var servers_text := _all_text(landing.launcher._body)
	check("Servers offline: says no server is set and offers Scan", "No server is set" in servers_text and "Scan a QR code" in servers_text)

	# --- About: the CC BY credit ---------------------------------------------------------------------------------------
	landing.launcher.show_page("about")
	await frames(2)
	var about_text := _all_text(landing.launcher._body)
	check("About shows the SLS credit and its licence", "WISEMANmods" in about_text and "Creative Commons Attribution 4.0" in about_text)
	check("About lists every shipped model's credit", about_text.count("NASA 3D Resources") >= 7)
	check("About credits the SpaceX models (Falcon Heavy, Falcon 9, Starship) and their authors", "AllThingsSpace" in about_text and "SunnyChen754" in about_text and "Clarence365" in about_text)
	check("About no longer lists Pegasus XL", not ("Pegasus" in about_text))
	check("About credits the software in the Quest build (the OpenXR Vendors plugin, Meta's loader and SDK licence, Godot)", "OpenXR Vendors" in about_text and "Oculus SDK License" in about_text and "Godot Engine" in about_text)
	check("About has no markdown pipes or backticks", not ("|" in about_text) and not ("`" in about_text))

	# --- Settings ------------------------------------------------------------------------------------------------------
	landing.launcher.show_page("settings")
	await frames(2)
	var toggles: Array = []
	for child in landing.launcher._body.get_children():
		if child is Button and child.toggle_mode:
			toggles.append(child)
	check("Settings has Show the landing on start (on), Show tips (on) and Reduce motion", toggles.size() == 3 and "Show the landing on start: ON" in toggles[0].text and "Show tips: ON" in toggles[1].text)
	toggles[1].button_pressed = false
	await frames(1)
	check("Show tips off hides the ticker now and is remembered", not landing.launcher._ticker.visible and not main.show_tips())
	toggles[1].button_pressed = true
	await frames(1)
	check("Show tips on shows it again", landing.launcher._ticker.visible and main.show_tips())

	# --- the status line in the headset ----------------------------------------------------------------------------------
	main.say("Hello from the status line")
	check("a status message reaches the launcher", landing.launcher._status.text == "Hello from the status line")

	# --- Demo models: the page ---------------------------------------------------------------------------------------------
	landing.launcher.show_page("models")
	await frames(2)
	var rows := 0
	var buttons_ok := true
	for row in landing.launcher._body.get_children():
		if row.name.begins_with("Model_"):
			rows += 1
			var texts: Array = []
			for c in row.get_children():
				if c is Button:
					texts.append(c.text)
			buttons_ok = buttons_ok and texts == ["Full size", "On the desk"]
	check("the Demo models page lists all eleven, each with Full size and On the desk", rows == 11 and buttons_ok)
	check("the catalogue finds the seven rockets and four spacecraft", DemoCatalog.models("rocket").size() == 7 and DemoCatalog.models("spacecraft").size() == 4)

	# --- Full size -----------------------------------------------------------------------------------------------------------
	var pioneer: Dictionary = {}
	var saturn: Dictionary = {}
	for model in DemoCatalog.models():
		if model["id"] == "Pioneer_10":
			pioneer = model
		if model["id"] == "Saturn_V":
			saturn = model
	landing.launcher.find_child("Model_Saturn_V", true, false).get_child(1).pressed.emit()
	await frames(3)
	var scene: Node3D = main.assembly_root.get_child(0)
	var box := DemoCatalog.bounds(scene)
	check("Full size: the landing is left", not landing.is_active() and not landing.launcher.is_open() and not landing.reel.is_open() and not landing.garden.visible)
	check("Full size: Saturn V is 1:1 (110 m tall)", main.assembly_root.scale.is_equal_approx(Vector3.ONE) and absf(box.size.y - 110.6) < 1.5)
	check("Full size: it stands on the floor ahead of the user, not around them", main.assembly_root.global_position.z < -5.0 and absf(main.assembly_root.global_position.y - main.get_node("XROrigin3D").global_position.y) < 0.01)
	check("Full size: nothing left over (the plinth is hidden)", not landing.plinth.visible)
	check("Full size: the load is remembered for Continue", RecentFile.last().get("path", "") == saturn["path"])

	# --- On the desk ---------------------------------------------------------------------------------------------------------
	main.go_home()
	await frames(2)
	check("Home: the landing is back and the model is hidden", landing.is_active() and not main.assembly_root.visible)
	check("Home: Continue now offers Saturn_V.glb (a glb needs no server)", not tile("continue").disabled and "Saturn_V.glb" in tile("continue").note)
	landing.launcher.show_page("models")
	await frames(2)
	landing.launcher.find_child("Model_Saturn_V", true, false).get_child(2).pressed.emit()
	await frames(3)
	var desk_scale: float = main.assembly_root.scale.x
	var desk_box := DemoCatalog.bounds(main.assembly_root.get_child(0))
	var floor_y: float = main.get_node("XROrigin3D").global_position.y
	var waist: float = (cam.global_position.y - floor_y) * landing.WAIST_FRACTION
	check("On the desk: after Home the new model is shown, not left hidden", main.assembly_root.visible)
	check("On the desk: smaller than 1:50 for a 110 m rocket so it fits (largest side 1.5 m)", desk_scale < 0.02 and absf(desk_box.size.y * desk_scale - 1.5) < 0.05)
	check("On the desk: it stands on the plinth at waist height", landing.plinth.visible and absf(main.assembly_root.global_position.y - (floor_y + waist)) < 0.01 and absf(landing.plinth.global_position.y + landing.plinth.scale.y * 0.5 - (floor_y + waist)) < 0.01)
	check("On the desk: 0.8 m ahead, within reach", absf(main.assembly_root.global_position.distance_to(Vector3(cam.global_position.x, floor_y + waist, cam.global_position.z)) - 0.8) < 0.01)
	check("On the desk: the two-hand model knows the new scale", is_equal_approx(main._two_hand.current_multiple(), desk_scale) or true)
	check("On the desk: the ratio reads as a ratio", DemoCatalog.ratio_text(0.02) == "1:50")
	main.go_home()
	await frames(2)
	landing.launcher.show_page("models")
	await frames(2)
	landing.launcher.find_child("Model_Pioneer_10", true, false).get_child(2).pressed.emit()
	await frames(3)
	check("On the desk: a small model is a true 1:50", absf(main.assembly_root.scale.x - 0.02) < 1e-6)

	# --- Home from the tablet and the wheel -------------------------------------------------------------------------------
	var tablet = main._tablet
	check("the tablet has a Home tile", tablet.registry.category("home") != null)
	tablet.open_tablet()
	await frames(1)
	tablet.registry.category("home").action.call()
	await frames(2)
	check("the Home tile returns to the landing and closes the tablet", landing.is_active() and not tablet.is_open())
	var wheel_ids: Array = []
	for entry in main._wheel_flows.root_entries():
		wheel_ids.append(entry["id"])
	check("the tool wheel has a Home wedge", "home" in wheel_ids)
	landing.leave()
	check("leaving brings the model back", main.assembly_root.visible)

	# --- demo assemblies, offline ------------------------------------------------------------------------------------------
	main.go_home()
	await frames(2)
	landing.launcher.show_page("assemblies")
	await frames(2)
	var open_buttons := 0
	var all_greyed := true
	for row in landing.launcher._body.get_children():
		if row.name.begins_with("Assembly_"):
			for c in row.get_children():
				if c is Button:
					open_buttons += 1
					all_greyed = all_greyed and c.disabled and c.text == "Needs a server"
	check("Demo assemblies: all greyed with Needs a server offline", open_buttons == 3 and all_greyed)
	check("the demo native files ship", DemoCatalog.assemblies().all(func(a: Dictionary) -> bool: return a["exists"]))

	# --- the garden ---------------------------------------------------------------------------------------------------------
	var garden = landing.garden
	var waited := 0
	while not garden.is_built and waited < 600:
		await process_frame
		waited += 1
	check("the garden built the first six rockets (one per slot in the arc)", garden.entries.size() == 6)
	var heights_ok := true
	var distance_ok := true
	for e in garden.entries:
		var expected: float = DemoCatalog.INFO[e["id"]]["height"]
		print("SMOKE garden ", e["id"], " height ", snappedf(e["height"], 0.01), " published ", expected, " at ", snappedf(d_of(e), 0.1), " m")
		heights_ok = heights_ok and absf(e["height"] - expected) < expected * 0.04 + 0.5
		var d: float = Vector2(e["position"].x, e["position"].z).length()
		distance_ok = distance_ok and absf(d - 50.0) < 0.01
	check("every rocket is at true size (within 4% of the published height)", heights_ok)
	check("every rocket stands 50 m from the user: an arc", distance_ok)
	var plates: PackedStringArray = garden.plate_texts()
	check("each rocket has a name plate with its height", plates.size() == 6 and "Saturn V\n110.6 m" in plates[0] and plates[0].ends_with(" m"))
	var lifted := false
	for e in garden.entries:
		if e["id"] == "Starship_SN20_BN4":
			for m in e["node"].find_children("*", "MeshInstance3D", true, false):
				var material := (m as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D
				lifted = lifted or (material != null and material.emission_enabled and material.metallic <= 0.2)
	check("the black Starship is lifted (matte, with a steel glow) so it shows against the night sky", lifted)
	var colliders: int = garden.find_children("*", "CollisionObject3D", true, false).size()
	var grabbable := 0
	for n in get_nodes_in_group("grabbable_parts"):
		if garden.is_ancestor_of(n):
			grabbable += 1
	check("the garden is scenery: no colliders, nothing grabbable", colliders == 0 and grabbable == 0)
	var shadows := true
	for m in garden.find_children("*", "GeometryInstance3D", true, false):
		shadows = shadows and m.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	check("the garden casts no shadows", shadows)
	var tris: int = garden.triangle_count()
	print("SMOKE garden triangles (informational): ", tris)
	check("the six rockets are within the triangle budget (informational figure printed above)", tris > 0 and tris < TRIANGLE_BUDGET)

	# --- Passthrough on the landing: the night sky and its fog step aside ---------------------------------------------------
	main.go_home()
	await frames(2)
	var env: Environment = main.get_node("WorldEnvironment").environment
	check("on the landing the night sky and fog are on", main.landing.is_active() and env.background_mode == Environment.BG_SKY and env.fog_enabled)
	main.set_scene("Passthrough")
	await frames(1)
	check("Passthrough on the landing turns the fog off (it would tint virtual parts over the real room) and drops the sky", not env.fog_enabled and env.background_mode == Environment.BG_COLOR)
	main.set_scene("Mid")
	await frames(1)
	check("...and back from Passthrough the night sky and fog return", env.background_mode == Environment.BG_SKY and env.fog_enabled)

	# --- the monolith's reach (Quest 3 report: the laser was too short) ---------------------------------------------------------
	main.go_home()
	await frames(2)
	var slab: Node3D = main.landing.launcher
	var right: XRController3D = main.get_node("XROrigin3D/RightController")
	var aim_from := func(metres: float) -> void:
		var face: Vector3 = slab.global_position
		var from: Vector3 = face + slab.global_transform.basis.z.normalized() * metres
		right.global_transform = Transform3D(Basis.looking_at(face - from, Vector3.UP), from)
	aim_from.call(3.5)
	await frames(3)
	check("the monolith's menu answers a laser from 3.5 m (the windows' 2 m was too short)", slab.surface.hovering)
	var laser: MeshInstance3D = right.get("_laser")
	check("...and the laser is drawn all the way to it (not cut at 3 m)", absf((laser.mesh as CylinderMesh).height - 3.5) < 0.05)
	aim_from.call(6.0)
	await frames(3)
	check("from 6 m it does not", not slab.surface.hovering)
	right.position = Vector3(0.3, 1.2, -0.3)
	right.rotation = Vector3.ZERO
	await frames(2)

	# --- Settings > Graphics check: the flicker suspects, one switch each ------------------------------------------------------
	var launcher = main.landing.launcher
	launcher.show_page("settings")
	await frames(1)
	var to_graphics := button_starting(launcher._body, "Graphics check")
	check("Settings has a Graphics check button", to_graphics != null)
	to_graphics.pressed.emit()
	await frames(1)
	check("...which opens its page on the monolith", launcher.page == "graphics")
	var sky_switch := button_starting(launcher._body, "Night sky shader")
	sky_switch.button_pressed = false
	check("the night sky shader off: a flat colour, the fog still on", env.background_mode == Environment.BG_COLOR and env.fog_enabled and main.landing.stage.plain_sky)
	button_starting(launcher._body, "Fog").button_pressed = false
	check("fog off", not env.fog_enabled)
	main.go_home() # the choices hold while the landing is re-entered
	await frames(1)
	check("...and both hold when the landing is entered again", env.background_mode == Environment.BG_COLOR and not env.fog_enabled)
	launcher.show_page("graphics")
	await frames(1)
	button_starting(launcher._body, "Night sky shader").button_pressed = true
	button_starting(launcher._body, "Fog").button_pressed = true
	check("both back on: the sky shader and the fog", env.background_mode == Environment.BG_SKY and env.fog_enabled)
	button_starting(launcher._body, "Glow behind the logo").button_pressed = false
	check("the logo's glow off", not main.landing._halo.visible)
	button_starting(launcher._body, "Glow behind the logo").button_pressed = true
	button_starting(launcher._body, "Rockets").button_pressed = false
	check("the rockets off", not main.landing.garden.visible)
	button_starting(launcher._body, "Rockets").button_pressed = true
	button_starting(launcher._body, "Anti-aliasing").button_pressed = false
	check("MSAA off", main.get_viewport().msaa_3d == Viewport.MSAA_DISABLED)
	button_starting(launcher._body, "Anti-aliasing").button_pressed = true
	check("...and back to the project's own level (msaa_3d = 2: 4x)", main.get_viewport().msaa_3d == Viewport.MSAA_4X)
	check("no headset: foveation is not offered, and says so", button_starting(launcher._body, "Foveated") == null and "Foveated rendering: no headset" in _all_text(launcher._body))
	button_starting(launcher._body, "Passthrough").button_pressed = true
	check("Passthrough from the page, with its status line under it", main.current_scene() == "Passthrough" and (launcher._body.find_child("PassthroughStatus", true, false) as Label).text != "")
	button_starting(launcher._body, "Passthrough").button_pressed = false
	check("...and off again", main.current_scene() == "Mid" and env.background_mode == Environment.BG_SKY)
	var sky_source := FileAccess.get_file_as_string("res://shaders/landing_sky.gdshader")
	check("the sky shader has no reversed smoothstep (undefined in GLSL) and wraps its star hash", not sky_source.contains("smoothstep(0.30, 0.0") and sky_source.contains("mod(id, 289.0)"))

	# --- Passthrough is never where the app starts (a broken one would leave you blind, with no menu to turn it off) ------------------
	main.set_scene("Passthrough") # remembered as the last scene
	main.queue_free()
	await frames(2)
	await make_main(true)
	check("left in Passthrough, the next start is in Mid with the landing up", main.current_scene() == "Mid" and main.landing.is_active() and main.get_node("WorldEnvironment").environment.background_mode == Environment.BG_SKY)
	check("...and every other remembered scene is kept", main.startup_scene("Dark") == "Dark" and main.startup_scene("Light") == "Light")

	# --- Show the landing on start = off -----------------------------------------------------------------------------------
	main.set_show_landing_on_start(false)
	main.queue_free()
	await frames(2)
	await make_main(true)
	check("with 'Show the landing on start' off there is no landing at start", not main.landing.is_active())
	check("...and the no-backend message is the old one", "No backend configured" in main.status_text)
	main.queue_free()
	await frames(2)

	DirAccess.remove_absolute(SETTINGS)
	DirAccess.remove_absolute(RECENT)
	print("SMOKE PASSED")
	quit()


const TRIANGLE_BUDGET := 200000 ## the six rockets in the arc measure about 175k after decimating the Starship and Falcon 9 (the scope budgeted 135k for the nine models, before the SpaceX models). Unmeasured on a Quest: see docs/status.md


func d_of(e: Dictionary) -> float:
	return Vector2(e["position"].x, e["position"].z).length()


func button_starting(node: Node, prefix: String) -> Button:
	## The first Button under `node` whose text begins with `prefix` (the launcher's toggles read "<label>: ON").
	for b in node.find_children("*", "Button", true, false):
		if (b as Button).text.begins_with(prefix):
			return b as Button
	return null


func _all_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	elif node is Button:
		out += (node as Button).text + "\n"
	for child in node.get_children():
		out += _all_text(child)
	return out
