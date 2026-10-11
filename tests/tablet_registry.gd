extends SceneTree
## The redesigned tablet's data registry (scripts/ui/tablet_registry.gd): no scene
## tree needed. Covers registration, lookups, the 10-category cap, duplicate
## rejection, mode-tool discovery and how many grid rows the layout needs.
## Run: "$GODOT" --headless --path . --script res://tests/tablet_registry.gd  (see tests/README.md)

func _initialize() -> void:
	var Registry = load("res://scripts/ui/tablet_registry.gd")
	var reg = Registry.new()
	var fired := [0]
	reg.changed.connect(func() -> void: fired[0] += 1)

	print("SMOKE an empty registry still needs one grid row: ", reg.category_rows() == 1)
	var view = reg.add_category("view", "View", "view", Color.CYAN)
	var asm = reg.add_category("assembly", "Assembly", "assembly", Color.ORANGE)
	print("SMOKE categories register in order: ", reg.categories().size() == 2 and reg.categories()[0].id == "view" and reg.categories()[1].id == "assembly")
	print("SMOKE category lookup by id: ", reg.category("assembly") == asm and reg.category("nope") == null)

	var builder := func() -> Control: return Control.new()
	var scale_tool = reg.add_tool("view", "scale", "Scale", "scale", builder)
	var provider := func() -> Array: return [{"id": "m1", "title": "Mate 1"}]
	var mates_tool = reg.add_tool("assembly", "mates", "Mates", "mate", builder,
		{"kind": "mode", "list": provider, "on_activate": func() -> void: pass, "on_deactivate": func() -> void: pass, "help": "Pick two faces."})
	print("SMOKE a tool defaults to kind 'page' with no list: ", scale_tool.kind == "page" and not scale_tool.has_list() and not scale_tool.is_mode())
	print("SMOKE a mode tool keeps its kind, list provider and callbacks: ", mates_tool.is_mode() and mates_tool.has_list() and mates_tool.on_activate.is_valid() and mates_tool.on_deactivate.is_valid() and mates_tool.help == "Pick two faces.")
	print("SMOKE the list provider is callable and returns its rows: ", mates_tool.list_provider.call().size() == 1)
	var rich = reg.add_tool("view", "rich", "Rich", "view", builder, {"hint": "h", "status": func() -> String: return "live", "on_select": func() -> void: fired[0] += 100, "list_empty": "none yet"})
	print("SMOKE hint, status provider, on_select and list_empty options are kept: ", rich.hint == "h" and rich.status_provider.call() == "live" and rich.on_select.is_valid() and rich.list_empty == "none yet" and scale_tool.list_empty == "Nothing here yet.")
	print("SMOKE tools land in their own category, in order: ", view.tools == [scale_tool, rich] and asm.tools == [mates_tool])
	print("SMOKE tool lookup and category_of: ", reg.tool_def("mates") == mates_tool and reg.category_of("mates") == asm and reg.tool_def("zzz") == null and reg.category_of("zzz") == null)
	print("SMOKE mode_tools() lists only the mode tools: ", reg.mode_tools() == [mates_tool])
	print("SMOKE every registration emitted 'changed' (2 categories + 3 tools): ", fired[0] == 5)

	# Rejections are push_error()s — expected output for those lines, not failures.
	print("SMOKE a duplicate category id is refused: ", reg.add_category("view", "Again", "x", Color.RED) == null and reg.categories().size() == 2)
	print("SMOKE a duplicate tool id is refused (even in another category): ", reg.add_tool("view", "mates", "Dup", "x", builder) == null)
	print("SMOKE a tool for an unknown category is refused: ", reg.add_tool("ghost", "t", "T", "x", builder) == null)

	print("SMOKE five categories still need one row: ", _fill(reg, 5) and reg.category_rows() == 1)
	print("SMOKE a sixth category makes a second row: ", _fill(reg, 6) and reg.category_rows() == 2)
	print("SMOKE ten categories fit two rows: ", _fill(reg, 10) and reg.category_rows() == 2 and reg.categories().size() == 10)
	print("SMOKE an eleventh category is refused: ", reg.add_category("c11", "Eleven", "x", Color.WHITE) == null and reg.categories().size() == 10)

	# Home-tile options: a plain category, a hub, and an action tile with a live caption.
	var reg2 = Registry.new()
	var plain = reg2.add_category("p", "Plain", "x", Color.WHITE)
	var hub = reg2.add_category("h", "Hub", "x", Color.WHITE, {"hub": true, "subtitle": "a · b"})
	var live := ["one"]
	var act = reg2.add_category("a", "Act", "x", Color.WHITE, {"action": func() -> void: live[0] = "two", "caption": func() -> String: return live[0]})
	print("SMOKE a category defaults to a plain, non-hub, non-action tile with no subtitle: ", not plain.hub and not plain.is_action() and plain.subtitle == "" and not plain.caption.is_valid())
	print("SMOKE hub and subtitle options are kept: ", hub.hub and hub.subtitle == "a · b" and not hub.is_action())
	act.action.call()
	print("SMOKE an action category keeps its action and live caption: ", act.is_action() and act.caption.call() == "two")
	var cap = reg2.add_tool("h", "t", "T", "x", builder, {"caption": "small line"})
	print("SMOKE a tool keeps its hub-tile caption: ", cap.caption == "small line")
	quit()


func _fill(reg, count: int) -> bool:
	while reg.categories().size() < count:
		reg.add_category("cat%d" % reg.categories().size(), "C", "x", Color.WHITE)
	return true
