extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): F8 of docs/parity-followups-investigation.md, shape and line
## drags on sketches made through the routes VR's tools use (a new part, a sketch on XY). The seven drags of C3's table (a circle's centre and rim, a rectangle's centre and
## corner, a polygon's centre and vertex, a slot's end centre; each 10 mm right and 5 mm up through PointDrag) reach the flat app's answers: a centre drag translates the shape, a
## rim / vertex drag keeps the centre, a corner drag keeps the opposite corner, a slot's end keeps the other end. Each is DROPPED with SketchSession.drop_points (one
## solve-and-refresh): the backend's stored points equal the session's, the kept points are where they were, and ONE Undo puts every stored point back. A free line dragged by
## its body moves both ends by the same delta and is dropped the same way.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_sketch_shape_drag.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const PointDrag := preload("res://scripts/design_table/point_drag.gd")
const MOVE := Vector2(10.0, 5.0)

var main
var table
var api
var ed
var s
var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func backend_points() -> Dictionary:
	var r: Dictionary = await s.api.call(HTTPClient.METHOD_GET, "/sketch/sketches/" + s.sketch_id + "/points", null)
	var out := {}
	if r["ok"] and r["json"] is Array:
		for p in r["json"]:
			out[str(p["id"])] = Vector2(float(p["x"]), float(p["y"]))
	return out


func record_of(kind: String) -> Dictionary:
	for id in s.shape_records:
		if str(s.shape_records[id]["kind"]) == kind:
			return s.shape_records[id]
	return {}


func shifted(ids: Array, p0: Dictionary, p1: Dictionary, by: Vector2, tol := 1e-3) -> bool:
	for id in ids:
		if not p1.has(id) or ((p1[id] as Vector2) - (p0[id] as Vector2) - by).length() > tol:
			return false
	return true


func stayed(ids: Array, p0: Dictionary, p1: Dictionary, tol := 1e-3) -> bool:
	for id in ids:
		if not p1.has(id) or ((p1[id] as Vector2) - (p0[id] as Vector2)).length() > tol:
			return false
	return true


## One drag of `id` by MOVE (`line` = a line id: both ends), dropped; checks the session against the backend, then one Undo. Returns {before, after (backend), moved (the drop's
## ids), kind (the drag's shape family)}.
func drag_drop(label: String, id: String, line := false) -> Dictionary:
	var before: Dictionary = await backend_points()
	var p0: Dictionary = s.points.duplicate()
	var d := PointDrag.new()
	d.synchronous = true
	var at: Vector2 = s.points[id] if not line else Vector2.ZERO
	if line:
		var l: Dictionary = s.lines[id]
		at = ((s.points[l["a"]] as Vector2) + (s.points[l["b"]] as Vector2)) * 0.5
	var started: bool = d.begin_line(s, id, at) if line else d.begin(s, id, at)
	_check(started, "%s: the grab is accepted (%s)" % [label, d.refusal])
	if not started:
		return {}
	for i in range(1, 21):
		d.step(at + MOVE * float(i) / 20.0)
	var drop: Dictionary = d.finish()
	var result: Dictionary = await s.drop_points(drop)
	_check(bool(result["ok"]), "%s: the drop is accepted by the backend (%s)" % [label, str(result["message"])])
	var after: Dictionary = await backend_points()
	var same := true
	for pid in s.points:
		if not after.has(pid) or (after[pid] as Vector2).distance_to(s.points[pid]) > 1e-3:
			same = false
	_check(same, "%s: the session shows the backend's stored points" % label)
	var out := {"before": before, "after": after, "p0": p0, "moved": (drop["updates"] as Dictionary).keys(), "kind": d.shape_kind, "hybrid": d.hybrid, "result": result}
	return out


