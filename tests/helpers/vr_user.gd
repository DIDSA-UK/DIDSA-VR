extends RefCounted
## A person at the headset, for tests (not a test): two fake OpenXR hand trackers (XRServer) feed the app's real XRController3D nodes, so a press, a stick push or a
## hand pose reaches controller.gd exactly as a Quest's would (button_pressed signals, get_vector2, global_transform). Drives the tool wheel by chord and hand
## offset like a hand does. Needs the scene tree, the main scene and (for pictures) a real renderer (xvfb-run).

const TopologyPick := preload("res://scripts/topology_pick.gd")
const DriveTool := preload("res://scripts/drive_tool.gd")

const SIDES := {"left": "left_hand", "right": "right_hand"}

var tree: SceneTree
var main: Node
var origin: XROrigin3D
var camera: XRCamera3D
var trackers := {}
var eye: Camera3D
var shots_dir := ""
var _shot_index := 0


func _init(p_tree: SceneTree, p_main: Node) -> void:
	tree = p_tree
	main = p_main
	origin = main.get_node("XROrigin3D")
	camera = origin.get_node("XRCamera3D")
	for side in SIDES:
		var tracker := XRPositionalTracker.new()
		tracker.name = SIDES[side]
		tracker.type = XRServer.TRACKER_CONTROLLER
		tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT if side == "left" else XRPositionalTracker.TRACKER_HAND_RIGHT
		XRServer.add_tracker(tracker)
		trackers[side] = tracker
	set_hand("left", Transform3D(Basis.IDENTITY, Vector3(-0.3, 1.1, -0.4)))
	set_hand("right", Transform3D(Basis.IDENTITY, Vector3(0.3, 1.1, -0.4)))


func hand(side: String) -> XRController3D:
	return origin.get_node("LeftController" if side == "left" else "RightController")


func frames(n: int = 2) -> void:
	for i in n:
		await tree.process_frame


