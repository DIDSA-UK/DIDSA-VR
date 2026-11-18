extends Node3D
## MARKS in a live session (P4; DIDSA-CAD docs/live-sessions-scope.md 4.5, decision D7): what people show each other without changing anything.
##   Share        the cursor's current selection, shown to everyone as brackets round it with the sharer's name, in the sharer's colour. One live share per person (a new one replaces it);
##                it stays until they stop sharing, the presenter clears marks, or they leave. The hub keeps it in the snapshot, so someone who joins later sees it.
##   Ping         a pulse at a point (the cursor, or where the right laser ends), three seconds.
##   Look here    an arrow at a point, ten seconds: "come and look at this", seen by everyone and said to the presenter in words; the presenter can go there (`go_to_look_here`).
##   Raise hand   the roster's `hand` flag (the hub keeps it); it is said on the sharer's name tag and, to the presenter, in a line.
##   Clear marks  the presenter's button: every share, ping and look-here goes, for everyone.
## A mark is a `client.send` and is NEVER state: no `seq`, nothing is written anywhere (D7), and the hub forgets a share when its sender leaves. Marks arrive in MODEL space (a node is named by
## the glb's `instance_path`, the same key the poses use; a point is millimetres of the model) and are drawn through THIS person's view of the model, whatever its scale and place.
## A mark that names a part this person does not have (a refetch is pending) is kept and drawn once the part is there.

const Protocol := preload("res://scripts/session/session_protocol.gd")
const Publisher := preload("res://scripts/session/session_publisher.gd")
const Navigation := preload("res://scripts/session/session_navigation.gd")
const GroupCues := preload("res://scripts/group_cues.gd")
const GroupIndex := preload("res://scripts/group_index.gd")

const SHARE_ID := "share"
const LOOK_ID := "look"
const PING_TTL_S := 3.0
const LOOK_TTL_S := 10.0
const REFRESH_S := 0.1
const MAX_MARKS := 64 ## more than this and the oldest ping or look-here goes (a hostile or buggy client)
const LOOK_STAND_BACK := 1.0 ## metres short of the point where the presenter is put

signal marks_changed()
signal line(text: String) ## something for the status line ("Blake raised a hand")

var main: Node
var client: Node
var cursor: Node
var navigation: Node
var active := false
var hand_up := false
var marks: Dictionary = {} ## "from:id" -> {from, id, kind, target, colour, name, ttl, born, visuals}
var last_line := ""
var pings_sent := 0
var _ping_counter := 0
var _since_refresh := 0.0
var _hands_seen: Dictionary = {} ## participant id -> hand was up (to say a hand going up once)


func start(p_main: Node, p_client: Node, p_cursor: Node, p_navigation: Node) -> void:
	main = p_main
	client = p_client
	cursor = p_cursor
	navigation = p_navigation
	active = true
	hand_up = false
	_hands_seen.clear()
	if not client.message_received.is_connected(_on_message):
		client.message_received.connect(_on_message)
		client.roster_changed.connect(_on_roster)
		client.welcomed.connect(_on_welcomed)
	_feed_snapshot()
	_on_roster()


func stop() -> void:
	active = false
	if client != null and client.message_received.is_connected(_on_message):
		client.message_received.disconnect(_on_message)
		client.roster_changed.disconnect(_on_roster)
		client.welcomed.disconnect(_on_welcomed)
	_clear_all()
	hand_up = false
	_hands_seen.clear()


# --- Sending --------------------------------------------------------------------------------------------------------------------------

func share_selection() -> bool:
	## Shows what the cursor has selected to everyone. False (and a line saying why) with nothing selected.
	var selection: Dictionary = cursor.selection() if cursor != null else {}
	if selection.is_empty():
		_say("Nothing to share: put the cursor on a part first (Cursor on, then touch or point at it).")
		return false
	return _send_mark(SHARE_ID, "share", selection["target"], 0.0, str(selection.get("label", "")))


