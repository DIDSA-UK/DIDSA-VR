extends RefCounted
## The "grab me to move this" handle shared by every free-floating panel: floating
## windows (diegetic_panel.gd) and the popup keyboard. A small pill at the centre of
## the panel's lower edge; GRIP it with either hand to carry the whole panel along
## 1:1, release to drop it. Extracted from diegetic_panel.gd so the keyboard gets
## exactly the same behaviour instead of a second copy.
##
## Self-contained: it listens to both controllers' grip itself (not routed through
## controller.gd's part-grab search). The host does two things: calls follow() each
## frame (it returns true while being carried), and exposes in_reach() to
## controller.gd via a `handle_in_reach(hand)` method and the "diegetic_panels" group,
## so a grip aimed at a panel's handle never also grabs a part or the section gizmo.
##
## Grabbing sets a "window_held" meta on the hand (the same convention as
## section_tool.gd's "section_gizmo_held") so two_hand_model.gd's _hand_free() doesn't
## also drag the whole model with the same grip press — real-headset feedback:
## grabbing a window moved the world too. clear() undoes it, and the host must call
## clear() when it closes mid-grab or the hand's meta stays true and blocks model drags.
##
## DISTANCE GRAB (controller.gd drives it): a panel can end up somewhere awkward, so a hand whose
## LASER is on a panel can grab it from afar. The panel glows (halo) while a laser is on it and glows
## brighter while carried; grip starts a carry (start_laser_grab); the panel then follows the hand's
## position (it swings with the laser, smoothed) but always turns to face you, upright (a leaning
## keyboard keeps its lean); A/X pulls it towards you and B/Y pushes it away (nudge()).

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const HALO_SHADER := preload("res://shaders/ui_halo.gdshader")

signal grabbed(hand: XRController3D)
signal dropped(hand: XRController3D)

var node: MeshInstance3D ## the pill; null until build()
var held_by: XRController3D = null
var grab_action := "grip_click"
var reach_slack := 0.03 ## metres beyond the pill's own radius: it's small, so a bit of slack makes it easier to catch
var idle_colour := Color(0.60, 0.70, 0.80)
var held_colour := Color(0.31, 0.77, 1.0)
var drop_distance := 0.02 ## metres below the panel's lower edge
var camera: Node3D ## the host's camera: a distance-carried panel turns to face it
var laser_reach := 6.0 ## metres: how far away a laser can still pick this panel
var halo_margin := 0.05 ## metres: the glow's width, and how far past the panel's edge a laser still counts as on it
var min_pull_distance := 0.25 ## A/X won't pull a carried panel closer to the hand than this
var max_distance := 12.0
var distance_mode := false ## the current carry is a distance grab (faces you, smoothed) rather than a rigid near grab
var glow_level := 0.0 ## 0 none, 0.5 a laser is on it, 1 being carried

var _host: Node3D
var _is_open: Callable
var _material: StandardMaterial3D
var _grab_offset := Transform3D.IDENTITY
var _halo: MeshInstance3D
var _halo_material: ShaderMaterial
var _hover_hands := {}
var _dist_offset := Vector3.ZERO ## distance carry: the panel's position in the holding hand's local frame
var _tilt := Basis.IDENTITY ## distance carry: the panel's own pitch (a leaning keyboard), kept while it faces you
var _panel_size := Vector2(0.3, 0.2)


func setup(host: Node3D, left: XRController3D, right: XRController3D, is_open: Callable, tokens: Resource = null) -> void:
	_host = host
	_is_open = is_open
	if tokens != null:
		idle_colour = tokens.text_dim
		held_colour = tokens.accent
	left.button_pressed.connect(_on_pressed.bind(left))
	left.button_released.connect(_on_released.bind(left))
	right.button_pressed.connect(_on_pressed.bind(right))
	right.button_released.connect(_on_released.bind(right))


func build(panel_size: Vector2) -> MeshInstance3D:
	node = MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.008
	capsule.height = 0.05
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.emission_enabled = true
	_material.emission = idle_colour
	_material.albedo_color = idle_colour
	capsule.material = _material
	node.mesh = capsule
	node.rotation_degrees.z = 90.0 # a capsule's long axis is local Y; lay it along the panel's lower edge
	_host.add_child(node)
	_build_halo()
	layout(panel_size)
	return node


func set_colours(idle: Color, held: Color) -> void:
	idle_colour = idle
	held_colour = held
	if _material:
		var c := held_colour if held_by != null else idle_colour
		_material.albedo_color = c
		_material.emission = c
	if _halo_material:
		_halo_material.set_shader_parameter("glow_color", held_colour)


func layout(panel_size: Vector2) -> void:
	_panel_size = panel_size
	if node:
		node.position = Vector3(0.0, -panel_size.y * 0.5 - drop_distance, 0.01)
	if _halo:
		var outer := panel_size + Vector2.ONE * halo_margin * 2.0
		(_halo.mesh as QuadMesh).size = outer
		_halo_material.set_shader_parameter("inner", panel_size / outer)


func _build_halo() -> void:
	_halo = MeshInstance3D.new()
	_halo.mesh = QuadMesh.new()
	_halo_material = ShaderMaterial.new()
	_halo_material.shader = HALO_SHADER
	_halo_material.set_shader_parameter("glow_color", held_colour)
	_halo.material_override = _halo_material
	_halo.position = Vector3(0.0, 0.0, -0.003) # just behind the panel: its own quad hides the middle
	_halo.visible = false
	_host.add_child(_halo)


# --- Distance grab -----------------------------------------------------------------

