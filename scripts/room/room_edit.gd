extends RefCounted
## Changing what an Assembly Room's assembly is made of: adding a copy of an existing Part (drop-to-add), adding a Part from a file, and deleting a placed part
## (and restoring it for undo). Thin on purpose, like design_table/new_document.gd: DIDSA-CAD owns the document, this only calls its routes, found and
## checked live (docs/assembly-rooms-plan.md, "Drop-to-add and delete"):
##   POST   /document/parts/{owner}/occurrences      a client-made id and `resolved_part_id`: puts an existing Part on ANY Part (201)
##   POST   /document/parts/{owner}/add-component    a native file's own Part as a new occurrence (200); then PATCH its transform
##   DELETE /document/parts/{owner}/occurrences/{id} removes it (204) and, with it, every Mate and ComponentPattern that names it
## What the server does NOT stop, and so this does first: adding a Part into itself or into one that contains it (201, a wrong document), and an unknown
## Part id (201, an occurrence that silently shows nothing).
##
## `api` is anything with request(method, path, body) and fetch_bytes(path), each a coroutine returning {ok, code, json|bytes, error}: design_table/cad_api.gd
## in the app (one request at a time, the app's own document session), a fake in tests. Paths are full routes ("/document/parts/...").

const MatesTool := preload("res://scripts/mates_tool.gd")
const NewDocument := preload("res://scripts/design_table/new_document.gd")
const MeshIdentity := preload("res://scripts/mesh_identity.gd")

var api
var mesh_quality := 0.5
var mesh_tier := ""
var mesh_include_hidden := false

var _name_cache: Dictionary = {} ## Part id -> its name
var _occurrence_cache: Dictionary = {} ## owner Part id -> Array of OccurrenceResponse dictionaries, until that Part changes


func _init(p_api = null) -> void:
	api = p_api


func occurrences_of(owner_part_id: String, fresh: bool = false) -> Array:
	## The Part's direct occurrences, as the backend lists them ([] if they could not be read). Cached; `fresh` re-reads.
	var rows = await _occurrences_or_null(owner_part_id, fresh)
	return rows if rows != null else []


func _occurrences_or_null(owner_part_id: String, fresh: bool = false):
	## The same, but null when the read failed (so a caller that counts can tell "none" from "could not read").
	if not fresh and _occurrence_cache.has(owner_part_id):
		return _occurrence_cache[owner_part_id]
	var r: Dictionary = await api.request(HTTPClient.METHOD_GET, "/document/parts/%s/occurrences" % owner_part_id, null)
	if not r["ok"]:
		return null
	var rows: Array = r["json"] if r["json"] is Array else []
	_occurrence_cache[owner_part_id] = rows
	return rows


func part_name(part_id: String) -> String:
	## The Part's own name (cached); its id if the backend won't say.
	if _name_cache.has(part_id):
		return _name_cache[part_id]
	var r: Dictionary = await api.request(HTTPClient.METHOD_GET, "/document/parts/%s" % part_id, null)
	var name_ := str((r["json"] as Dictionary).get("name", "")) if r["ok"] and r["json"] is Dictionary else ""
	_name_cache[part_id] = name_ if name_ != "" else part_id
	return _name_cache[part_id]


func forget(owner_part_id: String) -> void:
	_occurrence_cache.erase(owner_part_id)


func definition_of(node: Node) -> String:
	## The Part a placed node shows: its owner's occurrence list says which Part its occurrence points at. "" if it has none (root content, an unknown id).
	var ref := MeshIdentity.occurrence_ref_for(node)
	if ref.is_empty() or str(ref.get("occurrence_id", "")) == "":
		return ""
	for row in await occurrences_of(str(ref["owner_part_id"])):
		if str(row.get("id", "")) == str(ref["occurrence_id"]):
			return str(row.get("resolved_part_id", "")) if row.get("resolved_part_id") != null else ""
	return ""


