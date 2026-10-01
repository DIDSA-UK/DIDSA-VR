extends SceneTree
## Passthrough (scripts/environment_manager.gd) against a FAKE headset runtime — no real
## OpenXR here, so this checks the logic and the diagnostics, not the camera feed itself.
## Real-headset report: choosing the Passthrough environment did nothing. Cause: the old code
## only called the legacy start_passthrough() and never set the environment blend mode that
## Godot 4.3+ uses (docs: tutorials/xr/ar_passthrough). Now: ALPHA_BLEND if the runtime offers it
## (+ transparent viewport), else ADDITIVE, else the legacy layer; OPAQUE again when leaving; the
## reason for any failure is stated; a late-starting session is retried on session_focussed.
## Run: "$GODOT" --headless --path . --script res://tests/passthrough.gd  (see tests/README.md)

class FakeXR extends RefCounted:
	signal session_focussed
	var ready := true
	var modes: Array = [XRInterface.XR_ENV_BLEND_MODE_OPAQUE]
	var legacy_supported := false
	var legacy_starts := true
	var environment_blend_mode: int = XRInterface.XR_ENV_BLEND_MODE_OPAQUE
	var legacy_on := false
	func is_initialized() -> bool: return ready
	func get_supported_environment_blend_modes() -> Array: return modes
	func is_passthrough_supported() -> bool: return legacy_supported
	func start_passthrough() -> bool:
		legacy_on = legacy_starts
		return legacy_starts
	func stop_passthrough() -> void: legacy_on = false

const Env := preload("res://scripts/environment_manager.gd")

func _make(xr) -> Node:
	var we = Env.new()
	root.add_child(we)
	we.setup(null, xr, root)
	return we

func _initialize() -> void:
	var OP := XRInterface.XR_ENV_BLEND_MODE_OPAQUE
	var AD := XRInterface.XR_ENV_BLEND_MODE_ADDITIVE
	var AL := XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND

	# --- a runtime that offers alpha blend (what a Quest over a PC link normally reports)
	var xr := FakeXR.new()
	xr.modes = [OP, AL]
	var we = _make(xr)
	we.set_scene("Passthrough")
	print("SMOKE alpha-blend runtime: the blend mode is SET to alpha blend (the missing step): ", xr.environment_blend_mode == AL)
	print("SMOKE ...the viewport renders a transparent background so the feed shows through: ", root.transparent_bg == true and we.environment.background_color.a == 0.0)
	print("SMOKE ...passthrough is reported ON, naming the method and what the runtime offers: ", we.passthrough_active and we.passthrough_status().contains("ON") and we.passthrough_status().contains("alpha") and we.passthrough_status().contains("opaque"))
	print("SMOKE ...and the legacy passthrough call is NOT also used (Godot's alpha mode does that itself): ", xr.legacy_on == false)
	print("SMOKE is_passthrough_supported() is true for such a runtime: ", we.is_passthrough_supported())
	we.set_scene("Mid")
	print("SMOKE leaving Passthrough restores OPAQUE and an opaque viewport: ", xr.environment_blend_mode == OP and root.transparent_bg == false and not we.passthrough_active)
	print("SMOKE ...and the status goes quiet for ordinary scenes: ", we.passthrough_status() == "")
	we.set_scene("Passthrough")
	print("SMOKE switching back on works again: ", xr.environment_blend_mode == AL and we.passthrough_active)
	we.queue_free()

	# --- additive only (a see-through display)
	xr = FakeXR.new()
	xr.modes = [AD]
	we = _make(xr)
	we.set_scene("Passthrough")
	print("SMOKE additive-only runtime: additive mode, opaque black background (black adds nothing): ", xr.environment_blend_mode == AD and root.transparent_bg == false and we.environment.background_color == Color(0, 0, 0, 1) and we.passthrough_active)
	we.queue_free()

	# --- only the legacy headset layer
	xr = FakeXR.new()
	xr.legacy_supported = true
	we = _make(xr)
	we.set_scene("Passthrough")
	print("SMOKE legacy-layer-only runtime: the layer is started and reported: ", xr.legacy_on and we.passthrough_active and we.passthrough_status().contains("passthrough layer"))
	we.set_scene("Dark")
	print("SMOKE ...and stopped when you leave: ", not xr.legacy_on)
	xr.legacy_starts = false
	we.set_scene("Passthrough")
	print("SMOKE a layer that fails to start is reported as such, not as success: ", not we.passthrough_active and we.passthrough_status().contains("failed to start"))
	we.queue_free()

	# --- nothing offered: say WHY, with what the runtime does offer
	xr = FakeXR.new()
	we = _make(xr)
	we.set_scene("Passthrough")
	print("SMOKE a runtime offering only opaque: passthrough is not claimed ON: ", not we.passthrough_active and not we.is_passthrough_supported())
	print("SMOKE ...the status explains it: what IS offered, and what to check (streaming app setting / Vendors plugin): ", we.passthrough_status().contains("NOT available") and we.passthrough_status().contains("opaque") and we.passthrough_status().contains("Vendors plugin"))
	we.queue_free()

	# --- session not ready at startup: retried when the headset gains focus
	xr = FakeXR.new()
	xr.ready = false
	xr.modes = []
	we = _make(xr)
	we.current_scene = "Passthrough"
	we.set_scene("Passthrough")
	print("SMOKE before the session is ready it doesn't claim success: ", not we.passthrough_active)
	xr.ready = true
	xr.modes = [OP, AL]
	xr.session_focussed.emit()
	print("SMOKE ...and turns on by itself once the headset gains focus: ", we.passthrough_active and xr.environment_blend_mode == AL)
	var changed := [0]
	we.scene_changed.connect(func(_n: String) -> void: changed[0] += 1)
	xr.session_focussed.emit()
	print("SMOKE a later focus event doesn't redo it: ", changed[0] == 0)
	we.queue_free()

	# --- no headset at all (desktop preview)
	we = _make(null)
	we.set_scene("Passthrough")
	print("SMOKE desktop preview (no XR): no crash, honest message: ", not we.passthrough_active and we.passthrough_status().contains("No headset") and not we.is_passthrough_supported())
	we.set_scene("Light")
	print("SMOKE ...and the other scenes still apply: ", we.environment.background_color == Color(0.82, 0.85, 0.89))
	quit()
