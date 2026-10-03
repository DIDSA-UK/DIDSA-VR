extends SceneTree
## Full-scene test for the design table (scripts/design_table/design_table.gd): main.tscn with NO backend, a
## simulated right laser and hand-built parts. Covers the tablet's Table page summoning it, the deck's category
## and tool rows by real laser clicks (the one-active-tool rule, hints, the "ui_hover" claim), putting a part on
## the table by letting go of it over the slab (the arena node stays put, hidden; a scaled copy floats above the
## slab), refusals (no backend identity, table full, outside the slab), lifting it off by grip (original
## orientation, the arena's scale, saved as an ordinary move), closing with a part on it, hide-all not bringing
## the seated node back, and the grab handle moving the console with the part riding along.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_scene.gd  (see tests/README.md)

var main
var table
var l: XRController3D
var r: XRController3D
var origin: XROrigin3D
var cam: XRCamera3D

func find_button(pred: Callable) -> Button:
	var stack: Array = [table._viewport]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Button and n.is_visible_in_tree() and pred.call(n):
			return n
		stack.append_array(n.get_children())
	return null

func click_now() -> void:
	r.button_pressed.emit("trigger_click")
	await process_frame
	r.button_released.emit("trigger_click")
	await process_frame

func aim_only(b: Button) -> void:
	var c: Vector2 = b.global_position + b.size * 0.5
	var vp := Vector2(table._viewport.size)
	var lx: float = (c.x / vp.x - 0.5) * table.tools_size.x
	var ly: float = (0.5 - c.y / vp.y) * table.tools_size.y
	var xf: Transform3D = table._deck_quad.global_transform
	var p: Vector3 = xf * Vector3(lx, ly, 0.0)
	var n: Vector3 = xf.basis.z.normalized()
	r.global_transform = Transform3D(Basis.looking_at(-n, Vector3.UP), p + n * 0.4)
	for i in 3:
		await process_frame

func aim_and_click(b: Button) -> void:
	await aim_only(b)
	await click_now()

func part(size_mm: Vector3, pos: Vector3, owner_id := "P1") -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size_mm
	m.mesh = bm
	main.assembly_root.add_child(m)
	m.position = pos
	m.add_to_group("grabbable_parts")
	if owner_id != "":
		m.set_meta("owner_part_id", owner_id)
		m.set_meta("occurrence_id", "occ_" + m.name)
	return m

func carry_to(hand: XRController3D, node: Node3D, world_point: Vector3) -> void:
	# Grab it where it is, move the hand, let physics drive the carried part, let go.
	hand.global_position = node.global_position
	await physics_frame
	hand._try_grab()
	hand.global_position = world_point
	await physics_frame
	await physics_frame