func laser_hit_distance(origin: Vector3, dir: Vector3) -> float:
	## Metres along the ray to this panel (its plane, within the panel's rectangle plus the halo
	## margin all round), or -1 if the ray misses, it's too far, or the panel isn't open.
	if node == null or not _is_open.call() or not _host.visible:
		return -1.0
	var hit = Plane(_host.global_transform.basis.z.normalized(), _host.global_position).intersects_ray(origin, dir)
	if hit == null:
		return -1.0
	var d := origin.distance_to(hit)
	if d > laser_reach:
		return -1.0
	var local: Vector3 = _host.global_transform.affine_inverse() * hit
	var pad := halo_margin + 0.02
	if absf(local.x) > _panel_size.x * 0.5 + pad or absf(local.y) > _panel_size.y * 0.5 + pad:
		return -1.0
	return d


func set_hover(hand: Object, on: bool) -> void:
	## A laser is (or stopped being) on this panel: it glows while any hand points at it.
	var had := not _hover_hands.is_empty()
	if on:
		_hover_hands[hand] = true
	else:
		_hover_hands.erase(hand)
	if had != not _hover_hands.is_empty():
		_refresh_glow()


func is_hovered() -> bool:
	return not _hover_hands.is_empty()


func _refresh_glow() -> void:
	glow_level = 1.0 if held_by != null else (0.5 if not _hover_hands.is_empty() else 0.0)
	if _halo:
		_halo.visible = glow_level > 0.0
		_halo_material.set_shader_parameter("intensity", glow_level)


func start_laser_grab(hand: XRController3D) -> bool:
	## Carry this panel from where the laser is on it. False if it can't be (closed, already held).
	if held_by != null or not _is_open.call() or not _host.visible:
		return false
	held_by = hand
	distance_mode = true
	hand.set_meta("window_held", true)
	_dist_offset = hand.global_transform.affine_inverse() * _host.global_position
	_tilt = Basis(Vector3.RIGHT, _host.global_transform.basis.get_euler(EULER_ORDER_YXZ).x) # its own lean (the full keyboard's), nothing else
	_material.albedo_color = held_colour
	_material.emission = held_colour
	_refresh_glow()
	UiFeedback.haptic(hand, "grab")
	UiFeedback.play("grab", _host)
	grabbed.emit(hand)
	return true


func nudge(amount: float) -> void:
	## A/X (amount < 0) pulls the carried panel towards the hand, B/Y (> 0) pushes it away, along the
	## line from the hand to the panel. A panel already nearer than the minimum can't be pulled closer.
	if held_by == null:
		return
	var current: Vector3 = _dist_offset if distance_mode else _grab_offset.origin
	var length := current.length()
	if length < 0.0001:
		return
	var wanted := clampf(length + amount, minf(min_pull_distance, length), max_distance)
	var scaled := current * (wanted / length)
	if distance_mode:
		_dist_offset = scaled
	else:
		_grab_offset.origin = scaled


func carry_distance() -> float:
	## Metres from the holding hand to the carried panel (0 when nothing is held).
	if held_by == null:
		return 0.0
	return (_dist_offset if distance_mode else _grab_offset.origin).length()


func in_reach(hand: Node3D) -> bool:
	if node == null or not _is_open.call() or not _host.visible:
		return false
	var reach: float = (node.mesh as CapsuleMesh).radius + reach_slack
	return hand.global_position.distance_to(node.global_position) <= reach


func follow(delta: float = 0.0) -> bool:
	## Call every frame. While carried by a NEAR grab: the host's pose is the holding hand's, 1:1
	## (a floating panel isn't a precision placement task, so no steadiness filter). While carried by a
	## DISTANCE grab: it follows the hand's position, smoothed, and turns to face you.
	if held_by == null:
		return false
	if not distance_mode:
		_host.global_transform = held_by.global_transform * _grab_offset
		return true
	var target := held_by.global_transform * _dist_offset
	var t := _host.global_transform
	var blend_p := 1.0 if delta <= 0.0 else 1.0 - exp(-24.0 * delta)
	var blend_r := 1.0 if delta <= 0.0 else 1.0 - exp(-14.0 * delta)
	var pos := t.origin.lerp(target, blend_p)
	var wanted_basis := _facing_basis(pos) * _tilt
	_host.global_transform = Transform3D(t.basis.orthonormalized().slerp(wanted_basis, blend_r), pos)
	return true


func _facing_basis(pos: Vector3) -> Basis:
	## Upright, with the panel's front (+Z) towards the camera.
	var away := pos - (camera.global_position if camera != null else pos + Vector3.BACK)
	away.y = 0.0
	if away.length() < 0.001:
		away = -_host.global_transform.basis.z
		away.y = 0.0
		if away.length() < 0.001:
			away = Vector3.FORWARD
	return Basis.looking_at(away.normalized(), Vector3.UP)


func clear() -> void:
	## Release + drop the hand meta; safe to call when nothing is held.
	var hand := held_by
	if hand != null and is_instance_valid(hand):
		hand.set_meta("window_held", false)
	held_by = null
	distance_mode = false
	if _material:
		_material.albedo_color = idle_colour
		_material.emission = idle_colour
	_refresh_glow()
	if hand != null and is_instance_valid(hand):
		dropped.emit(hand)


func _on_pressed(action_name: String, hand: XRController3D) -> void:
	if action_name != grab_action or not _is_open.call() or held_by != null:
		return
	if in_reach(hand):
		held_by = hand
		hand.set_meta("window_held", true)
		_grab_offset = hand.global_transform.affine_inverse() * _host.global_transform
		_material.albedo_color = held_colour
		_material.emission = held_colour
		_refresh_glow()
		UiFeedback.haptic(hand, "grab")
		UiFeedback.play("grab", _host)
		grabbed.emit(hand)


func _on_released(action_name: String, hand: XRController3D) -> void:
	if action_name == grab_action and held_by == hand:
		clear()
