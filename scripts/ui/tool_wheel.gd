extends Node3D
## The tool wheel: a quick radial menu for the tools you reach for most, like the spell / weapon wheel in an FPS
## VR game. Squeeze the right trigger and grip together; a ring of wedges opens at your hand. Move the hand
## towards a wedge (the ring is steered by hand MOVEMENT, not by aiming) and let go to choose it. Let go at the
## centre to cancel. A wedge marked as a sub-wheel opens its own ring once the hand travels well out towards it;
## release over one of its wedges to choose that.
##
## controller.gd detects the chord (trigger + grip within a quarter of a second of each other, so a single
## press still grabs or selects exactly as before) and emits wheel_chord_started. From then until BOTH buttons
## are up again the hand carries the meta "wheel_open": the grip, trigger, stick and laser are the wheel's
## (controller.gd, two_hand_model.gd and locomotion.gd's is_manipulating() check it).
##
## What is on the ring comes from `entries_provider` (wheel_flows.gd), asked each time the wheel opens, so the
## ring can follow what you are doing (while Mates is on it offers Create / Flip / Clear). An entry is a
## dictionary:
##   id, label, icon (ui_icons.gd name), accent (Color), hint (one line shown in the centre),
##   enabled (bool, default true), run (Callable, for a normal wedge), children (Callable -> Array, for a
##   sub-wheel), active (bool: drawn as "on").
## The geometry (which wedge, outlines) is tool_wheel_math.gd, pure and tested headless.

const Math := preload("res://scripts/ui/tool_wheel_math.gd")
const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")

signal opened()
signal closed()
signal chosen(entry_id: String)
signal summary_changed(summary: Dictionary) ## what the wrist hint panel should say: {title, body, tone, accent}
signal shown_changed(shown: bool) ## the ring went up / down (it goes down on the first release, before the chord ends)

const ICON_PX := 96
const ICON_PIXEL_SIZE := 0.00047 ## metres per icon pixel: a 4.5 cm icon
const ICON_SIZE := ICON_PX * ICON_PIXEL_SIZE
const ICON_LABEL_GAP := 0.008 ## metres between a tile's icon and its name
const MIN_LABEL_FONT := 22
const MIN_RING_FONT := 26 ## the smallest the ring-wide name size goes; a name that would not fit even then runs a little past its tile
const PILL_TRACKING := 0.003 ## metres of extra space between the glyphs of the pill's curved name
const NAME_PADDING := 0.014 ## metres of clear space kept between a name and its tile's edges (both sides together)
const LABEL_LINE_HEIGHT := 1.28 ## a line of label text is this many font sizes tall
const HOVER_LIFT := 0.012 ## metres: the hovered wedge lifts towards you
const PX := 1.0 / 2667.0 ## metres per tablet pixel (wrist_tablet.gd's pixels_per_metre): the theme's shape tokens are in these pixels
const CORNER_SCALE := 1.5 ## the ring is seen from further off than the tablet, so its corners and borders are drawn a little heavier
const BORDER_PER_PX := 0.00175 ## metres of border per theme border_width pixel
const GLOW := 0.014 ## metres: how far the hovered wedge's glow reaches
const LABEL_PIXEL_SIZE := 0.0006
const SIZE_NAMES: Array[String] = ["Small", "Normal", "Large"]
const SIZE_SCALES: Array[float] = [0.8, 1.0, 1.3]
const TRIGGER_ACTION := "trigger_click"
const GRIP_ACTION := "grip_click"

var tokens: Resource
var entries_provider: Callable = Callable() ## () -> Array of entry dictionaries
var dead_zone := Math.DEAD_ZONE
var wheel_scale := 1.0

