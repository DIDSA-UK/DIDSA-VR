extends Node3D
## "Push changes to world": the context for an edit made in an Assembly Room. While a sub-assembly is open in a room its world copy is hidden; this shows it
## again, in one of three states per room:
##   HIDDEN   nothing (the world copy stays hidden, as it always was)
##   GHOST    the ORIGINAL world copy, faint, where it sits
##   PREVIEW  the EDITED sub-assembly (the room's parts, as they are now) at every place the original sits in the world, in the preview colour; parts the edit
##            moved or added are tinted differently from the ones it left alone
## Nothing here is real geometry or real data: each stand-in is a MeshInstance3D sharing the part's mesh (the cost is a transform per part), drawn with
## shaders/world_preview.gdshader, which obeys the same clips as any world part. Moving the room's parts moves their previews when `live` is on (the
## auto-update); with it off the preview shows the pose of the last push() and only that.
##
## WHERE the world copy sits: the room's parts and the world's parts carry their place in the occurrence tree (group_index.gd), so a room part's path is the
## tail of the path of its world twin and the rest is the PLACEMENT. The pose of a placement is read off one twin: world pose * the pose that part had when
## the room opened (`room_orig`, kept by room.gd) inverted. If the same sub-assembly is placed several times each placement gets its own preview.

const GroupIndex := preload("res://scripts/group_index.gd")
const PreviewShader := preload("res://shaders/world_preview.gdshader")
const ClipGlobals := preload("res://scripts/clip_globals.gd")

enum Mode { HIDDEN, GHOST, PREVIEW }

const MODE_NAMES := ["Hidden", "Ghost", "Preview"]
const GHOST_TINT := Color(0.68, 0.76, 0.9)
const PREVIEW_TINT := Color(0.58, 0.3, 0.95) ## violet: not the cyan hover, the pale-yellow selection or the orange second mate pick
const CHANGED_TINT := Color(1.0, 0.42, 0.72) ## a part the edit moved or added
const MOVED_EPS := 0.05 ## mm of change that counts as "moved" (the room's frame is the backend's millimetres)
const TETHER_COLOUR := Color(0.58, 0.3, 0.95, 0.7)

var mode := Mode.HIDDEN
var live := true ## preview follows the room's parts every frame (off: it shows the last push())
var pulse := false ## the preview breathes (an aesthetic option)
var room: Node
var instances: Array = [] ## [{prefix: Array, xform: Transform3D, seeds: Array of world nodes, centre: Vector3}]
var warning := "" ## set by refresh(): why the preview may not be where the mates would put it

var _proxies: Array = [] ## [{node: MeshInstance3D, src: Node3D, inst: int, cls: int}]
var _ghosts: Array = []
var _snapshot: Dictionary = {} ## src -> its local pose at the last push()
var _tether: MeshInstance3D
var _mates = null ## the mates tool, for the "mated in the world" warning


func setup(p_room: Node, mates_tool = null) -> void:
	room = p_room
	_mates = mates_tool
	name = "WorldPreview"
	top_level = true # world-space stand-ins: nothing above it may move them


# --- finding the placements ---

static func orig_of(part: Node) -> Variant:
	## The pose (in the room's frame) a part had when the room opened; null for a part that was added since.
	return part.get_meta("room_orig") if is_instance_valid(part) and part.has_meta("room_orig") else null


static func classify(part: Node3D, pose: Transform3D) -> int:
	## 0 = unchanged, 1 = moved, 2 = added since the room opened.
	var orig: Variant = orig_of(part)
	if orig == null:
		return 2
	var o: Transform3D = orig
	if o.origin.distance_to(pose.origin) > MOVED_EPS or not o.basis.orthonormalized().is_equal_approx(pose.basis.orthonormalized()):
		return 1
	return 0


