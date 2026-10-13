extends "res://scripts/diegetic_panel.gd"
## A room's console (docs/assembly-rooms-scope.md, section 7): a small floating panel of the controls that belong to ONE room, in the room's colour. It has
## the usual window handle at its lower edge (grip it to carry the console somewhere comfortable) and a ghostly pedestal from its foot down to the floor,
## purely so it doesn't look like it is hanging in nothing. It is a child of its room, so carrying the room carries the console with it.
##   scale: 1:1 / Fit / half / double (undoable, about the room's middle)  ·  walls: fit to contents / back to the 3 m cube  ·  "used N times" (editing a Part
##   changes every placement of it)  ·  delete the selected part (two presses, naming the Mates that would go)  ·  close the room.
## The logic is room_actions.gd and room_manager.gd; this is only the buttons.

const RoomActions := preload("res://scripts/room/room_actions.gd")
const PedestalShader := preload("res://shaders/room_pedestal.gdshader")

var room: Node3D
var manager: Node
var _main: Node
var pedestal_enabled := true
var _scale_label: Label
var _uses_label: Label
var _note_label: Label
var _delete_button: Button
var _delete_armed := ""
var _delete_armed_until_ms := 0
var _delete_mates := 0
var _refresh_left := 0.0
var _pedestal: MeshInstance3D
var _pedestal_ring: MeshInstance3D
var _uses_asked_for := -1

const DELETE_CONFIRM_MS := 4000


func setup_console(p_room: Node3D, p_manager: Node, main: Node, left: XRController3D, right: XRController3D, camera: XRCamera3D) -> void:
	room = p_room
	manager = p_manager
	_main = main
	panel_title = room.label
	panel_size = Vector2(0.30, 0.40)
	viewport_size = Vector2i(480, 640)
	super.setup(left, right, camera)
	set_title(room.label)
	_build_pedestal()
	open()


func _place_in_front_of_camera() -> void:
	## The console stands beside the room on the user's side (its +z, the side the room faces away from), at chest height, facing the user.
	if room == null:
		return
	var back: Vector3 = room.global_transform.basis.z.normalized()
	var position_: Vector3 = room.global_position + back * (room.volume.half.z + 0.8)
	position_.y = 1.1
	global_transform = Transform3D(Basis.looking_at(-back, Vector3.UP), position_)


func _build_content() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_scale_label = Label.new()
	_scale_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_scale_label)
	box.add_child(_row([["1:1", _one_to_one], ["Fit", _fit_scale], ["Half", _half], ["Double", _double]]))
	box.add_child(_row([["Fit walls", _fit_walls], ["3 m cube", _reset_walls]]))
	_uses_label = Label.new()
	_uses_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_uses_label)
	_delete_button = Button.new()
	_delete_button.text = "Delete selected part"
	_delete_button.pressed.connect(_on_delete_pressed)
	box.add_child(_delete_button)
	_note_label = Label.new()
	_note_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_note_label)
	var close_button := Button.new()
	close_button.text = "Close room"
	close_button.pressed.connect(func() -> void: manager.close_room(room))
	box.add_child(close_button)
	return box


