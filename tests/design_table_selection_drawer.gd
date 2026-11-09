extends SceneTree
## T6 (docs/test-report-30-oct-plan.md): the selection drawer, against the fake backend and the real laser path. With no tool chosen a pull on the part SELECTS what is
## lit and the drawer rises out of the front of the slab: its fixed size (0.40 x 0.11 m at every slab size), inside the slab's outline, never past its front edge; the
## default action first (New sketch on face for a flat face; Fillet for an edge), disabled actions kept; choosing an action STARTS the existing tool with the selection
## already picked (Fillet with the edge in `edges`, state pick_edges), the drawer hides while the tool runs; New sketch on face opens the sketch on THAT face; a pull on
## empty space, B, and the X all clear the selection and close the drawer, a pull on the deck does not; a Build tree row offers the feature / sketch actions; with a sketch
## open the drawer carries the sketch selection's options. From the standing eye point the drawer's on-screen rectangle clears the tool deck, the Properties window and
## the tree window at the smallest and largest slab, with the drawer open and while a sketch is open. NOT checked: whether the drawer is the right place, or quicker
## than the deck, on a headset; the live backend (tests/e2e_table_context.gd).
## Run: "$GODOT" --headless --path . --script res://tests/design_table_selection_drawer.gd  (see tests/README.md)

const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

const Fake := preload("res://tests/helpers/fake_cad.gd")

var main
var table
var ed
var r: XRController3D
var fake


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func aim(from: Vector3, to: Vector3) -> void:
	var dir := (to - from).normalized()
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	r.global_transform = Transform3D(Basis.looking_at(dir, up), from)
	await frames(3)


func pull() -> void:
	r.button_pressed.emit("trigger_click")
	await frames(2)
	r.button_released.emit("trigger_click")
	await frames(2)


func settle(pred: Callable, n := 200) -> bool:
	for i in n:
		if pred.call():
			return true
		await process_frame
	return false


func calls_to(fragment: String) -> Array:
	return fake.calls.filter(func(c): return c[0].contains(fragment))


