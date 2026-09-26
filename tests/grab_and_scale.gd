extends SceneTree
## Grip-grab reach (bounding box + 5 cm), hover highlight, part pivots about the grab point, smallest-part preference, and the 3x two-hand scale gain (10% spread -> x1.331, same in one step or ten).
## Run: "$GODOT" --headless --path . --script res://tests/grab_and_scale.gd  (see tests/README.md)

func box_part(parent: Node, size: Vector3, pos: Vector3) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = size
	m.mesh = bm
	parent.add_child(m)
	m.position = pos
	m.add_to_group("grabbable_parts")
	return m

func _initialize() -> void:
	var world := Node3D.new(); root.add_child(world)
	var origin := XROrigin3D.new(); world.add_child(origin)
	var l := XRController3D.new(); l.tracker = &"left_hand"; l.set_script(load("res://scripts/controller.gd")); origin.add_child(l)
	var r := XRController3D.new(); r.tracker = &"right_hand"; r.set_script(load("res://scripts/controller.gd")); origin.add_child(r)
	var assembly := Node3D.new(); assembly.add_to_group("assembly_root"); world.add_child(assembly)
	await process_frame

	# A 1 m long bar, origin at its centre, at (0,1,-1). Its END is 0.5 m from the origin.
	var bar := box_part(assembly, Vector3(1.0, 0.1, 0.1), Vector3(0, 1, -1))
	l.position = Vector3(0.45, 1, -1)         # inside the bar, 0.45 m from its origin
	print("SMOKE hand inside bar end (0.45 m from origin) grabs it: ", l._find_grab_target() == bar, "   [old rule: radius 0.25 from origin -> would MISS]")
	l.position = Vector3(0.54, 1, -1)         # 4 cm past the end
	print("SMOKE hand 4 cm past the end (within 5 cm reach): ", l._find_grab_target() == bar)
	l.position = Vector3(0.58, 1, -1)         # 8 cm past the end
	print("SMOKE hand 8 cm past the end (outside reach): ", l._find_grab_target() == null)
	l.position = Vector3(0.0, 1.3, -1)        # 25 cm above the centre, old rule radius edge
	print("SMOKE hand 25 cm above the bar's centre (was inside the old sphere, isn't touching): ", l._find_grab_target() == null)

	# hover highlight
	l.position = Vector3(0.3, 1, -1)
	await physics_frame; await physics_frame
	print("SMOKE hover highlight on when touching: ", bar.material_overlay != null)
	l.position = Vector3(2, 1, -1)
	await physics_frame; await physics_frame
	print("SMOKE hover highlight off when away: ", bar.material_overlay == null)

	# grabbing at the end: the part turns about where you took hold of it
	l.position = Vector3(0.45, 1, -1)
	await physics_frame
	var grab_point_local: Vector3 = bar.global_transform.affine_inverse() * l.global_position
	l._try_grab()
	print("SMOKE grabbed: ", l.held_node == bar)
	l.rotation_degrees = Vector3(0, 90, 30)   # turn the hand
	l.position += Vector3(0.2, 0.1, 0.0)      # and move it
	var where_grabbed_now: Vector3 = bar.global_transform * grab_point_local
	print("SMOKE grab point stays in the hand after moving+turning (distance): ", snappedf(where_grabbed_now.distance_to(l.global_position), 0.0001))
	print("SMOKE part centre swung away from hand (distance ~0.45): ", snappedf(bar.global_position.distance_to(l.global_position), 0.001))
	l._try_release()

	# preference: small part inside a big one
	l.position = Vector3(0, 1, -1); l.rotation = Vector3.ZERO
	var big := box_part(assembly, Vector3(1, 1, 1), Vector3(0, 1, -1))
	var small := box_part(assembly, Vector3(0.1, 0.1, 0.1), Vector3(0, 1, -1))
	print("SMOKE small part inside a big one is preferred: ", l._find_grab_target() == small)

	# two-hand scale gain: hands 10% farther apart => 1.1^3 = 1.331x
	var th = load("res://scripts/two_hand_model.gd").new(); world.add_child(th)
	var model := Node3D.new(); world.add_child(model)
	th.setup(model, l, r, 1.0)
	var mid := Vector3(0, 1, 0)
	l.position = mid + Vector3(-0.3, 0, 0); r.position = mid + Vector3(0.3, 0, 0)
	th._update_two_hand(l.position, r.position)
	l.position = mid + Vector3(-0.33, 0, 0); r.position = mid + Vector3(0.33, 0, 0)
	th._update_two_hand(l.position, r.position)
	print("SMOKE hands 10% apart -> scale x", snappedf(model.scale.x, 0.001), " (expect 1.331)")
	# and splitting the same spread over many frames gives the same result (path independent)
	model.transform = Transform3D.IDENTITY
	l.position = mid + Vector3(-0.3, 0, 0); r.position = mid + Vector3(0.3, 0, 0)
	th._mode = 0
	th._update_two_hand(l.position, r.position)
	for i in range(1, 11):
		var half := 0.3 + 0.03 * i / 10.0
		l.position = mid + Vector3(-half, 0, 0); r.position = mid + Vector3(half, 0, 0)
		th._update_two_hand(l.position, r.position)
	print("SMOKE same spread in 10 small steps -> scale x", snappedf(model.scale.x, 0.001))
	quit()
