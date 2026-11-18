extends Node3D
## The DRONE CURSOR (P4, DIDSA-CAD plan "Observer tools"): a small coloured, named marker an observer flies through the model. It is the observer's way of choosing a thing, since an
## observer has no laser-select: it SELECTS WHAT IT TOUCHES OR POINTS AT, and the existing paint breadcrumb (appearance_tool.gd `rows_for`: Face, Body, Part, each sub-assembly)
## says at which level. Everyone sees it: it travels in presence's `cursor` field (a pose in model space) and session_avatars.gd draws it with the owner's name and colour.
##
## Flying. The cursor sits on a leash along the right hand's laser, `distance` metres out. The RIGHT STICK (up / down) lets the leash out and in while the cursor is on (that stick
## is the cursor's then, so it does not also snap-turn or teleport: controller.gd `is_manipulating`); the aim steers it. A (button AX) takes the selection one level WIDER (face, body,
## part, sub-assembly, the next one out), B (button BY) one level NARROWER. The cursor passes through surfaces.
## What it picks, in this order: (1) a surface within TOUCH_RADIUS of the cursor (six short rays out of it), "touching"; (2) a part whose bounds hold the cursor, the smallest one,
## "inside" (no face is known); (3) the first surface beyond the cursor along the aim, "pointing". A hidden part is never picked (the same rules as the laser: laser_pick.gd).
##
## The selection is what Share shows to everyone (session_marks.gd) and what the own-view buttons act on (colour, hide, isolate, see-through; ui/observer_pages.gd). Headless tests
## replace `aim` and `stick` (there is no hand) and read `selection()`; what it feels like to fly one is for a headset.

const Protocol := preload("res://scripts/session/session_protocol.gd")
const Presence := preload("res://scripts/session/session_presence.gd")
const Publisher := preload("res://scripts/session/session_publisher.gd")
const LaserPick := preload("res://scripts/laser_pick.gd")
const GroupIndex := preload("res://scripts/group_index.gd")
const GroupCues := preload("res://scripts/group_cues.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")

const MIN_DISTANCE := 0.15
const MAX_DISTANCE := 8.0
const FLY_SPEED := 1.5 ## metres a second at full stick
const STICK_DEADZONE := 0.15
const TOUCH_RADIUS := 0.04 ## metres
const SELECT_HZ := 15.0
const MARKER_RADIUS := 0.014
const MAX_RANK := 12
const BASE_RANKS := {"face": 0, "body": 1, "part": 2}

signal enabled_changed(on: bool)
signal selection_changed()

var main: Node
var client: Node
var enabled := false
var distance := 0.8
var level_rank := 2 ## which level to take: 0 face, 1 body, 2 part, 3 the sub-assembly the part is in, 4 the one around that ...
var aim: Callable = Callable() ## () -> {origin, direction}: the right hand's laser (tests replace it)
var stick: Callable = Callable() ## () -> Vector2: the right stick (tests replace it)
var last_how := "" ## "touching" | "inside" | "pointing" | "" (nothing)

var _hit: Dictionary = {} ## {part, point, face_index, how} of what the cursor is on
var _rows: Array = [] ## the breadcrumb levels of that part (innermost first, no "whole assembly")
var _chosen := -1 ## index into _rows
var _position := Vector3.ZERO ## the marker, world
var _direction := Vector3.FORWARD
var _have_position := false
var _since_select := 1.0
var _marker: Node3D
var _tag: Label3D
var _material: StandardMaterial3D
var _hand: Node = null
var _brackets: MeshInstance3D = null ## corner brackets round what the cursor has picked (in the cursor's colour), so the picker sees what a Share or a colour would take
var _brackets_box := AABB()
var _active := false


func start(p_main: Node, p_client: Node) -> void:
	main = p_main
	client = p_client
	_active = true
	if not aim.is_valid():
		aim = _hand_aim
	if not stick.is_valid():
		stick = _hand_stick
	_hand = main.session_hands()[1]
	if _hand != null and _hand.has_signal("button_pressed") and not _hand.button_pressed.is_connected(_on_button):
		_hand.button_pressed.connect(_on_button)