func stop_sharing() -> bool:
	## Takes this person's own share away from everyone's view.
	var key := _key(_me(), SHARE_ID)
	if not marks.has(key):
		_say("You are not sharing anything.")
		return false
	_remove(key)
	if client.is_live():
		client.send({"t": "mark_clear", "id": SHARE_ID})
	marks_changed.emit()
	return true


func ping() -> bool:
	## A pulse at the cursor, or where the right laser ends.
	var point = _aim_point()
	if point == null:
		_say("Nothing to ping: aim at the model, or turn the cursor on.")
		return false
	_ping_counter += 1
	pings_sent += 1
	return _send_mark("ping%d" % _ping_counter, "ping", {"point": _to_model(point)}, PING_TTL_S)


func look_here() -> bool:
	## Asks the presenter (and shows everyone) to look at the spot, or at what is selected there.
	var point = _aim_point()
	if point == null:
		_say("Nothing to point out: aim at the model, or turn the cursor on.")
		return false
	var target := {"point": _to_model(point)}
	var selection: Dictionary = cursor.selection() if cursor != null else {}
	if not selection.is_empty():
		target = (selection["target"] as Dictionary).duplicate()
		target["point"] = _to_model(point)
	return _send_mark(LOOK_ID, "look_here", target, LOOK_TTL_S)


func set_hand(up: bool) -> bool:
	if not client.is_live():
		return false
	hand_up = up
	var sent: bool = client.send({"t": "hand", "up": up})
	marks_changed.emit()
	return sent


func clear_marks() -> bool:
	## The presenter's: every mark goes, for everyone. (An observer's `marks_clear` is dropped by the hub, so it is not offered.)
	if not client.is_presenter():
		_say("Only the presenter clears marks. You can stop your own share.")
		return false
	var sent: bool = client.send({"t": "marks_clear"})
	_clear_all()
	marks_changed.emit()
	return sent


func _send_mark(id: String, kind: String, target: Dictionary, ttl_s: float, label: String = "") -> bool:
	if not client.is_live():
		_say("Not connected to the session.")
		return false
	var message := {"t": "mark", "id": id, "kind": kind, "target": target, "colour": str(client.me.get("colour", "")), "ttl_s": ttl_s}
	var sent: bool = client.send(message)
	if sent:
		_add(_me(), message, label) # (the hub does not echo a mark to its sender: this person's own is drawn from what was sent)
	return sent


func _aim_point() -> Variant:
	## The world point a ping or look-here means: the cursor when it is out, else the end of the right laser.
	if cursor != null and cursor.enabled:
		var t = cursor.world_transform()
		if t != null:
			return (t as Transform3D).origin
	var right: Node = main.session_hands()[1]
	if right.has_method("laser_tip"):
		return right.laser_tip()
	return null


func _to_model(world: Vector3) -> Array:
	var scene_root: Node3D = main.session_scene_root()
	var local: Vector3 = scene_root.global_transform.affine_inverse() * world
	var mm: Vector3 = local * float(main.session_unit_mm())
	return [snappedf(mm.x, Protocol.POSITION_STEP), snappedf(mm.y, Protocol.POSITION_STEP), snappedf(mm.z, Protocol.POSITION_STEP)]


func _from_model(point) -> Variant:
	if not Protocol.is_numbers(point, 3):
		return null
	var scene_root: Node3D = main.session_scene_root()
	if scene_root == null or not is_instance_valid(scene_root):
		return null
	return scene_root.global_transform * (Vector3(point[0], point[1], point[2]) / main.session_unit_mm())


func _me() -> int:
	return int(client.me.get("id", -1))


static func _key(from: int, id: String) -> String:
	return "%d:%s" % [from, id]


# --- Receiving -----------------------------------------------------------------------------------------------------------------------

func _on_welcomed(_welcome: Dictionary, _resumed: bool) -> void:
	_feed_snapshot()


