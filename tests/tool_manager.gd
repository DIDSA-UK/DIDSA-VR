extends SceneTree
## One-active-tool rule (scripts/ui/tool_manager.gd) over a registry, no scene tree:
## activating a mode tool turns the previous one off first; page tools can't be
## "activated"; toggling; unknown ids; the signal.
## Run: "$GODOT" --headless --path . --script res://tests/tool_manager.gd  (see tests/README.md)

func _initialize() -> void:
	var reg = load("res://scripts/ui/tablet_registry.gd").new()
	var mgr = load("res://scripts/ui/tool_manager.gd").new()
	var log := []
	var build := func() -> Control: return Control.new()
	reg.add_category("c", "C", "view", Color.WHITE)
	for id in ["a", "b"]:
		reg.add_tool("c", id, id, "view", build, {"kind": "mode",
			"on_activate": func() -> void: log.append("+" + id),
			"on_deactivate": func() -> void: log.append("-" + id)})
	reg.add_tool("c", "page", "page", "view", build)
	mgr.setup(reg)
	var changes := []
	mgr.active_changed.connect(func(id: String) -> void: changes.append(id))

	print("SMOKE nothing is active at the start: ", mgr.active_id == "" and mgr.active_def() == null and not mgr.is_active("a"))
	print("SMOKE activating a mode tool turns it on: ", mgr.activate("a") and mgr.is_active("a") and log == ["+a"])
	print("SMOKE activating it again does nothing more: ", mgr.activate("a") and log == ["+a"] and changes == ["a"])
	log.clear()
	print("SMOKE activating another turns the first OFF first, then the new one on: ", mgr.activate("b") and log == ["-a", "+b"] and mgr.active_id == "b" and not mgr.is_active("a"))
	print("SMOKE only one mode tool is ever active: ", [mgr.is_active("a"), mgr.is_active("b")] == [false, true])
	log.clear()
	print("SMOKE a page tool can't be activated and changes nothing: ", not mgr.activate("page") and mgr.active_id == "b" and log.is_empty())
	print("SMOKE an unknown id can't be activated and changes nothing: ", not mgr.activate("ghost") and mgr.active_id == "b")
	print("SMOKE toggling the active tool turns it off: ", mgr.toggle("b") == false and mgr.active_id == "" and log == ["-b"])
	log.clear()
	print("SMOKE toggling an inactive tool turns it on: ", mgr.toggle("a") == true and mgr.is_active("a") and log == ["+a"])
	log.clear()
	mgr.deactivate()
	mgr.deactivate()
	print("SMOKE deactivate() is idempotent: ", log == ["-a"] and mgr.active_id == "")
	print("SMOKE active_changed fired once per real change (a, b, none, a, none): ", changes == ["a", "b", "", "a", ""])
	quit()
