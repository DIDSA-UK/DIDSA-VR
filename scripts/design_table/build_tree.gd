extends RefCounted
## The numbers and words behind the design table's BUILD tree: the ordered list of everything that built the part on the table
## (planes, sketches, extrudes, fillets, chamfers...), the same tree the flat app shows in its part design lens
## (client/lib/viewport3d/feature_tree_panel.dart). Pure functions over the backend's `GET /document/parts/{id}/features` rows and the
## part's mesh ids, no scene tree, so tests can pin them.

const TopologyPick := preload("res://scripts/topology_pick.gd")

const LABELS := {
	"sketch": "Sketch", "extrude": "Extrude", "create_plane": "Plane", "fillet": "Fillet", "chamfer": "Chamfer",
	"revolve": "Revolve", "sweep": "Sweep", "loft": "Loft", "surface": "Surface", "mirror": "Mirror", "pattern": "Pattern",
	"merge": "Merge", "split": "Split", "shell": "Shell", "import": "Import", "delete_body": "Delete Body",
	"scale_body": "Scale", "move_body": "Move Body", "delete_face": "Delete Face", "move_face": "Move Face",
}
const EDITABLE := ["extrude", "fillet", "chamfer"] ## the types whose value the table can change (a PATCH of one number)


static func label(type: String) -> String:
	if LABELS.has(type):
		return LABELS[type]
	return type.replace("_", " ").capitalize()


static func names(features: Array) -> Array:
	## "Sketch 1", "Extrude 1", "Sketch 2"...: the type's name and how many of that type there are up to and including this one,
	## in order, one per feature (the flat app's featureDisplayName).
	var counts := {}
	var out: Array = []
	for f in features:
		var type := str(f.get("type", ""))
		counts[type] = int(counts.get(type, 0)) + 1
		out.append("%s %d" % [label(type), counts[type]])
	return out


static func name_of(features: Array, feature_id: String) -> String:
	var all := names(features)
	for i in features.size():
		if str(features[i].get("id", "")) == feature_id:
			return all[i]
	return ""


static func glyph(type: String) -> String:
	## The icon name (ui_icons.gd) for a row.
	match type:
		"sketch":
			return "cat_sketch"
		"create_plane":
			return "feat_plane"
		"extrude":
			return "tool_extrude"
		"revolve":
			return "tool_revolve"
		"fillet":
			return "tool_fillet"
		"chamfer":
			return "tool_chamfer"
	return "cat_feature"


static func number(x: float) -> String:
	## 12 -> "12", 12.5 -> "12.5", 0.125 -> "0.13": short, for a one-line summary.
	var s := "%.2f" % x
	return s.rstrip("0").rstrip(".")


static func summary(features: Array, index: int) -> String:
	## The second line of a row: what the feature does, in a few words.
	var f: Dictionary = features[index]
	match str(f.get("type", "")):
		"sketch":
			var plane_id = f.get("plane_feature_id")
			if plane_id != null and str(plane_id) != "":
				var plane_name := name_of(features, str(plane_id))
				return "on %s" % plane_name if plane_name != "" else "on a plane"
			return "on a reference plane"
		"extrude":
			var depth := absf(float(f.get("end_distance", 0.0)) - float(f.get("start_distance", 0.0)))
			return "%s %s mm" % ["Cut" if str(f.get("extrude_type", "boss")) == "cut" else "Boss", number(depth)]
		"fillet":
			return "R %s mm, %d edge(s)" % [number(float(f.get("radius", 0.0))), (f.get("edge_refs", []) as Array).size()]
		"chamfer":
			return "%s mm, %d edge(s)" % [number(float(f.get("distance", 0.0))), (f.get("edge_refs", []) as Array).size()]
		"create_plane":
			return str(f.get("plane_type", "plane")).replace("_", " ")
	return ""


static func value_of(feature: Dictionary) -> float:
	## The one number Edit changes: an extrude's depth, a fillet's radius, a chamfer's distance. -1 for a type with none.
	match str(feature.get("type", "")):
		"extrude":
			return absf(float(feature.get("end_distance", 0.0)) - float(feature.get("start_distance", 0.0)))
		"fillet":
			return float(feature.get("radius", 0.0))
		"chamfer":
			return float(feature.get("distance", 0.0))
	return -1.0


