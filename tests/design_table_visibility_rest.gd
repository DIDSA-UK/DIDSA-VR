extends SceneTree
## Visibility at REST (plan step 3): the finished sketches the Visibility model shows are drawn on the table's copy without a tool active, and the
## plane squares show at rest too. Fake backend. A finished sketch is drawn (read once, nothing made) and follows hide / show (a redraw, no new
## backend reads); the Sketches button and the drawer's Hide all take the lines away and bring them back; they are not drawn while a sketch is
## open or while curves are being picked; leaving the table or the part drops them. Planes: the reference planes show at rest only with their
## switch (always while picking a plane), a made plane follows its own hide state, and the editor wires both.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_visibility_rest.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const PlaneMarkers := preload("res://scripts/design_table/plane_markers.gd")
const Vis := preload("res://scripts/design_table/visibility.gd")


func _initialize() -> void:
	# --- pure: the plane squares' two reasons to show
	var pm := PlaneMarkers.new()
	pm.setup(100.0, Vector3.ZERO, 0.003)
	pm.add_plane("plane:p1", {"origin": Vector3(0, 0, 30), "x": Vector3.RIGHT, "y": Vector3.UP, "n": Vector3.BACK}, "Plane 1")
	print("SMOKE while picking a plane every square shows (the reference planes and the made one): ", pm.visible and pm.shows("XY") and pm.shows("plane:p1"))
	pm.set_markers_visible(false)
	print("SMOKE not picking and nothing switched on, none shows and the node is hidden: ", not pm.visible and not pm.shows("XY") and not pm.shows("plane:p1"))
	pm.set_rest_fixed(true)
	print("SMOKE the reference-plane switch shows the three fixed squares and leaves the made one hidden: ", pm.visible and pm.shows("XY") and pm.shows("XZ") and pm.shows("YZ") and not pm.shows("plane:p1"))
	pm.set_rest_custom("plane:p1", true)
	pm.set_rest_fixed(false)
	print("SMOKE a made plane shows on its own, the fixed ones off: ", pm.visible and pm.shows("plane:p1") and not pm.shows("XY"))
	pm.set_markers_visible(true)
	pm.set_markers_visible(false)
	print("SMOKE picking turning off again returns to the rest state: ", pm.shows("plane:p1") and not pm.shows("YZ"))
	pm.free()

	# --- scene
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	await rig.draw_rectangle()
	var sketch_feature: String = ed.session.feature_id
	var sketch_id: String = ed.session.sketch_id
	fake.sketch_plane = "XY"
	fake.feature_rows["PART_BOX"] = [{"id": sketch_feature, "type": "sketch", "sketch_id": sketch_id, "plane_feature_id": null, "name": "Sketch 1"}]
	main_mark_ruled(rig)
	await table.build.reload()
	table.manager.deactivate()
	fake.calls.clear()
	ed.end_sketch()
	await rig.frames(6)
	var rest = ed.rest_sketches
	print("SMOKE a finished sketch no tool is using is drawn on the copy at rest: ", rest != null and is_instance_valid(rest) and rest.get_parent() == table.table_copy and rest.candidates().size() == 4 and rest.get_node_or_null("SketchCurves") != null and rest.visible)
	print("SMOKE ...read once, read-only (nothing was made): ", fake.calls.filter(func(c): return String(c[0]).begins_with("POST") and not String(c[0]).ends_with("solve-and-refresh")).is_empty())
	fake.calls.clear()
	rig.main.set_feature_hidden(sketch_feature, true)
	table.build.changed.emit()
	await rig.frames(3)
	print("SMOKE hiding the sketch takes its lines away without reading anything again: ", rest.candidates().is_empty() and fake.calls.is_empty(), " ", fake.calls.size())
	rig.main.set_feature_hidden(sketch_feature, false)
	table.build.changed.emit()
	await rig.frames(3)
	print("SMOKE ...showing it brings them back, the same node: ", rest.candidates().size() == 4 and ed.rest_sketches == rest and fake.calls.is_empty())
	await table.build.toggle_category(Vis.SKETCHES)
	print("SMOKE the Sketches button on an all-visible category hides them: ", rest.candidates().is_empty() and rig.main.hidden_feature_ids().has(sketch_feature))
	await table.build.toggle_category(Vis.SKETCHES)
	print("SMOKE ...and pressing again shows them: ", rest.candidates().size() == 4)
	await table.build.set_all_visible(false)
	print("SMOKE the drawer's Hide all takes them away: ", rest.candidates().is_empty())
	await table.build.set_all_visible(true)
	print("SMOKE ...and Show all brings them back: ", rest.candidates().size() == 4)

	# --- states: not drawn while curves are picked, back afterwards
	await ed.start_curve_picks()
	await rig.frames(3)
	print("SMOKE while curves are being picked the at-rest lines step aside for the picking ones: ", not ed.rest_sketches.visible and ed.sketch_picks != null)
	ed.set_state("pick_plane")
	await rig.frames(4)
	print("SMOKE ...and come back when picking ends: ", ed.rest_sketches != null and ed.rest_sketches.visible and ed.rest_sketches.candidates().size() == 4)

	# --- the reference-plane switch through the editor
	table.build.visibility.set_on(Vis.REFERENCE_PLANES, false) # (Show all above switched every session row on)
	ed.markers.set_markers_visible(false)
	ed.sync_plane_markers()
	print("SMOKE with the switch off and no plane picking the reference planes are not drawn: ", not ed.markers.visible)
	table.build.visibility.set_on(Vis.REFERENCE_PLANES, true)
	await rig.frames(2)
	print("SMOKE the drawer's Reference planes switch draws the three squares at rest: ", ed.markers.visible and ed.markers.shows("XY") and ed.markers.shows("XZ") and ed.markers.shows("YZ"))
	table.build.visibility.set_on(Vis.REFERENCE_PLANES, false)
	await rig.frames(2)
	print("SMOKE ...and switching it off takes them away again: ", not ed.markers.visible)

	# --- leaving the part drops the lines
	table.close()
	await rig.frames(3)
	print("SMOKE closing the table drops the at-rest lines with the copy: ", ed.rest_sketches == null)
	quit()


func main_mark_ruled(rig) -> void:
	rig.main.visibility_ruled_parts.append("PART_BOX") # the rule has met this part: the sketch is the user's to show or hide
