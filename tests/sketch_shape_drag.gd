extends SceneTree
## F8 (parity follow-ups), the logic half (no scene tree, no backend): scripts/design_table/point_drag.gd dragging a shape's point, a line, and the pre-grab rule, on the
## sketches of DIDSA-CAD's shape vectors (tests/fixtures/sketch_shape_vectors.json; the shapes come from the flat app's test fake).
## The seven drags of the investigation's C3 table (a point dragged 10 mm right and 5 mm up through PointDrag, synchronous, with no user constraint on any of them) reach the
## flat app's answers: a circle's centre translates it, its rim keeps the centre, a rectangle's centre translates it and its corner keeps the opposite corner, a polygon's
## centre translates it and its vertex keeps the centre, a slot's end centre keeps the other. A dimensioned centre is clamped (hybrid); a line moves both ends by one delta
## (a polygon edge drags its first vertex); the grab rule refuses a confirmed slot width, a fully pinned centre, and a pinned end. The worker-thread path ends where the
## synchronous one does. NOT checked: the feel, a real laser, a backend-made sketch (tests/e2e_sketch_shape_drag.gd does that).
## Run: "$GODOT" --headless --path . --script res://tests/sketch_shape_drag.gd  (see tests/README.md)

const Session := preload("res://scripts/design_table/sketch_session.gd")
const PointDrag := preload("res://scripts/design_table/point_drag.gd")
const FIXTURE := "res://tests/fixtures/sketch_shape_vectors.json"
const MOVE := Vector2(10.0, 5.0)

var failures := 0
var cases := {}


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


## A session holding one of the vector file's sketches (points, lines, arcs, constraints, shape records).
func _session(case_id: String) -> Object:
	var inp: Dictionary = (cases[case_id] as Dictionary)["input"]
	var s = Session.new(Callable())
	s.origin_id = "origin-1"
	for id in inp["points"]:
		var p: Array = inp["points"][id]
		s.points[id] = Vector2(p[0], p[1])
		s.point_xy[id] = [float(p[0]), float(p[1])]
		s.point_locked[id] = false
	for lid in inp["lines"]:
		s.lines[lid] = {"a": inp["lines"][lid][0], "b": inp["lines"][lid][1]}
	for sid in inp["shapes"]:
		var rec: Dictionary = (inp["shapes"][sid] as Dictionary).duplicate(true)
		s.shape_records[sid] = rec
		if rec["kind"] == "arc":
			s.arcs[sid] = {"c": rec["center_point_id"], "s": rec["start_point_id"], "e": rec["end_point_id"]}
	for c: Dictionary in inp["constraints"]:
		s.constraints[c["id"]] = c.duplicate(true)
	return s


## Drags `id` by MOVE in 12 frames from its place; returns {moved: id -> [x, y] (finish()'s updates), drag}.
func _drag_point(s, id: String, synchronous := true) -> Dictionary:
	var drag := PointDrag.new()
	drag.synchronous = synchronous
	var at: Vector2 = s.points[id]
	var ok := drag.begin(s, id, at)
	if not ok:
		return {"ok": false, "refusal": drag.refusal, "drag": drag}
	for i in range(1, 13):
		drag.step(at + MOVE * float(i) / 12.0)
		if not synchronous:
			drag.wait_all_frames()
	var drop := drag.finish()
	return {"ok": true, "moved": drop["updates"], "drag": drag}


func _same(p: Variant, x: float, y: float, tol := 1e-4) -> bool:
	return p is Array and absf(float(p[0]) - x) < tol and absf(float(p[1]) - y) < tol


func _shifted(s, moved: Dictionary, id: String) -> bool:
	## the point went by exactly MOVE
	var p: Vector2 = s.points[id]
	return moved.has(id) and _same(moved[id], p.x + MOVE.x, p.y + MOVE.y)


func _stays(moved: Dictionary, id: String) -> bool:
	return not moved.has(id)


