extends RefCounted
## Which rooms exist, which slot each has, and the two things everything else needs to know about them:
##   * what the shader is told (`push()` packs every room's box into the small float texture `room_clip_tex` and sets `room_clip_count`), and
##   * whether a given spot on a given part is actually visible (`part_visible_at`), which the picking code asks so a clipped-away part
##     cannot be hit by the laser or taken by a grip (a shader discard does not change a part's collision geometry).
## Static state, like clip_globals.gd's: the shader's uniforms are global too, so there is one set of rooms per process.
## A part says where it lives with the `room_slot` meta: absent or -1 = the world, >= 0 = that room (room_clip.gd sets it and the material's switch).
## Slots are stable: removing a room leaves a hole (its row's half extent goes negative) rather than renumbering the rest, so the slot a part
## carries stays right. `max_rooms` is the user-facing cap (default 4, a setting); HARD_MAX is what the texture holds.

const ClipGlobals := preload("res://scripts/clip_globals.gd")

const HARD_MAX := 16 ## rows in the shader's texture
const META := "room_slot"

static var max_rooms := 4 ## the cap on open rooms; Settings changes it (clamped to 1..HARD_MAX)
static var rooms: Array = [] ## RoomVolume or null per slot
static var revision := 0 ## bumps whenever a room is added, removed, moved or resized (push() was called)


static func set_max_rooms(count: int) -> void:
	max_rooms = clampi(count, 1, HARD_MAX)


static func room_count() -> int:
	var n := 0
	for r in rooms:
		if r != null:
			n += 1
	return n


static func can_add() -> bool:
	return room_count() < max_rooms


static func add_room(volume: RefCounted) -> int:
	## The slot the room got, or -1 if the cap is reached or the box overlaps an existing room (rooms never overlap).
	if not can_add():
		return -1
	for other in rooms:
		if other != null and other.overlaps(volume):
			return -1
	var slot := rooms.find(null)
	if slot == -1:
		slot = rooms.size()
		rooms.append(volume)
	else:
		rooms[slot] = volume
	volume.slot = slot
	push()
	return slot


static func next_slot() -> int:
	## The slot the next room would get (a hole left by a closed room first), so a placement ghost can wear the colour the room will have.
	var hole := rooms.find(null)
	return hole if hole != -1 else rooms.size()


static func would_overlap(volume: RefCounted, ignoring: RefCounted = null) -> bool:
	## Would this box share volume with any open room (other than `ignoring`, the room being moved or resized)?
	for other in rooms:
		if other != null and other != ignoring and other.overlaps(volume):
			return true
	return false


static func remove_room(volume: RefCounted) -> void:
	var slot := rooms.find(volume)
	if slot == -1:
		return
	rooms[slot] = null
	volume.slot = -1
	while not rooms.is_empty() and rooms.back() == null:
		rooms.pop_back()
	push()


static func clear() -> void:
	for r in rooms:
		if r != null:
			r.slot = -1
	rooms.clear()
	push()


static func slot_of(part: Node) -> int:
	return int(part.get_meta(META, -1)) if part != null else -1


static func is_room_part(node: Node) -> bool:
	## A part that lives in an Assembly Room (room.gd tags it `room_id`), as opposed to the world's.
	return node != null and node.has_meta("room_id")


static func world_parts(tree: SceneTree) -> Array:
	## The arena's own parts: everything grabbable that is not in a room (and not the one sitting on the design table).
	return tree.get_nodes_in_group("grabbable_parts").filter(func(p: Node) -> bool: return not p.has_meta("room_id") and not p.has_meta("on_table"))


static func parts_in_room(tree: SceneTree, room_id: int) -> Array:
	return tree.get_nodes_in_group("grabbable_parts").filter(func(p: Node) -> bool: return int(p.get_meta("room_id", 0)) == room_id)


static func part_centre(part: Node3D) -> Vector3:
	if part is MeshInstance3D:
		return part.global_transform * (part as MeshInstance3D).get_aabb().get_center()
	return part.global_position


static func stray_reason(part: Node3D) -> String:
	## Why a part that was just put down must go back where it was, or "" if it may stay. A room's part may not leave its room (nothing outside the
	## walls is its to show), and a world part may not be left inside one (it would be cut away, invisible and unreachable): both snap back. Putting a
	## NEW item into a room is the separate drop-to-add flow (docs/assembly-rooms-scope.md), not a stray move.
	if rooms.is_empty() or part == null:
		return ""
	var slot := slot_of(part)
	var centre := part_centre(part)
	if is_room_part(part) and slot >= 0:
		if slot < rooms.size() and rooms[slot] != null and rooms[slot].contains(centre):
			return ""
		var other := room_at(centre)
		return "entered_room" if other != -1 and other != slot else "left_room" # put down inside ANOTHER room: a copy for that room (room_manager.gd)
	return "entered_room" if room_at(centre) != -1 else ""


static func room_at(world_point: Vector3) -> int:
	## The slot of the room containing the point, or -1.
	for i in rooms.size():
		if rooms[i] != null and rooms[i].contains(world_point):
			return i
	return -1


static func part_visible_at(part: Node, world_point: Vector3) -> bool:
	## The shader's decision, for one point of one part: a room's content shows only inside its own box; the world shows only outside every box.
	## True when there are no rooms (the common case costs one comparison). Parts that never carry the meta are the world.
	if rooms.is_empty():
		return true
	var slot := slot_of(part)
	if slot >= 0:
		return slot < rooms.size() and rooms[slot] != null and rooms[slot].contains(world_point)
	return room_at(world_point) == -1


static func pack_image() -> Image:
	## The rows the shader reads. Row = slot: texels 0..2 are the world -> room-local matrix (xyz = basis row, w = translation), texel 3 the half extents.
	## An empty slot has a negative half extent, which room_contains() treats as "no room".
	var img := Image.create_empty(ClipGlobals.ROOM_TEX_WIDTH, ClipGlobals.ROOM_TEX_ROWS, false, Image.FORMAT_RGBAF)
	img.fill(Color(0, 0, 0, 0))
	for y in ClipGlobals.ROOM_TEX_ROWS:
		img.set_pixel(3, y, Color(-1, -1, -1, 0))
	for i in mini(rooms.size(), ClipGlobals.ROOM_TEX_ROWS):
		var v = rooms[i]
		if v == null:
			continue
		var inv: Transform3D = v.xform.affine_inverse()
		var b := inv.basis
		var o := inv.origin
		img.set_pixel(0, i, Color(b.x.x, b.y.x, b.z.x, o.x)) # row 0 of the matrix: local.x = dot(row.xyz, p) + row.w
		img.set_pixel(1, i, Color(b.x.y, b.y.y, b.z.y, o.y))
		img.set_pixel(2, i, Color(b.x.z, b.y.z, b.z.z, o.z))
		img.set_pixel(3, i, Color(v.half.x, v.half.y, v.half.z, 0))
	return img


static func push() -> void:
	## Tells the shader. Call after any change to a room's box (a move, a wall drag): add/remove do it themselves.
	revision += 1
	ClipGlobals.ensure()
	ClipGlobals.room_texture.update(pack_image())
	RenderingServer.global_shader_parameter_set("room_clip_count", rooms.size())