var _hand: XRController3D
var _camera: Camera3D
var _held := false ## the chord is held (the hand's "wheel_open" meta)
var _shown := false ## the ring is up (it goes away as soon as one button is released)
var _entries: Array = []
var _stack: Array = [] ## the rings above the current one (for a sub-wheel): [{entries, title}]
var _title := ""
var _hover := -1
var _anchor := Vector3.ZERO
var _right := Vector3.RIGHT
var title_provider: Callable = Callable() ## () -> String: the ring's name above it when nothing is hovered ("Mates" while the Mates tool is on)
var _wedges: Array[MeshInstance3D] = [] ## each wedge's fill; its border and glow are siblings (_borders, _glows)
var _borders: Array[MeshInstance3D] = []
var _glows: Array[MeshInstance3D] = []
var _labels: Array[Label3D] = []
var _icons: Array[Sprite3D] = []
var _hole: MeshInstance3D
var _outlines: Array = [] ## each wedge's polygon, kept to lay its name out inside it
var _hole_border: MeshInstance3D
var _seen_revision := -1 ## ui_themes.gd's revision when the ring was last built: a theme change while it is up rebuilds it
var _corner := 0.009
var _border := 0.0035
var _glow_alpha := 0.3
var pill_provider: Callable = Callable() ## () -> Dictionary: the entry for the pill under a top-level ring ({} = no pill)
var ring_lift := 0.45 ## metres the ring is drawn above the hand (the hand's own steering is unchanged): the wrist panel hangs below the hand, so with the ring this far up it never covers the tile being pointed at
var _pill: Dictionary = {}
var _pill_hover := false
var _pill_nodes: Dictionary = {}
var _summary: Dictionary = {}
var _ring_font := 28 ## the ring-wide name size (_layout_tiles): the pill's curved name uses it too
var _cursor: MeshInstance3D
var _ring: Node3D


func setup(hand: XRController3D, camera: Camera3D, p_tokens: Resource, provider: Callable) -> void:
	_hand = hand
	_camera = camera
	tokens = p_tokens
	entries_provider = provider
	_ring = Node3D.new()
	_ring.name = "Ring"
	add_child(_ring)
	_hole_border = MeshInstance3D.new()
	_ring.add_child(_hole_border)
	_hole = MeshInstance3D.new()
	_ring.add_child(_hole)
	_cursor = MeshInstance3D.new()
	var dot := SphereMesh.new()
	dot.radius = 0.007
	dot.height = 0.014
	_cursor.mesh = dot
	_cursor.material_override = _material(tokens.text, 1.0)
	_ring.add_child(_cursor)
	visible = false
	hand.wheel_enabled = true
	hand.wheel_chord_started.connect(_on_chord)
	hand.button_released.connect(_on_released)
	set_process(false)


func set_size(index: int) -> void:
	wheel_scale = SIZE_SCALES[clampi(index, 0, SIZE_SCALES.size() - 1)]


func is_open() -> bool:
	## The chord is held (whether or not the ring is still up).
	return _held


func is_shown() -> bool:
	return _shown


func hovered_index() -> int:
	return _hover


func current_entries() -> Array:
	return _entries


func summary() -> Dictionary:
	## What the wrist hint panel is being told right now.
	return _summary


func pill_entry() -> Dictionary:
	return _pill


func pill_hovered() -> bool:
	return _pill_hover


func set_enabled(on: bool) -> void:
	if _hand:
		_hand.wheel_enabled = on
	if not on and _held:
		_end()


# --- Opening / closing -------------------------------------------------------------------------

func _on_chord() -> void:
	if _held:
		return
	_hand.cancel_for_wheel() # the first press of the chord already began a grab / selected something: let go of it
	_held = true
	_hand.set_meta("wheel_open", true)
	_stack.clear()
	var entries: Array = entries_provider.call() if entries_provider.is_valid() else []
	_title = ""
	_show_ring(entries, _hand.global_position)
	UiFeedback.play("open", self)
	UiFeedback.haptic(_hand, "open")
	opened.emit()


func _show_ring(entries: Array, at: Vector3) -> void:
	_entries = entries
	_hover = -1
	_pill_hover = false
	_pill = pill_provider.call() if pill_provider.is_valid() and _stack.is_empty() else {} # only a top-level ring has the pill
	_anchor = at
	_orient_to_user()
	global_transform = Transform3D(_basis_for(), _anchor + Vector3.UP * ring_lift)
	scale = Vector3.ONE * wheel_scale
	_rebuild()
	_set_shown(not _entries.is_empty())
	visible = _shown
	set_process(_shown)
	_update_centre()


func _set_shown(on: bool) -> void:
	if on == _shown:
		return
	_shown = on
	shown_changed.emit(on)


func _orient_to_user() -> void:
	## A vertical ring facing the user's head, steered by the head's yaw only (looking down at your hand doesn't tip it).
	var forward := -_camera.global_transform.basis.z if _camera != null and _camera.is_inside_tree() else Vector3.FORWARD
	forward.y = 0.0
	if forward.length() < 0.001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	_right = forward.cross(Vector3.UP).normalized()


func _basis_for() -> Basis:
	return Basis(_right, Vector3.UP, _right.cross(Vector3.UP).normalized())


func _on_released(action_name: String) -> void:
	if not _held or (action_name != TRIGGER_ACTION and action_name != GRIP_ACTION):
		return
	if _shown:
		_commit()
	if not _hand.is_button_pressed(TRIGGER_ACTION) and not _hand.is_button_pressed(GRIP_ACTION):
		_end()


func _end() -> void:
	_held = false
	_set_shown(false)
	_hover = -1
	_pill_hover = false
	_stack.clear()
	visible = false
	set_process(false)
	if _hand:
		_hand.set_meta("wheel_open", false)
	closed.emit()


func _commit() -> void:
	## Release: do what the hovered wedge says. Release at the centre, over a greyed wedge or over a sub-wheel's
	## label (the ring wasn't opened) does nothing.
	var picked := _hover
	var on_pill := _pill_hover and not _pill.is_empty()
	_set_shown(false)
	visible = false
	set_process(false)
	if not on_pill and (picked < 0 or picked >= _entries.size()):
		UiFeedback.play("close", self)
		return
	var entry: Dictionary = _pill if on_pill else _entries[picked]
	if not bool(entry.get("enabled", true)) or entry.has("children") or not entry.has("run"):
		UiFeedback.haptic(_hand, "error")
		UiFeedback.play("error", self)
		return
	UiFeedback.play("confirm", self)
	UiFeedback.haptic(_hand, "confirm")
	chosen.emit(str(entry.get("id", "")))
	(entry["run"] as Callable).call()


# --- Per frame: steer by hand movement ---------------------------------------------------------

func _process(_delta: float) -> void:
	if not _shown:
		return
	if _seen_revision != UiThemes.revision:
		_rebuild() # the theme (or the effects switch) changed while the ring is up: re-skin it in place
		_update_centre()
	var offset := Math.project_offset(_hand.global_position, _anchor, _right) / maxf(wheel_scale, 0.01)
	var on_pill := not _pill.is_empty() and Math.in_pill(offset)
	_update_hover(-1 if on_pill else Math.wedge_for(offset, _entries.size(), dead_zone), on_pill)
	var shown_len := minf(offset.length(), Math.OUTER_RADIUS * 1.15)
	_cursor.position = Vector3(offset.normalized().x * shown_len, offset.normalized().y * shown_len, 0.006) if offset.length() > 0.0001 else Vector3(0, 0, 0.006)
	if not on_pill and _hover >= 0 and _entries[_hover].has("children") and bool(_entries[_hover].get("enabled", true)) and Math.is_drilling(offset):
		_drill(_hover)


func _update_hover(index: int, on_pill: bool) -> void:
	# (a greyed wedge is still pointed at, to read why it is greyed; it just can't be chosen)
	if index == _hover and on_pill == _pill_hover:
		return
	_hover = index
	_pill_hover = on_pill
	if _hover >= 0 or _pill_hover:
		UiFeedback.haptic(_hand, "hover")
	_paint()
	_update_centre()


