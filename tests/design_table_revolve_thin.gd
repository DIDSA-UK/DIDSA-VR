extends SceneTree
## Thin Revolve in the design table (DIDSA-CAD docs/flutter-testing-feedback-2026-11-11-plan.md item 5, V3): the revolve tool gets the options the
## extrude tool has (Thin wall, Wall N mm, and the three directions; options rev_thin / rev_wall / rev_dir). The request sends `thickness` and
## `thickness_direction` only when thin and refuses a wall of 0; a sketch with no closed shape but ONE open line chain can be revolved (the open-chain
## gate), with Thin locked on and the directions read against the axis ("Away from axis / Toward axis / Both sides"); a Build row shows "thin N mm".
## The tool is checked against a stub editor (like design_table_feature_tools.gd) and then the real editor on the fake backend for the gate.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_revolve_thin.gd  (see tests/README.md)

const FeatureTools := preload("res://scripts/design_table/features/feature_tools.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")
const SelectionActions := preload("res://scripts/design_table/selection_actions.gd")
const Rig := preload("res://tests/helpers/table_rig.gd")

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


class FakeSession extends RefCounted:
	var feature_id := "S1"
	var sketch_id := "SK1"
	var closed := true
	var open_chain := false
	func profile_ok() -> bool: return closed
	func open_chain_ok() -> bool: return not closed and open_chain


class FakeTable extends RefCounted:
	var status := ""
	func set_status(text: String) -> void: status = text


class Ed extends RefCounted:
	const BuildTree := preload("res://scripts/design_table/build_tree.gd")
	var options := {"boss": true, "angle": 360.0, "rev_thin": false, "rev_wall": 2.0, "rev_dir": "outward"}
	var session: RefCounted = FakeSession.new()
	var table := FakeTable.new()
	var revolve_axis := ""
	var seed_sketch := ""
	var typed: Array = []
	func seed_sketch_id() -> String: return session.feature_id
	func seed_axis_sketch_id() -> String: return session.sketch_id
	func seed_ready() -> bool: return session.profile_ok()
	func seed_open_chain() -> bool: return session.open_chain_ok()
	func extrude_targets() -> Array: return []
	func targets_option() -> Dictionary: return {"id": "targets", "text": "Targets: none", "toggle": true, "pressed": false}
	func type_option(key: String, title: String) -> void: typed.append([key, title])
	func start_sketch_pick() -> void: pass
	func set_state(_s: String) -> void: pass
	var state := "sketch"


func _ids(list: Array) -> Array:
	return list.map(func(o): return o["id"])


func _opt(list: Array, id: String) -> Dictionary:
	for o in list:
		if o["id"] == id:
			return o
	return {}


