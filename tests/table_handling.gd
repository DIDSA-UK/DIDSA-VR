extends SceneTree
## How the design table handles a part and remembers things (G17-G19 of docs/design-table-gaps.md): the slab's size is remembered and
## the tool deck follows its width; the biggest zoom is a setting; a part sent back to the arena comes back in its original turn or,
## by setting, in the turn it was given on the table; and one hand with the turn modifier held (the left stick) turns the part with
## the wrist, while without it a wrist twist does nothing.
## Run: "$GODOT" --headless --path . --script res://tests/table_handling.gd  (see tests/README.md)

const AppSettings := preload("res://scripts/app_settings.gd")
const TablePose := preload("res://scripts/design_table/table_pose.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var l: XRController3D
var r: XRController3D


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	l = origin.get_node("LeftController")
	r = origin.get_node("RightController")
	l.position = Vector3(-0.5, 1.0, -0.2)
	r.position = Vector3(1.0, 1.5, 1.0)
	l.set_steadiness(0)
	table = main.design_table
	table.surface.settle_seconds = 0.0
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	var settings = main.app_settings()
	var saved_before: Vector2 = settings.table_slab_size

	# --- the slab's size is remembered, the deck follows its width
	table.open()
	print("SMOKE the deck starts 0.6 m wide, as wide as the default slab: ", is_equal_approx(table.tools_size.x, 0.6) and is_equal_approx(table.deck_width_for(0.6), 0.6))
	table.set_slab_size(Vector2(0.9, 0.55))
	print("SMOKE a wider slab gives a wider deck (0.9 m): the picture, the surface and the quad all follow: ", is_equal_approx(table.tools_size.x, 0.9) and table._viewport.size.x == int(round(0.9 * table.pixels_per_metre)) and is_equal_approx(table.surface.panel_size.x, 0.9) and is_equal_approx((table._deck_quad.mesh as QuadMesh).size.x, 0.9) and is_equal_approx(table.ui.size.x, float(table._viewport.size.x)))
	table.set_slab_size(Vector2(1.4, 0.8))
	print("SMOKE ...never wider than 1 m, and a small slab never narrows it below 0.6 m: ", is_equal_approx(table.tools_size.x, 1.0) and is_equal_approx(table.deck_width_for(0.5), 0.6))
	table.set_slab_size(Vector2(0.6, 0.4))
	print("SMOKE ...and back to 0.6 m: ", is_equal_approx(table.tools_size.x, 0.6))
	table.set_slab_size(Vector2(0.9, 0.55))
	table.resizer.dragging = 3
	table.resizer._on_released(table.click_action) # the end of a corner drag
	print("SMOKE letting go of a corner drag remembers the slab's size in the settings: ", settings.table_slab_size.is_equal_approx(Vector2(0.9, 0.55)))
	var again = AppSettings.new()
	again.load_from_disk()
	print("SMOKE ...it is in the settings file for the next launch: ", again.table_slab_size.is_equal_approx(Vector2(0.9, 0.55)))
	table.set_slab_size(Vector2(0.6, 0.4))
	table.apply_settings(settings)
	print("SMOKE ...and apply_settings (main does it at start) puts the table at that size, clamped to what a drag allows: ", table.slab_size.is_equal_approx(Vector2(0.9, 0.55)) and is_equal_approx(table.tools_size.x, 0.9))
	settings.table_slab_size = Vector2(9.0, 9.0)
	table.apply_settings(settings)
	print("SMOKE ...a saved size out of range is clamped to the limits: ", table.slab_size.is_equal_approx(table.resizer.max_size))
	settings.set_table_slab_size(saved_before)
	table.set_slab_size(Vector2(0.6, 0.4))

	# --- the biggest zoom is a setting
	print("SMOKE the everyday zoom limit is 3x by default and a sketch allows 8x: ", is_equal_approx(table.max_user_scale(), 3.0))
	table.max_scale_setting = 5.0
	print("SMOKE ...set to 5x it is 5x (and a sketch still allows 8x, or more if the setting is higher): ", is_equal_approx(table.max_user_scale(), 5.0))
	var zoomed := TablePose.two_hand(Vector3(-0.1, 0, 0), Vector3(0.1, 0, 0), Vector3(-5, 0, 0), Vector3(5, 0, 0), Vector3.ZERO, Basis.IDENTITY, 1.0, true, table.max_user_scale())
	print("SMOKE ...two hands spread far stop at the limit: ", is_equal_approx(zoomed["scale"], 5.0))
	table.max_scale_setting = 3.0
	settings.set_table_max_scale(3.0)
	var reloaded = AppSettings.new()
	reloaded.load_from_disk()
	print("SMOKE the zoom limit and the send-back choice persist (clamped to 1.5-8x): ", is_equal_approx(reloaded.table_max_scale, 3.0) and reloaded.table_keep_turn == settings.table_keep_turn)

	# --- the page on the tablet
	var tablet = l.get_node("WristTablet")
	var page: Control = tablet.registry.tool_def("table").build.call()
	var choices: Array = page.find_children("*", "Button", true, false).map(func(b): return (b as Button).text)
	print("SMOKE the tablet's Table page offers the send-back choice and the zoom limit: ", choices.has("Original turn") and choices.has("As turned") and choices.has("2x") and choices.has("8x"))
	for b in page.find_children("*", "Button", true, false):
		if (b as Button).text == "As turned":
			(b as Button).pressed.emit()
	print("SMOKE ...choosing As turned sets it on the table and in the settings: ", table.keep_turn_on_return and settings.table_keep_turn)
	for b in page.find_children("*", "Button", true, false):
		if (b as Button).text == "Original turn":
			(b as Button).pressed.emit()
	print("SMOKE ...and back: ", not table.keep_turn_on_return and not settings.table_keep_turn)

	# --- sending a part back: original turn, or the turn it was given
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(60, 30, 20)
	mesh.mesh = box
	main.assembly_root.add_child(mesh)
	mesh.position = Vector3(0, 0, 0)
	mesh.add_to_group("grabbable_parts")
	mesh.set_meta("owner_part_id", "P1")
	mesh.set_meta("occurrence_id", "occ_a")
	await frames(2)
	var original_basis: Basis = mesh.global_transform.basis.orthonormalized()
	table.seat(mesh)
	await frames(2)
	var turned := Basis(Vector3.UP, deg_to_rad(70.0)) * Basis(Vector3.RIGHT, deg_to_rad(25.0))
	table.apply_pose(Vector3(0.1, table.hover_height, 0.0), table._seat_pivot_basis * turned, 1.0)
	var console_basis: Basis = table.global_transform.basis.orthonormalized()
	var wanted_with_turn: Basis = table.pivot.basis.orthonormalized() # the part's orientation as the table shows it (the pivot is in the console frame)
	var world_target: Vector3 = table.to_global(Vector3(0.0, 0.2, 0.9)) # beyond the slab's front edge
	table.send_to_arena(world_target)
	await frames(2)
	print("SMOKE sent back with the default, the part is in its ORIGINAL orientation (not the turn it had): ", mesh.global_transform.basis.orthonormalized().is_equal_approx(original_basis) and table.seated == null)
	table.seat(mesh)
	await frames(2)
	table.keep_turn_on_return = true
	table.apply_pose(Vector3(0.1, table.hover_height, 0.0), table._seat_pivot_basis * turned, 1.0)
	table.send_to_arena(world_target)
	await frames(2)
	var in_console: Basis = console_basis.inverse() * mesh.global_transform.basis.orthonormalized()
	print("SMOKE with 'As turned' it comes back looking the way it did on the table (same orientation relative to the console): ", in_console.is_equal_approx(wanted_with_turn) and not mesh.global_transform.basis.orthonormalized().is_equal_approx(original_basis))
	table.keep_turn_on_return = false

	# --- one hand turns it with the wrist behind the modifier
	table.seat(mesh)
	await frames(2)
	table.apply_pose(Vector3(0.0, table.hover_height, 0.0), table._seat_pivot_basis, 1.0)
	l.global_transform = Transform3D(console_basis, table.to_global(Vector3(-0.05, table.hover_height, 0.0)))
	await physics_frame
	l.button_pressed.emit("grip_click")
	await frames(2)
	var held: bool = table.manip.is_gripping()
	var basis_before: Basis = table.pivot.basis.orthonormalized()
	var offset_before: Vector3 = table.pivot.position - table.to_local(l.global_position)
	var twist := Basis(Vector3.UP, deg_to_rad(90.0))
	l.global_transform = Transform3D(twist * console_basis, l.global_position)
	await frames(2)
	print("SMOKE one hand gripping and twisting its wrist does NOT turn the part without the modifier: ", held and table.pivot.basis.orthonormalized().is_equal_approx(basis_before))
	table.manip.turn_modifier = func(_hand) -> bool: return true
	l.global_transform = Transform3D(console_basis, l.global_position) # back, so the next twist is measured from a known pose
	await frames(2)
	basis_before = table.pivot.basis.orthonormalized()
	offset_before = table.pivot.position - table.to_local(l.global_position)
	l.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(90.0)) * console_basis, l.global_position)
	await frames(2)
	var rot_world := Basis(Vector3.UP, deg_to_rad(90.0))
	var rot_console: Basis = (console_basis.inverse() * rot_world * console_basis).orthonormalized()
	print("SMOKE ...with the modifier held, a 90 degree wrist twist turns the part 90 degrees (about the hand): ", table.pivot.basis.orthonormalized().is_equal_approx((rot_console * basis_before).orthonormalized()))
	var offset_after: Vector3 = table.pivot.position - table.to_local(l.global_position)
	print("SMOKE ...and the part swings round the hand as if held in the fist (its offset from the hand turns too): ", offset_after.is_equal_approx(rot_console * offset_before))
	table.manip.turn_modifier = Callable()
	print("SMOKE the real modifier is the LEFT stick press (never the right one, which opens the world-scale pad): ", not table.manip.turn_held(r) and not table.manip.turn_held(l))
	l.button_released.emit("grip_click")
	await frames(2)
	table.close()
	quit()
