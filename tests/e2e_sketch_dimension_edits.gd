extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): F5 of docs/parity-followups-investigation.md on a real sketch
## (a new part, a sketch on XY). Needs a DIDSA-CAD backend that has F4's `number` and `show` (branch ccr-30fb030e-pts96i until it is merged).
##   * C5: an existing two-line angle and a point-to-line distance typed again: ONE constraint, the new value (read back from the backend).
##   * A1: the backend's own names reach the breadcrumb (`Line 1`, `D1 ...`, never an id); the open sketch's rung is its feature name; an Undo that re-creates a dimension
##     brings it back with its number.
##   * C4 / decision 10: an elliptical arc's axis dimension is dropped with a radial placement and the backend stores {angle, leg, show}; the saved placement is read back
##     (also one the flat app would have saved); the semi / full and Radius / Diameter choices survive a reload and a placement PUT.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_sketch_dimension_edits.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const Crumbs := preload("res://scripts/design_table/selection_breadcrumbs.gd")

var main
var table
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


func backend_constraints() -> Array:
	var r: Dictionary = await s.api.call(HTTPClient.METHOD_GET, "/sketch/sketches/" + s.sketch_id + "/constraints", null)
	return r["json"] if r["ok"] and r["json"] is Array else []


func of_type(rows: Array, type: String) -> Array:
	return rows.filter(func(c): return str(c.get("type", "")) == type)


func line(a: Vector2, b: Vector2) -> String:
	s.set_tool("line")
	await s.tap({"uv": a})
	var before: Array = s.lines.keys()
	await s.tap({"uv": b})
	s.finish_chain()
	for id in s.lines:
		if not before.has(id):
			return id
	return ""


