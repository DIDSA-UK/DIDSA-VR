extends SceneTree
## The drawer's tiles for the part and the sketch glyphs (plan step 7, as corrected): ORIGIN AND AXES (a ball and three coloured axes on the copy,
## shown only with the tile on); SKETCH DIMENSIONS and CONSTRAINTS, two tiles that start ON: they show ONLY in the sketch that is open (never on a finished
## sketch at rest) and each follows its tile there; the Dimension tool's own candidates always show; construction lines are ordinary lines (drawn and offered
## at rest like the rest). None of it is saved. Fake backend.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_visibility_glyphs.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const Vis := preload("res://scripts/design_table/visibility.gd")


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	var b = table.build
	fake.filtered_mesh_bytes = fake.mesh_bytes
	await rig.draw_rectangle()
	var sk: String = ed.session.feature_id
	fake.sketch_plane = "XY"
	# one of the four lines is a construction line; the sketch carries a typed 40 mm dimension and two constraints
	fake.entities[0]["construction"] = true
	var line_ids: Array = fake.entities.filter(func(e): return e["type"] == "line").map(func(e): return e["id"])
	var pids: Array = fake.points.keys()
	fake.cons["dim1"] = {"type": "distance", "id": "dim1", "point_a_id": pids[0], "point_b_id": pids[1], "distance": 40.0, "orientation": "linear", "provisional": false}
	fake.cons["c_h"] = {"type": "horizontal", "id": "c_h", "line_id": line_ids[1]}
	fake.cons["c_par"] = {"type": "parallel", "id": "c_par", "line1_id": line_ids[1], "line2_id": line_ids[3]}
	fake.feature_rows["PART_BOX"] = [{"id": sk, "type": "sketch", "sketch_id": ed.session.sketch_id, "plane_feature_id": null}]
	rig.main.visibility_ruled_parts.append("PART_BOX")
	await b.reload()
	table.manager.deactivate()

	# --- the glyphs show in the open sketch, by default
	ed.end_sketch() # (the rig's sketch is still open from drawing: leave it, then open it again as a finished sketch is)
	await rig.frames(3)
	await ed.reopen_sketch(sk)
	await rig.frames(4)
	var view = ed.view
	print("SMOKE both tiles start on, so the open sketch shows its dimension and its constraint glyphs: ", b.visibility.is_on(Vis.DIMENSIONS) and b.visibility.is_on(Vis.CONSTRAINTS) and view.label_texts().any(func(t): return str(t).contains("40")) and view.constraint_glyph_texts().has("H") and view.constraint_glyph_texts().count("//") == 2, " ", view.label_texts(), " ", view.constraint_glyph_texts())
	b.visibility.set_on(Vis.DIMENSIONS, false)
	await rig.frames(3)
	print("SMOKE the Dims tile off takes the sketch's dimension away and keeps its constraints: ", not ed.view.label_texts().any(func(t): return str(t).contains("40")) and ed.view.constraint_glyph_texts().has("H"))
	b.visibility.set_on(Vis.CONSTRAINTS, false)
	await rig.frames(3)
	print("SMOKE the Constr. tile off takes the constraint glyphs away: ", ed.view.constraint_glyph_texts().is_empty())
	b.visibility.set_on(Vis.DIMENSIONS, true)
	b.visibility.set_on(Vis.CONSTRAINTS, true)
	await rig.frames(3)
	print("SMOKE ...and both come back with their tiles: ", ed.view.label_texts().any(func(t): return str(t).contains("40")) and not ed.view.constraint_glyph_texts().is_empty())
	ed.finish_sketch()
	await rig.frames(8)

	# --- never on a finished sketch at rest
	var rest = ed.rest_sketches
	print("SMOKE a finished sketch at rest shows neither dimensions nor constraint glyphs, whatever the tiles say: ", rest != null and rest.get_node_or_null("SketchDimensions") == null and rest.get_node_or_null("SketchDimensionValues") == null)
	print("SMOKE ...and its construction line is an ordinary line: drawn and offered like the other three (4 of 4): ", rest.candidates().size() == 4 and rest.curves.filter(func(c): return c["construction"]).size() == 1)

	# --- origin and axes
	var axes = ed.origin_axes
	print("SMOKE the part has its origin and axes on the copy, hidden until the tile is on: ", axes != null and axes.get_parent() == table.table_copy and not axes.visible and axes.get_node_or_null("AxisX") != null and axes.get_node_or_null("AxisY") != null and axes.get_node_or_null("AxisZ") != null and axes.get_node_or_null("Origin") != null)
	b.visibility.set_on(Vis.ORIGIN_AXES, true)
	await rig.frames(2)
	print("SMOKE the Origin, axes tile shows them: ", ed.origin_axes.visible)
	b.visibility.set_on(Vis.ORIGIN_AXES, false)
	await rig.frames(2)
	print("SMOKE ...and switching it off hides them again: ", not ed.origin_axes.visible)
	print("SMOKE none of the tiles is saved: ", rig.main.native_extras_to_add({}).keys().filter(func(k): return str(k).contains("axes") or str(k).contains("dimension") or str(k).contains("constraint")).is_empty())
	table.close()
	await rig.frames(2)
	quit()
