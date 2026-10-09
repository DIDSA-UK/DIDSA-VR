extends SceneTree
## CREATE PLANE (Phase 6.1), fake backend: the tool asks for a face or a plane to offset from (a pull picks it), the options are the offset and Reverse,
## Make plane sends offset_face with the right ref and a signed offset, the made plane is drawn beside the three reference planes and can be pulled on to
## sketch on it (the sketch is made on that plane feature), a plane a sketch-on-a-face made lying on its face is not offered, redo makes it again.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_create_plane.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	ed.preview_enabled = false
	table.manager.activate("create_plane")
	await rig.frames(3)
	print("SMOKE choosing Plane goes to plane picking and says what to do: ", ed.state == "pick_plane" and table.status().contains("offset"))
	print("SMOKE ...the panel lists From, Offset, Reverse and a greyed Make plane: ", table.props.option_ids() == ["plane_base", "plane_offset", "plane_flip", "apply"] and table.props.option_button("apply").disabled)
	ed._hover_plane = "XY"
	await ed._pick_plane()
	print("SMOKE a pull on a reference plane makes it the base and turns Make plane on: ", ed.plane_base == {"fixed": "XY"} and not table.props.option_button("apply").disabled and table.props.option_button("plane_base").text.contains("XY"))
	ed.option_typed("plane_offset", "15")
	await ed.on_option("plane_flip")
	await ed.apply_feature()
	var made: Array = rig.calls_to("POST /document/parts/PART_BOX/create-plane-features")
	print("SMOKE Make plane sends offset_face from the XY plane with the signed offset (-15): ", made.size() == 1 and made[0][1] == {"plane_type": "offset_face", "face_refs": [{"fixed_plane": "XY"}], "offset": -15.0}, " ", made)
	print("SMOKE ...it is on Undo's stack, redo-able, and the Build tree was read again: ", ed.feature_stack.size() == 1 and ed.created_requests.has(ed.feature_stack[0]) and not rig.calls_to("/features").is_empty())
	# a plane row the Build tree has, drawn beside the fixed ones
	var plane_id: String = ed.feature_stack[0]
	fake.feature_rows["PART_BOX"] = [
		{"id": plane_id, "type": "create_plane", "plane_type": "offset_face", "offset": -15.0, "origin": [0, 0, -15], "normal": [0, 0, 1], "x_axis": [1, 0, 0], "y_axis": [0, 1, 0]},
		{"id": "p_face", "type": "create_plane", "plane_type": "offset_face", "offset": 0.0, "origin": [0, 0, 20], "normal": [0, 0, 1], "x_axis": [1, 0, 0], "y_axis": [0, 1, 0]}]
	await table.build.reload()
	ed.sync_plane_markers()
	print("SMOKE the made plane is drawn with the reference planes, the sketch-on-a-face one (offset 0) is not: ", ed.markers.has_plane("plane:" + plane_id) and not ed.markers.has_plane("plane:p_face"))
	var hit: Dictionary = ed.markers.intersect(Vector3(5, 5, -100), Vector3(0, 0, 1))
	print("SMOKE ...a ray meets it by name: ", ed.markers._plane_names().has("plane:" + plane_id) and hit.has("plane"))
	# offset again from the made plane
	ed._hover_plane = "plane:" + plane_id
	await ed._pick_plane()
	print("SMOKE a made plane can be the base of another: ", ed.plane_base.get("plane_feature_id", "") == plane_id)
	ed.option_typed("plane_offset", "5")
	await ed.on_option("plane_flip")
	await ed.apply_feature()
	var second: Array = rig.calls_to("POST /document/parts/PART_BOX/create-plane-features")
	print("SMOKE ...Make plane sends it by plane_feature_id: ", second.size() == 2 and second[1][1]["face_refs"] == [{"plane_feature_id": plane_id}] and second[1][1]["offset"] == 5.0)
	# sketch on the made plane
	table.manager.deactivate()
	await rig.frames(2)
	ed.set_state("pick_plane")
	ed._hover_plane = "plane:" + plane_id
	fake.sketch_plane = null
	await ed._pick_plane()
	var sketched: bool = await rig.settle(func() -> bool: return ed.state == "sketch")
	var sketch_call: Array = rig.calls_to("/features/sketch")[0] if not rig.calls_to("/features/sketch").is_empty() else []
	print("SMOKE with no plane tool a pull on it opens a sketch ON that plane feature: ", sketched and not sketch_call.is_empty() and sketch_call[1] == {"plane_feature_id": plane_id}, " ", sketch_call)
	print("SMOKE ...and it is the chosen plane: ", ed.chosen_plane == "plane:" + plane_id)
	quit()
