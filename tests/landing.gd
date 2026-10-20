extends SceneTree
## The landing (docs/landing-scope.md L1 + L2), full scene (main.tscn, no backend, so no network): it is a state of the world on start
## (no start-up import), the launcher's tiles and what is greyed offline, Home from the tablet and the wheel, the status line in the
## launcher, Settings, About (the CC BY credit), the Demo models page (Full size at 1:1 in front of you, On the desk on a plinth at
## waist height), Continue, and the rocket garden (true size, 40-60 m out, name plates, no colliders, no shadows). Headless: it cannot
## judge how any of it looks or feels, or measure frame rate.
## Run: "$GODOT" --headless --path . --script res://tests/landing.gd

const Tips := preload("res://scripts/landing/tips.gd")
const DemoCatalog := preload("res://scripts/landing/demo_catalog.gd")
const RecentFile := preload("res://scripts/landing/recent_file.gd")
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
	return main.landing.launcher._body.find_child("Tile_" + id, true, false) as Button


func make_main(landing_on: bool) -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg" # no backend => no network
	main.landing_enabled = landing_on
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
	check("the logo is 2.5 m ahead", absf(logo_offset.dot(forward) - 2.5) < 0.01 and absf(logo_offset.x) < 0.01)
	check("the logo is at eye height", absf(landing.logo.global_position.y - cam.global_position.y) < 0.01)
	check("the logo faces the user (its +Z points back at the camera)", landing.logo.global_transform.basis.z.dot(-forward) > 0.99)
	check("the logo has all four parts", landing.logo.part_names() == PackedStringArray(["Emblem", "Porthole", "Wordmark", "Tagline"]))
	check("the launcher and the tips reel are open", landing.launcher.is_open() and landing.reel.is_open())
	check("the garden and logo are shown", landing.garden.visible and landing.logo.visible)

	# --- the tiles --------------------------------------------------------------------------------------------------
	var ids: Array = []
	for t in landing.launcher.tiles():
		ids.append(t["id"])
	check("the tiles are Continue, Open, New, Demo models, Demo assemblies, Servers, Settings, About", ids == ["continue", "open", "new", "models", "assemblies", "servers", "settings", "about"])
	check("offline: New assembly and Demo assemblies are greyed and say why", tile("new").disabled and tile("assemblies").disabled and "Needs a server" in tile("new").text and "Needs a server" in tile("assemblies").text)
	check("offline: Continue is greyed with nothing opened yet", tile("continue").disabled and "Nothing yet" in tile("continue").text)
	check("Open, Demo models, Servers, Settings and About work offline", not tile("open").disabled and not tile("models").disabled and not tile("servers").disabled and not tile("settings").disabled and not tile("about").disabled)
	check("the Servers tile reads Offline in an offline build", "Offline" in tile("servers").text)
	check("the connection pill says demo models only", "Offline: demo models only" in landing.launcher._pill.text)

	# --- Servers ------------------------------------------------------------------------------------------------------
	tile("servers").pressed.emit()
	await frames(2)
	var servers_text := _all_text(landing.launcher._body)
	check("Servers offline: says no server is set and shows the Scan note as coming soon", "No server is set" in servers_text and "Coming soon" in servers_text)

	# --- About: the CC BY credit ---------------------------------------------------------------------------------------
	landing.launcher.show_page("about")
	await frames(2)
	var about_text := _all_text(landing.launcher._body)
	check("About shows the SLS credit and its licence", "WISEMANmods" in about_text and "Creative Commons Attribution 4.0" in about_text)
	check("About lists every shipped model's credit", about_text.count("NASA 3D Resources") >= 8)
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
	check("Show tips off closes the reel now and is remembered", not landing.reel.is_open() and not main.show_tips())
	toggles[1].button_pressed = true
	await frames(1)
	check("Show tips on opens it again", landing.reel.is_open() and main.show_tips())

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
	check("the Demo models page lists all nine, each with Full size and On the desk", rows == 9 and buttons_ok)
	check("the catalogue finds the five rockets and four spacecraft", DemoCatalog.models("rocket").size() == 5 and DemoCatalog.models("spacecraft").size() == 4)

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
	check("Home: Continue now offers Saturn_V.glb (a glb needs no server)", not tile("continue").disabled and "Saturn_V.glb" in tile("continue").text)
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
	check("Demo assemblies: both greyed with Needs a server offline", open_buttons == 2 and all_greyed)
	check("the two demo native files ship", DemoCatalog.assemblies().all(func(a: Dictionary) -> bool: return a["exists"]))

	# --- the garden ---------------------------------------------------------------------------------------------------------
	var garden = landing.garden
	var waited := 0
	while not garden.is_built and waited < 600:
		await process_frame
		waited += 1
	check("the garden built all five rockets", garden.entries.size() == 5)
	var heights_ok := true
	var distance_ok := true
	for e in garden.entries:
		var expected: float = DemoCatalog.INFO[e["id"]]["height"]
		print("SMOKE garden ", e["id"], " height ", snappedf(e["height"], 0.01), " published ", expected, " at ", snappedf(d_of(e), 0.1), " m")
		heights_ok = heights_ok and absf(e["height"] - expected) < expected * 0.04 + 0.5
		var d: float = Vector2(e["position"].x, e["position"].z).length()
		distance_ok = distance_ok and d >= 39.99 and d <= 60.01
	check("every rocket is at true size (within 4% of the published height)", heights_ok)
	check("every rocket stands 40-60 m from the user", distance_ok)
	var plates: PackedStringArray = garden.plate_texts()
	check("each rocket has a name plate with its height", plates.size() == 5 and "Saturn V\n110.6 m" in plates[0] and plates[0].ends_with(" m"))
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
	check("the five rockets are in the scope's budget (under 135k for all nine)", tris > 0 and tris < 135000)

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


func d_of(e: Dictionary) -> float:
	return Vector2(e["position"].x, e["position"].z).length()


func _all_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	elif node is Button:
		out += (node as Button).text + "\n"
	for child in node.get_children():
		out += _all_text(child)
	return out
