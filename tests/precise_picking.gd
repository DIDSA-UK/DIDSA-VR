extends SceneTree
## Precise picking: a real ray test against parts' actual collision geometry
## (nearest hit wins), replacing the old angle-to-origin cone; hover
## highlight plus the hovered part's name; rotation pivoting on the ray's hit
## point (or the part's centre) rather than the part's own origin.
## Run: "$GODOT" --headless --path . --script res://tests/precise_picking.gd  (see tests/README.md)

func box_part(parent: Node, size: Vector3, pos: Vector3) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = size
	m.mesh = bm
	parent.add_child(m)
	m.position = pos
	m.add_to_group("grabbable_parts")
	m.create_trimesh_collision() # matches main.gd's real-load path so the ray test has geometry to hit
	return m

func _initialize() -> void:
	var world := Node3D.new(); root.add_child(world)
	var origin := XROrigin3D.new(); world.add_child(origin)
	var l := XRController3D.new(); l.tracker = &"left_hand"; l.set_script(load("res://scripts/controller.gd")); origin.add_child(l)
	var assembly := Node3D.new(); assembly.add_to_group("assembly_root"); world.add_child(assembly)
	await process_frame

	l.position = Vector3(0, 1, 0)
	l.rotation = Vector3.ZERO # aims along -Z

	# --- the old bug: a small part sits within the old 12deg cone around
	# the hand's aim (measured to its ORIGIN), but the ray itself never
	# touches its actual geometry. Old code would have picked it anyway.
	var off_target := box_part(assembly, Vector3(0.1, 0.1, 0.1), Vector3(0.3, 1, -3))
	await physics_frame; await physics_frame
	var l_forward: Vector3 = -l.global_transform.basis.z.normalized()
	var angle_to_origin := rad_to_deg(l_forward.angle_to((off_target.global_position - l.global_position).normalized()))
	print("SMOKE off-axis small part: angle to its origin = ", snappedf(angle_to_origin, 0.1), " deg (old 12 deg cone would have picked it)")
	var miss: Dictionary = l._raycast_part(l.global_transform.origin, l_forward, l.select_max_distance)
	print("SMOKE real ray test correctly finds nothing there: ", miss.is_empty())
	off_target.queue_free(); await physics_frame

	# --- nearest hit wins among two parts overlapping along the same ray
	var far := box_part(assembly, Vector3(0.4, 0.4, 0.4), Vector3(0, 1, -5))
	var near := box_part(assembly, Vector3(0.4, 0.4, 0.4), Vector3(0, 1, -2))
	await physics_frame; await physics_frame
	var hit: Dictionary = l._raycast_part(l.global_transform.origin, l_forward, l.select_max_distance)
	print("SMOKE nearest of two overlapping parts wins: ", hit.get("part") == near)

	# --- hover highlight + name, before pulling the trigger
	print("SMOKE hover highlights the part the ray would hit: ", near.material_overlay != null)
	print("SMOKE hovering a part highlights it but shows NO name label (the 'MESH 2' text was removed): ", near.material_overlay != null and l.get("_aim_label") == null)
	l.position += Vector3(5, 0, 0) # aim away from everything
	await physics_frame; await physics_frame
	print("SMOKE hover clears when aiming at nothing: ", near.material_overlay == null)
	l.position = Vector3(0, 1, 0)
	near.queue_free(); far.queue_free()

	# --- selecting pivots rotation on the ray's HIT point, not the part's origin
	var big := box_part(assembly, Vector3(1, 1, 1), Vector3(0, 1, -2)) # spans x/y +-0.5 about its centre
	await physics_frame; await physics_frame
	l.position = Vector3(0.4, 1.4, 0) # aim at a corner of the box, well off its centre
	await physics_frame
	l._try_select()
	print("SMOKE selected the big box: ", l.selected_node == big)
	var pivot_before: Vector3 = big.global_transform * l._pivot_local
	print("SMOKE pivot sits away from the part's own origin: ", pivot_before.distance_to(big.global_position) > 0.3)
	var origin_before := big.global_position
	l._rotate_about_pivot(big, Vector3.UP, deg_to_rad(90.0))
	var pivot_after: Vector3 = big.global_transform * l._pivot_local
	print("SMOKE hit point stays put through the rotation (distance moved): ", snappedf(pivot_before.distance_to(pivot_after), 0.001))
	print("SMOKE part origin swung away from the hit point instead: ", big.global_position.distance_to(origin_before) > 0.3)
	quit()
