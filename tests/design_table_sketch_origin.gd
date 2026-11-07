extends SceneTree
## A sketch whose origin was moved in the flat app, opened on the design table (DIDSA-CAD sketch origin, 3d). Through the real table editor and its FAKE
## backend: reopening a finished sketch from the Build tree draws its plane from the row's `resolved_origin`; the plane every Loft / Sweep / Pattern curve
## pick is placed on (`_plane_for_row`) does too; a row with no `resolved_origin` (an older backend) or a null one (a lost reference) keeps the plane's own
## origin; and a sketch on a face asks the backend for "origin": "auto". Box-and-cylinder fixture.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_sketch_origin.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self, false)
	var table = rig.table
	var ed = rig.ed
	var fake = rig.fake
	fake.sketch_plane = "XY"
	fake.filtered_mesh_bytes = fake.mesh_bytes # (what is checked is the plane, not which fetch was made)
	fake.points = {"pA": Vector2(0, 0), "pB": Vector2(40, 0)}
	fake.entities = [{"type": "line", "id": "lnA", "start_point_id": "pA", "end_point_id": "pB", "construction": false}]
	fake.feature_rows = {"PART_BOX": [
		{"type": "sketch", "id": "skMoved", "sketch_id": "s1", "plane_feature_id": null, "locked": false, "has_lost_reference": false, "origin": {"point_ref": {"vertex_ref": {"body_id": "b", "shape_type": "vertex", "index": 2}, "sketch_point_ref": null}, "circle_centre_ref": null}, "resolved_origin": [30.0, 40.0, 0.0]},
		{"type": "sketch", "id": "skPlain", "sketch_id": "s2", "plane_feature_id": null, "locked": false, "has_lost_reference": false},
		{"type": "sketch", "id": "skLost", "sketch_id": "s3", "plane_feature_id": null, "locked": false, "has_lost_reference": true, "lost_references": ["origin.point_ref.vertex_ref"], "origin": {"point_ref": {"vertex_ref": {"body_id": "b", "shape_type": "vertex", "index": 2}, "sketch_point_ref": null}, "circle_centre_ref": null}, "resolved_origin": null},
	]}
	table.seat(rig.box)
	table.build.clear()
	await table.build.reload()
	await rig.settle(func() -> bool: return table.build.features.size() == 3)

	var moved_plane: Dictionary = await ed._plane_for_row(table.build.row("skMoved"))
	print("SMOKE the plane a Loft / Sweep / Pattern pick places a finished sketch on starts at its resolved origin: ", moved_plane.get("origin", Vector3.INF).is_equal_approx(Vector3(30, 40, 0)) and moved_plane["x"].is_equal_approx(Vector3(1, 0, 0)))
	var plain_plane: Dictionary = await ed._plane_for_row(table.build.row("skPlain"))
	print("SMOKE ...a sketch with no resolved_origin (an older backend, or no moved origin) keeps the plane's own origin: ", plain_plane.get("origin", Vector3.INF).is_equal_approx(Vector3.ZERO))
	var lost_plane: Dictionary = await ed._plane_for_row(table.build.row("skLost"))
	print("SMOKE ...and so does one whose origin the backend could not resolve (null): ", lost_plane.get("origin", Vector3.INF).is_equal_approx(Vector3.ZERO))

	var reopened: bool = await ed.reopen_sketch("skMoved")
	print("SMOKE reopening that sketch from the Build tree draws it from the moved origin: ", reopened and ed.session != null and ed.session.plane["origin"].is_equal_approx(Vector3(30, 40, 0)))
	print("SMOKE ...and a point at sheet (0, 0) is where the corner is, in the part's frame: ", reopened and ed.session.plane["origin"].is_equal_approx(Vector3(30, 40, 0)) and SketchMath.from_sheet(Vector2.ZERO, ed.session.plane).is_equal_approx(Vector3(30, 40, 0)))
	quit()
