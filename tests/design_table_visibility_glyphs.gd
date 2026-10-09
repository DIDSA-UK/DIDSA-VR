extends SceneTree
## The drawer's last three tiles (plan step 7): ORIGIN AND AXES (a ball and three coloured axes on the copy), SKETCH DIMENSIONS (the finished sketches'
## typed dimensions drawn at rest, laid out by dimension_layout.gd, with their values) and CONSTRUCTION GEOMETRY (construction lines are drawn and offered
## at rest only with the tile on; Revolve's axis picking shows them). Each follows its switch, and the tile's state is not saved. Fake backend.
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
	# one of the four lines is a construction line, and the sketch carries a typed 40 mm dimension
	fake.entities[0]["construction"] = true
	var pids: Array = fake.points.keys()
	fake.cons["dim1"] = {"type": "distance", "id": "dim1", "point_a_id": pids[0], "point_b_id": pids[1], "distance": 40.0, "orientation": "linear", "provisional": false}
	fake.feature_rows["PART_BOX"] = [{"id": sk, "type": "sketch", "sketch_id": ed.session.sketch_id, "plane_feature_id": null}]
	rig.main.visibility_ruled_parts.append("PART_BOX")
	await b.reload()
	table.manager.deactivate()
	ed.end_sketch()
	await rig.frames(8)

	# --- origin and axes
	var axes = ed.origin_axes
	print("SMOKE the part has its origin and axes on the copy, hidden until the tile is on: ", axes != null and axes.get_parent() == table.table_copy and not axes.visible and axes.get_node_or_null("AxisX") != null and axes.get_node_or_null("AxisY") != null and axes.get_node_or_null("AxisZ") != null and axes.get_node_or_null("Origin") != null)
	b.visibility.set_on(Vis.ORIGIN_AXES, true)
	await rig.frames(2)
	print("SMOKE the Origin, axes tile shows them: ", ed.origin_axes.visible)
	b.visibility.set_on(Vis.ORIGIN_AXES, false)
	await rig.frames(2)
	print("SMOKE ...and switching it off hides them again: ", not ed.origin_axes.visible)

	# --- construction geometry
	var rest = ed.rest_sketches
	print("SMOKE with the Constr. tile off the sketch is drawn without its construction line (3 of 4 lines): ", rest != null and rest.candidates().size() == 3 and rest.curves.size() == 4 and not rest.show_construction)
	b.visibility.set_on(Vis.CONSTRUCTION, true)
	await rig.frames(3)
	print("SMOKE ...with it on the construction line is drawn and offered too: ", ed.rest_sketches.candidates().size() == 4 and ed.rest_sketches.show_construction)
	b.visibility.set_on(Vis.CONSTRUCTION, false)
	await rig.frames(3)
	table.manager.activate("revolve")
	await rig.frames(6)
	print("SMOKE while Revolve picks (its axis is often a construction line) they are shown whatever the tile says: ", ed.state == "pick_sketch" and ed.rest_sketches.candidates().size() == 4)
	table.manager.deactivate()
	await rig.frames(4)
	print("SMOKE ...and hidden again afterwards: ", ed.rest_sketches.candidates().size() == 3)

	# --- sketch dimensions
	rest = ed.rest_sketches
	var glyph: Dictionary = rest.dims.get(sk, {})
	print("SMOKE the sketch's typed dimension was laid out (lines and a value) when it was read: ", glyph.has("points") and (glyph["points"] as PackedVector3Array).size() > 0 and glyph["labels"].size() == 1 and str(glyph["labels"][0]["text"]).contains("40"), " ", glyph.get("labels", []).map(func(l): return l["text"]))
	print("SMOKE with the Dims tile off nothing of it is drawn: ", not rest.dims_on and rest.get_node_or_null("SketchDimensions") == null and rest.get_node_or_null("SketchDimensionValues") == null)
	b.visibility.set_on(Vis.DIMENSIONS, true)
	await rig.frames(3)
	rest = ed.rest_sketches
	print("SMOKE with it on the dimension lines and the value are drawn on the part: ", rest.dims_on and rest.get_node_or_null("SketchDimensions") != null and rest.get_node_or_null("SketchDimensionValues") != null and rest.get_node("SketchDimensionValues").get_child_count() == 1)
	rig.main.set_feature_hidden(sk, true)
	b.changed.emit()
	await rig.frames(4)
	print("SMOKE hiding the sketch takes its dimensions away too: ", ed.rest_sketches.get_node_or_null("SketchDimensions") == null and ed.rest_sketches.get_node_or_null("SketchDimensionValues") == null)
	rig.main.set_feature_hidden(sk, false)
	b.changed.emit()
	await rig.frames(4)
	b.visibility.set_on(Vis.DIMENSIONS, false)
	await rig.frames(3)
	print("SMOKE ...and switching the tile off clears them: ", ed.rest_sketches.get_node_or_null("SketchDimensions") == null)
	print("SMOKE none of the tiles is saved: ", rig.main.native_extras_to_add({}).keys().filter(func(k): return str(k).contains("axes") or str(k).contains("dimension") or str(k).contains("construction")).is_empty())
	table.close()
	await rig.frames(2)
	quit()
