extends RefCounted
## "One tool active at a time" for the redesigned tablet. Mode tools (Mates,
## Measure, Sections, Shoot-to-hide: anything registered with kind "mode") change
## what the laser does in the world, so at most one may be on:
##   * activate(id) turns the previous one off first (its on_deactivate runs),
##     then the new one on (its on_activate runs);
##   * viewing another page (Scale, Colours, Files...) never changes it;
##   * closing the tablet does not either — you need the laser in the world, and
##     the badge on the right hand shows what's active.
## Pure logic over a registry (scripts/ui/tablet_registry.gd): no scene tree.

signal active_changed(tool_id: String) ## "" = no mode tool active

var active_id := ""
var _registry


func setup(registry) -> void:
	_registry = registry


func is_active(tool_id: String) -> bool:
	return active_id != "" and active_id == tool_id


func active_def():
	return _registry.tool_def(active_id) if active_id != "" and _registry != null else null


func activate(tool_id: String) -> bool:
	## True if tool_id is now the active mode tool.
	var def = _registry.tool_def(tool_id) if _registry != null else null
	if def == null or not def.is_mode():
		return false
	if active_id == tool_id:
		return true
	_turn_off_current()
	active_id = tool_id
	if def.on_activate.is_valid():
		def.on_activate.call()
	active_changed.emit(active_id)
	return true


func deactivate() -> void:
	if active_id == "":
		return
	_turn_off_current()
	active_id = ""
	active_changed.emit("")


func toggle(tool_id: String) -> bool:
	## Returns whether the tool is active afterwards.
	if is_active(tool_id):
		deactivate()
		return false
	return activate(tool_id)


func _turn_off_current() -> void:
	var def = active_def()
	if def != null and def.on_deactivate.is_valid():
		def.on_deactivate.call()