func _drill(index: int) -> void:
	## The hand travelled out towards a sub-wheel's wedge: open its ring, centred where the hand is now.
	var children: Array = (_entries[index]["children"] as Callable).call()
	if children.is_empty():
		return
	_stack.append({"entries": _entries, "title": _title})
	_title = str(_entries[index].get("label", ""))
	UiFeedback.play("open", self)
	UiFeedback.haptic(_hand, "press")
	_show_ring(children, _hand.global_position)


# --- Drawing -----------------------------------------------------------------------------------
# Styled like the wrist tablet's tiles (didsa_ui_theme.gd tokens): a rounded raised tile with a thin accent border, an accent
# outline icon and the name always underneath in the theme font. The hovered tile gets a brighter border, a glow and an accent
# tint; the tool that is on is filled with accent_deep; a greyed one drops to the border / disabled colours.

func _clear_nodes() -> void:
	for group in [_wedges, _borders, _glows, _labels, _icons]:
		for n in group:
			n.queue_free()
		group.clear()
	for n in _pill_nodes.values():
		n.queue_free()
	_pill_nodes.clear()


func _read_theme() -> void:
	## Shape and effects come from the live theme like the tablet's do: Navy is rounded with a heavier outline and a
	## strong glow, Simple is squarer with a thin outline, Dark sits between; Settings > Appearance > Shader effects turns the glow off.
	_seen_revision = UiThemes.revision
	_corner = clampf(float(tokens.radius_control) * PX * CORNER_SCALE, 0.002, 0.02)
	_border = maxf(float(tokens.border_width) * BORDER_PER_PX, 0.0008)
	_glow_alpha = float(tokens.fx_button_glow) if UiThemes.fx_enabled else 0.0


func style_summary() -> Dictionary:
	## What the live theme currently makes of the ring (tests compare it across themes).
	return {"corner": _corner, "border": _border, "glow": _glow_alpha, "revision": _seen_revision}


func _rebuild() -> void:
	_clear_nodes()
	_outlines.clear()
	_read_theme()
	var count := _entries.size()
	for i in count:
		var outline := Math.wedge_outline(i, count, Math.INNER_RADIUS, Math.OUTER_RADIUS, Math.GAP, 14, _corner)
		var glow := _node_for(Math.grown(outline, GLOW), 8)
		var border := _node_for(Math.grown(outline, _border), 9)
		var fill := _node_for(outline, 10)
		_glows.append(glow)
		_borders.append(border)
		_wedges.append(fill)
		var icon := Sprite3D.new()
		icon.texture = UiIcons.texture(str(_entries[i].get("icon", "")), ICON_PX)
		icon.pixel_size = ICON_PIXEL_SIZE
		icon.shaded = false
		icon.double_sided = true
		icon.no_depth_test = true
		icon.render_priority = 12
		icon.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		_ring.add_child(icon)
		_icons.append(icon)
		var label := _make_label(int(float(tokens.font_small) * 1.9), LABEL_PIXEL_SIZE, false)
		label.outline_size = 4
		label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		_ring.add_child(label)
		_labels.append(label)
		_outlines.append(outline)
	_layout_tiles()
	_build_pill()
	# the centre: where the hand rests, and "release here to cancel"
	var hole_outline := Math.circle(Math.INNER_RADIUS - Math.GAP)
	_hole.mesh = _poly_mesh(hole_outline)
	var hole_mat := _material(tokens.bg_panel, 0.85)
	hole_mat.render_priority = 9
	_hole.material_override = hole_mat
	_hole_border.mesh = _poly_mesh(Math.grown(hole_outline, _border))
	var hole_border_mat := _material(tokens.border, 0.9)
	hole_border_mat.render_priority = 8
	_hole_border.material_override = hole_border_mat
	_cursor.position = Vector3(0, 0, 0.006)
	_paint()


