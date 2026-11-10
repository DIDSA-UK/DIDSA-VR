extends SceneTree
## Walking or snap-turning with the sticks while holding something carries it 1:1, as if carried (owner, 10 Nov 2026: a held part
## "moves much faster than me"). The steadiness filter and the whole-model drag gain apply to the hand's movement in the XR origin's
## frame only, so moving the origin (what locomotion.gd does) moves the held thing exactly as far as you.
## Run: "$GODOT" --headless --path . --script res://tests/carry_while_walking.gd  (see tests/README.md)

func _initialize() -> void:
	var world := Node3D.new(); root.add_child(world)
	var origin := XROrigin3D.new(); world.add_child(origin)
	var l := XRController3D.new(); l.tracker = &"left_hand"; l.set_script(load("res://scripts/controller.gd")); origin.add_child(l)
	var r := XRController3D.new(); r.tracker = &"right_hand"; r.set_script(load("res://scripts/controller.gd")); origin.add_child(r)
	var assembly := Node3D.new(); assembly.add_to_group("assembly_root"); world.add_child(assembly)
	await process_frame

	# A part gripped with steadiness at Strong (the most lag a world-space filter would give), then a 1.5 m/s walk for one second.
	var part := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = Vector3(0.1, 0.1, 0.1); part.mesh = bm
	assembly.add_child(part); part.add_to_group("grabbable_parts")
	part.position = Vector3(0, 1, -0.4)
	l.position = Vector3(0.03, 1, -0.4) # holding it off-centre, so the hand-to-part offset is not zero
	l.set_steadiness(3)
	await physics_frame
	l._try_grab()
	print("SMOKE part grabbed: ", l.held_node == part)
	var hand_to_part: Vector3 = part.global_position - l.global_position
	var worst := 0.0
	for i in 90:
		origin.global_position += Vector3(0, 0, -1.5 / 90.0)
		await physics_frame
		worst = maxf(worst, (part.global_position - l.global_position - hand_to_part).length())
	print("SMOKE part stays in the hand during a 1.5 m/s walk (worst drift, mm): ", snappedf(worst * 1000.0, 0.01))
	# A snap turn (about the head, as locomotion.gd does): the part swings round with you, still where it was in the hand.
	var in_hand_before: Vector3 = l.global_transform.affine_inverse() * part.global_position
	var pivot := origin.global_position + Vector3(0, 1.6, 0)
	origin.global_position = pivot + (origin.global_position - pivot).rotated(Vector3.UP, deg_to_rad(-30))
	origin.rotate_y(deg_to_rad(-30))
	await physics_frame
	var in_hand_after: Vector3 = l.global_transform.affine_inverse() * part.global_position
	print("SMOKE part stays in the hand through a snap turn (drift, mm): ", snappedf((in_hand_after - in_hand_before).length() * 1000.0, 0.01))
	l._try_release()
	part.queue_free()
	await process_frame

	# Whole-model one-hand drag on a big model (gain > 1): a stick walk moves the model exactly as far as the origin, not gain times.
	var th = load("res://scripts/two_hand_model.gd").new(); world.add_child(th)
	var model := Node3D.new(); world.add_child(model)
	var big := MeshInstance3D.new(); var bb := BoxMesh.new(); bb.size = Vector3(10, 2, 10); big.mesh = bb; model.add_child(big); big.add_to_group("grabbable_parts")
	await process_frame
	th.setup(model, l, r, 1.0)
	th.set_steadiness(0)
	var hand_local := Vector3(0.2, 1.0, -0.3)
	th._update_one_hand(l, hand_local) # starts the drag
	print("SMOKE big model drags with gain > 1: ", th._one_hand_gain > 1.0, " (", snappedf(th._one_hand_gain, 0.01), ")")
	var m0: Vector3 = model.global_position
	var o0: Vector3 = origin.global_position
	origin.global_position += Vector3(2.0, 0, -1.0) # walked 2.24 m, hand still in the same place relative to you
	th._update_one_hand(l, hand_local)
	print("SMOKE model moved as far as the walk, not gain times (error, mm): ", snappedf(((model.global_position - m0) - (origin.global_position - o0)).length() * 1000.0, 0.01))
	th._update_one_hand(l, hand_local + Vector3(0.1, 0, 0)) # the arm's own move IS amplified
	var arm_move: float = (model.global_position - m0 - (origin.global_position - o0)).length()
	print("SMOKE the arm's own 10 cm move is still amplified by the gain: ", is_equal_approx(snappedf(arm_move, 0.0001), snappedf(0.1 * th._one_hand_gain, 0.0001)))

	# Two-hand drag, same: walking with both hands on the model carries it along unamplified and unscaled.
	th._mode = 0
	var lp := Vector3(-0.3, 1.0, -0.3); var rp := Vector3(0.3, 1.0, -0.3)
	th._update_two_hand(lp, rp)
	var before: Transform3D = model.global_transform
	var o1: Vector3 = origin.global_position
	origin.global_position += Vector3(0, 0, -3.0)
	th._update_two_hand(lp, rp)
	print("SMOKE two-hand: model moved as far as the walk (error, mm): ", snappedf(((model.global_position - before.origin) - (origin.global_position - o1)).length() * 1000.0, 0.01),
		"  scale unchanged: ", model.global_transform.basis.get_scale().is_equal_approx(before.basis.get_scale()))
	quit()
