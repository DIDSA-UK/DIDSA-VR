extends RefCounted
## What the redesigned tablet shows, as DATA: categories (the top grid) and the
## tools inside each (the left rail). The layout code reads this and never names
## a specific tool, so adding a tool or a whole category is one registration call
## and touches no layout code.
##
##   var reg := preload("res://scripts/ui/tablet_registry.gd").new()
##   reg.add_category("view", "View", "view", Color(0.35, 0.78, 0.95))
##   reg.add_tool("view", "scale", "Scale", "scale", _build_scale_page)
##   reg.add_tool("assembly", "mates", "Mates", "mate", _build_mates_page,
##       {"kind": "mode", "on_activate": ..., "on_deactivate": ..., "list": ...})
##
## Pure data, no scene tree, so it is unit-tested on its own (tests/tablet_registry.gd).
##
## ToolDef.kind:
##   "page"  an ordinary page of controls (Scale, Colours, Files...).
##   "mode"  a tool that changes what the laser does in the world (Mates, Measure,
##           Sections, Shoot-to-hide). At most ONE mode tool is active at a time;
##           that rule lives in tool_manager.gd, which calls on_activate /
##           on_deactivate. The registry only stores the callables.
##
## ToolDef.build:  Callable() -> Control, the tool's controls pane.
## ToolDef.status_provider / hint / on_select / help: see the fields; all optional.
## ToolDef.list_provider (optional): Callable() -> Array of row Dictionaries for the
##           contextual side panel, each {id, title, subtitle, state, actions}
##           where state is "normal" | "ok" | "warn" | "error" and actions is an
##           Array of {label, danger, callback}. An invalid Callable = no list.

signal changed

const MAX_CATEGORIES := 8 ## the grid is 4 columns x 2 rows
const GRID_COLUMNS := 4


class ToolDef extends RefCounted:
	var id: String
	var category_id: String
	var label: String
	var icon: String
	var kind := "page"
	var build: Callable = Callable()
	var list_provider: Callable = Callable()
	var on_activate: Callable = Callable()
	var on_deactivate: Callable = Callable()
	var help: String = "" ## text of the tool header's "?" card
	var hint: String = "" ## one-line instruction for the status line when no status_provider text is available
	var status_provider: Callable = Callable() ## () -> String, live text for the status line
	var on_select: Callable = Callable() ## runs whenever the tool becomes the one being viewed (refresh data)
	var list_empty: String = "Nothing here yet." ## side-panel text when list_provider returns no rows

	func has_list() -> bool:
		return list_provider.is_valid()

	func is_mode() -> bool:
		return kind == "mode"


class CategoryDef extends RefCounted:
	var id: String
	var label: String
	var icon: String
	var accent: Color
	var tools: Array[ToolDef] = []


var _categories: Array[CategoryDef] = []
var _tools := {} ## tool id -> ToolDef (ids are unique across the whole registry)


func add_category(id: String, label: String, icon: String, accent: Color) -> CategoryDef:
	if category(id) != null:
		push_error("tablet_registry: duplicate category id '%s'" % id)
		return null
	if _categories.size() >= MAX_CATEGORIES:
		push_error("tablet_registry: the category grid holds %d; '%s' not added" % [MAX_CATEGORIES, id])
		return null
	var def := CategoryDef.new()
	def.id = id
	def.label = label
	def.icon = icon
	def.accent = accent
	_categories.append(def)
	changed.emit()
	return def


func add_tool(category_id: String, id: String, label: String, icon: String, build: Callable, options: Dictionary = {}) -> ToolDef:
	var cat := category(category_id)
	if cat == null:
		push_error("tablet_registry: no category '%s' for tool '%s'" % [category_id, id])
		return null
	if _tools.has(id):
		push_error("tablet_registry: duplicate tool id '%s'" % id)
		return null
	var def := ToolDef.new()
	def.id = id
	def.category_id = category_id
	def.label = label
	def.icon = icon
	def.build = build
	def.kind = str(options.get("kind", "page"))
	def.list_provider = options.get("list", Callable())
	def.on_activate = options.get("on_activate", Callable())
	def.on_deactivate = options.get("on_deactivate", Callable())
	def.help = str(options.get("help", ""))
	def.hint = str(options.get("hint", ""))
	def.status_provider = options.get("status", Callable())
	def.on_select = options.get("on_select", Callable())
	def.list_empty = str(options.get("list_empty", "Nothing here yet."))
	cat.tools.append(def)
	_tools[id] = def
	changed.emit()
	return def


func categories() -> Array[CategoryDef]:
	return _categories


func category(id: String) -> CategoryDef:
	for c in _categories:
		if c.id == id:
			return c
	return null


func tool_def(id: String) -> ToolDef:
	return _tools.get(id)


func category_of(tool_id: String) -> CategoryDef:
	var def := tool_def(tool_id)
	return category(def.category_id) if def else null


func mode_tools() -> Array[ToolDef]:
	var out: Array[ToolDef] = []
	for c in _categories:
		for t in c.tools:
			if t.is_mode():
				out.append(t)
	return out


func category_rows() -> int:
	## Rows of the category grid actually needed: one while there are four or
	## fewer categories (no empty slots drawn), two from the fifth on.
	return maxi(1, ceili(float(_categories.size()) / float(GRID_COLUMNS)))
