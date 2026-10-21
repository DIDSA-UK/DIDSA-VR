extends SceneTree
## The QR scanner (docs/landing-scope.md L5; scripts/landing/qr_scanner.gd), headless: what it reports when there is no headset (which is every
## headless run), and the real path a headset uses, driven by hand: a genuine OpenXRMarkerTracker added to the XRServer with a QR code's text is read
## (and once, not on every poll), a second code is read, other marker types are counted and not read, stopping really stops. WHAT IT CANNOT SAY: whether
## a Quest answers is_qrcode_supported(), which permission it needs, or whether the runtime ever creates a tracker for a code on a screen. That is
## step L5 itself and needs the headset (docs/servers.md, "Scanning a QR code").
## Run: "$GODOT" --headless --path . --script res://tests/qr_scanner.gd

const Scanner := preload("res://scripts/landing/qr_scanner.gd")

var seen: Array[String] = []


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func marker(tracker_name: String, type: int, data: Variant) -> OpenXRMarkerTracker:
	var tracker := OpenXRMarkerTracker.new()
	tracker.set_tracker_name(StringName(tracker_name))
	tracker.set_tracker_type(XRServer.TRACKER_ANCHOR)
	tracker.set_marker_type(type)
	tracker.set_marker_data(data)
	return tracker


func _initialize() -> void:
	var scanner := Scanner.new()
	root.add_child(scanner)
	scanner.code_seen.connect(func(text: String) -> void: seen.append(text))
	await process_frame

	var status := scanner.probe()
	check("no headset: OpenXR is not running and no support is claimed (the capability exists in the build and would say false: not a finding)", not status["openxr"] and status["qr_supported"] == null)
	check("the report says each stage in words", "OpenXR running: no" in scanner.report() and "QR codes supported: not asked" in scanner.report() and "Listening: no" in scanner.report())
	scanner.start()
	check("started with no headset: it says why it cannot scan", scanner.running and "OpenXR is not running" in scanner.report())
	scanner.start()
	check("starting twice does nothing more", scanner.running)

	# the path a headset uses: a marker tracker appears in the XRServer
	var code := "didsa-vr:1?n=Workshop+PC&u=https%3A%2F%2Fcad.example.net&k=abc"
	var qr := marker("marker_qr_1", OpenXRSpatialComponentMarkerList.MARKER_TYPE_QRCODE, code)
	XRServer.add_tracker(qr)
	await process_frame
	check("a QR marker appearing is read", seen == [code] and scanner.codes_seen == 1 and scanner.trackers_seen == 1 and scanner.last_text == code)
	await create_timer(1.2).timeout # a few polls
	check("polling the same marker does not read it again", seen.size() == 1 and scanner.codes_seen == 1)
	XRServer.add_tracker(marker("marker_qr_2", OpenXRSpatialComponentMarkerList.MARKER_TYPE_QRCODE, "https://example.com/not-ours"))
	await process_frame
	check("a different code is read too (the page decides what it means)", seen.size() == 2 and seen[1] == "https://example.com/not-ours" and scanner.trackers_seen == 2)
	XRServer.add_tracker(marker("marker_aruco_7", OpenXRSpatialComponentMarkerList.MARKER_TYPE_ARUCO, 7))
	await process_frame
	check("an ArUco marker is counted and not read", seen.size() == 2 and scanner.other_markers == 1 and scanner.trackers_seen == 3)
	var bytes := marker("marker_qr_3", OpenXRSpatialComponentMarkerList.MARKER_TYPE_QRCODE, "bytes".to_utf8_buffer())
	XRServer.add_tracker(bytes)
	await process_frame
	check("a code delivered as bytes is read as text", seen.size() == 3 and seen[2] == "bytes")
	check("the report counts them", "Trackers seen: 4, QR codes read: 3, other markers: 1" in scanner.report())

	# the same text again after a gap is a new read; immediately it is not
	scanner.feed("again")
	scanner.feed("again")
	check("the same text twice in a row is one read", seen.size() == 4)
	scanner._last_seen_ms -= int((Scanner.SAME_CODE_GAP_SECONDS + 1.0) * 1000.0)
	scanner.feed("again")
	check("...and a read again after the code was out of sight for a while", seen.size() == 5)
	scanner.feed("")
	check("empty text is nothing", seen.size() == 5)

	scanner.stop()
	check("stopped: listening is off", not scanner.running and "Listening: no" in scanner.report())
	XRServer.add_tracker(marker("marker_qr_4", OpenXRSpatialComponentMarkerList.MARKER_TYPE_QRCODE, "after stop"))
	await process_frame
	await create_timer(0.7).timeout
	check("stopped: a marker appearing is not read", seen.size() == 5)
	scanner.start()
	await process_frame
	check("started again: markers already there are picked up (and counted afresh)", scanner.running and "after stop" in seen and scanner.trackers_seen == 5)
	scanner.stop()
	for t in ["marker_qr_1", "marker_qr_2", "marker_aruco_7", "marker_qr_3", "marker_qr_4"]:
		XRServer.remove_tracker(XRServer.get_tracker(StringName(t)))
	print("SMOKE PASSED")
	quit()