func stop() -> void:
	set_enabled(false)
	_active = false
	if _hand != null and is_instance_valid(_hand) and _hand.has_signal("button_pressed") and _hand.button_pressed.is_connected(_on_button):
		_hand.button_pressed.disconnect(_on_button)
	_hand = null
	_forget_target()
	if _marker != null and is_instance_valid(_marker):
		_marker.queue_free()
	_marker = null
	_tag = null
	_clear_brackets()


func set_enabled(on: bool) -> void:
	if on == enabled:
		return
	if on and not _active:
		return
	enabled = on
	if _hand != null and is_instance_valid(_hand):
		_hand.set_meta("cursor_owns_stick", on) # controller.gd is_manipulating(): locomotion leaves this stick alone
	if on:
		_ensure_marker()
		_since_select = 1.0
	else:
		_forget_target()
		_have_position = false
		_clear_brackets()
		if _marker != null:
			_marker.visible = false
	enabled_changed.emit(on)
	selection_changed.emit()


# --- Aim and stick -----------------------------------------------------------------------------------------------------------------

func _hand_aim() -> Dictionary:
	if _hand == null or not is_instance_valid(_hand):
		return {}
	var t: Transform3D = _hand.global_transform
	return {"origin": t.origin, "direction": -t.basis.z.normalized()}


func _hand_stick() -> Vector2:
	return _hand.get_vector2("primary") if _hand != null and is_instance_valid(_hand) and _hand.has_method("get_vector2") else Vector2.ZERO


func _on_button(action: String) -> void:
	if not enabled:
		return
	if action == "ax_button":
		step_level(1)
	elif action == "by_button":
		step_level(-1)


# --- The frame ---------------------------------------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not _active or not enabled or main == null:
		return
	var s: Vector2 = stick.call()
	if absf(s.y) > STICK_DEADZONE:
		fly(-s.y * FLY_SPEED * delta)
	var a: Dictionary = aim.call()
	if a.is_empty():
		return
	_direction = (a["direction"] as Vector3).normalized()
	_position = (a["origin"] as Vector3) + _direction * distance
	_have_position = true
	_since_select += delta
	if _since_select >= 1.0 / SELECT_HZ:
		_since_select = 0.0
		refresh()
	_draw()


func fly(metres: float) -> void:
	## Lets the leash out (positive) or reels it in.
	distance = clampf(distance + metres, MIN_DISTANCE, MAX_DISTANCE)


func refresh() -> void:
	## Works out what the cursor is on now (what the frame does at 15 Hz; a test calls it after placing the cursor).
	if not enabled or main == null or not _have_position:
		return
	var hit := find_hit(_position, _direction)
	var same: bool = is_instance_valid(_hit.get("part")) and hit.get("part") == _hit.get("part") and int(hit.get("face_index", -1)) == int(_hit.get("face_index", -1))
	_hit = hit
	last_how = str(hit.get("how", ""))
	if hit.is_empty():
		if not _rows.is_empty():
			_rows = []
			_chosen = -1
			selection_changed.emit()
		return
	if hit["how"] == "touching":
		_position = hit["point"] # the marker rests on what it touches
	if not same:
		_rows = rows_for(hit["part"], int(hit.get("face_index", -1)))
		_pick_row()
		selection_changed.emit()


func find_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	## {part, point, face_index, how} or {}: what a cursor at `origin`, flown along `direction`, touches or points at.
	if not is_inside_tree():
		return {}
	var world := get_world_3d()
	var best := {}
	var best_d := INF
	for axis in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.FORWARD, Vector3.BACK]:
		var h := LaserPick.ray(world, origin, axis, TOUCH_RADIUS, _classify, 0xFFFFFFFF, RoomRegistry.part_visible_at)
		if not h.is_empty() and float(h["distance"]) < best_d:
			best = h
			best_d = float(h["distance"])
	if not best.is_empty():
		best["how"] = "touching"
		return best
	var inside := _smallest_part_holding(origin)
	if inside != null:
		return {"part": inside, "point": origin, "face_index": -1, "how": "inside"}
	var ahead := LaserPick.ray(world, origin, direction, MAX_DISTANCE, _classify, 0xFFFFFFFF, RoomRegistry.part_visible_at)
	if not ahead.is_empty():
		ahead["how"] = "pointing"
	return ahead