func fresh() -> void:
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await ed.begin_sketch({"fixed": "XY"})
	s = ed.session


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
	table.surface.settle_seconds = 0.0
	ed = table.editor

	# --- Two lines: the angle and a point's distance to a line, typed twice
	await fresh()
	_check(s != null and s.is_open(), "a sketch opens on XY")
	var l1: String = await line(Vector2(0, 0), Vector2(40, 0))
	var l2: String = await line(Vector2(0, 20), Vector2(25, 45))
	var pt := str(s.lines[l2]["a"])
	s.set_tool("dimension")
	s.clear_selection()
	await s.select({"kind": "line", "id": l1})
	await s.select({"kind": "line", "id": l2})
	var made: Dictionary = await s.confirm_ghost("angle", 30.0)
	_check(bool(made["ok"]), "the angle between the two lines is made: " + str(made.get("message", "")))
	s.clear_selection()
	await s.select({"kind": "line", "id": l2})
	await s.select({"kind": "line", "id": l1})
	var again: Dictionary = await s.confirm_ghost("angle", 45.0)
	var rows: Array = await backend_constraints()
	var angles := of_type(rows, "angle")
	_check(bool(again["ok"]) and angles.size() == 1 and absf(float(angles[0]["angle_degrees"]) - 45.0) < 0.01, "retyping the angle: the backend holds ONE angle, 45 (%d)" % angles.size())
	s.clear_selection()
	await s.select({"kind": "point", "id": pt})
	await s.select({"kind": "line", "id": l1})
	var first: Dictionary = await s.confirm_ghost("perpendicular", 20.0)
	s.clear_selection()
	await s.select({"kind": "point", "id": pt})
	await s.select({"kind": "line", "id": l1})
	var second: Dictionary = await s.confirm_ghost("perpendicular", 15.0)
	rows = await backend_constraints()
	var pld := of_type(rows, "point_line_distance")
	_check(bool(first["ok"]) and bool(second["ok"]) and pld.size() == 1 and absf(absf(float(pld[0]["distance"])) - 15.0) < 0.01, "retyping the point-to-line distance: the backend holds ONE, 15 (%d)" % pld.size())

	# --- Names from the backend
	var angle_id: String = str(angles[0]["id"]) if not angles.is_empty() else ""
	_check(s.number_of(l1) >= 1 and s.name_of("line", l1).begins_with("Line ") and not s.name_of("line", l1).contains(l1), "the backend's number reaches the session: " + s.name_of("line", l1))
	_check(s.name_of("point", s.origin_id) == "Origin", "the origin is `Origin`")
	var dim_name: String = s.name_of("dimension", angle_id)
	_check(dim_name.begins_with("D") and dim_name.contains("Angle"), "a dimension is `D<n> Angle 45`: " + dim_name)
	s.set_tool("select")
	s.clear_selection()
	await s.select({"kind": "line", "id": l1})
	var current: Array = ed.current_selection()
	var rungs: Array = Crumbs.chain(current, ed._drawer_context())
	print("SMOKE breadcrumb: ", " > ".join(rungs.map(func(r): return str(r["text"]))))
	_check(str(rungs[0]["text"]) == s.name_of("line", l1) and not str(rungs[0]["text"]).contains("-"), "the breadcrumb's first rung is the line's backend name")
	_check(str(rungs[1]["text"]) != "Sketch" or table.build == null, "the sketch rung is the open sketch's feature name (%s)" % str(rungs[1]["text"]))
	# an Undo that re-creates a dimension brings it back with its number
	var number_before: int = s.number_of(angle_id)
	s.annotations.append({"kind": "dimension", "id": angle_id})
	s.selection.clear() # (a selected line would be deleted with it, and that has no undo)
	await s.delete_annotations()
	await s.undo()
	rows = await backend_constraints()
	angles = of_type(rows, "angle")
	_check(angles.size() == 1 and int(angles[0].get("number", -1)) == number_before and number_before > 0, "Undo of a deleted dimension re-creates it with its old number (D%d)" % number_before)

	# --- An elliptical arc's axis: radial placement saved, the flat app's placement read, the choice kept
	await fresh()
	s.set_tool("ellipse_arc")
	table.manager.activate("ellipse_arc")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(20, 0)})
	await s.tap({"uv": Vector2(0, 10)})
	await s.tap({"uv": Vector2(20, 0)})
	await s.tap({"uv": Vector2(-20, 0)})
	var aid: String = s.ellipse_arcs.keys()[0] if not s.ellipse_arcs.is_empty() else ""
	_check(aid != "", "an elliptical arc is drawn")
	s.set_tool("dimension")
	s.clear_selection()
	await s.select({"kind": "ellipse_arc", "id": aid})
	var cand: Dictionary = (s.ghosts.filter(func(c): return c["key"] == "majorradius") + [{}])[0]
	_check(not cand.is_empty() and cand["spec"]["kind"] == "radius", "the arc's semi-axis candidate is a radial leader")
	var dropped: Dictionary = cand.duplicate(true)
	dropped["place"] = {"angle": 30.0, "leg": 3.0}
	var arc_made: Dictionary = await s.confirm_ghost("majorradius", 20.0, dropped)
	rows = await backend_constraints()
	var axis_row: Dictionary = {}
	for c in rows:
		if str(c.get("type", "")) == "distance" and c.get("label") is Dictionary and not (c["label"] as Dictionary).is_empty():
			axis_row = c
	var label: Dictionary = axis_row.get("label", {}) if axis_row.get("label") is Dictionary else {}
	_check(bool(arc_made["ok"]) and absf(float(label.get("angle", 0.0)) - 30.0) < 0.01 and absf(float(label.get("leg", 0.0)) - 3.0) < 0.01, "the axis's radial placement is saved on the backend: " + str(label))
	var axis_id := str(axis_row.get("id", ""))
	await s.refresh(true)
	var item := {}
	for it in s.dimension_items():
		if str(it["id"]) == axis_id:
			item = it
	var tip: Vector2 = s.points[s.ellipse_arcs[aid]["ma"]]
	var centre: Vector2 = s.points[s.ellipse_arcs[aid]["c"]]
	var want_u := Vector2.from_angle((tip - centre).angle() + deg_to_rad(30.0))
	_check(not item.is_empty() and item["spec"]["kind"] == "radius" and (item["spec"]["u"] as Vector2).distance_to(want_u) < 0.01 and absf(float(item["spec"]["label_r"]) - (tip.distance_to(centre) + 3.0)) < 0.01, "after a reload the placed axis is read back as drawn")
	# a placement the flat app saved (kind `radius`: {angle, leg}) is read the same way
	var put: Dictionary = await s.api.call(HTTPClient.METHOD_PUT, "/sketch/sketches/" + s.sketch_id + "/constraints/" + axis_id + "/label", {"angle": 120.0, "leg": 5.0})
	await s.refresh(true)
	item = {}
	for it in s.dimension_items():
		if str(it["id"]) == axis_id:
			item = it
	var want_u2 := Vector2.from_angle((tip - centre).angle() + deg_to_rad(120.0))
	_check(bool(put["ok"]) and not item.is_empty() and (item["spec"]["u"] as Vector2).distance_to(want_u2) < 0.01, "a placement the flat app saved is read")
	# the toggle: Show full axis is saved, survives a placement PUT and a reload
	_check(s.toggle_axis(axis_id), "the axis toggles")
	await wait_for(func() -> bool: return not s.show_writes_pending())
	await s.save_label(axis_id, {"angle": 60.0, "leg": 2.0})
	s.axis_semi.clear()
	await s.refresh(true)
	rows = await backend_constraints()
	var stored: Dictionary = {}
	for c in rows:
		if str(c.get("id", "")) == axis_id:
			stored = c
	_check(stored.get("label", {}).get("show") == "full" and absf(float(stored["label"].get("angle", 0.0)) - 60.0) < 0.01, "the saved `show` survives a placement PUT on the backend: " + str(stored.get("label", {})))
	_check(s.show_of(axis_id) == "full" and absf(float(s.dimension_value(axis_id)["value"]) - 2.0 * float(stored["distance"])) < 0.01, "a reload reads it back: the pad shows the full axis (twice the stored value)")
	var typed: Dictionary = await s.edit_dimension(axis_id, 60.0)
	rows = await backend_constraints()
	for c in rows:
		if str(c.get("id", "")) == axis_id:
			stored = c
	_check(bool(typed["ok"]) and absf(float(stored["distance"]) - 30.0) < 0.01, "show full, type 60: the backend stores 30")

	# --- Radius / Diameter is saved too
	await fresh()
	table.manager.activate("circle")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(8, 0)})
	var cid: String = s.circles.keys()[0] if not s.circles.is_empty() else ""
	var k: String = str(s.circles[cid]["k"]) if cid != "" else ""
	_check(k != "" and s.toggle_diameter(k), "a circle's size dimension switches to the diameter")
	await wait_for(func() -> bool: return not s.show_writes_pending())
	s.diameter_shown.clear()
	await s.refresh(true)
	_check(s.show_of(k) == "diameter" and absf(float(s.dimension_value(k)["value"]) - 16.0) < 0.01, "a reload reads the diameter back (saved in the label record)")

	print("SMOKE dimension edits e2e failures: ", failures)
	quit(1 if failures > 0 else 0)
