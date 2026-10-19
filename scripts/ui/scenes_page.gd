extends RefCounted
## The wrist tablet's Scenes page (Assemble; DIDSA-CAD `docs/scenes-scope.md`, S2): the scenes of the assembly you work in
## (scenes_tool.gd), what shows now, and the scene buttons.
##
##   * what shows: a scene's name, or the default (the real model), and whether what is on screen differs from it;
##   * which assembly: the world's, or an open room's (a scene lives in its own assembly);
##   * Save as new... (the keyboard names it), Update scene (the shown one), Back to default (Return parts);
##   * when one of those would lose unsaved changes it asks first: Update / Discard / Stay;
##   * a row per scene: Show, Delete;
##   * View on Show (the scene's viewpoint turns and places the model; the scale stays) and Save my view (Save as new keeps where
##     you look from as the scene's viewpoint).

var tool: Node ## scenes_tool.gd
var tokens: Resource
var open_keyboard: Callable ## (initial text, on_done(text), options) - main.gd's open_keyboard_for
var toast: Callable ## (text, kind)
var scope_names: Callable = Callable() ## (root Part id) -> a name for the scope row

var status: Label
var unsaved: Label
var scope_row: HBoxContainer
var ask_box: PanelContainer
var list_box: VBoxContainer
var update_button: Button
var back_button: Button
var save_view := true
var _page: Control


func _init(p_tool: Node, p_tokens: Resource, p_open_keyboard: Callable, p_toast: Callable) -> void:
	tool = p_tool
	tokens = p_tokens
	open_keyboard = p_open_keyboard
	toast = p_toast


func build() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)
	_page = page
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(status)
	unsaved = _hint("", true)
	page.add_child(unsaved)
	scope_row = HBoxContainer.new()
	scope_row.add_theme_constant_override("separation", 8)
	page.add_child(scope_row)

	var actions := _row()
	page.add_child(actions)
	actions.add_child(_button("Save as new...", _on_save_new, &"ButtonAccent"))
	update_button = _button("Update scene", func() -> void: _run(func() -> Variant: return await tool.update_scene()))
	actions.add_child(update_button)
	back_button = _button("Back to default", func() -> void: _run(func() -> Variant: return await tool.request_back()))
	actions.add_child(back_button)

	ask_box = PanelContainer.new()
	ask_box.theme_type_variation = &"PanelRaised"
	var ask := VBoxContainer.new()
	ask_box.add_child(ask)
	ask.add_child(_hint("What is on screen differs from the scene. Keep it in the scene first?"))
	var answers := _row()
	ask.add_child(answers)
	answers.add_child(_button("Update", func() -> void: _run(func() -> Variant: return await tool.answer("update")), &"ButtonAccent"))
	answers.add_child(_button("Discard", func() -> void: _run(func() -> Variant: return await tool.answer("discard")), &"ButtonDanger"))
	answers.add_child(_button("Stay", func() -> void: _run(func() -> Variant: return await tool.answer("stay"))))
	page.add_child(ask_box)

	var toggles := _row()
	page.add_child(toggles)
	toggles.add_child(_toggle("View on Show", tool.use_viewpoint, func(on: bool) -> void: tool.use_viewpoint = on))
	toggles.add_child(_toggle("Save my view", save_view, func(on: bool) -> void: save_view = on))

	var head := _row()
	page.add_child(head)
	var title := Label.new()
	title.text = "Scenes"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var refresh := _button("Refresh", func() -> void: _run(func() -> Variant: return await tool.refresh()))
	refresh.size_flags_horizontal = Control.SIZE_SHRINK_END
	head.add_child(refresh)
	list_box = VBoxContainer.new()
	list_box.add_theme_constant_override("separation", 6)
	page.add_child(list_box)

	var timer := Timer.new()
	timer.wait_time = 0.5
	timer.autostart = true
	timer.timeout.connect(_refresh_status)
	page.add_child(timer)
	tool.scenes_changed.connect(refresh_all)
	page.tree_exiting.connect(func() -> void:
		if tool.scenes_changed.is_connected(refresh_all):
			tool.scenes_changed.disconnect(refresh_all))
	refresh_all()
	tool.refresh() # (fire and forget: the list fills when it lands)
	return page