static func find_instances(world_nodes: Array, room_parts: Array) -> Array:
	## Where the room's Part sits in the world. A world node is another placement's twin of a room part if its path ends with the room part's path and its
	## tags agree; the rest of its path names the placement. Returns [{prefix, xform, seeds, centre}] (xform maps the Part's own frame to the world).
	var by_prefix: Dictionary = {}
	var order: Array = []
	for rp in room_parts:
		if not is_instance_valid(rp) or orig_of(rp) == null or not rp.has_meta("group_path"):
			continue
		var rpath: Array = rp.get_meta("group_path")
		for wn in world_nodes:
			if not is_instance_valid(wn) or not wn.has_meta("group_path"):
				continue
			var wpath: Array = wn.get_meta("group_path")
			if wpath.size() < rpath.size() or str(wn.get_meta("owner_part_id", "")) != str(rp.get_meta("owner_part_id", "")) or str(wn.get_meta("occurrence_id", "")) != str(rp.get_meta("occurrence_id", "")):
				continue
			var cut := wpath.size() - rpath.size()
			var tail := wpath.slice(cut)
			if tail != rpath:
				continue
			var prefix := wpath.slice(0, cut)
			var key := "/".join(PackedStringArray(prefix))
			if by_prefix.has(key):
				continue
			var o: Transform3D = orig_of(rp)
			by_prefix[key] = {"prefix": prefix, "xform": (wn as Node3D).global_transform * o.affine_inverse(), "seeds": [], "centre": Vector3.ZERO}
			order.append(key)
	for key in order:
		var inst: Dictionary = by_prefix[key]
		var prefix: Array = inst["prefix"]
		for wn in world_nodes:
			if not is_instance_valid(wn) or not wn.has_meta("group_path"):
				continue
			var wpath: Array = wn.get_meta("group_path")
			if wpath.size() >= prefix.size() and wpath.slice(0, prefix.size()) == prefix:
				(inst["seeds"] as Array).append(wn)
		var box := GroupIndex.union_aabb(inst["seeds"])
		inst["centre"] = box.get_center()
	var out: Array = []
	for key in order:
		out.append(by_prefix[key])
	return out


# --- building ---

func available() -> bool:
	return not instances.is_empty()


func rebuild(world_nodes: Array) -> void:
	## Works out the placements again from the nodes as they are now and rebuilds whatever the mode shows.
	_free_all()
	instances = find_instances(world_nodes, room.parts if is_instance_valid(room) else [])
	_apply_mode()


func set_mode(m: int) -> bool:
	## False (and the mode stays) if there is no placement to show it at.
	if m != Mode.HIDDEN and not available():
		return false
	mode = m as Mode
	_apply_mode()
	return true


func cycle_mode() -> int:
	var next := (int(mode) + 1) % 3
	if next != Mode.HIDDEN and not available():
		next = Mode.HIDDEN
	set_mode(next)
	return int(mode)


func push() -> void:
	## Takes the room's parts as they are now as the preview (and, in Preview mode, redraws it).
	_snapshot.clear()
	if is_instance_valid(room):
		for p in room.parts:
			if is_instance_valid(p):
				_snapshot[p] = p.transform
	if mode == Mode.PREVIEW:
		_build_previews()
		refresh()


func _apply_mode() -> void:
	_clear_proxies()
	match mode:
		Mode.GHOST:
			_build_ghosts()
		Mode.PREVIEW:
			push()
	_update_tether()
	set_process(mode != Mode.HIDDEN)


func _free_all() -> void:
	_clear_proxies()
	instances = []


func _clear_proxies() -> void:
	for p in _proxies:
		if is_instance_valid(p["node"]):
			(p["node"] as Node).queue_free()
	_proxies.clear()
	for g in _ghosts:
		if is_instance_valid(g):
			(g as Node).queue_free()
	_ghosts.clear()
	if is_instance_valid(_tether):
		_tether.queue_free()
	_tether = null


func _material(tint: Color, alpha: float) -> ShaderMaterial:
	ClipGlobals.ensure()
	var m := ShaderMaterial.new()
	m.shader = PreviewShader
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("alpha", alpha)
	m.set_shader_parameter("pulse", 0.12 if pulse else 0.0)
	return m


