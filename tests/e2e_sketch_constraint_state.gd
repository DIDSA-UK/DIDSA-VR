extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): the constraint state and the relations' glyphs
## as the backend really sends them (S3 of docs/dimension-constraint-parity-plan.md). A new part and a sketch on XY:
##   * a line with a Fix, Horizontal and a typed Length: under constrained, then FULLY constrained after the last dimension (the status says so, the hand ticks);
##   * the Fix glyph is drawn (the backend sends `point_ids`, not the picked entity) and Equal radius is drawn on both circles (it sends centre / rim points);
##   * Unfix takes a Fix off, and Undo fixes it again;
##   * a LATER conflict, an edited value the pinned line cannot meet, is kept (not taken back) and the solver's failed list turns what it holds red;
##   * what a glyph holds is lit when hovered or picked, in the real view.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_sketch_constraint_state.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var api
var s
var ticks := 0


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


func pick(entities: Array) -> void:
	s.set_tool("select")
	s.clear_selection()
	for e in entities:
		await s.select({"kind": e[0], "id": e[1]})


func s_menu() -> Array:
	return load("res://scripts/design_table/sketch_selection.gd").options(s.selection, s, s.ghosts).map(func(o): return o["id"])


func glyph_on(owner: String, text: String) -> bool:
	for item in s.constraint_items():
		if str(item["owner"]) == owner and str(item["text"]) == text:
			return true
	return false