func contains_part(container_id: String, target_id: String) -> bool:
	## Is `target_id` the container Part itself or anywhere in its subtree? (How adding a Part into itself is caught.)
	var seen := {}
	var queue: Array = [container_id]
	while not queue.is_empty():
		var current: String = queue.pop_back()
		if current == target_id:
			return true
		if seen.has(current):
			continue
		seen[current] = true
		for row in await occurrences_of(current):
			var child = row.get("resolved_part_id")
			if child != null and str(child) != "":
				queue.append(str(child))
	return false


func file_conflict(container_id: String, file_text: String) -> String:
	## "" if the native file may be added to the Part `container_id`, else why not. The server only refuses a file whose ROOT is the container; it merges the
	## file's Parts into the document by id, so a file that contains the container anywhere (or a Part the document already has that does) would put the
	## container inside itself. Followed here through the file's own placements and the document's.
	var parsed = JSON.parse_string(file_text)
	if not (parsed is Dictionary) or not (parsed.get("document") is Dictionary):
		return "That isn't a native DIDSA file."
	var document: Dictionary = parsed["document"]
	var file_parts: Dictionary = {}
	var first_id := ""
	for p in document.get("parts", []):
		if p is Dictionary:
			var kids: Array = []
			for occ in p.get("occurrences", []):
				if occ is Dictionary and occ.get("resolved_part_id") != null and str(occ["resolved_part_id"]) != "":
					kids.append(str(occ["resolved_part_id"]))
			file_parts[str(p.get("id", ""))] = kids
			if first_id == "":
				first_id = str(p.get("id", ""))
	var root_id := str(document.get("root_part_id", "")) if str(document.get("root_part_id", "")) != "" else first_id
	if root_id == "":
		return "That file has no Parts."
	var seen := {}
	var queue: Array = [root_id]
	while not queue.is_empty():
		var current: String = queue.pop_back()
		if current == container_id:
			return "Can't add that file here: it contains this assembly (a Part can't hold itself)."
		if seen.has(current):
			continue
		seen[current] = true
		for kid in file_parts.get(current, []):
			queue.append(kid)
		for row in await occurrences_of(current): # (a Part the document already has keeps its own placements when the file's copy is merged in by id)
			if row.get("resolved_part_id") != null and str(row["resolved_part_id"]) != "":
				queue.append(str(row["resolved_part_id"]))
	return ""


func instance_count(root_part_id: String, target_part_id: String) -> int:
	## How many times `target_part_id` is placed in the assembly under `root_part_id`, counting every path to it (a bolt in a bracket that is placed three
	## times counts three). The room console's "used N times": editing a Part in a room changes every one of them. -1 when an occurrences read failed (the count is unknown,
	## not 0).
	var memo := {}
	return await _count_placements(root_part_id, target_part_id, memo, 0)


func _count_placements(container_id: String, target_id: String, memo: Dictionary, depth: int) -> int:
	if depth > 24:
		return 0 # (a cycle the server let through: stop rather than loop)
	if memo.has(container_id):
		return memo[container_id]
	var total := 0
	var rows = await _occurrences_or_null(container_id)
	if rows == null:
		return -1
	for row in rows:
		var child = row.get("resolved_part_id")
		if child == null or str(child) == "":
			continue
		if str(child) == target_id:
			total += 1
		var below := await _count_placements(str(child), target_id, memo, depth + 1)
		if below < 0:
			return -1
		total += below
	memo[container_id] = total
	return total


func check_addable(room_part_id: String, definition_id: String) -> String:
	## "" if `definition_id` may be added to the room's Part, else why not (plain text for a status line).
	if definition_id == "":
		return "That part has no source Part to copy (it is the assembly's own content, or not from the backend)."
	if definition_id == room_part_id or await contains_part(definition_id, room_part_id):
		return "Can't add that here: it contains this room's own assembly (a Part can't hold itself)."
	return ""


const FIRST_PART_NOTE := "First part: fixed at the room's origin"
const ORIGIN_POSE := {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}


func is_empty_room(room_part_id: String) -> bool:
	## The room's Part has no placed occurrences yet (T2): what is added next is its first part, which goes in fixed at the origin.
	return (await occurrences_of(room_part_id, true)).is_empty()


