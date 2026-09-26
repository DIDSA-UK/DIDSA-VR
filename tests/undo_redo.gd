extends SceneTree
## Undo/redo command stack (command_stack.gd): part moves (grip-drag and
## laser-select rotate/nudge), whole-model moves (drag, and the Scale tab's
## presets/Fit/Home), and — to prove the stack is generic enough for
## whatever a later tool pushes to it — a synthetic hide/show toggle, since
## shoot-to-hide/hide-all/isolate themselves are the next phase's work, not
## this one's.
## Run: "$GODOT" --headless --path . --script res://tests/undo_redo.gd  (see tests/README.md)

func box_part(parent: Node, size: Vector3, pos: Vector3) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = size
	m.mesh = bm
	parent.add_child(m)
	m.position = pos
	m.add_to_group("grabbable_parts")
	m.create_trimesh_collision()
	return m

func _initialize() -> void:
	var stack = load("res://scripts/command_stack.gd").new()

	var world := Node3D.new(); root.add_child(world)
	var origin := XROrigin3D.new(); world.add_child(origin)
	var l := XRController3D.new(); l.tracker = &"left_hand"; l.set_script(load("res://scripts/controller.gd")); origin.add_child(l)
	var r := XRController3D.new(); r.tracker = &"right_hand"; r.set_script(load("res://scripts/controller.gd")); origin.add_child(r)
	l.command_stack = stack
	r.command_stack = stack
	var assembly := Node3D.new(); assembly.add_to_group("assembly_root"); world.add_child(assembly)
	await process_frame

	# --- part move via grip-drag: grab, move, release -> undo puts it back
	var part := box_part(assembly, Vector3(0.1, 0.1, 0.1), Vector3(0, 1, -1))
	l.position = Vector3(0, 1, -1)
	await physics_frame; await physics_frame
	l._try_grab()
	l.position += Vector3(0.5, 0.2, 0)
	var moved_to := part.global_position
	l._try_release()
	print("SMOKE part moved by the grip-drag: ", part.global_position.is_equal_approx(moved_to))
	print("SMOKE can_undo after a real move: ", stack.can_undo())
	stack.undo()
	print("SMOKE undo puts the part back where it started: ", part.global_position.is_equal_approx(Vector3(0, 1, -1)))
	print("SMOKE can_redo after an undo: ", stack.can_redo())
	stack.redo()
	print("SMOKE redo re-applies the move: ", part.global_position.is_equal_approx(moved_to))

	# --- a drag that ends up back where it started pushes nothing
	stack.clear()
	l.position = part.global_position
	await physics_frame; await physics_frame
	l._try_grab()
	l._try_release() # no movement in between
	print("SMOKE a no-op grab+release pushes nothing new: ", not stack.can_undo())

	# --- whole-model move via one-hand drag
	stack.clear()
	var model := Node3D.new(); world.add_child(model)
	var th = load("res://scripts/two_hand_model.gd").new(); world.add_child(th)
	th.setup(model, l, r, 1.0, stack)
	var model_start := model.global_position
	l.position = Vector3(2, 1, 0) # away from any part, so grip grabs empty space (whole model)
	th._update_one_hand(l, l.position) # first frame: begins the gesture
	l.position += Vector3(0.3, 0, 0)
	th._update_one_hand(l, l.position) # second frame: actually drags it
	var model_moved_to := model.global_position
	th._end_gesture()
	print("SMOKE model moved by the one-hand drag: ", not model.global_position.is_equal_approx(model_start))
	stack.undo()
	print("SMOKE undo puts the model back: ", model.global_position.is_equal_approx(model_start))
	stack.redo()
	print("SMOKE redo re-applies the model move: ", model.global_position.is_equal_approx(model_moved_to))

	# --- Scale tab actions (preset/Fit/Home) push their own undo step too
	stack.clear()
	box_part(assembly, Vector3(0.2, 0.2, 0.2), Vector3(0, 1, -1)) # something for _model_bounds() to measure
	var scale_before := model.global_transform
	th.set_preset(2.0)
	print("SMOKE scale preset changed the model: ", not model.global_transform.is_equal_approx(scale_before))
	stack.undo()
	print("SMOKE undo reverts the scale preset: ", model.global_transform.is_equal_approx(scale_before))

	# --- generic enough for a later tool's hide/show: push a synthetic command
	stack.clear()
	var mesh := box_part(assembly, Vector3(0.1, 0.1, 0.1), Vector3(0, 1, -1))
	mesh.visible = true
	stack.push("hide part",
		func() -> void: mesh.visible = true,
		func() -> void: mesh.visible = false)
	mesh.visible = false
	stack.undo()
	print("SMOKE synthetic hide command: undo shows it again: ", mesh.visible == true)
	stack.redo()
	print("SMOKE synthetic hide command: redo hides it again: ", mesh.visible == false)
	quit()
