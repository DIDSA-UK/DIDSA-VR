extends SceneTree
## Full-scene test for the design table (scripts/design_table/design_table.gd): main.tscn with NO backend, a
## simulated right laser and hand-built parts. Covers the tablet's Table page summoning it, the deck's category
## and tool rows by real laser clicks (the one-active-tool rule, hints, the "ui_hover" claim), putting a part on
## the table by letting go of it over the slab (the arena node stays put, hidden; a scaled copy floats above the
## slab), refusals (no backend identity, table full, outside the slab), handling it on the table (one grip moves it,
## two turn and scale it, the stick spins it, A / B push and pull it, all independent of the world; the engaged tell;
## Reset), letting go beyond the slab sending the real part back (original orientation, the arena's scale, saved as an
## ordinary move), the To arena button, closing with a part on it, hide-all not bringing
## the seated node back, and the grab handle moving the console with the part riding along.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_scene.gd  (see tests/README.md)

const TableSeat := preload("res://scripts/design_table/table_seat.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

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

func _settles_disengaged() -> bool:
	# Laser far away, no grips: after the grace period the table lets go of the stick.
	r.global_transform = Transform3D(Basis.IDENTITY, Vector3(1.0, 1.5, 1.0))
	for i in 3:
		await process_frame
	table.manip.process(0.2)
	return not table.manip.engaged and not table.ui.chip_visible() and not table._engaged and not r.is_manipulating()


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
	print("SMOKE Sketch is shown first, with Select and the first four drawing tools: ", shown == ["select", "line", "rectangle", "circle", "arc"])
	print("SMOKE ...and a More button, since seven do not fit the row of six: ", table.ui.more_button() != null)
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

	# --- handling the part on the table: independent of the world
	UiFeedback.reduce_motion = true
	r.global_position = Vector3(1.0, 1.5, 1.0)
	var arena_scale := 0.001
	var root_before: Transform3D = main.assembly_root.global_transform
	print("SMOKE Reset and To arena are on the deck and live while a part is on the table: ", table.ui.reset_button() != null and not table.ui.reset_button().disabled and not table.ui.return_button().disabled)
	print("SMOKE the table is not engaged while nobody is on the part: ", not table.manip.engaged and not table.ui.chip_visible())
	var home: Vector3 = table.pivot.position
	var pivot_world: Vector3 = table.pivot.global_position
	l.global_position = pivot_world + Vector3(0.05, 0.0, 0.0)
	await physics_frame
	l.button_pressed.emit("grip_click")
	await process_frame
	print("SMOKE gripping the part on the table holds the COPY, not the real part: ", table.manip.is_gripping() and l.held_node == null and table.seated == body and not body.visible and body.has_meta("on_table"))
	print("SMOKE ...the hand is marked so the world is not also dragged: ", l.get_meta("table_part_held", false) and not main._two_hand._hand_free_ignoring_button(l))
	print("SMOKE ...and the table is engaged: chip on the deck and the frame glowing: ", table.manip.engaged and table.ui.chip_visible() and table._engaged and float(table._frame_material.get_shader_parameter("glow")) > 0.5)
	l.global_position = pivot_world + Vector3(0.05, 0.0, 0.0) + table.global_transform.basis * Vector3(0.10, 0.04, 0.0)
	await process_frame
	await process_frame
	print("SMOKE moving the hand moves the part 1:1 along the console's own axes: ", (table.pivot.position - (home + Vector3(0.10, 0.04, 0.0))).length() < 0.002)
	print("SMOKE ...while the arena (the real part, the model, the world scale) is untouched: ", body.global_transform.is_equal_approx(original) and main.assembly_root.global_transform.is_equal_approx(root_before))
	print("SMOKE ...and the part's own turn and size on the table are unchanged by a one-hand move: ", is_equal_approx(table.user_scale, 1.0) and table.pivot.basis.is_equal_approx(table._seat_pivot_basis))
	l.button_released.emit("grip_click")
	await process_frame
	print("SMOKE letting go over the slab leaves it on the table, where you put it: ", table.seated == body and not table.manip.is_gripping() and not l.get_meta("table_part_held", false) and (table.pivot.position - (home + Vector3(0.10, 0.04, 0.0))).length() < 0.002)
	print("SMOKE ...and a move on the table is not an arena move (nothing to undo): ", not main.command_stack.can_undo())
	print("SMOKE ...the table stops being engaged once the hands are off and the laser is elsewhere: ", await _settles_disengaged())

	# two hands: turn and scale about the midpoint
	var c: Vector3 = table.pivot.position
	var basis_before: Basis = table.pivot.basis.orthonormalized()
	l.global_position = table.to_global(c + Vector3(-0.10, 0.0, 0.0))
	r.global_position = table.to_global(c + Vector3(0.10, 0.0, 0.0))
	await physics_frame
	l.button_pressed.emit("grip_click")
	r.button_pressed.emit("grip_click")
	await process_frame
	print("SMOKE a second grip joins: two hands on the part, both marked: ", table.manip.grip_count() == 2 and r.get_meta("table_part_held", false))
	await process_frame
	r.global_position = table.to_global(c + Vector3(0.20, 0.0, 0.0)) # hands 0.2 m apart -> 0.3 m
	await process_frame
	await process_frame
	print("SMOKE spreading the hands scales the part (1.5x for 1.5x the spread): ", absf(table.user_scale - 1.5) < 0.02)
	print("SMOKE ...the scale lives on the pivot so the sketch sheet follows, and the fitted scale is unchanged: ", absf(table.pivot.basis.get_scale().x - table.user_scale) < 0.001 and absf(table.effective_scale() - table.fit_scale * 1.5) < 0.00001)
	print("SMOKE ...and its bounding sphere is bigger by the same factor: ", absf(table.part_radius() - table.fit_radius * 1.5) < 0.004)
	print("SMOKE ...all while the arena is untouched: ", body.global_transform.is_equal_approx(original) and main.assembly_root.global_transform.is_equal_approx(root_before))
	var mid_now: Vector3 = table.to_local((l.global_position + r.global_position) * 0.5)
	r.global_position = table.to_global(c + Vector3(-0.10, 0.0, -0.30) + Vector3(0.0, 0.0, 0.0)) # swing the line from +X to -Z (a quarter turn)
	l.global_position = table.to_global(c + Vector3(-0.10, 0.0, 0.0))
	await process_frame
	await process_frame
	var turned: Basis = table.pivot.basis.orthonormalized()
	print("SMOKE swinging the line between the hands turns the part (a quarter turn about the slab's up axis): ", (turned * basis_before.inverse() * Vector3.RIGHT).distance_to(Vector3(0, 0, -1)) < 0.2 or (turned * basis_before.inverse()).get_euler().length() > 0.8)
	r.global_position = table.to_global(c + Vector3(3.0, 0.0, 0.0)) # far beyond any sane spread
	await process_frame
	await process_frame
	print("SMOKE scale is clamped (at most 3x fitted): ", table.user_scale <= 3.0 + 0.0001)
	l.global_position = table.to_global(c + Vector3(-0.10, 0.0, 0.0)) # hands back over the slab
	r.global_position = table.to_global(c + Vector3(0.10, 0.0, 0.0))
	await process_frame
	await process_frame
	var before_release: Vector3 = table.pivot.position
	r.button_released.emit("grip_click")
	await process_frame
	print("SMOKE letting go of one hand carries on one-handed without a jump: ", table.manip.grip_count() == 1 and (table.pivot.position - before_release).length() < 0.002)
	l.button_released.emit("grip_click")
	await process_frame
	print("SMOKE ...and the table keeps it when the last hand lets go over the slab: ", table.seated == body and not table.manip.is_gripping() and not l.get_meta("table_part_held", false) and not r.get_meta("table_part_held", false))

	# a grip far from the part, with no other hand on it, is not for the table
	l.global_position = table.to_global(Vector3(0.4, 0.6, 0.0))
	await physics_frame
	l.button_pressed.emit("grip_click")
	print("SMOKE a grip away from the part does nothing on the table: ", not table.manip.is_gripping())
	l.button_released.emit("grip_click")

	# the right stick and A / B, while engaged
	r.global_position = table.to_global(Vector3(0.0, 0.55, 0.55))
	r.global_transform = Transform3D(Basis.looking_at((table.pivot.global_position - r.global_position).normalized(), Vector3.UP), r.global_position)
	for i in 3:
		await process_frame
	print("SMOKE aiming the right laser at the part engages the table (a tick, a chip, a glowing frame): ", table.manip.engaged and table.ui.chip_visible() and table._engaged)
	print("SMOKE ...and the right stick is the table's now, so it neither turns you nor spins a selected part: ", r.is_manipulating() and not l.is_manipulating() and table.owns_stick(r))
	var spin_from: Basis = table.pivot.basis.orthonormalized()
	table.manip.drive_input(Vector2(1.0, 0.0), false, false, 1.0)
	print("SMOKE the stick spins the part about the slab's up axis (a second at full tilt is a quarter turn): ", (table.pivot.basis.orthonormalized() * spin_from.inverse() * Vector3.RIGHT).distance_to(Basis(Vector3.UP, deg_to_rad(90.0)) * Vector3.RIGHT) < 0.01)
	var tip_from: Basis = table.pivot.basis.orthonormalized()
	table.manip.drive_input(Vector2(0.0, 1.0), false, false, 0.5)
	print("SMOKE ...and up on the stick tips it away from you: ", (table.pivot.basis.orthonormalized() * tip_from.inverse() * Vector3.UP).z < -0.5)
	var p0: Vector3 = table.pivot.position
	var hand_local: Vector3 = table.to_local(r.global_position)
	table.manip.drive_input(Vector2.ZERO, false, true, 0.5) # B: push away
	var p1: Vector3 = table.pivot.position
	print("SMOKE B pushes it farther from your hand: ", p1.distance_to(hand_local) > p0.distance_to(hand_local) + 0.01)
	table.manip.drive_input(Vector2.ZERO, true, false, 0.5) # A: pull nearer
	print("SMOKE A pulls it nearer: ", table.pivot.position.distance_to(hand_local) < p1.distance_to(hand_local) - 0.01)
	for i in 40:
		table.manip.drive_input(Vector2.ZERO, false, true, 0.5)
	print("SMOKE ...but pushing never walks it off the table or through the slab: ", TableSeat.in_drop_zone(table.pivot.position, table.slab_size, table.drop_floor, table.drop_ceiling) and table.pivot.position.y >= 0.05 - 0.0001)
	r.set_meta("ui_hover", true)
	var held_basis: Basis = table.pivot.basis
	table.manip.drive_input(Vector2(1.0, 0.0), false, false, 1.0)
	print("SMOKE with the laser on the tool deck the stick is the deck's, not the part's: ", table.pivot.basis.is_equal_approx(held_basis))
	r.set_meta("ui_hover", false)

	# Reset
	table.ui.reset_button().pressed.emit()
	print("SMOKE Reset puts it back in the middle of the slab at its fitted size, the way it was put on: ", table.pivot.position.is_equal_approx(Vector3(0, table.hover_height, 0)) and is_equal_approx(table.user_scale, 1.0) and table.pivot.basis.is_equal_approx(table._seat_pivot_basis))

	# letting go beyond the slab sends the real part back to the arena, at that spot, at the arena's scale
	var fit_before: float = table.fit_scale
	var leave_at: Vector3 = table.to_global(Vector3(1.2, 0.3, 0.1))
	l.global_position = table.pivot.global_position + Vector3(0.04, 0.0, 0.0)
	await physics_frame
	l.button_pressed.emit("grip_click")
	await process_frame
	l.global_position = leave_at + Vector3(0.04, 0.0, 0.0)
	await process_frame
	await process_frame
	print("SMOKE carrying it past the slab turns the frame amber and says what letting go will do: ", table._leave_cue and table.manip.carry_outside and table.status().contains("send it back to the arena"))
	var release_centre: Vector3 = table.pivot.global_position
	l.button_released.emit("grip_click")
	await process_frame
	print("SMOKE letting go there sends the real part back to the arena: ", table.seated == null and body.visible and not body.has_meta("on_table") and l.held_node == null)
	print("SMOKE ...at the arena's scale (the copy was ", snappedf(fit_before / arena_scale, 0.01), "x bigger): ", absf(body.global_transform.basis.get_scale().x - arena_scale) < 0.00001)
	print("SMOKE ...in its original orientation: ", body.global_transform.basis.orthonormalized().is_equal_approx(original.basis.orthonormalized()))
	var lifted_centre: Vector3 = body.global_transform * aabb.get_center()
	print("SMOKE ...with its middle where the copy's middle was when you let go: ", lifted_centre.distance_to(release_centre) < 0.003)
	print("SMOKE the copy and its pivot are gone, the amber is off and the deck is idle: ", table.pivot == null and table.table_copy == null and table.get_node_or_null("TablePivot") == null and not table._leave_cue and not table.manip.engaged and table.ui.return_button().disabled)
	print("SMOKE it is an ordinary move, undoable back to the pre-table pose: ", main.command_stack.can_undo())
	main.command_stack.undo()
	print("SMOKE ...and undo puts it back where it was before it went on the table: ", body.global_transform.is_equal_approx(original))
	main.command_stack.clear()

	# the Return button: back exactly where it came from, nothing moved
	await carry_to(l, body, above_slab)
	l._try_release()
	print("SMOKE seated again: ", table.seated == body)
	table.ui.return_button().pressed.emit()
	print("SMOKE To arena puts the real part back exactly where it came from: ", table.seated == null and body.visible and not body.has_meta("on_table") and body.global_transform.is_equal_approx(original))
	print("SMOKE ...without recording a move: ", not main.command_stack.can_undo())

	# closing while a hand is on the part drops the grip cleanly
	await carry_to(l, body, above_slab)
	l._try_release()
	l.global_position = table.pivot.global_position
	await physics_frame
	l.button_pressed.emit("grip_click")
	table.close()
	print("SMOKE closing the table with a hand on the part lets go cleanly: ", not table.manip.is_gripping() and not l.get_meta("table_part_held", false) and body.visible and body.global_transform.is_equal_approx(original))
	l.button_released.emit("grip_click")
	table.open()
	r.global_position = Vector3(1.0, 1.5, 1.0)
	r.rotation = Vector3.ZERO
	await process_frame

	# --- the glass slab, and dragging its corners to resize it (the same gesture as the floating windows)
	var glass_mat: ShaderMaterial = table._frame_material
	print("SMOKE the slab is a glass pane: rounded corners and a rim, a clear middle: ", table._slab.mesh is PlaneMesh and glass_mat.shader.resource_path.ends_with("table_glass.gdshader") and float(glass_mat.get_shader_parameter("radius")) > 0.02 and float(glass_mat.get_shader_parameter("border_width")) > 0.003 and (glass_mat.get_shader_parameter("fill_color") as Color).a < 0.5)
	print("SMOKE ...with a resize bracket at each corner, hugging the rounded corner: ", table.resizer._holders.size() == 4 and table.resizer._holders[3].position.is_equal_approx(Vector3(0.3, 0.003, 0.2)) and table.resizer._holders[0].scale.x < 0.0)
	var saved_xf: Transform3D = table.global_transform
	var up: Vector3 = table.global_transform.basis.y.normalized()
	var aim_world := func(target: Vector3) -> void:
		r.global_transform = Transform3D(Basis.looking_at(-up, table.global_transform.basis.z), target + up * 0.5)
		for i in 3:
			await process_frame
	var aim_at := func(local: Vector3) -> void:
		await aim_world.call(table.to_global(local))
	await aim_at.call(Vector3(0.0, 0.0, 0.0)) # on the glass itself: not a corner
	print("SMOKE aiming at the middle of the glass is not a corner: ", table.resizer.hover == -1 and not r.get_meta("ui_hover", false))
	await aim_at.call(Vector3(0.35, 0.0, 0.25)) # just outside the front-right corner
	print("SMOKE aiming just outside a corner lights its bracket and claims the laser (so a trigger never selects a part): ", table.resizer.hover == 3 and r.get_meta("ui_hover", false) and float(r.get_meta("ui_hit_distance", -1.0)) > 0.0 and table.resizer._materials[3].albedo_color.is_equal_approx(table.tokens.accent))
	var dot3: MeshInstance3D = table.resizer._holders[3].get_node("CornerDot")
	print("SMOKE ...a small point sits at the slab rectangle's corner (past the curved glass), the aimed one white and the rest in the accent: ", dot3.mesh is SphereMesh and (dot3.mesh as SphereMesh).radius > 0.005 and (dot3.mesh as SphereMesh).radius < 0.02 and table.resizer._dot_materials[3].albedo_color.is_equal_approx(Color.WHITE) and not table.resizer._dot_materials[0].albedo_color.is_equal_approx(Color.WHITE) and table.resizer._holders.all(func(h): return h.get_node("CornerDot").position == Vector3.ZERO))
	var back_left_before: Vector3 = table.to_global(Vector3(-0.3, 0.0, -0.2))
	var drag_to: Vector3 = table.to_global(Vector3(0.6, 0.0, 0.35)) # a world point: the console moves as it is dragged
	var deck_z_before: float = table._deck.position.z
	r.button_pressed.emit("trigger_click")
	await process_frame
	print("SMOKE the trigger starts a drag of that corner: ", table.resizer.dragging == 3)
	await aim_world.call(drag_to)
	print("SMOKE dragging the corner out resizes the slab, the opposite corner staying put: ", table.slab_size.is_equal_approx(Vector2(0.9, 0.55)) and table.to_global(Vector3(-0.45, 0.0, -0.275)).distance_to(back_left_before) < 0.003)
	print("SMOKE ...the glass, the handle on the front edge, the deck in front of it and the tree at the left all follow: ", ((table._slab.mesh as PlaneMesh).size).is_equal_approx(Vector2(0.9, 0.55)) and table.handle.node.position.is_equal_approx(Vector3(0.0, -0.275 - table.handle.drop_distance, 0.01)) and absf(table._deck.position.z - (deck_z_before + 0.075)) < 0.001 and table.tree.dock_position.x < -0.6 and table.resizer._holders[3].position.is_equal_approx(Vector3(0.45, 0.003, 0.275)))
	print("SMOKE ...and drop zone and the part's place follow too: ", TableSeat.in_drop_zone(Vector3(0.5, 0.2, 0.3), table.slab_size, table.drop_floor, table.drop_ceiling) and not TableSeat.in_drop_zone(Vector3(0.5, 0.2, 0.3), Vector2(0.6, 0.4), table.drop_floor, table.drop_ceiling))
	await aim_at.call(Vector3(5.0, 0.0, 5.0))
	print("SMOKE the size is clamped (at most 1.4 x 1.0 m): ", table.slab_size.is_equal_approx(Vector2(1.4, 1.0)))
	await aim_at.call(Vector3(-5.0, 0.0, -5.0))
	print("SMOKE ...and at least 0.5 x 0.3 m: ", table.slab_size.is_equal_approx(Vector2(0.5, 0.3)))
	r.button_released.emit("trigger_click")
	await process_frame
	print("SMOKE letting go ends the drag: ", table.resizer.dragging == -1)
	table.set_slab_size(Vector2(0.6, 0.4))
	table.global_transform = saved_xf
	r.global_transform = Transform3D(Basis.IDENTITY, Vector3(1.0, 1.5, 1.0))
	for i in 3:
		await process_frame
	print("SMOKE the laser away from the table lets go of the claim: ", not r.get_meta("ui_hover", false))

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