func _on_tick() -> void:
	ticks += 1


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
	s.fully_constrained.connect(_on_tick)
	print("SMOKE a sketch opens on XY: ", opened)

	# --- under -> fully constrained, by the last dimension
	var l1: String = await line(Vector2(20, 20), Vector2(80, 20))
	print("SMOKE a free line is under constrained, with DOF left in the phrase: ", s.constraint_state() == "under" and s.dof > 0 and s.constraint_summary().ends_with("DOF left."), " ", s.dof, " ", s.constraint_summary())
	await pick([["point", s.lines[l1]["a"]]])
	var fixed_point: Dictionary = await s.apply_menu("fix")
	print("SMOKE Fix on the start point is taken: ", fixed_point["ok"], " ", fixed_point)
	await pick([["line", l1]])
	await s.apply_menu("horizontal")
	print("SMOKE with the start fixed and the line horizontal, one DOF is left (the length): ", s.constraint_state() == "under" and s.dof == 1, " ", s.dof, " ", s.constraint_state())
	ticks = 0
	s.set_tool("dimension")
	await s.select({"kind": "line", "id": l1})
	var typed: Dictionary = await s.confirm_ghost("length", 70.0)
	print("SMOKE the typed length is taken: ", typed["ok"], " ", typed)
	print("SMOKE after the last dimension the sketch is FULLY constrained (DOF 0, converged, tied through the fixed point): ", s.constraint_state() == "full" and s.dof <= 0 and s.converged and s.constraint_summary() == "Fully constrained.", " ", s.constraint_state(), " ", s.dof)
	print("SMOKE ...and reaching it ticked once: ", ticks == 1, " ", ticks)
	print("SMOKE the Fix glyph is drawn on the Fix's point (the backend sends point_ids): ", glyph_on(s.lines[l1]["a"], "F"))
	print("SMOKE nothing is red: ", s.failed_point_ids().is_empty())

	# --- Equal radius: found by centre point, drawn on both circles
	var c1: String = await circle(Vector2(150, 60), Vector2(160, 60))
	var c2: String = await circle(Vector2(200, 60), Vector2(215, 60))
	await pick([["circle", c1], ["circle", c2]])
	var er: Dictionary = await s.apply_menu("equal_radius")
	print("SMOKE Equal radius is taken: ", er["ok"], " ", er)
	var eq_type := ""
	for cid in s.constraints:
		if str(s.constraints[cid].get("type", "")) == "equal_radius":
			eq_type = "equal_radius"
	print("SMOKE the sketch shows an Equal radius glyph on BOTH circles: ", eq_type == "equal_radius" and glyph_on(c1, "=") and glyph_on(c2, "="))

	# --- Fix on a whole line is one glyph on the line; Unfix and its undo
	var l2: String = await line(Vector2(20, 100), Vector2(60, 100))
	await pick([["line", l2]])
	var fix_line: Dictionary = await s.apply_menu("fix")
	print("SMOKE Fix on a line fixes both its ends, and the glyph is drawn once, on the line: ", fix_line["ok"] and glyph_on(l2, "F"), " ", fix_line)
	await pick([["line", l2]])
	var offered := s_menu()
	print("SMOKE the line's Select menu now offers Unfix: ", offered.has("unfix"), " ", offered)
	var unfixed: Dictionary = await s.apply_menu("unfix")
	print("SMOKE Unfix takes the Fix off (no Fix on the line any more, so no glyph): ", unfixed["ok"] and s.fix_constraints_for([{"kind": "line", "id": l2}]).is_empty() and not glyph_on(l2, "F"), " ", unfixed)
	await s.undo()
	print("SMOKE Undo fixes it again: ", not s.fix_constraints_for([{"kind": "line", "id": l2}]).is_empty() and glyph_on(l2, "F"))

	# --- a later conflict: an edited value the fixed line cannot meet is KEPT, red
	s.set_tool("dimension")
	await s.select({"kind": "line", "id": l2})
	var dim_id := ""
	var l3: String = await line(Vector2(120, 120), Vector2(170, 120))
	s.set_tool("dimension")
	await s.select({"kind": "line", "id": l3})
	var d3: Dictionary = await s.confirm_ghost("length", 50.0)
	for cid in s.constraints:
		var c: Dictionary = s.constraints[cid]
		if str(c.get("type", "")) == "distance" and absf(float(c.get("distance", 0.0)) - 50.0) < 0.001 and not bool(c.get("provisional", false)):
			dim_id = cid
	await pick([["line", l3]])
	await s.apply_menu("fix")
	print("SMOKE a line with a Length of 50 can be fixed where it is, and still converges: ", d3["ok"] and dim_id != "" and s.converged, " ", d3)
	var edited: Dictionary = await s.edit_dimension(dim_id, 80.0)
	print("SMOKE the edit that the fixed line cannot meet is KEPT, not taken back (the value stays 80, the sketch no longer converges): ", edited["ok"] and absf(float(s.constraints[dim_id]["distance"]) - 80.0) < 0.001 and not s.converged and s.constraint_state() == "over", " ", edited, " ", s.converged)
	print("SMOKE ...and the message says what is red: ", String(edited["message"]).contains("red"))
	var red: Dictionary = s.failed_point_ids()
	print("SMOKE the solver's failed list is read and the line's points are red: ", not s.failed_constraint_ids.is_empty() and red.has(s.lines[l3]["a"]) and red.has(s.lines[l3]["b"]), " ", s.failed_constraint_ids.size(), " ", red.size())
	print("SMOKE the status line says over-constrained: ", s.constraint_summary().begins_with("Over-constrained"), " ", s.constraint_summary())
	var view = table.editor.view
	view.rebuild(s, [], {})
	var geo: PackedColorArray = view._geo.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var any_red := false
	for c in geo:
		if absf(c.r - 1.0) < 0.01 and absf(c.g - 0.36) < 0.01 and absf(c.b - 0.36) < 0.01 and c.a > 0.95:
			any_red = true
	print("SMOKE the view draws the failed geometry red: ", any_red)
	var t: bool = await s.undo()
	print("SMOKE Undo puts the old value back and the red goes: ", t and s.converged and s.failed_point_ids().is_empty() and absf(float(s.constraints[dim_id]["distance"]) - 50.0) < 0.001, " ", s.converged)

	# --- what a glyph holds is lit in the real view
	var warn: Color = view._tokens.warn
	view.rebuild(s, [], {})
	var base_lit := _count(view, warn)
	view.set_annotation_hover("constraint:%s" % s.constraint_items()[0]["id"])
	var hover_lit := _count(view, warn)
	view.set_annotation_hover("")
	print("SMOKE hovering a glyph lights what it holds in the real view: ", hover_lit > base_lit, " ", [base_lit, hover_lit])
	quit()


func _count(view, want: Color) -> int:
	var cols: PackedColorArray = view._geo.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var n := 0
	for c in cols:
		if absf(c.r - want.r) < 0.01 and absf(c.g - want.g) < 0.01 and absf(c.b - want.b) < 0.01:
			n += 1
	return n