func add_new_part(room_part_id: String, name: String) -> Dictionary:
	## "New assembly" in a room (T2): a new empty Part placed in the room's Part. The first one goes in at the origin and fixed. {ok, error, part_id,
	## occurrence_id, first}.
	var first := await is_empty_room(room_part_id)
	var maker := NewDocument.new(Callable(api, "request"))
	var made: Dictionary = await maker.add_part(room_part_id, name, ORIGIN_POSE.duplicate(true))
	if not made["ok"]:
		return {"ok": false, "error": str(made["error"]), "part_id": str(made.get("part_id", "")), "occurrence_id": "", "first": first}
	if first:
		var grounded: Dictionary = await api.request(HTTPClient.METHOD_PATCH, "/document/parts/%s/occurrences/%s" % [room_part_id, made["occurrence_id"]], {"fixed": true})
		if not grounded["ok"]:
			return {"ok": false, "error": "Added, but couldn't fix it at the origin: %s" % str(grounded["error"]), "part_id": made["part_id"], "occurrence_id": made["occurrence_id"], "first": first}
	forget(room_part_id)
	return {"ok": true, "error": "", "part_id": made["part_id"], "occurrence_id": made["occurrence_id"], "first": first}


func add_copy(room_part_id: String, node: Node, world_pose: Transform3D, content_root: Node3D, label: String = "") -> Dictionary:
	## A new occurrence of the Part `node` shows, in the room's Part, at `world_pose` (where it was put down). {ok, error, occurrence_id, definition_id, pose}.
	var definition := await definition_of(node)
	var refusal := await check_addable(room_part_id, definition)
	if refusal != "":
		return {"ok": false, "error": refusal, "occurrence_id": "", "definition_id": definition, "pose": {}}
	var first := await is_empty_room(room_part_id) # T2: the first part of a room is fixed at the origin, wherever it was let go
	var pose := ORIGIN_POSE.duplicate(true) if first else pose_in_room(world_pose, content_root)
	var occurrence_id := NewDocument.new_occurrence_id()
	var placed: Dictionary = await api.request(HTTPClient.METHOD_POST, "/document/parts/%s/occurrences" % room_part_id, {
		"id": occurrence_id, "resolved_part_id": definition, "name_override": label if label != "" else null, "transform": pose,
	})
	if not placed["ok"]:
		return {"ok": false, "error": "Couldn't add it: %s" % str(placed["error"]), "occurrence_id": "", "definition_id": definition, "pose": pose, "first": first}
	if first:
		var grounded: Dictionary = await api.request(HTTPClient.METHOD_PATCH, "/document/parts/%s/occurrences/%s" % [room_part_id, occurrence_id], {"fixed": true})
		if not grounded["ok"]:
			return {"ok": false, "error": "Added, but couldn't fix it at the origin: %s" % str(grounded["error"]), "occurrence_id": occurrence_id, "definition_id": definition, "pose": pose, "first": first}
	forget(room_part_id)
	return {"ok": true, "error": "", "occurrence_id": occurrence_id, "definition_id": definition, "pose": pose, "first": first}


func chain_below(root_part_id: String, parts: Array, path: Array, depth: int) -> Transform3D:
	## The pose, in the sub-assembly's own frame, of the occurrence a group member stands for: the product of the placements below the group (path elements
	## `depth` onward; each one is an occurrence of the Part the previous element resolves to). The group's own frame in the world is then the member's world
	## pose times the inverse of this. (Millimetres, like every stored pose.)
	var result := Transform3D.IDENTITY
	for i in range(depth, path.size()):
		var owner := root_part_id if i == 0 else str(parts[i - 1])
		for row in await occurrences_of(owner):
			if str(row.get("id", "")) == str(path[i]):
				result = result * MatesTool.json_to_pose(row.get("transform", {}))
				break
	return result


