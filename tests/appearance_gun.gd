extends SceneTree
## The Appearance tool's gun in the real scene (main.tscn, no backend; appearance_tool.gd talks to tests/fake_appearance_api.gd):
## with the tool on, a CLICK (trigger down and up inside 0.45 s) paints the body under the laser on release; a HOLD opens the
## paint breadcrumb at the hit point (title "Painting", Body lit, a swatch and "set here" per row); swinging the laser over a row
## previews it live and letting go on it paints it (one undo step); letting go off the panel paints nothing and puts every look
## back. Headless can't squeeze a real trigger, so the press / release handlers are called and the press time is moved back to
## stand in for the hold (tests/README.md).
## Run: "$GODOT" --headless --path . --script res://tests/appearance_gun.gd

const FakeApi := preload("res://tests/fake_appearance_api.gd")
const Breadcrumb := preload("res://scripts/group_breadcrumb.gd")
const Look := preload("res://scripts/appearance/appearance_look.gd")

var failures := 0
var main
var r: XRController3D


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _box(label: String, occ: String, path: String, names: Array, at: Vector3) -> MeshInstance3D:
	## A 10 cm box, two bodies (faces 0-2 "<x>1", faces 3-5 "<x>2"), tagged like a backend part.
	var n := MeshInstance3D.new()
	n.name = label
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.1, 0.1, 0.1)
	n.mesh = mesh
	var faces: Array = []
	var bodies: Array = []
	for t in mesh.get_faces().size() / 3:
		var f := t / 2
		faces.append(f % 3)
		bodies.append("%s%d" % [label.to_lower().left(1), 1 if f < 3 else 2])
	n.set_meta("face_ids", faces)
	n.set_meta("body_ids", bodies)
	n.set_meta("owner_part_id", "F" if path.contains("/") else "R")
	n.set_meta("occurrence_id", occ)
	n.set_meta("instance_path", path)
	n.set_meta("group_root", "R")
	n.set_meta("group_path", Array(path.split("/")) if path != "" else [])
	n.set_meta("group_names", names)
	n.add_to_group("grabbable_parts")
	main.assembly_root.add_child(n)
	n.global_position = at
	n.create_trimesh_collision()
	return n


func _aim_at(point: Vector3) -> void:
	var from := point + Vector3(0.0, 0.0, 0.6)
	r.global_transform = Transform3D(Basis.looking_at(point - from, Vector3.UP), from)


func _press() -> void:
	r._on_button_pressed("trigger_click")


func _release() -> void:
	r._select_down = false
	await r._finish_paint()


