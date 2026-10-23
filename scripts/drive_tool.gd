extends Node
## The Drive tool (gears-and-motion plan M7, D7): turns a part continuously about the axis of a round face / circular edge you pick (or slides it along a
## straight edge) so the whole mechanism its mates couple to runs. It is a hand drag made by the stick: every physics frame the wish is the drag's
## accumulated wish moved on by speed x delta and handed to mates_tool.constrain_drag, exactly as controller.gd does for a hand, and stopping calls end_drag
## (ONE commit, ONE undo step). The backend couples the motion; nothing here knows about gears.
##
## Input (controller.gd feeds it, the tool ticks in _physics_process): the stick's X sets the speed, -1..1 -> -30..30 rpm (slide: -50..50 mm/s) past a
## dead zone of 0.15; A toggles "keep running" at the current speed; B stops. Hard cap 60 rpm (100 mm/s): a coupler's rows are only good within
## about 170 degrees of the last anchor and the clients re-anchor every ~150 ms.

const TopologyPick := preload("res://scripts/topology_pick.gd")

signal status_changed()

const DEADZONE := 0.15
const RPM_FULL := 30.0 ## rpm at full stick
const RPM_MAX := 60.0 ## hard cap
const SLIDE_FULL := 50.0 ## mm/s at full stick
const SLIDE_MAX := 100.0
const READOUT_SMOOTH := 0.15 ## weight of each frame in the smoothed rpm
const STATUS_EVERY_MS := 200

var active := false ## the tablet's / wheel's Drive tool switch
var mates_tool: Node ## set by main.gd
var part: Node3D = null ## the picked part
var kind := "" ## "spin" or "slide"
var speed := 0.0 ## signed rpm (spin) or mm/s (slide) now
var keep := false ## A: keep running at the current speed with the stick at rest
var running := false ## a drag is in progress (constrain_drag has been called and end_drag has not)

var _axis_local := {} ## {origin, dir} in the part's own frame
var _axis_world := {} ## {origin, dir} in the world, fixed for one run
var _status := ""
var _stick := 0.0 ## the largest stick X fed since the last tick (either hand)
var _a_edge := false
var _b_edge := false
var _a_down := false
var _rates := {} ## node -> smoothed signed rpm
var _prev := {} ## node -> Quaternion at the last tick
var _prev_pos := {} ## node -> its origin at the last tick
var _slides := {} ## node -> smoothed speed of its origin, mm/s (in the part's own units)
var _stuck := false
var _wait_for_rest := false ## a hand took the part: the stick is ignored until it has been at rest
var _last_status_ms := 0


func set_active(on: bool) -> void:
	active = on
	if not on:
		stop()
		clear_pick()
	else:
		_status = ""
	status_changed.emit()


func clear_pick() -> void:
	part = null
	kind = ""
	_axis_local = {}
	speed = 0.0
	keep = false
	_status = ""


func on_grip() -> void:
	## A hand took a part (controller.gd): a hand drag and the stick would both steer the same mated group, so the run stops (one commit) and the hand has it.
	if running:
		stop()
		_wait_for_rest = true # the stick is still pushed: it must come back to rest before it drives again, or it would take the part back from the hand


func owns_stick() -> bool:
	## True while a part is picked: the stick is the throttle, so locomotion leaves it alone.
	return active and part != null and is_instance_valid(part)


func status_text() -> String:
	if _status != "":
		return _status
	if running:
		return readout_text()
	if part == null or not is_instance_valid(part):
		return "Pick a round face to turn a part, or a straight edge to slide it."
	var what := "turn" if kind == "spin" else "slide"
	var label := _label(part)
	return "%sstick sideways to %s (A keeps it going, B stops)." % [label + ": " if label != "" else "", what]


# --- Picking ----------------------------------------------------------------------------------

func try_pick(target: Node3D, face_index: int, entity: Dictionary, _point: Vector3 = Vector3.INF) -> void:
	if target == null or entity.is_empty():
		return
	stop()
	# The laser on a bore or a shaft snaps to its seam line or a corner when near one: that is the round face, which turns about its axis.
	var hit_face := TopologyPick.face_entity(target, face_index)
	if not hit_face.is_empty() and TopologyPick.axis_kind(target, hit_face) == "cylinder" and (str(entity.get("kind", "")) == "vertex" or TopologyPick.axis_kind(target, entity) == "line"):
		entity = hit_face
	var axis := axis_of(target, entity)
	if axis.is_empty():
		_reject("Pick a round face to turn it, or a straight edge to slide it.")
		return
	if mates_tool == null or not mates_tool.is_managed(target):
		_reject("Select a placed part first.")
		return
	if mates_tool.is_locked(target):
		mates_tool.notify_locked(target)
		_reject("%s is grounded: Float it first." % _label_or(target, "This part"))
		return
	if bool(mates_tool.get("relaxed")):
		_reject("Mates are relaxed (a sandbox): Drive needs them enforced. Wheel: Return parts first.")
		return
	if not mates_tool.is_constrained(target):
		_reject("%s has no mates: Drive turns a part its mates hold (mate it to something first)." % _label_or(target, "This part"))
		return
	part = target
	kind = str(axis["kind"])
	_axis_local = {"origin": axis["origin"], "dir": axis["dir"]}
	speed = 0.0
	keep = false
	_status = ""
	status_changed.emit()


