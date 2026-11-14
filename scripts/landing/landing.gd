extends Node3D
## The landing: the first screen, a STATE of main.gd's world (not a scene), so entering and leaving it costs no load and the wrist
## tablet, wheel and locomotion keep working. While it is up: a night-sky pad, the monolith menu (landing_monolith.gd) standing on the floor
## ahead with the DIDSA logo floating above it, and the demo rockets in an arc round the user (scenery: no colliders, not grabbable; the same
## rockets are loaded from Demo models to try grab, scale and turn). It is left by loading anything (main.gd's _show_model() tells it) or by
## the menu's tiles, and comes back from the Home tile on the wrist tablet and the tool wheel (main.go_home()). The model that was loaded stays
## loaded, hidden, and comes back with Continue.
## Scope: docs/landing-scope.md (L1 to L3).

signal entered
signal exited

const DidsaLogo := preload("res://scripts/landing/didsa_logo.gd")
const RocketGarden := preload("res://scripts/landing/rocket_garden.gd")
const LandingMonolith := preload("res://scripts/landing/landing_monolith.gd")
const LandingStage := preload("res://scripts/landing/landing_stage.gd")
const HALO_SHADER := preload("res://shaders/landing_halo.gdshader")
const TipsReel := preload("res://scripts/landing/tips_reel.gd")
const QrScanner := preload("res://scripts/landing/qr_scanner.gd")
const QrReticle := preload("res://scripts/landing/qr_reticle.gd")
const DemoCatalog := preload("res://scripts/landing/demo_catalog.gd")
const RecentFile := preload("res://scripts/landing/recent_file.gd")
const LOGO_DISTANCE := 3.0 ## metres ahead of the user
const LOGO_SCALE := 2.64 ## the logo glb is 1.2 m wide: about 3.2 m at this scale, wider than the monolith it floats above
const LOGO_RISE := 1.05 ## metres above eye height (so the deck below it does not cover it)
const DESK_DISTANCE := 0.8 ## metres ahead: the plinth for "On the desk"
const WAIST_FRACTION := 0.55 ## of eye height: where the plinth's top is

var main: Node
var logo: Node3D
var garden: Node3D
var launcher: Node
var reel: Node
var scanner: Node ## qr_scanner.gd: reads QR codes through the headset's marker tracking; the launcher's Scan page starts and stops it
var reticle: Node3D ## qr_reticle.gd: brackets round each code the headset tracks while the scanner listens (under the XROrigin3D)
var active := false
var plinth: MeshInstance3D
var stage: Node3D ## landing_stage.gd: the night pad (sky, floor, lights) while the landing is up
var _halo: MeshInstance3D
var _camera: XRCamera3D
var _model_hidden := false ## the loaded model is hidden while the landing is up
var _placing_demo := false ## show_demo() is mid-load: the plinth it is about to set up must survive on_model_shown()


func setup(p_main: Node, left: XRController3D, right: XRController3D, camera: XRCamera3D) -> void:
	main = p_main
	_camera = camera
	logo = DidsaLogo.new()
	logo.name = "Logo"
	add_child(logo)
	logo.visible = false
	_halo = MeshInstance3D.new()
	_halo.name = "Halo"
	var quad := QuadMesh.new()
	quad.size = Vector2(6.0, 3.6)
	var halo_material := ShaderMaterial.new()
	halo_material.shader = HALO_SHADER
	quad.material = halo_material
	_halo.mesh = quad
	_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_halo.visible = false
	add_child(_halo)
	stage = LandingStage.new()
	stage.name = "Stage"
	add_child(stage)
	stage.setup(main, main.get_node("WorldEnvironment"), main.get_node("DirectionalLight3D"), main.get_node("Ground/MeshInstance3D"))
	garden = RocketGarden.new()
	garden.name = "RocketGarden"
	add_child(garden)
	garden.visible = false
	plinth = _make_plinth()
	add_child(plinth)
	plinth.visible = false
	launcher = LandingMonolith.new()
	launcher.name = "Launcher"
	add_child(launcher)
	launcher.setup_launcher(left, right, camera, self)
	reel = TipsReel.new()
	reel.name = "TipsReel"
	add_child(reel)
	reel.setup_reel(left, right, camera)
	scanner = QrScanner.new()
	scanner.name = "QrScanner"
	add_child(scanner)
	launcher.attach_scanner(scanner)
	reticle = QrReticle.new()
	reticle.name = "QrReticle"
	reticle.scanner = scanner
	camera.get_parent().add_child.call_deferred(reticle) # marker poses are in the origin's space; deferred: the origin may still be setting up its children
	main.status_changed.connect(launcher.set_status)
	main.server_changed.connect(_on_server_changed)


func _on_server_changed() -> void:
	## A different server (or none): the tiles that need one, the connection pill and the tips list follow.
	reel.set_connected(main.has_backend())
	if launcher.is_open():
		launcher.show_page(launcher.page)


func is_active() -> bool:
	return active


func enter() -> void:
	## Shows the landing in front of where the user is looking now (again, if it is already up).
	if not active:
		active = true
		var model := _model_root()
		if model != null and model.visible:
			model.visible = false
			_model_hidden = true
		plinth.visible = false
	place()
	var forward := _flat_forward()
	stage.enter(Vector3(_camera.global_position.x, _floor_y(), _camera.global_position.z), forward)
	logo.visible = true
	_halo.visible = halo_on
	garden.visible = rockets_on
	if rockets_on and not garden.is_built:
		garden.build()
	launcher.open()
	reel.set_connected(main.has_backend())
	launcher.set_ticker_visible(main.show_tips())
	entered.emit()


