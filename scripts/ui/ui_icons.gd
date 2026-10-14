extends RefCounted
## One icon family for the whole UI, drawn on a 48 x 48 grid with a single
## 3-unit round stroke (heavier than DIDSA-CAD's flat 1.5 so it reads at arm's
## length in a headset; same single-colour stroke language as CAD's SVG set in
## client/assets/icons). Each icon is a handful of SVG elements held as a
## string and rasterised at the exact pixel size asked for with
## Image.load_svg_from_string(), so there is no editor import step (tests and
## `--headless --script` runs need none) and an export needs no extra files.
##
## Icons are white. Tint them with a Button's icon_*_color theme items (the UI
## theme does this) or a modulate.
##
##   Button.icon = preload("res://scripts/ui/ui_icons.gd").texture("mates", 32)
##
## To add one: add a line to _ICONS (inner SVG only). A name that isn't known
## falls back to a plain ring, so a typo is visible rather than blank.

const _OPEN := '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" fill="none" stroke="white" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">'
const _CLOSE := '</svg>'

const _ICONS := {
	# categories
	"view": '<path d="M4 24C10 13 38 13 44 24C38 35 10 35 4 24Z"/><circle cx="24" cy="24" r="5"/>',
	"assembly": '<rect x="6" y="15" width="22" height="22" rx="2"/><rect x="20" y="9" width="22" height="22" rx="2"/>',
	"room": '<path d="M24 5L41 14.5V33.5L24 43L7 33.5V14.5Z"/><path d="M7 14.5L24 24L41 14.5"/><path d="M24 24V43" stroke-dasharray="3 3"/>',
	"windows": '<rect x="5" y="9" width="38" height="30" rx="3"/><path d="M5 19H43"/>',
	"files": '<path d="M5 13a2 2 0 0 1 2-2H18L23 17H41a2 2 0 0 1 2 2V37a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2Z"/>',
	# home screen tiles (new)
	"design": '<path d="M9 39L11 29L31 9L39 17L19 37Z"/><path d="M27 13L35 21"/><path d="M9 39L19 37"/>',
	"tree": '<rect x="17" y="6" width="14" height="10" rx="2"/><rect x="5" y="32" width="14" height="10" rx="2"/><rect x="29" y="32" width="14" height="10" rx="2"/><path d="M24 16V24M12 32V24H36V32"/>',
	"calculator": '<rect x="10" y="5" width="28" height="38" rx="4"/><rect x="15" y="10" width="18" height="8" rx="1"/><path d="M16 26H18M24 26H26M32 26H34M16 33H18M24 33H26M32 33H34M16 39H18M24 39H26"/>',
	"image": '<rect x="5" y="9" width="38" height="30" rx="3"/><circle cx="16" cy="20" r="4"/><path d="M5 34L17 25L26 32L33 27L43 35"/>',
	"browser": '<circle cx="24" cy="24" r="18"/><path d="M6 24H42"/><path d="M24 6C16 14 16 34 24 42M24 6C32 14 32 34 24 42"/>',
	"movement": '<path d="M24 6V42M6 24H42"/><path d="M19 11L24 6L29 11M19 37L24 42L29 37M11 19L6 24L11 29M37 19L42 24L37 29"/>',
	"comfort": '<path d="M6 19H14L26 9V39L14 29H6Z"/><path d="M32 17A10 10 0 0 1 32 31M37 12A17 17 0 0 1 37 36"/>',
	"back": '<path d="M30 9L15 24L30 39"/>',
	# utility cluster
	"undo": '<path d="M17 11L8 20L17 29"/><path d="M8 20H28a10 10 0 0 1 0 20H20"/>',
	"redo": '<path d="M31 11L40 20L31 29"/><path d="M40 20H20a10 10 0 0 0 0 20H28"/>',
	"settings": '<path d="M6 14H12M20 14H42"/><circle cx="16" cy="14" r="4"/><path d="M6 24H28M36 24H42"/><circle cx="32" cy="24" r="4"/><path d="M6 34H10M18 34H42"/><circle cx="14" cy="34" r="4"/>',
	"close": '<path d="M12 12L36 36M36 12L12 36"/>',
	"help": '<circle cx="24" cy="24" r="18"/><path d="M18 19a6 6 0 1 1 9 5c-2 1.5-3 2.5-3 5"/><path d="M24 35.5V36"/>',
	"history": '<circle cx="24" cy="24" r="18"/><path d="M24 12V24L32 30"/>',
	"check": '<path d="M10 25L20 35L38 13"/>',
	"warn": '<path d="M24 6L44 40H4Z"/><path d="M24 19V29"/><path d="M24 35V35.5"/>',
	# View tools
	"navigate": '<path d="M24 6V42M6 24H42"/><path d="M19 11L24 6L29 11M19 37L24 42L29 37M11 19L6 24L11 29M37 19L42 24L37 29"/>',
	"scale": '<path d="M28 8H40V20M20 40H8V28M40 8L26 22M8 40L22 26"/>',
	"visibility": '<path d="M4 24C10 13 38 13 44 24C38 35 10 35 4 24Z"/><circle cx="24" cy="24" r="5"/><path d="M8 42L40 6"/>',
	"shoot_hide": '<circle cx="24" cy="24" r="12"/><path d="M24 5V13M24 35V43M5 24H13M35 24H43"/>',
	"environment": '<circle cx="24" cy="19" r="8"/><path d="M4 36H44M12 43H36"/>',
	# Assembly tools
	"mates": '<circle cx="24" cy="24" r="17"/><circle cx="24" cy="24" r="8"/><path d="M24 24V24.5"/>',
	"paint": '<path d="M6 17H30V29H6Z"/><path d="M30 20H40"/><path d="M40 14V26"/><path d="M12 29V38H20V29"/>',
	"invert": '<circle cx="24" cy="24" r="16"/><path d="M24 8A16 16 0 0 1 24 40Z" fill="white"/>',
	"flip": '<path d="M8 18H36"/><path d="M30 12L36 18L30 24"/><path d="M40 30H12"/><path d="M18 24L12 30L18 36"/>',
	"clear_picks": '<path d="M10 10L38 38"/><path d="M38 10L10 38"/><circle cx="24" cy="24" r="17"/>',
	"layers": '<path d="M24 6L42 16L24 26L6 16Z"/><path d="M6 24L24 34L42 24"/><path d="M6 32L24 42L42 32"/>',
	"tablet": '<rect x="9" y="6" width="30" height="36" rx="4"/><path d="M21 36H27"/>',
	"tools": '<circle cx="24" cy="24" r="6"/><circle cx="24" cy="8" r="3"/><circle cx="24" cy="40" r="3"/><circle cx="8" cy="24" r="3"/><circle cx="40" cy="24" r="3"/>',
	"colours": '<path d="M24 6C24 6 10 22 10 31a14 14 0 0 0 28 0C38 22 24 6 24 6Z"/>',
	"sections": '<rect x="8" y="8" width="26" height="26" rx="2"/><path d="M4 42L42 4"/>',
	"measure": '<path d="M8 36L36 8L42 14L14 42Z"/><path d="M16 28L20 32M22 22L26 26M28 16L32 20"/>',
	# Windows / Files
	"models": '<path d="M24 6L42 15V33L24 42L6 33V15Z"/><path d="M6 15L24 24L42 15M24 24V42"/>',
	# Design table (scripts/design_table/): the Table tool, its categories, and its tools
	"table": '<path d="M12 14H36L44 28H4Z"/><path d="M10 28V42M38 28V42"/>',
	"cat_sketch": '<path d="M8 40L10 30L32 8L40 16L18 38Z"/><path d="M27 13L35 21"/>',
	"cat_constrain": '<rect x="5" y="18" width="20" height="12" rx="6"/><rect x="23" y="18" width="20" height="12" rx="6"/>',
	"cat_feature": '<rect x="8" y="26" width="26" height="14" rx="2"/><path d="M8 26L16 16H42L34 26M42 16V30L34 40"/>',
	"cat_modify": '<path d="M8 40L26 22"/><path d="M30 8a9 9 0 0 0-5 12l4 4a9 9 0 0 0 12-5l-6 3-4-4 3-6Z"/>',
	"cat_inspect": '<circle cx="21" cy="21" r="14"/><path d="M31 31L42 42"/>',
	"tool_line": '<path d="M9 39L39 9"/><circle cx="9" cy="39" r="3"/><circle cx="39" cy="9" r="3"/>',
	"tool_rectangle": '<rect x="8" y="12" width="32" height="24" rx="1"/>',
	"tool_circle": '<circle cx="24" cy="24" r="16"/><path d="M24 24V24.5"/>',
	"tool_arc": '<path d="M8 36A20 20 0 0 1 40 36"/><path d="M8 36V36.5M40 36V36.5M24 36V36.5"/>',
	"tool_polygon": '<path d="M24 6L41 18L35 38H13L7 18Z"/>',
	"tool_slot": '<path d="M14 14H34A10 10 0 0 1 34 34H14A10 10 0 0 1 14 14Z"/><path d="M14 24H34" stroke-dasharray="3 3"/>',
	"tool_select": '<path d="M10 6L10 36L19 28L25 42L31 39L25 26L37 26Z"/>',
	"tool_point": '<circle cx="24" cy="24" r="4"/><path d="M24 7V14M24 34V41M7 24H14M34 24H41"/>',
	"tool_dimension": '<path d="M8 34H40"/><path d="M8 28V40M40 28V40"/><path d="M14 14H34"/>',
	"tool_horizontal": '<path d="M6 24H42"/><path d="M6 17V31M42 17V31"/>',
	"tool_vertical": '<path d="M24 6V42"/><path d="M17 6H31M17 42H31"/>',
	"tool_parallel": '<path d="M13 40L25 8M27 40L39 8"/>',
	"tool_perpendicular": '<path d="M8 40H40M24 40V8"/><path d="M24 31H33V40"/>',
	"tool_coincident": '<path d="M8 40L24 24L40 40"/><circle cx="24" cy="24" r="5"/>',
	"tool_extrude": '<rect x="8" y="26" width="26" height="14" rx="2"/><path d="M8 26L16 16H42L34 26M42 16V30L34 40"/>',
	"tool_revolve": '<path d="M24 6V42"/><path d="M24 14C34 14 40 20 40 24S34 34 24 34"/>',
	"tool_fillet": '<path d="M8 8V28a12 12 0 0 0 12 12H40"/>',
	"tool_chamfer": '<path d="M8 8V28L20 40H40"/>',
	"tool_shell": '<rect x="7" y="9" width="34" height="30" rx="3"/><rect x="15" y="17" width="18" height="14" rx="1"/>',
	"tool_mirror": '<path d="M24 5V43" stroke-dasharray="3 3"/><path d="M19 14L7 24L19 34Z"/><path d="M29 14L41 24L29 34Z"/>',
	"tool_loft": '<path d="M8 36H20L14 26H26L20 16H32L26 8"/><path d="M8 36L26 8M20 36L32 16" stroke-dasharray="2 3"/>',
	"tool_sweep": '<circle cx="12" cy="34" r="5"/><path d="M14 30C20 10 30 40 38 12"/>',
	"tool_pattern": '<rect x="6" y="6" width="12" height="12"/><rect x="28" y="6" width="12" height="12"/><rect x="6" y="28" width="12" height="12"/><rect x="28" y="28" width="12" height="12"/>',
	"tool_boolean": '<circle cx="18" cy="24" r="12"/><circle cx="30" cy="24" r="12"/>',
	"tool_merge": '<path d="M6 14H22V34H6Z"/><path d="M26 14H42V34H26Z"/><path d="M22 24H26"/>',
	"tool_split": '<rect x="8" y="10" width="32" height="28"/><path d="M24 4V44" stroke-dasharray="3 3"/>',
	"tool_trim": '<path d="M6 24H42"/><path d="M24 8V40"/><path d="M6 24H20" stroke-width="5"/>',
	"tool_offset": '<path d="M8 36L36 8"/><path d="M14 42L42 14" stroke-dasharray="3 3"/>',
	"tool_move_face": '<rect x="8" y="22" width="26" height="18"/><path d="M34 22L42 14M38 14H42V18"/>',
	"tool_delete_face": '<rect x="8" y="22" width="26" height="18"/><path d="M12 12L28 28M28 12L12 28"/>',
	"tool_move_body": '<rect x="8" y="18" width="20" height="20"/><path d="M30 12H42M38 8L42 12L38 16"/>',
	"tool_scale_body": '<rect x="10" y="22" width="16" height="16"/><rect x="6" y="6" width="32" height="32" stroke-dasharray="3 3"/>',
	"tool_delete_body": '<rect x="10" y="14" width="26" height="26"/><path d="M6 8L42 44"/>',
	"tool_ellipse": '<ellipse cx="24" cy="24" rx="18" ry="10"/>',
	"tool_ellipse_arc": '<path d="M6 24A18 10 0 0 1 42 24"/><circle cx="24" cy="24" r="1.5"/>',
	"tool_spline": '<path d="M6 34C14 6 24 44 42 14"/><circle cx="6" cy="34" r="2"/><circle cx="42" cy="14" r="2"/>',
	"tool_text": '<path d="M10 12H38M24 12V38M18 38H30"/>',
	"tool_more": '<path d="M11 24V24.5M24 24V24.5M37 24V24.5"/>',
	"snap": '<path d="M10 8V26a14 14 0 0 0 28 0V8H28V26a4 4 0 0 1-8 0V8Z"/><path d="M10 14H20M28 14H38"/>',
	"feat_plane": '<path d="M8 32L20 14H42L30 32Z"/><path d="M24 36V42"/>',
	"plus": '<path d="M24 10V38M10 24H38"/>',
	"recentre": '<circle cx="24" cy="24" r="9"/><circle cx="24" cy="24" r="2"/><path d="M24 5V13M24 35V43M5 24H13M35 24H43"/>',
	"to_arena": '<path d="M24 31V8"/><path d="M15 17L24 8L33 17"/><path d="M8 34V40H40V34"/>',
	"lock": '<rect x="10" y="22" width="28" height="20" rx="3"/><path d="M16 22V15a8 8 0 0 1 16 0V22"/>',
	"eye": '<path d="M4 24C10 14 17 10 24 10S38 14 44 24C38 34 31 38 24 38S10 34 4 24Z"/><circle cx="24" cy="24" r="6"/>',
	"eye_half": '<path d="M4 24C10 14 17 10 24 10S38 14 44 24C38 34 31 38 24 38S10 34 4 24Z"/><path d="M24 10V38"/><path d="M4 24C10 14 17 10 24 10V38C17 38 10 34 4 24Z" fill="white"/>',
	"eye_off": '<path d="M4 24C10 14 17 10 24 10S38 14 44 24C38 34 31 38 24 38S10 34 4 24Z"/><path d="M8 40L40 8"/>',
	"eye_shaded": '<path d="M24 6L42 15V33L24 42L6 33V15Z" fill="white"/>',
	"eye_shaded_edges": '<path d="M24 6L42 15V33L24 42L6 33V15Z"/><path d="M6 15L24 24L42 15M24 24V42"/><path d="M6 15L24 6L42 15L24 24Z" fill="white"/>',
	"eye_wireframe": '<path d="M24 6L42 15V33L24 42L6 33V15Z"/><path d="M6 15L24 24L42 15M24 24V42"/>',
	"fit": '<path d="M7 17V7H17M31 7H41V17M41 31V41H31M17 41H7V31"/><rect x="17" y="17" width="14" height="14" rx="1"/>',
	"enforce": '<path d="M10 25L20 35L38 13"/><circle cx="24" cy="24" r="20"/>',
	# environment scenes
	"scene_light": '<circle cx="24" cy="24" r="8"/><path d="M24 4V10M24 38V44M4 24H10M38 24H44M10 10L14 14M34 34L38 38M38 10L34 14M14 34L10 38"/>',
	"scene_dark": '<path d="M36 29A15 15 0 1 1 19 10A12 12 0 0 0 36 29Z"/>',
	"scene_mid": '<circle cx="24" cy="24" r="15"/><path d="M24 9A15 15 0 0 1 24 39Z" fill="white"/>',
	"scene_passthrough": '<rect x="5" y="14" width="38" height="20" rx="9"/><circle cx="16" cy="24" r="4"/><circle cx="32" cy="24" r="4"/>',
}

static var _cache := {}


static func has_icon(name: String) -> bool:
	return _ICONS.has(name)


static func names() -> Array:
	return _ICONS.keys()


static func svg(name: String) -> String:
	var body: String = _ICONS.get(name, '<circle cx="24" cy="24" r="14"/>')
	return _OPEN + body + _CLOSE


static func texture(name: String, px: int = 32) -> ImageTexture:
	var key := "%s@%d" % [name, px]
	if _cache.has(key):
		return _cache[key]
	var img := Image.new()
	var err := img.load_svg_from_string(svg(name), float(px) / 48.0)
	if err != OK or img.is_empty():
		img = Image.create(px, px, false, Image.FORMAT_RGBA8) # never hand back null: a blank is a visible bug, a crash isn't
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex
