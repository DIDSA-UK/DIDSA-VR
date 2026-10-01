extends RefCounted
## Which look the UI has, and whether shader effects are on. Static, no autoload (see
## ui_feedback.gd for why): the live theme is ONE shared resource, ui/didsa_ui_theme.tres,
## that every tablet / window / keyboard already holds. Picking a theme copies a preset
## (ui/themes/*.tres) into that shared resource in place, and bumps `revision`. Every UI
## watches `revision` and re-themes itself in place the next frame (no rebuild, no lost state).
##
## Presets are ordinary DidsaUITheme resources, so you can edit them in the Godot Inspector:
##   ui/themes/navy.tres    the original look (dark navy, cyan accent, rounded, outlined)
##   ui/themes/simple.tres  flat and plain: slate grey, square-ish, thin outlines, little glow
##   ui/themes/dark.tres    near-black neutral greys, softer text for dark rooms
## To add a theme: save a copy of one as ui/themes/<name>.tres and add it to PRESETS / ORDER.
##
## Shader effects (fx_enabled): the glass overlay shader (shaders/ui_glass.gdshader via
## fx_overlay.gd) and the soft glow on hovered / selected buttons. One switch for all of it;
## each theme sets how strong the effects are with its fx_* tokens.

const LIVE_PATH := "res://ui/didsa_ui_theme.tres"
const PRESETS := {
	"Navy": "res://ui/themes/navy.tres",
	"Simple": "res://ui/themes/simple.tres",
	"Dark": "res://ui/themes/dark.tres",
}
const ORDER: Array[String] = ["Navy", "Simple", "Dark"]

static var current := "Navy"
static var fx_enabled := true
static var revision := 0 ## bumped by every theme or effects change: UIs compare and re-theme themselves


static func live() -> Resource:
	return load(LIVE_PATH)


static func preset(theme_name: String) -> Resource:
	return load(PRESETS[theme_name]) if PRESETS.has(theme_name) else null


static func apply(theme_name: String) -> bool:
	## True if the theme exists and is now applied.
	var source := preset(theme_name)
	if source == null:
		return false
	live().apply_from(source)
	current = theme_name
	revision += 1
	return true


static func set_fx(on: bool) -> void:
	if on != fx_enabled:
		fx_enabled = on
		revision += 1
