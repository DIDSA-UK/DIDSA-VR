extends Node3D
## A small floating badge above the right hand's tracking ring that says which
## mode tool is active (Mates, Measure, Sections, Shoot hide) — the "advisory
## icon" for the one-active-tool rule. A mode tool keeps working with the tablet
## closed (you pick things in the world with the laser), so without this you
## could forget what your trigger is about to do. Hidden while no mode tool is on.
##
## Billboarded sprite (always faces you) plus a one-word label. Icon, name and
## accent come straight from the registry, so a new mode tool gets its badge for free.

const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const DISC_PX := 96
const ICON_PX := 56

var tokens: Resource
var _registry
var _manager
var _sprite: Sprite3D
var _label: Label3D
var _cache := {}


func setup(manager, registry, p_tokens: Resource) -> void:
	_manager = manager
	_registry = registry
	tokens = p_tokens
	position = Vector3(0.0, 0.055, 0.083) # above the tracking ring (controller.gd's _add_tracking_ring())
	_sprite = Sprite3D.new()
	_sprite.pixel_size = 0.032 / float(DISC_PX) # a 3.2 cm disc
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.shaded = false
	_sprite.double_sided = true
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	add_child(_sprite)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.shaded = false
	_label.font_size = 32
	_label.pixel_size = 0.00045
	_label.outline_size = 8
	_label.position = Vector3(0.0, -0.024, 0.0)
	add_child(_label)
	visible = false
	_manager.active_changed.connect(_on_active_changed)


func shown_tool_id() -> String:
	return _manager.active_id if visible else ""


func _on_active_changed(tool_id: String) -> void:
	if tool_id == "":
		visible = false
		return
	var def = _registry.tool_def(tool_id)
	var cat = _registry.category_of(tool_id)
	if def == null or cat == null:
		visible = false
		return
	_sprite.texture = _texture_for(def.icon, cat.accent)
	_label.text = def.label
	_label.modulate = cat.accent.lightened(0.3)
	visible = true


func _texture_for(icon_name: String, accent: Color) -> ImageTexture:
	var key := "%s|%s" % [icon_name, accent.to_html()]
	if _cache.has(key):
		return _cache[key]
	var img := Image.create(DISC_PX, DISC_PX, false, Image.FORMAT_RGBA8)
	var c := (DISC_PX - 1) * 0.5
	var outer := DISC_PX * 0.5 - 1.0
	for y in DISC_PX:
		for x in DISC_PX:
			var d := Vector2(x - c, y - c).length()
			if d <= outer:
				var edge := clampf(outer - d, 0.0, 1.0)
				var fill: Color = accent if d > outer - 5.0 else tokens.bg_panel
				img.set_pixel(x, y, Color(fill.r, fill.g, fill.b, edge * (1.0 if d > outer - 5.0 else 0.92)))
	var icon := UiIcons.texture(icon_name, ICON_PX).get_image()
	var offset := Vector2i((DISC_PX - ICON_PX) / 2, (DISC_PX - ICON_PX) / 2)
	for y in ICON_PX:
		for x in ICON_PX:
			var a := icon.get_pixel(x, y).a
			if a > 0.0:
				var base := img.get_pixel(x + offset.x, y + offset.y)
				var out := base.lerp(Color(accent.r, accent.g, accent.b, 1.0), a)
				out.a = maxf(base.a, a)
				img.set_pixel(x + offset.x, y + offset.y, out)
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex
