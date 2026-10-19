extends RefCounted
## Scene composition (DIDSA-CAD `docs/scenes-scope.md` section 5): a scene plus the real placement tree give every placed instance
## its pose, visibility and appearance while the scene is shown. A line-for-line copy of DIDSA-CAD's reference,
## `backend/app/document/scene_compose.py`, checked against its golden vectors (tests/fixtures/scene_vectors.json, a copy of
## DIDSA-CAD's `docs/scenes/vectors.json`; tests/scene_vectors.gd).
##
## nodes: [{"path", "local": T, "hidden": bool, "bodies": [body ids]}] - every placed instance, its occurrence path from the scene's
## Part ("" = the Part's own bodies), its REAL local transform at its own level, its real hidden flag. T is the backend's
## {translation (mm), rotation_axis, rotation_angle_degrees}. scene: {"overrides": [{path, body_id?, face?, transform?, hidden?,
## appearance?}]} or {} for the default.
##
## The rule: a node's local transform is the scene's for its path, else its real one, and world poses compose down the tree; the
## nearest scene `hidden` on the node or an ancestor decides its visibility (else its own real flag); the scene's appearance
## overrides are the top layer of the Appearance tool's rule.

const Rule := preload("res://scripts/appearance/appearance_rule.gd")

const IDENTITY := {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}


static func matrix(transform: Dictionary) -> Array:
	## Rodrigues: the rotation matrix (row-major, [[r00, r01, r02], ...]) of an axis-angle transform.
	var axis: Array = transform.get("rotation_axis", [0.0, 0.0, 1.0])
	var x := float(axis[0])
	var y := float(axis[1])
	var z := float(axis[2])
	var length := sqrt(x * x + y * y + z * z)
	var angle := deg_to_rad(float(transform.get("rotation_angle_degrees", 0.0)))
	if length < 1e-12 or absf(angle) < 1e-12:
		return [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
	x /= length
	y /= length
	z /= length
	var c := cos(angle)
	var s := sin(angle)
	var t := 1.0 - c
	return [
		[t * x * x + c, t * x * y - s * z, t * x * z + s * y],
		[t * x * y + s * z, t * y * y + c, t * y * z - s * x],
		[t * x * z - s * y, t * y * z + s * x, t * z * z + c],
	]


static func pose(transform: Dictionary) -> Dictionary:
	var tr: Array = transform.get("translation", [0.0, 0.0, 0.0])
	return {"basis": matrix(transform), "origin": [float(tr[0]), float(tr[1]), float(tr[2])]}


static func compose_poses(parent: Dictionary, child: Dictionary) -> Dictionary:
	## `parent` then `child` (child in the parent's frame), poses as {basis (row-major 3x3), origin}.
	var pb: Array = parent["basis"]
	var po: Array = parent["origin"]
	var cb: Array = child["basis"]
	var co: Array = child["origin"]
	var basis: Array = []
	for r in 3:
		var row: Array = []
		for c in 3:
			var sum := 0.0
			for k in 3:
				sum += float(pb[r][k]) * float(cb[k][c])
			row.append(sum)
		basis.append(row)
	var origin: Array = []
	for r in 3:
		var sum := float(po[r])
		for k in 3:
			sum += float(pb[r][k]) * float(co[k])
		origin.append(sum)
	return {"basis": basis, "origin": origin}


static func parent_path(path: String) -> Variant:
	## The path of the node that places `path` ("" for a top-level one), or null for the Part's own content ("").
	if path == "":
		return null
	var at := path.rfind("/")
	return path.substr(0, at) if at >= 0 else ""


static func compose_scene(nodes: Array, model: Dictionary, root_id: String, scene: Dictionary = {}) -> Dictionary:
	## Every node's {world, hidden, appearance, bodies} while `scene` is shown ({} = the default). `world` is {basis, origin} in the
	## scene's Part's frame (mm).
	var overrides: Array = scene.get("overrides", []) if scene.get("overrides") is Array else []
	var transforms := {}
	var hidden_set := {}
	var layer: Array = []
	for o in overrides:
		var whole: bool = o.get("body_id") == null and o.get("face") == null
		if whole and o.get("transform") != null:
			transforms[str(o["path"])] = o["transform"]
		if whole and o.get("hidden") != null:
			hidden_set[str(o["path"])] = bool(o["hidden"])
		if o.get("appearance") is Dictionary and not (o["appearance"] as Dictionary).is_empty():
			var rec := {}
			for k in ["path", "body_id", "face", "appearance"]:
				if o.has(k) and o[k] != null:
					rec[k] = o[k]
			layer.append(rec)
	var by_path := {}
	for n in nodes:
		by_path[str(n["path"])] = n
	var world := {}
	var out := {}
	for n in nodes:
		var path := str(n["path"])
		var hidden := bool(n.get("hidden", false))
		var probe: Variant = path
		while probe != null:
			if hidden_set.has(probe):
				hidden = hidden_set[probe]
				break
			probe = parent_path(probe)
		var segments := Rule.split_path(path)
		var bodies := {}
		for b in n.get("bodies", []):
			bodies[str(b)] = Rule.resolve_appearance(model, root_id, segments, str(b), null, layer)
		out[path] = {
			"world": _world_of(path, by_path, transforms, world),
			"hidden": hidden,
			"appearance": Rule.resolve_appearance(model, root_id, segments, null, null, layer),
			"bodies": bodies,
		}
	return out


static func _world_of(path: String, by_path: Dictionary, transforms: Dictionary, world: Dictionary) -> Dictionary:
	if world.has(path):
		return world[path]
	var node = by_path.get(path)
	var local: Dictionary = transforms.get(path, node["local"] if node != null else IDENTITY)
	var parent = parent_path(path)
	var p: Dictionary = pose(local) if parent == null else compose_poses(_world_of(parent, by_path, transforms, world), pose(local))
	world[path] = p
	return p


# --- Godot transforms (the app's nodes) ---------------------------------------------------------------------------

static func to_transform(p: Dictionary) -> Transform3D:
	## A {basis (row-major), origin} pose as a Godot Transform3D (Basis takes COLUMNS, so the rows are transposed in).
	var b: Array = p["basis"]
	var basis := Basis(Vector3(b[0][0], b[1][0], b[2][0]), Vector3(b[0][1], b[1][1], b[2][1]), Vector3(b[0][2], b[1][2], b[2][2]))
	return Transform3D(basis, Vector3(p["origin"][0], p["origin"][1], p["origin"][2]))


static func from_transform(t: Transform3D) -> Dictionary:
	## A Godot Transform3D as the backend's {translation, rotation_axis, rotation_angle_degrees} (scale dropped).
	var q := t.basis.orthonormalized().get_rotation_quaternion()
	var axis := Vector3(0, 0, 1)
	var angle := 0.0
	if absf(q.w) < 0.9999999:
		angle = q.get_angle()
		axis = q.get_axis()
		if axis.length() < 0.0001:
			axis = Vector3(0, 0, 1)
	return {"translation": [t.origin.x, t.origin.y, t.origin.z], "rotation_axis": [axis.x, axis.y, axis.z], "rotation_angle_degrees": rad_to_deg(angle)}
