extends WorldEnvironment
## Scene switching for the wrist tablet's View > Environment tab: three
## rendered look presets (Light/Dark/Mid) plus Passthrough (OpenXR mixed
## reality — the headset's own camera feed, composited by the runtime, not
## drawn by Godot). Owns this node's own Environment resource and the
## scene's one DirectionalLight3D; switching only touches their properties,
## never the floor grid or the model, so parts read consistently across all
## three rendered presets.
##
## Passthrough: per Godot's own OpenXR passthrough flow (start_passthrough()/
## stop_passthrough() on the OpenXRInterface, added alongside
## is_passthrough_supported()), the viewport must render with a fully
## transparent clear colour wherever nothing else is drawn, so the
## runtime's own passthrough compositor layer shows through those pixels.
## On desktop (no headset, or a non-Quest runtime without the passthrough
## extension) this falls back to a plain black background and warns once —
## there's no camera feed to show outside a real headset.

signal scene_changed(scene_name: String)

const SCENES: Array[String] = ["Light", "Dark", "Mid", "Passthrough"]

var _sun: DirectionalLight3D
var _xr_interface: XRInterface
var _viewport: Viewport
var current_scene: String = "Mid"

const _PRESETS := {
	"Light": {
		"bg": Color(0.82, 0.85, 0.89),
		"ambient": Color(0.85, 0.87, 0.9),
		"ambient_energy": 1.1,
		"sun_energy": 1.15,
		"sun_color": Color(1.0, 0.98, 0.94),
	},
	"Dark": {
		"bg": Color(0.02, 0.02, 0.03),
		"ambient": Color(0.05, 0.06, 0.09),
		"ambient_energy": 0.5,
		"sun_energy": 0.55,
		"sun_color": Color(0.75, 0.82, 1.0),
	},
	"Mid": {
		"bg": Color(0.32, 0.34, 0.37),
		"ambient": Color(0.4, 0.42, 0.45),
		"ambient_energy": 0.85,
		"sun_energy": 0.9,
		"sun_color": Color(1.0, 1.0, 1.0),
	},
}


func setup(sun: DirectionalLight3D, xr_interface: XRInterface, viewport: Viewport) -> void:
	_sun = sun
	_xr_interface = xr_interface
	_viewport = viewport
	if environment == null:
		environment = Environment.new()
	set_scene(current_scene)


func set_scene(scene_name: String) -> void:
	if scene_name == "Passthrough":
		_enable_passthrough()
	else:
		_disable_passthrough()
		_apply_preset(_PRESETS[scene_name] if _PRESETS.has(scene_name) else _PRESETS["Mid"])
	current_scene = scene_name
	scene_changed.emit(current_scene)


func _apply_preset(p: Dictionary) -> void:
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = p["bg"]
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = p["ambient"]
	environment.ambient_light_energy = p["ambient_energy"]
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	if _sun:
		_sun.visible = true
		_sun.light_energy = p["sun_energy"]
		_sun.light_color = p["sun_color"]


func _enable_passthrough() -> void:
	if _sun:
		# A real room already has its own light; a dim sun keeps virtual
		# parts readable in front of a dark wall without washing out the
		# camera feed the way a full-strength directional light would.
		_sun.light_energy = 0.35
		_sun.light_color = Color(1.0, 1.0, 1.0)
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0, 0, 0, 0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.6, 0.6, 0.6)
	environment.ambient_light_energy = 0.6
	if _viewport:
		_viewport.transparent_bg = true
	RenderingServer.set_default_clear_color(Color(0, 0, 0, 0))
	if _xr_interface is OpenXRInterface:
		var xr: OpenXRInterface = _xr_interface
		if xr.is_passthrough_supported():
			if not xr.start_passthrough():
				push_warning("DIDSA VR: OpenXR passthrough is supported but failed to start — showing black instead.")
		else:
			push_warning("DIDSA VR: this headset/runtime doesn't support OpenXR passthrough — showing black instead of a camera feed.")
	else:
		push_warning("DIDSA VR: no OpenXR interface active (desktop preview) — Passthrough shows black instead of a camera feed.")


func _disable_passthrough() -> void:
	if _viewport:
		_viewport.transparent_bg = false
	RenderingServer.set_default_clear_color(Color(0, 0, 0, 1))
	if _xr_interface is OpenXRInterface:
		var xr: OpenXRInterface = _xr_interface
		if xr.is_passthrough_supported():
			xr.stop_passthrough()


func is_passthrough_supported() -> bool:
	return _xr_interface is OpenXRInterface and (_xr_interface as OpenXRInterface).is_passthrough_supported()