func _proxy_of(src: MeshInstance3D, mat: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = src.mesh
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.set_instance_shader_parameter("room_slot", -1) # a world thing: hidden inside every room's box
	add_child(node)
	return node


func _build_ghosts() -> void:
	for inst in instances:
		for seed in inst["seeds"]:
			if is_instance_valid(seed) and seed is MeshInstance3D:
				var g := _proxy_of(seed, _material(GHOST_TINT, 0.18))
				g.global_transform = (seed as Node3D).global_transform
				_ghosts.append(g)


func _build_previews() -> void:
	for p in _proxies:
		if is_instance_valid(p["node"]):
			(p["node"] as Node).queue_free()
	_proxies.clear()
	if not is_instance_valid(room):
		return
	for i in instances.size():
		for src in room.parts:
			if is_instance_valid(src) and src is MeshInstance3D and src.mesh != null:
				var node := _proxy_of(src, _material(PREVIEW_TINT, 0.55))
				_proxies.append({"node": node, "src": src, "inst": i, "cls": -1})


func _process(_delta: float) -> void:
	if mode == Mode.PREVIEW and live:
		refresh()
	elif mode != Mode.HIDDEN:
		_update_tether()


func refresh() -> void:
	## Puts each preview where its room part is (live) or was at the last push, tints the changed ones, and draws the tether.
	if mode != Mode.PREVIEW:
		_update_tether()
		return
	var changed := false
	for entry in _proxies:
		var src: Node3D = entry["src"]
		var node: MeshInstance3D = entry["node"]
		if not is_instance_valid(src) or not is_instance_valid(node):
			continue
		var pose: Transform3D = src.transform if live else _snapshot.get(src, src.transform)
		node.global_transform = (instances[entry["inst"]]["xform"] as Transform3D) * pose
		var cls := classify(src, pose)
		if cls != 0:
			changed = true
		if cls != entry["cls"]:
			entry["cls"] = cls
			var m := node.material_override as ShaderMaterial
			m.set_shader_parameter("tint", PREVIEW_TINT if cls == 0 else CHANGED_TINT)
			m.set_shader_parameter("alpha", 0.55 if cls == 0 else 0.7)
	warning = _warning_for(changed)
	_update_tether()


func changed_count() -> int:
	## How many of the room's parts the edit moved or added (against where they were when the room opened).
	var n := 0
	if is_instance_valid(room):
		for p in room.parts:
			if is_instance_valid(p) and classify(p, p.transform) != 0:
				n += 1
	return n


func _warning_for(changed: bool) -> String:
	if not changed or _mates == null:
		return ""
	for inst in instances:
		var prefix: Array = inst["prefix"]
		if prefix.size() == 1:
			var owner: String = str(room.seed_owner_part_id) if is_instance_valid(room) else ""
			if owner != "" and _mates.has_method("group_state") and _mates.group_state(owner, str(prefix[0])) == "mated":
				return "Mated in the world: Enforce mates there after this edit."
	return ""


func nearest_instance(from: Vector3) -> int:
	var best := -1
	var best_d := INF
	for i in instances.size():
		var d := from.distance_to(instances[i]["centre"])
		if d < best_d:
			best_d = d
			best = i
	return best


func _update_tether() -> void:
	if mode == Mode.HIDDEN or instances.is_empty() or not is_instance_valid(room):
		if is_instance_valid(_tether):
			_tether.visible = false
		return
	var from: Vector3 = room.global_position
	var target: Vector3 = instances[nearest_instance(from)]["centre"]
	if _tether == null:
		_tether = MeshInstance3D.new()
		_tether.mesh = ImmediateMesh.new()
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = TETHER_COLOUR
		m.no_depth_test = true
		_tether.material_override = m
		_tether.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_tether)
	_tether.visible = true
	var im := _tether.mesh as ImmediateMesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(from)
	im.surface_add_vertex(target)
	im.surface_end()
