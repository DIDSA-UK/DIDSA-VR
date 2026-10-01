extends Control
## The contextual list beside the tablet: whatever the active tool has a list of
## (mates, measurement results, model files, undo history). Pure 2D UI, no XR:
## it runs in a plain window (the UI Lab) exactly as it does on a SubViewport quad.
##
## Rows are plain data (see tablet_registry.gd): {id, title, subtitle, state,
## actions: [{label, callback, danger, confirm}]}. set_list() rebuilds only when
## the visible content actually changed, so a provider can be polled cheaply
## without the list flickering or losing the scroll position. An action with
## "confirm": true needs a second press within 3 s ("Sure?") before it runs.

const UiThemes := preload("res://scripts/ui/ui_themes.gd")
const FxOverlay := preload("res://scripts/ui/fx_overlay.gd")

var tokens: Resource
var _fx: ColorRect
var _seen_revision := -1
var scroll: ScrollContainer ## the host hands this to its LaserSurface as scroll_target
var _title: Label
var _count: Label
var _rows: VBoxContainer
var _signature := ""
var _confirm_token := 0


func setup(p_tokens: Resource, viewport_size: Vector2) -> void:
	tokens = p_tokens
	theme = tokens.build_theme()
	_seen_revision = UiThemes.revision
	size = viewport_size
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", tokens.gap)
	panel.add_child(column)
	var head := HBoxContainer.new()
	column.add_child(head)
	_title = Label.new()
	_title.theme_type_variation = &"LabelTitle"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.clip_text = true
	head.add_child(_title)
	_count = Label.new()
	_count.theme_type_variation = &"LabelDim"
	head.add_child(_count)
	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", tokens.gap)
	scroll.add_child(_rows)
	_fx = FxOverlay.new()
	add_child(_fx)
	_fx.setup(tokens)


func apply_theme() -> void:
	## See tablet_ui.gd's apply_theme(): re-themed in place; the rows are rebuilt on the next poll
	## (their state colours come from the theme), the scroll position is kept by the host's poll.
	_seen_revision = UiThemes.revision
	theme = tokens.build_theme()
	_fx.refresh(tokens)
	_signature = ""


func _process(_delta: float) -> void:
	if _seen_revision != UiThemes.revision:
		apply_theme()


func set_list(title: String, rows: Array, empty_text: String = "Nothing here yet.") -> void:
	var sig := _signature_of(title, rows, empty_text)
	if sig == _signature:
		return
	_signature = sig
	_confirm_token += 1
	_title.text = title
	_count.text = str(rows.size()) if not rows.is_empty() else ""
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	if rows.is_empty():
		var none := Label.new()
		none.text = empty_text
		none.theme_type_variation = &"LabelDim"
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_rows.add_child(none)
		return
	for row in rows:
		_rows.add_child(_build_row(row))


func play_intro() -> void:
	## Rows fade in one after another (25 ms apart, capped so the whole thing stays under
	## ~300 ms) when the panel opens. Instant with Reduce motion.
	var d: float = tokens.duration(0.12)
	if d <= 0.0:
		return
	var i := 0
	for card in _rows.get_children():
		card.modulate.a = 0.0
		var t := create_tween()
		t.tween_interval(minf(float(i) * 0.025, 0.18))
		t.tween_property(card, "modulate:a", 1.0, d)
		i += 1


func row_count() -> int:
	return _rows.get_child_count()


func _signature_of(title: String, rows: Array, empty_text: String) -> String:
	var plain := []
	for row in rows:
		var labels := []
		for a in row.get("actions", []):
			labels.append([str(a.get("label", "")), bool(a.get("danger", false))])
		plain.append([str(row.get("id", "")), str(row.get("title", "")), str(row.get("subtitle", "")), str(row.get("state", "")), labels])
	return JSON.stringify([title, empty_text, plain])


func _build_row(row: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.theme_type_variation = &"PanelRaised"
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 4)
	card.add_child(inner)
	var title := Label.new()
	title.text = str(row.get("title", ""))
	title.clip_text = true
	inner.add_child(title)
	var subtitle := str(row.get("subtitle", ""))
	if subtitle != "":
		var sub := Label.new()
		sub.text = subtitle
		sub.theme_type_variation = &"LabelDim"
		sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		match str(row.get("state", "normal")):
			"warn": sub.add_theme_color_override("font_color", tokens.warn)
			"error": sub.add_theme_color_override("font_color", tokens.danger)
			"ok": sub.add_theme_color_override("font_color", tokens.ok)
		inner.add_child(sub)
	var actions: Array = row.get("actions", [])
	if not actions.is_empty():
		var bar := HBoxContainer.new()
		bar.add_theme_constant_override("separation", tokens.gap)
		inner.add_child(bar)
		for action in actions:
			bar.add_child(_build_action(action))
	return card


func _build_action(action: Dictionary) -> Button:
	var button := Button.new()
	var label := str(action.get("label", "?"))
	button.text = label
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size = Vector2(0, 52)
	if bool(action.get("danger", false)):
		button.theme_type_variation = &"ButtonDanger"
	elif bool(action.get("accent", false)):
		button.theme_type_variation = &"ButtonAccent"
	var callback: Callable = action.get("callback", Callable())
	var needs_confirm := bool(action.get("confirm", false))
	var armed := [false]
	button.pressed.connect(func() -> void:
		if needs_confirm and not armed[0]:
			armed[0] = true
			button.text = "Sure?"
			var token := _confirm_token
			get_tree().create_timer(3.0).timeout.connect(func() -> void:
				if is_instance_valid(button) and token == _confirm_token and armed[0]:
					armed[0] = false
					button.text = label
			)
			return
		armed[0] = false
		button.text = label
		if callback.is_valid():
			callback.call()
	)
	return button
