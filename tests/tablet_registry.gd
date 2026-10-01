extends SceneTree
## The redesigned tablet's data registry (scripts/ui/tablet_registry.gd): no scene
## tree needed. Covers registration, lookups, the 8-category cap, duplicate
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
	print("SMOKE tools land in their own category, in order: ", view.tools == [scale_tool] and asm.tools == [mates_tool])
	print("SMOKE tool lookup and category_of: ", reg.tool_def("mates") == mates_tool and reg.category_of("mates") == asm and reg.tool_def("zzz") == null and reg.category_of("zzz") == null)
	print("SMOKE mode_tools() lists only the mode tools: ", reg.mode_tools() == [mates_tool])
	print("SMOKE every registration emitted 'changed': ", fired[0] == 4)

	# Rejections are push_error()s — expected output for those lines, not failures.
	print("SMOKE a duplicate category id is refused: ", reg.add_category("view", "Again", "x", Color.RED) == null and reg.categories().size() == 2)
	print("SMOKE a duplicate tool id is refused (even in another category): ", reg.add_tool("view", "mates", "Dup", "x", builder) == null)
	print("SMOKE a tool for an unknown category is refused: ", reg.add_tool("ghost", "t", "T", "x", builder) == null)

	print("SMOKE four categories still need one row: ", _fill(reg, 4) and reg.category_rows() == 1)
	print("SMOKE a fifth category makes a second row: ", _fill(reg, 5) and reg.category_rows() == 2)
	print("SMOKE eight categories fit two rows: ", _fill(reg, 8) and reg.category_rows() == 2 and reg.categories().size() == 8)
	print("SMOKE a ninth category is refused: ", reg.add_category("c9", "Nine", "x", Color.WHITE) == null and reg.categories().size() == 8)
	quit()


func _fill(reg, count: int) -> bool:
	while reg.categories().size() < count:
		reg.add_category("cat%d" % reg.categories().size(), "C", "x", Color.WHITE)
	return true
