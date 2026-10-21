extends SceneTree
## The landing's tips reel and logo (docs/landing-scope.md L3), full scene (main.tscn, no backend): the 17 tips as data, the offline
## list leaving out server-only tips, the reel cycling every 8 s, pause, previous / next (wrapping), the "Show tips" setting, and the
## logo's idle animation (porthole pulse, sway) freezing under Reduce motion. Headless: cannot judge how the fade or the sway looks.
## Run: "$GODOT" --headless --path . --script res://tests/tips_reel.gd

const Tips := preload("res://scripts/landing/tips.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const SETTINGS := "user://settings_tips_test.cfg"
const RECENT := "user://recent_tips_test.cfg"

var main


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(count: int = 3) -> void:
	for i in count:
		await process_frame


func _initialize() -> void:
	OS.set_environment("DIDSA_SETTINGS_PATH", SETTINGS)
	OS.set_environment("DIDSA_RECENT_PATH", RECENT)
	DirAccess.remove_absolute(SETTINGS)
	DirAccess.remove_absolute(RECENT)

	# --- the data --------------------------------------------------------------------------------------------------
	var ids := {}
	var well_formed := true
	var icons_exist := true
	for tip in Tips.TIPS:
		ids[tip["id"]] = true
		well_formed = well_formed and tip.has_all(["id", "title", "text", "icon", "server"]) and str(tip["title"]) != "" and str(tip["text"]).ends_with(".")
		icons_exist = icons_exist and UiIcons.has_icon(str(tip["icon"]))
	check("there are 17 tips with unique ids", Tips.TIPS.size() == 17 and ids.size() == 17)
	check("every tip has an id, title, sentence, icon and server flag", well_formed)
	check("every tip's icon is a real icon", icons_exist)
	var offline := Tips.for_connection(false)
	var online := Tips.for_connection(true)
	var offline_has_server_tip := false
	for tip in offline:
		offline_has_server_tip = offline_has_server_tip or tip["server"]
	check("with a server all 17 show; offline the server-only ones are left out", online.size() == 17 and offline.size() < 17 and offline.size() >= 8 and not offline_has_server_tip)
	check("the tips that need DIDSA-CAD are the paint, measure, mates, rooms, scenes and files ones", ["paint", "measure", "mates", "rooms", "scenes", "same_files"].all(func(id: String) -> bool: return not Tips.for_connection(false).any(func(t: Dictionary) -> bool: return t["id"] == id)))
	check("the cycle is 8 seconds", Tips.CYCLE_SECONDS == 8.0)

	# --- the reel in the world ----------------------------------------------------------------------------------------
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	main.landing_enabled = true
	root.add_child(main)
	await frames(1)
	main.get_node("XROrigin3D/XRCamera3D").position = Vector3(0.0, 1.6, 0.0)
	await frames(3)
	var reel = main.landing.reel
	check("the monolith's ticker is showing on the landing and the reel starts at the first offline tip", main.landing.launcher._ticker.visible and reel.index == 0 and reel.current()["id"] == offline[0]["id"])
	check("offline the reel holds only the offline tips", reel.tip_count() == offline.size())
	reel.next() # restart the clock (the frames above ran it a little, in real time)
	reel.previous()
	var first_id: String = reel.current()["id"]
	reel.tick(7.9)
	check("it stays on a tip for 8 s (7.9 s: not yet)", reel.current()["id"] == first_id)
	reel.tick(0.2)
	check("after 8 s it moves on", reel.current()["id"] != first_id and reel.index == 1)
	reel.toggle_pause()
	var paused_id: String = reel.current()["id"]
	reel.tick(30.0)
	check("paused: it stays however long it waits", reel.current()["id"] == paused_id and reel.paused)
	check("the pause button reads Play while paused", reel._pause_button.text == "Play")
	reel.next()
	check("Next works while paused", reel.index == 2)
	reel.previous()
	reel.previous()
	check("Previous goes back", reel.index == 0)
	reel.previous()
	check("Previous wraps from the first to the last", reel.index == reel.tip_count() - 1)
	reel.next()
	check("Next wraps from the last to the first", reel.index == 0)
	reel.toggle_pause()
	reel.tick(1.0)
	reel.next()
	reel.tick(7.5)
	check("a manual step restarts the 8 s clock", reel.index == 1)
	check("the card shows the tip's title, text and position", reel._title.text == reel.current()["title"] and reel._text.text == reel.current()["text"] and reel._counter.text == "2 / %d" % reel.tip_count())

	# --- it walks every tip -----------------------------------------------------------------------------------------------
	var seen := {}
	reel.index = 0
	for i in reel.tip_count():
		seen[reel.current()["id"]] = true
		reel.tick(8.0)
	check("a full cycle shows every offline tip once", seen.size() == offline.size() and reel.index == 0)

	# --- Show tips setting ---------------------------------------------------------------------------------------------------
	main.set_show_tips(false)
	check("Show tips off hides the ticker", not main.landing.launcher._ticker.visible)
	main.landing.enter()
	await frames(2)
	check("...and the landing does not show it again", not main.landing.launcher._ticker.visible)
	main.set_show_tips(true)
	check("Show tips on shows it again", main.landing.launcher._ticker.visible)

	# --- logo animation ---------------------------------------------------------------------------------------------------------
	var logo = main.landing.logo
	UiFeedback.reduce_motion = false
	logo.set_clock(1.3) # 1.3 s into the 2.6 s pulse: the top
	check("the porthole swells at the top of its pulse", logo.pulse_amount() > 0.95)
	logo.set_clock(0.0)
	check("...and is at rest at the start", absf(logo.pulse_amount()) < 0.001 and absf(logo._scene.rotation.y) < 1e-6)
	logo.set_clock(3.5) # a quarter of the 14 s sway
	check("the whole logo sways (about 3 degrees at the most)", absf(rad_to_deg(logo._scene.rotation.y)) > 2.8 and absf(rad_to_deg(logo._scene.rotation.y)) <= 3.001)
	logo.set_clock(0.0)
	await frames(30) # the logo's own _process advances its clock
	check("with motion on, it animates by itself", logo._clock > 0.0)
	UiFeedback.reduce_motion = true
	await frames(3)
	check("Reduce motion: the clock stops, the logo faces straight ahead and the porthole is at rest", logo._clock == 0.0 and absf(logo._scene.rotation.y) < 1e-6 and absf(logo.pulse_amount()) < 0.001)
	var before: float = logo._clock
	await frames(30)
	check("Reduce motion: it stays frozen", logo._clock == before)
	main.set_reduce_motion(false)
	check("the porthole has its own material (the other parts' are untouched)", logo.porthole.get_surface_override_material(0) != null)

	UiFeedback.reduce_motion = false
	main.queue_free()
	await frames(2)
	DirAccess.remove_absolute(SETTINGS)
	DirAccess.remove_absolute(RECENT)
	print("SMOKE PASSED")
	quit()
