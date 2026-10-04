extends SceneTree
## Stale mates after an edit (scripts/design_table/dirty_mates.gd, enforce_button.gd; mates_tool.gd's dirty check): editing a part
## flags EVERY arena instance of it with a warning badge; a flagged part is no longer steered by (or an anchor for) its mates;
## putting a flagged part down — or handing it back when the table closes — shows one "Enforce mates" button above it, facing you,
## following it and parked while it is carried; pressing it with the real laser re-solves, and the flags go only when every
## mate was met (a failed try keeps them and says why); reloading the model clears the button.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_mates.gd  (see tests/README.md)

const DirtyMates := preload("res://scripts/design_table/dirty_mates.gd")
const MateHealth := preload("res://scripts/design_table/mate_health.gd")
const Fake := preload("res://tests/helpers/fake_cad.gd")

var main
var table
var l: XRController3D
var r: XRController3D
var cam: XRCamera3D


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func carry_to(node: Node3D, world_point: Vector3) -> void:
	l.global_position = node.global_position
	await physics_frame
	l._try_grab()
	l.global_position = world_point
	await frames(2)


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	cam = origin.get_node("XRCamera3D")
	cam.position = Vector3(0, 1.6, 0)
	l = origin.get_node("LeftController")
	r = origin.get_node("RightController")
	l.set_steadiness(0)
	l.position = Vector3(-0.8, 1.0, -0.2)
	r.position = Vector3(1.0, 1.5, 1.0)
	table = main.design_table
	var bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb")
	main._show_model(bytes, "", 0.001)
	await frames(2)
	var box: MeshInstance3D = null
	var cyl: MeshInstance3D = null
	for p in get_nodes_in_group("grabbable_parts"):
		p.set_meta("owner_part_id", "ASM")
		if p.get_meta("occurrence_id", "") == "occ_box":
			box = p
		else:
			cyl = p
	var mates = main._mates_tool

	# --- flags and badges
	print("SMOKE nothing is flagged to start with: ", DirtyMates.dirty_nodes(self).is_empty() and not table.enforce_button.is_showing())
	table.notify_edited("PART_BOX", [box, cyl])
	print("SMOKE an edit flags every arena instance of the part (they share one definition): ", DirtyMates.is_dirty(box) and DirtyMates.is_dirty(cyl))
	var badge := box.get_node_or_null("DirtyBadge") as Sprite3D
	print("SMOKE ...each with a warning badge that faces you and shows through the part: ", badge != null and badge.billboard == BaseMaterial3D.BILLBOARD_ENABLED and badge.no_depth_test)
	var world_width := badge.texture.get_width() * badge.pixel_size * box.global_transform.basis.get_scale().x
	print("SMOKE ...about 4.5 cm across whatever the model's scale: ", absf(world_width - 0.045) < 0.002)
	table.notify_edited("PART_BOX", [box])
	print("SMOKE flagging twice doesn't pile up badges: ", box.get_children().filter(func(c): return c.name == "DirtyBadge").size() == 1)

	# --- a flagged part isn't steered by its mates
	mates.backend_url = "http://x"
	mates.api_key = "k"
	mates._current_owner_part_id = "ASM"
	mates._mated_ids = {"occ_box": true, "occ_cyl": true}
	mates.occurrences = {"occ_box": {"fixed": true}, "occ_cyl": {"fixed": false}}
	mates.relaxed = false
	DirtyMates.clear(box)
	DirtyMates.clear(cyl)
	print("SMOKE (setup) with clean parts the mates DO steer: ", mates.is_locked(box) and mates.is_constrained(cyl))
	DirtyMates.mark(box)
	DirtyMates.mark(cyl)
	print("SMOKE a flagged part is not steered by its mates: ", not mates.is_constrained(cyl))
	print("SMOKE ...and a flagged anchor doesn't lock: ", not mates.is_locked(box))
	DirtyMates.clear(cyl)
	print("SMOKE clearing the flag gives the mates back, and removes the badge: ", mates.is_constrained(cyl) and cyl.get_node_or_null("DirtyBadge") == null and not DirtyMates.is_dirty(cyl))
	mates.backend_url = ""
	mates.api_key = ""

	# --- the button appears where a flagged part is put down
	var spot := Vector3(-0.8, 1.2, -0.6)
	await carry_to(box, spot)
	print("SMOKE while it is carried there's no button yet: ", not table.enforce_button.is_showing())
	l._try_release()
	await frames(3)
	var button = table.enforce_button
	print("SMOKE putting the flagged part down shows the Enforce mates button for it: ", button.is_showing() and button.target == box and button.visible)
	var part_centre: Vector3 = box.global_transform * box.get_aabb().get_center()
	print("SMOKE ...floating just above the part: ", button.global_position.y > part_centre.y + 0.05 and Vector2(button.global_position.x, button.global_position.z).distance_to(Vector2(part_centre.x, part_centre.z)) < 0.05)
	var to_camera: Vector3 = (cam.global_position - button.global_position).normalized()
	print("SMOKE ...facing you: ", button.global_transform.basis.z.dot(Vector3(to_camera.x, 0, to_camera.z).normalized()) > 0.95)
	print("SMOKE ...in the app's styling (the accent button, a hint under it): ", button.button().theme_type_variation == &"ButtonAccent" and button.message().contains("mates need redoing"))
	await carry_to(box, Vector3(-0.8, 1.2, -0.3))
	await frames(2)
	print("SMOKE the button is parked while the part is in a hand: ", not button.visible and button.is_showing())
	l._try_release()
	await frames(3)
	var moved: Vector3 = box.global_transform * box.get_aabb().get_center()
	print("SMOKE ...and comes back over it where it was put down: ", button.visible and absf(button.global_position.z - moved.z) < 0.05)
	main.command_stack.clear()

	# --- a clean part gets no button
	DirtyMates.clear(cyl)
	await carry_to(cyl, Vector3(-0.2, 1.2, -0.7))
	button.hide_button()
	l._try_release()
	await frames(2)
	print("SMOKE a part with up-to-date mates gets none: ", not button.is_showing())

	# --- pressing it with the real laser
	button.show_for(box)
	await frames(2)
	var panel_size: Vector2 = button.panel_size
	var b: Button = button.button()
	var c := b.global_position + b.size * 0.5
	var vp := Vector2(button._viewport.size)
	var point: Vector3 = button.global_transform * Vector3((c.x / vp.x - 0.5) * panel_size.x, (0.5 - c.y / vp.y) * panel_size.y, 0.0)
	var normal: Vector3 = button.global_transform.basis.z.normalized()
	r.global_transform = Transform3D(Basis.looking_at(-normal, Vector3.UP), point + normal * 0.35)
	await frames(3)
	print("SMOKE aiming at the button takes the laser (so a trigger can't also select a part): ", button.surface.hovering and r.get_meta("ui_hover", false))
	var pressed: Array = []
	button.pressed_enforce.connect(func() -> void: pressed.append(true))
	button.surface.settle_seconds = 0.0
	r.button_pressed.emit("trigger_click")
	await frames(2)
	r.button_released.emit("trigger_click")
	await frames(2)
	print("SMOKE a trigger pull on it presses it: ", pressed.size() == 1)
	print("SMOKE ...with no assembly loaded there is nothing to enforce, and it says so without clearing anything: ", button.message().contains("no assembly") and DirtyMates.is_dirty(box))
	main._resolved_part_id = "ASM" # an assembly is loaded now (there is no backend, so there are no mates to solve)
	button.show_for(box)
	await frames(2)
	r.button_pressed.emit("trigger_click")
	await frames(2)
	r.button_released.emit("trigger_click")
	await frames(2)
	var done: bool = false
	for i in 120:
		if not DirtyMates.is_dirty(box):
			done = true
			break
		await process_frame
	print("SMOKE ...which re-solves (nothing to solve here without a backend), clears every flag and puts the button away: ", done and DirtyMates.dirty_nodes(self).is_empty() and not button.is_showing())
	print("SMOKE ...and tells the table's status line: ", table.status().begins_with("Mates enforced"))

	# --- a failed try keeps the flags and says why
	DirtyMates.mark(box)
	button.show_for(box)
	mates.enforce_finished.emit({"ok": false, "solved": 0, "problems": ["the mates can't all be satisfied"]})
	print("SMOKE if a mate can't be met the flags stay and the button says why: ", DirtyMates.is_dirty(box) and button.is_showing() and button.message().contains("can't all be satisfied") and not button.button().disabled)

	# --- a mate whose face the edit changed is spotted, undone edits clear it, and Enforce turns it off instead of solving it
	button.hide_button()
	DirtyMates.clear_all(self)
	var body_id := str(box.get_meta("body_ids")[0])
	var face_id := int(box.get_meta("face_ids")[0])
	var mate_list := [{"id": "m1", "suppressed": false, "references": [
		{"occurrence_id": "occ_box", "subshape_ref": {"body_id": body_id, "shape_type": "face", "index": face_id}},
		{"occurrence_id": "occ_cyl", "subshape_ref": {"body_id": str(cyl.get_meta("body_ids")[0]), "shape_type": "face", "index": int(cyl.get_meta("face_ids")[0])}}]}]
	table.add_mate_baseline(MateHealth.capture([box, cyl], mate_list))
	table.add_mate_baseline(MateHealth.capture([box, cyl], mate_list))
	print("SMOKE the faces a mate names are remembered once, before the first edit (asking twice doesn't duplicate): ", table.mate_baseline.size() == 2)
	table.update_mate_drift()
	print("SMOKE with nothing changed no mate has drifted: ", table.mate_drift.is_empty())
	var original_mesh: Mesh = box.mesh
	var original_ids: Array = box.get_meta("face_ids")
	var original_bodies: Array = box.get_meta("body_ids")
	var original_topology: Dictionary = box.get_meta("topology")
	box.mesh = cyl.mesh # the edit renumbered the faces: face 0 of the part is now a face of something else entirely
	box.set_meta("face_ids", cyl.get_meta("face_ids"))
	box.set_meta("body_ids", cyl.get_meta("body_ids"))
	box.set_meta("topology", cyl.get_meta("topology"))
	table.update_mate_drift()
	print("SMOKE after the part's faces change under a mate, that mate is reported: ", table.mate_drift.keys() == ["m1"] and table.status().contains("1 mate"))
	box.mesh = original_mesh
	box.set_meta("face_ids", original_ids)
	box.set_meta("body_ids", original_bodies)
	box.set_meta("topology", original_topology)
	table.update_mate_drift()
	print("SMOKE ...and undoing the edit (the old faces back) clears the report: ", table.mate_drift.is_empty())
	box.mesh = cyl.mesh
	box.set_meta("face_ids", cyl.get_meta("face_ids"))
	box.set_meta("body_ids", cyl.get_meta("body_ids"))
	box.set_meta("topology", cyl.get_meta("topology"))
	table.update_mate_drift()
	var fake := Fake.new()
	var real_api = table.api
	table.api = fake
	main._resolved_part_id = "ASM"
	DirtyMates.mark(box)
	button.show_for(box)
	await table.enforce_mates()
	var patch_calls := fake.calls.filter(func(c): return c[0].begins_with("PATCH"))
	print("SMOKE Enforce turns a mate whose face changed OFF (suppressed) instead of solving it: ", patch_calls.size() == 1 and patch_calls[0][0] == "PATCH /document/parts/ASM/mates/m1" and patch_calls[0][1] == {"suppressed": true})
	print("SMOKE ...tells you on the button and keeps it up long enough to read: ", button.message().contains("turned off") and button.is_showing())
	print("SMOKE ...clears the stale flags and the record: ", DirtyMates.dirty_nodes(self).is_empty() and table.mate_drift.is_empty() and table.mate_baseline.is_empty())
	table.api = real_api
	button.hide_button()
	box.mesh = original_mesh
	box.set_meta("face_ids", original_ids)
	box.set_meta("body_ids", original_bodies)
	box.set_meta("topology", original_topology)

	# --- the offer to remake the turned-off mate on the face that is now the same one
	var unique_ids := {}
	for f in original_ids:
		unique_ids[int(f)] = true
	var face_count := unique_ids.size()
	var full_mates := [{"id": "m1", "type": "coincident", "value": null, "flipped": false, "allow_rotation": true, "suppressed": false, "references": [
		{"occurrence_id": "occ_box", "subshape_ref": {"body_id": body_id, "shape_type": "face", "index": face_id}, "plane_ref": null, "point_ref": null},
		{"occurrence_id": "occ_cyl", "subshape_ref": {"body_id": str(cyl.get_meta("body_ids")[0]), "shape_type": "face", "index": int(cyl.get_meta("face_ids")[0])}, "plane_ref": null, "point_ref": null}]}]
	mates.mates = full_mates
	table.mate_baseline.clear()
	table.add_mate_baseline(MateHealth.capture([box, cyl], full_mates))
	box.set_meta("face_ids", original_ids.map(func(f): return (int(f) + 1) % face_count)) # the edit renumbered every face of the box by one
	table.update_mate_drift()
	var fake2 := Fake.new()
	table.api = fake2
	DirtyMates.mark(box)
	button.show_for(box)
	await table.enforce_mates()
	var equivalent := (face_id + 1) % face_count
	print("SMOKE after Enforce a turned-off mate whose face still exists under a new number is OFFERED for remaking on the button: ", table.remake_plan.size() == 1 and button.button().text == "Remake 1 mate(s)" and button.message().contains("can be remade") and button.is_showing())
	fake2.calls.clear()
	await table.remake_mates()
	var posts := fake2.calls.filter(func(c): return c[0] == "POST /document/parts/ASM/mates")
	var refs: Array = posts[0][1]["references"] if posts.size() == 1 else []
	print("SMOKE pressing it makes the mate again on the equivalent face (same type, the box's face moved to its new number, the cylinder's untouched): ", posts.size() == 1 and posts[0][1]["type"] == "coincident" and refs[0]["subshape_ref"]["index"] == equivalent and refs[1]["subshape_ref"]["index"] == int(cyl.get_meta("face_ids")[0]))
	print("SMOKE ...deletes the old turned-off mate, tells you, and the offer is spent: ", not fake2.calls.filter(func(c): return c[0] == "DELETE /document/parts/ASM/mates/m1").is_empty() and table.status().contains("remade") and table.remake_plan.is_empty())
	mates.mates = []
	table.api = real_api
	button.hide_button()
	box.mesh = original_mesh
	box.set_meta("face_ids", original_ids)
	box.set_meta("body_ids", original_bodies)
	box.set_meta("topology", original_topology)
	table.mate_baseline.clear()
	DirtyMates.clear(box)

	# --- an edit on the table, then the table closing hands the part back with the button
	button.hide_button()
	DirtyMates.clear(box)
	r.position = Vector3(1.0, 1.5, 1.0)
	table.open()
	table.seat(box)
	await frames(2)
	table.notify_edited("PART_BOX", [box])
	table.close()
	await frames(2)
	print("SMOKE closing the table on an edited part hands it back with the button over it: ", box.visible and button.is_showing() and button.target == box and DirtyMates.is_dirty(box))

	# --- reloading clears the button
	main._show_model(bytes, "", 0.001)
	await frames(2)
	print("SMOKE reloading the model puts the button away: ", not button.is_showing())
	quit()
