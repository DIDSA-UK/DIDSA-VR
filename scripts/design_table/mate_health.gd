extends RefCounted
## "Does this mate still point at the face it was made on?" DIDSA-CAD names a mate's face by its INDEX in the part's current shape
## (a SubShapeRef) and re-resolves it only when it solves; it has no persistent naming. After an edit the indices are renumbered, and a
## mate can end up joining two completely different faces — a real run of the design table: a boss added to a plate's top turned
## "face 5, the top" into "face 5, the +X side", and Enforce mates reported success while the stack stayed apart. The backend can't tell,
## but the client can: it has the part's triangles from BEFORE the edit and AFTER it. So, around an edit:
##   capture()  records, for every mate reference into the edited part, what the face it names looks like;
##   drifted()  after the new mesh is in, lists the references whose face is no longer that face.
## A face is "the same" if it is the same kind and, for a plane (every mate on a face is a plane today), faces the same way at the same
## place. Its AREA is ignored on purpose: adding a boss to a face changes its area but not the plane a mate needs.
## Pure functions over the part nodes' mesh and face-identity metas; no network. Tests: tests/mate_health.gd.

const TopologyPick := preload("res://scripts/topology_pick.gd")

const NORMAL_COS := 0.9995 ## about 1.8 degrees
const OFFSET_TOLERANCE := 0.05 ## mm along the normal
const CENTROID_TOLERANCE := 0.02 ## of the part's diagonal, for faces that aren't planes
const AREA_TOLERANCE := 0.25 ## fraction, for faces that aren't planes


static func signature(part: Node3D, body_id: String, face_id: int) -> Dictionary:
	## What a face looks like: {kind, n (outward, area-weighted), centroid, area, offset (n . centroid), diagonal}; {} if the part has no such face.
	var tris := TopologyPick.face_triangles(part, body_id, face_id)
	if tris.size() < 3:
		return {}
	var normal := Vector3.ZERO
	var centroid := Vector3.ZERO
	var area := 0.0
	for i in range(0, tris.size() - 2, 3):
		var a := tris[i]
		var b := tris[i + 1]
		var c := tris[i + 2]
		var cross := (c - a).cross(b - a) # Godot front faces are clockwise: this is the outward normal, twice the area long
		var tri_area := cross.length() * 0.5
		normal += cross
		centroid += (a + b + c) / 3.0 * tri_area
		area += tri_area
	if area < 0.0000001:
		return {}
	centroid /= area
	var kind := ""
	if part.has_meta("topology"):
		var kinds: Array = ((part.get_meta("topology") as Dictionary).get(body_id, {}) as Dictionary).get("face_kinds", [])
		if face_id >= 0 and face_id < kinds.size():
			kind = str(kinds[face_id])
	var n := normal.normalized() if normal.length() > 0.0000001 else Vector3.ZERO
	var flatness := normal.length() / (2.0 * area) # 1 when every triangle faces the same way, far less on a curved face
	return {"kind": kind, "n": n, "centroid": centroid, "area": area, "offset": n.dot(centroid), "flatness": flatness,
		"diagonal": (part as MeshInstance3D).get_aabb().size.length() if part is MeshInstance3D else 1.0}


static func same(before: Dictionary, after: Dictionary) -> bool:
	if before.is_empty() or after.is_empty():
		return false # the face is gone
	if str(before["kind"]) != str(after["kind"]):
		return false
	if _is_plane(before):
		return (before["n"] as Vector3).dot(after["n"]) >= NORMAL_COS and absf(float(before["offset"]) - float(after["offset"])) <= OFFSET_TOLERANCE
	var diag := maxf(float(before["diagonal"]), 0.001)
	var area_ratio := absf(float(after["area"]) - float(before["area"])) / maxf(float(before["area"]), 0.000001)
	return (before["centroid"] as Vector3).distance_to(after["centroid"]) <= CENTROID_TOLERANCE * diag and area_ratio <= AREA_TOLERANCE


static func _is_plane(sig: Dictionary) -> bool:
	## The backend says plane; an older backend says nothing, and then a face whose triangles all agree on one direction is taken as one.
	return str(sig["kind"]) == "plane" or (str(sig["kind"]) == "" and float(sig["flatness"]) > 0.9999)


static func capture(nodes: Array, mates: Array) -> Array:
	## Before the edit: [{mate_id, occurrence_id, body_id, index, before}] for every face reference of every mate that lands on one of
	## `nodes` (the arena nodes that show the part being edited). `mates` is the backend's mate list (mates_tool.mates).
	var by_occurrence := {}
	for node in nodes:
		by_occurrence[str(node.get_meta("occurrence_id", ""))] = node
	var out: Array = []
	for mate in mates:
		if bool(mate.get("suppressed", false)):
			continue # it isn't doing anything
		for ref in mate.get("references", []):
			var sub = ref.get("subshape_ref")
			var node = by_occurrence.get(str(ref.get("occurrence_id", "")))
			if sub == null or node == null or str(sub.get("shape_type", "")) != "face":
				continue
			var body_id := str(sub.get("body_id", ""))
			var index := int(sub.get("index", -1))
			out.append({"mate_id": str(mate.get("id", "")), "occurrence_id": str(ref.get("occurrence_id", "")), "body_id": body_id, "index": index,
				"before": signature(node, body_id, index)})
	return out


static func drifted(captured: Array, nodes: Array) -> Array:
	## After the edit: the captured references whose face is no longer the same one. [{mate_id, occurrence_id, body_id, index}].
	var by_occurrence := {}
	for node in nodes:
		by_occurrence[str(node.get_meta("occurrence_id", ""))] = node
	var out: Array = []
	for entry in captured:
		var node = by_occurrence.get(entry["occurrence_id"])
		if node == null:
			continue
		if not same(entry["before"], signature(node, entry["body_id"], int(entry["index"]))):
			out.append({"mate_id": entry["mate_id"], "occurrence_id": entry["occurrence_id"], "body_id": entry["body_id"], "index": entry["index"]})
	return out


static func mate_ids(drift: Array) -> Array:
	var seen := {}
	for d in drift:
		seen[str(d["mate_id"])] = true
	return seen.keys()
