extends Node3D
## The other people in a live session, drawn from their presence (DIDSA-CAD docs/live-sessions-scope.md, 4.4 and 4.8; decision D6): a head, two controllers with the laser, a name tag that
## faces whoever looks at it, one colour each (the hub's palette). Presence arrives in MODEL space (mm); each avatar is put into the world through THIS person's view of the model
## (the glb root's transform), so it stands where that person stands relative to the model whatever scale and place the model has here; its own size stays that of a person.
## Rendered one interval behind (70 ms at 15 Hz) between the last two samples by the hub's `at`; a gap over 500 ms snaps. This person's own avatar is never drawn.
## Not shown: a participant the hub says is not connected, or one with no presence yet. Cheap: at most six, a few meshes each.

const Protocol := preload("res://scripts/session/session_protocol.gd")

const DELAY_MS := 70.0
const SNAP_GAP_MS := 500.0
const HEAD_RADIUS := 0.10
const TAG_RISE := 0.24 ## metres above the head's centre

var main: Node
var client: Node
var active := false
var heads: Dictionary = {} ## participant id -> the head's world Transform3D as drawn this frame (for Go to / Follow presenter)
var modes: Dictionary = {} ## participant id -> "free" | "following" | "seated"

var _avatars: Dictionary = {} ## id -> {root, head, left, right, laser, tag, material, laser_mesh, name}
var _tracks: Dictionary = {} ## id -> {a, b, offset, have}


func start(p_main: Node, p_client: Node) -> void:
	main = p_main
	client = p_client
	active = true
	if not client.presence_received.is_connected(_on_presence):
		client.presence_received.connect(_on_presence)
		client.welcomed.connect(_on_welcomed)
	_feed_snapshot()


func stop() -> void:
	active = false
	if client != null and client.presence_received.is_connected(_on_presence):
		client.presence_received.disconnect(_on_presence)
		client.welcomed.disconnect(_on_welcomed)
	for id in _avatars.keys():
		_remove(id)
	_tracks.clear()
	heads.clear()
	modes.clear()


func avatar_ids() -> Array:
	return _avatars.keys()


func avatar_of(id: int) -> Dictionary:
	return _avatars.get(id, {})


func _on_welcomed(_welcome: Dictionary, _resumed: bool) -> void:
	_feed_snapshot()


func _feed_snapshot() -> void:
	## A late joiner or a resume: each participant's last presence is in the welcome (scope 4.7), so people are drawn at once, not at their next 1 Hz message.
	var held = client.snapshot.get("presence", {})
	if held is Dictionary:
		for id in held:
			if held[id] is Dictionary:
				_on_presence(held[id])


func _on_presence(message: Dictionary) -> void:
	var id := int(message.get("from", 0))
	if id == 0 or id == int(client.me.get("id", -1)):
		return
	var sample := {"at": float(message.get("at", 0)), "head": message.get("head"), "hands": message.get("hands", [null, null]), "laser": message.get("laser"), "cursor": message.get("cursor"), "mode": str(message.get("mode", "free"))}
	var track: Dictionary = _tracks.get(id, {"a": null, "b": null, "offset": 0.0, "have": false})
	var offset_sample: float = sample["at"] - float(Time.get_ticks_msec())
	if not bool(track["have"]) or absf(offset_sample - float(track["offset"])) > 2000.0:
		track["offset"] = offset_sample
		track["have"] = true
	else:
		track["offset"] = lerpf(float(track["offset"]), offset_sample, 0.1)
	track["a"] = track["b"]
	track["b"] = sample
	_tracks[id] = track


func _process(_delta: float) -> void:
	if not active or main == null:
		return
	var scene_root: Node3D = main.session_scene_root()
	var me := int(client.me.get("id", -1))
	for id in _avatars.keys():
		if not client.participants.has(id) or id == me:
			_remove(id)
	heads.clear()
	if scene_root == null or not is_instance_valid(scene_root):
		for id in _avatars:
			(_avatars[id]["root"] as Node3D).visible = false
		return
	var unit: float = main.session_unit_mm()
	var frame := scene_root.global_transform
	for id in client.participants:
		if id == me or not _tracks.has(id):
			continue
		var person: Dictionary = client.participants[id]
		var track: Dictionary = _tracks[id]
		var avatar: Dictionary = _avatars.get(id, {})
		if not bool(person.get("connected", true)) or track["b"] == null or track["b"]["head"] == null:
			if not avatar.is_empty():
				(avatar["root"] as Node3D).visible = false
			continue
		if avatar.is_empty():
			avatar = _make(id, person)
		(avatar["root"] as Node3D).visible = true
		var render_at := float(Time.get_ticks_msec()) + float(track["offset"]) - DELAY_MS
		var shown := sample_at(track, render_at)
		_pose_avatar(avatar, shown, frame, unit, person)
		modes[id] = str(shown["mode"])


# --- Sampling -------------------------------------------------------------------------------------------------------------------

