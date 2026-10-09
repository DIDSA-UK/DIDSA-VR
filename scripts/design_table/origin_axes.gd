extends Node3D
## The part's ORIGIN AND AXES, drawn on the table's copy when the Visibility drawer's "Origin, axes" tile is on: a small ball at the origin and the X, Y and Z
## axes as thin lines (X red, Y green, Z blue, the colours of the flat app). A child of the copy, so its frame is the part's own, in millimetres.

const COLOURS := {"X": Color(1.0, 0.35, 0.35), "Y": Color(0.40, 0.90, 0.50), "Z": Color(0.35, 0.55, 1.0)}
const DIRECTIONS := {"X": Vector3(1, 0, 0), "Y": Vector3(0, 1, 0), "Z": Vector3(0, 0, 1)}
const FaceHighlight := preload("res://scripts/face_highlight.gd")

var length := 100.0 ## mm each axis reaches from the origin


func setup(p_length: float, scale_m_per_mm: float) -> void:
	length = p_length
	var radius := 0.0009 / maxf(scale_m_per_mm, 0.000001) # world metres turned into the part's millimetres
	for axis in DIRECTIONS:
		var mesh := FaceHighlight.tube_mesh(PackedVector3Array([Vector3.ZERO, (DIRECTIONS[axis] as Vector3) * length]), radius)
		if mesh == null:
			continue
		var line := MeshInstance3D.new()
		line.name = "Axis" + axis
		line.mesh = mesh
		line.material_override = _material(COLOURS[axis])
		line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(line)
		var label := Label3D.new()
		label.text = axis
		label.font_size = 40
		label.pixel_size = 0.0004 / maxf(scale_m_per_mm, 0.000001)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.outline_size = 8
		label.modulate = COLOURS[axis]
		label.position = (DIRECTIONS[axis] as Vector3) * length * 1.04
		add_child(label)
	var ball := MeshInstance3D.new()
	ball.name = "Origin"
	var sphere := SphereMesh.new()
	sphere.radius = radius * 2.4
	sphere.height = radius * 4.8
	ball.mesh = sphere
	ball.material_override = _material(Color(0.92, 0.92, 0.95))
	ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ball)


func _material(colour: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = colour
	return m
