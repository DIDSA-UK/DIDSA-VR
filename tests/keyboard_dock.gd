extends SceneTree
## V-8 (docs/vr-feedback-2026-11-11-plan.md): the number pad no longer opens behind the sketch sheet. At the design table every typed value (a dimension, a feature
## value, an option, a rename: all through `table.open_keyboard`) opens DOCKED at `table.keyboard_dock()`, a pose in the console's frame below the tool deck's
## lower edge, on the user's side of the sheet's hinge. A keyboard the user carried elsewhere at the table is remembered in the console's frame, so it comes back
## to the same place relative to the console after the console is recalled. For every placement, a ray from the eyes to the keyboard's middle that crosses a
## panel (or the sheet) pulls the keyboard towards the eyes until clear, never closer than 0.3 m. With no context the keyboard still opens in front of you.
## NOT checked: reach and readability of the dock on a headset, how it looks next to the deck, the optional "typed value shows on the dimension" (not built).
## Run: "$GODOT" --headless --path . --script res://tests/keyboard_dock.gd  (see tests/README.md)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func plane() -> Dictionary:
	return {"origin": Vector3.ZERO, "n": Vector3(0, 0, 1), "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0)}


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var camera: XRCamera3D = main.get_node("XROrigin3D/XRCamera3D")
	camera.position = Vector3(0, 1.6, 0)
	table = main.design_table
	var kb = main._keyboard
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(60, 30, 20)
	mesh.mesh = box
	main.assembly_root.add_child(mesh)
	mesh.add_to_group("grabbable_parts")
	mesh.set_meta("owner_part_id", "P1")
	mesh.set_meta("occurrence_id", "occ_a")
	table.open()
	await frames(3)
	table.seat(mesh)
	await frames(3)
	table.orient_to_plane(plane())
	await frames(3)
	check("a sketch is open on the table (the sheet is up)", table.window_anchor_normal != Vector3.ZERO)

	# --- the dock: opens at keyboard_dock() (to 1 cm), on the camera's side of the sheet, below the deck's lower edge
	table.open_keyboard("1.00", func(_t: String) -> void: pass, {"title": "Dimension (mm)"})
	var expected: Transform3D = table.global_transform * table.keyboard_dock() * Transform3D(Basis.IDENTITY, Vector3(0.0, -kb.panel_size.y * 0.5, 0.0))
	check("the keypad opens at the dock (within 1 cm)", kb.is_open() and kb.global_position.distance_to(expected.origin) < 0.01)
	var sheet_n: Vector3 = (table.global_transform.basis * table.window_anchor_normal).normalized()
	var sheet_c: Vector3 = table.to_global(table.window_anchor)
	check("...on the camera's side of the sheet's plane (not behind it)", (kb.global_position - sheet_c).dot(sheet_n) * (camera.global_position - sheet_c).dot(sheet_n) > 0.0)
	var deck_bottom: Vector3 = table.to_global(Vector3(0.0, -0.1, table.slab_size.y * 0.5 + table.deck_gap + 0.15))
	check("...in front of the tool deck's lower edge, towards you", (kb.global_position - deck_bottom).dot(table.global_transform.basis.z) > 0.0)
	check("...and its front face leans back towards your eyes (normal tilted up, not down)", kb.global_transform.basis.z.y > 0.0 and kb.global_transform.basis.z.dot(camera.global_position - kb.global_position) > 0.0)

	# --- the same place for a full keyboard (a rename): it hangs from the same top edge
	table.open_keyboard("Part", func(_t: String) -> void: pass, {"mode": "full", "title": "Part name"})
	var top_full: Vector3 = kb.global_transform * Vector3(0.0, kb.panel_size.y * 0.5, 0.0)
	var top_dock: Vector3 = (table.global_transform * table.keyboard_dock()).origin
	check("a full keyboard hangs from the same top-edge point (within 1 cm)", top_full.distance_to(top_dock) < 0.01)
	kb.close()

	# --- carried elsewhere at the table: remembered in the console's frame; recalled console -> same pose relative to it
	table.open_keyboard("1.00", func(_t: String) -> void: pass, {})
	kb.global_position += table.global_transform.basis.x * 0.15
	kb._on_handle_dropped(null)
	var local_before: Transform3D = table.global_transform.affine_inverse() * kb.global_transform
	kb.close()
	table.global_transform = Transform3D(table.global_transform.basis.rotated(Vector3.UP, 0.4), table.global_position + Vector3(0.3, 0.0, 0.2))
	table.open_keyboard("2.00", func(_t: String) -> void: pass, {})
	var local_after: Transform3D = table.global_transform.affine_inverse() * kb.global_transform
	check("a carried keyboard reopens at the same pose in the console's frame after the console moved", local_after.origin.distance_to(local_before.origin) < 0.001 and local_after.basis.is_equal_approx(local_before.basis))
	kb.close()

	# --- no context: in front of the eyes as before (never the dock)
	main.open_keyboard_for("1", func(_t: String) -> void: pass)
	var ahead: Vector3 = camera.global_position + Vector3(0, -0.1, -0.6)
	check("with no context the pad opens 0.6 m in front of the eyes, 0.1 m below, as before", kb.global_position.distance_to(ahead) < 0.02)
	kb.close()

	# --- the clear-view check: a panel in the way pulls it towards the eyes (and stays 0.3 m+ away)
	var ray_to: Vector3 = (camera.global_position + Vector3(0, -0.1, -0.6))
	var wall := {"xf": Transform3D(Basis.IDENTITY, camera.global_position.lerp(ray_to, 0.5)), "size": Vector2(2.0, 2.0)}
	main.open_keyboard_for("1", func(_t: String) -> void: pass, {"obstacles": func() -> Array: return [wall]})
	var d_eye: float = kb.global_position.distance_to(camera.global_position)
	check("a quad between the eyes and the pad brings it closer, in front of the quad (and not under 0.3 m)", d_eye < 0.6 - 0.05 and d_eye >= 0.3 - 0.001 and kb.global_position.z > wall["xf"].origin.z)
	var far_wall := {"xf": Transform3D(Basis.IDENTITY, camera.global_position + Vector3(0, 0, -2.0)), "size": Vector2(2.0, 2.0)}
	main.open_keyboard_for("1", func(_t: String) -> void: pass, {"obstacles": func() -> Array: return [far_wall]})
	check("a quad BEHIND the pad changes nothing", kb.global_position.distance_to(ahead) < 0.02)
	kb.close()
	check("ray vs quad: a hit, a miss to the side, a miss behind the origin",
		kb._ray_quad(Vector3.ZERO, Vector3.FORWARD, Transform3D(Basis.IDENTITY, Vector3(0, 0, -1)), Vector2(1, 1)) > 0.99
		and kb._ray_quad(Vector3.ZERO, Vector3.FORWARD, Transform3D(Basis.IDENTITY, Vector3(3, 0, -1)), Vector2(1, 1)) < 0.0
		and kb._ray_quad(Vector3.ZERO, Vector3.BACK, Transform3D(Basis.IDENTITY, Vector3(0, 0, -1)), Vector2(1, 1)) < 0.0)

	# --- the table's own obstacle: the sheet's quad while a sketch is open (a stand-in session: the real one needs a backend)
	check("with no sketch open the table offers no obstacle", table.keyboard_obstacles().is_empty())
	table.editor.session = RefCounted.new()
	var quads: Array = table.keyboard_obstacles()
	var q: Transform3D = quads[0]["xf"] if quads.size() == 1 else Transform3D.IDENTITY
	check("while a sketch is open it offers the sheet's quad: sized as the sheet window, centred on the anchor, facing the sketch plane's normal", quads.size() == 1 and (quads[0]["size"] as Vector2).is_equal_approx(table.sheet_window_m) and q.origin.distance_to(table.to_global(table.window_anchor)) < 0.001 and q.basis.z.dot(table.global_transform.basis * table.window_anchor_normal) > 0.999)
	# a pad that would land BEHIND that sheet is pulled out in front of it
	var behind: Vector3 = sheet_c - sheet_n * 0.1 * signf((camera.global_position - sheet_c).dot(sheet_n))
	var obstructed: float = kb._ray_quad(camera.global_position, (behind - camera.global_position).normalized(), q, table.sheet_window_m)
	check("a ray from the eyes to a spot just behind the sheet meets the sheet first", obstructed > 0.0 and obstructed < camera.global_position.distance_to(behind))
	table.editor.session = null
	quit(0)