func _row(items: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	for item in items:
		var b := Button.new()
		b.text = item[0]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(item[1])
		row.add_child(b)
	return row


func button_named(text: String) -> Button:
	## A button of the console by its label (tests and anything that wants to press one).
	return _find_button(_ui_root if _ui_root != null else self, text)


func _find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node
	for child in node.get_children():
		var found := _find_button(child, text)
		if found != null:
			return found
	return null


func _stack():
	return _main.get("command_stack") if _main != null else null


func _show(result: Dictionary) -> void:
	_note_label.text = str(result.get("message", ""))
	_refresh_labels()


func _one_to_one() -> void:
	_show(RoomActions.one_to_one(room, _stack()))


func _fit_scale() -> void:
	_show(RoomActions.fit_scale(room, _stack()))


func _half() -> void:
	_show(RoomActions.scale_by(room, 0.5, _stack()))


func _double() -> void:
	_show(RoomActions.scale_by(room, 2.0, _stack()))


func _fit_walls() -> void:
	_show(RoomActions.fit_walls(room))


func _reset_walls() -> void:
	_show(RoomActions.reset_walls(room))


func _on_delete_pressed() -> void:
	var part: Node3D = _main.current_selected_part() if _main != null and _main.has_method("current_selected_part") else null
	if part == null:
		_note_label.text = "Select a part first (point at it and pull the trigger)."
		return
	var owner := str(part.get_meta("owner_part_id", ""))
	var occ := str(part.get_meta("occurrence_id", ""))
	if owner == "" or occ == "":
		_note_label.text = "That part can't be deleted (it is the assembly's own content)."
		return
	var now := Time.get_ticks_msec()
	if _delete_armed == occ and now < _delete_armed_until_ms:
		_delete_armed = ""
		_delete_button.text = "Delete selected part"
		await manager.delete_occurrence(owner, occ, str(part.name))
		return
	_delete_armed = occ
	_delete_armed_until_ms = now + DELETE_CONFIRM_MS
	_delete_mates = 0
	_delete_button.text = "Sure? Delete %s" % str(part.name)
	var e = manager.edit_api()
	if e != null:
		_delete_mates = await e.mates_naming(owner, occ)
		if _delete_armed == occ:
			_delete_button.text = "Sure? Delete %s%s" % [str(part.name), "" if _delete_mates == 0 else " (%d mate%s)" % [_delete_mates, "" if _delete_mates == 1 else "s"]]


func _refresh_labels() -> void:
	if _scale_label == null or room == null or not is_instance_valid(room):
		return
	_scale_label.text = "Scale %s  ·  %s" % [room.scale_text(), room.grid_text()]
	if _delete_armed != "" and Time.get_ticks_msec() >= _delete_armed_until_ms:
		_delete_armed = ""
		_delete_button.text = "Delete selected part"


func _refresh_uses() -> void:
	## How many times this Part is placed in the assembly: editing it in the room changes every one.
	if manager == null or _main == null:
		return
	var e = manager.edit_api()
	var root_id: String = _main.current_root_part_id() if _main.has_method("current_root_part_id") else ""
	if e == null or root_id == "":
		_uses_label.text = ""
		return
	var count: int = await e.instance_count(root_id, room.part_id)
	if not is_instance_valid(self):
		return
	_uses_label.text = "Not placed in the assembly" if count == 0 else ("Placed once" if count == 1 else "Placed %d times: editing it here changes all of them" % count)


func _on_opened() -> void:
	_refresh_labels()
	_refresh_uses()


func refresh_uses() -> void:
	_refresh_uses()


func set_pedestal(on: bool) -> void:
	pedestal_enabled = on
	if _pedestal != null:
		_pedestal.visible = on and visible
		_pedestal_ring.visible = on and visible


func _build_pedestal() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = PedestalShader
	mat.set_shader_parameter("tint", room.colour)
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.05
	cyl.bottom_radius = 0.07
	cyl.height = 1.0
	cyl.radial_segments = 24
	_pedestal = MeshInstance3D.new()
	_pedestal.mesh = cyl
	_pedestal.material_override = mat
	_pedestal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pedestal.top_level = true # placed in world space each frame, not turned with the console
	add_child(_pedestal)
	var torus := TorusMesh.new()
	torus.inner_radius = 0.16
	torus.outer_radius = 0.19
	torus.rings = 32
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.albedo_color = Color(room.colour.r, room.colour.g, room.colour.b, 0.28)
	torus.material = ring_mat
	_pedestal_ring = MeshInstance3D.new()
	_pedestal_ring.mesh = torus
	_pedestal_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pedestal_ring.top_level = true
	add_child(_pedestal_ring)
	set_pedestal(pedestal_enabled)


func _update_pedestal() -> void:
	## From the console's foot straight down to the floor (y = 0), wherever the console has been carried to.
	if _pedestal == null:
		return
	var foot := global_position - Vector3(0.0, panel_size.y * 0.5, 0.0)
	var height := maxf(foot.y, 0.02)
	_pedestal.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3(1.0, height, 1.0)), Vector3(foot.x, height * 0.5, foot.z))
	_pedestal_ring.global_transform = Transform3D(Basis.IDENTITY, Vector3(foot.x, 0.01, foot.z))


func _process(delta: float) -> void:
	super._process(delta)
	_update_pedestal()
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		_refresh_left = 0.25
		_refresh_labels()
