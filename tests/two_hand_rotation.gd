extends SceneTree
## Two-hand rotation: yaw the hand-line then tilt it, and check the model's up axis builds on each rotation (expect (0, 0.7071, 0.7071)).
## Run: "$GODOT" --headless --path . --script res://tests/two_hand_rotation.gd  (see tests/README.md)
# Yaw the hand-line 90 deg, THEN pitch it up 45 deg. Where does the model's X axis end up?
func _initialize() -> void:
	var world := Node3D.new(); root.add_child(world)
	var origin := XROrigin3D.new(); world.add_child(origin)
	var l := XRController3D.new(); l.tracker = &"left_hand"; origin.add_child(l)
	var r := XRController3D.new(); r.tracker = &"right_hand"; origin.add_child(r)
	var assembly := Node3D.new(); world.add_child(assembly)
	var th = load("res://scripts/two_hand_model.gd").new(); world.add_child(th)
	th.setup(assembly, l, r, 1.0)
	await process_frame
	var mid := Vector3(0, 1, 0)
	var set_hands := func(v: Vector3):
		l.position = mid - v * 0.5
		r.position = mid + v * 0.5
	var v0 := Vector3(1, 0, 0) * 0.6
	var v1 := Vector3(0, 0, -1) * 0.6                      # after the first rotation (yaw 90)
	var v2 := Vector3(0, 0.7071, -0.7071) * 0.6            # then tilt the line up 45 deg
	set_hands.call(v0); th._update_two_hand(l.position, r.position)
	set_hands.call(v1); th._update_two_hand(l.position, r.position)
	print("SMOKE model X axis after yaw:   ", assembly.global_transform.basis.x)
	set_hands.call(v2); th._update_two_hand(l.position, r.position)
	print("SMOKE model X axis after tilt:  ", assembly.global_transform.basis.x)
	print("SMOKE model Y (up) axis after yaw+tilt: ", assembly.global_transform.basis.y)
	var expect := Basis(Quaternion(v1.normalized(), v2.normalized())) * Basis(Quaternion(v0.normalized(), v1.normalized()))
	print("SMOKE expected Y if each rotation builds on the last: ", expect.y)
	print("SMOKE  intuitive (follows hand-line the whole way) would be: ", v2.normalized())
	quit()
