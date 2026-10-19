extends RefCounted
## Puts parts under the room clip: every part, the world's and each room's, has to wear shaders/section_clip.gdshader once rooms exist, because a
## plain glTF StandardMaterial3D cannot discard by a uniform. This is the section tool's wrap (section_tool.gd), kept apart so the two do not fight:
## `assign()` installs the clip material (carrying the part's colour) and sets the part's `room_slot` (a per-INSTANCE shader parameter, so the part's
## edge lines and overlays, which are child nodes with their own materials, carry it too: `sync_node`) and its `room_slot` meta; `release()` puts the
## part's own material back. section_tool.gd's wrap ADOPTS a part already wearing this material instead of replacing it (and losing the slot).

const ClipShader := preload("res://shaders/section_clip.gdshader")
const ClipLook := preload("res://scripts/clip_look.gd") ## the part's whole look in the clip shader, per surface for a part split by appearance
const ClipGlobals := preload("res://scripts/clip_globals.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")

const WRAPPED := "room_clip_material" ## meta: the ShaderMaterial we installed as the part's material_override
const PRIOR := "room_clip_prior" ## meta: whatever material_override the part had before (Material or null)


static func assign(part: MeshInstance3D, slot: int) -> void:
	## slot -1 = the world, >= 0 = that room.
	ClipGlobals.ensure()
	part.set_meta(RoomRegistry.META, slot)
	if ClipLook.per_surface(part):
		# Split by appearance: each surface wears its own look's clip material (material_override stays empty).
		if not ClipLook.surfaces_wrapped(part):
			ClipLook.wrap_surfaces(part)
	elif not ClipLook.is_clip(part.material_override):
		var prior: Material = part.material_override
		var mat := ClipLook.clip_for(prior, part)
		part.set_meta(PRIOR, prior)
		part.set_meta(WRAPPED, mat)
		part.material_override = mat
	part.set_instance_shader_parameter("room_slot", slot)
	sync_children(part)


static func sync_node(part: Node, node: Node) -> void:
	## Gives one child of a part (its EdgeLines, a hover / pick overlay) the part's room slot, or "ignore rooms" (-2) if the part is under no room clip.
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).set_instance_shader_parameter("room_slot", int(part.get_meta(RoomRegistry.META)) if part.has_meta(RoomRegistry.META) else -2)


static func sync_children(part: Node) -> void:
	for child in part.get_children():
		if child is MeshInstance3D and (child.name == "EdgeLines" or child.has_meta("highlight_kind")):
			sync_node(part, child)


static func release(part: MeshInstance3D) -> void:
	## Back to exactly what the part wore before assign(). A part we did not wrap (the section tool got there first, say) just loses its slot.
	part.remove_meta(RoomRegistry.META)
	part.set_instance_shader_parameter("room_slot", -2)
	sync_children(part)
	if part.has_meta(WRAPPED):
		if part.material_override == part.get_meta(WRAPPED):
			part.material_override = part.get_meta(PRIOR)
		part.remove_meta(WRAPPED)
		part.remove_meta(PRIOR)
	ClipLook.unwrap_surfaces(part)


static func reconcile(parts: Array) -> void:
	## `parts` is the arena's parts (main.gd's _arena_parts()): NOT the design table's copy or anything else meant to ignore rooms; those are never passed.
	## Once a frame while rooms exist (cheap: a meta read and a reference compare per part): wraps any part whose override was replaced since
	## (appearance_tool.gd paints by setting material_override, or splits a part's mesh into one surface per look) or that has never been wrapped, keeping each part in the room its meta says.
	if RoomRegistry.rooms.is_empty():
		for part in parts:
			if is_instance_valid(part) and part is MeshInstance3D and part.has_meta(WRAPPED):
				release(part)
		return
	for part in parts:
		if not is_instance_valid(part) or not (part is MeshInstance3D):
			continue # (a part freed since the list was made, say a room that just closed)
		var slot := RoomRegistry.slot_of(part)
		var wrapped := ClipLook.surfaces_wrapped(part) if ClipLook.per_surface(part) else ClipLook.is_clip(part.material_override)
		if not wrapped or not part.has_meta(RoomRegistry.META) or int(part.get_meta(RoomRegistry.META)) != slot:
			assign(part, slot)
		else:
			sync_children(part) # edge lines / overlays built since the last pass
