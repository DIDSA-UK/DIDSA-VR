extends Node
## Reads QR codes with the headset's own marker tracking: OpenXR spatial-entity marker tracking, which is in Godot's core (4.7), so no addon and no camera
## access. The headset's runtime finds and decodes the code; Godot hands over an OpenXRMarkerTracker whose marker data is the text.
## docs/landing-scope.md, "QR code: viable, and probably without a plugin" (route A). Needs, on a Quest: Horizon OS with marker tracking (v83 or later
## was reported to work with Godot 4.6), the project's spatial-entity settings (project.godot, Android only), the scene permission, and passthrough so a
## person can see the screen the code is on. NONE OF THAT HAS BEEN RUN ON A HEADSET: step L5 of the scope is exactly to find out, and report() says what
## this headset answered at each stage so the first run explains itself.
##
## The scanner only produces text; what the text means is pairing_payload.gd's, and nothing here saves anything.

signal code_seen(text: String) ## a QR code's text was read (again, only when it changed or after a gap)
signal report_changed ## something the report() shows changed

const CAPABILITY := "OpenXRSpatialMarkerTrackingCapability"
const SCENE_PERMISSION := "com.oculus.permission.USE_SCENE" ## what Meta's spatial entities ask for; unconfirmed for marker tracking (an L5 question)
const POLL_SECONDS := 0.5
const SAME_CODE_GAP_SECONDS := 3.0 ## the same text is reported again after it has not been seen for this long

var running := false
var codes_seen := 0 ## distinct reads of a QR code
var other_markers := 0 ## markers that are not QR codes (ArUco and so on)
var trackers_seen := 0 ## distinct marker trackers
var _seen_names := {}
var last_text := ""
var notes: PackedStringArray = []
var _last_seen_ms := 0
var _poll_left := 0.0
var _permission_state := "not asked"
var _qr_supported: Variant = null ## bool once asked, null until then


func probe() -> Dictionary:
	## What this device answers, without starting: {openxr: bool, capability: bool, qr_supported: Variant, permission: String}. Safe anywhere (a desktop
	## build with no headset answers "no").
	var interface := XRServer.find_interface("OpenXR")
	var has_openxr: bool = interface != null and interface.is_initialized()
	var has_capability := Engine.has_singleton(CAPABILITY)
	var supported: Variant = null
	if has_capability and has_openxr: # without a running OpenXR session the capability answers false: that is not a finding (a desktop build has the singleton too)
		var capability: Object = Engine.get_singleton(CAPABILITY)
		if capability != null and capability.has_method("is_qrcode_supported"):
			supported = bool(capability.call("is_qrcode_supported"))
	_qr_supported = supported
	return {"openxr": has_openxr, "capability": has_capability, "qr_supported": supported, "permission": _permission_state}


func start() -> void:
	## Begin listening. Asks for the scene permission on Android (the answer arrives later: report() shows it).
	if running:
		return
	running = true
	notes.clear()
	_seen_names.clear()
	trackers_seen = 0
	other_markers = 0
	if OS.get_name() == "Android":
		_permission_state = "asked"
		OS.request_permission(SCENE_PERMISSION)
		if not get_tree().on_request_permissions_result.is_connected(_on_permission_result):
			get_tree().on_request_permissions_result.connect(_on_permission_result)
	var status := probe()
	if not status["openxr"]:
		notes.append("OpenXR is not running, so no headset can read a code. (A flat desktop preview cannot scan.)")
	elif not status["capability"]:
		notes.append("This build has no marker-tracking capability (the project's spatial-entity settings may be off, or the headset does not offer it).")
	elif status["qr_supported"] == false:
		notes.append("The headset says it cannot read QR codes (Horizon OS too old, or the permission was not granted).")
	if not XRServer.tracker_added.is_connected(_on_tracker):
		XRServer.tracker_added.connect(_on_tracker)
		XRServer.tracker_updated.connect(_on_tracker)
	for tracker_name in XRServer.get_trackers(XRServer.TRACKER_ANY):
		_on_tracker(tracker_name, XRServer.TRACKER_ANY)
	report_changed.emit()


func stop() -> void:
	if not running:
		return
	running = false
	if XRServer.tracker_added.is_connected(_on_tracker):
		XRServer.tracker_added.disconnect(_on_tracker)
		XRServer.tracker_updated.disconnect(_on_tracker)
	report_changed.emit()


func report() -> String:
	## Plain lines for the Scan page: each stage and what the headset said.
	var status := probe()
	var lines := PackedStringArray()
	lines.append("OpenXR running: %s" % _yes_no(status["openxr"]))
	lines.append("Marker tracking present: %s" % (_yes_no(status["capability"]) if status["openxr"] else "not known without OpenXR"))
	lines.append("QR codes supported: %s" % ("not asked" if status["qr_supported"] == null else _yes_no(status["qr_supported"])))
	lines.append("Scene permission: %s" % _permission_state)
	lines.append("Listening: %s" % _yes_no(running))
	lines.append("Trackers seen: %d, QR codes read: %d, other markers: %d" % [trackers_seen, codes_seen, other_markers])
	lines.append_array(notes)
	return "\n".join(lines)


func _process(delta: float) -> void:
	if not running:
		return
	_poll_left -= delta
	if _poll_left > 0.0:
		return
	_poll_left = POLL_SECONDS
	# Markers whose data changed without a signal (not known whether the runtime sends one) are caught here.
	for tracker_name in XRServer.get_trackers(XRServer.TRACKER_ANY):
		_on_tracker(tracker_name, XRServer.TRACKER_ANY)
	report_changed.emit()


func feed(text: String) -> void:
	## A QR code's text, from the headset or (tests, a pasted code) from anywhere: reported once per read.
	var now := Time.get_ticks_msec()
	var fresh := text != last_text or now - _last_seen_ms > int(SAME_CODE_GAP_SECONDS * 1000.0)
	_last_seen_ms = now
	if text == "" or not fresh:
		return
	last_text = text
	codes_seen += 1
	code_seen.emit(text)
	report_changed.emit()


func _on_tracker(tracker_name: StringName, _type: int) -> void:
	var tracker := XRServer.get_tracker(tracker_name)
	if not tracker is OpenXRMarkerTracker:
		return
	var marker := tracker as OpenXRMarkerTracker
	if not _seen_names.has(tracker_name):
		_seen_names[tracker_name] = marker.get_marker_type()
		trackers_seen = _seen_names.size()
		if marker.get_marker_type() != OpenXRSpatialComponentMarkerList.MARKER_TYPE_QRCODE:
			other_markers += 1
		report_changed.emit()
	if marker.get_marker_type() != OpenXRSpatialComponentMarkerList.MARKER_TYPE_QRCODE:
		return
	var data: Variant = marker.get_marker_data()
	var text := ""
	if data is String:
		text = data
	elif data is PackedByteArray:
		text = (data as PackedByteArray).get_string_from_utf8()
	if text != "":
		feed(text)


func _on_permission_result(permission: String, granted: bool) -> void:
	if permission == SCENE_PERMISSION:
		_permission_state = "granted" if granted else "refused"
		report_changed.emit()


static func _yes_no(value: Variant) -> String:
	return "yes" if value else "no"
