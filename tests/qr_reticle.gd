extends SceneTree
## The QR reticle and the Scan page's live search line (docs/quest-first-run-fixes.md B6: "it wasn't clear that it was reading"), full scene with the
## landing on and no headset: real OpenXRMarkerTracker objects added to the XRServer as the headset's marker tracking adds them. Brackets appear on a
## tracked code in the origin's space at the code's size (amber, breathing, "Reading..." while it has no text; green with the server's name for a DIDSA
## code, which also raises the Connect card; grey for another QR code; red for a refused DIDSA code), hide while the code is paused, go when it goes and
## when the scanner stops; the step line says a code is in view; the report says whether the scanner's own search runs. Cannot check: that the brackets
## sit on the code on a real headset (the plane of the marker's pose), or the own search itself (it needs the headset's spatial entities).
## Run: "$GODOT" --headless --path . --script res://tests/qr_reticle.gd

const QrReticle := preload("res://scripts/landing/qr_reticle.gd")
const GOOD := "didsa-vr:1?n=Workshop+PC&u=https%3A%2F%2Fcad.example.net&k=TOPSECRETKEY"

var main


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(count: int = 3) -> void:
	for i in count:
		await process_frame


func marker(tracker_name: String, data: Variant, at: Transform3D, size: Vector2) -> OpenXRMarkerTracker:
	var tracker := OpenXRMarkerTracker.new()
	tracker.name = tracker_name
	tracker.set_marker_type(OpenXRSpatialComponentMarkerList.MARKER_TYPE_QRCODE)
	tracker.set_marker_data(data)
	tracker.bounds_size = size
	tracker.set_spatial_tracking_state(OpenXRSpatialEntityTracker.ENTITY_TRACKING_STATE_TRACKING)
	tracker.set_pose(&"default", at, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	XRServer.add_tracker(tracker)
	return tracker


func _initialize() -> void:
	OS.set_environment("DIDSA_SETTINGS_PATH", "user://settings_reticle_test.cfg")
	OS.set_environment("DIDSA_RECENT_PATH", "user://recent_reticle_test.cfg")
	OS.set_environment("DIDSA_SERVERS_PATH", "user://servers_reticle_test.cfg")
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	main.landing_enabled = true
	root.add_child(main)
	await frames(2)
	main.get_node("XROrigin3D/XRCamera3D").position = Vector3(0.0, 1.6, 0.0)
	await frames(3)
	var landing = main.landing
	var launcher = landing.launcher
	var scanner = landing.scanner
	var reticle: Node3D = landing.reticle
	check("the reticle lives under the XR origin (marker poses are in its space)", reticle != null and reticle.get_parent() == main.get_node("XROrigin3D"))

	# not listening: nothing drawn even with a code tracked
	var at := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.4, -0.9))
	var code := marker("qr_test_1", "", at, Vector2(0.2, 0.2))
	await frames(2)
	check("while the Scan page is shut, no brackets", reticle.reticles.is_empty())

	launcher.show_page("scan")
	await frames(2)
	check("the report says whether the scanner's own search runs (not without a headset) and how many codes are in view", "Searching every 1 s: no" in scanner.report() and "Codes in view now: 1" in scanner.report())
	launcher._body.find_child("Passthrough", true, false).pressed.emit()
	await frames(2)
	check("listening: brackets on the tracked code", reticle.reticles.size() == 1)
	var one: Dictionary = reticle.reticles.values()[0]
	var node: Node3D = one["node"]
	check("...placed at the code's pose, in the origin's space", node.visible and node.transform.origin.is_equal_approx(at.origin))
	var bars: Array = one["frame"].get_children()
	var widest := 0.0
	for bar in bars:
		widest = maxf(widest, absf((bar as Node3D).position.x))
	check("...four corners of two arms each, just outside a 20 cm code", bars.size() == 8 and widest > 0.08 and widest < 0.13)
	check("...amber and 'Reading...' while it has no text yet", one["state"] == "reading" and one["label"].text == "Reading..." and one["label"].modulate.is_equal_approx(QrReticle.COLOURS["reading"]))
	launcher._refresh_scan()
	check("the step line says a code is in view and is being read", "a code is in view" in launcher._scan_step.text)

	code.set_marker_data(GOOD)
	await create_timer(0.7).timeout # the scanner polls trackers twice a second (headless frames run far faster than that)
	await frames(2)
	one = reticle.reticles.values()[0]
	check("a DIDSA code turns the brackets green with the server's name", one["state"] == "ok" and "Workshop PC" in one["label"].text and "Connect" in one["label"].text)
	check("...the key is not on the label", not ("TOPSECRETKEY" in one["label"].text))
	check("...and the scanner read it: the Connect card is up, step 3", launcher._scan_card.find_child("CardTitle", true, false) != null and launcher._scan_step.text.begins_with("Step 3"))

	code.set_marker_data("https://example.com/menu")
	await frames(2)
	check("another QR code: grey, 'Not a DIDSA code'", reticle.reticles.values()[0]["state"] == "other" and reticle.reticles.values()[0]["label"].text == "Not a DIDSA code")
	check("a refused DIDSA code would be red", QrReticle.state_of("didsa-vr:1?u=http%3A%2F%2Fexample.com&k=k")["state"] == "refused")

	code.set_spatial_tracking_state(OpenXRSpatialEntityTracker.ENTITY_TRACKING_STATE_PAUSED)
	await frames(2)
	check("a paused code (out of view) hides its brackets", not node.visible)
	code.set_spatial_tracking_state(OpenXRSpatialEntityTracker.ENTITY_TRACKING_STATE_TRACKING)
	var second := marker("qr_test_2", GOOD, Transform3D(Basis.IDENTITY, Vector3(-0.3, 1.5, -1.0)), Vector2(0.1, 0.1))
	await frames(2)
	check("two codes: two reticles", reticle.reticles.size() == 2)
	XRServer.remove_tracker(second)
	await frames(2)
	check("a code that goes takes its brackets with it", reticle.reticles.size() == 1)

	launcher.show_page("servers") # leaving the Scan page stops the scanner
	await frames(2)
	check("leaving the Scan page clears the brackets", reticle.reticles.is_empty() and not scanner.running)

	XRServer.remove_tracker(code)
	main.queue_free()
	await frames(2)
	print("SMOKE PASSED")
	quit()