func _build_pill() -> void:
	## The pill under a top-level ring: an action that is not a wedge (e.g. "Clear", which puts the tool away). Styled like a
	## tile (same fill, corner, border, hover), with its name set along the arc, one glyph at a time, because a label cannot bend.
	if _pill.is_empty():
		return
	var outline := Math.pill_outline(24, _corner)
	_pill_nodes["glow"] = _node_for(Math.grown(outline, GLOW), 8)
	_pill_nodes["border"] = _node_for(Math.grown(outline, _border), 9)
	_pill_nodes["fill"] = _node_for(outline, 10)
	var text := Node3D.new()
	_ring.add_child(text)
	_pill_nodes["text"] = text
	var size := _ring_font
	var probe := _make_label(size, LABEL_PIXEL_SIZE, false)
	var font: Font = probe.font if probe.font != null else ThemeDB.fallback_font
	probe.free()
	var label := str(_pill.get("label", ""))
	var radius := Math.OUTER_RADIUS + Math.PILL_GAP + Math.PILL_DEPTH * 0.5 # the middle of the band
	var widths: Array[float] = []
	var total := 0.0
	for ch in label:
		var w := font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x * LABEL_PIXEL_SIZE + PILL_TRACKING
		widths.append(w)
		total += w
	# Read left to right along the bottom: the angle (clockwise from straight up) decreases from PI + half the text to PI - half.
	var angle := PI + (total / radius) * 0.5
	for i in label.length():
		var step := widths[i] / radius
		var a := angle - step * 0.5
		var glyph := _make_label(size, LABEL_PIXEL_SIZE, false)
		glyph.outline_size = 4
		glyph.text = label[i]
		text.add_child(glyph)
		glyph.position = Vector3(sin(a) * radius, cos(a) * radius, 0.004)
		glyph.rotation.z = atan2(sin(a), -cos(a)) # baseline along the arc, tops towards the ring's centre
		angle -= step


func _layout_tiles() -> void:
	## Puts each tile's icon and name where they sit best. Each name is sized for the room its tile really has at that height
	## (_fit_label), centred in that slice of the tile rather than on the wedge's axis (a diagonal tile is lopsided at the
	## text's height), and one size is used for the whole ring so the names read as a set.
	var count := _entries.size()
	var texts: Array = []
	var best := int(float(tokens.font_small) * 1.9)
	for i in count:
		var text := str(_entries[i].get("label", ""))
		texts.append(text)
		var centre_y := Math.centre_direction(i, count).y * Math.CONTENT_RADIUS
		var label := _labels[i]
		label.font_size = int(float(tokens.font_small) * 1.9)
		var lines := 1
		for pass_number in 2:
			var span := _span(_outlines[i], centre_y, lines, label.font_size)
			lines = _fit_label(label, text, maxf(span.y, 0.03))
		best = mini(best, label.font_size)
	best = maxi(best, MIN_RING_FONT)
	_ring_font = best
	for i in count:
		var label := _labels[i]
		label.font_size = best
		var centre := Math.centre_direction(i, count) * Math.CONTENT_RADIUS
		var lines := 1
		var span := Vector2.ZERO
		for pass_number in 2:
			span = _span(_outlines[i], centre.y, lines, best)
			lines = _fit_label(label, texts[i], maxf(span.y, 0.03))
		var text_h := float(lines) * float(label.font_size) * LABEL_PIXEL_SIZE * LABEL_LINE_HEIGHT
		var block := ICON_SIZE + ICON_LABEL_GAP + text_h
		var top := centre.y + block * 0.5
		var x := span.x
		_icons[i].position = Vector3(x, top - ICON_SIZE * 0.5, 0.003)
		label.position = Vector3(x, top - ICON_SIZE - ICON_LABEL_GAP, 0.004)