func undo_restores(label: String, before: Dictionary) -> void:
	_check(s.can_undo() and s.undo_label() == "point move", "%s: the drop is one Undo step" % label)
	await s.undo()
	var back: Dictionary = await backend_points()
	var restored := true
	for id in before:
		if not back.has(id) or (back[id] as Vector2).distance_to(before[id]) > 1e-3:
			restored = false
	_check(restored, "%s: Undo puts every stored point back" % label)


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend, see tests/README.md")
		quit()
		return
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	var url := str(cfg.get_value("backend", "url"))
	var key := str(cfg.get_value("backend", "api_key"))
	main.backend_url = url
	main.api_key = key
	table = main.design_table
	table.configure_backend(url, key)
	api = table.api
	table.surface.settle_seconds = 0.0
	ed = table.editor

	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	var opened: bool = await ed.begin_sketch({"fixed": "XY"})
	s = ed.session
	_check(opened, "a sketch opens on XY")

	# --- the shapes, each in its own corner of the sheet, no user constraint on any
	s.set_tool("circle")
	await s.tap({"uv": Vector2(30, 30)})
	await s.tap({"uv": Vector2(40, 30)})
	s.set_tool("rectangle")
	s.rect_method = "centre"
	await s.tap({"uv": Vector2(94, 31)})
	await s.tap({"uv": Vector2(104, 41)})
	s.set_tool("polygon")
	await s.tap({"uv": Vector2(30, 80)})
	await s.tap({"uv": Vector2(40, 80)})
	s.set_tool("line")
	await s.tap({"uv": Vector2(30, 130)})
	await s.tap({"uv": Vector2(60, 134)})
	s.set_tool("select")
	var circle := record_of("circle")
	var rect := record_of("rectangle")
	var poly := record_of("polygon")
	_check(not circle.is_empty() and not rect.is_empty() and not poly.is_empty(), "a circle, a rectangle (centre method) and a hexagon are in the sketch (the records the proposals read)")
	if circle.is_empty() or rect.is_empty() or poly.is_empty():
		print("SMOKE FAILED (%d)" % (failures + 1))
		quit(1)
		return
	_check(not circle.has("structural_constraint_ids"), "the sketch state's records do NOT carry structural_constraint_ids (a press fetches them: load_shape_structure)")
	await s.load_shape_structure(str(circle["center_point_id"]))
	circle = record_of("circle")
	_check(circle.has("structural_constraint_ids") and (circle["structural_constraint_ids"] as Array).size() > 0, "...after the press's one GET the circle's record carries them (%d)" % (circle.get("structural_constraint_ids", []) as Array).size())
	_check(s.converged, "the sketch solves before any drag (converged %s, dof %d)" % [str(s.converged), s.dof])
	var circle_pts: Array = [circle["center_point_id"], circle["radius_point_id"]] + (circle["cardinal_point_ids"] as Array)
	var rect_corners: Array = rect["corner_point_ids"]
	var poly_pts: Array = (poly["vertex_point_ids"] as Array).duplicate()
	poly_pts.append(poly["center_point_id"])

	# 1. circle centre: translates
	var r1 := await drag_drop("circle centre", str(circle["center_point_id"]))
	_check(r1.get("kind", "") == "circle" and shifted(circle_pts, r1["before"], r1["after"], MOVE), "circle centre drag: the whole circle translates (centre, rim and cardinals by 10, 5 in the backend)")
	await undo_restores("circle centre", r1["before"])

	# 2. circle rim: the centre stays, the radius changes
	var r2 := await drag_drop("circle rim", str(circle["radius_point_id"]))
	var c_id := str(circle["center_point_id"])
	var rim: Vector2 = r2["after"][str(circle["radius_point_id"])]
	var radius: float = rim.distance_to(r2["after"][c_id])
	var round_ok := true
	for cid in circle["cardinal_point_ids"]:
		round_ok = round_ok and absf((r2["after"][cid] as Vector2).distance_to(r2["after"][c_id]) - radius) < 1e-3
	_check(stayed([c_id], r2["before"], r2["after"]) and round_ok and absf(radius - 10.0) > 1.0, "circle rim drag: the centre stays (a dragged rim no longer carries it away), the circle is still round, radius %.3f (was 10)" % radius)
	await undo_restores("circle rim", r2["before"])

	# 3. rectangle centre: translates
	var r3 := await drag_drop("rectangle centre", str(rect["center_point_id"]))
	_check(r3.get("kind", "") == "rectangle" and shifted(rect_corners + [rect["center_point_id"]], r3["before"], r3["after"], MOVE), "rectangle centre drag: every corner translates by (10, 5)")
	await undo_restores("rectangle centre", r3["before"])

	# 4. rectangle corner: the opposite corner stays
	var r4 := await drag_drop("rectangle corner", str(rect_corners[0]))
	_check(stayed([rect_corners[2]], r4["before"], r4["after"]) and shifted([rect_corners[0]], r4["before"], r4["after"], MOVE), "rectangle corner drag: the opposite corner stays, the dragged one went by (10, 5)")
	await undo_restores("rectangle corner", r4["before"])

	# 5. polygon centre: translates
	var r5 := await drag_drop("polygon centre", str(poly["center_point_id"]))
	_check(r5.get("kind", "") == "polygon" and shifted(poly_pts, r5["before"], r5["after"], MOVE), "polygon centre drag: every vertex translates by (10, 5)")
	await undo_restores("polygon centre", r5["before"])

	# 6. polygon vertex: the centre stays
	var r6 := await drag_drop("polygon vertex", str((poly["vertex_point_ids"] as Array)[0]))
	_check(stayed([poly["center_point_id"]], r6["before"], r6["after"]), "polygon vertex drag: the centre stays")
	await undo_restores("polygon vertex", r6["before"])

	# 8. a free line by its body: both ends by one delta
	var line_id := ""
	for id in s.lines:
		var l: Dictionary = s.lines[id]
		if (s.points[l["a"]] as Vector2).distance_to(Vector2(30, 130)) < 0.5:
			line_id = str(id)
	_check(line_id != "", "a free line to drag")
	if line_id != "":
		var l: Dictionary = s.lines[line_id]
		var r8 := await drag_drop("line", line_id, true)
		_check(shifted([l["a"], l["b"]], r8["before"], r8["after"], MOVE, 0.5), "line drag: both ends went by the same (10, 5) in the backend")
		await undo_restores("line", r8["before"])

	# 9. a user dimension on the circle makes its drag hybrid: the centre dimensioned to the origin keeps that distance (clamped by the projector), and the drop stores it
	var cen := str(circle["center_point_id"])
	var dist0: float = (s.points[cen] as Vector2).distance_to(s.points[s.origin_id])
	var made: Dictionary = await s.api.call(HTTPClient.METHOD_POST, "/sketch/sketches/" + s.sketch_id + "/constraints", {"type": "distance", "point_a_id": s.origin_id, "point_b_id": cen, "distance": dist0})
	await s.refresh(false)
	await s.load_shape_structure(cen)
	_check(bool(made["ok"]), "a dimension from the origin to the circle's centre (%.3f mm)" % dist0)
	var r9 := await drag_drop("dimensioned circle centre", cen)
	var d9: float = (r9["after"][cen] as Vector2).distance_to(r9["after"][s.origin_id])
	_check(bool(r9.get("hybrid", false)) and absf(d9 - dist0) < 1e-3 and not shifted([cen], r9["before"], r9["after"], MOVE, 0.5),
		"dimensioned circle centre drag: hybrid, the clamp keeps %.3f mm to the origin (%.4f) and the centre did not go the whole (10, 5)" % [dist0, d9])
	await undo_restores("dimensioned circle centre", r9["before"])

	# 7. slot end centre: the other centre stays. A slot of its own sketch: any rectangle drawn in a sketch with a slot made this backend report "not converged" with nothing
	# failed (found writing this test; a backend question, not looked into: docs/status.md)
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	opened = await ed.begin_sketch({"fixed": "XY"})
	s = ed.session
	s.set_tool("slot")
	await s.tap({"uv": Vector2(80, 80)})
	await s.tap({"uv": Vector2(100, 80)})
	await s.tap({"uv": Vector2(90, 86)})
	s.set_tool("select")
	var slot := record_of("slot")
	_check(opened and not slot.is_empty() and s.converged, "a slot in a sketch of its own, and it solves")
	if not slot.is_empty():
		await s.load_shape_structure(str(slot["center1_point_id"]))
		var r7 := await drag_drop("slot end centre", str(slot["center1_point_id"]))
		_check(r7.get("kind", "") == "slot" and stayed([slot["center2_point_id"]], r7["before"], r7["after"]) and shifted([slot["center1_point_id"]], r7["before"], r7["after"], MOVE), "slot end-centre drag: the other centre stays, this one went by (10, 5)")
		await undo_restores("slot end centre", r7["before"])

	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
