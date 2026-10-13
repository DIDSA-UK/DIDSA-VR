extends RefCounted
## Which sub-assembly each part belongs to. The backend's assembly-mesh.glb is FLAT: one node per placed instance (the root's own content first, then every
## placed Part in a depth-first, pre-order walk of the occurrence tree), tagged only with the Part that owns it and the occurrence that placed it
## (mesh_identity.gd) - and two instances of the same sub-assembly carry identical tags. So the ancestors cannot be read off a node; they are recovered by
## replaying the same walk over the occurrence rows (`GET /parts/{id}/occurrences`, the tree window's source) and lining the nodes up with it in order.
##
## Each node that lines up gets metadata:
##   group_path   Array[String]  the occurrence ids from the scope's root down to this node (empty for the root's own content)
##   group_parts  Array[String]  the Part each of those resolves to (parallel to group_path)
##   group_names  Array[String]  a label for each (parallel)
##   group_root   String         the Part the scope is rooted at (the loaded root for the world, the room's Part for a room)
## A node that doesn't line up (a pattern-derived copy, a hidden occurrence the mesh left out, a stale tree) simply has no group_path and behaves as a
## plain part. The walk mirrors router._walk_assembly_glb_instances: suppressed occurrences and unresolved ones are skipped, as is a Part already on the
## path (a cycle); Component patterns are not replayed (their copies carry no occurrence id).
##
## A "level" is a candidate for what a grip or a selection should take: the part itself, then each sub-assembly it sits in, innermost first, never the root.

const MAX_DEPTH := 32


static func replay(rows_by_part: Dictionary, root_part_id: String, part_names: Dictionary = {}) -> Array:
	## The walk, as [{owner, occ, path, parts, names, part}] in glb order. `rows_by_part`: Part id -> its occurrence rows.
	var out: Array = []
	_walk(rows_by_part, part_names, root_part_id, root_part_id, "", [], [], [], [root_part_id], out, 0)
	return out


static func _walk(rows_by_part: Dictionary, part_names: Dictionary, part_id: String, owner: String, occ: String, path: Array, parts: Array, names: Array, ancestors: Array, out: Array, depth: int, hidden: bool = false) -> void:
	out.append({"owner": owner, "occ": occ, "path": path, "parts": parts, "names": names, "part": part_id, "hidden": hidden})
	if depth >= MAX_DEPTH:
		return
	for row in rows_by_part.get(part_id, []):
		if bool(row.get("suppressed", false)):
			continue
		var child := str(row.get("resolved_part_id", ""))
		if child == "" or ancestors.has(child):
			continue
		var label := ""
		if row.get("name_override") != null:
			label = str(row["name_override"])
		if label == "":
			label = str(part_names.get(child, child))
		var id := str(row.get("id", ""))
		_walk(rows_by_part, part_names, child, part_id, id, path + [id], parts + [child], names + [label], ancestors + [child], out, depth + 1, bool(row.get("hidden", false)))


static func assign(nodes: Array, entries: Array, root_part_id: String, include_hidden: bool = false) -> int:
	## Lines the nodes (in glb order) up with the replayed walk and tags the ones that match. A node is matched to the next entry, at or after the last
	## match, with its (owner Part, occurrence id); entries a node skips over are occurrences the mesh left out (hidden). Returns how many were tagged.
	if not include_hidden:
		entries = entries.filter(func(e: Dictionary) -> bool: return not bool(e.get("hidden", false))) # the mesh leaves a hidden occurrence's own node out (its children stay)
	var tagged := 0
	var at := 0
	for node in nodes:
		if not is_instance_valid(node):
			continue
		_clear(node)
		var owner := str(node.get_meta("owner_part_id", ""))
		var occ := str(node.get_meta("occurrence_id", ""))
		var found := -1
		for k in range(at, entries.size()):
			var e: Dictionary = entries[k]
			if str(e["occ"]) == occ and (occ == "" or str(e["owner"]) == owner):
				found = k
				break
		if found < 0:
			continue
		var entry: Dictionary = entries[found]
		at = found + 1
		node.set_meta("group_path", (entry["path"] as Array).duplicate())
		node.set_meta("group_parts", (entry["parts"] as Array).duplicate())
		node.set_meta("group_names", (entry["names"] as Array).duplicate())
		node.set_meta("group_root", root_part_id)
		tagged += 1
	return tagged


