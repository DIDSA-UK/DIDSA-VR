extends Node3D
## An AR reticle round every QR code the headset is tracking while the Scan page listens (owner's request, 22 Oct 2026: "it wasn't clear that it was
## reading"): four corner brackets on the code itself, seen through passthrough, and a line under it. Amber and breathing while it is being read, green
## for a DIDSA pairing code (with its name: press Connect), red for a DIDSA code that was refused, grey for any other QR code. Drawn on top of everything
## and never fogged. It lives under the XROrigin3D, because a marker's pose is in the origin's space.
##
## The code's plane: the brackets lie in the X / Y plane of the marker's "default" pose, sized by its bounds_size (OpenXR's bounded-2D extents).
## NOT yet seen on a headset: if they stand at right angles to the code there, the plane is X / Z instead (one line, _frame()).

const PairingPayload := preload("res://scripts/landing/pairing_payload.gd")
const MARGIN := 1.18 ## the brackets sit this much outside the code
const ARM := 0.3 ## each bracket arm, as a fraction of the side
const BAR := 0.006 ## metres: the brackets' line width
const COLOURS := {"reading": Color(1.0, 0.78, 0.35), "ok": Color(0.45, 0.95, 0.55), "refused": Color(1.0, 0.42, 0.35), "other": Color(0.72, 0.76, 0.82)}

var scanner: Node ## qr_scanner.gd: the reticle shows only while it is running
var reticles := {} ## tracker name -> {node: Node3D, frame: Node3D, label: Label3D, size: Vector2, state: String}
var _clock := 0.0


func _process(delta: float) -> void:
	_clock += delta
	if scanner == null or not scanner.running:
		clear()
		return
	var seen := {}
	for tracker_name in XRServer.get_trackers(XRServer.TRACKER_ANY):
		var marker := XRServer.get_tracker(tracker_name) as OpenXRMarkerTracker
		if marker == null or marker.get_marker_type() != OpenXRSpatialComponentMarkerList.MARKER_TYPE_QRCODE:
			continue
		seen[tracker_name] = true
		if not reticles.has(tracker_name):
			reticles[tracker_name] = _make()
		_update(reticles[tracker_name], marker)
	for tracker_name in reticles.keys():
		if not seen.has(tracker_name):
			(reticles[tracker_name]["node"] as Node3D).queue_free()
			reticles.erase(tracker_name)


func clear() -> void:
	for tracker_name in reticles:
		(reticles[tracker_name]["node"] as Node3D).queue_free()
	reticles.clear()


static func state_of(text: String) -> Dictionary:
	## {state, text}: what a code's text is, for the colour and the line under it (pure, for the test). Never shows the code itself: it carries a key.
	if text == "":
		return {"state": "reading", "text": "Reading..."}
	if not PairingPayload.looks_like_pairing(text):
		return {"state": "other", "text": "Not a DIDSA code"}
	var parsed := PairingPayload.parse(text)
	if not parsed["ok"]:
		return {"state": "refused", "text": "DIDSA code refused: see the Scan page"}
	return {"state": "ok", "text": "%s: read. Press Connect." % parsed["name"]}


func _make() -> Dictionary:
	var node := Node3D.new()
	node.name = "Reticle"
	add_child(node)
	var frame := Node3D.new()
	frame.name = "Frame"
	node.add_child(frame)
	var label := Label3D.new()
	label.name = "Label"
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.render_priority = 11
	label.fixed_size = false
	label.pixel_size = 0.0009
	label.font_size = 40
	label.outline_size = 10
	label.outline_modulate = Color(0, 0, 0, 0.8)
	node.add_child(label)
	return {"node": node, "frame": frame, "label": label, "size": Vector2.ZERO, "state": ""}


func _update(reticle: Dictionary, marker: OpenXRMarkerTracker) -> void:
	var node: Node3D = reticle["node"]
	var pose := marker.get_pose(&"default")
	var tracking := marker.get_spatial_tracking_state() == OpenXRSpatialEntityTracker.ENTITY_TRACKING_STATE_TRACKING and pose != null and pose.has_tracking_data
	node.visible = tracking
	if not tracking:
		return
	node.transform = pose.transform
	var size: Vector2 = marker.bounds_size if marker.bounds_size.x > 0.01 and marker.bounds_size.y > 0.01 else Vector2(0.15, 0.15)
	var data: Variant = marker.get_marker_data()
	var text: String = data if data is String else ((data as PackedByteArray).get_string_from_utf8() if data is PackedByteArray else "")
	var look := state_of(text)
	if look["state"] != reticle["state"] or not size.is_equal_approx(reticle["size"]):
		_frame(reticle["frame"], size, COLOURS[look["state"]])
		reticle["state"] = look["state"]
		reticle["size"] = size
	var label: Label3D = reticle["label"]
	label.text = look["text"]
	label.modulate = COLOURS[look["state"]]
	label.position = Vector3(0.0, -size.y * MARGIN * 0.5 - 0.04, 0.0)
	var breathe := 1.0 + (0.05 * sin(_clock * TAU / 1.2) if look["state"] == "reading" else 0.0) # amber breathes while it is being read
	(reticle["frame"] as Node3D).scale = Vector3(breathe, breathe, 1.0)


func _frame(frame: Node3D, size: Vector2, colour: Color) -> void:
	## Four corner brackets round a size.x by size.y code, in the X / Y plane.
	for child in frame.get_children():
		child.queue_free()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = colour
	material.no_depth_test = true # seen through the screen the code is on, and through anything virtual in front of it
	material.disable_fog = true
	material.render_priority = 10
	var half := size * MARGIN * 0.5
	var arm := minf(size.x, size.y) * MARGIN * ARM
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner := Vector3(half.x * sx, half.y * sy, 0.0)
			_bar(frame, material, Vector3(arm, BAR, BAR), corner - Vector3(sx * arm * 0.5, 0.0, 0.0)) # along x, back from the corner
			_bar(frame, material, Vector3(BAR, arm, BAR), corner - Vector3(0.0, sy * arm * 0.5, 0.0)) # along y


func _bar(frame: Node3D, material: Material, extent: Vector3, at: Vector3) -> void:
	var mesh := BoxMesh.new()
	mesh.size = extent
	mesh.material = material
	var bar := MeshInstance3D.new()
	bar.mesh = mesh
	bar.position = at
	bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	frame.add_child(bar)
