extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): S6 of docs/dimension-constraint-parity-plan.md, editing
## what is there, on a real sketch (a new part, a sketch on XY). A line's Length, a circle's size, two lines' angle and a full ellipse's axes are made through the routes.
##   * A label dragged and dropped (move_label): the backend returns that placement (GET .../constraints), a fresh read draws the label at the pointer, Undo returns the old one.
##     The placement the ROUTE saves (PUT, as the flat app does) is drawn at the place it names.
##   * The R / diameter switch sends nothing; the diameter edit stores half.
##   * An angle's side: the backend holds the new quadrant with the angle that side measures and still converges; the lines did not move; Undo.
##   * A full ellipse's axis: the ellipse's size constraint holds the semi value, VR draws tip to tip with twice it, a placement dropped on its candidate is saved and is
##     drawn at the pointer (one of an elliptical arc's is not written from VR).
##   * The conflict rule: a dimension that cannot be met is taken back in a sketch that converged; in one that already fails it is kept unless the solver blames it.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_sketch_label_edit.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const DimLayout := preload("res://scripts/design_table/dimension_layout.gd")
const Flow := preload("res://scripts/design_table/dimension_preview.gd")

var main
var table
var api
var ed
var s


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


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


func backend_constraint(cid: String) -> Dictionary:
	var r: Dictionary = await s.api.call(HTTPClient.METHOD_GET, "/sketch/sketches/" + s.sketch_id + "/constraints", null)
	if r["ok"] and r["json"] is Array:
		for c in r["json"]:
			if str(c.get("id", "")) == cid:
				return c
	return {}


func drawn_at(cid: String) -> Variant:
	for it in s.dimension_items():
		if str(it["id"]) == cid:
			return DimLayout.layout(it["spec"], {"offset": 2.0, "arrow": 0.5, "gap": 0.2, "over": 0.3, "centroid": Vector2.ZERO, "text_h": 1.0, "text_w": 3.0})["text_uv"]
	return null


func dimension(entities: Array, key: String, value: float) -> String:
	s.set_tool("dimension")
	s.clear_selection()
	for e in entities:
		await s.select({"kind": e[0], "id": e[1]})
	var r: Dictionary = await s.confirm_ghost(key, value)
	return str(r.get("id", "")) if r.has("id") else ""