func _initialize() -> void:
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	for c: Dictionary in doc["cases"]:
		cases[c["id"]] = c

	# --- the seven drags of C3's table, no user constraint on any
	var s = _session("circle-centre")
	var r := _drag_point(s, "point-1")
	var all_shifted := true
	for id in ["point-1", "point-3", "point-4", "point-5", "point-6"]:
		all_shifted = all_shifted and _shifted(s, r["moved"], id)
	_check(r["ok"] and all_shifted, "circle centre drag: the whole circle translates (centre, rim and the cardinals each by 10, 5)")

	s = _session("circle-cardinal-east")
	r = _drag_point(s, "point-4")
	var radius := float((r["moved"]["point-4"] as Array)[0]) - 40.0
	_check(r["ok"] and _stays(r["moved"], "point-1") and absf(radius - 20.0) < 1e-4 and _same(r["moved"]["point-6"], 20.0, 20.0), "circle rim drag: the centre stays, the radius becomes 20 (the cardinals follow, no wander): %s" % str(r["moved"]))

	s = _session("rectangle-centre")
	r = _drag_point(s, "point-16")
	all_shifted = true
	for id in ["point-1", "point-2", "point-3", "point-4", "point-16"]:
		all_shifted = all_shifted and _shifted(s, r["moved"], id)
	_check(r["ok"] and all_shifted, "rectangle centre drag: every corner translates by (10, 5)")

	s = _session("rectangle-corner")
	r = _drag_point(s, "point-1")
	_check(r["ok"] and _stays(r["moved"], "point-3") and _shifted(s, r["moved"], "point-1") and _same(r["moved"]["point-2"], 30.0, 15.0) and _same(r["moved"]["point-4"], 20.0, 25.0),
		"rectangle corner drag: the opposite corner stays, the neighbours keep the axes, the centre is the middle: %s" % str(r["moved"]))

	s = _session("polygon-centre")
	r = _drag_point(s, "point-1")
	all_shifted = true
	for id in s.points:
		if id != "origin-1":
			all_shifted = all_shifted and _shifted(s, r["moved"], id)
	_check(r["ok"] and all_shifted, "polygon centre drag: every vertex translates by (10, 5)")

	s = _session("polygon-vertex")
	r = _drag_point(s, "point-2")
	_check(r["ok"] and _stays(r["moved"], "point-1") and r["moved"].has("point-2"), "polygon vertex drag: the centre stays (a turn and a scale about it): %s" % str(r["moved"].keys()))

	s = _session("slot-centre")
	r = _drag_point(s, "point-1")
	_check(r["ok"] and _shifted(s, r["moved"], "point-1") and _stays(r["moved"], "point-2"), "slot end-centre drag: the other centre stays (the corners follow the new axis): %s" % str(r["moved"].keys()))

	# --- a user constraint clamps (hybrid): the centre dimensioned 20 mm from a point stays on its circle
	s = _session("circle-centre-dimensioned")
	var drag := PointDrag.new()
	drag.synchronous = true
	var at: Vector2 = s.points["point-2"]
	_check(drag.begin(s, "point-2", at) and drag.hybrid and drag.shape_kind == "circle", "a user dimension on the circle makes its drag hybrid (clamped by the projector)")
	for i in range(1, 13):
		drag.step(at + MOVE * float(i) / 12.0)
	var done: Dictionary = drag.moved()
	_check(not done.is_empty(), "...the clamped drag moved the circle: %s" % str(done.keys()))
	drag.cancel()

	# --- a line moves both ends by one delta
	s = _session("rectangle-corner")
	var d := PointDrag.new()
	d.synchronous = true
	var press := Vector2(20.0, 10.0)
	_check(d.begin_line(s, "line-6", press), "a press on a rectangle side starts a line drag (two anchors)")
	for i in range(1, 7):
		d.step(press + Vector2(0.0, -4.0) * float(i) / 6.0)
	var lm: Dictionary = d.moved()
	_check(d.grabbed == ["point-1", "point-2"] and _same(lm.get("point-1"), 10.0, 6.0) and _same(lm.get("point-2"), 30.0, 6.0), "...both ends go up 4 mm together (the drop's solve settles the rest): %s" % str(lm))
	d.cancel()

	s = _session("polygon-vertex")
	d = PointDrag.new()
	d.synchronous = true
	_check(d.begin_line(s, "line-9", Vector2(25.0, 20.0)) and d.grabbed.size() == 1 and d.shape_kind == "polygon", "a polygon edge drags its first vertex instead (the flat app's redirect), as a shape")
	d.cancel()

	# --- the pre-grab rule
	s = _session("slot-corner-radius-confirmed-refused")
	d = PointDrag.new()
	_check(not d.begin(s, "point-4", s.points["point-4"]) and d.refusal != "", "a slot corner with a dimensioned width is refused: %s" % d.refusal)
	s = _session("ellipse-minor-confirmed-refused")
	d = PointDrag.new()
	_check(not d.begin(s, "point-4", s.points["point-4"]) and d.refusal != "", "an ellipse's minor tip with a dimensioned minor radius is refused: %s" % d.refusal)
	s = _session("circle-centre")
	s.dof = 0 # the backend says the whole sketch is fully constrained
	d = PointDrag.new()
	_check(not d.begin(s, "point-1", s.points["point-1"]) and d.refusal != "", "a fully constrained sketch refuses a circle's centre: %s" % d.refusal)
	s = _session("circle-centre")
	s.point_locked["point-3"] = true
	d = PointDrag.new()
	_check(not d.begin(s, "point-3", s.points["point-3"]) and d.refusal.begins_with("That point is held"), "a locked rim point is refused as held in place")
	s = _session("rectangle-corner")
	s.constraints["a"] = {"id": "a", "type": "horizontal", "line_id": "line-6"}
	s.constraints["b"] = {"id": "b", "type": "vertical", "line_id": "line-6"}
	d = PointDrag.new()
	_check(not d.begin_line(s, "line-6", Vector2(20, 10)) and d.refusal != "", "a line that is both horizontal and vertical is refused: %s" % d.refusal)

	# --- the worker thread ends where the synchronous drag does
	s = _session("rectangle-corner")
	var sync_end: Dictionary = _drag_point(s, "point-1", true)["moved"]
	s = _session("rectangle-corner")
	var thread_end: Dictionary = _drag_point(s, "point-1", false)["moved"]
	var same := sync_end.size() == thread_end.size()
	for id in sync_end:
		same = same and thread_end.has(id) and _same(thread_end[id], sync_end[id][0], sync_end[id][1])
	_check(same, "the worker-thread drag of a shape ends where the synchronous one does")

	print("SMOKE ", "PASSED" if failures == 0 else "FAILED")
	quit(0 if failures == 0 else 1)