func _feed_snapshot() -> void:
	## Shares that were up before this person joined (or while the connection was down), from the welcome's snapshot.
	var held = client.snapshot.get("marks", [])
	if not (held is Array):
		return
	for message in held:
		if message is Dictionary and str(message.get("kind", "")) == "share":
			_on_message(message)


func _on_message(message: Dictionary) -> void:
	if not active:
		return
	match str(message.get("t", "")):
		"mark":
			var from := int(message.get("from", 0))
			if from == 0 or from == _me():
				return
			_add(from, message, "")
			if str(message.get("kind", "")) == "look_here":
				var who := _name_of(from)
				var text := "%s asks you to look here." % who if client.is_presenter() else "%s points something out." % who
				_say(text)
		"mark_clear":
			var from_id := int(message.get("from", 0))
			var key := _key(from_id, str(message.get("id", "")))
			if marks.has(key):
				_remove(key)
				marks_changed.emit()
		"marks_clear":
			var ids: Variant = message.get("ids")
			if ids is Array:
				for key in marks.keys():
					if (ids as Array).has(str(marks[key]["id"])) or (ids as Array).has(key):
						_remove(key)
			else:
				_clear_all()
			marks_changed.emit()
			if not client.is_presenter():
				_say("The presenter cleared the marks.")


func _on_roster() -> void:
	## A hand going up is said to the presenter once; a person who left takes their share with them (the hub forgets it).
	for key in marks.keys():
		var from := int(marks[key]["from"])
		if from != _me() and not client.participants.has(from):
			_remove(key)
	for id in client.participants:
		var person: Dictionary = client.participants[id]
		var up := bool(person.get("hand", false))
		if up and not bool(_hands_seen.get(id, false)) and int(id) != _me() and client.is_presenter():
			_say("%s raised a hand." % str(person.get("name", "Someone")))
		_hands_seen[id] = up
	marks_changed.emit()


func raised_hands() -> Array:
	## The names of those whose hand is up, in the order of their ids.
	var out: Array = []
	var ids: Array = client.participants.keys()
	ids.sort()
	for id in ids:
		if bool(client.participants[id].get("hand", false)):
			out.append(str(client.participants[id].get("name", "?")))
	return out


func _name_of(id: int) -> String:
	return str(client.participants.get(id, {}).get("name", "Someone"))


# --- The set of marks ----------------------------------------------------------------------------------------------------------------

func _add(from: int, message: Dictionary, label: String) -> void:
	var kind := str(message.get("kind", ""))
	var target = message.get("target")
	if kind not in ["share", "ping", "look_here"] or not (target is Dictionary):
		return
	var key := _key(from, str(message.get("id", "")))
	if marks.has(key):
		_remove(key) # (a new share, or a look-here again, replaces the old one)
	if marks.size() >= MAX_MARKS:
		for old in marks.keys():
			if str(marks[old]["kind"]) != "share":
				_remove(old)
				break
	var ttl := float(message.get("ttl_s", 0.0) if message.get("ttl_s") != null else 0.0)
	if kind == "ping":
		ttl = clampf(ttl if ttl > 0.0 else PING_TTL_S, 0.5, 10.0)
	elif kind == "look_here":
		ttl = clampf(ttl if ttl > 0.0 else LOOK_TTL_S, 1.0, 30.0)
	else:
		ttl = 0.0
	marks[key] = {"from": from, "id": str(message.get("id", "")), "kind": kind, "target": (target as Dictionary).duplicate(), "colour": str(message.get("colour", client.participants.get(from, {}).get("colour", "#FFFFFF"))),
		"name": _name_of(from) if from != _me() else str(client.me.get("name", "You")), "ttl": ttl, "born": Time.get_ticks_msec() / 1000.0, "label": label, "visuals": {}}
	_since_refresh = REFRESH_S
	marks_changed.emit()


