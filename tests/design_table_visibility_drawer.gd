extends SceneTree
## The Visibility DRAWER and its eye button (scripts/design_table/table_visibility_window.gd, plan step 2) on the rig's fake backend:
## the eye sits in the generic column next to Snap and opens the drawer, stationary against the deck's right edge; the rows show an eye / half eye /
## eye-off and "3 of 5" counts that follow the Build tree's hidden ids; a row press is the batch rule (all visible -> hide all, else show
## all); an empty category and Centre of gravity are dimmed and do nothing; the session rows flip their switch; Show all / Hide all act on
## every row; the eye closes it again, no title bar; closing the table puts the drawer away; widening the slab keeps it flush with the deck.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_visibility_drawer.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const Vis := preload("res://scripts/design_table/visibility.gd")


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var table = rig.table
	rig.fake.feature_rows = {"PART_BOX": [
		{"type": "sketch", "id": "sk_a", "sketch_id": "sA"},
		{"type": "extrude", "id": "ex_a", "sketch_feature_id": "sk_a"},
		{"type": "sketch", "id": "sk_b", "sketch_id": "sB"},
		{"type": "sketch", "id": "sk_c", "sketch_id": "sC"},
		{"type": "create_plane", "id": "pl_1"},
	]}
	rig.fake.filtered_mesh_bytes = rig.fake.mesh_bytes
	rig.main.visibility_ruled_parts.clear() # the rig seated the part with no features yet: let the load rule meet these
	await table.build.reload()
	await rig.frames(2)
	var win = table.visibility_window
	var eye: Button = table.ui.eye_button()
	print("SMOKE the eye button sits in the generic column beside Snap, and the drawer starts closed: ", eye != null and eye.is_visible_in_tree() and eye.get_parent() == table.ui._snap_button.get_parent() and not win.is_open() and not eye.button_pressed)
	eye.button_pressed = true
	await rig.frames(2)
	print("SMOKE pressing the eye opens the drawer on the deck's right edge, level with its top, a child of the deck with no grab handle: ", win.is_open() and win.get_parent() == table._deck and is_equal_approx(win.position.x, table.tools_size.x * 0.5 + win.panel_size.x * 0.5 + win.GAP) and is_equal_approx(win.position.y + win.panel_size.y * 0.5, table.tools_size.y * 0.5) and win._handle == null and win.handle_in_reach(rig.r) == false)
	var sk: Button = win.button_for(Vis.SKETCHES)
	print("SMOKE Sketches reads 'some' after the load rule (the extrude consumed one) and the tiles carry no counts: ", sk.text == "Sketches" and win.row_state(Vis.SKETCHES)["label"] == "2 of 3" and not win.button_for(Vis.BODIES).text.contains(" of "), " ", sk.text)
	print("SMOKE Bodies is a full eye '1 of 1', Created planes is eye-off '0 of 1' (hidden by the load rule): ", win.row_state(Vis.BODIES) == {"state": "all", "label": "1 of 1"} and win.row_state(Vis.PLANES) == {"state": "none", "label": "0 of 1"})
	print("SMOKE categories with nothing in them (Surfaces, 3D curves) and Centre of gravity are dimmed and disabled: ", win.button_for(Vis.SURFACES).disabled and win.button_for(Vis.CURVES).disabled and win.button_for("centre_of_gravity").disabled and not sk.disabled)
	sk.pressed.emit()
	await rig.frames(3)
	print("SMOKE a press on the mixed Sketches row shows them all ('3 of 3'), the file's hidden list loses them: ", win.row_state(Vis.SKETCHES)["label"] == "3 of 3" and not rig.main.hidden_feature_ids().has("sk_a"))
	sk.pressed.emit()
	await rig.frames(3)
	print("SMOKE ...pressed again it hides them all: ", win.row_state(Vis.SKETCHES)["state"] == "none" and rig.main.hidden_feature_ids().has("sk_c"))
	var ref: Button = win.button_for(Vis.REFERENCE_PLANES)
	ref.pressed.emit()
	await rig.frames(2)
	print("SMOKE a session row (Reference planes) flips its switch and its eye, and writes nothing to the file: ", table.build.visibility.is_on(Vis.REFERENCE_PLANES) and win.row_state(Vis.REFERENCE_PLANES)["state"] == "all" and not rig.main.native_extras_to_add({}).keys().any(func(k): return str(k).begins_with("vr_")))
	win.button_for("centre_of_gravity").pressed.emit()
	win._hide_all.pressed.emit()
	await rig.frames(3)
	print("SMOKE Hide all hides every feature row and switches every session row off: ", win.row_state(Vis.BODIES)["state"] == "none" and win.row_state(Vis.PLANES)["state"] == "none" and not table.build.visibility.is_on(Vis.REFERENCE_PLANES) and not table.build.visibility.is_on(Vis.EDGE_LINES))
	win._show_all.pressed.emit()
	await rig.frames(3)
	print("SMOKE Show all brings every one back (the file's hidden list is empty): ", win.row_state(Vis.BODIES)["state"] == "all" and win.row_state(Vis.PLANES)["state"] == "all" and table.build.visibility.is_on(Vis.EDGE_LINES) and rig.main.hidden_feature_ids().is_empty())
	print("SMOKE the drawer has no title bar (the eye is its switch): ", not win._header.visible)
	eye.button_pressed = false
	await rig.frames(2)
	print("SMOKE pressing the eye again closes the drawer: ", not win.is_open() and not eye.button_pressed)
	eye.button_pressed = true
	await rig.frames(2)
	var before: float = win.position.x
	table.set_slab_size(table.slab_size + Vector2(0.2, 0.0))
	print("SMOKE widening the slab widens the deck, and the drawer stays flush against its right edge: ", win.position.x > before and is_equal_approx(win.position.x, table.tools_size.x * 0.5 + win.panel_size.x * 0.5 + win.GAP))
	table.close()
	await rig.frames(2)
	print("SMOKE closing the table puts the drawer away and releases the eye: ", not win.is_open() and not eye.button_pressed)
	quit()
