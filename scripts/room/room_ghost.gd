extends Node3D
## The outline of a room being placed: follows the laser on the floor until the trigger drops the room there. The wireframe box is the room's own walls in the
## colour it will have, red when it can't go there (it would overlap another room), and a ring on the floor marks the centre. Pure display; room_manager.gd
## decides where it is and whether that spot is allowed.

const Room := preload("res://scripts/room/room.gd")

const OK_TINT := 0.9
const BLOCKED := Color(1.0, 0.25, 0.2)

var _walls: MeshInstance3D
var _ring: MeshInstance3D
var _colour := Color.WHITE
var _valid := true


func setup(half: Vector3, colour: Color) -> void:
	_colour = colour
	_walls = Room.wall_lines(half, colour)
	add_child(_walls)
	_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.18
	torus.outer_radius = 0.22
	torus.rings = 32
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(colour.r, colour.g, colour.b, 0.9)
	torus.material = mat
	_ring.mesh = torus
	_ring.position = Vector3(0.0, -half.y + 0.01, 0.0) # on the floor, under the room's middle
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)
	visible = false


func set_valid(valid: bool) -> void:
	if valid == _valid:
		return
	_valid = valid
	var c := _colour if valid else BLOCKED
	((_walls.mesh as ArrayMesh).surface_get_material(0) as StandardMaterial3D).albedo_color = Color(c.r, c.g, c.b, OK_TINT)
	((_ring.mesh as TorusMesh).material as StandardMaterial3D).albedo_color = Color(c.r, c.g, c.b, OK_TINT)


func is_valid_spot() -> bool:
	return _valid
