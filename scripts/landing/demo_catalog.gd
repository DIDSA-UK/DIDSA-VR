extends RefCounted
## The demo content that ships in the APK (demo/): what the landing lists. The folders are scanned, so a glb dropped into
## demo/rockets/ or demo/spacecraft/ shows up; the table below only gives a nicer name, the size to expect and the order.
## Credits: demo/CREDITS.md. Every glb is 1:1 in metres, Y up, base on the floor at the origin, loaded with scale 1.0.

const MODEL_DIRS := {"rocket": "res://demo/rockets", "spacecraft": "res://demo/spacecraft"}
const ASSEMBLY_FILES: Array[Dictionary] = [
	{"name": "Table top and frame", "path": "res://demo/assemblies/table/Top_and_frame.didsa"},
	{"name": "Plate and peg", "path": "res://demo/assemblies/plate_and_peg/Plate_and_peg.didsa"},
	{"name": "Gear train", "path": "res://demo/assemblies/gear_train/Gear_train.didsa"},
]
const CREDITS_PATH := "res://demo/CREDITS.md"
const DESK_RATIO := 50.0 ## "On the desk" is 1:50 ...
const DESK_MAX_SIZE := 1.5 ## ... unless that would stand taller than this (metres), then the largest side is brought down to it
const INFO := { ## file base name -> {name, height (metres: the published figure the scope checks the glb against; its largest dimension), night_lift (optional: the model is dark metal that vanishes against the night sky, so the garden lifts it)}
	"Saturn_V": {"name": "Saturn V", "height": 110.6},
	"SLS_Block_1": {"name": "SLS Block 1", "height": 98.1},
	"Starship_SN20_BN4": {"name": "Starship SN20 / BN4", "height": 120.0, "night_lift": true},
	"Falcon_Heavy": {"name": "Falcon Heavy", "height": 70.0},
	"Falcon_9": {"name": "Falcon 9", "height": 70.0},
	"Delta_II": {"name": "Delta II", "height": 40.5},
	"Jupiter-C_Explorer_1": {"name": "Jupiter-C", "height": 21.2},
	"Apollo-Soyuz": {"name": "Apollo-Soyuz", "height": 21.6},
	"Hubble_Space_Telescope": {"name": "Hubble Space Telescope", "height": 13.35},
	"Voyager": {"name": "Voyager", "height": 12.3},
	"Pioneer_10": {"name": "Pioneer 10", "height": 2.74},
}
const ORDER: Array[String] = ["Saturn_V", "SLS_Block_1", "Starship_SN20_BN4", "Falcon_Heavy", "Falcon_9", "Delta_II", "Jupiter-C_Explorer_1", "Apollo-Soyuz", "Hubble_Space_Telescope", "Voyager", "Pioneer_10"]


static func models(kind: String = "") -> Array[Dictionary]:
	## [{id, name, kind, path, height, night_lift}] in ORDER (unknown files last, by name); `kind` "rocket" / "spacecraft" or "" for both.
	## `height` is the size to expect, 0 when the file isn't in INFO (the garden measures those itself).
	var found: Array[Dictionary] = []
	for dir_kind in MODEL_DIRS:
		if kind != "" and kind != dir_kind:
			continue
		var dir_path: String = MODEL_DIRS[dir_kind]
		for file_name in _glb_files(dir_path):
			var id := file_name.get_basename()
			var info: Dictionary = INFO.get(id, {})
			found.append({"id": id, "name": info.get("name", id.replace("_", " ")), "kind": dir_kind,
				"path": dir_path.path_join(file_name), "height": float(info.get("height", 0.0)), "night_lift": bool(info.get("night_lift", false))})
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ia := ORDER.find(a["id"])
		var ib := ORDER.find(b["id"])
		if ia == -1 and ib == -1:
			return str(a["name"]) < str(b["name"])
		if ia == -1 or ib == -1:
			return ib == -1
		return ia < ib)
	return found


static func assemblies() -> Array[Dictionary]:
	## [{name, path, exists}]: the demo native files. They need a backend to be meshed, so they are only listed here.
	var out: Array[Dictionary] = []
	for entry in ASSEMBLY_FILES:
		out.append({"name": entry["name"], "path": entry["path"], "exists": FileAccess.file_exists(entry["path"])})
	return out


static func credits_text() -> String:
	## demo/CREDITS.md as it ships (empty if the file is missing from the export).
	if not FileAccess.file_exists(CREDITS_PATH):
		return ""
	return FileAccess.get_file_as_string(CREDITS_PATH)


static func credits_plain() -> String:
	## The credits for the About page: demo/CREDITS.md without the markdown (headings, table pipes, links and backticks), one
	## paragraph per model. The licence text and URLs are kept: CC BY needs them shown.
	var link := RegEx.create_from_string("\\[([^\\]]+)\\]\\(([^)]+)\\)")
	var out := PackedStringArray()
	for raw in credits_text().split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("|"):
			var cells := line.trim_prefix("|").trim_suffix("|").split("|")
			if cells.size() < 4 or cells[0].strip_edges().begins_with("---") or cells[0].strip_edges() == "File":
				continue
			line = "%s: %s. Licence: %s. Changes: %s" % [cells[0].strip_edges(), cells[1].strip_edges(), cells[2].strip_edges(), cells[3].strip_edges()]
		line = line.lstrip("# ")
		line = link.sub(line, "$1 ($2)", true)
		out.append(line.replace("`", "").replace("**", ""))
	return "\n".join(out)


static func desk_scale(largest_side: float) -> float:
	## The scale for "On the desk": 1:50, or smaller if that would be taller than DESK_MAX_SIZE.
	if largest_side <= 0.0:
		return 1.0 / DESK_RATIO
	return minf(1.0 / DESK_RATIO, DESK_MAX_SIZE / largest_side)


static func bounds(root: Node3D) -> AABB:
	## The box round every mesh under `root`, in root's own space (a glb's scene root can itself be the mesh).
	var box := AABB()
	var first := true
	var meshes: Array[Node] = root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		meshes.push_front(root)
	for node in meshes:
		var mesh_node := node as MeshInstance3D
		if mesh_node.mesh == null:
			continue
		var part_box := _relative_transform(root, mesh_node) * mesh_node.get_aabb()
		box = part_box if first else box.merge(part_box)
		first = false
	return box


static func _relative_transform(root: Node3D, node: Node3D) -> Transform3D:
	## `node`'s transform in `root`'s space (works for a scene that is not in the tree yet, which global_transform does not).
	var xf := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != root:
		if current is Node3D:
			xf = (current as Node3D).transform * xf
		current = current.get_parent()
	return xf


static func ratio_text(scale_value: float) -> String:
	return "1:%d" % int(roundf(1.0 / maxf(scale_value, 0.0001)))


static func _glb_files(dir_path: String) -> PackedStringArray:
	## The glb files in a folder. In an export the `.import` sidecars of "keep" files may be listed too; they are skipped.
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for file_name in dir.get_files():
		if file_name.get_extension().to_lower() == "glb":
			out.append(file_name)
	out.sort()
	return out
