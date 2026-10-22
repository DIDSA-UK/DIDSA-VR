extends SceneTree
## The launcher's Scan page (docs/landing-scope.md L5), full scene (main.tscn, no backend), with codes fed in by hand as the headset's marker tracking
## would deliver them: opening it starts the scanner and says, in words, what the headset answered at each step (here: no OpenXR, since this is headless);
## what a read code is called, never showing the code itself (it carries the API key); leaving the page, going Back or closing the launcher stops
## listening; the passthrough toggle and putting the scene back; and the project's Android-only spatial-entity settings being in project.godot (they
## are read at OpenXR start-up, so they cannot be exercised here). Cannot say whether a Quest reads a code: that is step L5 on the headset.
## Run: "$GODOT" --headless --path . --script res://tests/scan_page.gd

const SETTINGS := "user://settings_scan_test.cfg"


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(count: int = 3) -> void:
	for i in count:
		await process_frame


func _initialize() -> void:
	OS.set_environment("DIDSA_SETTINGS_PATH", SETTINGS)
	OS.set_environment("DIDSA_RECENT_PATH", "user://recent_scan_test.cfg")
	OS.set_environment("DIDSA_SERVERS_PATH", "user://servers_scan_test.cfg")
	DirAccess.remove_absolute(SETTINGS)
	var packed: PackedScene = load("res://scenes/main.tscn")
	var main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	main.landing_enabled = true
	root.add_child(main)
	await frames(2)
	main.get_node("XROrigin3D/XRCamera3D").position = Vector3(0.0, 1.6, 0.0)
	await frames(3)
	var launcher = main.landing.launcher
	var scanner = main.landing.scanner
	check("the landing owns a scanner, not listening yet", scanner != null and not scanner.running)

	launcher.show_page("servers")
	await frames(2)
	launcher._body.find_child("Scan", true, false).pressed.emit()
	await frames(2)
	check("Scan opens its page and starts listening", launcher.page == "scan" and scanner.running)
	check("the page says what the headset answered, step by step", "OpenXR running: no" in launcher._scan_report.text and "Listening: yes" in launcher._scan_report.text and "OpenXR is not running" in launcher._scan_report.text)
	check("it tells you to turn passthrough on and to look at DIDSA-CAD's Connect a VR headset", "Connect a VR headset" in _all_text(launcher._body) and "passthrough" in _all_text(launcher._body).to_lower())

	var step: Label = launcher._body.find_child("ScanStep", true, false)
	check("the first line says what to do now: turn passthrough on", step != null and step.text.begins_with("Step 1 of 3") and "passthrough" in step.text and launcher._body.get_child(0) == step)
	launcher._body.find_child("Passthrough", true, false).pressed.emit()
	await frames(1)
	check("with passthrough on it says to look at the QR code, on the monolith and the status line", step.text.begins_with("Step 2 of 3") and "look at the QR code" in step.text and "look at the QR code" in main.status_text)
	var valid := "didsa-vr:1?n=Workshop+PC&u=https%3A%2F%2Fcad.example.net&k=TOPSECRETKEY"
	scanner.feed(valid)
	await frames(1)
	check("once a code is read it says so and asks you to confirm with Connect (in green)", step.text.begins_with("Step 3 of 3") and "Connect" in step.text and step.get_theme_color("font_color").g > 0.9)
	launcher._body.find_child("CardCancel", true, false).pressed.emit()
	await frames(1)
	check("Cancel goes back to looking at the code", step.text.begins_with("Step 2 of 3"))
	launcher._body.find_child("Passthrough", true, false).pressed.emit()
	await frames(1)
	scanner._last_seen_ms -= 5000
	scanner.feed(valid)
	await frames(1)
	check("a good code is described by name and host", "Read a DIDSA pairing code for Workshop PC (cad.example.net)" in launcher._scan_read.text)
	check("the code itself, and so its key, is never put on screen", not ("TOPSECRETKEY" in _all_text(launcher._body)) and not ("TOPSECRETKEY" in launcher._scan_report.text))
	scanner.feed("https://example.com/menu")
	await frames(1)
	check("another QR code is called not ours and ignored", "not a DIDSA pairing code" in launcher._scan_read.text and "24 characters" in launcher._scan_read.text)
	scanner.feed("didsa-vr:1?u=http%3A%2F%2Fexample.com&k=k")
	await frames(1)
	check("our code with a refused address says why", "refused" in launcher._scan_read.text and "https" in launcher._scan_read.text)
	check("the report counts what was read (the good code twice, around a Cancel)", "QR codes read: 4" in launcher._scan_report.text)

	# passthrough toggle
	var before: String = main.current_scene()
	launcher._body.find_child("Passthrough", true, false).pressed.emit()
	await frames(2)
	check("the passthrough button turns it on", main.current_scene() == "Passthrough" and "ON" in launcher._body.find_child("Passthrough", true, false).text)
	launcher._body.find_child("Passthrough", true, false).pressed.emit()
	await frames(2)
	check("...and off again, back to the scene it was", main.current_scene() == before and "off" in launcher._body.find_child("Passthrough", true, false).text)
	launcher._body.find_child("Passthrough", true, false).pressed.emit()
	await frames(1)
	launcher._back.pressed.emit()
	await frames(2)
	check("Back stops listening, leaves the page and puts the scene back", launcher.page == "home" and not scanner.running and main.current_scene() == before)

	# closing while scanning
	launcher.show_page("scan")
	await frames(2)
	check("scanning again", scanner.running)
	launcher.close()
	await frames(1)
	check("closing the launcher stops listening", not scanner.running)
	launcher.open()
	await frames(2)
	check("it reopens on Home, not on Scan", launcher.page == "home" and not scanner.running)

	# project settings
	var project := ConfigFile.new()
	check("project.godot loads", project.load("res://project.godot") == OK)
	var keys := ["openxr/extensions/spatial_entity/enabled.android", "openxr/extensions/spatial_entity/enable_marker_tracking.android", "openxr/extensions/spatial_entity/enable_builtin_marker_tracking.android"]
	var all_on := true
	for k in keys:
		all_on = all_on and project.get_value("xr", k, false) == true
	check("project.godot turns on spatial-entity marker tracking for Android builds", all_on)
	check("...and not for desktop or PC-VR builds (the plain settings stay off)", ProjectSettings.get_setting("xr/openxr/extensions/spatial_entity/enabled") == false and ProjectSettings.get_setting("xr/openxr/extensions/spatial_entity/enable_marker_tracking") == false)

	main.queue_free()
	await frames(2)
	for path in [SETTINGS, "user://recent_scan_test.cfg", "user://servers_scan_test.cfg"]:
		DirAccess.remove_absolute(path)
	print("SMOKE PASSED")
	quit()


func _all_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	elif node is Button:
		out += (node as Button).text + "\n"
	for child in node.get_children():
		out += _all_text(child)
	return out
