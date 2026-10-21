extends Node3D
## The landing's setting: while it is up the world is a night launch pad instead of the grey grid: a deep sky with stars and a warm horizon, fog that
## softens the far rockets, a dark pad with an engineering grid, a cool key light from the side and a warm rim light from behind the rockets, no shadows.
## It takes over the world's Environment, sun and floor and gives them back exactly as it found them when the landing ends. Passthrough (the Scan page, View >
## Environment) lays the real room over all of it, so the sky and pad step aside while that scene is on. Everything is cheap on purpose (a sky shader that
## runs once, exponential fog, an unshaded pad, two directional lights without shadows): none of it has been measured on a Quest.

const SKY_SHADER := preload("res://shaders/landing_sky.gdshader")
const PAD_SHADER := preload("res://shaders/landing_pad.gdshader")
const FOG_COLOUR := Color(0.035, 0.07, 0.15)
const AMBIENT := Color(0.10, 0.14, 0.26)
const KEY_COLOUR := Color(0.62, 0.76, 1.0)
const RIM_COLOUR := Color(1.0, 0.58, 0.30)

var active := false
var pad: MeshInstance3D
var rim: DirectionalLight3D
var _main: Node
var _world_environment: WorldEnvironment
var _sun: DirectionalLight3D
var _ground: Node3D
var _saved := {}
var _passthrough := false
var _sky: Sky
var _pad_material: ShaderMaterial


func setup(p_main: Node, world_environment: WorldEnvironment, sun: DirectionalLight3D, ground: Node3D) -> void:
	_main = p_main
	_world_environment = world_environment
	_sun = sun
	_ground = ground
	pad = MeshInstance3D.new()
	pad.name = "Pad"
	var plane := PlaneMesh.new()
	plane.size = Vector2(700.0, 700.0)
	_pad_material = ShaderMaterial.new()
	_pad_material.shader = PAD_SHADER
	plane.material = _pad_material
	pad.mesh = plane
	pad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pad.extra_cull_margin = 1000.0 # a plane this large must never be culled by its own centre
	pad.visible = false
	add_child(pad)
	rim = DirectionalLight3D.new()
	rim.name = "Rim"
	rim.light_color = RIM_COLOUR
	rim.light_energy = 1.6
	rim.shadow_enabled = false
	rim.visible = false
	add_child(rim)
	_sky = Sky.new()
	var sky_material := ShaderMaterial.new()
	sky_material.shader = SKY_SHADER
	_sky.sky_material = sky_material
	_sky.radiance_size = Sky.RADIANCE_SIZE_32
	if _world_environment != null and _world_environment.has_signal("scene_changed"):
		_world_environment.scene_changed.connect(_on_scene_changed)


func enter(floor_centre: Vector3, forward: Vector3) -> void:
	## Takes over the setting. `floor_centre` is where the user stands (the rings and spokes centre on it), `forward` the way the garden faces.
	if _world_environment == null:
		return
	if not active:
		_snapshot()
		active = true
	_passthrough = _main.current_scene() == "Passthrough"
	_pad_material.set_shader_parameter("centre", Vector2(floor_centre.x, floor_centre.z))
	pad.global_position = Vector3(floor_centre.x, floor_centre.y + 0.004, floor_centre.z)
	# the rim light travels from behind the rockets towards the user, a little downward; the key from the left front, a little above
	rim.global_transform = Transform3D(Basis.looking_at(_toward_user(forward), Vector3.UP), floor_centre)
	_apply()


func leave() -> void:
	if not active:
		return
	active = false
	pad.visible = false
	rim.visible = false
	if _ground != null:
		_ground.visible = bool(_saved.get("ground_visible", true))
	if not _passthrough: # while passthrough is on the environment manager owns the environment: leave what it set
		_restore()
	_saved = {}


func _toward_user(forward: Vector3) -> Vector3:
	return Vector3(forward.x, -0.20, forward.z).normalized()


func _apply() -> void:
	var env := _world_environment.environment
	pad.visible = not _passthrough
	rim.visible = not _passthrough
	if _ground != null:
		_ground.visible = false # the pad is the floor (its collider stays: teleporting works as before)
	if _passthrough:
		_sun.visible = true
		return
	env.background_mode = Environment.BG_SKY
	env.sky = _sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = AMBIENT
	env.ambient_light_energy = 1.0
	env.fog_enabled = true
	env.fog_light_color = FOG_COLOUR
	env.fog_density = 0.0065
	env.fog_sky_affect = 0.0
	_sun.light_color = KEY_COLOUR
	_sun.light_energy = 1.25
	_sun.shadow_enabled = false
	_sun.rotation_degrees = Vector3(-24.0, -38.0, 0.0)


func _snapshot() -> void:
	var env := _world_environment.environment
	_saved = {
		"background_mode": env.background_mode, "background_color": env.background_color, "sky": env.sky,
		"ambient_source": env.ambient_light_source, "ambient_color": env.ambient_light_color, "ambient_energy": env.ambient_light_energy,
		"fog_enabled": env.fog_enabled, "fog_light_color": env.fog_light_color, "fog_density": env.fog_density, "fog_sky_affect": env.fog_sky_affect,
		"sun_transform": _sun.transform, "sun_energy": _sun.light_energy, "sun_color": _sun.light_color, "sun_shadows": _sun.shadow_enabled,
		"ground_visible": _ground.visible if _ground != null else true,
	}


func _restore() -> void:
	var env := _world_environment.environment
	env.background_mode = _saved["background_mode"]
	env.background_color = _saved["background_color"]
	env.sky = _saved["sky"]
	env.ambient_light_source = _saved["ambient_source"]
	env.ambient_light_color = _saved["ambient_color"]
	env.ambient_light_energy = _saved["ambient_energy"]
	env.fog_enabled = _saved["fog_enabled"]
	env.fog_light_color = _saved["fog_light_color"]
	env.fog_density = _saved["fog_density"]
	env.fog_sky_affect = _saved["fog_sky_affect"]
	_sun.transform = _saved["sun_transform"]
	_sun.light_energy = _saved["sun_energy"]
	_sun.light_color = _saved["sun_color"]
	_sun.shadow_enabled = _saved["sun_shadows"]


func _on_scene_changed(scene_name: String) -> void:
	## Passthrough on: the sky and pad step aside (the environment manager has just set what passthrough needs). Passthrough off: take the setting back.
	if not active:
		return
	var now := scene_name == "Passthrough"
	if now == _passthrough:
		return
	_passthrough = now
	if not now:
		var kept := _saved.duplicate()
		_snapshot() # the manager has just set a normal scene: that is what to give back at the end
		_saved["ground_visible"] = kept.get("ground_visible", true)
	_apply()