func set_hand(side: String, transform: Transform3D) -> void:
	## Where the hand is, in the tracking space (the XROrigin3D's frame).
	(trackers[side] as XRPositionalTracker).set_pose("default", transform, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func aim(side: String, from: Vector3, target: Vector3) -> void:
	## The hand at `from` with the laser (its -Z) pointing at `target`; both in the world.
	var inv := origin.global_transform.affine_inverse()
	var f := inv * from
	var t := inv * target
	var basis := Basis.looking_at((t - f).normalized(), Vector3.UP if absf((t - f).normalized().y) < 0.98 else Vector3.RIGHT)
	set_hand(side, Transform3D(basis, f))


func press(side: String, action: String) -> void:
	(trackers[side] as XRPositionalTracker).set_input(action, true)


func release(side: String, action: String) -> void:
	(trackers[side] as XRPositionalTracker).set_input(action, false)


func click(side: String, action: String = "trigger_click", hold_frames: int = 3) -> void:
	press(side, action)
	await frames(hold_frames)
	release(side, action)
	await frames(2)


func stick(side: String, value: Vector2) -> void:
	(trackers[side] as XRPositionalTracker).set_input("primary", value)


func chord(side: String = "right") -> void:
	## Grip then trigger within the wheel window: opens the tool wheel on that hand.
	press(side, "grip_click")
	await frames(1)
	press(side, "trigger_click")
	await frames(3)


func _wheel_hand_to(wheel, side: String, entries: Array, entry_id: String, radius: float) -> bool:
	## Moves the hand (relative to the ring's centre) towards the named wedge; false if the ring has none.
	var index := -1
	for i in entries.size():
		if str(entries[i]["id"]) == entry_id:
			index = i
	if index < 0:
		return false
	var angle := TAU * index / float(entries.size())
	var offset := Vector2(sin(angle), cos(angle)) * radius
	var target: Vector3 = wheel._anchor + wheel._right * offset.x + wheel._up * offset.y
	var inv := origin.global_transform.affine_inverse()
	set_hand(side, Transform3D((trackers[side] as XRPositionalTracker).get_pose("default").transform.basis, inv * target))
	return true


func wheel_pick(path, side: String = "right") -> bool:
	## Opens the tool wheel (chord) and walks `path` (a wedge id, or ids of nested sub-wheels then the wedge): a hand travels OUT to open a sub-wheel and
	## rests short of the rim on the last wedge; letting go chooses it. False (and the wheel closed) if a ring has no such wedge.
	var wheel = main.get_node("ToolWheel")
	var ids: Array = path if path is Array else [path]
	await chord(side)
	for k in ids.size():
		var last: bool = k == ids.size() - 1
		var entries: Array = wheel.current_entries()
		if not _wheel_hand_to(wheel, side, entries, str(ids[k]), 0.12 if last else 0.30):
			release(side, "trigger_click")
			release(side, "grip_click")
			await frames(3)
			return false
		await frames(4)
	release(side, "trigger_click")
	release(side, "grip_click")
	await frames(4)
	return true


func spread_hands_until(target_scale: float, max_frames: int = 400) -> float:
	## Both grips on empty space and the hands pulled apart (or pushed together) until the model's scale reaches `target_scale` (the real two-hand gesture).
	var root_node: Node3D = main.assembly_root
	var height := 1.15
	var half := 0.12
	set_hand("left", Transform3D(Basis.IDENTITY, Vector3(-half, height, -0.45)))
	set_hand("right", Transform3D(Basis.IDENTITY, Vector3(half, height, -0.45)))
	await frames(3)
	press("left", "grip_click")
	press("right", "grip_click")
	await frames(3)
	var n := 0
	while n < max_frames and absf(root_node.scale.x - target_scale) / target_scale > 0.03:
		half *= 1.03 if root_node.scale.x < target_scale else 0.97
		half = clampf(half, 0.05, 0.6)
		set_hand("left", Transform3D(Basis.IDENTITY, Vector3(-half, height, -0.45)))
		set_hand("right", Transform3D(Basis.IDENTITY, Vector3(half, height, -0.45)))
		await frames(1)
		n += 1
	release("left", "grip_click")
	release("right", "grip_click")
	await frames(3)
	return root_node.scale.x


func wheel_pill(side: String = "right") -> void:
	## Opens the wheel and lets go on the pill under the ring (Clear tool: hands free).
	var wheel = main.get_node("ToolWheel")
	await chord(side)
	var target: Vector3 = wheel._anchor + wheel._right * 0.0 + wheel._up * -0.26
	var inv := origin.global_transform.affine_inverse()
	set_hand(side, Transform3D((trackers[side] as XRPositionalTracker).get_pose("default").transform.basis, inv * target))
	await frames(4)
	release(side, "trigger_click")
	release(side, "grip_click")
	await frames(4)


func shot(name: String) -> void:
	## A picture from the player's eye (needs a real renderer; a no-op without a directory).
	if shots_dir == "":
		return
	if eye == null:
		eye = Camera3D.new()
		eye.fov = 70.0
		main.add_child(eye)
	eye.global_transform = camera.global_transform
	eye.make_current()
	await frames(3)
	var image := tree.root.get_texture().get_image()
	_shot_index += 1
	image.save_png("%s/%02d_%s.png" % [shots_dir, _shot_index, name])


func round_face_target(part: Node3D) -> Dictionary:
	## The first round (cylinder) face of a part: {wall (a point on it, world), axis_dir (unit, world), centre (a point on the axis, world), triangle}.
	if not part.has_meta("topology"):
		return {}
	var topology: Dictionary = part.get_meta("topology")
	var face_ids: Array = part.get_meta("face_ids")
	var body_ids: Array = part.get_meta("body_ids")
	var faces: PackedVector3Array = (part as MeshInstance3D).mesh.get_faces()
	for body in topology:
		var kinds: Array = (topology[body] as Dictionary).get("face_kinds", [])
		for t in face_ids.size():
			var f := int(face_ids[t])
			if str(body_ids[t]) == str(body) and f >= 0 and f < kinds.size() and str(kinds[f]) == "cylinder":
				var wall: Vector3 = part.global_transform * ((faces[t * 3] + faces[t * 3 + 1] + faces[t * 3 + 2]) / 3.0)
				var axis: Dictionary = DriveTool.axis_of(part, TopologyPick.face_entity(part, t))
				if axis.is_empty():
					continue
				return {"wall": wall, "axis_dir": (part.global_transform.basis * (axis["dir"] as Vector3)).normalized(), "centre": part.global_transform * (axis["origin"] as Vector3), "triangle": t}
	return {}


func aim_into_round_face(part: Node3D, side: String = "right") -> bool:
	## The hand 0.35 m from the part, above its round face, the laser aimed at its wall through the opening (a bore); false if it has no round face.
	var info := round_face_target(part)
	if info.is_empty():
		return false
	var axis_dir: Vector3 = info["axis_dir"]
	var centre: Vector3 = info["centre"]
	var wall: Vector3 = info["wall"]
	var toward_user: Vector3 = axis_dir if axis_dir.dot(camera.global_position - centre) > 0.0 else -axis_dir
	aim(side, centre + toward_user * 0.35 - (wall - centre).normalized() * 0.002, wall)
	await frames(3)
	return true


func frame_camera(centre: Vector3, distance: float = 0.9, height: float = 0.25) -> void:
	## Stands the player in front of the model looking at `centre`.
	camera.position = centre + Vector3(0.0, height, distance)
	camera.look_at(centre)
