extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): the six part D dimension types (arc length,
## angle to horizontal, three-point angle, and the minimum / maximum distances from a point, a line and a circle to a circle) seen and touched from VR (S2 of
## docs/dimension-constraint-parity-plan.md). A new part, a sketch on XY with a line pair, a quarter arc and two circles; for each type:
##   * made through the backend's routes (VR makes them from a pick only from S4), read back by the sketch session, and drawn (`dimension_items`) with its own
##     text (the arc mark and the number, degrees, a plain length) and layout spec (arc length, angle, a linear dimension between the measured ends);
##   * a saved quadrant is drawn (the angle to horizontal at the line's end, against -x) and survives an edited value;
##   * its value is edited (`dimension_value` / `edit_dimension`: the field per type) and the geometry follows;
##   * a label placement written through `PUT .../constraints/{id}/label` is read back and the label is drawn exactly where it says;
##   * Delete takes it away (and Undo brings it back); deleting a circle takes its distances with it;
##   * reference dimensions of the part D kinds (the five the backend stores) are drawn in brackets.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_sketch_dimension_types.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const DimLayout := preload("res://scripts/design_table/dimension_layout.gd")

var main
var table
var api
var s


func req(method: int, path: String, body = null) -> Dictionary:
	return await api.request(method, path, body)


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


func circle(centre: Vector2, rim: Vector2) -> String:
	var before: Array = s.circles.keys()
	s.set_tool("circle")
	await s.tap({"uv": centre})
	await s.tap({"uv": rim})
	for id in s.circles:
		if not before.has(id):
			return id
	return ""


func make(body: Dictionary) -> String:
	## A constraint through the route; its id once the session has read it back ("" if refused).
	var before: Array = s.constraints.keys()
	var r: Dictionary = await req(HTTPClient.METHOD_POST, "/sketch/sketches/%s/constraints" % s.sketch_id, body)
	await s.refresh(false)
	if not r["ok"]:
		print("  refused: ", body["type"], " ", r.get("error"))
		return ""
	for id in s.constraints:
		if not before.has(id) and str(s.constraints[id].get("type", "")) == str(body["type"]):
			return str(id)
	return ""


func item_of(id: String) -> Dictionary:
	for item in s.dimension_items():
		if str(item["id"]) == id:
			return item
	return {}


func params() -> Dictionary:
	return {"offset": 6.0, "arrow": 2.0, "gap": 1.0, "over": 1.5, "centroid": Vector2(100, 60), "text_h": 5.0, "text_w": 14.0}


func laid(id: String) -> Dictionary:
	return DimLayout.layout(item_of(id)["spec"], params())


func put_label(id: String, body: Dictionary) -> bool:
	var r: Dictionary = await req(HTTPClient.METHOD_PUT, "/sketch/sketches/%s/constraints/%s/label" % [s.sketch_id, id], body)
	await s.refresh(false)
	return bool(r["ok"])


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

	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return table.editor.state == "pick_plane")
	var opened: bool = await table.editor.begin_sketch({"fixed": "XY"})
	s = table.editor.session
	print("SMOKE a sketch opens on XY: ", opened)

	# the geometry: two lines, a quarter arc, two circles, a free point
	var la: String = await line(Vector2(10, 10), Vector2(70, 50))
	var lb: String = await line(Vector2(10, 110), Vector2(90, 110))
	s.set_tool("arc")
	await s.tap({"uv": Vector2(200, 0)})
	await s.tap({"uv": Vector2(230, 0)})
	await s.tap({"uv": Vector2(200, 30)})
	var arc_id: String = s.arcs.keys()[0] if not s.arcs.is_empty() else ""
	var c1: String = await circle(Vector2(200, 140), Vector2(210, 140))
	var c2: String = await circle(Vector2(260, 140), Vector2(268, 140))
	s.set_tool("point")
	await s.tap({"uv": Vector2(120, -40)})
	var free_pt := ""
	for id in s.points:
		if (s.points[id] as Vector2).distance_to(Vector2(120, -40)) < 0.01:
			free_pt = str(id)
	print("SMOKE the sketch holds two lines, an arc, two circles and a point: ", la != "" and lb != "" and arc_id != "" and c1 != "" and c2 != "" and free_pt != "")
	var la_start: String = s.lines[la]["a"]
	var la_end: String = s.lines[la]["b"]
	var lb_start: String = s.lines[lb]["a"]
	var arc_len: float = 30.0 * PI * 0.5

	# --- made through the routes, read back and drawn
	var k_arc := await make({"type": "arc_length", "arc_id": arc_id, "length": arc_len})
	var k_hang := await make({"type": "horizontal_angle", "line_id": la, "angle_degrees": rad_to_deg(atan2(40.0, 60.0)), "quadrant": 3})
	var k_pang := await make({"type": "point_angle", "vertex_point_id": la_start, "point1_id": la_end, "point2_id": lb_start, "angle_degrees": rad_to_deg(atan2(100.0, 0.0) - atan2(40.0, 60.0))})
	var k_pc := await make({"type": "point_circle_distance", "point_id": free_pt, "circle_or_arc_id": c2, "distance": 20.0, "side": "min"})
	var k_cc := await make({"type": "circle_distance", "entity1_id": c1, "entity2_id": c2, "distance": 42.0, "side": "min"})
	var k_lc := await make({"type": "line_circle_distance", "line_id": lb, "circle_or_arc_id": c1, "distance": 20.0, "side": "min"})
	print("SMOKE all six part D constraints were accepted and read back (converged): ", k_arc != "" and k_hang != "" and k_pang != "" and k_pc != "" and k_cc != "" and k_lc != "" and s.converged)
	var i_arc := item_of(k_arc)
	var i_hang := item_of(k_hang)
	var i_pang := item_of(k_pang)
	var i_pc := item_of(k_pc)
	var i_cc := item_of(k_cc)
	var i_lc := item_of(k_lc)
	print("SMOKE the arc length is drawn as an arc dimension with the arc sign and its number: ", not i_arc.is_empty() and i_arc["spec"]["kind"] == "arc_length" and i_arc["text"] == "⌒" + Session_format(arc_len), " ", i_arc.get("text"))
	print("SMOKE the two angles are drawn as angle arcs in degrees: ", not i_hang.is_empty() and i_hang["spec"]["kind"] == "angle" and str(i_hang["text"]).ends_with("°") and not i_pang.is_empty() and i_pang["spec"]["kind"] == "angle" and str(i_pang["text"]).ends_with("°"), " ", i_hang.get("text"), " ", i_pang.get("text"))
	print("SMOKE the three distances are linear dimensions between the measured ends (their lengths are the constraints' values): ",
		not i_pc.is_empty() and not i_cc.is_empty() and not i_lc.is_empty() and i_pc["spec"]["kind"] == "linear" and i_cc["spec"]["kind"] == "linear" and i_lc["spec"]["kind"] == "linear"
		and absf((i_pc["spec"]["a"] as Vector2).distance_to(i_pc["spec"]["b"]) - float(s.constraints[k_pc]["distance"])) < 0.05
		and absf((i_cc["spec"]["a"] as Vector2).distance_to(i_cc["spec"]["b"]) - float(s.constraints[k_cc]["distance"])) < 0.05
		and absf((i_lc["spec"]["a"] as Vector2).distance_to(i_lc["spec"]["b"]) - float(s.constraints[k_lc]["distance"])) < 0.05)
	var hang_apex: Vector2 = i_hang["spec"]["apex"]
	print("SMOKE the angle to horizontal saved with quadrant 3 is drawn at the line's END, against the -x ray: ", s.constraints[k_hang].get("quadrant") == 3 and hang_apex.distance_to(s.points[la_end]) < 0.05 and (i_hang["spec"]["d2"] as Vector2) == Vector2(-1, 0))
	var all_drawn := true
	for id in [k_arc, k_hang, k_pang, k_pc, k_cc, k_lc]:
		var l := laid(id)
		all_drawn = all_drawn and ((l["segments"] as Array).size() + (l["arcs"] as Array).size() > 0) and (l["text_uv"] as Vector2).is_finite()
	print("SMOKE every one of them lays out (lines or arcs, a finite label place): ", all_drawn)

	# --- values: read, edited (the geometry follows), the angles keep their quadrant
	var v_arc: Dictionary = s.dimension_value(k_arc)
	var v_hang: Dictionary = s.dimension_value(k_hang)
	var v_cc: Dictionary = s.dimension_value(k_cc)
	print("SMOKE dimension_value reads every type (arc length: length in mm; angles: degrees; distances: mm): ", v_arc["ok"] and v_arc["unit"] == "mm" and absf(float(v_arc["value"]) - arc_len) < 0.01 and v_hang["ok"] and v_hang["unit"] == "deg" and v_cc["ok"] and absf(float(v_cc["value"]) - 42.0) < 0.01 and s.dimension_value(k_pang)["unit"] == "deg" and s.dimension_value(k_pc)["ok"] and s.dimension_value(k_lc)["ok"])
	var e_arc: Dictionary = await s.edit_dimension(k_arc, 40.0)
	var arc_now: float = absf(float(s.constraints[k_arc]["length"]) - 40.0)
	var e_hang: Dictionary = await s.edit_dimension(k_hang, 45.0)
	var line_angle := rad_to_deg(((s.points[la_end] as Vector2) - (s.points[la_start] as Vector2)).angle())
	var e_pang: Dictionary = await s.edit_dimension(k_pang, 60.0)
	var e_pc: Dictionary = await s.edit_dimension(k_pc, 25.0)
	var e_cc: Dictionary = await s.edit_dimension(k_cc, 50.0)
	var e_lc: Dictionary = await s.edit_dimension(k_lc, 25.0)
	print("SMOKE an edited arc length changes on the backend and the arc follows: ", e_arc["ok"] and arc_now < 0.01)
	print("SMOKE an edited angle to horizontal turns the line (45 degrees) and keeps its quadrant 3: ", e_hang["ok"] and absf(absf(line_angle) - 45.0) < 0.1 and s.constraints[k_hang].get("quadrant") == 3, " ", line_angle, " ", s.constraints[k_hang].get("quadrant"))
	print("SMOKE the other four edits are taken (a three-point angle, a point's, a circle pair's and a line's distance to a circle): ", e_pang["ok"] and e_pc["ok"] and e_cc["ok"] and e_lc["ok"] and absf(float(s.constraints[k_pc]["distance"]) - 25.0) < 0.001 and absf(float(s.constraints[k_cc]["distance"]) - 50.0) < 0.001 and absf(float(s.constraints[k_lc]["distance"]) - 25.0) < 0.001 and absf(float(s.constraints[k_pang]["angle_degrees"]) - 60.0) < 0.001, " ", [e_pang, e_pc, e_cc, e_lc])
	await s.undo()
	print("SMOKE Undo puts the last edit back (the line-to-circle distance is 20 again): ", absf(float(s.constraints[k_lc]["distance"]) - 20.0) < 0.001)

	# --- a placement written by the route is drawn where it says
	var placed := {}
	placed[k_arc] = {"leg": 8.0, "angle": 20.0}
	placed[k_hang] = {"radius": 25.0, "angle": -5.0}
	placed[k_pang] = {"radius": 30.0, "angle": 10.0}
	placed[k_pc] = {"offset": 12.0, "along": 3.0}
	placed[k_cc] = {"offset": -9.0, "along": -2.0}
	placed[k_lc] = {"offset": 6.0, "along": 4.0}
	var wrote := true
	for id in placed:
		wrote = wrote and await put_label(id, placed[id])
	var read_back := true
	for id in placed:
		var lab: Variant = s.constraints[id].get("label")
		read_back = read_back and lab is Dictionary
		if lab is Dictionary:
			for k in placed[id]:
				read_back = read_back and absf(float((lab as Dictionary).get(k, 1e9)) - float(placed[id][k])) < 1e-6
	print("SMOKE a placement written by PUT .../label comes back on the constraint the session reads: ", wrote and read_back)
	var off := {}
	for id in [k_pc, k_cc, k_lc]:
		var sp: Dictionary = item_of(id)["spec"]
		var a: Vector2 = sp["a"]
		var b: Vector2 = sp["b"]
		var t := (b - a).normalized()
		var n := Vector2(-t.y, t.x)
		var want: Vector2 = (a + b) * 0.5 + n * float(placed[id]["offset"]) + t * float(placed[id]["along"])
		off[id] = (laid(id)["text_uv"] as Vector2).distance_to(want)
	print("SMOKE the three distances' labels are drawn exactly at their saved offset / along (within 0.01 mm): ", off[k_pc] < 0.01 and off[k_cc] < 0.01 and off[k_lc] < 0.01, " ", off)
	var ang_off := {}
	for id in [k_hang, k_pang]:
		var sp: Dictionary = item_of(id)["spec"]
		var a1: float = (sp["d1"] as Vector2).angle()
		var sweep := wrapf((sp["d2"] as Vector2).angle() - a1, -PI, PI)
		var want: Vector2 = (sp["apex"] as Vector2) + Vector2.from_angle(a1 + sweep * 0.5 + deg_to_rad(float(placed[id]["angle"]))) * float(placed[id]["radius"])
		ang_off[id] = (laid(id)["text_uv"] as Vector2).distance_to(want)
	var sp_arc: Dictionary = item_of(k_arc)["spec"]
	var arc_want: Vector2 = (sp_arc["c"] as Vector2) + Vector2.from_angle(float(sp_arc["a0"]) + float(sp_arc["sweep"]) * 0.5 + deg_to_rad(20.0)) * (float(sp_arc["r"]) + 8.0)
	print("SMOKE the two angles' labels sit on their saved radius at their saved angle from the arc's middle, the arc length's at leg 8 and angle 20: ", ang_off[k_hang] < 0.01 and ang_off[k_pang] < 0.01 and (laid(k_arc)["text_uv"] as Vector2).distance_to(arc_want) < 0.01, " ", ang_off)

	# --- Delete (and Undo), and a deleted circle takes its distances with it
	var kept_lines: int = s.lines.size()
	s.clear_selection()
	s.toggle_annotation("dimension", k_cc)
	var gone: Dictionary = await s.apply_menu("delete")
	print("SMOKE Delete on a circle distance takes the constraint away and leaves the circles: ", gone["ok"] and not s.constraints.has(k_cc) and s.circles.has(c1) and s.circles.has(c2) and s.lines.size() == kept_lines)
	await s.undo()
	var back := 0
	for cid in s.constraints:
		if str(s.constraints[cid].get("type", "")) == "circle_distance" and absf(float(s.constraints[cid]["distance"]) - 50.0) < 0.001:
			back += 1
	print("SMOKE ...and Undo makes it again (a circle distance of 50): ", back == 1)
	var every_delete := true
	for id in [k_arc, k_hang, k_pang, k_pc, k_lc]:
		s.clear_selection()
		s.toggle_annotation("dimension", id)
		var g: Dictionary = await s.apply_menu("delete")
		every_delete = every_delete and g["ok"] and not s.constraints.has(id)
	print("SMOKE Delete works for the other five types, one by one: ", every_delete)
	s.clear_selection()
	s.set_tool("select")
	await s.select({"kind": "circle", "id": c2})
	var cascade: Dictionary = await s.delete_selection()
	var left_with_c2 := 0
	for cid in s.constraints:
		if str(s.constraints[cid].get("type", "")) == "circle_distance":
			left_with_c2 += 1
	print("SMOKE deleting a circle takes the circle distance that named it with it: ", cascade["ok"] and not s.circles.has(c2) and left_with_c2 == 0, " ", cascade)

	# --- reference dimensions of the part D kinds
	var refs := [
		{"kind": "arc_length", "refs": [{"type": "arc", "id": arc_id}]},
		{"kind": "horizontal_angle", "refs": [{"type": "line", "id": lb}]},
		{"kind": "point_angle", "refs": [{"type": "point", "id": la_start}, {"type": "point", "id": la_end}, {"type": "point", "id": lb_start}]},
		{"kind": "min_distance", "refs": [{"type": "point", "id": free_pt}, {"type": "circle", "id": c1}]},
		{"kind": "max_distance", "refs": [{"type": "line", "id": lb}, {"type": "circle", "id": c1}]}]
	var made := 0
	for body in refs:
		var r: Dictionary = await req(HTTPClient.METHOD_POST, "/sketch/sketches/%s/reference-dimensions" % s.sketch_id, body)
		if r["ok"]:
			made += 1
		else:
			print("  refused: ", body["kind"], " ", r.get("error"))
	await s.refresh(false)
	var driven: Array = s.driven_items()
	var drawn_ok := driven.size() == 5
	var texts: Array = driven.map(func(i): return str(i["text"]))
	for item in driven:
		var l: Dictionary = DimLayout.layout(item["spec"], params())
		drawn_ok = drawn_ok and ((l["segments"] as Array).size() + (l["arcs"] as Array).size() > 0) and str(item["text"]).begins_with("(")
	print("SMOKE the five part D kinds of reference dimension the backend stores are all drawn, in brackets, with their own marks: ", made == 5 and drawn_ok and texts.any(func(t): return t.begins_with("(⌒")) and texts.any(func(t): return t.ends_with("°)")), " ", texts)
	print("SMOKE e2e done: ", true)
	quit()


func Session_format(v: float) -> String:
	return preload("res://scripts/design_table/sketch_session.gd").format_value(v)
