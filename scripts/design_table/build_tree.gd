extends RefCounted
## The numbers and words behind the design table's BUILD tree: the ordered list of everything that built the part on the table
## (planes, sketches, extrudes, fillets, chamfers...), the same tree the flat app shows in its part design lens
## (client/lib/viewport3d/feature_tree_panel.dart). Pure functions over the backend's `GET /document/parts/{id}/features` rows and the
## part's mesh ids, no scene tree, so tests can pin them.

const TopologyPick := preload("res://scripts/topology_pick.gd")
const FeatureTools := preload("res://scripts/design_table/features/feature_tools.gd")

const LABELS := {
	"sketch": "Sketch", "extrude": "Extrude", "create_plane": "Plane", "fillet": "Fillet", "chamfer": "Chamfer",
	"revolve": "Revolve", "sweep": "Sweep", "loft": "Loft", "surface": "Surface", "mirror": "Mirror", "pattern": "Pattern",
	"merge": "Merge", "split": "Split", "shell": "Shell", "import": "Import", "delete_body": "Delete Body",
	"scale_body": "Scale", "move_body": "Move Body", "delete_face": "Delete Face", "move_face": "Move Face",
	"gear": "Gear", "rack": "Rack", "bevel_gear": "Bevel Gear", "curve": "Curve", "spring": "Spring",
}
const EDITABLE := ["extrude", "revolve", "shell", "fillet", "chamfer"] ## the types whose value the table can change (a PATCH of one number)


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
		"shell":
			return "tool_shell"
		"mirror":
			return "tool_mirror"
		"gear":
			return "tool_gear"
		"rack":
			return "tool_rack"
		"curve":
			return "tool_helix"
		"spring":
			return "tool_spring"
		"bevel_gear":
			return "tool_bevel_gear"
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
			var text := "%s %s mm" % ["Cut" if str(f.get("extrude_type", "boss")) == "cut" else "Boss", number(depth)]
			if float(f.get("start_distance", 0.0)) < 0.0 and is_equal_approx(float(f.get("start_distance", 0.0)), -float(f.get("end_distance", 0.0))):
				text += ", both sides"
			if f.get("thickness") != null:
				text += ", wall %s" % number(absf(float(f["thickness"])))
			if f.get("draft_angle") != null:
				text += ", draft %s deg" % number(float(f["draft_angle"]))
			return text
		"revolve":
			var rev_text := "%s %s deg" % ["Cut" if str(f.get("mode", "boss")) == "cut" else "Boss", number(float(f.get("angle", 360.0)))]
			if f.get("thickness") != null:
				rev_text += ", thin %s mm" % number(absf(float(f["thickness"])))
			return rev_text
		"shell":
			return "%s mm, %d face(s) open" % [number(float(f.get("thickness", 0.0))), (f.get("faces_to_remove", []) as Array).size()]
		"mirror":
			var plane = f.get("mirror_plane")
			var which := "a face"
			if plane is Dictionary and plane.get("fixed_plane") != null:
				which = "%s plane" % str(plane["fixed_plane"])
			elif plane is Dictionary and plane.get("plane_feature_id") != null:
				which = "a plane"
			return "across %s" % which
		"fillet":
			return "R %s mm, %d edge(s)" % [number(float(f.get("radius", 0.0))), (f.get("edge_refs", []) as Array).size()]
		"chamfer":
			var chamfer := "%s mm, %d edge(s)" % [number(float(f.get("distance", 0.0))), (f.get("edge_refs", []) as Array).size()]
			if f.get("edge_options") is Dictionary and not (f["edge_options"] as Dictionary).is_empty():
				chamfer += ", angled"
			return chamfer
	var tool = FeatureTools.for_type(str(f.get("type", "")))
	return tool.summary(f, features) if tool != null else ""


static func reference_counts(f: Dictionary) -> Dictionary:
	## {lost, moved}: how many references of a feature the backend says are lost / may have moved (a sketch lists its point ids, other features list
	## their reference paths). A bare `has_lost_reference` with no list (an older backend) counts as one lost.
	var lost: int = (f.get("lost_reference_point_ids", []) as Array).size() + (f.get("lost_references", []) as Array).size()
	var moved: int = (f.get("moved_reference_point_ids", []) as Array).size() + (f.get("moved_references", []) as Array).size()
	if lost == 0 and bool(f.get("has_lost_reference", false)):
		lost = 1
	return {"lost": lost, "moved": moved}


const FIXABLE := ["fillet", "chamfer", "shell", "mirror", "create_plane"] ## the features whose flagged reference can be re-picked from the Build row (their PATCH takes a replacement)


static func fix_target(f: Dictionary) -> Dictionary:
	## What a flagged non-sketch feature needs re-picked: {type, kind ("edge" | "face"), paths: [the backend's reference paths, lost first then moved]}, or {}
	## when nothing is flagged, the feature cannot take a replacement here, or its flagged references are not all edges or all faces. (A sketch is mended in
	## the sketch: Select > Fix.) Paths look like `edge_refs[1]`, `faces_to_remove[0]`, `mirror_plane.face_ref`, `face_refs[0].face_ref`, `edge_ref`.
	var type := str(f.get("type", ""))
	if not FIXABLE.has(type):
		return {}
	var paths: Array = []
	paths.append_array(f.get("lost_references", []))
	for p in f.get("moved_references", []):
		if not paths.has(p):
			paths.append(p)
	if paths.is_empty():
		return {}
	var kind := ""
	for p in paths:
		var this_kind := "edge" if str(p).begins_with("edge_ref") else ("face" if str(p).contains("face") else "")
		if this_kind == "" or (kind != "" and kind != this_kind):
			return {}
		kind = this_kind
	return {"type": type, "kind": kind, "paths": paths}