func _initialize() -> void:
	var tool = FeatureTools.make_all()["revolve"]
	var ed := Ed.new()
	ed.revolve_axis = "L1"

	# Options: a solid revolve shows Thin wall off and nothing else of it.
	var list: Array = tool.options(ed)
	_check(not _opt(list, "rev_thin").is_empty() and not _opt(list, "rev_thin")["pressed"] and _opt(list, "rev_wall").is_empty(), "a solid revolve lists Thin wall, off, with no wall or direction buttons")
	_check(_ids(list).back() == "apply", "Apply stays the last button")
	var req: Dictionary = tool.request(ed)
	_check(req["ok"] and not req["body"].has("thickness") and not req["body"].has("thickness_direction"), "a solid revolve sends no thickness")

	# Thin on: the wall and the three directions appear, the request carries them.
	_check(tool.handle_option(ed, "rev_thin") and ed.options["rev_thin"], "Thin wall toggles on")
	list = tool.options(ed)
	_check(_opt(list, "rev_wall").get("text") == "Wall 2.00 mm" and _ids(list).has("rev_dir_outward") and _ids(list).has("rev_dir_inward") and _ids(list).has("rev_dir_symmetric"), "...and shows Wall 2.00 mm and the three directions (%s)" % str(_ids(list)))
	_check(_opt(list, "rev_dir_outward")["pressed"] and not _opt(list, "rev_dir_inward")["pressed"], "...Out is the default")
	_check(_opt(list, "rev_dir_outward")["text"] == "Out" and _opt(list, "rev_dir_symmetric")["text"] == "Mid", "...labelled as the extrude tool labels them")
	tool.handle_option(ed, "rev_dir_symmetric")
	ed.options["rev_wall"] = 3.5
	req = tool.request(ed)
	_check(req["ok"] and req["body"]["thickness"] == 3.5 and req["body"]["thickness_direction"] == "symmetric" and req["body"]["angle"] == 360.0, "the request has thickness 3.5 and direction symmetric (%s)" % str(req["body"]))
	tool.handle_option(ed, "rev_wall")
	_check(ed.typed == [["rev_wall", "Wall thickness (mm)"]], "Wall opens the number keyboard")
	ed.options["rev_wall"] = 0.0
	req = tool.request(ed)
	_check(not req["ok"] and str(req["error"]).contains("bigger than zero"), "a wall of 0 is refused with the usual message")
	ed.options["rev_wall"] = 2.0
	tool.handle_option(ed, "rev_thin")
	_check(not tool.request(ed)["body"].has("thickness"), "Thin off again sends no thickness")

	# Open profile: no closed shape, one open chain.
	ed.options["rev_thin"] = false
	ed.options["rev_dir"] = "outward"
	var s: FakeSession = ed.session
	s.closed = false
	s.open_chain = true
	list = tool.options(ed)
	_check(_opt(list, "rev_thin")["pressed"] and _opt(list, "rev_thin")["disabled"], "an open profile: Thin is on and locked")
	_check(_opt(list, "rev_dir_outward")["text"] == "Away from axis" and _opt(list, "rev_dir_inward")["text"] == "Toward axis" and _opt(list, "rev_dir_symmetric")["text"] == "Both sides", "...the directions read against the axis")
	_check(not _opt(list, "apply")["disabled"], "...Apply is on (an axis is set)")
	req = tool.request(ed)
	_check(req["ok"] and req["body"]["thickness"] == 2.0 and req["body"]["thickness_direction"] == "outward", "...the request is thin without anyone turning it on (%s)" % str(req["body"]))
	s.open_chain = false
	_check(not tool.request(ed)["ok"] and _opt(tool.options(ed), "apply")["disabled"], "no closed shape and no single open chain: refused, Apply off")
	_check(not tool.can_apply(ed), "...can_apply is false")
	tool.on_activated(ed)
	_check(ed.table.status.contains("one open line chain for a thin wall"), "the status says what the sketch needs (%s)" % ed.table.status)

	# The part_features request: a wall of 0 or less is refused there too, an unset one is not sent.
	var direct: Dictionary = PartFeatures.revolve_request("S", "K", "L", 360.0, true, [], {"thickness": 0.0})
	_check(not direct["ok"], "revolve_request refuses a wall of 0")
	direct = PartFeatures.revolve_request("S", "K", "L", 90.0, false, ["B1"], {"thickness": 1.5, "thickness_direction": "inward"})
	_check(direct["ok"] and direct["body"]["thickness"] == 1.5 and direct["body"]["mode"] == "cut" and direct["body"]["target_body_ids"] == ["B1"], "revolve_request passes the wall through")

	# The Build row and the selection action.
	var row_text := BuildTree.summary([{"type": "revolve", "mode": "boss", "angle": 360.0, "thickness": 2.0}, {"type": "revolve", "mode": "cut", "angle": 90.0}], 0)
	_check(row_text == "Boss 360 deg, thin 2 mm" and BuildTree.summary([{"type": "revolve", "mode": "cut", "angle": 90.0}], 0) == "Cut 90 deg", "the Build row reads 'thin 2 mm' for a thin revolve only (%s)" % row_text)
	var actions: Array = SelectionActions._sketch_actions({"closed": false, "open_chain": true})
	var rev: Dictionary = {}
	for a in actions:
		if a["id"] == "revolve":
			rev = a
	_check(not rev.is_empty() and bool(rev["enabled"]), "a sketch with only an open chain can be sent to Revolve from the selection actions")
	var none: Array = SelectionActions._sketch_actions({"closed": false, "open_chain": false})
	_check(none.any(func(a) -> bool: return a["id"] == "revolve" and not bool(a["enabled"])), "...and one with nothing closed or open-chain cannot")

	# The real editor: a sketch with one open chain opens the revolve tool and applies.
	var rig = Rig.new()
	await rig.boot(self)
	var real = rig.ed
	rig.fake.profile_open_chain = true
	var top: Dictionary = rig.top_face()
	await real.begin_sketch({"face": {"body_id": top["body_id"], "index": top["index"]}})
	var c: Vector2 = real.view.sheet_centre
	rig.table.manager.activate("line")
	await real.session.tap({"uv": c + Vector2(-30, 0), "id": ""})
	await real.session.tap({"uv": c + Vector2(10, 0), "id": ""})
	await real.session.tap({"uv": c + Vector2(10, 20), "id": ""})
	real.session.finish_chain()
	rig.table.manager.deactivate()
	await rig.frames(4)
	_check(not real.session.profile_ok() and real.session.open_chain_ok() and real.seed_open_chain(), "the real editor: the sketch has no closed shape but one open chain (the backend's open_chain)")
	rig.table.manager.activate("revolve")
	await rig.frames(4)
	_check(not rig.table.status().contains("needs a closed shape to revolve"), "activating Revolve on it does not say the sketch is unusable (%s)" % rig.table.status())
	var line_id := ""
	for id in real.session.lines:
		line_id = str(id)
	real.revolve_axis = line_id
	var real_req: Dictionary = real.tools["revolve"].request(real)
	_check(real_req["ok"] and real_req["body"].has("thickness") and real_req["route"] == "revolve-features", "...and its request is a thin revolve (%s)" % str(real_req.get("body", real_req)))

	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