func add_group(room_part_id: String, info: Dictionary, content_root: Node3D) -> Dictionary:
	## A new occurrence, in the room's Part, of the sub-assembly a dropped group stands for (a Part: it brings everything inside it), placed where the group's
	## own origin landed. `info`: {root, path, parts, depth, anchor_pose, label}. {ok, error, occurrence_id, definition_id, pose}.
	var depth := int(info["depth"])
	var parts: Array = info["parts"]
	var definition := str(parts[depth - 1]) if depth >= 1 and depth <= parts.size() else ""
	var refusal := await check_addable(room_part_id, definition)
	if refusal != "":
		return {"ok": false, "error": refusal, "occurrence_id": "", "definition_id": definition, "pose": {}}
	var below := await chain_below(str(info["root"]), parts, info["path"], depth)
	var group_world: Transform3D = (info["anchor_pose"] as Transform3D) * below.affine_inverse()
	var pose := pose_in_room(group_world, content_root)
	var occurrence_id := NewDocument.new_occurrence_id()
	var label := str(info.get("label", ""))
	var placed: Dictionary = await api.request(HTTPClient.METHOD_POST, "/document/parts/%s/occurrences" % room_part_id, {
		"id": occurrence_id, "resolved_part_id": definition, "name_override": label if label != "" else null, "transform": pose,
	})
	if not placed["ok"]:
		return {"ok": false, "error": "Couldn't add it: %s" % str(placed["error"]), "occurrence_id": "", "definition_id": definition, "pose": pose}
	forget(room_part_id)
	return {"ok": true, "error": "", "occurrence_id": occurrence_id, "definition_id": definition, "pose": pose}


static func pose_in_room(world_pose: Transform3D, content_root: Node3D) -> Dictionary:
	## `world_pose` as the backend stores a placement in the room's Part: its rotation and its position in the room's own millimetres. The room's scale
	## is a display scale and is dropped (a Part dropped into a 20:1 room is still its real size).
	var local := content_root.global_transform.affine_inverse() * world_pose
	return MatesTool.pose_to_json(Transform3D(local.basis.orthonormalized(), local.origin))


func add_file(room_part_id: String, file_text: String, pose: Dictionary, name_override: String = "") -> Dictionary:
	## A native file's Part as a new occurrence in the room's Part (the file's own text is sent as it is: its integers stay integers), then placed at `pose`.
	## T2: the first part of an empty room goes at the origin and fixed, whatever `pose` says.
	var refusal := await file_conflict(room_part_id, file_text)
	if refusal != "":
		return {"ok": false, "error": refusal, "occurrence_id": "", "first": false}
	var first := await is_empty_room(room_part_id)
	if first:
		pose = ORIGIN_POSE.duplicate(true)
	var body := '{"component": %s}' % file_text
	var added: Dictionary = await api.request(HTTPClient.METHOD_POST, "/document/parts/%s/add-component" % room_part_id, body)
	if not added["ok"] or not (added["json"] is Dictionary) or str((added["json"] as Dictionary).get("occurrence_id", "")) == "":
		return {"ok": false, "error": "Couldn't add the file: %s" % str(added["error"]), "occurrence_id": "", "first": first}
	var occurrence_id := str((added["json"] as Dictionary)["occurrence_id"])
	forget(room_part_id)
	var patch := {"transform": pose}
	if name_override != "":
		patch["name_override"] = name_override
	var occ_path := "/document/parts/%s/occurrences/%s" % [room_part_id, occurrence_id]
	var placed: Dictionary = await api.request(HTTPClient.METHOD_PATCH, occ_path, patch)
	if not placed["ok"] and str(placed["error"]).contains("occurrence_is_fixed"):
		# The first part put into an EMPTY Part (a New room) is grounded by the backend (fixed), and a fixed occurrence refuses a transform. Place it
		# unfixed in one call, then ground it again: the backend's own grounding stays.
		patch["fixed"] = false
		placed = await api.request(HTTPClient.METHOD_PATCH, occ_path, patch)
		if placed["ok"]:
			placed = await api.request(HTTPClient.METHOD_PATCH, occ_path, {"fixed": true})
	if not placed["ok"]:
		return {"ok": true, "error": "Added, but couldn't place it: %s" % str(placed["error"]), "occurrence_id": occurrence_id, "first": first}
	if first: # the backend grounds the first occurrence of an empty Part itself; say it too, so the rule does not depend on that
		var grounded: Dictionary = await api.request(HTTPClient.METHOD_PATCH, occ_path, {"fixed": true})
		if not grounded["ok"]:
			return {"ok": true, "error": "Added at the origin, but couldn't fix it: %s" % str(grounded["error"]), "occurrence_id": occurrence_id, "first": first}
	return {"ok": true, "error": "", "occurrence_id": occurrence_id, "first": first}


