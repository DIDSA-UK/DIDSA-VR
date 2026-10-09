extends SceneTree
## Eyes in the Build tree (plan step 4, table_tree_window.gd): every feature row has an eye laid over its left that hides or shows the feature in one
## tap WITHOUT selecting it; a hidden row shows the closed eye; a strip of group headings (Sketches, Bodies, Surfaces, 3D curves, Planes: only the kinds
## the part has) carries one eye each that acts on the whole kind exactly like the drawer's tile (all visible -> hide all, otherwise show all); the
## list itself stays in build order. Fake backend.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_visibility_tree.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const Vis := preload("res://scripts/design_table/visibility.gd")


func eye_of(table, prefix: String) -> Button:
	for row in table.tree._build_rows.get_children():
		if row is Button and (row as Button).text.begins_with(prefix):
			return row.get_node_or_null("Eye")
	return null


func group_button(table, name: String) -> Button:
	for n in table.tree._build_rows.find_children("*", "Button", true, false):
		if (n as Button).get_parent() is HFlowContainer and (n as Button).text.strip_edges() == name:
			return n
	return null


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var table = rig.table
	var fake = rig.fake
	fake.filtered_mesh_bytes = fake.mesh_bytes
	fake.feature_rows = {"PART_BOX": [
		{"type": "sketch", "id": "sk_a", "sketch_id": "sA", "plane_feature_id": null},
		{"type": "extrude", "id": "ex_a", "sketch_feature_id": "sk_a", "extrude_type": "boss", "start_distance": 0.0, "end_distance": 12.0},
		{"type": "sketch", "id": "sk_b", "sketch_id": "sB", "plane_feature_id": null},
		{"type": "sketch", "id": "sk_c", "sketch_id": "sC", "plane_feature_id": null},
	]}
	rig.main.visibility_ruled_parts.clear()
	await table.build.reload()
	table.tree.show_tab("build")
	await rig.frames(3)
	var rows: Array = table.tree._build_rows.get_children().filter(func(c): return c is Button and c.get_node_or_null("Eye") != null)
	print("SMOKE every feature row has an eye laid over its left (four rows, four eyes): ", rows.size() == 4 and rows.all(func(r): return r.get_node("Eye").position.x < 60.0))
	print("SMOKE the rows stay in build order: ", rows.map(func(r): return r.text.split(" ")[0] + r.text.split(" ")[1]) == ["Sketch1", "Extrude1", "Sketch2", "Sketch3"])
	print("SMOKE after the load rule the consumed sketch's eye is closed, a free sketch's open: ", eye_of(table, "Sketch 1").icon != eye_of(table, "Sketch 2").icon and table.build.is_hidden("sk_a") and not table.build.is_hidden("sk_b"))
	eye_of(table, "Sketch 2").pressed.emit()
	await rig.frames(4)
	print("SMOKE one tap on a row's eye hides that feature without selecting it: ", table.build.is_hidden("sk_b") and table.build.selected_id == "")
	print("SMOKE ...and its row now shows the closed eye and 'hidden': ", eye_of(table, "Sketch 2").icon == eye_of(table, "Sketch 1").icon and (eye_of(table, "Sketch 2").get_parent() as Button).text.contains("hidden"))
	eye_of(table, "Sketch 2").pressed.emit()
	await rig.frames(4)
	print("SMOKE a second tap shows it again: ", not table.build.is_hidden("sk_b"))

	var sketches := group_button(table, "Sketches")
	var bodies := group_button(table, "Bodies")
	print("SMOKE the group strip has a heading for each kind the part has (Sketches, Bodies) and none for the others: ", sketches != null and bodies != null and group_button(table, "Surfaces") == null and group_button(table, "Planes") == null)
	print("SMOKE ...Sketches shows the half eye (the consumed one is hidden), Bodies the full eye: ", sketches.icon != bodies.icon and table.build.category_state(Vis.SKETCHES)["state"] == "some" and table.build.category_state(Vis.BODIES)["state"] == "all")
	sketches.pressed.emit()
	await rig.frames(4)
	print("SMOKE a heading on a mixed kind shows ALL of it (the drawer's rule): ", table.build.category_state(Vis.SKETCHES)["state"] == "all")
	group_button(table, "Sketches").pressed.emit()
	await rig.frames(4)
	print("SMOKE ...pressed again it hides all of the kind, and the rows' eyes follow: ", table.build.category_state(Vis.SKETCHES)["state"] == "none" and eye_of(table, "Sketch 3").icon == eye_of(table, "Sketch 1").icon)
	print("SMOKE the Build tree and the drawer agree: the drawer's Sketches tile reads the same: ", table.visibility_window.row_state(Vis.SKETCHES)["state"] == "none")
	table.close()
	await rig.frames(2)
	quit()
