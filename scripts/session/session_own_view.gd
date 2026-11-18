extends Node
## An observer's OWN VIEW (P4; plan "Observer tools", decision D7: observers change their own view by default and nothing is saved). The presenter's model is shown as the presenter shows it
## (session_observer.gd); what this person does on top of that is theirs alone: colour a part, hide it, isolate it, make it see-through, cut the model, measure it, pull a part out.
## NOTHING here is sent: not to the hub (an observer sends presence, marks and a raised hand, nothing of the model's state), and not to a backend (an observer has none: main.gd `_apply_backend`).
##   colour, see-through   the Appearance tool in `local_only` mode: the sandbox's temporary layer (records by path, never sent) on a model built from the glb's own paths (appearance_tool.gd
##                         `seed_local_model`); the paint breadcrumb, the swatches and the laser gun work as they do for a presenter in the Relax sandbox.
##   hide, isolate         the part's `visible`, as the Visibility page and the Hide tool already set it. The presenter's hide list is applied as CHANGES (session_observer.gd), so what this
##                         person hid stays hidden until the presenter shows that same part (or Reset my view).
##   section               the section tool, one clip plane, client-side as ever. While this person has their own cut on, the presenter's cut is held back (not applied) until Reset.
##   measure               the Measure tool in `local_only` mode: the straight line between the two spots the laser touched (no backend to ask for a face's identity or an edge's length).
##   pull a part out       the hand's grip, as in the Relax sandbox: the part follows the hand and nothing is saved (an observer's mates tool has no backend, so `persist_pose` has nowhere to
##                         write). A pulled part keeps where this person put it: the presenter's pose for THAT part is not applied (it still arrives and is kept), until Reset.
## Reset my view (`reset_my_view`) puts all of it back to exactly what the presenter shows now.

const Publisher := preload("res://scripts/session/session_publisher.gd")

signal changed() ## the set of own edits changed (the tablet's page refreshes)

var main: Node
var client: Node
var observer: Node
var active := false
var pull_out := false ## the grip takes a part (and, when off, only the cut's handle)
var see_through_opacity := 0.25

var _pulled: Dictionary = {} ## part node -> true (moved by this person's hand)


func start(p_main: Node, p_client: Node, p_observer: Node) -> void:
	main = p_main
	client = p_client
	observer = p_observer
	active = true
	_pulled.clear()
	pull_out = false
	add_to_group("session_listeners") # controller.gd _sync_pose() / the mates glide call on_parts_moving: for an observer that means this person's hand moved a part


func stop() -> void:
	if active:
		remove_from_group("session_listeners")
	active = false
	_pulled.clear()
	pull_out = false


func on_parts_moving(parts: Array) -> void:
	## A grab, a release or a glide: these parts are this person's now (see is_pulled).
	if not active or not pull_out:
		return
	for part in parts:
		if is_instance_valid(part):
			_pulled[part] = true
	changed.emit()


func is_pulled(node: Node) -> bool:
	## Whether the presenter's pose must leave this part alone: this person's hand has it, or put it somewhere.
	return _pulled.has(node) or (is_instance_valid(node) and bool(node.get_meta("held", false)))


func set_pull_out(on: bool) -> void:
	pull_out = on
	changed.emit()


func put_pulled_back() -> int:
	## Every part this person pulled goes back to the presenter's pose for it (the rest of the view stays as it is). Returns how many.
	var parts: Array = []
	for part in _pulled:
		if is_instance_valid(part):
			parts.append(part)
	_pulled.clear()
	observer.restore_poses(parts)
	changed.emit()
	return parts.size()


# --- Appearance ----------------------------------------------------------------------------------------------------------------------

func on_model_indexed() -> void:
	## A model was put in (first load, a refetch, another model): the appearance rules need their stand-in model again, and the paint this person had goes back on the new nodes.
	var appearance: Node = main.session_appearance_tool()
	var parts: Array = main.session_world_parts()
	appearance.seed_local_model(parts, "own")
	appearance.repaint(parts, "own")
	for part in _pulled.keys():
		if not is_instance_valid(part):
			_pulled.erase(part)
	changed.emit()


