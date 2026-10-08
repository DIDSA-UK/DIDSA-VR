extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): the Ellipse, Ellipse Arc, Spline and Text sketch tools (Phase 6.6) against the real routes. Each is DRAWN by taps (and for Text a
## typed content and a font), appears in the session's model and outline, can be PICKED by the laser's nearest search, DIMENSIONED (an ellipse's major and minor radius are
## real constraints: the ghosts' PATCH changes the shape), and EXTRUDED (the closed ones: an ellipse 40 x 20 gives a solid 40 x 20; Text letters give a solid).
## Run: "$GODOT" --headless --path . --script res://tests/e2e_curves.gd  (needs secrets.cfg and a running backend)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func fresh() -> void:
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return table.editor.state == "pick_plane")
	await table.editor.begin_sketch({"fixed": "XY"})


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
	main.backend_url = str(cfg.get_value("backend", "url"))
	main.api_key = str(cfg.get_value("backend", "api_key"))
	table = main.design_table
	table.configure_backend(main.backend_url, main.api_key)
	table.surface.settle_seconds = 0.0
	var ed = table.editor
	ed.preview_enabled = false

	# --- Ellipse
	await fresh()
	var s = ed.session
	table.manager.activate("ellipse")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(20, 0)})
	await s.tap({"uv": Vector2(0, 10)})
	print("SMOKE an ellipse is drawn by three taps (centre, long axis end, short radius): one ellipse of 20 x 10 radii", s.ellipses.size() == 1, " ", s.ellipses.keys())
	var eid: String = s.ellipses.keys()[0] if not s.ellipses.is_empty() else ""
	var outline: Array = s.outline_of("ellipse", eid)
	var xs: Array = outline.map(func(p): return p.x)
	var ys: Array = outline.map(func(p): return p.y)
	print("SMOKE ...its sampled outline spans x -20..20 and y -10..10: ", outline.size() > 10 and absf(xs.max() - 20.0) < 0.2 and absf(ys.max() - 10.0) < 0.2 and absf(xs.min() + 20.0) < 0.2, " ", xs.max(), " ", ys.max())
	var hit: Dictionary = s.nearest_entity(Vector2(14.14, 7.07), 1.5)
	print("SMOKE ...the laser's nearest search finds it near the rim: ", hit.get("kind", "") == "ellipse")
	await s.select({"kind": "ellipse", "id": eid})
	s.set_tool("dimension")
	await s.select({"kind": "ellipse", "id": eid})
	var keys: Array = s.ghosts.map(func(g): return g["key"])
	print("SMOKE ...Dimension offers its major and minor radius: ", keys == ["major_radius", "minor_radius"], " ", keys)
	var done: Dictionary = await s.confirm_ghost("major_radius", 30.0)
	var major: float = absf(s.points[s.ellipses[eid]["ma"]].distance_to(s.points[s.ellipses[eid]["c"]]))
	print("SMOKE ...typing 30 for the major radius is solved by the backend (the long axis grows to 30): ", done["ok"] and absf(major - 30.0) < 0.05, " ", major)
	s.set_tool("")
	ed.session.tool = ""
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = 5.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	var box: Vector3 = table.seated.get_aabb().size
	var minor_now: float = s.points[s.ellipses[eid]["mi"]].distance_to(s.points[s.ellipses[eid]["c"]])
	print("SMOKE ...and the ellipse extrudes: a solid as wide as its two radii say (60 x 2 * minor x 5; the backend rescaled the minor radius with the major, see the gaps note): ", absf(box.x - 60.0) < 0.6 and absf(box.y - 2.0 * minor_now) < 0.6 and absf(box.z - 5.0) < 0.3, " ", box, " minor ", minor_now)

	# --- Ellipse arc
	await fresh()
	s = ed.session
	table.manager.activate("ellipse_arc")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(20, 0)})
	await s.tap({"uv": Vector2(0, 10)})
	await s.tap({"uv": Vector2(20, 0)})
	await s.tap({"uv": Vector2(-20, 0)})
	print("SMOKE an ellipse arc is drawn by five taps (the upper half from the right end to the left end): ", s.ellipse_arcs.size() == 1)
	var aid: String = s.ellipse_arcs.keys()[0] if not s.ellipse_arcs.is_empty() else ""
	var arc_outline: Array = s.outline_of("ellipse_arc", aid)
	var top_y: float = arc_outline.map(func(p): return p.y).max() if not arc_outline.is_empty() else 0.0
	print("SMOKE ...the outline is the upper half (it reaches y = +10, never below 0): ", not arc_outline.is_empty() and absf(top_y - 10.0) < 0.3 and arc_outline.all(func(p): return p.y > -0.3), " ", top_y)
	print("SMOKE ...and the laser finds it: ", s.nearest_entity(Vector2(14.14, 7.07), 1.5).get("kind", "") == "ellipse_arc")

	# --- Spline
	await fresh()
	s = ed.session
	table.manager.activate("spline")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(20, 15)})
	await s.tap({"uv": Vector2(40, 0)})
	print("SMOKE taps on the Spline tool only collect points (nothing made until Finish): ", s.splines.is_empty() and s.pending.size() == 3 and table.props.option_button("finish_spline") != null)
	await ed.on_option("finish_spline")
	print("SMOKE Finish makes one spline through the three points: ", s.splines.size() == 1 and s.pending.is_empty())
	var sid: String = s.splines.keys()[0] if not s.splines.is_empty() else ""
	var spline_outline: Array = s.outline_of("spline", sid)
	var mid_hit: Dictionary = s.nearest_entity(spline_outline[spline_outline.size() / 4] if not spline_outline.is_empty() else Vector2.ZERO, 1.0)
	print("SMOKE ...its outline is sampled (curve between the points) and the laser finds it on the curve: ", spline_outline.size() > 8 and mid_hit.get("kind", "") == "spline", " ", spline_outline.size())
	var one: Dictionary = await s.finish_spline()
	print("SMOKE a spline of fewer than two points is refused: ", not one["ok"])

	# --- Text
	await fresh()
	s = ed.session
	table.manager.activate("text")
	var refused: Dictionary = await s.tap({"uv": Vector2(0, 0)})
	print("SMOKE placing text with nothing typed is refused with a reason: ", not refused["ok"] and s.texts.is_empty())
	s.text_content = "AB"
	s.text_size = 20.0
	await ed.on_option("text_font")
	print("SMOKE the Font button steps to the next bundled font: ", ed.options["text_font"] == "Roboto" and s.text_font == "Roboto")
	await s.tap({"uv": Vector2(0, 0)})
	print("SMOKE a tap places the text (real route, the font name accepted): ", s.texts.size() == 1)
	var tid: String = s.texts.keys()[0] if not s.texts.is_empty() else ""
	var fetched: bool = await wait_for(func() -> bool: return s.text_outlines.has(tid), 300)
	print("SMOKE ...the backend's glyph outlines are fetched (two letters, each with its contours): ", fetched and (s.text_outlines[tid] as Array).size() >= 2, " ", (s.text_outlines.get(tid, []) as Array).size())
	var near: Vector2 = (s.text_outlines[tid][0] as Array)[0] if fetched else Vector2.ZERO
	print("SMOKE ...the laser finds the text near a glyph edge: ", s.nearest_entity(near, 1.0).get("kind", "") == "text")
	s.set_tool("")
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = 3.0
	await ed.apply_feature()
	var extruded: bool = await wait_for(func() -> bool: return not table.is_blank(), 400)
	print("SMOKE ...and the letters extrude into a solid (3 mm thick): ", extruded and absf(table.seated.get_aabb().size.z - 3.0) < 0.3, " ", table.seated.get_aabb().size if extruded else "")
	quit()