func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	origin = main.get_node("XROrigin3D")
	cam = origin.get_node("XRCamera3D")
	l = origin.get_node("LeftController")
	r = origin.get_node("RightController")
	cam.position = Vector3(0, 1.6, 0)
	l.position = Vector3(-0.5, 1.0, -0.2)
	r.position = Vector3(1.0, 1.5, 1.0)
	l.set_steadiness(0)
	r.set_steadiness(0)
	table = main.design_table
	table.surface.settle_seconds = 0.0
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	for i in 4:
		await process_frame

	# --- built, closed by default, summoned from the tablet's Table page
	print("SMOKE main built the design table: ", table != null and table.get_script().resource_path.ends_with("design_table.gd"))
	print("SMOKE it is closed and hidden by default: ", not table.is_open() and not table.visible)
	print("SMOKE it is in the groups controller.gd asks about: ", table.is_in_group("design_tables") and table.is_in_group("diegetic_panels"))
	var tablet = l.get_node("WristTablet")
	var def = tablet.registry.tool_def("table")
	print("SMOKE the tablet has a Table tool in the Assembly category: ", def != null and def.category_id == "assembly" and not def.is_mode())
	var page: Control = def.build.call()
	var summon: Button = null
	for n in page.find_children("*", "Button", true, false):
		if (n as Button).text == "Summon table":
			summon = n
	print("SMOKE the Table page offers Summon table: ", summon != null)
	summon.pressed.emit()
	await process_frame
	print("SMOKE pressing it opens the table: ", table.is_open() and table.visible)
	var ahead: Vector3 = table.global_position - cam.global_position
	print("SMOKE it opens in front of you, below eye level: ", ahead.z < -0.5 and absf(ahead.x) < 0.1 and ahead.y < -0.3 and ahead.y > -0.6)
	print("SMOKE ...facing you (its +Z towards the camera) and leaning back a little: ", table.global_transform.basis.z.z > 0.85 and table.global_transform.basis.y.y < 0.97 and table.global_transform.basis.y.y > 0.85)
	print("SMOKE the table starts empty: ", table.seated == null and table.pivot == null)

	# --- the deck: categories and tools, by real laser clicks
	print("SMOKE three category buttons: ", ["Sketch", "Constrain", "Feature"].all(func(t): return find_button(func(b): return b.text == t) != null))
	var shown: Array = table.ui.shown_tool_ids()
	print("SMOKE Sketch is shown first with DIDSA-CAD's six drawing tools: ", shown == ["line", "rectangle", "circle", "arc", "polygon", "point"])
	print("SMOKE ...and no More button, since six fit: ", table.ui.more_button() == null)
	await aim_and_click(find_button(func(b): return b.text == "Constrain"))
	print("SMOKE clicking Constrain swaps the tool row: ", table.ui.shown_tool_ids() == ["dimension", "horizontal", "vertical", "parallel", "perpendicular", "coincident"])
	print("SMOKE ...without switching any tool on: ", table.active_tool == "")
	await aim_and_click(find_button(func(b): return b.text == "Dimension"))
	print("SMOKE clicking a tool turns it on and shows its hint: ", table.active_tool == "dimension" and table.status().begins_with("Pick a line"))
	print("SMOKE the pressed tool button shows as on: ", table.ui.tool_button("dimension").button_pressed)
	await aim_and_click(find_button(func(b): return b.text == "Feature"))
	await aim_and_click(find_button(func(b): return b.text == "Extrude"))
	print("SMOKE only one tool is on across categories: ", table.active_tool == "extrude" and not table.manager.is_active("dimension"))
	await aim_and_click(find_button(func(b): return b.text == "Extrude"))
	print("SMOKE clicking the active tool again turns it off: ", table.active_tool == "")
	await aim_only(find_button(func(b): return b.text == "Sketch"))
	print("SMOKE the laser on the deck claims ui_hover: ", r.get_meta("ui_hover", false) and float(r.get_meta("ui_hit_distance", -1.0)) > 0.0)
	r.global_position = Vector3(1.0, 1.5, 1.0)
	for i in 3:
		await process_frame
	print("SMOKE ...and lets go when the laser leaves: ", not r.get_meta("ui_hover", false))

	# --- seating
	var body := part(Vector3(100, 50, 30), Vector3(0, 100, 0)) # 10 x 5 x 3 cm at 1:1000 scale, up at x=0, y=1.1, z=-1.0
	var original: Transform3D = body.global_transform
	var above_slab: Vector3 = table.to_global(Vector3(0.0, 0.2, 0.0))
	await carry_to(l, body, above_slab)
	print("SMOKE the hand carries the part: ", l.held_node == body and body.has_meta("held"))
	l._try_release()
	print("SMOKE letting go over the slab puts it on the table: ", table.seated == body and body.has_meta("on_table"))
	print("SMOKE the arena node is hidden and exactly where it was (nothing about the assembly changed): ", not body.visible and body.global_transform.is_equal_approx(original))
	print("SMOKE it was not recorded as a move, so nothing is saved: ", not main.command_stack.can_undo())
	print("SMOKE a copy floats above the slab: ", table.table_copy != null and table.pivot.position.is_equal_approx(Vector3(0, table.hover_height, 0)))
	var aabb: AABB = body.get_aabb()
	print("SMOKE ...scaled so its bounding sphere is the fit radius: ", absf(aabb.size.length() * 0.5 * table.fit_scale - table.fit_radius) < 0.001)
	var centre_world: Vector3 = table.table_copy.global_transform * aabb.get_center()
	print("SMOKE ...with the middle of its bounds on the pivot: ", centre_world.distance_to(table.pivot.global_position) < 0.002)
	print("SMOKE ...tagged with the same identity, with a collider on the table layer only: ", table.table_copy.get_meta("owner_part_id") == "P1" and table.table_copy.get_children().any(func(c): return c is StaticBody3D and c.collision_layer == table.TABLE_LAYER and c.collision_mask == 0))
	print("SMOKE the copy is not an arena part, so arena tools never see it: ", not table.table_copy.is_in_group("grabbable_parts"))
	print("SMOKE ...and the hand can no longer grab the hidden arena node: ", l._find_grab_target() == null)

	# --- hide / show all must not bring the seated node back
	main.show_all_parts()
	print("SMOKE show-all leaves the seated node hidden: ", not body.visible)
	main.reverse_visibility()
	main.reverse_visibility()
	print("SMOKE ...and so does reverse visibility: ", not body.visible)

	# --- refusals
	var second := part(Vector3(40, 40, 40), Vector3(0.2 * 1000, 100, 0), "P2")
	await carry_to(l, second, above_slab)
	l._try_release()
	print("SMOKE a second part is refused while the table is full: ", table.seated == body and second.visible and table.status().contains("already holds"))
	print("SMOKE ...and let go as an ordinary move: ", main.command_stack.can_undo())
	main.command_stack.clear()

	# --- lifting
	r.global_position = Vector3(1.0, 1.5, 1.0)
	var arena_scale := 0.001
	l.global_position = table.pivot.global_position + Vector3(0.05, 0.0, 0.0)
	await physics_frame
	var count_before: int = table.get_child_count()
	var fit_before: float = table.fit_scale
	l._try_grab()
	print("SMOKE gripping the part on the table lifts the real one out: ", l.held_node == body and body.visible and not body.has_meta("on_table") and table.seated == null)
	print("SMOKE ...at the arena's scale (the copy was ", snappedf(fit_before / arena_scale, 0.01), "x bigger): ", absf(body.global_transform.basis.get_scale().x - arena_scale) < 0.00001)
	print("SMOKE ...in its original orientation: ", body.global_transform.basis.orthonormalized().is_equal_approx(original.basis.orthonormalized()))
	var lifted_centre: Vector3 = body.global_transform * aabb.get_center()
	print("SMOKE ...with its middle where the copy's middle was: ", lifted_centre.distance_to(table.to_global(Vector3(0, table.hover_height, 0))) < 0.003)
	print("SMOKE the copy and its pivot are gone: ", table.pivot == null and table.table_copy == null and table.get_child_count() == count_before - 1)
	l.global_position = Vector3(-0.8, 1.0, -0.6)
	await physics_frame
	await physics_frame
	l._try_release()
	print("SMOKE put down in the arena it is an ordinary move, undoable back to the pre-table pose: ", main.command_stack.can_undo() and not body.get_meta("held", false))
	main.command_stack.undo()
	print("SMOKE ...and undo puts it back where it was before it went on the table: ", body.global_transform.is_equal_approx(original))

	# --- no backend identity: not editable
	var local := part(Vector3(30, 30, 30), Vector3(0, 100, 0), "")
	await carry_to(l, local, above_slab)
	l._try_release()
	print("SMOKE a part with no backend identity is refused with a reason: ", table.seated == null and table.status().contains("no part behind it"))
	print("SMOKE ...and is put down as an ordinary part: ", local.visible and main.command_stack.can_undo())
	main.command_stack.clear()

	# --- outside the slab
	var outside: Vector3 = table.to_global(Vector3(1.2, 0.2, 0.0))
	await carry_to(l, body, outside)
	l._try_release()
	print("SMOKE letting go beside the slab is just an ordinary release: ", table.seated == null and body.visible)
	main.command_stack.clear()

	# --- closing with a part on the table
	await carry_to(l, body, above_slab)
	l._try_release()
	print("SMOKE seated again: ", table.seated == body)
	var close_pose: Transform3D = body.global_transform
	table.close()
	print("SMOKE closing the table brings the real node back untouched: ", not table.is_open() and body.visible and not body.has_meta("on_table") and body.global_transform.is_equal_approx(close_pose) and table.seated == null)

	# --- the grab handle moves the console, the part rides along
	table.open()
	await carry_to(l, body, above_slab)
	l._try_release()
	r.global_position = Vector3(1.0, 1.5, 1.0)
	var before_console: Transform3D = table.global_transform
	var rel_pivot: Vector3 = table.to_local(table.pivot.global_position)
	var pill: Vector3 = table.handle.node.global_position
	l.global_position = pill
	await physics_frame
	l.button_pressed.emit("grip_click")
	print("SMOKE gripping the handle takes it, not the part: ", table.handle.held_by == l and l.held_node == null and table.seated == body)
	l.global_position = pill + Vector3(0.0, 0.0, 0.5)
	l.rotation_degrees.y = 30.0
	await process_frame
	await process_frame
	l.button_released.emit("grip_click")
	print("SMOKE moving the hand moves the console: ", table.global_position.distance_to(before_console.origin) > 0.3)
	print("SMOKE ...and turns it with the hand: ", not table.global_transform.basis.is_equal_approx(before_console.basis))
	print("SMOKE ...the part stays where it was ON the console: ", table.to_local(table.pivot.global_position).distance_to(rel_pivot) < 0.001)
	print("SMOKE ...and the console's slab/deck layout is rigid: ", table._handle_frame.transform.is_equal_approx(table._handle_local))
	table.close()
	quit()
