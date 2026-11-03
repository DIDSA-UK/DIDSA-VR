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
signal preview_changed(room) ## a room's world preview changed mode or availability (the console button follows)
signal delete_state_changed ## the Delete-selected button's text changed (armed, disarmed): every button showing it follows

const BackendSession := preload("res://scripts/backend_session.gd")
const Room := preload("res://scripts/room/room.gd")
const RoomVolume := preload("res://scripts/room/room_volume.gd")
const GroupIndex := preload("res://scripts/group_index.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const NativeCompose := preload("res://scripts/native_compose.gd")
const RoomClip := preload("res://scripts/room/room_clip.gd")
const RoomPlacement := preload("res://scripts/room/room_placement.gd")
const TwoHandModel := preload("res://scripts/two_hand_model.gd")
const RoomEdit := preload("res://scripts/room/room_edit.gd")
const DropCue := preload("res://scripts/room/drop_cue.gd")
const RoomGhost := preload("res://scripts/room/room_ghost.gd")
const RoomConsole := preload("res://scripts/room/room_console.gd")
const WorldPreview := preload("res://scripts/room/world_preview.gd")
const RoomThumbnail := preload("res://scripts/room/room_thumbnail.gd")
const NewDocument := preload("res://scripts/design_table/new_document.gd")

const PLACE_CONFIRM := "trigger_click" ## placing a room: the right trigger drops it where the laser meets the floor,
const PLACE_CANCEL := "by_button" ## B / Y gives up

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
var pedestal := true ## the faint column from each room console down to the floor (Settings > Appearance)
var glass := true ## the see-through wall look for new and open rooms (Settings > Appearance); off = wireframe only
var edit: RefCounted ## room_edit.gd: adding and deleting parts (made on first use from the design table's CAD helper; tests set a fake)
var _busy_edit := false ## one membership change at a time (each ends in a refresh of the room)
var _cued: Dictionary = {} ## hand -> the part it carries that currently shows the drop cue
var preview_message := "" ## what the last Push / mode change had to say (the console shows it)
var previews: Dictionary = {} ## room instance id -> its WorldPreview
var preview_live := true ## the previews follow the rooms' parts as they move (Settings: Auto-update world preview)
var preview_pulse := false ## the previews breathe (Settings: Pulse world preview)
var _away_from: Variant = null ## the user's position before "To world" flew them to a placement (a Transform3D), or null
var _placing: Dictionary = {} ## while a room is being placed: part_id, label, seed_owner, seed_occurrence, token, hand, ghost, size, bytes, spot (Transform3D or null), confirmed
var _place_token := 0
var _steadiness := 2 ## index into TwoHandModel.STEADINESS_NAMES, as the tablet last set it
var thumbnails: Node ## room_thumbnail.gd: each room's picture for the tablet's Rooms page


func _ready() -> void:
	add_to_group("room_listeners") # controller.gd tells us when it sent a stray part back (on_part_refused)
	thumbnails = RoomThumbnail.new()
	thumbnails.name = "Thumbnails"
	add_child(thumbnails)


func thumbnail(room: Node) -> Texture2D:
	## The room's picture for its Rooms page tile (rendered on first ask, cached until its parts change). Null: empty, or nothing renders here.
	return await thumbnails.render(room) if thumbnails != null else null


func new_room() -> bool:
	## The Rooms page's New room: a new, empty sub-assembly placed on the loaded assembly's root (a new Part and an occurrence of it, the same shape
	## as the design table's New part), then summoned like any room (aim at the floor, trigger). Carry parts into it, or Files > Add while standing in
	## it. True once the placement has started.
	var root: String = _main.current_root_part_id() if _main != null and _main.has_method("current_root_part_id") else ""
	if root == "":
		status.emit("Open or start an assembly first (Files): a new room is a sub-assembly inside it.")
		return false
	if not RoomRegistry.can_add():
		status.emit("Room limit reached (%d). Close a room, or raise the limit in Settings > Display." % RoomRegistry.max_rooms)
		return false
	var e := edit_api()
	if e == null or _backend_url == "" or _api_key == "":
		status.emit("No backend configured: a room holds a Part from the backend.")
		return false
	if _busy_edit:
		status.emit("Still working on the last change, try again in a moment.")
		return false
	_busy_edit = true
	var maker := NewDocument.new(Callable(e.api, "request"))
	var existing: Array = await e.occurrences_of(root, true)
	var name := "Sub-assembly %d" % (existing.size() + 1)
	status.emit("Making %s..." % name)
	var made: Dictionary = await maker.add_part(root, name, {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0})
	_busy_edit = false
	if not made["ok"]:
		status.emit("Couldn't make a new room: %s" % str(made["error"]))
		return false
	e.forget(root)
	_mark_dirty()
	if _main.has_method("refresh_assembly_tree"):
		_main.refresh_assembly_tree()
	await begin_placement(str(made["part_id"]), name, root, str(made["occurrence_id"]))
	return true


func bring_to_me(room: Node) -> bool:
	## The Rooms page's Bring to me: the room (box and content together; a minimised one comes back full size) to a clear spot in front of the user.
	if not is_instance_valid(room) or not rooms.has(room):
		return false
	var size: Vector3 = room.full_size()
	var others: Array = RoomRegistry.rooms.filter(func(v) -> bool: return v != null and v != room.volume)
	var spot = RoomPlacement.find_spot(_eye(), _forward(), size, others)
	if spot == null or not room.bring_to(spot):
		status.emit("No clear space for %s in front of you. Turn or walk somewhere roomier." % room.label)
		return false
	status.emit("Brought %s to you." % room.label)
	rooms_changed.emit()
	return true


func setup(main: Node, view_modes: Node) -> void:
	_main = main
	_view_modes = view_modes


func mates_tool() -> Node:
	return _main.get("_mates_tool") if _main != null else null


func on_part_refused(part: Node3D, reason: String, dropped: Transform3D = Transform3D.IDENTITY) -> void:
	## controller.gd sent a stray part back. A room's part let go outside its room stays a refusal; a part let go INSIDE a room (the world's, or another
	## room's) was dropped there to be added: it is copied into that room's assembly (the original has gone back to where it was picked up).
	if reason != "entered_room":
		status.emit("That part went back: a room's parts stay in the room.")
		return
	var centre: Vector3 = dropped * (part as MeshInstance3D).get_aabb().get_center() if part is MeshInstance3D else dropped.origin
	var room := room_for_slot(RoomRegistry.room_at(centre))
	if room == null or not room.interactive:
		status.emit("That part went back: the room isn't ready yet (its parts are still loading).")
		return
	add_to_room(room, part, dropped)


func minimise_room(room: Node) -> void:
	if not is_instance_valid(room) or room.minimised:
		return
	_release_hands_from(room)
	room.minimise()
	status.emit("%s minimised: restore it from the Rooms page." % room.label)
	rooms_changed.emit()


func restore_room(room: Node) -> void:
	if not is_instance_valid(room) or not room.minimised:
		return
	if room.restore():
		status.emit("%s restored." % room.label)
	else:
		status.emit("Can't restore %s: another room is in its space. Close or move that room first." % room.label)
	rooms_changed.emit()


func room_for_slot(slot: int) -> Node:
	for r in rooms:
		if is_instance_valid(r) and r.volume.slot == slot:
			return r
	return null


func edit_api() -> RefCounted:
	## The room editor, made on first use; the mesh settings follow the app's own (quality, tier, hidden parts).
	if edit == null and _main != null and _main.get("design_table") != null:
		edit = RoomEdit.new(_main.design_table.api)
	if edit != null and _main != null and _main.get("quality") != null:
		edit.mesh_quality = _main.quality
		edit.mesh_tier = _main.tier
		edit.mesh_include_hidden = _main.include_hidden
	return edit


func add_to_room(room: Node, node: Node3D, dropped: Transform3D) -> bool:
	## Drop-to-add: a new occurrence of the part `node` shows is put in the room's Part at the pose it was let go at, the room's mesh is reloaded, and it is
	## one undo step. The source stays where it was (a copy; delete the seed afterwards if you want a move).
	if _busy_edit:
		status.emit("Still working on the last change, try again in a moment.")
		return false
	var e := edit_api()
	if e == null:
		status.emit("Adding to a room needs the backend.")
		return false
	_busy_edit = true
	status.emit("Adding it to the room...")
	var result: Dictionary = await e.add_copy(room.part_id, node, dropped, room.content_root, "")
	if not result["ok"]:
		_busy_edit = false
		status.emit(str(result["error"]))
		return false
	var snapshot := await _snapshot_of(room.part_id, str(result["occurrence_id"]))
	await refresh_room(room)
	_mark_room_changed(room)
	_busy_edit = false
	_mark_dirty()
	status.emit("Added to the room. (A copy: the original is where it was; delete it if you meant to move it.)")
	_push_undo("add to room", room.part_id, str(result["occurrence_id"]), snapshot, true)
	return true


func on_group_refused(info: Dictionary, reason: String) -> void:
	## controller.gd sent a stray sub-assembly (a GroupSet) back. One let go INSIDE a room (from the world or another room) is copied into that room's
	## assembly, as a single part is: a new occurrence of the sub-assembly's Part, placed where its origin landed. Out of its own room it just stays refused.
	if reason != "entered_room":
		status.emit("%s went back: a room's parts stay in the room." % info["label"])
		return
	var room := room_for_slot(RoomRegistry.room_at(info["centre"]))
	if room == null or not room.interactive:
		status.emit("%s went back: the room isn't ready yet (its parts are still loading)." % info["label"])
		return
	add_group_to_room(room, info)


func add_group_to_room(room: Node, info: Dictionary) -> bool:
	if _busy_edit:
		status.emit("Still working on the last change, try again in a moment.")
		return false
	var e := edit_api()
	if e == null:
		status.emit("Adding to a room needs the backend.")
		return false
	_busy_edit = true
	status.emit("Adding %s to the room..." % info["label"])
	var result: Dictionary = await e.add_group(room.part_id, info, room.content_root)
	if not result["ok"]:
		_busy_edit = false
		status.emit(str(result["error"]))
		return false
	var snapshot := await _snapshot_of(room.part_id, str(result["occurrence_id"]))
	await refresh_room(room)
	_mark_room_changed(room)
	_busy_edit = false
	_mark_dirty()
	status.emit("Added %s to the room. (A copy: the original is where it was; delete it if you meant to move it.)" % info["label"])
	_push_undo("add %s to room" % info["label"], room.part_id, str(result["occurrence_id"]), snapshot, true)
	return true


func add_file_to_room(room: Node, path: String) -> bool:
	## The Files tab's Add while standing in a room: the file's Part becomes a new occurrence in the room's Part (at its origin; move it from there).
	if _busy_edit:
		status.emit("Still working on the last change, try again in a moment.")
		return false
	var e := edit_api()
	var composed: Dictionary = _main.compose_native(path) if _main != null and _main.has_method("compose_native") else NativeCompose.compose(path) # the files a sub-assembly references come too
	var text: String = composed["text"]
	if e == null or not composed["ok"] or text == "":
		status.emit("Couldn't read %s as a native file." % path.get_file())
		return false
	_busy_edit = true
	status.emit("Adding %s to the room..." % path.get_file())
	var pose := {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}
	var result: Dictionary = await e.add_file(room.part_id, text, pose, path.get_file().get_basename())
	if not result["ok"]:
		_busy_edit = false
		status.emit(str(result["error"]))
		return false
	var snapshot := await _snapshot_of(room.part_id, str(result["occurrence_id"]))
	await refresh_room(room)
	_mark_room_changed(room)
	_busy_edit = false
	_mark_dirty()
	status.emit(("Added %s to the room.%s" % [path.get_file(), NativeCompose.unresolved_note(composed)]) if str(result["error"]) == "" else str(result["error"]))
	_push_undo("add %s" % path.get_file(), room.part_id, str(result["occurrence_id"]), snapshot, true)
	return true


func delete_occurrence(owner_part_id: String, occurrence_id: String, label: String) -> Dictionary:
	## Deletes a placed part from its owner Part (cascading its Mates, which the answer counts) and refreshes whatever shows it: the room for that Part, or
	## the world. One undo step puts it back (not the Mates). Returns the editor's answer.
	if _busy_edit:
		status.emit("Still working on the last change, try again in a moment.")
		return {"ok": false}
	var e := edit_api()
	if e == null:
		status.emit("Deleting needs the backend.")
		return {"ok": false}
	_busy_edit = true
	var result: Dictionary = await e.delete_occurrence(owner_part_id, occurrence_id)
	if not result["ok"]:
		_busy_edit = false
		status.emit(str(result["error"]))
		return result
	await _refresh_for_owner(owner_part_id)
	_busy_edit = false
	_mark_dirty()
	var mates := int(result["mates_removed"])
	status.emit("Deleted %s%s." % [label, "" if mates == 0 else " and %d mate%s that used it" % [mates, "" if mates == 1 else "s"]])
	_push_undo("delete %s" % label, owner_part_id, occurrence_id, result["snapshot"], false)
	return result


func index_world() -> void:
	## Works out which sub-assembly each of the world's parts sits in (group_index.gd), so a grip or the laser can take a whole one. A coroutine; the parts
	## carry nothing until it lands, and then behave exactly as before for any it couldn't place.
	var root: String = _main.current_root_part_id() if _main != null else ""
	var e := edit_api()
	if root == "" or e == null:
		return
	await GroupIndex.index(e, root, RoomRegistry.world_parts(get_tree()), _main.appearance_patterns() if _main != null and _main.has_method("appearance_patterns") else {})


func index_room(room) -> void:
	var e := edit_api()
	if e == null or not is_instance_valid(room):
		return
	await GroupIndex.index(e, room.part_id, room.parts, _main.appearance_patterns() if _main != null and _main.has_method("appearance_patterns") else {})


# --- world preview (world_preview.gd) ---

func preview_of(room: Node) -> Node:
	## The room's world preview, made on first use.
	var key := room.get_instance_id()
	if not previews.has(key) or not is_instance_valid(previews[key]):
		var wp := WorldPreview.new()
		wp.live = preview_live
		wp.pulse = preview_pulse
		add_child(wp)
		wp.setup(room, mates_tool())
		previews[key] = wp
	return previews[key]


func set_preview_mode(room: Node, mode: int) -> bool:
	## Hidden / Ghost / Preview of the room's world copy. A coroutine: the room's and the world's parts must know their place in the tree first. False, with a
	## message, if there is no placement in the world to show it at (a room opened on something that is not an instance there).
	if not is_instance_valid(room):
		return false
	var wp := preview_of(room)
	if mode != WorldPreview.Mode.HIDDEN:
		await _ensure_indexed(room)
		if not is_instance_valid(room):
			return false
		wp.rebuild(_world_parts())
		if not wp.available():
			preview_message = "Nothing to show: %s isn't placed in the world that is open." % room.label
			status.emit(preview_message)
			preview_changed.emit(room)
			return false
	var ok: bool = wp.set_mode(mode)
	preview_changed.emit(room)
	return ok


func cycle_preview(room: Node) -> void:
	var wp := preview_of(room)
	await set_preview_mode(room, (int(wp.mode) + 1) % 3)
	if is_instance_valid(room) and not wp.available() and wp.mode != WorldPreview.Mode.HIDDEN:
		wp.set_mode(WorldPreview.Mode.HIDDEN)


func push_preview(room: Node) -> void:
	## "Push to world": the preview shows the room's parts as they are now (and, with auto-update off, only as they are now).
	var wp := preview_of(room)
	if wp.mode != WorldPreview.Mode.PREVIEW:
		await set_preview_mode(room, WorldPreview.Mode.PREVIEW)
	if is_instance_valid(room) and wp.mode == WorldPreview.Mode.PREVIEW:
		wp.push()
		preview_message = "Pushed %d changed part%s to the world preview." % [wp.changed_count(), "" if wp.changed_count() == 1 else "s"]
		status.emit(preview_message)
		preview_changed.emit(room)


func set_preview_live(on: bool) -> void:
	preview_live = on
	for wp in previews.values():
		if is_instance_valid(wp):
			wp.live = on


func set_preview_pulse(on: bool) -> void:
	preview_pulse = on
	for wp in previews.values():
		if is_instance_valid(wp):
			wp.pulse = on
			wp.rebuild(_world_parts())


func _ensure_indexed(room: Node) -> void:
	var tagged := false
	for n in _world_parts():
		if n.has_meta("group_path"):
			tagged = true
			break
	if not tagged:
		await index_world()
	var room_tagged: bool = is_instance_valid(room) and not room.parts.is_empty() and room.parts[0].has_meta("group_path")
	if not room_tagged:
		await index_room(room)


func _rebuild_previews() -> void:
	## After the world's or a room's parts were replaced: the placements are found again for every preview that is showing something.
	for key in previews.keys():
		var wp = previews[key]
		if is_instance_valid(wp) and wp.mode != WorldPreview.Mode.HIDDEN and is_instance_valid(wp.room):
			wp.rebuild(_world_parts())
			if not wp.available():
				wp.set_mode(WorldPreview.Mode.HIDDEN)
			preview_changed.emit(wp.room)


func fly_to_world(room: Node) -> bool:
	## Takes the user to the room's world placement (the nearest one), standing back from it, and back to where they were on a second press.
	var origin: Node3D = _main.get_node_or_null("XROrigin3D") if _main != null else null
	var wp := preview_of(room)
	if origin == null or not wp.available():
		return false
	if _away_from != null:
		origin.global_transform = _away_from
		_away_from = null
		preview_changed.emit(room)
		return true
	var target: Vector3 = wp.instances[wp.nearest_instance(room.global_position)]["centre"]
	var eye := _eye()
	var away := eye - target
	away.y = 0.0
	away = away.normalized() if away.length() > 0.01 else Vector3(0, 0, 1)
	var stand: Vector3 = target + away * 2.0
	_away_from = origin.global_transform
	origin.global_position += Vector3(stand.x - eye.x, 0.0, stand.z - eye.z)
	preview_changed.emit(room)
	return true


func is_away() -> bool:
	return _away_from != null


func refresh_room(room: Node) -> bool:
	## Re-reads the room's Part from the backend and swaps the room's content for it (scale and position kept), then re-reads its state for the mates tool.
	if not is_instance_valid(room):
		return false
	var e := edit_api()
	var bytes: PackedByteArray = await e.fetch_part_glb(room.part_id)
	if not is_instance_valid(room):
		return false
	if bytes.is_empty():
		status.emit("Couldn't refresh the room from the backend.")
		return false
	_release_hands_from(room)
	room.reload(bytes)
	var mates := mates_tool()
	if mates != null:
		await mates.load_owner_state(room.part_id)
	if _view_modes != null and is_instance_valid(room):
		for p in room.parts:
			_view_modes.apply_to(p)
	await index_room(room)
	_rebuild_previews()
	return true


func _refresh_for_owner(owner_part_id: String) -> void:
	## Something changed under this Part: its room (if open) is reloaded and marked, otherwise the world, which shows it, is.
	var room := room_for_part(owner_part_id)
	if room != null:
		await refresh_room(room)
		_mark_room_changed(room)
	elif _main != null and _main.has_method("reload_world_model"):
		await _main.reload_world_model()


var _delete_armed := ""
var _delete_armed_until_ms := 0
var _delete_text := ""
const DELETE_CONFIRM_MS := 4000


func delete_selected_label() -> String:
	## The text of every "Delete selected part" button: that, or "Sure? Delete X (N mates)" for a few seconds after the first press.
	if _delete_armed != "" and Time.get_ticks_msec() < _delete_armed_until_ms:
		return _delete_text
	return "Delete selected part"


func delete_selected_press() -> Dictionary:
	## One press of "Delete selected part" (the console's and the tablet's): the first arms it for a few seconds, naming the part and the Mates that would go,
	## the second deletes it. {status: none / unavailable / armed / deleted / failed, message}. The buttons read delete_selected_label() when
	## delete_state_changed fires.
	var part: Node3D = _main.current_selected_part() if _main != null and _main.has_method("current_selected_part") else null
	if part == null:
		return {"status": "none", "message": "Select a part first (point at it and pull the trigger)."}
	var owner := str(part.get_meta("owner_part_id", ""))
	var occ := str(part.get_meta("occurrence_id", ""))
	if owner == "" or occ == "":
		return {"status": "unavailable", "message": "That part can't be deleted (it is the assembly's own content)."}
	var now := Time.get_ticks_msec()
	if _delete_armed == occ and now < _delete_armed_until_ms:
		_delete_armed = ""
		delete_state_changed.emit()
		var result: Dictionary = await delete_occurrence(owner, occ, str(part.name))
		return {"status": "deleted" if result.get("ok", false) else "failed", "message": ""}
	_delete_armed = occ
	_delete_armed_until_ms = now + DELETE_CONFIRM_MS
	_delete_text = "Sure? Delete %s" % str(part.name)
	delete_state_changed.emit()
	var e := edit_api()
	if e != null:
		var mates: int = await e.mates_naming(owner, occ)
		if _delete_armed == occ:
			_delete_text = "Sure? Delete %s%s" % [str(part.name), "" if mates == 0 else " (%d mate%s)" % [mates, "" if mates == 1 else "s"]]
			delete_state_changed.emit()
	return {"status": "armed", "message": ""}


func _mark_room_changed(room) -> void: # (untyped: a room closed meanwhile is a freed object, which a typed argument would reject)
	## The room's assembly changed. If the room was closed while that was being refreshed it can't carry the mark, so the world is reloaded now instead
	## (closing it earlier did not know the change was coming).
	if is_instance_valid(room):
		room.members_changed = true
	elif _main != null and _main.has_method("reload_world_model"):
		_main.reload_world_model()


func _snapshot_of(owner_part_id: String, occurrence_id: String) -> Dictionary:
	var e := edit_api()
	for row in await e.occurrences_of(owner_part_id, true):
		if str(row.get("id", "")) == occurrence_id:
			return (row as Dictionary).duplicate(true)
	return {}


func _push_undo(label: String, owner_part_id: String, occurrence_id: String, snapshot: Dictionary, was_add: bool) -> void:
	## One step on the shared undo stack. Undoing an add deletes it again; undoing a delete puts it back with everything it had (not its Mates).
	var stack = _main.get("command_stack") if _main != null else null
	if stack == null:
		return
	var undo_it := func() -> void: _replay(owner_part_id, occurrence_id, snapshot, not was_add)
	var redo_it := func() -> void: _replay(owner_part_id, occurrence_id, snapshot, was_add)
	stack.push(label, undo_it, redo_it, true)


func _replay(owner_part_id: String, occurrence_id: String, snapshot: Dictionary, put_back: bool) -> void:
	var e := edit_api()
	if e == null or snapshot.is_empty():
		return
	if put_back:
		var r: Dictionary = await e.restore_occurrence(owner_part_id, snapshot)
		if not r["ok"]:
			status.emit(str(r["error"]))
			return
	else:
		await e.remove_added(owner_part_id, occurrence_id)
	await _refresh_for_owner(owner_part_id)
	_mark_dirty()


func _mark_dirty() -> void:
	if _main != null and _main.has_method("mark_dirty"):
		_main.mark_dirty()
	if _main != null and _main.has_method("refresh_assembly_tree"):
		_main.refresh_assembly_tree() # the tree window's list is out of date


func _release_hands_from(room: Node) -> void:
	for hand_name in ["XROrigin3D/LeftController", "XROrigin3D/RightController"]:
		var hand = _main.get_node_or_null(hand_name) if _main != null else null
		if hand != null and (room.parts.has(hand.held_node) or room.parts.has(hand.selected_node)):
			hand.reset_interaction()


func _update_drop_cues() -> void:
	## While a hand carries a part whose middle is inside a room that can take it (and is not the room it already belongs to), that part shows the corner
	## brackets in the room's colour: letting go will add it there.
	for hand_name in ["XROrigin3D/LeftController", "XROrigin3D/RightController"]:
		var hand = _main.get_node_or_null(hand_name) if _main != null else null
		if hand == null:
			continue
		var held = hand.held_node
		var previous = _cued.get(hand)
		if previous != null and previous != held:
			DropCue.hide_on(previous)
			_cued.erase(hand)
		if held == null or not (held is MeshInstance3D) or RoomRegistry.rooms.is_empty():
			continue
		var target := RoomRegistry.room_at(RoomRegistry.part_centre(held))
		var own := RoomRegistry.slot_of(held) if RoomRegistry.is_room_part(held) else -1
		var room := room_for_slot(target) if target != -1 and target != own else null
		if room != null and room.interactive:
			DropCue.show_on(held, room.colour)
			_cued[hand] = held
		else:
			DropCue.hide_on(held)

func configure_backend(url: String, key: String) -> void:
	_backend_url = url
	_api_key = key


func room_for_part(part_id: String) -> Node:
	for r in rooms:
		if is_instance_valid(r) and r.part_id == part_id:
			return r
	return null


func is_open_for(part_id: String) -> bool:
	return room_for_part(part_id) != null or _opening.has(part_id) or is_placing_for(part_id)


func is_placing_for(part_id: String) -> bool:
	return not _placing.is_empty() and _placing["part_id"] == part_id


func toggle_room(part_id: String, label: String, seed_owner_part_id: String = "", seed_occurrence_id: String = "") -> void:
	## The tree's Room button: closes the room if open, gives up the placement if one is in progress, else starts placing one.
	if is_placing_for(part_id):
		cancel_placement()
		return
	var existing := room_for_part(part_id)
	if existing != null:
		close_room(existing)
		return
	await begin_placement(part_id, label, seed_owner_part_id, seed_occurrence_id)


func begin_placement(part_id: String, label: String, seed_owner_part_id: String = "", seed_occurrence_id: String = "") -> void:
	## Summoning a room: aim the right laser at the floor where its middle should go (a ghost follows, red where it can't), trigger to drop it, B / Y to
	## give up. The Part's mesh loads while you aim. With no laser to aim (no headset: the desktop preview) it opens in front of the user, as before.
	if part_id == "" or is_open_for(part_id):
		return
	var hand = _main.get_node_or_null("XROrigin3D/RightController") if _main != null else null
	var xr = _main.get("xr_interface") if _main != null else null
	if hand == null or xr == null or not xr.is_initialized():
		await open_room(part_id, label, seed_owner_part_id, seed_occurrence_id)
		return
	if not RoomRegistry.can_add():
		status.emit("Room limit reached (%d). Close a room, or raise the limit in Settings > Display." % RoomRegistry.max_rooms)
		return
	var e := edit_api()
	if e == null or _backend_url == "" or _api_key == "":
		status.emit("No backend configured: rooms open a Part from the backend.")
		return
	cancel_placement()
	_place_token += 1
	var token := _place_token
	var size := RoomVolume.spawn_size(Vector3.ZERO)
	var ghost := RoomGhost.new()
	ghost.setup(size * 0.5, Room.colour_for(RoomRegistry.next_slot()))
	_main.add_child(ghost)
	_placing = {"part_id": part_id, "label": label, "seed_owner": seed_owner_part_id, "seed_occurrence": seed_occurrence_id, "token": token,
		"hand": hand, "ghost": ghost, "size": size, "bytes": PackedByteArray(), "spot": null, "confirmed": false}
	hand.set_meta("room_placing", true)
	hand.button_pressed.connect(_on_placement_button)
	status.emit("Aim your right laser at the floor where the room should go, trigger to drop it, B to cancel.")
	rooms_changed.emit()
	var bytes: PackedByteArray = await e.fetch_part_glb(part_id)
	if _placing.is_empty() or int(_placing["token"]) != token:
		return # given up (or replaced) while the mesh was loading
	if bytes.is_empty():
		status.emit("Couldn't load %s's mesh." % label)
		_end_placement()
		return
	_placing["bytes"] = bytes
	if _placing["confirmed"]:
		_complete_placement()


func cancel_placement() -> void:
	if _placing.is_empty():
		return
	_end_placement()
	status.emit("Placement cancelled.")


func _end_placement() -> void:
	var hand = _placing.get("hand")
	if hand != null and is_instance_valid(hand):
		hand.set_meta("room_placing", false)
		if hand.button_pressed.is_connected(_on_placement_button):
			hand.button_pressed.disconnect(_on_placement_button)
	var ghost = _placing.get("ghost")
	if ghost != null and is_instance_valid(ghost):
		ghost.queue_free()
	_placing = {}
	rooms_changed.emit()


func _on_placement_button(action_name: String) -> void:
	if _placing.is_empty():
		return
	if action_name == PLACE_CANCEL:
		cancel_placement()
	elif action_name == PLACE_CONFIRM:
		if _placing["spot"] == null:
			status.emit("The room can't go there: aim at clear floor (red means it would overlap another room).")
			var hand = _placing["hand"]
			hand.trigger_haptic_pulse("haptic", 0.0, 0.6, 0.12, 0.0)
			return
		_placing["confirmed"] = true
		_placing["final"] = _placing["spot"]
		(_placing["ghost"] as Node3D).visible = false
		if (_placing["bytes"] as PackedByteArray).is_empty():
			status.emit("Loading %s's mesh..." % _placing["label"])
		else:
			_complete_placement()


func _complete_placement() -> void:
	var p := _placing
	_end_placement()
	var room := open_from_bytes(p["bytes"], p["part_id"], p["label"], p["seed_owner"], p["seed_occurrence"], p["final"])
	if room != null:
		await _ready_room(room, p["part_id"], p["label"])


func _update_placement() -> void:
	## Each frame while placing: the ghost sits where the right laser meets the floor, turned to face the user; red if the room would overlap another.
	if _placing.is_empty():
		return
	var hand = _placing["hand"]
	if not is_instance_valid(hand):
		_end_placement()
		return
	var ghost: Node3D = _placing["ghost"]
	if _placing["confirmed"]:
		return
	var hit = RoomPlacement.floor_hit(hand.global_position, -hand.global_transform.basis.z.normalized())
	if hit == null:
		ghost.visible = false
		_placing["spot"] = null
		return
	var size: Vector3 = _placing["size"]
	var spot := RoomPlacement.transform_at(hit, _eye(), size)
	var clear := not RoomRegistry.would_overlap(RoomVolume.make(spot, size))
	ghost.transform = spot
	ghost.visible = true
	ghost.set_valid(clear)
	_placing["spot"] = spot if clear else null


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
	var waited := 0
	while _main != null and _main.get("_load_busy") == true and waited < 900:
		await get_tree().process_frame # the world is being re-read (a room was just closed after changes): its seed nodes are about to be replaced
		waited += 1
	_opening[part_id] = true
	rooms_changed.emit()
	status.emit("Opening a room for %s..." % label)
	var bytes: PackedByteArray = await edit_api().fetch_part_glb(part_id)
	if bytes.is_empty():
		status.emit("Couldn't load %s's mesh." % label)
	_opening.erase(part_id)
	if bytes.is_empty():
		rooms_changed.emit()
		return null
	var room := open_from_bytes(bytes, part_id, label, seed_owner_part_id, seed_occurrence_id)
	if room != null:
		await _ready_room(room, part_id, label)
	return room


func _ready_room(room: Node, part_id: String, label: String) -> void:
	## The room's Part's occurrences and Mates, so moves are saved to it and its mates steer; then its parts become touchable.
	var mates := mates_tool()
	if mates != null:
		var loaded: bool = await mates.load_owner_state(part_id)
		if not loaded:
			status.emit("Room for %s is open, but its mates and saved poses could not be read: parts move but are not saved." % label)
	if is_instance_valid(room) and rooms.has(room):
		activate(room)
		index_room(room)


func activate(room: Node) -> void:
	## Makes a room a world within the world: its parts become grabbable and a whole-room gesture (grip on empty space inside it) moves, turns and scales
	## its content. (Split out of opening so it waits for the Part's state, and so tests can drive it.)
	room.set_interactive(true)
	_make_console(room)
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


func _make_console(room: Node) -> void:
	## The room's own console, beside it on the user's side. Needs the headset nodes (hands and head); tests without them skip it.
	if room.console != null or _main == null:
		return
	var left = _main.get_node_or_null("XROrigin3D/LeftController")
	var right = _main.get_node_or_null("XROrigin3D/RightController")
	var camera = _main.get_node_or_null("XROrigin3D/XRCamera3D")
	if left == null or right == null or camera == null:
		return
	var console := RoomConsole.new()
	console.name = "Console"
	room.add_child(console)
	console.pedestal_enabled = pedestal
	console.setup_console(room, self, _main, left, right, camera)
	room.console = console


func set_pedestal(on: bool) -> void:
	pedestal = on
	for r in rooms:
		if is_instance_valid(r) and r.console != null:
			r.console.set_pedestal(on)


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


func open_from_bytes(bytes: PackedByteArray, part_id: String, label: String, seed_owner_part_id: String = "", seed_occurrence_id: String = "", placement: Variant = null) -> Node:
	## The part of opening a room that needs no network: parse the mesh, put the room where the user chose (`placement`, a Transform3D) or else find a clear
	## spot in front of them, register the box, hide the world's copy. (Split out so tests/room_manager.gd can drive it with a built glb.)
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
	var spot = placement if placement is Transform3D else RoomPlacement.find_spot(_eye(), _forward(), size, RoomRegistry.rooms)
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
	room.glass = glass
	_main.add_child(room)
	room.register(slot)
	rooms.append(room)
	_hide_seed(room)
	if _view_modes != null:
		for p in room.parts:
			_view_modes.apply_to(p)
	_was_active = true
	status.emit("Room open for %s at %s. Close it from its console or the Rooms tile." % [label, room.scale_text()])
	rooms_changed.emit()
	return room


func close_room(room: Node) -> void:
	if not is_instance_valid(room):
		return
	_forget_room(room)
	_restore_seed(room)
	_drop_preview(room)
	if thumbnails != null:
		thumbnails.forget(room)
	var stale: bool = room.members_changed
	rooms.erase(room)
	room.close()
	status.emit("Closed the room for %s." % room.label)
	rooms_changed.emit()
	if stale and _main != null and _main.has_method("reload_world_model"):
		_main.reload_world_model() # parts were added or deleted in it: the world's own copies of this Part are out of date


func _drop_preview(room: Node) -> void:
	var key := room.get_instance_id()
	if previews.has(key):
		if is_instance_valid(previews[key]):
			previews[key].queue_free()
		previews.erase(key)


func close_all() -> void:
	for room in rooms.duplicate():
		if is_instance_valid(room):
			_forget_room(room)
			_restore_seed(room)
			_drop_preview(room)
			room.close()
	rooms.clear()
	rooms_changed.emit()


func on_model_replaced(keep_rooms: bool = false) -> void:
	## main.gd is about to swap the world's model. Normally (a different file is opening) every room closes: its Part may not exist in the new model. When
	## the SAME document is merely being re-read (parts were added or deleted, main.reload_world_model) the rooms stay, and reseed_rooms() hides their
	## new world copies afterwards: closing one room must not close the others.
	_seed_hidden.clear()
	if not keep_rooms:
		close_all()


func reseed_rooms() -> void:
	## After the world's model was re-read: the nodes each open room had hidden were replaced, so hide the new copies.
	for r in rooms:
		if is_instance_valid(r):
			_seed_hidden.erase(r.get_instance_id())
			_hide_seed(r)
	if not previews.is_empty():
		await index_world()
		_rebuild_previews()


func set_glass(on: bool) -> void:
	glass = on
	for r in rooms:
		if is_instance_valid(r):
			r.set_glass(on)


func _update_walls() -> void:
	## The grid in each room's glass walls fades in near the user's hands.
	if rooms.is_empty() or _main == null:
		return
	var hands: Array = []
	for hand_name in ["XROrigin3D/LeftController", "XROrigin3D/RightController"]:
		var hand = _main.get_node_or_null(hand_name)
		if hand != null:
			hands.append(hand.global_position)
	for r in rooms:
		if is_instance_valid(r):
			r.update_reveal(hands)
			if r.handles != null:
				r.handles.update_visibility(hands)


func _process(_delta: float) -> void:
	_update_placement()
	_update_walls()
	_update_drop_cues()
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
	## The mates tool stops managing the room's Part, and anything still held from the room is let go of.
	var mates := mates_tool()
	if mates != null:
		mates.drop_owner_state(room.part_id)
	_release_hands_from(room)


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