func _reject(text: String) -> void:
	part = null
	kind = ""
	_status = text
	status_changed.emit()


static func axis_of(target: Node3D, entity: Dictionary) -> Dictionary:
	## {origin, dir (unit), kind: "spin"|"slide"} in the part's own frame for a picked entity, or {}: a round face (its circular boundary edge fixes the axis),
	## a circular edge (the axis through its centre, normal to it), a straight edge (slide along it). Anything else is {}.
	var shape := str(entity.get("kind", "face"))
	if shape == "vertex":
		return {}
	var topo_kind := TopologyPick.axis_kind(target, entity)
	if shape == "edge":
		var pts := TopologyPick.edge_points(target, str(entity["body_id"]), int(entity["index"]))
		if topo_kind == "line" or (topo_kind == "" and _is_line(pts)):
			return _line_axis(pts)
		if topo_kind == "circle" or topo_kind == "":
			return _circle_axis(pts)
		return {}
	if topo_kind != "cylinder" and topo_kind != "":
		return {}
	if not target.has_meta("topology"):
		return {}
	var body: Dictionary = (target.get_meta("topology") as Dictionary).get(str(entity["body_id"]), {})
	var face_edges: Array = body.get("face_edges", [])
	var face_id := int(entity.get("index", -1))
	if face_id < 0 or face_id >= face_edges.size():
		return {}
	var kinds: Dictionary = body.get("edge_kinds", {})
	for edge_index in (face_edges[face_id] as PackedInt32Array):
		if str(kinds.get(edge_index, "")) == "circle":
			var found := _circle_axis(TopologyPick.edge_points(target, str(entity["body_id"]), edge_index))
			if not found.is_empty():
				return found
	return {}


static func _is_line(pts: PackedVector3Array) -> bool:
	return pts.size() == 2


static func _line_axis(pts: PackedVector3Array) -> Dictionary:
	if pts.size() < 2:
		return {}
	var d := pts[pts.size() - 1] - pts[0]
	if d.length() < 0.000001:
		return {}
	return {"origin": pts[0], "dir": d.normalized(), "kind": "slide"}


static func _circle_axis(pts: PackedVector3Array) -> Dictionary:
	## The circle through three well-spread points of the polyline: centre and unit normal.
	if pts.size() < 3:
		return {}
	var a := pts[0]
	var b := pts[pts.size() / 3]
	var c := pts[(2 * pts.size()) / 3]
	var ab := b - a
	var ac := c - a
	var n := ab.cross(ac)
	var n2 := n.length_squared()
	if n2 < 1e-18:
		return {}
	var centre := a + (n.cross(ab) * ac.length_squared() + ac.cross(n) * ab.length_squared()) / (2.0 * n2)
	return {"origin": centre, "dir": n.normalized(), "kind": "spin"}


# --- Input ------------------------------------------------------------------------------------

func feed(stick: Vector2, a_down: bool, b_down: bool) -> void:
	## One hand's stick and A / B this frame (controller.gd): the tool keeps the strongest stick and acts on the next tick.
	if absf(stick.x) > absf(_stick):
		_stick = stick.x
	if a_down and not _a_down:
		_a_edge = true
	_a_down = a_down
	if b_down:
		_b_edge = true


func _physics_process(delta: float) -> void:
	if active:
		tick(delta)


func speed_for(stick_x: float) -> float:
	## Stick X (-1..1) to rpm (spin) or mm/s (slide): zero inside the dead zone, then linear to the full speed, capped.
	var m := absf(stick_x)
	if m < DEADZONE:
		return 0.0
	var full := RPM_FULL if kind != "slide" else SLIDE_FULL
	var cap := RPM_MAX if kind != "slide" else SLIDE_MAX
	return signf(stick_x) * minf((m - DEADZONE) / (1.0 - DEADZONE) * full, cap)


func tick(delta: float) -> void:
	var x := _stick
	var a := _a_edge
	var b := _b_edge
	_stick = 0.0
	_a_edge = false
	_b_edge = false
	if part == null or not is_instance_valid(part) or delta <= 0.0:
		return
	if _wait_for_rest:
		if absf(x) < DEADZONE and not b:
			_wait_for_rest = false
		return
	if b:
		stop()
		return
	if a and (speed != 0.0 or running):
		keep = not keep
	if absf(x) >= DEADZONE:
		speed = speed_for(x)
	elif not keep:
		speed = 0.0
	if speed == 0.0:
		if running:
			stop()
		return
	_step(delta)