func _classify(part: Node3D) -> int:
	if not part.is_in_group("grabbable_parts"):
		return LaserPick.BLOCK
	if (part.has_meta("held") and part.get_meta("held")) or not part.visible:
		return LaserPick.SKIP
	return LaserPick.HIT


func _smallest_part_holding(point: Vector3) -> Node3D:
	var best: Node3D = null
	var best_volume := INF
	for node in main.session_world_parts():
		var part := node as MeshInstance3D
		if part == null or not part.is_visible_in_tree() or part.mesh == null:
			continue
		var box := part.global_transform * part.get_aabb()
		if box.has_point(point):
			var volume := box.size.x * box.size.y * box.size.z
			if volume < best_volume:
				best_volume = volume
				best = part
	return best


# --- The breadcrumb ----------------------------------------------------------------------------------------------------------------

func rows_for(part: Node3D, face_index: int) -> Array:
	## The paint breadcrumb's levels for this part, innermost first, without "Whole assembly" (the cursor chooses a thing, not everything), each {id, label, record, members, rank}.
	## A part with no occurrence path (a demo's) still gets its own "Part" level.
	var rows: Array = main.session_level_rows(part, face_index)
	var out: Array = []
	var subs := 0
	var have_part := false
	for row in rows:
		var id := str(row["id"])
		if id == "whole" or id == "same_part" or id.begins_with("pattern_"):
			continue
		var copy: Dictionary = (row as Dictionary).duplicate()
		if BASE_RANKS.has(id):
			copy["rank"] = BASE_RANKS[id]
			have_part = have_part or id == "part"
		else:
			subs += 1
			copy["rank"] = 2 + subs
		out.append(copy)
	if not have_part:
		var at := 0
		var body_record: Variant = null # (a part with no path of its own, the root's content, can only be coloured by its body; with no face identity at all, not by itself)
		for i in out.size():
			if int(out[i]["rank"]) < 2:
				at = i + 1
			if str(out[i]["id"]) == "body":
				body_record = (out[i]["record"] as Dictionary).duplicate(true)
		out.insert(at, {"id": "part", "label": "Part · %s" % str(part.get_meta("display_name", part.name)), "record": body_record, "members": [part], "rank": 2})
	return out


func step_level(delta: int) -> void:
	## One level wider (+1) or narrower (-1). Never past what this part has.
	if _rows.is_empty():
		level_rank = clampi(level_rank + delta, 0, MAX_RANK)
		return
	var low := int(_rows[0]["rank"])
	var high := int(_rows[_rows.size() - 1]["rank"])
	level_rank = clampi(level_rank + delta, low, high)
	_pick_row()
	selection_changed.emit()


func set_level_rank(rank: int) -> void:
	level_rank = clampi(rank, 0, MAX_RANK)
	_pick_row()
	selection_changed.emit()


func _pick_row() -> void:
	## The level nearest the one asked for (ties go to the wider).
	_chosen = -1
	var best_gap := 1000
	for i in _rows.size():
		var rank := int(_rows[i]["rank"])
		var gap := absi(rank - level_rank)
		if _chosen < 0 or gap < best_gap or (gap == best_gap and rank > int(_rows[_chosen]["rank"])):
			_chosen = i
			best_gap = gap


func selection() -> Dictionary:
	## What the cursor has selected: {} or {row, label, node, members, point, face_index, how, target, rank}. `target` is the wire's (scope 4.3): {path, body?, face?}, with the part's wire key
	## (the glb's instance_path) so every device finds the same node; a sub-assembly's path is the prefix.
	if not enabled or _hit.is_empty() or _chosen < 0 or _chosen >= _rows.size():
		return {}
	var row: Dictionary = _rows[_chosen]
	var part = _hit.get("part") # (it may have been freed: the presenter's model was refetched)
	if not is_instance_valid(part):
		return {}
	var scene_root: Node3D = main.session_scene_root()
	var record: Dictionary = row["record"] if row.get("record") is Dictionary else {} # (null for a part that cannot be coloured by itself)
	var id := str(row["id"])
	var target := {"path": Publisher.part_key(part, scene_root)}
	if id.begins_with("sub_"):
		target["path"] = str(record.get("path", ""))
	elif id == "face" or id == "body":
		target["body"] = str(record.get("body_id", ""))
		if id == "face":
			target["face"] = int((record.get("face", {}) as Dictionary).get("index", -1))
	return {"row": row, "label": str(row["label"]), "node": part, "members": row["members"], "point": _hit["point"], "face_index": int(_hit.get("face_index", -1)),
		"how": str(_hit.get("how", "")), "target": target, "rank": int(row["rank"])}