func newest(type: String) -> Dictionary:
	var best: Dictionary = {}
	for id in s.constraints:
		if str(s.constraints[id].get("type", "")) == type:
			best = s.constraints[id]
	return best


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
	print("SMOKE a sketch opens on XY: ", opened)

	# --- a label dragged
	var free_line: String = await line(Vector2(10, 10), Vector2(70, 50))
	await dimension([["line", free_line]], "length", 72.0)
	var c := newest("distance")
	var cid := str(c.get("id", ""))
	var g: Dictionary = s.label_candidate(cid)
	var pointer := Vector2(60, 15)
	var place: Dictionary = Flow.placement_at(s, g, pointer)
	var moved: Dictionary = await s.move_label(cid, place)
	var got := await backend_constraint(cid)
	var lbl: Variant = got.get("label")
	print("SMOKE a label dragged and dropped: the backend returns that placement: ", moved["ok"] and lbl is Dictionary and absf(float(lbl["offset"]) - float(place["offset"])) < 1e-4 and absf(float(lbl["along"]) - float(place["along"])) < 1e-4)
	await s.refresh(false)
	var at: Variant = drawn_at(cid)
	print("SMOKE ...and a fresh read draws the label where the pointer was: ", at != null and (at as Vector2).distance_to(pointer) < 1e-3)
	# a placement written by the route (as the flat app saves one) is drawn at the place it names
	var written := {"offset": -9.0, "along": 4.0}
	await s.api.call(HTTPClient.METHOD_PUT, "/sketch/sketches/" + s.sketch_id + "/constraints/" + cid + "/label", written)
	await s.refresh(false)
	var expected: Vector2
	var spec_a: Vector2 = s.points[s._line_points(free_line)[0]]
	var spec_b: Vector2 = s.points[s._line_points(free_line)[1]]
	var t := (spec_b - spec_a).normalized()
	expected = (spec_a + spec_b) * 0.5 + Vector2(-t.y, t.x) * -9.0 + t * 4.0
	at = drawn_at(cid)
	print("SMOKE a placement saved by the route is drawn where it says (offset -9, along 4): ", at != null and (at as Vector2).distance_to(expected) < 1e-3)
	await s.move_label(cid, place)
	await s.undo()
	got = await backend_constraint(cid)
	lbl = got.get("label")
	print("SMOKE Undo of a move puts the previous placement back on the backend: ", lbl is Dictionary and absf(float(lbl["offset"]) + 9.0) < 1e-4)

	# --- a circle's size: R / diameter
	s.set_tool("circle")
	await s.tap({"uv": Vector2(220, 60)})
	await s.tap({"uv": Vector2(232, 60)})
	var circ: String = s.circles.keys()[0]
	var k := str((s.circles[circ] as Dictionary).get("k", ""))
	s.set_tool("dimension")
	s.clear_selection()
	await s.select({"kind": "circle", "id": circ})
	await s.confirm_ghost("diameter", 30.0)
	print("SMOKE a circle's Diameter 30 stores the radius 15: ", absf(float(s.constraints[k].get("distance", 0.0)) - 15.0) < 1e-6)
	var before := await backend_constraint(k)
	# (F5: a dimension made with the Diameter candidate already reads as a diameter, and that choice is saved with it)
	await wait_for(func() -> bool: return not s.show_writes_pending())
	var after := await backend_constraint(k)
	print("SMOKE it reads as a diameter (the choice is saved in the label record) and the radius is unchanged on the backend: ", str(s.dimension_items().filter(func(it): return str(it["id"]) == k)[0]["text"]).begins_with("⌀") and float(after["distance"]) == float(before["distance"]) and str((after.get("label", {}) as Dictionary).get("show", "")) == "diameter")
	await s.edit_dimension(k, 20.0)
	print("SMOKE an edit of the shown diameter 20 stores the radius 10: ", absf(float((await backend_constraint(k))["distance"]) - 10.0) < 1e-6 and s.converged)
	s.toggle_diameter(k)
	await wait_for(func() -> bool: return not s.show_writes_pending())

	# --- an angle's side
	var la: String = await line(Vector2(100, 0), Vector2(160, 0))
	var lb: String = await line(Vector2(100, 0), Vector2(140, 40))
	var pts_before := {}
	for id in s.points:
		pts_before[id] = s.points[id]
	var ang_id := await dimension([["line", la], ["line", lb]], "angle", 45.0)
	var ang := newest("angle")
	ang_id = str(ang.get("id", ""))
	var r: Dictionary = await s.set_angle_side(ang_id)
	var now := await backend_constraint(ang_id)
	var moved_points := 0
	for id in pts_before:
		if s.points.has(id) and (s.points[id] as Vector2).distance_to(pts_before[id]) > 1e-3:
			moved_points += 1
	print("SMOKE Other side: the backend holds the next quadrant with the angle that side measures (135), converged: ", r["ok"] and int(now.get("quadrant", -1)) == 1 and absf(float(now.get("angle_degrees", 0.0)) - 135.0) < 0.01 and s.converged)
	print("SMOKE ...and no point moved: ", moved_points == 0)
	await s.undo()
	now = await backend_constraint(ang_id)
	print("SMOKE ...Undo puts the old side and value back: ", absf(float(now.get("angle_degrees", 0.0)) - 45.0) < 0.01)

	# --- a full ellipse's axis
	s.set_tool("ellipse")
	await s.tap({"uv": Vector2(300, 100)})
	await s.tap({"uv": Vector2(330, 100)})
	await s.tap({"uv": Vector2(300, 115)})
	var eid: String = s.ellipses.keys()[0] if not s.ellipses.is_empty() else ""
	print("SMOKE a full ellipse (30 x 15 semi axes) is made: ", eid != "")
	var km := str((s.ellipses[eid] as Dictionary).get("km", ""))
	s.set_tool("dimension")
	s.clear_selection()
	await s.select({"kind": "ellipse", "id": eid})
	var cands: Array = s.ghosts
	var cand := cands.filter(func(x): return x["key"] == "majordiameter")
	var spec: Dictionary = cand[0]["spec"] if not cand.is_empty() else {}
	var tip_to_tip: bool = not spec.is_empty() and absf((spec["a"] as Vector2).distance_to(spec["b"]) - 60.0) < 0.5
	print("SMOKE the Major diameter candidate is drawn tip to tip: ", tip_to_tip)
	var drop_at := Vector2(300, 140)
	var dg: Dictionary = Flow.new().drop(s, drop_at, 1.0)
	ed.dim_flow.sync(s)
	ed.dim_flow.choose(s, "majordiameter")
	ed.dim_flow.preview(s, drop_at, 1.0)
	dg = ed.dim_flow.drop(s, drop_at, 1.0)
	await ed.dimension_typed("majordiameter", "80", dg.duplicate(true))
	var ek := await backend_constraint(km)
	print("SMOKE typing the diameter 80 stores the semi axis 40 on the ellipse's own constraint: ", absf(float(ek.get("distance", 0.0)) - 40.0) < 1e-4)
	var elbl: Variant = ek.get("label")
	print("SMOKE ...its placement is saved on it, read back from the backend: ", elbl is Dictionary and (elbl as Dictionary).has("offset") and (elbl as Dictionary).has("along"))
	await s.refresh(false)
	var item: Dictionary = {}
	for it in s.dimension_items():
		if str(it["id"]) == km:
			item = it
	var drawn: Variant = drawn_at(km)
	print("SMOKE ...VR draws it tip to tip, twice the stored value, with its label at the drop point (the solve moved the centre 2 mm, the placement is relative to it): ", not item.is_empty() and str(item["text"]).contains("80") and drawn != null and absf((drawn as Vector2).y - drop_at.y) < 1e-3 and absf((drawn as Vector2).x - ((item["spec"]["a"] as Vector2).x + (item["spec"]["b"] as Vector2).x) * 0.5) < 1e-3)
	print("SMOKE ...and the value pad reads 80, an edit of 90 stores 45: ", absf(float(s.dimension_value(km)["value"]) - 80.0) < 1e-4 and bool((await s.edit_dimension(km, 90.0))["ok"]) and absf(float((await backend_constraint(km))["distance"]) - 45.0) < 1e-4)

	# --- the conflict rule (3.3, second refinement)
	var lc: String = await line(Vector2(10, 150), Vector2(60, 160))
	s.set_tool("select")
	s.clear_selection()
	await s.select({"kind": "line", "id": lc})
	var horiz: Dictionary = await s.apply_menu("horizontal")
	var count: int = s.constraints.size()
	s.set_tool("dimension")
	s.clear_selection()
	await s.select({"kind": "line", "id": lc})
	var bad: Dictionary = await s.confirm_ghost("horizontalAngle", 30.0)
	print("SMOKE a Horizontal line, then an angle to horizontal of 30: the solver cannot, so it is taken back and the sketch converges: ", horiz["ok"] and not bool(bad["ok"]) and s.converged and s.constraints.size() == count)
	# a conflict that comes later is kept; a new constraint in that failing sketch the solver does not blame is kept too
	var ld: String = await line(Vector2(100, 150), Vector2(150, 150))
	await dimension([["line", ld]], "length", 50.0)
	var len_c := newest("distance")
	s.set_tool("dimension")
	s.clear_selection()
	await s.select({"kind": "line", "id": ld})
	await s.confirm_ghost("h", 50.0)
	var h_c := newest("distance")
	await s.edit_dimension(str(h_c.get("id", "")), 60.0) # 60 across while the length is 50: a conflict that comes later
	print("SMOKE an edited value that conflicts is kept and the sketch no longer converges: ", not s.converged and s.constraints.has(str(h_c.get("id", ""))))
	var le: String = await line(Vector2(200, 150), Vector2(240, 150))
	count = s.constraints.size()
	s.set_tool("dimension")
	s.clear_selection()
	await s.select({"kind": "line", "id": le})
	var kept_dim: Dictionary = await s.confirm_ghost("length", 40.0)
	print("SMOKE in that failing sketch a new dimension elsewhere is kept (the failed list does not name it): ", bool(kept_dim["ok"]) and s.constraints.size() == count + 1 and not s.failed_constraint_ids.has(str(newest("distance").get("id", ""))))
	count = s.constraints.size()
	var lf: String = await line(Vector2(300, 150), Vector2(340, 155))
	count = s.constraints.size()
	s.set_tool("select")
	s.clear_selection()
	await s.select({"kind": "line", "id": lf})
	var rel: Dictionary = await s.apply_menu("horizontal")
	print("SMOKE ...and so is a Select menu relation: ", bool(rel["ok"]) and s.constraints.size() == count + 1)
	quit()
