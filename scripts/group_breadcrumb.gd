extends Node3D
## The laser's assembly-level breadcrumb: hold the trigger on a part that sits in sub-assemblies and a small panel opens at the hit point, the part first then
## each sub-assembly it belongs to, innermost to outermost. Swing the laser over the level you want (its row lights up) and let go to take it; letting go off the
## panel keeps the part. It faces the user and is flat, so the hit test is a ray against its plane.
##
## It is drawn like the rest of the UI: a real Control tree in the app's theme (the same panel chrome, an accent outline, rows that light up like a selected
## button) in a SubViewport shown on a quad, so a theme change or a new theme reaches it like it reaches the tablet.
##
## The Appearance tool's paint breadcrumb uses the same panel with a title row ("Painting"; not a choice) and, per row, a swatch of what is there now and a
## note ("set here"): open()'s `extra` {title, swatches: [Color or null], notes: [String]}.

const UiThemes := preload("res://scripts/ui/ui_themes.gd")

const PX_PER_M := 1500.0 ## the panel's texture density
const ROW_PX := 68.0
const ROW_H := ROW_PX / PX_PER_M ## metres per row
const WIDTH_PX := 510.0
const WIDTH := WIDTH_PX / PX_PER_M
const MARGIN_PX := 5.0 ## inside the outline, round the rows
const MARGIN_M := MARGIN_PX / PX_PER_M

var labels: Array[String] = []
var hovered := 0
var title := "" ## a heading above the rows ("" = none): not a row, never hovered
var swatches: Array = [] ## per row: a Color shown as a small square before the label, or null
var notes: Array = [] ## per row: a short dim note after the label ("set here"), or ""

var _viewport: SubViewport
var _quad: MeshInstance3D
var _rows: Array[PanelContainer] = []
var _row_labels: Array[Label] = []
var _painted := -2
var _tokens: Resource
var _theme_revision := -1


static func row_at(local: Vector2, count: int, header_rows: int = 0) -> int:
	## Which row a point on the panel (x across, y down from the top edge, metres, panel-local with x from the left edge) is over; -1 outside.
	## `header_rows`: a title row above the rows (it is never a row).
	var y := local.y - MARGIN_M - ROW_H * header_rows
	if local.x < 0.0 or local.x > WIDTH or y < 0.0 or y >= ROW_H * count:
		return -1
	return clampi(int(y / ROW_H), 0, count - 1)


static func height_for(count: int) -> float:
	return ROW_H * count + MARGIN_M * 2.0


func _header_rows() -> int:
	return 1 if title != "" else 0


func open(texts: Array, at: Vector3, towards: Vector3, selected: int, extra: Dictionary = {}) -> void:
	labels.clear()
	for t in texts:
		labels.append(str(t))
	hovered = selected
	title = str(extra.get("title", ""))
	swatches = (extra.get("swatches", []) as Array).duplicate()
	notes = (extra.get("notes", []) as Array).duplicate()
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_rows.clear()
	_row_labels.clear()
	_painted = -2
	global_position = at
	_face(towards)
	_build()
	_paint()


func _build() -> void:
	_tokens = UiThemes.live()
	_theme_revision = UiThemes.revision
	var height_px := ROW_PX * (labels.size() + _header_rows()) + MARGIN_PX * 2.0
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(int(WIDTH_PX), int(height_px))
	_viewport.transparent_bg = true
	_viewport.disable_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_viewport)
	var chrome := PanelContainer.new()
	chrome.theme = _tokens.build_theme()
	chrome.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var frame: StyleBoxFlat = _tokens.box(Color(_tokens.bg_panel.r, _tokens.bg_panel.g, _tokens.bg_panel.b, 0.96), _tokens.accent, 16, int(MARGIN_PX), 3)
	chrome.add_theme_stylebox_override("panel", frame)
	_viewport.add_child(chrome)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 0)
	chrome.add_child(list)
	if title != "":
		var heading := Label.new()
		heading.text = title
		heading.custom_minimum_size = Vector2(0, ROW_PX)
		heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		heading.add_theme_color_override("font_color", _tokens.accent)
		heading.clip_text = true
		list.add_child(heading)
	for i in labels.size():
		var row := PanelContainer.new()
		row.custom_minimum_size = Vector2(0, ROW_PX)
		list.add_child(row)
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 12)
		row.add_child(line)
		if i < swatches.size() and swatches[i] is Color:
			var chip := ColorRect.new()
			chip.color = swatches[i]
			chip.custom_minimum_size = Vector2(30, 30)
			chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			line.add_child(chip)
		var label := Label.new()
		label.text = labels[i]
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.clip_text = true
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(label)
		if i < notes.size() and str(notes[i]) != "":
			var note := Label.new()
			note.text = str(notes[i])
			note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			note.add_theme_color_override("font_color", _tokens.text_dim)
			line.add_child(note)
		_rows.append(row)
		_row_labels.append(label)
	_quad = MeshInstance3D.new()
	var q := QuadMesh.new()
	var h := height_for(labels.size() + _header_rows())
	q.size = Vector2(WIDTH, h)
	_quad.mesh = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = _viewport.get_texture()
	m.no_depth_test = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.render_priority = 9
	_quad.material_override = m
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.position = Vector3(WIDTH * 0.5, -h * 0.5, 0.0)
	add_child(_quad)


func _face(towards: Vector3) -> void:
	## Turn the panel's +Z to look at `towards` (the user's head), staying upright, with its top-left corner at the hit point.
	var to := towards - global_position
	to.y = 0.0
	if to.length() < 0.001:
		return
	look_at(global_position - to.normalized(), Vector3.UP) # -Z points away from the user, so +Z (the face) looks at them


func point_to_local(ray_origin: Vector3, ray_dir: Vector3) -> Variant:
	## Where the laser meets the panel's plane, in panel coordinates (x from the left edge, y down from the top), or null if it points away.
	var plane := Plane(global_transform.basis.z.normalized(), global_position)
	var hit: Variant = plane.intersects_ray(ray_origin, ray_dir.normalized())
	if hit == null:
		return null
	var local: Vector3 = global_transform.affine_inverse() * (hit as Vector3)
	return Vector2(local.x, -local.y)


func update_aim(ray_origin: Vector3, ray_dir: Vector3) -> int:
	## Lights the row under the laser (or none) and returns its index (-1 for none).
	var local: Variant = point_to_local(ray_origin, ray_dir)
	hovered = row_at(local, labels.size(), _header_rows()) if local != null else -1
	_paint()
	return hovered


func _paint() -> void:
	if _rows.is_empty():
		return
	if _theme_revision != UiThemes.revision:
		var keep := labels.duplicate()
		var at := global_position
		open(keep, at, at + global_transform.basis.z, hovered, {"title": title, "swatches": swatches, "notes": notes}) # (the theme changed under an open panel: rebuilt in the new one)
		return
	if hovered == _painted:
		return
	_painted = hovered
	for i in _rows.size():
		var on := i == hovered
		var style: StyleBoxFlat
		if on:
			style = _tokens.selected_box()
		else:
			style = _tokens.box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), _tokens.radius_small, int(_tokens.pad_control))
		style.content_margin_top = 0
		style.content_margin_bottom = 0
		style.content_margin_left = 16
		_rows[i].add_theme_stylebox_override("panel", style)
		_row_labels[i].add_theme_color_override("font_color", _tokens.text if on else _tokens.text_dim)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