static func sample_at(track: Dictionary, render_at: float) -> Dictionary:
	## The presence to show at `render_at` (hub ms): between the last two samples; past the newest, the newest; a gap over 500 ms, the newer; a hand or laser missing from either, the newer's.
	var b: Dictionary = track["b"]
	var a = track["a"]
	if a == null or float(b["at"]) - float(a["at"]) > SNAP_GAP_MS or render_at >= float(b["at"]):
		return b
	var span := float(b["at"]) - float(a["at"])
	if span <= 0.0 or render_at <= float(a["at"]):
		return a
	var t := (render_at - float(a["at"])) / span
	var hands: Array = []
	for i in 2:
		var ha = a["hands"][i] if a["hands"].size() > i else null
		var hb = b["hands"][i] if b["hands"].size() > i else null
		hands.append(lerp_pose(ha, hb, t) if ha != null and hb != null else hb)
	var laser = b["laser"]
	if a["laser"] != null and b["laser"] != null and Protocol.is_numbers(a["laser"], 3) and Protocol.is_numbers(b["laser"], 3):
		laser = [lerpf(a["laser"][0], b["laser"][0], t), lerpf(a["laser"][1], b["laser"][1], t), lerpf(a["laser"][2], b["laser"][2], t)]
	var cursor = b.get("cursor")
	if a.get("cursor") != null and cursor != null and Protocol.is_numbers(a["cursor"], 7) and Protocol.is_numbers(cursor, 7):
		cursor = lerp_pose(a["cursor"], cursor, t)
	return {"at": render_at, "head": lerp_pose(a["head"], b["head"], t), "hands": hands, "laser": laser, "cursor": cursor, "mode": b["mode"]}


static func lerp_pose(a: Array, b: Array, t: float) -> Array:
	## Two 7-number poses blended: position lerped, rotation slerped.
	var qa := Quaternion(float(a[3]), float(a[4]), float(a[5]), float(a[6])).normalized()
	var qb := Quaternion(float(b[3]), float(b[4]), float(b[5]), float(b[6])).normalized()
	var q := qa.slerp(qb, t)
	return [lerpf(a[0], b[0], t), lerpf(a[1], b[1], t), lerpf(a[2], b[2], t), q.x, q.y, q.z, q.w]


static func world_of(pose, frame: Transform3D, unit_mm: float) -> Variant:
	## A model-space pose (position mm, quaternion) as a world Transform3D through the glb root's transform, or null if it is not a pose.
	if not Protocol.is_numbers(pose, 7):
		return null
	var local := Transform3D(Basis(Quaternion(float(pose[3]), float(pose[4]), float(pose[5]), float(pose[6])).normalized()), Vector3(pose[0], pose[1], pose[2]) / unit_mm)
	return Transform3D(frame.basis.orthonormalized() * local.basis, frame * local.origin)


# --- Drawing --------------------------------------------------------------------------------------------------------------------

func _pose_avatar(avatar: Dictionary, shown: Dictionary, frame: Transform3D, unit: float, person: Dictionary) -> void:
	var head = world_of(shown["head"], frame, unit)
	if head == null:
		(avatar["root"] as Node3D).visible = false
		return
	var id := int(person["id"])
	(avatar["head"] as Node3D).global_transform = head
	heads[id] = head
	var tag: Label3D = avatar["tag"]
	tag.global_position = (head as Transform3D).origin + Vector3(0.0, TAG_RISE, 0.0)
	var text := tag_text(person, str(shown["mode"]))
	if tag.text != text:
		tag.text = text
	_pose_cursor(avatar, shown, frame, unit, person)
	var hand_world: Array = []
	for i in 2:
		var hand = world_of(shown["hands"][i], frame, unit) if shown["hands"].size() > i else null
		var node: Node3D = avatar["left"] if i == 0 else avatar["right"]
		node.visible = hand != null
		if hand != null:
			node.global_transform = hand
		hand_world.append(hand)
	var laser: MeshInstance3D = avatar["laser"]
	var from = hand_world[1] if hand_world[1] != null else hand_world[0]
	laser.visible = from != null and shown["laser"] != null and Protocol.is_numbers(shown["laser"], 3)
	if laser.visible:
		var tip: Vector3 = frame * (Vector3(shown["laser"][0], shown["laser"][1], shown["laser"][2]) / unit)
		var start: Vector3 = (from as Transform3D).origin
		var length := start.distance_to(tip)
		if length < 0.01:
			laser.visible = false
		else:
			var direction := (tip - start) / length
			var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
			(avatar["laser_mesh"] as CylinderMesh).height = length
			laser.global_transform = Transform3D(Basis.looking_at(direction, up) * Basis(Vector3.RIGHT, deg_to_rad(90.0)), start + direction * length * 0.5)


static func tag_text(person: Dictionary, mode: String) -> String:
	## The name over the head: the presenter with a star, a person riding the presenter's viewpoint with a note, a raised hand said in words (P4).
	var text := str(person.get("name", "?"))
	if str(person.get("role", "")) == "presenter":
		text = "★ " + text
	if mode == "following":
		text += " (following)"
	if bool(person.get("hand", false)):
		text += " (hand up)"
	return text