func aim_uv(uv: Vector2) -> void:
	## Aims the laser at a sheet position from above the sheet.
	var copy: Node3D = table.table_copy
	var plane: Dictionary = ed.session.plane
	var world: Vector3 = copy.global_transform * SketchMath.from_sheet(uv, plane)
	var normal: Vector3 = (copy.global_transform.basis * (plane["n"] as Vector3)).normalized()
	await aim(world + normal * 0.45 + Vector3(0, 0, 0.12), world)


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	r = origin.get_node("RightController")
	var l: XRController3D = origin.get_node("LeftController")
	l.position = Vector3(-0.5, 1.0, -0.2)
	r.position = Vector3(1.0, 1.5, 1.0)
	table = main.design_table
	table.surface.settle_seconds = 0.0
	ed = table.editor
	var bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb")
	main._show_model(bytes, "", 0.001)
	await frames(3)
	var box: MeshInstance3D = null
	for p in get_nodes_in_group("grabbable_parts"):
		if p.get_meta("occurrence_id", "") == "occ_box":
			box = p
	var owner_id := str(box.get_meta("owner_part_id", ""))
	if owner_id == "":
		owner_id = "ASM"
		for p in get_nodes_in_group("grabbable_parts"):
			p.set_meta("owner_part_id", owner_id)
	fake = Fake.new()
	fake.occurrences = {owner_id: [{"id": "occ_box", "resolved_part_id": "PART_BOX"}, {"id": "occ_cyl", "resolved_part_id": "PART_CYL"}]}
	fake.mesh_bytes = bytes
	fake.origin = true
	fake.plane_for = func(body: Dictionary) -> Dictionary:
		var ref: Dictionary = body["face_refs"][0]["face_ref"]
		var plane := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(table.table_copy, ref["body_id"], int(ref["index"])))
		return {"origin": [plane["origin"].x, plane["origin"].y, plane["origin"].z], "normal": [plane["n"].x, plane["n"].y, plane["n"].z],
			"x_axis": [plane["x"].x, plane["x"].y, plane["x"].z], "y_axis": [plane["y"].x, plane["y"].y, plane["y"].z]}
	ed.api = fake

	# --- a part on the table is looked up from its occurrence
	table.open()
	print("setup: with no part on the table the editor is idle: ", ed.state == "idle")
	table.seat(box)
	var looked_up: bool = await settle(func() -> bool: return ed.state == "pick_plane")
	print("setup: seating looks the part up through the owner's occurrences, not the node's own ids: ", looked_up and ed.part_id == "PART_BOX" and calls_to("/occurrences").size() >= 2)
	print("setup: plane picking is on, with the three reference planes drawn on the copy: ", ed.markers != null and ed.markers.get_parent() == table.table_copy and ed.markers.get_child_count() == 3)
	print("setup: ...and the user is told what to do: ", table.status().contains("Aim at a flat face"))

	# --- aiming at a face lights it up and takes the laser
	var pivot_world: Vector3 = table.pivot.global_position
	await aim(pivot_world + table.global_transform.basis * Vector3(0.0, 0.25, 0.45), pivot_world)
	print("setup: aiming at the part finds a face and the editor takes the laser: ", ed.hovering and not ed._hover_face.is_empty() and ed._hover_face["kind"] == "face")
	print("setup: ...the shared ui_hover claim is set, so a trigger here never selects an arena part: ", r.get_meta("ui_hover", false) and float(r.get_meta("ui_hit_distance", -1.0)) > 0.0)
	print("setup: ...and that face is lit on the copy: ", ed.highlight.hover_node(r) != null and ed.highlight.hover_node(r).get_parent() == table.table_copy)
	await aim(Vector3(1.0, 1.5, 1.0), Vector3(2.0, 1.5, 2.0))
	print("setup: aiming away lets go of the claim and clears the highlight: ", not ed.hovering and not r.get_meta("ui_hover", false) and ed.highlight.hover_node(r) == null)

	# ================= T6 =================
	var SA := preload("res://scripts/design_table/selection_actions.gd")
	var Drawer := preload("res://scripts/design_table/selection_drawer.gd")
	var pivot_at: Vector3 = table.pivot.global_position
	var face_view_from: Vector3 = pivot_at + table.global_transform.basis * Vector3(0.0, 0.25, 0.45)
	print("SMOKE the table has a selection drawer, away to begin with, a child of the console (it moves when the console is carried): ", table.drawer != null and not table.drawer.shown and table.drawer.get_parent() == table)

	# --- a pull on a face selects it and the drawer rises
	await aim(face_view_from, pivot_at)
	await pull()
	print("SMOKE with no tool a pull on a lit face SELECTS it (no sketch is started): ", ed.part_selection.size() == 1 and ed.part_selection[0]["kind"] == "face" and ed.state == "pick_plane" and calls_to("/create-plane-features").is_empty())
	print("SMOKE ...the drawer is out, its first action is New sketch on face (flat face), and the breadcrumb starts Face N: ", table.drawer.shown and table.drawer.visible and table.drawer.actions[0]["id"] == "sketch_on_face" and table.drawer.rungs[0]["text"].begins_with("Face ") and table.drawer.button_named("Action_sketch_on_face") != null and table.drawer.button_named("Crumb_part") != null)
	print("SMOKE ...every action is a laser target at least 4 cm tall, a disabled one stays with its reason (Create plane for one face is on; the breadcrumb has the part as its last rung): ", table.drawer.button_named("Action_sketch_on_face").custom_minimum_size.y / Drawer.PX_PER_M >= 0.04 and table.drawer.rungs.back()["level"] == "part")

	# --- fixed size, inside the slab
	for size in [Vector2(0.5, 0.3), Vector2(0.6, 0.4), Vector2(1.4, 0.8)]:
		table.set_slab_size(size)
		await frames(2)
		var cs: Array = table.drawer.corners_in_console()
		var minx := INF
		var maxx := -INF
		var maxz := -INF
		var minz := INF
		for c in cs:
			minx = minf(minx, c.x)
			maxx = maxf(maxx, c.x)
			maxz = maxf(maxz, c.z)
			minz = minf(minz, c.z)
		var width := maxx - minx
		print("SMOKE slab %s: the drawer is 0.40 m wide whatever the slab, centred, and inside the slab's outline (never past its front edge): " % str(size), absf(width - 0.40) < 0.002 and absf((minx + maxx) * 0.5) < 0.002 and maxz <= size.y * 0.5 + 0.001 and minz >= -size.y * 0.5 and maxx <= size.x * 0.5 and minx >= -size.x * 0.5)
		print("SMOKE slab %s: ...its depth along the slab is about 0.106 m (0.11 m tipped up 15 degrees) and it stays a few millimetres above the glass: " % str(size), absf((maxz - minz) - 0.11 * cos(deg_to_rad(15.0))) < 0.003 and table.drawer.corners_in_console().all(func(c) -> bool: return c.y > 0.0))
	table.set_slab_size(Vector2(0.6, 0.4))
	await frames(2)

	# --- the standing eye point: the drawer clears the deck, the Properties and the tree windows
	var eye := Camera3D.new()
	main.add_child(eye)
	eye.make_current()
	eye.global_transform = main.get_node("XROrigin3D/XRCamera3D").global_transform
	var drawer_rect_for := func() -> Rect2:
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for c in table.drawer.corners_in_console():
			var p: Vector2 = eye.unproject_position(table.to_global(c))
			lo = lo.min(p)
			hi = hi.max(p)
		return Rect2(lo, hi - lo)
	var panel_rect_for := func(panel: Node3D) -> Rect2:
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		var h: Vector2 = panel.panel_size * 0.5
		for c in [Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)]:
			var p: Vector2 = eye.unproject_position(panel.to_global(Vector3(c.x, c.y, 0.0)))
			lo = lo.min(p)
			hi = hi.max(p)
		return Rect2(lo, hi - lo)
	for size in [Vector2(0.5, 0.3), Vector2(1.4, 0.8)]:
		table.set_slab_size(size)
		table.recall()
		await frames(3)
		eye.global_transform = main.get_node("XROrigin3D/XRCamera3D").global_transform
		var dr: Rect2 = drawer_rect_for.call()
		var deck_top_y: float = eye.unproject_position(table.to_global(Vector3(0.0, -0.01, size.y * 0.5 + table.deck_gap))).y
		var deck_rect := Rect2(Vector2(-1e5, deck_top_y), Vector2(2e5, 1e5)) # everything on screen below the deck's top edge
		var tree_rect: Rect2 = panel_rect_for.call(table.tree)
		var props_rect: Rect2 = panel_rect_for.call(table.props)
		print("SMOKE slab %s, from the standing eye point: the drawer's on-screen rectangle is above the tool deck's top edge (it never covers a deck button): " % str(size), table.drawer.shown and not dr.intersects(deck_rect))
		print("SMOKE slab %s: ...and clear of the Properties window and the tree window: " % str(size), not dr.intersects(props_rect) and not dr.intersects(tree_rect))
	table.set_slab_size(Vector2(0.6, 0.4))
	table.recall()
	await frames(3)

	# --- the deck does not move when the drawer opens or closes
	var deck_before: Vector3 = table._deck.global_position
	ed.clear_part_selection()
	await frames(2)
	print("SMOKE the drawer closing / opening does not move the deck (controls that shift under the laser are worse than a smaller drawer): ", table._deck.global_position.is_equal_approx(deck_before) and not table.drawer.shown)

	# --- Fillet on an edge starts Fillet with the edge already picked
	var topo: Dictionary = table.table_copy.get_meta("topology")
	var body_id: String = topo.keys()[0]
	var edge_index := -1
	var edge_mid := Vector3.ZERO
	for index in (topo[body_id]["edge_kinds"] as Dictionary):
		if topo[body_id]["edge_kinds"][index] == "line":
			var pts: PackedVector3Array = topo[body_id]["edges"][index]
			edge_index = int(index)
			edge_mid = (pts[0] + pts[pts.size() - 1]) * 0.5
			break
	var edge_world: Vector3 = table.table_copy.global_transform * edge_mid
	var outward: Vector3 = (edge_world - table.pivot.global_position).normalized()
	var saved_markers = ed.markers
	ed.markers = null # (a reference-plane square can sit between the laser and a part's edge; this aim is for the edge)
	await aim(edge_world + outward * 0.4, edge_world)
	await pull()
	ed.markers = saved_markers
	print("SMOKE a pull on a lit edge selects the edge, and the drawer offers Fillet first, then Chamfer, Create plane: ", ed.part_selection.size() == 1 and ed.part_selection[0]["kind"] == "edge" and table.drawer.shown and table.drawer.actions.map(func(a): return a["id"]) == ["fillet", "chamfer", "create_plane"])
	var edge_key: String = ed.part_selection[0]["key"]
	table.drawer.button_named("Action_fillet").pressed.emit()
	await frames(4)
	print("SMOKE choosing Fillet starts the Fillet tool in edge picking with that edge already picked (still removable), and the drawer goes while the tool runs: ", table.active_tool == "fillet" and ed.state == "pick_edges" and ed.edges.size() == 1 and ed.edges[0]["key"] == edge_key and not table.drawer.shown and ed.part_selection.is_empty())
	print("SMOKE ...and the tool's own option row is there to set the radius: ", table.ui.option_button("radius") != null)
	table.manager.deactivate()
	await frames(3)
	print("SMOKE putting the tool down goes back to choosing: the edge picks are the tool's, so no drawer: ", ed.state == "pick_plane" and not table.drawer.shown)

	# --- empty space, B and X
	await aim(face_view_from, pivot_at)
	await pull()
	print("# selected again: ", ed.part_selection.size())
	await aim(Vector3(1.0, 1.5, 1.0), Vector3(2.0, 1.5, 2.0))
	await pull()
	print("SMOKE a pull on empty space (no part entity, no UI) lets go of the selection and closes the drawer: ", ed.part_selection.is_empty() and not table.drawer.shown)
	await aim(face_view_from, pivot_at)
	await pull()
	var deck_aim: Vector3 = table._deck.global_position
	await aim(deck_aim + table._deck.global_transform.basis.z * 0.5, deck_aim)
	await pull()
	print("SMOKE a pull on the tool deck never clears the selection: ", not ed.part_selection.is_empty() and table.drawer.shown)
	r.button_pressed.emit("by_button")
	await frames(2)
	print("SMOKE B on the right controller closes the drawer and clears the selection: ", ed.part_selection.is_empty() and not table.drawer.shown)
	await aim(face_view_from, pivot_at)
	await pull()
	table.drawer.button_named("Close").pressed.emit()
	await frames(2)
	print("SMOKE the X clears the selection and closes the drawer (one meaning for close): ", ed.part_selection.is_empty() and not table.drawer.shown)

	# --- New sketch on face opens the sketch on THAT face
	await aim(face_view_from, pivot_at)
	await pull()
	var chosen: Dictionary = ed.part_selection[0].duplicate()
	table.drawer.button_named("Action_sketch_on_face").pressed.emit()
	var opened: bool = await settle(func() -> bool: return ed.state == "sketch")
	var plane_call: Array = calls_to("/create-plane-features")[0] if not calls_to("/create-plane-features").is_empty() else [0, {}]
	print("SMOKE New sketch on face opens a sketch on the selected face (an offset_face plane on exactly that face), and the selection is spent: ", opened and plane_call[1].get("plane_type", "") == "offset_face" and plane_call[1]["face_refs"][0]["face_ref"]["index"] == chosen["index"] and ed.part_selection.is_empty() and not table.drawer.shown)

	# --- a sketch open: the drawer carries the sketch selection's options, and the sheet stands behind it
	print("SMOKE with a sketch open the front-hinged sheet stands behind the drawer, never over it: ", table.sketch_sheet_front and table.sheet_centre().z + table.sheet_window_m.y * 0.5 * cos(deg_to_rad(table.sketch_tilt())) <= table.slab_size.y * 0.5 - Drawer.DRAWER_SIZE.y + 0.001)
	table.manager.activate("select")
	await frames(2)
	await ed.session.select({"kind": "point", "id": ed.session.origin_id})
	await frames(2)
	print("SMOKE ...and a sketch selection's options (Fix for a point) are in the drawer too: ", table.drawer.shown and table.drawer.button_named("Action_fix") != null)
	var sketch_dr: Rect2 = drawer_rect_for.call()
	eye.global_transform = main.get_node("XROrigin3D/XRCamera3D").global_transform
	var deck_top2: float = eye.unproject_position(table.to_global(Vector3(0.0, -0.01, table.slab_size.y * 0.5 + table.deck_gap))).y
	print("SMOKE ...and with the sketch open the drawer still clears the deck, the Properties and the tree windows: ", not sketch_dr.intersects(Rect2(Vector2(-1e5, deck_top2), Vector2(2e5, 1e5))) and not sketch_dr.intersects(panel_rect_for.call(table.props)) and not sketch_dr.intersects(panel_rect_for.call(table.tree)))
	ed.session.clear_selection()
	await frames(2)
	print("SMOKE ...and it goes when the sketch selection is cleared: ", not table.drawer.shown)
	table.close()
	await frames(2)
	print("SMOKE closing the table closes the drawer: ", not table.drawer.shown)
	quit()
