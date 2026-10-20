extends Node3D
## The landing: the first screen, a STATE of main.gd's world (not a scene), so entering and leaving it costs no load and the wrist
## tablet, wheel and locomotion keep working. While it is up: the DIDSA logo hangs 2.5 m ahead at eye height, the demo rockets
## stand at true size on the ground behind it, the launcher panel is at arm's reach and the tips reel to its left. It is left by
## loading anything (main.gd's _show_model() tells it) or by the launcher's tiles, and comes back from the Home tile on the wrist
## tablet and the tool wheel (main.go_home()). The model that was loaded stays loaded, hidden, and comes back with Continue.
## Scope: docs/landing-scope.md (L1 to L3).

signal entered
signal exited

const DidsaLogo := preload("res://scripts/landing/didsa_logo.gd")
const RocketGarden := preload("res://scripts/landing/rocket_garden.gd")
const LauncherWindow := preload("res://scripts/landing/launcher_window.gd")
const TipsReel := preload("res://scripts/landing/tips_reel.gd")
const DemoCatalog := preload("res://scripts/landing/demo_catalog.gd")
const RecentFile := preload("res://scripts/landing/recent_file.gd")
const LOGO_DISTANCE := 2.5 ## metres ahead of the user
const LOGO_TAGLINE := "Design and assemble parts at full size."
const DESK_DISTANCE := 0.8 ## metres ahead: the plinth for "On the desk"
const WAIST_FRACTION := 0.55 ## of eye height: where the plinth's top is

var main: Node
var logo: Node3D
var garden: Node3D
var launcher: Node
var reel: Node
var active := false
var plinth: MeshInstance3D
var _caption: Label3D
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
	_caption = Label3D.new()
	_caption.text = LOGO_TAGLINE
	_caption.font_size = 48
	_caption.pixel_size = 0.0011
	_caption.shaded = false
	_caption.modulate = Color(0.85, 0.9, 1.0, 0.9)
	_caption.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_caption.visible = false
	add_child(_caption)
	garden = RocketGarden.new()
	garden.name = "RocketGarden"
	add_child(garden)
	garden.visible = false
	plinth = _make_plinth()
	add_child(plinth)
	plinth.visible = false
	launcher = LauncherWindow.new()
	launcher.name = "Launcher"
	add_child(launcher)
	launcher.setup_launcher(left, right, camera, self)
	reel = TipsReel.new()
	reel.name = "TipsReel"
	add_child(reel)
	reel.setup_reel(left, right, camera)
	main.status_changed.connect(launcher.set_status)


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
	logo.visible = true
	_caption.visible = true
	garden.visible = true
	if not garden.is_built:
		garden.build()
	launcher.open()
	reel.set_connected(main.has_backend())
	if main.show_tips():
		reel.open()
	entered.emit()


func leave() -> void:
	if not active:
		return
	active = false
	logo.visible = false
	_caption.visible = false
	garden.visible = false
	launcher.close()
	reel.close()
	var model := _model_root()
	if model != null and _model_hidden:
		model.visible = true
	_model_hidden = false
	exited.emit()


func set_show_tips(on: bool) -> void:
	## Settings > Show tips, applied now if the landing is up.
	if not active:
		return
	if on and not reel.is_open():
		reel.open()
	elif not on and reel.is_open():
		reel.close()


func place() -> void:
	## The logo 2.5 m ahead at eye height facing the user, the garden on the floor where the user stands facing the same way.
	var forward := _flat_forward()
	var eye := _camera.global_position
	var floor_y := _floor_y()
	logo.global_transform = Transform3D(Basis.looking_at(forward, Vector3.UP), Vector3(eye.x, eye.y, eye.z) + forward * LOGO_DISTANCE)
	_caption.global_transform = Transform3D(Basis.looking_at(forward, Vector3.UP), logo.global_position + Vector3(0.0, -0.38, 0.0))
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
	var loaded: bool = main.load_glb_file(str(model["path"]))
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