static func value_title(type: String) -> String:
	return {"extrude": "Depth (mm)", "fillet": "Radius (mm)", "chamfer": "Distance (mm)"}.get(type, "Value (mm)")


static func edit_payload(feature: Dictionary, new_value: float) -> Dictionary:
	## The PATCH body that gives the feature `new_value`: an extrude keeps its start and direction (the end moves, same sign), a
	## fillet / chamfer replace their one number. {} for a type that has none.
	match str(feature.get("type", "")):
		"extrude":
			var start := float(feature.get("start_distance", 0.0))
			var end := float(feature.get("end_distance", 0.0))
			var direction := 1.0 if end >= start else -1.0
			return {"start_distance": start, "end_distance": start + direction * new_value}
		"fillet":
			return {"radius": new_value}
		"chamfer":
			return {"distance": new_value}
	return {}


static func base_id(id: String) -> String:
	## A body id without its "#N" split suffix: the id of the feature that made it.
	var i := id.find("#")
	return id if i < 0 else id.substr(0, i)


static func dependencies(feature: Dictionary) -> Array:
	## The ids of the features this one is built on (the backend's dependency graph, as far as the table can see it).
	var out: Array = []
	for key in ["sketch_feature_id", "plane_feature_id"]:
		var v = feature.get(key)
		if v != null and str(v) != "":
			out.append(str(v))
	for body_id in feature.get("target_body_ids", []):
		out.append(base_id(str(body_id)))
	for ref in feature.get("edge_refs", []):
		out.append(base_id(str((ref as Dictionary).get("body_id", ""))))
	for ref in feature.get("face_refs", []):
		var inner = (ref as Dictionary).get("face_ref", ref)
		out.append(base_id(str((inner as Dictionary).get("body_id", ""))))
	return out


static func dependents(features: Array, feature_id: String) -> Array:
	## The ids of every feature that would go with `feature_id` in a cascade delete (not including it), in list order: those built
	## on it, and those built on those. The backend's own answer is what actually happens; this is for the "Sure?" text.
	var gone := {feature_id: true}
	var out: Array = []
	var changed := true
	while changed:
		changed = false
		for f in features:
			var id := str(f.get("id", ""))
			if gone.has(id):
				continue
			for dep in dependencies(f):
				if gone.has(dep):
					gone[id] = true
					out.append(id)
					changed = true
					break
	return features.map(func(f): return str(f.get("id", ""))).filter(func(id): return out.has(id))


static func rolled_back_ids(features: Array, index: int) -> Array:
	## "Roll back to here": the ids of every feature AFTER row `index`, in order.
	var out: Array = []
	for i in range(index + 1, features.size()):
		out.append(str(features[i].get("id", "")))
	return out


static func body_names(body_ids: Array) -> Dictionary:
	## body id -> "Body 1", "Body 2"..., in the order the ids are given.
	var out := {}
	for id in body_ids:
		if not out.has(str(id)):
			out[str(id)] = "Body %d" % (out.size() + 1)
	return out


static func faces_of(feature_id: String, tri_body_ids: Array, tri_face_ids: Array, only_body := "") -> Array:
	## The faces (as {body_id, index} pairs, each once) of the bodies the feature made, or of the one body `only_body` names, from
	## the part's per-triangle ids.
	var seen := {}
	var out: Array = []
	for i in mini(tri_body_ids.size(), tri_face_ids.size()):
		var body := str(tri_body_ids[i])
		if only_body != "" and body != only_body:
			continue
		if only_body == "" and base_id(body) != feature_id:
			continue
		var key := "%s:%d" % [body, int(tri_face_ids[i])]
		if seen.has(key):
			continue
		seen[key] = true
		out.append({"body_id": body, "index": int(tri_face_ids[i])})
	return out


static func entity(kind: String, body_id: String, index: int) -> Dictionary:
	## What FaceHighlight.set_set takes for one face or edge.
	return {"kind": kind, "body_id": body_id, "index": index, "key": TopologyPick.entity_key(kind, body_id, index)}