func _pose_cursor(avatar: Dictionary, shown: Dictionary, frame: Transform3D, unit: float, person: Dictionary) -> void:
	## P4: the drone cursor of this person, a small marker of their colour with their name, where their presence says it is (model space, through this person's view of the model).
	## Nothing is drawn while they have none out.
	var node: Node3D = avatar["cursor"]
	var world = world_of(shown.get("cursor"), frame, unit)
	node.visible = world != null
	if world == null:
		return
	node.global_position = (world as Transform3D).origin
	var label: Label3D = avatar["cursor_tag"]
	var text := str(person.get("name", "?"))
	if label.text != text:
		label.text = text


func _make(id: int, person: Dictionary) -> Dictionary:
	var colour := Protocol.colour_of(str(person.get("colour", "#FFFFFF")))
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = colour
	var dark := StandardMaterial3D.new()
	dark.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dark.albedo_color = Color(0.04, 0.05, 0.09)
	var root := Node3D.new()
	root.name = "Avatar_%d" % id
	add_child(root)
	var head := Node3D.new() # at the head's pose: forward is -Z
	head.name = "Head"
	root.add_child(head)
	var skull := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = HEAD_RADIUS
	sphere.height = HEAD_RADIUS * 2.0
	sphere.material = material
	skull.mesh = sphere
	skull.scale = Vector3(0.9, 1.0, 1.0)
	head.add_child(skull)
	var visor := MeshInstance3D.new() # the face: a dark band on the front, so a glance says which way they look
	var visor_mesh := BoxMesh.new()
	visor_mesh.size = Vector3(0.17, 0.06, 0.05)
	visor_mesh.material = dark
	visor.mesh = visor_mesh
	visor.position = Vector3(0.0, 0.01, -HEAD_RADIUS * 0.85)
	head.add_child(visor)
	var hands: Array = []
	for hand_name in ["LeftHand", "RightHand"]:
		var hand := MeshInstance3D.new()
		hand.name = hand_name
		var box := BoxMesh.new()
		box.size = Vector3(0.05, 0.04, 0.13)
		box.material = material
		hand.mesh = box
		root.add_child(hand)
		hands.append(hand)
	var laser := MeshInstance3D.new()
	laser.name = "Laser"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.004
	cylinder.bottom_radius = 0.004
	cylinder.height = 1.0
	cylinder.radial_segments = 6
	cylinder.rings = 1
	cylinder.material = material
	laser.mesh = cylinder
	laser.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(laser)
	var tag := Label3D.new()
	tag.name = "NameTag"
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.pixel_size = 0.0022
	tag.font_size = 56
	tag.outline_size = 14
	tag.modulate = colour
	tag.outline_modulate = Color(0.02, 0.03, 0.06)
	tag.shaded = false
	tag.double_sided = true
	tag.text = tag_text(person, "free")
	root.add_child(tag)
	var cursor := Node3D.new() # P4: the drone cursor (a dot and a ring, a small name): drawn only while their presence carries one
	cursor.name = "Cursor"
	cursor.visible = false
	root.add_child(cursor)
	var dot := MeshInstance3D.new()
	var dot_mesh := SphereMesh.new()
	dot_mesh.radius = 0.014
	dot_mesh.height = 0.028
	dot_mesh.radial_segments = 12
	dot_mesh.rings = 6
	dot_mesh.material = material
	dot.mesh = dot_mesh
	cursor.add_child(dot)
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.024
	torus.outer_radius = 0.028
	torus.rings = 16
	torus.ring_segments = 6
	torus.material = material
	ring.mesh = torus
	ring.rotation_degrees.x = 90.0
	cursor.add_child(ring)
	var cursor_tag := Label3D.new()
	cursor_tag.name = "CursorTag"
	cursor_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	cursor_tag.pixel_size = 0.0014
	cursor_tag.font_size = 44
	cursor_tag.outline_size = 10
	cursor_tag.modulate = colour
	cursor_tag.outline_modulate = Color(0.02, 0.03, 0.06)
	cursor_tag.shaded = false
	cursor_tag.no_depth_test = true
	cursor_tag.position = Vector3(0.0, 0.05, 0.0)
	cursor.add_child(cursor_tag)
	var avatar := {"root": root, "head": head, "left": hands[0], "right": hands[1], "laser": laser, "laser_mesh": cylinder, "tag": tag, "material": material, "colour": colour, "cursor": cursor, "cursor_tag": cursor_tag}
	_avatars[id] = avatar
	return avatar


func _remove(id: int) -> void:
	var avatar: Dictionary = _avatars.get(id, {})
	if not avatar.is_empty() and is_instance_valid(avatar["root"]):
		(avatar["root"] as Node3D).queue_free()
	_avatars.erase(id)
	_tracks.erase(id)
	heads.erase(id)
	modes.erase(id)
