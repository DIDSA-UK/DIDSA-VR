extends SceneTree
## Assembly Rooms, R0 (docs/assembly-rooms-scope.md): the room volume maths, the registry (slots, cap, no overlap, the packed texture rows the shader reads),
## the part wrapping (and the section tool adopting it), and that a clipped-away spot cannot be picked: the laser's ray carries on through it and a grip
## cannot take it. Headless: logic only, no pixels (tests/room_clip_render.gd draws the shader).
## Run: "$GODOT" --headless --path . --script res://tests/room_clip.gd  (see tests/README.md)

const RoomVolume := preload("res://scripts/room/room_volume.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const RoomClip := preload("res://scripts/room/room_clip.gd")
const LaserPick := preload("res://scripts/laser_pick.gd")
const SectionTool := preload("res://scripts/section_tool.gd")
const ClipShader := preload("res://shaders/section_clip.gdshader")


func box_part(parent: Node, size: Vector3, pos: Vector3, colour: Color = Color(0.8, 0.2, 0.2)) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	bm.material = mat
	m.mesh = bm
	parent.add_child(m)
	m.position = pos
	m.add_to_group("grabbable_parts")
	m.create_trimesh_collision()
	return m


func _initialize() -> void:
	# --- the minimum size: a new room is at least a 3 m cube, larger only if its content needs it
	var small := RoomVolume.spawn_size(Vector3(0.2, 0.1, 0.3))
	var big := RoomVolume.spawn_size(Vector3(4.0, 1.0, 2.0))
	print("SMOKE a new room around small content is a 3 m cube: ", small.is_equal_approx(Vector3(3, 3, 3)))
	print("SMOKE content bigger than the cube grows only the sides it needs, with a margin each side: ", big.is_equal_approx(Vector3(4.5, 3.0, 3.0)))
	print("SMOKE a wall drag may not go under the (smaller) drag minimum: ", RoomVolume.clamp_drag_size(Vector3(0.1, 2.0, 0.5)).is_equal_approx(Vector3(0.5, 2.0, 0.5)) and RoomVolume.MIN_DRAG_SIZE_M < RoomVolume.MIN_SPAWN_SIZE_M)

	# --- the volume
	var room := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(0, 1, -3)), Vector3(3, 3, 3))
	print("SMOKE contains: the middle, a corner just inside, not just outside: ", room.contains(Vector3(0, 1, -3)) and room.contains(Vector3(1.49, 2.49, -1.51)) and not room.contains(Vector3(1.51, 1, -3)) and not room.contains(Vector3(0, 2.6, -3)))
	var turned := RoomVolume.make(Transform3D(Basis(Vector3.UP, deg_to_rad(45.0)), Vector3.ZERO), Vector3(2, 2, 2))
	print("SMOKE a turned room (45 degrees): its corner reaches past the world-axis edge, and a spot inside the unturned box can be outside it: ", turned.contains(Vector3(1.2, 0, 0.0)) and not turned.contains(Vector3(0.9, 0, 0.9)) and turned.contains(Vector3(0.5, 0, 0.0)))
	var scaled_in := RoomVolume.make(Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 5.0), Vector3.ZERO), Vector3(2, 2, 2))
	print("SMOKE a scale in the transform is dropped (walls are never scaled, only content): ", scaled_in.contains(Vector3(0.9, 0.9, 0.9)) and not scaled_in.contains(Vector3(1.1, 0, 0)))

	# --- overlap
	var a := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3.ZERO), Vector3(3, 3, 3))
	var b := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(3.2, 0, 0)), Vector3(3, 3, 3))
	var c := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(2.9, 0, 0)), Vector3(3, 3, 3))
	var d := RoomVolume.make(Transform3D(Basis(Vector3.UP, deg_to_rad(45.0)), Vector3(3.4, 0, 0)), Vector3(3, 3, 3))
	var e := RoomVolume.make(Transform3D(Basis(Vector3.UP, deg_to_rad(45.0)), Vector3(3.8, 0, 0)), Vector3(3, 3, 3))
	print("SMOKE overlap: apart is false, sharing volume is true: ", not a.overlaps(b) and a.overlaps(c) and c.overlaps(a))
	print("SMOKE overlap: a turned box's corner reaching in counts, one just clear of it does not: ", a.overlaps(d) and not a.overlaps(e))

	# --- the registry
	RoomRegistry.clear()
	RoomRegistry.set_max_rooms(4)
	var r0 := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(0, 1, -4)), Vector3(3, 3, 3))
	var r1 := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(5, 1, -4)), Vector3(3, 3, 3))
	var overlapping := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(1, 1, -4)), Vector3(3, 3, 3))
	print("SMOKE first rooms get slots 0 and 1: ", RoomRegistry.add_room(r0) == 0 and RoomRegistry.add_room(r1) == 1 and r1.slot == 1)
	print("SMOKE a room overlapping an existing one is refused: ", RoomRegistry.add_room(overlapping) == -1 and RoomRegistry.room_count() == 2)
	RoomRegistry.remove_room(r0)
	var r2 := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(-5, 1, -4)), Vector3(3, 3, 3))
	print("SMOKE slots are stable: removing room 0 leaves room 1 at slot 1, and the hole is reused: ", r1.slot == 1 and RoomRegistry.add_room(r2) == 0)
	RoomRegistry.add_room(r0)
	var r3 := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(10, 1, -4)), Vector3(3, 3, 3))
	var r4 := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(15, 1, -4)), Vector3(3, 3, 3))
	print("SMOKE the cap (4) stops a fifth room; raising it allows one: ", RoomRegistry.add_room(r3) >= 0 and RoomRegistry.add_room(r4) == -1 and not RoomRegistry.can_add())
	RoomRegistry.set_max_rooms(6)
	print("SMOKE max_rooms is a setting: raising it lets the fifth in, and it is clamped to what the texture holds: ", RoomRegistry.add_room(r4) >= 0)
	RoomRegistry.set_max_rooms(99)
	print("SMOKE max_rooms is clamped to the hard limit: ", RoomRegistry.max_rooms == RoomRegistry.HARD_MAX)
	RoomRegistry.clear()
	RoomRegistry.set_max_rooms(4)

	# --- the packed texture rows are exactly the maths the shader does
	RoomRegistry.clear()
	var tilted := RoomVolume.make(Transform3D(Basis(Vector3(0.3, 1, 0.2).normalized(), 0.7), Vector3(1.5, 2.0, -3.0)), Vector3(3, 2, 4))
	RoomRegistry.add_room(RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(20, 0, 0)), Vector3(3, 3, 3))) # slot 0 elsewhere
	var slot := RoomRegistry.add_room(tilted)
	var img := RoomRegistry.pack_image()
	var worst := 0.0
	for p in [Vector3(1.5, 2.0, -3.0), Vector3(2.0, 2.5, -2.0), Vector3(-1, 0, 1), Vector3(3, 3, -5)]:
		var r0p := img.get_pixel(0, slot)
		var r1p := img.get_pixel(1, slot)
		var r2p := img.get_pixel(2, slot)
		var l := Vector3(Vector3(r0p.r, r0p.g, r0p.b).dot(p) + r0p.a, Vector3(r1p.r, r1p.g, r1p.b).dot(p) + r1p.a, Vector3(r2p.r, r2p.g, r2p.b).dot(p) + r2p.a)
		worst = maxf(worst, l.distance_to(tilted.to_local(p)))
	var h := img.get_pixel(3, slot)
	print("SMOKE the texture rows reproduce the box's world-to-local maths (worst error under 1e-4): ", worst < 0.0001, " ", worst)
	print("SMOKE the half extents are in texel 3, and an empty slot is negative (= no room): ", Vector3(h.r, h.g, h.b).is_equal_approx(Vector3(1.5, 1.0, 2.0)) and img.get_pixel(3, 5).r < 0.0)
	RoomRegistry.clear()

	# --- visibility: a room's content shows inside its box, the world outside every box
	var rv := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(0, 1, -3)), Vector3(3, 3, 3))
	var holder := Node3D.new()
	root.add_child(holder)
	var world_part := Node3D.new()
	var room_part := Node3D.new()
	holder.add_child(world_part)
	holder.add_child(room_part)
	print("SMOKE no rooms: everything is visible everywhere: ", RoomRegistry.part_visible_at(world_part, Vector3(0, 1, -3)) and RoomRegistry.part_visible_at(room_part, Vector3(99, 0, 0)))
	RoomRegistry.add_room(rv)
	room_part.set_meta(RoomRegistry.META, rv.slot)
	var inside := Vector3(0, 1, -3)
	var outside := Vector3(4, 1, -3)
	print("SMOKE the world shows outside the room and is cut inside it: ", RoomRegistry.part_visible_at(world_part, outside) and not RoomRegistry.part_visible_at(world_part, inside))
	print("SMOKE a room's part shows inside the room and is cut outside it: ", RoomRegistry.part_visible_at(room_part, inside) and not RoomRegistry.part_visible_at(room_part, outside))
	RoomRegistry.clear()

	# --- wrapping: a part wears the clip material with its colour and slot, and gets its own material back
	var wrap_part := box_part(holder, Vector3(1, 1, 1), Vector3(0, 0, 0), Color(0.1, 0.6, 0.3))
	RoomClip.assign(wrap_part, 2)
	var mat := wrap_part.material_override as ShaderMaterial
	print("SMOKE assign wraps the part in the clip shader with its colour and room slot: ", mat != null and mat.shader == ClipShader and (mat.get_shader_parameter("albedo_color") as Color).is_equal_approx(Color(0.1, 0.6, 0.3)) and int(wrap_part.get_instance_shader_parameter("room_slot")) == 2 and RoomRegistry.slot_of(wrap_part) == 2)
	RoomClip.assign(wrap_part, 1)
	print("SMOKE moving a part to another room keeps one material (no stacking): ", wrap_part.material_override == mat and int(wrap_part.get_instance_shader_parameter("room_slot")) == 1)
	RoomClip.release(wrap_part)
	print("SMOKE release puts the part's own look back and forgets the slot: ", wrap_part.material_override == null and not wrap_part.has_meta(RoomRegistry.META) and RoomRegistry.slot_of(wrap_part) == -1)
	var painted := box_part(holder, Vector3(1, 1, 1), Vector3(0, 0, 0))
	var flat := StandardMaterial3D.new()
	flat.albedo_color = Color(0.9, 0.9, 0.1)
	painted.material_override = flat
	RoomClip.assign(painted, -1)
	RoomClip.release(painted)
	print("SMOKE a part with a colour override gets that override back: ", painted.material_override == flat)

	# the section tool adopts a part already wearing the clip material instead of replacing it (which would lose the slot and the colour)
	var section_part := box_part(holder, Vector3(1, 1, 1), Vector3(0, 0, 0), Color(0.2, 0.3, 0.9))
	RoomClip.assign(section_part, 3)
	var before := section_part.material_override
	var tool := SectionTool.new()
	root.add_child(tool)
	await process_frame
	tool.set_active(true, null)
	tool.reconcile([section_part])
	print("SMOKE the section tool adopts a room part's clip material (slot and colour survive): ", section_part.material_override == before and int(section_part.get_instance_shader_parameter("room_slot")) == 3 and ((before as ShaderMaterial).get_shader_parameter("albedo_color") as Color).is_equal_approx(Color(0.2, 0.3, 0.9)))
	tool.set_active(false)
	print("SMOKE ...and leaves it in place when the tool goes off: ", section_part.material_override == before)
	tool.free()
	RoomClip.release(section_part)

	# reconcile follows the registry: wraps when rooms exist, unwraps when none are left, re-wraps a part colour_tool.gd just painted
	var rec := box_part(holder, Vector3(1, 1, 1), Vector3(0, 0, 0))
	RoomClip.reconcile([rec])
	print("SMOKE with no rooms, reconcile leaves parts alone: ", rec.material_override == null)
	RoomRegistry.add_room(RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(0, 1, -3)), Vector3(3, 3, 3)))
	RoomClip.reconcile([rec])
	print("SMOKE with a room, reconcile wraps a world part (slot -1): ", rec.material_override is ShaderMaterial and int(rec.get_instance_shader_parameter("room_slot")) == -1)
	var repainted := StandardMaterial3D.new()
	repainted.albedo_color = Color(0.5, 0.1, 0.1)
	rec.material_override = repainted # colour_tool.gd paints by replacing the override
	RoomClip.reconcile([rec])
	print("SMOKE ...and wraps it again after a repaint, with the new colour: ", rec.material_override is ShaderMaterial and ((rec.material_override as ShaderMaterial).get_shader_parameter("albedo_color") as Color).is_equal_approx(Color(0.5, 0.1, 0.1)))
	RoomRegistry.clear()
	RoomClip.reconcile([rec])
	print("SMOKE when the last room goes, the parts are given back: ", rec.material_override == repainted)
	holder.queue_free()
	await process_frame

	# --- picking: the laser's ray goes through a cut-away spot
	var world := Node3D.new()
	root.add_child(world)
	var room_box := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(0, 0, -3)), Vector3(3, 3, 3)) # x -1.5..1.5, z -4.5..-1.5
	RoomRegistry.add_room(room_box)
	var wall := box_part(world, Vector3(10, 1, 0.1), Vector3(0, 0, -2)) # a WORLD part: passes through the room at z = -2
	var back := box_part(world, Vector3(10, 1, 0.1), Vector3(0, 0, -4)) # a ROOM part, wider than the room, at z = -4
	back.set_meta(RoomRegistry.META, room_box.slot)
	await physics_frame
	await physics_frame
	var classify := func(part: Node3D) -> int:
		if part == null or not part.is_in_group("grabbable_parts"):
			return LaserPick.BLOCK
		return LaserPick.HIT if part.visible else LaserPick.SKIP
	var w := root.get_world_3d()
	var dir := Vector3(0, 0, -1)
	var plain_inside: Dictionary = LaserPick.ray(w, Vector3(0, 0, 5), dir, 20.0, classify)
	var filtered_inside: Dictionary = LaserPick.ray(w, Vector3(0, 0, 5), dir, 20.0, classify, 0xFFFFFFFF, RoomRegistry.part_visible_at)
	var filtered_outside: Dictionary = LaserPick.ray(w, Vector3(3, 0, 5), dir, 20.0, classify, 0xFFFFFFFF, RoomRegistry.part_visible_at)
	print("SMOKE without the filter the ray hits the world wall first (old behaviour unchanged): ", plain_inside.get("part") == wall)
	print("SMOKE inside the room the ray goes through the cut-away world wall and picks the room's part behind it: ", filtered_inside.get("part") == back)
	print("SMOKE outside the room the world wall is visible and is picked: ", filtered_outside.get("part") == wall)
	wall.visible = false
	var only_back_outside: Dictionary = LaserPick.ray(w, Vector3(3, 0, 5), dir, 20.0, classify, 0xFFFFFFFF, RoomRegistry.part_visible_at)
	print("SMOKE the room's part outside the room is cut away and cannot be picked: ", only_back_outside.is_empty())
	wall.visible = true

	# --- a grip cannot take the cut-away part
	var origin := XROrigin3D.new()
	world.add_child(origin)
	var hand := XRController3D.new()
	hand.tracker = &"left_hand"
	hand.set_script(load("res://scripts/controller.gd"))
	origin.add_child(hand)
	var assembly := Node3D.new()
	assembly.add_to_group("assembly_root")
	world.add_child(assembly)
	await process_frame
	wall.visible = false
	hand.position = Vector3(0.0, 0.0, -4.0) # touching the room's part, inside the room
	print("SMOKE a hand touching a room part inside its room can grip it: ", hand._find_grab_target() == back)
	hand.position = Vector3(4.0, 0.0, -4.0) # touching the same part, but out past the room's wall
	print("SMOKE a hand touching it out past the wall (cut away) cannot: ", hand._find_grab_target() == null)
	RoomRegistry.clear()
	hand.position = Vector3(4.0, 0.0, -4.0)
	print("SMOKE with the room gone the same spot grips again (nothing else changed): ", hand._find_grab_target() == back)
	quit()
