extends Node3D
## The rocket garden: the demo rockets standing at true size (1:1, metres) 40-60 m out on the ground behind the logo, each
## with a name plate and its height. Scenery: no colliders, not grabbable, no shadows (about 135k triangles in all, so the
## shadow pass would cost more than it shows; not measured on a Quest). Built one model per frame so the landing doesn't hitch.
##
## The garden node sits on the floor where the user stands and faces the way the logo does; the rockets stand on an arc in its
## local space, the tallest nearest the middle (the logo hangs in the gap dead ahead, 14 degrees either side, so no rocket or plate sits behind it).

const DemoCatalog := preload("res://scripts/landing/demo_catalog.gd")
const DimensionCallout := preload("res://scripts/landing/dimension_callout.gd")
const SLOTS: Array[Vector2] = [ ## (azimuth in degrees from straight ahead, + to the right; distance in metres), in the catalogue's order. All at one distance: an arc round the user,
	## with the middle 70 degrees left clear for the monolith and the logo.
	Vector2(38.0, 50.0), Vector2(-38.0, 50.0), Vector2(72.0, 50.0), Vector2(-72.0, 50.0), Vector2(106.0, 50.0), Vector2(-106.0, 50.0),
]

signal built ## every rocket is in (or failed and was skipped)

var entries: Array[Dictionary] = [] ## [{id, name, node, plate, height (the largest dimension), position}] for each rocket that loaded
var is_built := false
var _plates: Array[Node3D] = [] ## each rocket's dimension callout
var _plate_texts: PackedStringArray = []


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
	var extent := maxf(box.size.y, maxf(box.size.x, box.size.z)) # a rocket's height (the largest dimension, in case one lies flat)
	var callout := DimensionCallout.build(box.size, slot.y, str(model["name"]).to_upper(), "%.1f m" % extent, entries.size())
	callout.position = Vector3(box.get_center().x, 0.0, box.get_center().z)
	holder.add_child(callout)
	holder.add_child(_make_ring(maxf(box.size.x, box.size.z) * 0.5 + 3.5, slot.y))
	_plates.append(callout)
	_plate_texts.append("%s\n%.1f m" % [model["name"], extent])
	entries.append({"id": model["id"], "name": model["name"], "node": holder, "plate": callout, "height": extent, "position": spot})


static func load_glb_scene(path: String) -> Node3D:
	## A demo glb read straight from its file as a scene (the same GLTFDocument route the app uses for any glb), or null.
	if not FileAccess.file_exists(path):
		return null
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_buffer(FileAccess.get_file_as_bytes(path), path.get_base_dir(), state) != OK:
		return null
	return document.generate_scene(state) as Node3D


func _make_ring(radius: float, distance: float) -> MeshInstance3D:
	## A thin glowing ring on the ground round a rocket's foot: it anchors the rocket to the pad. Sized by distance so it is a line, not a thread, from afar.
	var torus := TorusMesh.new()
	var half := maxf(distance * 0.0022, 0.05)
	torus.inner_radius = radius - half
	torus.outer_radius = radius + half
	torus.rings = 48
	torus.ring_segments = 4
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.30, 0.88, 1.0, 0.85)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.disable_fog = true
	torus.material = material
	var node := MeshInstance3D.new()
	node.mesh = torus
	node.position.y = 0.03
	node.scale = Vector3(1.0, 0.05, 1.0)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.name = "Ring"
	return node


func _no_shadows(root: Node) -> void:
	if root is GeometryInstance3D:
		(root as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in root.get_children():
		_no_shadows(child)


func plate_texts() -> PackedStringArray:
	## "Name\nheight m" for each rocket (what its callout says, in the order the rockets were built).
	return _plate_texts


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