func _span(outline: PackedVector2Array, centre_y: float, lines: int, font_size: int) -> Vector2:
	## (x of the middle of the tile's slice at the name's height, room for the name there), for an icon-over-name block
	## centred at centre_y.
	var name_y := _name_centre_y(centre_y, lines, font_size)
	var half := float(lines) * float(font_size) * LABEL_PIXEL_SIZE * LABEL_LINE_HEIGHT * 0.5
	var lr := Math.horizontal_span(outline, name_y + half, name_y - half)
	return Vector2((lr.x + lr.y) * 0.5, lr.y - lr.x - NAME_PADDING)


func _name_centre_y(content_y: float, lines: int, font_size: int) -> float:
	## Where the middle of the name's text falls (plane y, metres) for an icon-over-name block centred at content_y.
	var text_h := float(lines) * float(font_size) * LABEL_PIXEL_SIZE * LABEL_LINE_HEIGHT
	var block := ICON_SIZE + ICON_LABEL_GAP + text_h
	return content_y + block * 0.5 - ICON_SIZE - ICON_LABEL_GAP - text_h * 0.5


func _fit_label(label: Label3D, text: String, room: float) -> int:
	## Sets the label's text at the largest size that fits `room` metres: one line if it fits, else wrapped at its spaces onto
	## two lines, else the type shrinks (down to MIN_LABEL_FONT). Returns the number of lines.
	var font: Font = label.font if label.font != null else ThemeDB.fallback_font
	var size := label.font_size
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	var words := text.split(" ")
	while size >= MIN_LABEL_FONT:
		var whole := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x * LABEL_PIXEL_SIZE
		if whole <= room:
			label.font_size = size
			return 1
		if words.size() > 1:
			var widest := 0.0
			for w in words:
				widest = maxf(widest, font.get_string_size(w, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x * LABEL_PIXEL_SIZE)
			if widest <= room:
				label.font_size = size
				label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				label.width = room / LABEL_PIXEL_SIZE
				return 2
		size -= 2
	label.font_size = MIN_LABEL_FONT
	return 1


func _paint() -> void:
	for i in _wedges.size():
		var entry: Dictionary = _entries[i]
		var accent: Color = entry.get("accent", tokens.accent)
		var enabled := bool(entry.get("enabled", true))
		var on := bool(entry.get("active", false))
		var lit := i == _hover and enabled
		var fill: Color = tokens.surface
		var border_colour: Color = accent if enabled else tokens.border
		var border_alpha := 0.6
		if on:
			fill = tokens.accent_deep
			border_alpha = 0.95
		if lit:
			fill = tokens.surface_hover.lerp(accent, 0.28)
			border_alpha = 1.0
		elif i == _hover:
			border_colour = tokens.warn # pointed at but greyed: the border says "not now" and the hint says why
			border_alpha = 0.8
		_set_colour(_wedges[i], Color(fill.r, fill.g, fill.b, 0.97))
		_set_colour(_borders[i], Color(border_colour.r, border_colour.g, border_colour.b, border_alpha))
		_set_colour(_glows[i], Color(accent.r, accent.g, accent.b, _glow_alpha))
		_glows[i].visible = lit and _glow_alpha > 0.001
		var lift := HOVER_LIFT if lit else 0.0
		_wedges[i].position.z = lift
		_borders[i].position.z = lift
		_glows[i].position.z = lift
		_icons[i].modulate = accent if enabled else tokens.text_disabled
		_icons[i].position.z = 0.003 + lift
		_icons[i].scale = Vector3.ONE * (1.12 if lit else 1.0)
		_labels[i].modulate = tokens.text if enabled else tokens.text_disabled
		_labels[i].position.z = 0.004 + lift


func _paint_pill() -> void:
	if _pill_nodes.is_empty():
		return
	var accent: Color = _pill.get("accent", tokens.accent)
	var hot: Color = _pill.get("text_colour", accent) # its own colour (red for Clear): the hover tint, so red text never sits on a pale fill
	var enabled := bool(_pill.get("enabled", true))
	var lit := _pill_hover and enabled
	var fill: Color = tokens.surface # the same as a tile at rest
	var border_colour: Color = accent if enabled else tokens.border
	var border_alpha := 0.6
	if lit:
		fill = tokens.surface_hover.lerp(hot, 0.16)
		border_colour = hot
		border_alpha = 1.0
	elif _pill_hover:
		border_colour = tokens.warn
		border_alpha = 0.8
	_set_colour(_pill_nodes["fill"], Color(fill.r, fill.g, fill.b, 0.97))
	_set_colour(_pill_nodes["border"], Color(border_colour.r, border_colour.g, border_colour.b, border_alpha))
	_set_colour(_pill_nodes["glow"], Color(hot.r, hot.g, hot.b, _glow_alpha))
	_pill_nodes["glow"].visible = lit and _glow_alpha > 0.001
	var lift := HOVER_LIFT if lit else 0.0
	for key in ["fill", "border", "glow"]:
		_pill_nodes[key].position.z = lift
	var text_colour: Color = _pill.get("text_colour", tokens.text) if enabled else tokens.text_disabled
	if lit:
		text_colour = text_colour.lightened(0.35)
	var text: Node3D = _pill_nodes["text"]
	text.position.z = lift
	for glyph in text.get_children():
		(glyph as Label3D).modulate = text_colour


func _summary_for(entry: Dictionary) -> Dictionary:
	## What the wrist panel says about a pointed-at tile: its name and what it does, or (greyed) why it cannot be chosen.
	var enabled := bool(entry.get("enabled", true))
	return {
		"title": str(entry.get("title", entry.get("label", ""))),
		"body": str(entry.get("hint", "")) if enabled else str(entry.get("hint_disabled", "Not available right now")),
		"tone": "normal" if enabled else "warn",
		"accent": entry.get("accent", tokens.accent),
	}


func _update_centre() -> void:
	## Tells the wrist panel what the hand is pointing at; with nothing pointed at, the ring's own name and how to use it.
	if _pill_hover and not _pill.is_empty():
		_summary = _summary_for(_pill)
	elif _hover >= 0 and _hover < _entries.size():
		_summary = _summary_for(_entries[_hover])
	else:
		var ring_name := _title
		if ring_name == "" and title_provider.is_valid():
			ring_name = str(title_provider.call())
		_summary = {"title": ring_name if ring_name != "" else "Tools", "body": "Move to a tile and let go to choose it. Let go in the middle to cancel.", "tone": "normal", "accent": tokens.accent}
	_paint_pill()
	summary_changed.emit(_summary)


func _poly_mesh(outline: PackedVector2Array) -> ArrayMesh:
	var indices := Geometry2D.triangulate_polygon(outline)
	var mesh := ArrayMesh.new()
	if indices.is_empty():
		return mesh
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	for p in outline:
		verts.append(Vector3(p.x, p.y, 0.0))
		normals.append(Vector3.BACK)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _node_for(outline: PackedVector2Array, priority: int) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.mesh = _poly_mesh(outline)
	var m := _material(Color.WHITE, 1.0)
	m.render_priority = priority
	n.material_override = m
	_ring.add_child(n)
	return n


func _set_colour(n: MeshInstance3D, colour: Color) -> void:
	(n.material_override as StandardMaterial3D).albedo_color = colour


func _material(colour: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(colour.r, colour.g, colour.b, alpha)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = true
	m.render_priority = 10
	return m


func _make_label(font_size: int, pixel_size: float, add: bool = true) -> Label3D:
	var l := Label3D.new()
	l.font_size = font_size
	l.pixel_size = pixel_size
	l.shaded = false
	l.no_depth_test = true
	l.outline_size = 8
	l.render_priority = 14
	l.outline_render_priority = 13
	l.outline_modulate = Color(tokens.bg_panel.r, tokens.bg_panel.g, tokens.bg_panel.b, 0.9)
	l.modulate = tokens.text
	if tokens.get("font") != null:
		l.font = tokens.get("font")
	if add:
		add_child(l)
	return l