func _remove(key: String) -> void:
	var mark: Dictionary = marks.get(key, {})
	if mark.is_empty():
		return
	var visuals: Dictionary = mark["visuals"]
	for node in visuals.values():
		if node is Node and is_instance_valid(node):
			GroupCues.clear([node])
	marks.erase(key)


func _clear_all() -> void:
	for key in marks.keys():
		_remove(key)


func marks_of(kind: String = "") -> Array:
	## The live marks (optionally of one kind), oldest first by sender id.
	var out: Array = []
	for key in marks:
		if kind == "" or str(marks[key]["kind"]) == kind:
			out.append(marks[key])
	return out


func shared_by(id: int) -> Dictionary:
	return marks.get(_key(id, SHARE_ID), {})


# --- Where a mark is ------------------------------------------------------------------------------------------------------------------

func nodes_for_target(target: Dictionary) -> Array:
	## The parts a target names: the node whose wire key is `path`, or every node below that path (a sub-assembly).
	var out: Array = []
	if not target.has("path") or main == null:
		return out
	var path := str(target["path"]) # ("" is the root's own content: its wire key is "" too)
	var scene_root: Node3D = main.session_scene_root()
	for node in main.session_world_parts():
		var key := Publisher.part_key(node, scene_root)
		if key == path or (path != "" and key.begins_with(path + "/")):
			out.append(node)
	return out


func world_point_of(mark: Dictionary) -> Variant:
	## Where the mark is in this person's world: its point, else the middle of the parts it names. null when it cannot be placed (yet).
	var target: Dictionary = mark["target"]
	if target.has("point") and str(mark["kind"]) != "share":
		return _from_model(target["point"])
	var nodes := nodes_for_target(target)
	if nodes.is_empty():
		return _from_model(target.get("point")) if target.has("point") else null
	var box := GroupIndex.union_aabb(nodes)
	return box.get_center()


# --- Drawing -------------------------------------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not active or marks.is_empty():
		return
	_since_refresh += delta
	if _since_refresh < REFRESH_S:
		return
	_since_refresh = 0.0
	refresh()


func refresh() -> void:
	## Expires pings and look-heres, and puts every mark where it belongs now (the parts may have moved or been refetched).
	var now := Time.get_ticks_msec() / 1000.0
	var expired := false
	for key in marks.keys():
		var mark: Dictionary = marks[key]
		var age := now - float(mark["born"])
		if float(mark["ttl"]) > 0.0 and age >= float(mark["ttl"]):
			_remove(key)
			expired = true
			continue
		_draw(mark, age)
	if expired:
		marks_changed.emit()


func _colour_of(mark: Dictionary) -> Color:
	return Protocol.colour_of(str(mark["colour"]))