func _step(delta: float) -> void:
	var base: Transform3D
	if not running:
		# A fresh run: the axis in the world from where the part is now, held for the whole run.
		var t := part.global_transform
		_axis_world = {"origin": t * (_axis_local["origin"] as Vector3), "dir": (t.basis * (_axis_local["dir"] as Vector3)).normalized()}
		base = t
		running = true
		_stuck = false
		_rates.clear()
		_prev.clear()
		_prev_pos.clear()
		_slides.clear()
	else:
		base = mates_tool.desired_global(part) if mates_tool.has_drag(part) else part.global_transform
		if mates_tool.has_method("drag_at_limit") and mates_tool.drag_at_limit(part):
			# Stopped by a limit mate: the wish stays one step past the stop instead of winding up (the stick held on past a stop would otherwise run the wish
			# half a turn or more beyond it, where a pose is read as being on the other side, and reversing would have to unwind it first).
			base = part.global_transform
	var dir: Vector3 = _axis_world["dir"]
	var wish: Transform3D
	if kind == "spin":
		var rot := Basis(dir, speed * TAU / 60.0 * delta)
		var pivot: Vector3 = _axis_world["origin"]
		wish = Transform3D(rot, pivot - rot * pivot) * base
	else:
		var scale: float = part.global_transform.basis.get_scale().x # mm of the backend -> world
		wish = Transform3D(Basis.IDENTITY, dir * speed * delta * scale) * base
	part.global_transform = mates_tool.constrain_drag(part, wish)
	if not _stuck and mates_tool.take_stuck_notice(part):
		_stuck = true
		_status = "Held: nothing can turn."
		status_changed.emit()
	_update_readout(delta)


func stop() -> void:
	if running and part != null and is_instance_valid(part) and mates_tool != null:
		mates_tool.end_drag(part)
	running = false
	speed = 0.0
	keep = false
	_rates.clear()
	_prev.clear()
	_prev_pos.clear()
	_slides.clear()
	if _status.begins_with("Held:"):
		_status = ""
	status_changed.emit()


func _label(node: Node3D) -> String:
	return mates_tool.part_label(node) if mates_tool != null and mates_tool.has_method("part_label") else ""


func _label_or(node: Node3D, fallback: String) -> String:
	var label := _label(node)
	return label if label != "" else fallback


# --- Readout ----------------------------------------------------------------------------------

func _update_readout(delta: float) -> void:
	var nodes: Array = [part]
	for node in mates_tool.drag_member_nodes(part).values():
		if node != part and is_instance_valid(node):
			nodes.append(node)
	var axis: Vector3 = _axis_world["dir"]
	for node in nodes:
		var q := Quaternion(node.global_transform.basis.orthonormalized())
		if _prev.has(node):
			var dq: Quaternion = q * (_prev[node] as Quaternion).inverse()
			if dq.w < 0.0:
				dq = -dq
			var angle := dq.get_angle()
			var rpm := 0.0
			if angle > 1e-7:
				# (a slide has no turning direction to sign against: every follower reads as a plain rpm)
				rpm = angle * (signf(dq.get_axis().dot(axis)) if kind == "spin" else 1.0) / delta * 60.0 / TAU
			_rates[node] = lerpf(float(_rates.get(node, rpm)), rpm, READOUT_SMOOTH)
			var here: Vector3 = node.global_transform.origin
			var mm_per_s: float = here.distance_to(_prev_pos[node]) / delta / maxf(node.global_transform.basis.get_scale().x, 1e-9)
			_slides[node] = lerpf(float(_slides.get(node, mm_per_s)), mm_per_s, READOUT_SMOOTH)
		_prev[node] = q
		_prev_pos[node] = node.global_transform.origin
	if Time.get_ticks_msec() - _last_status_ms < STATUS_EVERY_MS:
		return
	_last_status_ms = Time.get_ticks_msec()
	status_changed.emit() # (status_text() reads the readout live while running)


func readout_text() -> String:
	## "Gear A 30 rpm · Gear B -15 rpm": the driven part first, then every other member that turns (signed against the drive axis) or slides (mm/s).
	if part == null or not is_instance_valid(part):
		return ""
	var named := func(node: Node3D, value: String) -> String:
		var label := _label(node)
		return "%s %s" % [label, value] if label != "" else value
	var parts := PackedStringArray([named.call(part, ("%d mm/s" % roundi(speed)) if kind == "slide" else ("%d rpm" % roundi(speed)))])
	for node in _rates:
		if node == part or not is_instance_valid(node):
			continue
		var rpm: float = _rates[node]
		var slide: float = _slides.get(node, 0.0)
		if absf(rpm) >= 0.5:
			parts.append(named.call(node, "%d rpm" % roundi(rpm)))
		elif slide >= 0.5:
			parts.append(named.call(node, "%d mm/s" % roundi(slide))) # a rack: it slides, it does not turn
	if mates_tool != null and mates_tool.has_method("drag_at_limit") and mates_tool.drag_at_limit(part):
		parts.append("at its limit")
	return " · ".join(parts)
