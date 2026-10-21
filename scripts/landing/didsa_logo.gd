extends Node3D
## The DIDSA logo in 3D (ui/logo/didsa_logo.glb: 1.2 m wide, facing +Z, nodes Emblem / Porthole / Wordmark / Tagline),
## with its idle animation: the porthole pulses (it swells a little and its glow breathes) and the whole logo sways slowly.
## Both stop for Settings > Comfort > Reduce motion (UiFeedback.reduce_motion), and the logo then rests facing straight ahead.
## The emblem traces as one connected shape (planet ring, orbit band, rocket and exhaust touch), so the rocket cannot glide
## along the orbit by itself: see docs/landing-scope.md, Logo.

const LOGO_PATH := "res://ui/logo/didsa_logo.glb"
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const SWAY_DEGREES := 3.0 ## each way
const SWAY_SECONDS := 14.0 ## one full sway there and back
const PULSE_SECONDS := 2.6
const PULSE_SCALE := 0.22 ## the porthole swells by up to this much
const GLOW_BASE := 1.0 ## the porthole's emission energy at rest ...
const GLOW_PEAK := 2.4 ## ... and at the top of the pulse

var porthole: MeshInstance3D
var _porthole_centre := Vector3.ZERO ## the porthole's centre in the logo's own space (the mesh is authored in place)
var _glow: StandardMaterial3D
var _clock := 0.0
var _scene: Node3D
var night_glow := 0.55 ## emission added to the logo's white so it glows against a dark sky (0 = none)


func _ready() -> void:
	_scene = _load_scene()
	if _scene == null:
		push_warning("DIDSA VR: couldn't load %s" % LOGO_PATH)
		return
	add_child(_scene)
	porthole = _scene.find_child("Porthole", true, false) as MeshInstance3D
	for node in _scene.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF # a flat sign: nothing to gain from a shadow
	if porthole != null:
		_porthole_centre = porthole.get_aabb().get_center()
		var source := porthole.get_active_material(0) as StandardMaterial3D
		if source != null:
			_glow = source.duplicate() as StandardMaterial3D # its own copy: the other parts share the glb's material
			_glow.emission_enabled = true
			porthole.set_surface_override_material(0, _glow)
	_glow_parts()
	apply_pose()


func _glow_parts() -> void:
	## The white parts get an emission of their own colour, so they read as lit signage on a night sky.
	if night_glow <= 0.0:
		return
	for node in _scene.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := node as MeshInstance3D
		if mesh_node == porthole or mesh_node.mesh == null:
			continue
		for surface in mesh_node.mesh.get_surface_count():
			var source := mesh_node.get_active_material(surface) as StandardMaterial3D
			if source == null:
				continue
			var lit := source.duplicate() as StandardMaterial3D
			lit.emission_enabled = true
			lit.emission = lit.albedo_color
			lit.emission_energy_multiplier = night_glow
			mesh_node.set_surface_override_material(surface, lit)


static func _load_scene() -> Node3D:
	## The imported scene (the editor, an exported build). A checkout that has not been imported (headless CI, `--script` runs) has no imported copy, so the raw
	## glb is read instead, the way the demo models are; the glb is not packed into an export, which is why the imported one comes first.
	if ResourceLoader.exists(LOGO_PATH, "PackedScene"):
		var packed := load(LOGO_PATH) as PackedScene
		if packed != null:
			return packed.instantiate() as Node3D
	return preload("res://scripts/landing/rocket_garden.gd").load_glb_scene(LOGO_PATH)


func part_names() -> PackedStringArray:
	## The logo's named parts that were found (the test checks the glb still has all four).
	var found := PackedStringArray()
	if _scene == null:
		return found
	for part_name in ["Emblem", "Porthole", "Wordmark", "Tagline"]:
		if _scene.find_child(part_name, true, false) != null:
			found.append(part_name)
	return found


func _process(delta: float) -> void:
	if not visible or _scene == null:
		return
	if UiFeedback.reduce_motion:
		if _clock != 0.0:
			_clock = 0.0
			apply_pose()
		return
	_clock += delta
	apply_pose()


func apply_pose() -> void:
	## The logo's pose at the current clock (0 = rest): a slow sway about the vertical and the porthole's pulse.
	if _scene == null:
		return
	_scene.rotation.y = deg_to_rad(SWAY_DEGREES) * sin(_clock * TAU / SWAY_SECONDS)
	if porthole == null:
		return
	var pulse := 0.5 - 0.5 * cos(_clock * TAU / PULSE_SECONDS) # 0 at rest, 1 at the top
	var s := 1.0 + PULSE_SCALE * pulse
	porthole.scale = Vector3(s, s, s)
	porthole.position = _porthole_centre * (1.0 - s) # swell about its own centre
	if _glow != null:
		_glow.emission_energy_multiplier = lerpf(GLOW_BASE, GLOW_PEAK, pulse)


func pulse_amount() -> float:
	## How far the porthole has swollen, 0..1 (tests read it to see that the pulse runs and that reduce motion stops it).
	if porthole == null:
		return 0.0
	return (porthole.scale.x - 1.0) / PULSE_SCALE


func set_clock(seconds: float) -> void:
	_clock = seconds
	apply_pose()