func refresh_all() -> void:
	if not is_instance_valid(_page):
		return
	_refresh_status()
	_fill_scopes()
	_fill_list()


func _refresh_status() -> void:
	if not is_instance_valid(status):
		return
	var showing: String = tool.shown_name()
	status.text = "Showing: %s" % showing if showing != "" else "Showing: the default (the real model)"
	var relaxed: bool = tool.mates_tool != null and tool.mates_tool.relaxed
	var changed: bool = relaxed and tool.has_unsaved()
	unsaved.text = ("Changed since %s: Update scene or Save as new keeps it." % ("the scene was shown" if showing != "" else "the default")) if changed else \
		("Mates are relaxed: moves and paint are temporary." if relaxed else "Show a scene, or relax the mates, move and paint, then Save as new.")
	update_button.disabled = showing == ""
	back_button.disabled = not relaxed
	ask_box.visible = not tool.pending_ask.is_empty()


func _fill_scopes() -> void:
	for c in scope_row.get_children():
		scope_row.remove_child(c)
		c.queue_free()
	var all: Array = tool._scopes()
	scope_row.visible = all.size() > 1
	if all.size() < 2:
		return
	for s in all:
		var root := str(s["root"])
		var label := str(scope_names.call(root)) if scope_names.is_valid() else root
		var b := _button(label, func() -> void:
			tool.scope_root = root
			_run(func() -> Variant: return await tool.refresh()))
		b.toggle_mode = true
		b.button_pressed = root == tool.current_root()
		scope_row.add_child(b)


func _fill_list() -> void:
	for c in list_box.get_children():
		list_box.remove_child(c)
		c.queue_free()
	var scenes: Array = tool.scenes_of()
	if scenes.is_empty():
		list_box.add_child(_hint("No scenes in this assembly yet."))
		return
	for scene in scenes:
		var id := str(scene.get("id", ""))
		var row := _row()
		var name_l := Label.new()
		var marks := ""
		if id == tool.shown_id():
			marks += "  (showing)"
		if not (scene.get("unresolved", []) as Array).is_empty():
			marks += "  (%d no longer match)" % (scene["unresolved"] as Array).size()
		name_l.text = str(scene.get("name", "")) + marks
		name_l.clip_text = true
		name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_l)
		var show := _button("Show", func() -> void: _run(func() -> Variant: return await tool.request_show(id)))
		show.size_flags_horizontal = Control.SIZE_SHRINK_END
		show.custom_minimum_size = Vector2(120, 56)
		row.add_child(show)
		var del := _button("Delete", func() -> void: _run(func() -> Variant: return await tool.delete_scene(id)), &"ButtonDanger")
		del.size_flags_horizontal = Control.SIZE_SHRINK_END
		del.custom_minimum_size = Vector2(120, 56)
		row.add_child(del)
		list_box.add_child(row)


func _on_save_new() -> void:
	if not open_keyboard.is_valid():
		return
	var suggestion := "Scene %d" % (tool.scenes_of().size() + 1)
	open_keyboard.call(suggestion, func(text: String) -> void:
		var name_ := text.strip_edges()
		if name_ == "":
			_toast("A scene needs a name.", "warn")
			return
		_run(func() -> Variant: return await tool.save_as_new(name_, save_view))
	, {"mode": "full", "title": "Scene name", "confirm_label": "Save"})


func _run(call: Callable) -> void:
	## Runs a scenes_tool coroutine and says how it went (a refused request as a warning).
	var r = await call.call()
	if r is Dictionary and not r.get("ok", true):
		_toast(str(r.get("error", "That didn't work.")), "warn")
	refresh_all()


func _toast(text: String, kind: String) -> void:
	if toast.is_valid():
		toast.call(text, kind)


# --- widgets (the tablet's look) ---

func _hint(text: String, small: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = &"LabelSmall" if small else &"LabelDim"
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _button(text: String, callback: Callable, variation: StringName = &"") -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 56)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if variation != &"":
		b.theme_type_variation = variation
	b.pressed.connect(callback)
	return b


func _toggle(text: String, on: bool, apply: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_pressed = on
	b.custom_minimum_size = Vector2(0, 56)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.toggled.connect(apply)
	return b


func _row() -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 8)
	return r