func paint_selection(brush: Dictionary, selection: Dictionary) -> Dictionary:
	## Paints the cursor's selection (its level's row) with `brush` ({"colour": "#RRGGBB"}, {"opacity": 0.25}, {} clears it). A coroutine. {ok, error}.
	if selection.is_empty():
		return {"ok": false, "error": "Nothing selected: put the cursor on a part."}
	var row: Dictionary = selection["row"]
	if row.get("record") == null:
		return {"ok": false, "error": "That part cannot be coloured by itself here: try the body or the sub-assembly."}
	var appearance: Node = main.session_appearance_tool()
	var previous: Dictionary = appearance.brush
	appearance.brush = brush
	var result: Dictionary = await appearance.apply(row, "own", main.session_world_parts(), "own")
	appearance.brush = previous
	changed.emit()
	return result


func clear_paint() -> void:
	main.session_appearance_tool().clear_local(main.session_world_parts())
	changed.emit()


# --- Hide, isolate -------------------------------------------------------------------------------------------------------------------

func hide_selection(selection: Dictionary) -> int:
	## Hides the selection's parts for this person. Returns how many.
	var n := 0
	for node in selection.get("members", []):
		if is_instance_valid(node) and (node as Node3D).visible:
			(node as Node3D).visible = false
			n += 1
	changed.emit()
	return n


func isolate_selection(selection: Dictionary) -> int:
	## Hides everything but the selection's parts. Returns how many parts are left showing.
	if selection.is_empty():
		return 0
	var keep := {}
	for node in selection["members"]:
		keep[node] = true
	var shown := 0
	for node in main.session_world_parts():
		var show: bool = keep.has(node)
		(node as Node3D).visible = show
		shown += 1 if show else 0
	changed.emit()
	return shown


func show_all() -> void:
	for node in main.session_world_parts():
		(node as Node3D).visible = true
	changed.emit()


# --- Section, measure ----------------------------------------------------------------------------------------------------------------

func own_section_active() -> bool:
	## The section tool is on and it is not just the presenter's cut being shown: this person turned it on.
	var tool: Node = main.session_section_tool()
	return tool.active and not observer.remote_section_on


# --- Reset my view -------------------------------------------------------------------------------------------------------------------

func differs() -> Dictionary:
	## What differs from the presenter's view right now: {moved, hidden, painted, cut, measuring}.
	var moved := 0
	for part in _pulled:
		if is_instance_valid(part):
			moved += 1
	var appearance: Node = main.session_appearance_tool()
	return {"moved": moved, "hidden": observer.own_visibility_changes(), "painted": appearance.temporary_count(), "cut": own_section_active(), "measuring": not main.session_measure_tool().picked_points().is_empty()}


func summary() -> String:
	var d := differs()
	var bits: Array[String] = []
	if int(d["moved"]) > 0:
		bits.append("%d part%s pulled out" % [d["moved"], "" if int(d["moved"]) == 1 else "s"])
	if int(d["hidden"]) > 0:
		bits.append("%d part%s shown or hidden differently" % [d["hidden"], "" if int(d["hidden"]) == 1 else "s"])
	if int(d["painted"]) > 0:
		bits.append("%d colour%s" % [d["painted"], "" if int(d["painted"]) == 1 else "s"])
	if bool(d["cut"]):
		bits.append("your own cut")
	if bool(d["measuring"]):
		bits.append("a measurement")
	return "Your view is the presenter's." if bits.is_empty() else "Your view differs: " + ", ".join(bits) + "."


func reset_my_view() -> void:
	## Puts everything back to exactly what the presenter shows: colours and see-through off, every part shown or hidden as the presenter has it, every part at the presenter's pose for it,
	## the cut theirs (or none), measurements cleared. Nothing is sent: the presenter's state was never touched.
	main.session_appearance_tool().clear_local(main.session_world_parts())
	main.session_measure_tool().clear_picks()
	_pulled.clear()
	observer.reset_to_presenter()
	changed.emit()
	main.say("Your view is back to what the presenter shows.")