func _draw(mark: Dictionary, age: float) -> void:
	var visuals: Dictionary = mark["visuals"]
	var colour := _colour_of(mark)
	var kind := str(mark["kind"])
	var point = world_point_of(mark)
	var caption: Label3D = visuals.get("caption")
	if point == null:
		for node in visuals.values():
			if node is Node3D and is_instance_valid(node):
				(node as Node3D).visible = false
		return
	if caption == null or not is_instance_valid(caption):
		caption = GroupCues.caption("", Vector3.ZERO)
		caption.modulate = colour
		add_child(caption)
		visuals["caption"] = caption
	caption.visible = true
	match kind:
		"share":
			var nodes := nodes_for_target(mark["target"])
			var box := GroupIndex.union_aabb(nodes)
			var brackets = visuals.get("brackets")
			if brackets == null or not is_instance_valid(brackets) or not (visuals.get("box", AABB()) as AABB).is_equal_approx(box):
				if brackets != null and is_instance_valid(brackets):
					GroupCues.clear([brackets])
				brackets = GroupCues.brackets(box.grow(0.004), colour)
				add_child(brackets)
				visuals["brackets"] = brackets
				visuals["box"] = box
			(brackets as Node3D).visible = true
			caption.global_position = box.get_center() + Vector3(0.0, box.size.y * 0.5 + 0.05, 0.0)
			var what := str(mark.get("label", ""))
			if what == "":
				what = _describe(mark["target"], nodes)
			caption.text = "%s: %s" % [mark["name"], what] if what != "" else str(mark["name"])
		"ping":
			var ring: MeshInstance3D = visuals.get("ring")
			if ring == null or not is_instance_valid(ring):
				ring = _ring(colour)
				add_child(ring)
				visuals["ring"] = ring
			var t := clampf(age / float(mark["ttl"]), 0.0, 1.0)
			ring.global_position = point
			ring.scale = Vector3.ONE * lerpf(0.4, 3.0, t)
			(ring.material_override as StandardMaterial3D).albedo_color = Color(colour.r, colour.g, colour.b, 1.0 - t)
			caption.global_position = (point as Vector3) + Vector3(0.0, 0.07, 0.0)
			caption.text = str(mark["name"])
		"look_here":
			var arrow: MeshInstance3D = visuals.get("arrow")
			if arrow == null or not is_instance_valid(arrow):
				arrow = _arrow(colour)
				add_child(arrow)
				visuals["arrow"] = arrow
			arrow.global_position = (point as Vector3) + Vector3(0.0, 0.09 + 0.02 * sin(age * 6.0), 0.0) # bobs, so it reads as "here"
			caption.global_position = (point as Vector3) + Vector3(0.0, 0.2, 0.0)
			caption.text = "%s: look here" % str(mark["name"])


func _describe(target: Dictionary, nodes: Array) -> String:
	if nodes.size() == 1:
		return str(nodes[0].get_meta("display_name", nodes[0].name))
	if nodes.size() > 1:
		return "%d parts" % nodes.size()
	return ""


func _ring(colour: Color) -> MeshInstance3D:
	var ring := MeshInstance3D.new()
	ring.name = "PingRing"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.045
	torus.outer_radius = 0.05
	torus.rings = 24
	torus.ring_segments = 6
	ring.mesh = torus
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	m.albedo_color = colour
	ring.material_override = m
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return ring


func _arrow(colour: Color) -> MeshInstance3D:
	var arrow := MeshInstance3D.new()
	arrow.name = "LookHereArrow"
	var cone := CylinderMesh.new() # a cone pointing down at the spot
	cone.top_radius = 0.035
	cone.bottom_radius = 0.0
	cone.height = 0.08
	arrow.mesh = cone
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true
	m.albedo_color = colour
	arrow.material_override = m
	arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return arrow


# --- The presenter goes ---------------------------------------------------------------------------------------------------------------

func latest_look_here() -> Dictionary:
	var best: Dictionary = {}
	for mark in marks_of("look_here"):
		if best.is_empty() or float(mark["born"]) > float(best["born"]):
			best = mark
	return best


func go_to_look_here() -> bool:
	## The presenter is put LOOK_STAND_BACK metres short of the newest look-here, level with their own eyes, facing it. An observer can use it too (to go and see).
	var mark := latest_look_here()
	if mark.is_empty():
		_say("No one has asked you to look anywhere.")
		return false
	var point = world_point_of(mark)
	if point == null:
		_say("That spot is not in your model yet.")
		return false
	var camera: Node3D = main.session_camera()
	var eye := camera.global_position
	var flat: Vector3 = (point as Vector3) - eye
	flat.y = 0.0
	var away := flat.normalized() if flat.length() > 0.001 else Vector3.FORWARD
	var stand := (point as Vector3) - away * LOOK_STAND_BACK
	stand.y = eye.y
	navigation.place_head(stand, Navigation.yaw_of(Basis.looking_at(away, Vector3.UP)))
	_say("At %s's spot." % str(mark["name"]))
	return true


func _say(text: String) -> void:
	last_line = text
	if main != null:
		main.say(text)
	line.emit(text)