func leave() -> void:
	if not active:
		return
	active = false
	logo.visible = false
	_halo.visible = false
	garden.visible = false
	stage.leave()
	launcher.close()
	reel.close()
	var model := _model_root()
	if model != null and _model_hidden:
		model.visible = true
	_model_hidden = false
	exited.emit()


var halo_on := true ## Settings > Graphics check: the additive glow behind the logo
var rockets_on := true ## Settings > Graphics check and graphics.cfg: the rocket garden (off: not even loaded)


func set_rockets_on(on: bool) -> void:
	rockets_on = on
	garden.visible = active and on
	if active and on and not garden.is_built:
		garden.build()


func set_halo_on(on: bool) -> void:
	halo_on = on
	_halo.visible = active and on


func set_show_tips(on: bool) -> void:
	## Settings > Show tips, applied now if the landing is up.
	if active:
		launcher.set_ticker_visible(on)


func place() -> void:
	## The logo 2.5 m ahead at eye height facing the user, the garden on the floor where the user stands facing the same way.
	var forward := _flat_forward()
	var eye := _camera.global_position
	var floor_y := _floor_y()
	var facing := Basis.looking_at(forward, Vector3.UP)
	var logo_at: Vector3 = LandingMonolith.logo_position(eye, forward, floor_y) # above the monolith, separate from it
	logo.global_transform = Transform3D(facing.scaled(Vector3.ONE * LOGO_SCALE), logo_at)
	_halo.global_transform = Transform3D(facing, logo_at + forward * 0.25) # the glow a little behind the logo
	garden.global_transform = Transform3D(Basis.looking_at(forward, Vector3.UP), Vector3(eye.x, floor_y, eye.z))


func on_model_shown() -> void:
	## main.gd just replaced the model: whatever loaded it, the landing is over.
	if not _placing_demo:
		plinth.visible = false
	leave() # shows the model again if the landing had hidden it: the new one sits under the same root


# --- What the tiles do ---------------------------------------------------------------------------------------

func continue_last() -> void:
	var last := RecentFile.last()
	if last.is_empty():
		main.say("Nothing to continue yet: open a file first.")
		return
	main.load_model_file(str(last["path"]))


func open_files() -> void:
	main.open_tablet_at("files")


func open_server_projects() -> void:
	main.open_tablet_at("files", "cloud")


func new_assembly() -> void:
	await main.new_assembly()


func open_assembly(path: String) -> void:
	await main.open_native_file(path)


func open_tablet_settings() -> void:
	main.open_tablet_at("settings")


func show_demo(model: Dictionary, desk: bool) -> void:
	## A demo glb at full size (1:1) in front of the user, or small (1:50) on a plinth at waist height. Loaded like any glb from
	## the Files tab (local_glb_scale 1.0), then placed.
	_placing_demo = true
	var loaded: bool = main.load_glb_file(str(model["path"]), show_demo.bind(model, desk)) # after "Discard and continue", place it the same way
	_placing_demo = false
	if not loaded:
		return
	var scene := _model_scene()
	if scene == null:
		return
	var box := DemoCatalog.bounds(scene)
	var forward := _flat_forward()
	var eye := _camera.global_position
	var floor_y := _floor_y()
	var span := maxf(box.size.x, box.size.z)
	if not desk:
		var distance := maxf(2.5, span * 0.5 + 3.0)
		var spot := Vector3(eye.x, floor_y, eye.z) + forward * distance
		main.place_model(Transform3D(Basis.looking_at(forward, Vector3.UP), spot), 1.0)
		main.say("%s at full size: %.1f m tall." % [model["name"], box.size.y])
		return
	var scale_value := DemoCatalog.desk_scale(maxf(span, box.size.y))
	var waist := (eye.y - floor_y) * WAIST_FRACTION
	var desk_spot := Vector3(eye.x, floor_y + waist, eye.z) + forward * DESK_DISTANCE
	main.place_model(Transform3D(Basis.looking_at(forward, Vector3.UP), desk_spot), scale_value)
	_set_plinth(desk_spot, waist, maxf(span * scale_value * 0.5 + 0.08, 0.2))
	main.say("%s on the desk at %s." % [model["name"], DemoCatalog.ratio_text(scale_value)])


# --- Helpers ----------------------------------------------------------------------------------------------------

func _make_plinth() -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = "Plinth"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.0
	cylinder.bottom_radius = 1.0
	cylinder.height = 1.0
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.16, 0.19, 0.25)
	material.roughness = 0.6
	cylinder.material = material
	instance.mesh = cylinder
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _set_plinth(top_centre: Vector3, height: float, radius: float) -> void:
	plinth.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3(radius, height, radius)), top_centre - Vector3(0.0, height * 0.5, 0.0))
	plinth.visible = true


func _flat_forward() -> Vector3:
	var forward := -_camera.global_transform.basis.z
	forward.y = 0.0
	return Vector3.FORWARD if forward.length() < 0.001 else forward.normalized()


func _floor_y() -> float:
	return _camera.get_parent().global_position.y # the XROrigin sits on the floor


func _model_root() -> Node3D:
	return main.assembly_root as Node3D


func _model_scene() -> Node3D:
	var root := _model_root()
	return root.get_child(0) as Node3D if root != null and root.get_child_count() > 0 else null