static func fix_payload(f: Dictionary, paths: Array, picked: Array) -> Dictionary:
	## The PATCH body that swaps the references at `paths` (in order) for the entities `picked` ({body_id, index} each) and keeps every other reference of the
	## feature as it is. {} if a path is not one this knows how to replace or there is not one pick per path.
	if paths.size() != picked.size() or paths.is_empty():
		return {}
	var type := str(f.get("type", ""))
	var edge := func(e: Dictionary) -> Dictionary: return {"body_id": str(e["body_id"]), "shape_type": "edge", "index": int(e["index"])}
	var face := func(e: Dictionary) -> Dictionary: return {"body_id": str(e["body_id"]), "shape_type": "face", "index": int(e["index"])}
	match type:
		"fillet", "chamfer":
			var refs: Array = (f.get("edge_refs", []) as Array).duplicate(true)
			for i in paths.size():
				var at := _path_index(str(paths[i]), "edge_refs")
				if at < 0 or at >= refs.size():
					return {}
				refs[at] = edge.call(picked[i])
			return {"edge_refs": refs}
		"shell":
			var faces: Array = (f.get("faces_to_remove", []) as Array).duplicate(true)
			for i in paths.size():
				var at := _path_index(str(paths[i]), "faces_to_remove")
				if at < 0 or at >= faces.size():
					return {}
				faces[at] = face.call(picked[i])
			return {"faces_to_remove": faces}
		"mirror":
			if paths.size() != 1 or str(paths[0]) != "mirror_plane.face_ref":
				return {}
			return {"mirror_plane": {"face_ref": face.call(picked[0])}}
		"create_plane":
			if paths.size() == 1 and str(paths[0]) == "edge_ref":
				return {"edge_ref": edge.call(picked[0])}
			var plane_faces: Array = (f.get("face_refs", []) as Array).duplicate(true)
			for i in paths.size():
				var at := _path_index(str(paths[i]), "face_refs")
				if at < 0 or at >= plane_faces.size():
					return {}
				plane_faces[at] = {"face_ref": face.call(picked[i])}
			return {"face_refs": plane_faces}
	return {}


static func _path_index(path: String, name: String) -> int:
	## The list position in a path like `edge_refs[2]` or `face_refs[1].face_ref`; -1 if the path is not about `name`.
	if not path.begins_with(name + "["):
		return -1
	return int(path.substr(name.length() + 1, path.find("]") - name.length() - 1))


static func reference_note(f: Dictionary) -> String:
	## The short flag on a Build row: "lost reference", "2 lost references", "reference may have moved", "1 lost, 2 may have moved"; "" if all is well.
	var c := reference_counts(f)
	var lost: int = c["lost"]
	var moved: int = c["moved"]
	if lost == 0 and moved == 0:
		return ""
	if moved == 0:
		return "lost reference" if lost == 1 else "%d lost references" % lost
	if lost == 0:
		return "reference may have moved" if moved == 1 else "%d references may have moved" % moved
	return "%d lost, %d may have moved" % [lost, moved]


static func value_of(feature: Dictionary) -> float:
	## The one number Edit changes: an extrude's depth, a fillet's radius, a chamfer's distance. -1 for a type with none.
	match str(feature.get("type", "")):
		"extrude":
			return absf(float(feature.get("end_distance", 0.0)) - float(feature.get("start_distance", 0.0)))
		"revolve":
			return float(feature.get("angle", 360.0))
		"shell":
			return float(feature.get("thickness", 0.0))
		"fillet":
			return float(feature.get("radius", 0.0))
		"chamfer":
			return float(feature.get("distance", 0.0))
	return -1.0


static func value_title(type: String) -> String:
	return {"extrude": "Depth (mm)", "revolve": "Angle (deg)", "shell": "Thickness (mm)", "fillet": "Radius (mm)", "chamfer": "Distance (mm)"}.get(type, "Value (mm)")


static func edit_payload(feature: Dictionary, new_value: float) -> Dictionary:
	## The PATCH body that gives the feature `new_value`: an extrude keeps its start and direction (the end moves, same sign), a
	## fillet / chamfer replace their one number. {} for a type that has none.
	match str(feature.get("type", "")):
		"extrude":
			var start := float(feature.get("start_distance", 0.0))
			var end := float(feature.get("end_distance", 0.0))
			var direction := 1.0 if end >= start else -1.0
			return {"start_distance": start, "end_distance": start + direction * new_value}
		"revolve":
			return {"angle": new_value}
		"shell":
			return {"thickness": new_value}
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
	var shell_body = feature.get("body_id")
	if shell_body != null and str(shell_body) != "":
		out.append(base_id(str(shell_body)))
	for ref in feature.get("faces_to_remove", []):
		out.append(base_id(str((ref as Dictionary).get("body_id", ""))))
	for body_id in feature.get("source_body_ids", []):
		out.append(base_id(str(body_id)))
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