func mates_naming(owner_part_id: String, occurrence_id: String) -> int:
	## How many Mates deleting this occurrence would take with it.
	var r: Dictionary = await api.request(HTTPClient.METHOD_GET, "/document/parts/%s/mates" % owner_part_id, null)
	var count := 0
	if r["ok"] and r["json"] is Array:
		for mate in r["json"]:
			for ref in mate.get("references", []):
				if str(ref.get("occurrence_id", "")) == occurrence_id:
					count += 1
					break
	return count


func delete_occurrence(owner_part_id: String, occurrence_id: String) -> Dictionary:
	## Takes a placed part off its owner Part. {ok, error, snapshot (the occurrence as it was, for restore), mates_removed}.
	var rows := await occurrences_of(owner_part_id, true)
	var snapshot := {}
	for row in rows:
		if str(row.get("id", "")) == occurrence_id:
			snapshot = (row as Dictionary).duplicate(true)
	if snapshot.is_empty():
		return {"ok": false, "error": "That part is not in the backend's assembly (already deleted?).", "snapshot": {}, "mates_removed": 0}
	var mates := await mates_naming(owner_part_id, occurrence_id)
	var r: Dictionary = await api.request(HTTPClient.METHOD_DELETE, "/document/parts/%s/occurrences/%s" % [owner_part_id, occurrence_id], null)
	forget(owner_part_id)
	if not r["ok"]:
		return {"ok": false, "error": "Couldn't delete it: %s" % str(r["error"]), "snapshot": snapshot, "mates_removed": 0}
	return {"ok": true, "error": "", "snapshot": snapshot, "mates_removed": mates}


func restore_occurrence(owner_part_id: String, snapshot: Dictionary) -> Dictionary:
	## Puts a deleted (or undone-added) occurrence back with its old id and everything it had. Mates the delete removed do not come back.
	var body := {}
	for key in ["id", "external_ref", "resolved_part_id", "name_override", "transform", "suppressed", "hidden", "fixed", "color"]:
		if snapshot.has(key):
			body[key] = snapshot[key]
	var r: Dictionary = await api.request(HTTPClient.METHOD_POST, "/document/parts/%s/occurrences" % owner_part_id, body)
	forget(owner_part_id)
	return {"ok": bool(r["ok"]), "error": "" if r["ok"] else "Couldn't put it back: %s" % str(r["error"])}


func remove_added(owner_part_id: String, occurrence_id: String) -> bool:
	## Undo of an add: the occurrence goes again (a copy has no Mates yet, so nothing else goes with it).
	var r: Dictionary = await api.request(HTTPClient.METHOD_DELETE, "/document/parts/%s/occurrences/%s" % [owner_part_id, occurrence_id], null)
	forget(owner_part_id)
	return bool(r["ok"])


func fetch_part_glb(part_id: String) -> PackedByteArray:
	## A Part's own assembly-mesh.glb (it as a root, in its own frame): what a room shows. Empty if it could not be read.
	var path := "/document/parts/%s/assembly-mesh.glb?quality=%s&include_hidden=%s" % [part_id, str(mesh_quality), str(mesh_include_hidden).to_lower()]
	if mesh_tier != "":
		path += "&tier=%s" % mesh_tier
	var r: Dictionary = await api.fetch_bytes(path)
	return r["bytes"] if r["ok"] else PackedByteArray()
