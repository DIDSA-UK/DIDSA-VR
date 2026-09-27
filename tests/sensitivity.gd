extends SceneTree
## One-hand drag gain by model size (1:1 to 0.6 m radius, capped x15) and A/B nudge speed by distance from the hand (0.6 x distance per second, clamped 0.03-8 m/s).
## Run: "$GODOT" --headless --path . --script res://tests/sensitivity.gd  (see tests/README.md)
func box(parent: Node, size: Vector3, pos: Vector3) -> MeshInstance3D:
	var m := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = size; m.mesh = bm
	parent.add_child(m); m.position = pos; m.add_to_group("grabbable_parts"); return m

func _initialize() -> void:
	var world := Node3D.new(); root.add_child(world)
	var origin := XROrigin3D.new(); world.add_child(origin)
	var l := XRController3D.new(); l.tracker = &"left_hand"; l.set_script(load("res://scripts/controller.gd")); origin.add_child(l)
	var r := XRController3D.new(); r.tracker = &"right_hand"; r.set_script(load("res://scripts/controller.gd")); origin.add_child(r)
	await process_frame
	var th = load("res://scripts/two_hand_model.gd").new(); world.add_child(th)

	print("SMOKE --- one-hand drag gain by model size (half its bounding diagonal)")
	for diag_half in [0.3, 0.6, 1.5, 3.0, 6.0, 20.0]:
		var model := Node3D.new(); world.add_child(model)
		var side: float = diag_half * 2.0 / sqrt(3.0)          # a cube whose half-diagonal is diag_half
		box(model, Vector3(side, side, side), Vector3(0, 1, -2))
		th.setup(model, l, r, 1.0)
		th._mode = 0
		var g: float = th.one_hand_drag_gain()
		# real code path: baseline then move the hand 10 cm forward
		var before := model.global_position
		th._update_one_hand(l, Vector3(0, 1, 0))
		th._update_one_hand(l, Vector3(0, 1, -0.10))
		print("SMOKE model radius %5.1f m -> gain x%5.2f ; hand moved 10 cm -> model moved %5.1f cm" % [diag_half, g, (model.global_position - before).length() * 100.0])
		for c in model.get_children(): c.remove_from_group("grabbable_parts")
		model.queue_free()

	print("SMOKE --- two-hand drag gain by model size (same formula as one-hand; rotation/scale stay ungained)")
	for diag_half in [0.3, 6.0, 20.0]:
		var model := Node3D.new(); world.add_child(model)
		var side: float = diag_half * 2.0 / sqrt(3.0)
		box(model, Vector3(side, side, side), Vector3(0, 1, -2))
		th.setup(model, l, r, 1.0)
		th._mode = 0
		var mid := Vector3(0, 1, 0)
		l.position = mid + Vector3(-0.3, 0, 0); r.position = mid + Vector3(0.3, 0, 0)
		th._update_two_hand(l.position, r.position) # first frame: baselines, measures gain
		var g: float = th.one_hand_drag_gain()
		var before: Vector3 = model.global_position
		l.position += Vector3(0, 0, -0.10); r.position += Vector3(0, 0, -0.10) # both hands drag 10 cm the same way: pure translation
		th._update_two_hand(l.position, r.position)
		var moved := (model.global_position - before).length()
		print("SMOKE model radius %5.1f m -> gain x%5.2f ; both hands moved 10 cm -> model moved %5.1f cm (expect %5.1f)" % [diag_half, g, moved * 100.0, 10.0 * g])
		for c in model.get_children(): c.remove_from_group("grabbable_parts")
		model.queue_free()

	# a pure rotation (hands swing, spread unchanged) must turn the model by the raw angle regardless of size — never gain-amplified
	for diag_half in [0.3, 20.0]:
		var model := Node3D.new(); world.add_child(model)
		var side: float = diag_half * 2.0 / sqrt(3.0)
		box(model, Vector3(side, side, side), Vector3(0, 1, -2))
		th.setup(model, l, r, 1.0)
		th._mode = 0
		var mid := Vector3(0, 1, 0)
		l.position = mid + Vector3(-0.3, 0, 0); r.position = mid + Vector3(0.3, 0, 0)
		th._update_two_hand(l.position, r.position)
		var half := 0.3
		var angle := deg_to_rad(30.0)
		l.position = mid + Vector3(-half * cos(angle), 0, -half * sin(angle))
		r.position = mid + Vector3(half * cos(angle), 0, half * sin(angle))
		th._update_two_hand(l.position, r.position)
		var turned := rad_to_deg(model.global_transform.basis.get_rotation_quaternion().get_axis().y * model.global_transform.basis.get_rotation_quaternion().get_angle())
		print("SMOKE model radius %5.1f m -> 30 deg hand swing turns it %5.1f deg (ungained, same for any size)" % [diag_half, turned])
		for c in model.get_children(): c.remove_from_group("grabbable_parts")
		model.queue_free()

	print("SMOKE --- A/B nudge speed by distance from the hand (old fixed speed: 0.60 m/s)")
	l.position = Vector3.ZERO
	var part := box(world, Vector3(0.1, 0.1, 0.1), Vector3.ZERO)
	for d in [0.05, 0.15, 0.3, 1.0, 3.0, 5.0, 10.0, 30.0]:
		part.global_position = Vector3(0, 0, -d)
		print("SMOKE part %5.2f m away -> %5.2f m/s" % [d, l.nudge_speed_for(part)])
	quit()
