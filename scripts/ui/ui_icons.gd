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
	"windows": '<rect x="5" y="9" width="38" height="30" rx="3"/><path d="M5 19H43"/>',
	"files": '<path d="M5 13a2 2 0 0 1 2-2H18L23 17H41a2 2 0 0 1 2 2V37a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2Z"/>',
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
	"colours": '<path d="M24 6C24 6 10 22 10 31a14 14 0 0 0 28 0C38 22 24 6 24 6Z"/>',
	"sections": '<rect x="8" y="8" width="26" height="26" rx="2"/><path d="M4 42L42 4"/>',
	"measure": '<path d="M8 36L36 8L42 14L14 42Z"/><path d="M16 28L20 32M22 22L26 26M28 16L32 20"/>',
	# Windows / Files
	"models": '<path d="M24 6L42 15V33L24 42L6 33V15Z"/><path d="M6 15L24 24L42 15M24 24V42"/>',
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
