extends WorldEnvironment
## Scene switching for the wrist tablet's View > Environment tab: three
## rendered look presets (Light/Dark/Mid) plus Passthrough (OpenXR mixed
## reality — the headset's own camera feed, composited by the runtime, not
## drawn by Godot). Owns this node's own Environment resource and the
## scene's one DirectionalLight3D; switching only touches their properties,
## never the floor grid or the model, so parts read consistently across all
## three rendered presets.
##
## Passthrough: Godot 4.3+'s unified way (docs: tutorials/xr/ar_passthrough) is the
## ENVIRONMENT BLEND MODE: ask the runtime which modes it offers
## (get_supported_environment_blend_modes()); if ALPHA_BLEND is there set it and make
## the viewport's background transparent (alpha blended over the camera feed, and Godot
## performs the platform's extra "turn passthrough on" steps itself); else ADDITIVE with a
## black background. Only if the runtime offers neither is the older
## start_passthrough() tried. (The first version of this file used ONLY that older call
## and never set a blend mode, which is why passthrough did nothing over a PC link.)
## Leaving Passthrough sets OPAQUE again. Whatever happened is described in
## passthrough_status(), which the tablet's Environment page shows, so a failure says
## WHY (what the runtime offers) instead of just showing black. On desktop (no headset) it
## falls back to a plain black background.

signal scene_changed(scene_name: String)

const SCENES: Array[String] = ["Light", "Dark", "Mid", "Passthrough"]

var _sun: DirectionalLight3D
var _xr_interface: Object ## the OpenXRInterface (duck-typed so tests can pass a fake)
var _viewport: Viewport
var _grid_material: ShaderMaterial ## the floor's infinite_grid.gdshader material; its line colour follows the scene
var current_scene: String = "Mid"
var passthrough_active := false ## the camera feed is being shown (by any method)
var _focussed := false ## the OpenXR session has had focus at least once
var passthrough_report := "" ## what Passthrough did and why — see passthrough_status()

## Light/Dark/Mid deliberately share ONE lighting rig (the Mid look: models
## read the same grey in all three) and differ only in background colour and
## floor-grid colour. Real-headset feedback: in Light and Dark the models were
## nearly the background colour. Cause (confirmed against a real backend glb,
## whose parts import with a pure-white albedo, metallic 0, roughness 1): the
## old per-scene ambient/sun energies. Light (ambient 1.1 + sun 1.15) blew a
## white part out to about the pale background; Dark (ambient 0.5 x near-black
## colour) left every face the sun doesn't reach almost black. One shared
## rig keeps an ambient floor so no face is ever black and nothing blows out.
const _RIG := {
	"ambient": Color(0.4, 0.42, 0.45),
	"ambient_energy": 0.85,
	"sun_energy": 0.9,
	"sun_color": Color(1.0, 1.0, 1.0),
}
const _GRID_WHITE := Color(1.0, 1.0, 1.0, 0.4) # infinite_grid.gdshader's own default
const _GRID_CHARCOAL := Color(0.2, 0.21, 0.23, 0.6) # Light scene: white lines vanish against a pale background

const _PRESETS := {
	"Light": {"bg": Color(0.82, 0.85, 0.89), "grid": _GRID_CHARCOAL},
	"Dark": {"bg": Color(0.02, 0.02, 0.03), "grid": _GRID_WHITE},
	"Mid": {"bg": Color(0.32, 0.34, 0.37), "grid": _GRID_WHITE},
}


func setup(sun: DirectionalLight3D, xr_interface: Object, viewport: Viewport, grid_material: ShaderMaterial = null) -> void:
	_grid_material = grid_material
	_sun = sun
	_xr_interface = xr_interface
	_viewport = viewport
	if environment == null:
		environment = Environment.new()
	if _xr_interface != null and _xr_interface.has_signal("session_focussed"):
		# The OpenXR session may not be ready when the saved scene is first applied at startup;
		# once the headset has focus, try again if Passthrough was wanted but didn't take.
		_xr_interface.connect("session_focussed", _on_session_focussed)
	set_scene(current_scene)


func set_scene(scene_name: String) -> void:
	if scene_name == "Passthrough":
		_enable_passthrough()
	else:
		_disable_passthrough()
		_apply_preset(_PRESETS[scene_name] if _PRESETS.has(scene_name) else _PRESETS["Mid"])
	current_scene = scene_name
	scene_changed.emit(current_scene)


func apply_saved_scene(scene_name: String) -> void:
	## The scene remembered from the last run, applied at startup. Passthrough waits for the headset to have focus (session_focussed): asking an
	## OpenXR runtime for the passthrough layer while the session is still starting is a way to drop a Virtual Desktop / Link connection.
	if scene_name == "Passthrough" and _xr_ready() and not _focussed:
		current_scene = scene_name
		_apply_preset(_PRESETS["Mid"])
		passthrough_report = "Passthrough will start once the headset has focus. If it does not, pick another scene and then Passthrough again."
		scene_changed.emit(current_scene)
		return
	set_scene(scene_name)


func _on_session_focussed() -> void:
	_focussed = true
	if current_scene == "Passthrough" and not passthrough_active:
		_enable_passthrough()
		scene_changed.emit(current_scene) # so the tablet's status line refreshes


func _apply_preset(p: Dictionary) -> void:
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = p["bg"]
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = _RIG["ambient"]
	environment.ambient_light_energy = _RIG["ambient_energy"]
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	if _sun:
		_sun.visible = true
		_sun.light_energy = _RIG["sun_energy"]
		_sun.light_color = _RIG["sun_color"]
	_set_grid_color(p["grid"])


func _set_grid_color(color: Color) -> void:
	if _grid_material:
		_grid_material.set_shader_parameter("line_color", color)


func _xr_ready() -> bool:
	return _xr_interface != null and is_instance_valid(_xr_interface) and _xr_interface.has_method("is_initialized") and _xr_interface.is_initialized()


func _blend_mode_names(modes: Array) -> String:
	var names := []
	for m in modes:
		names.append({XRInterface.XR_ENV_BLEND_MODE_OPAQUE: "opaque", XRInterface.XR_ENV_BLEND_MODE_ADDITIVE: "additive", XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND: "alpha-blend"}.get(m, "mode %s" % str(m)))
	return ", ".join(names) if not names.is_empty() else "none reported"


func _enable_passthrough() -> void:
	_set_grid_color(_GRID_WHITE)
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
	passthrough_active = false
	if not _xr_ready():
		passthrough_report = "No headset runtime is active (desktop preview), so there is no camera feed: showing a transparent/black background."
		_set_transparent(true)
		push_warning("DIDSA VR: " + passthrough_report)
		return

	var modes: Array = _xr_interface.get_supported_environment_blend_modes()
	var offered := _blend_mode_names(modes)
	var legacy_note := ""
	if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in modes:
		_xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
		_set_transparent(true)
		passthrough_active = true
		passthrough_report = "Passthrough ON (alpha blend). The runtime offers: %s." % offered
	elif XRInterface.XR_ENV_BLEND_MODE_ADDITIVE in modes:
		_xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ADDITIVE
		_set_transparent(false)
		environment.background_color = Color(0, 0, 0, 1) # additive: black adds nothing, so the real world shows through
		passthrough_active = true
		passthrough_report = "Passthrough ON (additive: virtual parts look semi-transparent). The runtime offers: %s." % offered
	elif _xr_interface.has_method("is_passthrough_supported") and _xr_interface.is_passthrough_supported():
		_set_transparent(true)
		if _xr_interface.start_passthrough():
			passthrough_active = true
			passthrough_report = "Passthrough ON (the headset's own passthrough layer). The runtime offers blend modes: %s." % offered
		else:
			legacy_note = " The headset's passthrough layer is available but failed to start."
	if not passthrough_active:
		_set_transparent(true)
		passthrough_report = "Passthrough is NOT available from this runtime. It offers blend modes: %s%s.%s %s" % [offered, "" if legacy_note != "" else ", and no passthrough layer", legacy_note, _fix_advice()]
		push_warning("DIDSA VR: " + passthrough_report)
	print("DIDSA VR: ", passthrough_report)


func _fix_advice() -> String:
	## What to change when the runtime would not give the camera feed: it depends on whether this is the Quest app itself or a PC link.
	if OS.get_name() == "Android":
		return "On the headset the APK must declare passthrough in its manifest. In the Export dialog: XR Features > Enable Meta Plugin ticked (off by default; without it nothing Meta goes into the APK), and Meta XR Features > Passthrough shown and set to Optional (if it is not shown, the editor read xr/openxr/extensions/meta/passthrough as off). See docs/android-build.md. Re-export, and leave the headset's own Passthrough setting on."
	return "Over a PC link, turn on Passthrough over Link in the Meta Quest Link / Horizon app (Settings > Beta), or the passthrough setting of your streaming app (Virtual Desktop), then choose Passthrough again."


func _set_transparent(on: bool) -> void:
	if _viewport:
		_viewport.transparent_bg = on
	RenderingServer.set_default_clear_color(Color(0, 0, 0, 0) if on else Color(0, 0, 0, 1))


func _disable_passthrough() -> void:
	var was_active := passthrough_active
	passthrough_active = false
	passthrough_report = ""
	_set_transparent(false)
	if _xr_ready():
		var modes: Array = _xr_interface.get_supported_environment_blend_modes()
		if XRInterface.XR_ENV_BLEND_MODE_OPAQUE in modes and _xr_interface.environment_blend_mode != XRInterface.XR_ENV_BLEND_MODE_OPAQUE:
			_xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE # back to full VR
		if was_active and _xr_interface.has_method("is_passthrough_supported") and _xr_interface.is_passthrough_supported():
			_xr_interface.stop_passthrough()


func is_passthrough_supported() -> bool:
	## True if this runtime can show the camera feed by ANY method: an alpha-blend or additive
	## environment blend mode, or the headset's own passthrough layer.
	if not _xr_ready():
		return false
	var modes: Array = _xr_interface.get_supported_environment_blend_modes()
	if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in modes or XRInterface.XR_ENV_BLEND_MODE_ADDITIVE in modes:
		return true
	return _xr_interface.has_method("is_passthrough_supported") and _xr_interface.is_passthrough_supported()


func passthrough_status() -> String:
	## One human-readable line (or two) about what Passthrough is doing; "" unless that scene is chosen.
	return passthrough_report if current_scene == "Passthrough" else ""