func _row_point(crumb, row: int) -> Vector3:
	## The middle of a row of the open breadcrumb (it has a title row above its rows).
	var y := Breadcrumb.MARGIN_M + Breadcrumb.ROW_H * (row + 1) + Breadcrumb.ROW_H * 0.5
	return crumb.global_transform * Vector3(Breadcrumb.WIDTH * 0.5, -y, 0.0)


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	for i in 3:
		await process_frame
	r = main.get_node("XROrigin3D/RightController")
	var tool = main._appearance_tool
	var api := FakeApi.new()
	api.parts = {
		"R": {"name": "Rig", "occurrences": [FakeApi.row("frame", "F")]},
		"F": {"name": "Frame", "occurrences": [FakeApi.row("barA", "A"), FakeApi.row("barB", "A")]},
		"A": {"name": "Bar"},
	}
	tool.configure(api)
	tool.world_root = "R"
	main.assembly_root.transform = Transform3D.IDENTITY
	var bar_a := _box("BarA", "barA", "frame/barA", ["Frame", "Bar"], Vector3(0.0, 1.2, -1.0))
	var bar_b := _box("BarB", "barB", "frame/barB", ["Frame", "Bar"], Vector3(0.4, 1.2, -1.0))
	await _frames(2)
	await tool.ensure_loaded("R")
	main._tablet.manager.activate("paint")
	main._tablet.pages.set_paint_colour("#E63946")
	_check(r.paint_active, "switching the Appearance tool on arms the right trigger")

	# --- a click paints the body under the laser, on release (nothing on press)
	_aim_at(bar_a.global_position + Vector3(0.0, 0.0, 0.05)) # the box's +z face: a "b2" triangle
	await _frames(2)
	_press()
	await _frames(1)
	_check(api.puts().is_empty(), "the press paints nothing yet (a press may turn into a hold)")
	await _release()
	var put: Dictionary = api.puts().back() if not api.puts().is_empty() else {}
	_check(api.puts().size() == 1 and put["body"].get("path") == "frame/barA" and put["body"].has("body_id") and not put["body"].has("face") and put["body"]["appearance"] == {"colour": "#E63946"},
		"a click paints the BODY under the laser on release (%s)" % str(put.get("body")))
	_check(bar_a.mesh.get_surface_count() == 2 and bar_b.material_override == Look.plain() or bar_b.material_override == null, "...only that body of that bar changes on screen")
	_check(main.command_stack.undo_label() == "paint Body", "...one undo step")

	# --- a hold opens the breadcrumb at the hit point, Body lit, with the title and the rows
	_aim_at(bar_b.global_position + Vector3(0.0, 0.0, 0.05))
	await _frames(2)
	_press()
	r._paint_press["ms"] = int(r._paint_press["ms"]) - 600 # stands in for holding the trigger 0.45 s
	await _frames(1)
	var crumb = r._paint_crumb
	_check(crumb != null and crumb.title == "Painting", "holding the trigger opens the paint breadcrumb, titled Painting")
	var labels: Array = crumb.labels if crumb != null else []
	_check(labels.size() == 6 and labels[0] == "Face" and labels[1] == "Body" and str(labels[3]).begins_with("Every Bar (2)") and str(labels[4]).begins_with("Frame") and labels[5] == "Whole assembly",
		"its rows: Face, Body, Part, Every Bar (2), the Frame, Whole assembly (%s)" % str(labels))
	_check(crumb != null and crumb.hovered == 1, "...Body is lit when it opens (what a click would have done)")
	_check(crumb != null and crumb.notes.size() == 6 and crumb.notes.all(func(n) -> bool: return n == ""), "...nothing is set here yet on bar B's rows")

	# --- hovering a row previews it live; letting go on it paints it
	var frame_row := 4
	_aim_at(_row_point(crumb, frame_row))
	await _frames(2)
	_check(r._paint_hover == frame_row and crumb.hovered == frame_row, "pointing at the Frame row lights it")
	var b_mat := bar_b.material_override as StandardMaterial3D
	_check(b_mat != null and b_mat.albedo_color.is_equal_approx(Color.html("#E63946")) and api.puts().size() == 1, "...and previews it: bar B shows the colour, nothing is sent")
	_check(not r._paint_cues.is_empty(), "...with brackets round what it would paint")
	await _release()
	_check(api.puts().size() == 2 and api.puts().back()["body"] == {"path": "frame", "appearance": {"colour": "#E63946"}}, "letting go on the Frame row paints the frame (one PUT)")
	_check(r._paint_crumb == null and r._paint_cues.is_empty(), "...and the breadcrumb closes")

	# --- a hold released off the panel paints nothing and puts every look back
	main._tablet.pages.set_paint_colour("#3498DB")
	_aim_at(bar_b.global_position + Vector3(0.0, 0.0, 0.05))
	await _frames(2)
	_press()
	r._paint_press["ms"] = int(r._paint_press["ms"]) - 600
	await _frames(1)
	crumb = r._paint_crumb
	_aim_at(_row_point(crumb, 2)) # the Part row: bar B previews blue (Whole assembly wouldn't: the frame's red is more specific)
	await _frames(2)
	var previewed := (bar_b.material_override as StandardMaterial3D).albedo_color.is_equal_approx(Color.html("#3498DB"))
	_aim_at(crumb.global_position + Vector3(2.0, 2.0, 0.0)) # well off the panel
	await _frames(2)
	await _release()
	var back := (bar_b.material_override as StandardMaterial3D).albedo_color.is_equal_approx(Color.html("#E63946"))
	_check(previewed and back and api.puts().size() == 2, "letting go off the panel paints nothing, and the preview is undone (previewed %s, back %s, %d puts)" % [previewed, back, api.puts().size()])
	_check(str(main.status_text).begins_with("Nothing painted"), "...and says so")

	main._tablet.manager.deactivate()
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
