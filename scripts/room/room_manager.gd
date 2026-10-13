extends Node
## The open Assembly Rooms (docs/assembly-rooms-scope.md): opens one for a Part (fetching its own assembly-mesh.glb), puts it in front of the user clear of
## the others, hides the world's copy of it while it is open, keeps every part under the room clip each frame, and closes it again. main.gd owns one.
##
## Opening a sub-assembly: GET /document/parts/{part_id}/assembly-mesh.glb is that Part as its own root, in its own frame. The WORLD's copy is found by
## owner: the backend tags every node with its immediate parent Part (`owner_part_id`) and the Occurrence that placed it (mesh_identity.gd), so the nodes
## to hide are those owned by this sub-assembly Part or any Part nested in it, plus the sub-assembly's own geometry (owner = its parent, occurrence = the
## one opened). If the same Part is placed more than once, all its placements are hidden while it is open: a room edits the shared definition (the scope
## document's rule) and the later Preview feature shows the instances updated.

signal rooms_changed
signal status(text: String)

const BackendSession := preload("res://scripts/backend_session.gd")
const Room := preload("res://scripts/room/room.gd")
const RoomVolume := preload("res://scripts/room/room_volume.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const RoomClip := preload("res://scripts/room/room_clip.gd")
const RoomPlacement := preload("res://scripts/room/room_placement.gd")
const TwoHandModel := preload("res://scripts/two_hand_model.gd")

const ROOM_MIN_MULTIPLE := 0.01 ## a room's content may be scaled between these multiples of real life (the world's are 0.1 to 50): a 10 mm part fits a 3 m room at about 200x
const ROOM_MAX_MULTIPLE := 2000.0

var rooms: Array = [] ## Room nodes, in the order they were opened

var _main: Node
var _view_modes: Node
var _backend_url := ""
var _api_key := ""
var _opening: Dictionary = {} ## part_id -> true while its mesh is being fetched
var _seed_hidden: Dictionary = {} ## room instance id -> Array of world nodes this room hid
var _was_active := false
var _steadiness := 2 ## index into TwoHandModel.STEADINESS_NAMES, as the tablet last set it


func _ready() -> void:
	add_to_group("room_listeners") # controller.gd tells us when it sent a stray part back (on_part_refused)


func setup(main: Node, view_modes: Node) -> void:
	_main = main
	_view_modes = view_modes


func mates_tool() -> Node:
	return _main.get("_mates_tool") if _main != null else null


func on_part_refused(_part: Node3D, reason: String) -> void:
	status.emit("That part went back: a room's parts stay in the room." if reason == "left_room" else "That part went back: it can't be left inside a room (adding it to the room is not built yet).")


func configure_backend(url: String, key: String) -> void:
	_backend_url = url
	_api_key = key


func room_for_part(part_id: String) -> Node:
	for r in rooms:
		if is_instance_valid(r) and r.part_id == part_id:
			return r
	return null


func is_open_for(part_id: String) -> bool:
	return room_for_part(part_id) != null or _opening.has(part_id)


func toggle_room(part_id: String, label: String, seed_owner_part_id: String = "", seed_occurrence_id: String = "") -> void:
	var existing := room_for_part(part_id)
	if existing != null:
		close_room(existing)
		return
	await open_room(part_id, label, seed_owner_part_id, seed_occurrence_id)


func open_room(part_id: String, label: String, seed_owner_part_id: String = "", seed_occurrence_id: String = "") -> Node:
	## Fetches the Part's own mesh and opens a room for it. Returns the Room, or null (with a status message) if it could not.
	if part_id == "" or is_open_for(part_id):
		return null
	if not RoomRegistry.can_add():
		status.emit("Room limit reached (%d). Close a room, or raise the limit in Settings > Display." % RoomRegistry.max_rooms)
		return null
	if _backend_url == "" or _api_key == "":
		status.emit("No backend configured: rooms open a Part from the backend.")
		return null
	_opening[part_id] = true
	rooms_changed.emit()
	status.emit("Opening a room for %s..." % label)
	var bytes := await _fetch_glb(part_id)
	_opening.erase(part_id)
	if bytes.is_empty():
		rooms_changed.emit()
		return null
	var room := open_from_bytes(bytes, part_id, label, seed_owner_part_id, seed_occurrence_id)
	if room != null:
		# The room's Part's occurrences and Mates, so moves are saved to it and its mates steer; then its parts become touchable.
		var mates := mates_tool()
		if mates != null:
			var loaded: bool = await mates.load_owner_state(part_id)
			if not loaded:
				status.emit("Room for %s is open, but its mates and saved poses could not be read: parts move but are not saved." % label)
		if is_instance_valid(room) and rooms.has(room):
			activate(room)
	return room


func activate(room: Node) -> void:
	## Makes a room a world within the world: its parts become grabbable and a whole-room gesture (grip on empty space inside it) moves, turns and scales
	## its content. (Split out of opening so it waits for the Part's state, and so tests can drive it.)
	room.set_interactive(true)
	var left = _main.get_node_or_null("XROrigin3D/LeftController") if _main != null else null
	var right = _main.get_node_or_null("XROrigin3D/RightController") if _main != null else null
	if room.two_hand == null and left != null and right != null:
		var gesture := TwoHandModel.new()
		gesture.name = "TwoHand"
		room.add_child(gesture)
		gesture.setup(room.content_root, left, right, 0.001, _main.command_stack)
		gesture.min_multiple = ROOM_MIN_MULTIPLE
		gesture.max_multiple = ROOM_MAX_MULTIPLE
		gesture.focus = func(hand: Node3D) -> bool: return is_instance_valid(room) and room.volume.contains(hand.global_position)
		gesture.set_steadiness(_steadiness)
		room.two_hand = gesture
	if _view_modes != null:
		for p in room.parts:
			_view_modes.apply_to(p)


func apply_steadiness(level: int) -> void:
	## The tablet's Steadiness choice, for every room's whole-room gesture too.
	_steadiness = level
	for r in rooms:
		if is_instance_valid(r) and r.two_hand != null:
			r.two_hand.set_steadiness(level)


func focus_room() -> Node:
	## The room the user is standing in (their head is inside its walls), or null for the world: what the tablet's group operations (Hide all, Isolate...)
	## act on.
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return null
	for r in rooms:
		if is_instance_valid(r) and r.volume.contains(cam.global_position):
			return r
	return null


func scope_parts(anchor: Node = null) -> Array:
	## The parts a group operation acts on: those of the anchor's room if the anchor is in one, else of the room the user is standing in, else the world's.
	var room_id := 0
	if anchor != null and anchor.has_meta("room_id"):
		room_id = int(anchor.get_meta("room_id"))
	elif anchor == null:
		var focus := focus_room()
		room_id = focus.get_instance_id() if focus != null else 0
	return RoomRegistry.parts_in_room(get_tree(), room_id) if room_id != 0 else RoomRegistry.world_parts(get_tree())


func open_from_bytes(bytes: PackedByteArray, part_id: String, label: String, seed_owner_part_id: String = "", seed_occurrence_id: String = "") -> Node:
	## The part of opening a room that needs no network: parse the mesh, find a clear spot in front of the user, register the box, hide the world's copy.
	## (Split out so tests/room_manager.gd can drive it with a built glb.)
	if not RoomRegistry.can_add():
		status.emit("Room limit reached (%d). Close a room, or raise the limit in Settings > Display." % RoomRegistry.max_rooms)
		return null
	var room := Room.new()
	# A new room is the 3 m cube (RoomVolume.spawn_size): the content is scaled to fit it, so it never needs to be bigger.
	var size := RoomVolume.spawn_size(Vector3.ZERO)
	if not room.build(bytes, Transform3D.IDENTITY, size, part_id, label):
		room.free()
		status.emit("Couldn't read %s's mesh." % label)
		rooms_changed.emit()
		return null
	var spot = RoomPlacement.find_spot(_eye(), _forward(), size, RoomRegistry.rooms)
	if spot == null:
		room.free()
		status.emit("No clear space for a room here. Walk somewhere roomier or close a room.")
		rooms_changed.emit()
		return null
	room.seed_owner_part_id = seed_owner_part_id
	room.seed_occurrence_id = seed_occurrence_id
	room.volume = RoomVolume.make(spot, size)
	room.transform = Transform3D((spot as Transform3D).basis.orthonormalized(), (spot as Transform3D).origin)
	var slot := RoomRegistry.add_room(room.volume)
	if slot < 0:
		room.free()
		status.emit("Couldn't place a room (limit reached or no clear space).")
		rooms_changed.emit()
		return null
	_main.add_child(room)
	room.register(slot)
	rooms.append(room)
	_hide_seed(room)
	if _view_modes != null:
		for p in room.parts:
			_view_modes.apply_to(p)
	_was_active = true
	status.emit("Room open for %s at %s. Close it from the Assembly Tree." % [label, room.scale_text()])
	rooms_changed.emit()
	return room


func close_room(room: Node) -> void:
	if not is_instance_valid(room):
		return
	_forget_room(room)
	_restore_seed(room)
	rooms.erase(room)
	room.close()
	status.emit("Closed the room for %s." % room.label)
	rooms_changed.emit()


func close_all() -> void:
	for room in rooms.duplicate():
		if is_instance_valid(room):
			_forget_room(room)
			_restore_seed(room)
			room.close()
	rooms.clear()
	rooms_changed.emit()


func on_model_replaced() -> void:
	## main.gd is about to swap the world's model: the nodes a room hid are going away with it, and a room's seed no longer exists.
	_seed_hidden.clear()
	close_all()


func _process(_delta: float) -> void:
	if RoomRegistry.rooms.is_empty():
		if _was_active:
			_was_active = false
			RoomClip.reconcile(_world_parts()) # the last room is gone: give the world its own materials back
		return
	_was_active = true
	var all: Array = _world_parts()
	for r in rooms:
		if is_instance_valid(r):
			all.append_array(r.parts)
	RoomClip.reconcile(all)


func _forget_room(room: Node) -> void:
	## The mates tool stops managing the room's Part. Anything still held from the room is let go of first by closing (set_interactive(false) takes the parts
	## out of the grab group).
	var mates := mates_tool()
	if mates != null:
		mates.drop_owner_state(room.part_id)
	for hand_name in ["XROrigin3D/LeftController", "XROrigin3D/RightController"]:
		var hand = _main.get_node_or_null(hand_name) if _main != null else null
		if hand != null and (room.parts.has(hand.held_node) or room.parts.has(hand.selected_node)):
			hand.reset_interaction()


func _world_parts() -> Array:
	return RoomRegistry.world_parts(get_tree())


func _hide_seed(room: Node) -> void:
	var owners: Dictionary = room.owner_part_ids()
	var hidden: Array = []
	for node in _world_parts():
		if not node.visible or not node.has_meta("owner_part_id"):
			continue
		var owner := str(node.get_meta("owner_part_id"))
		var occ := str(node.get_meta("occurrence_id", ""))
		if owners.has(owner) or (room.seed_occurrence_id != "" and owner == room.seed_owner_part_id and occ == room.seed_occurrence_id):
			node.visible = false
			hidden.append(node)
	_seed_hidden[room.get_instance_id()] = hidden


func _restore_seed(room: Node) -> void:
	for node in _seed_hidden.get(room.get_instance_id(), []):
		if is_instance_valid(node):
			node.visible = true
	_seed_hidden.erase(room.get_instance_id())


func _eye() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	return cam.global_position if cam != null else Vector3(0, 1.6, 0)


func _forward() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	return -cam.global_transform.basis.z if cam != null else Vector3(0, 0, -1)


func _fetch_glb(part_id: String) -> PackedByteArray:
	var url := "%s/document/parts/%s/assembly-mesh.glb?quality=%s&include_hidden=%s" % [_backend_url, part_id, str(_main.quality), str(_main.include_hidden).to_lower()]
	if _main.tier != "":
		url += "&tier=%s" % _main.tier
	var req := HTTPRequest.new()
	add_child(req)
	var result: Array = await _main._get_mesh_result(req, url)
	req.queue_free()
	if result[0] != HTTPRequest.RESULT_SUCCESS or int(result[1]) != 200:
		status.emit("Couldn't load the room's mesh: %s" % _main._http_error_text(int(result[1]), int(result[0]), result[3]))
		return PackedByteArray()
	return result[3]
