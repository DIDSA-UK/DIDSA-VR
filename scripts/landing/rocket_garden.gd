extends Node3D
## The rocket garden: the demo rockets standing at true size (1:1, metres) 40-60 m out on the ground behind the logo, each
## with a name plate and its height. Scenery: no colliders, not grabbable, no shadows (about 135k triangles in all, so the
## shadow pass would cost more than it shows; not measured on a Quest). Built one model per frame so the landing doesn't hitch.
##
## The garden node sits on the floor where the user stands and faces the way the logo does; the rockets stand on an arc in its
## local space, the tallest nearest the middle (the logo hangs in the gap dead ahead, 14 degrees either side, so no rocket or plate sits behind it).

const DemoCatalog := preload("res://scripts/landing/demo_catalog.gd")
const SLOTS: Array[Vector2] = [ ## (azimuth in degrees from straight ahead, + to the right; distance in metres), in the catalogue's order
	Vector2(24.0, 60.0), Vector2(-22.0, 52.0), Vector2(38.0, 46.0), Vector2(-38.0, 42.0), Vector2(54.0, 40.0),
]
const PLATE_PIXEL_SIZE_PER_METRE := 0.00045 ## metres per label pixel for each metre of distance, so a plate reads about as large from the user at 40 m as at 60 m
const PLATE_CLEARANCE := 3.0 ## metres in front of the rocket's nearest edge

signal built ## every rocket is in (or failed and was skipped)

var entries: Array[Dictionary] = [] ## [{id, name, node, plate, height (the largest dimension), position}] for each rocket that loaded
var is_built := false
var _plates: Array[Label3D] = []


func build() -> void:
	## Loads the rockets from demo/rockets, one per frame. Safe to call once.
	if is_built or not entries.is_empty():
		return
	var rockets := DemoCatalog.models("rocket").slice(0, SLOTS.size())
	for i in rockets.size():
		if not is_inside_tree():
			return
		_add_rocket(rockets[i], SLOTS[i])
		await get_tree().process_frame
	is_built = true
	built.emit()


func _add_rocket(model: Dictionary, slot: Vector2) -> void:
	var scene := load_glb_scene(model["path"])
	if scene == null:
		push_warning("DIDSA VR: garden: couldn't load %s" % model["path"])
		return
	var azimuth := deg_to_rad(slot.x)
	var spot := Vector3(sin(azimuth) * slot.y, 0.0, -cos(azimuth) * slot.y)
	var holder := Node3D.new()
	holder.name = str(model["id"])
	holder.position = spot
	holder.rotation.y = -azimuth # square to the user, so the plate side faces them
	add_child(holder)
	holder.add_child(scene)
	_no_shadows(scene)
	var box := DemoCatalog.bounds(scene)
	var extent := maxf(box.size.y, maxf(box.size.x, box.size.z)) # a rocket's height; Pegasus XL lies horizontal (it is launched from under an aircraft), so its length
	var plate := _make_plate(str(model["name"]), extent, slot.y)
	plate.position = Vector3(0.0, 1.5, maxf(box.end.z, box.size.x * 0.5) + PLATE_CLEARANCE)
	holder.add_child(plate)
	_plates.append(plate)
	entries.append({"id": model["id"], "name": model["name"], "node": holder, "plate": plate, "height": extent, "position": spot})


static func load_glb_scene(path: String) -> Node3D:
	## A demo glb read straight from its file as a scene (the same GLTFDocument route the app uses for any glb), or null.
	if not FileAccess.file_exists(path):
		return null
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_buffer(FileAccess.get_file_as_bytes(path), path.get_base_dir(), state) != OK:
		return null
	return document.generate_scene(state) as Node3D


func _make_plate(display_name: String, extent: float, distance: float) -> Label3D:
	var plate := Label3D.new()
	plate.text = "%s\n%.1f m" % [display_name, extent]
	plate.font_size = 64
	plate.pixel_size = PLATE_PIXEL_SIZE_PER_METRE * distance
	plate.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y # turns about the vertical to face the user as they walk
	plate.shaded = false
	plate.double_sided = true
	plate.modulate = Color(1, 1, 1, 0.92)
	plate.outline_size = 12
	plate.outline_modulate = Color(0.02, 0.03, 0.05, 0.9)
	plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	plate.name = "Plate"
	return plate


func _no_shadows(root: Node) -> void:
	if root is GeometryInstance3D:
		(root as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in root.get_children():
		_no_shadows(child)


func plate_texts() -> PackedStringArray:
	var out := PackedStringArray()
	for plate in _plates:
		out.append(plate.text)
	return out


func triangle_count() -> int:
	## Triangles in every rocket loaded (the scope puts the whole garden at about 135k).
	var total := 0
	for mesh_node in find_children("*", "MeshInstance3D", true, false):
		var mesh := (mesh_node as MeshInstance3D).mesh
		if mesh == null:
			continue
		for surface in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface)
			var indices = arrays[Mesh.ARRAY_INDEX]
			total += (indices.size() if indices != null and indices.size() > 0 else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return total