func levels() -> Array:
	return _rows


func hovered_node() -> Node3D:
	return _hit.get("part") if not _hit.is_empty() and is_instance_valid(_hit.get("part")) else null


func _forget_target() -> void:
	_hit = {}
	_rows = []
	_chosen = -1
	last_how = ""


# --- What others get, and the drawing ----------------------------------------------------------------------------------------------

func world_transform() -> Variant:
	## The cursor as a world Transform3D (pointing the way it is aimed), or null while it is off.
	if not enabled or not _have_position:
		return null
	var up := Vector3.UP if absf(_direction.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	return Transform3D(Basis.looking_at(_direction, up), _position)


func pose() -> Variant:
	## The 7-number model-space pose the presence message carries, or null.
	var t = world_transform()
	if t == null:
		return null
	var scene_root: Node3D = main.session_scene_root()
	if scene_root == null or not is_instance_valid(scene_root):
		return null
	return Presence.pose_of(t, scene_root.global_transform.affine_inverse(), main.session_unit_mm())


func _ensure_marker() -> void:
	if _marker != null and is_instance_valid(_marker):
		return
	var colour := Protocol.colour_of(str(client.me.get("colour", "#FFFFFF")))
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = colour
	_marker = Node3D.new()
	_marker.name = "DroneCursor"
	add_child(_marker)
	var body := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = MARKER_RADIUS
	sphere.height = MARKER_RADIUS * 2.0
	sphere.radial_segments = 12
	sphere.rings = 6
	sphere.material = _material
	body.mesh = sphere
	_marker.add_child(body)
	var ring := MeshInstance3D.new() # a thin ring round it: reads as a cursor, not a dot, against a busy model
	var torus := TorusMesh.new()
	torus.inner_radius = MARKER_RADIUS * 1.7
	torus.outer_radius = MARKER_RADIUS * 2.0
	torus.rings = 16
	torus.ring_segments = 6
	torus.material = _material
	ring.mesh = torus
	ring.rotation_degrees.x = 90.0
	_marker.add_child(ring)
	_tag = Label3D.new()
	_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tag.pixel_size = 0.0014
	_tag.font_size = 44
	_tag.outline_size = 10
	_tag.modulate = colour
	_tag.outline_modulate = Color(0.02, 0.03, 0.06)
	_tag.shaded = false
	_tag.no_depth_test = true
	_tag.position = Vector3(0.0, 0.05, 0.0)
	_marker.add_child(_tag)


func _draw() -> void:
	if _marker == null or not is_instance_valid(_marker):
		return
	_marker.visible = enabled and _have_position
	_marker.global_position = _position
	var colour := Protocol.colour_of(str(client.me.get("colour", "#FFFFFF")))
	if _material.albedo_color != colour:
		_material.albedo_color = colour
		_tag.modulate = colour
	var text := str(client.me.get("name", ""))
	var s := selection()
	if not s.is_empty():
		text += "\n" + str(s["label"])
		var box := GroupIndex.union_aabb(s["members"])
		if _brackets == null or not is_instance_valid(_brackets) or not _brackets_box.is_equal_approx(box):
			_clear_brackets()
			_brackets = GroupCues.brackets(box.grow(0.004), colour)
			add_child(_brackets)
			_brackets_box = box
	else:
		_clear_brackets()
	if _tag.text != text:
		_tag.text = text


func _clear_brackets() -> void:
	if _brackets != null and is_instance_valid(_brackets):
		GroupCues.clear([_brackets])
	_brackets = null