static func _clear(node: Node) -> void:
	for key in ["group_path", "group_parts", "group_names", "group_root"]:
		if node.has_meta(key):
			node.remove_meta(key)


static func index(api_edit, root_part_id: String, nodes: Array) -> int:
	## Fetches the occurrence rows of the root and every Part below it (cached by `api_edit`, a RoomEdit), replays the walk and tags `nodes`. A coroutine.
	if api_edit == null or root_part_id == "" or nodes.is_empty():
		return 0
	var rows_by_part := {}
	var queue: Array = [root_part_id]
	var seen := {}
	while not queue.is_empty():
		var pid: String = queue.pop_front()
		if seen.has(pid):
			continue
		seen[pid] = true
		var rows: Array = await api_edit.occurrences_of(pid, true)
		rows_by_part[pid] = rows
		for row in rows:
			var child := str(row.get("resolved_part_id", ""))
			if child != "" and not seen.has(child) and not bool(row.get("suppressed", false)):
				queue.append(child)
	var names := {}
	for pid in seen:
		names[pid] = await api_edit.part_name(pid)
	return assign(nodes, replay(rows_by_part, root_part_id, names), root_part_id, bool(api_edit.mesh_include_hidden))


# --- levels ---

static func path_of(node: Node) -> Array:
	return node.get_meta("group_path", []) if is_instance_valid(node) else []


static func has_groups(node: Node) -> bool:
	## True if this part sits inside at least one sub-assembly of its scope (a top-level part has none: it grabs as it always has).
	return path_of(node).size() >= 2


static func members_of(nodes: Array, root: String, prefix: Array, room_id: int = 0) -> Array:
	## The nodes of the scope `root` whose path starts with `prefix` (the sub-assembly's own geometry, if it has any, and everything below it).
	var out: Array = []
	for n in nodes:
		if not is_instance_valid(n) or str(n.get_meta("group_root", "")) != root or int(n.get_meta("room_id", 0)) != room_id:
			continue
		var p: Array = n.get_meta("group_path", [])
		if p.size() < prefix.size():
			continue
		var ok := true
		for i in prefix.size():
			if p[i] != prefix[i]:
				ok = false
				break
		if ok:
			out.append(n)
	return out


static func levels(node: Node, scope_nodes: Array) -> Array:
	## What a grip on `node` can take, innermost first: [{depth, prefix, members, label}]. depth 0 is the part alone (members == [node]); deeper levels
	## are the sub-assemblies it sits in (depth = how many path elements the group spans, so 1 is a top-level sub-assembly). A level that would take
	## exactly what the one before took (a sub-assembly holding a single part) is left out.
	var path := path_of(node)
	var out: Array = [{"depth": 0, "prefix": path, "members": [node], "label": _label(node, path.size())}]
	if path.is_empty():
		return out
	var root := str(node.get_meta("group_root", ""))
	var room_id := int(node.get_meta("room_id", 0))
	for d in range(path.size(), 0, -1):
		var prefix := path.slice(0, d)
		var members := members_of(scope_nodes, root, prefix, room_id)
		if members.size() <= (out[out.size() - 1]["members"] as Array).size():
			continue
		out.append({"depth": d, "prefix": prefix, "members": members, "label": _label(node, d)})
	return out


static func _label(node: Node, depth: int) -> String:
	var names: Array = node.get_meta("group_names", [])
	if names.is_empty():
		return "Part" if depth == 0 else "Assembly"
	return str(names[names.size() - 1]) if depth == 0 or depth > names.size() else str(names[depth - 1])


static func breadcrumb(levels_: Array, current: int) -> String:
	## "Bolt < Bracket < Drive unit", the chosen level in brackets.
	var parts: PackedStringArray = []
	for i in levels_.size():
		var s := str(levels_[i]["label"])
		parts.append("[%s]" % s if i == current else s)
	return " < ".join(parts)


static func union_aabb(members: Array) -> AABB:
	## Bounds of the members in world space (an axis-aligned box round all of them).
	var box := AABB()
	var first := true
	for m in members:
		if not is_instance_valid(m) or not (m is MeshInstance3D):
			continue
		var local: AABB = (m as MeshInstance3D).get_aabb()
		var world: AABB = (m as Node3D).global_transform * local
		box = world if first else box.merge(world)
		first = false
	return box
