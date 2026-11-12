extends Node3D
## Local sensor misregistration: original hull returns, moving scan boundaries
## and three incomplete optical lenses. The original EVE source/channel lives
## in the electronic controller and shares this target's suppression state.
const ECHO := preload("res://scripts/visual/fx_suppression_echo.gdshader")
const OPTICS := preload("res://scripts/visual/fx_suppression_optics.gdshader")
const DETAIL := preload("res://assets/vfx/combat/electronic/textures/lightning5x_h_01b.res")
var materials: Array[ShaderMaterial] = []
var _returns: Array[Dictionary] = []
var _lenses: Array[MeshInstance3D] = []
var _seed := 0.0
static var _blades: Dictionary = {}


func configure_receiver(target: Node3D, seed_value: float) -> void:
	_seed = seed_value
	var hull: Node3D = target.get("hull_root")
	if hull != null:
		var models: Array[MeshInstance3D] = []
		for child in hull.get_children():
			if String(child.name).begins_with("Model_"):
				_collect_meshes(child, models)
		if models.is_empty():
			# Missing-model fallback: keep only the original hull mesh, not its
			# shields, engines, brackets or other attached presentation layers.
			var first := _first_mesh(hull)
			if first != null: models.append(first)
		for original in models:
			for layer in range(3):
				var material := ShaderMaterial.new()
				material.shader = ECHO
				material.set_shader_parameter("echo", layer > 0)
				material.set_shader_parameter("seed", _seed + float(layer) * 0.21)
				var original_material := original.get_active_material(0)
				var texture: Texture2D
				if original_material is ShaderMaterial:
					texture = original_material.get_shader_parameter("albedo_tex")
				elif original_material is StandardMaterial3D:
					texture = original_material.albedo_texture
				if texture != null: material.set_shader_parameter("hull_map", texture)
				var copy := MeshInstance3D.new()
				copy.name = "HullReturn_%d" % layer
				copy.mesh = original.mesh
				copy.material_override = material
				copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				add_child(copy)
				materials.append(material)
				_returns.append({"original": weakref(original), "copy": copy,
					"material": material, "layer": layer})
	for i in range(3):
		var lens := _optic(_blade(i), _seed + float(i) * 0.29)
		lens.name = "FocusingSlit_%d" % i
		add_child(lens)
		_lenses.append(lens)


func place_receiver(target: Node3D, source: Node3D, clock: float, gain: float) -> void:
	var center: Vector3 = target.fx_center_world()
	var span: float = maxf(float(target.fx_hull_span()), 0.1)
	var camera := get_viewport().get_camera_3d()
	var camera_basis := camera.global_basis.orthonormalized() if camera != null else Basis.IDENTITY
	var side := camera_basis.x
	var up := camera_basis.y
	var incoming: Vector3 = (source.fx_center_world() - center).normalized()
	var drift := (side * 0.75 + incoming * 0.25).normalized()
	var inverse := global_transform.affine_inverse()
	for entry in _returns:
		var original: MeshInstance3D = entry.original.get_ref()
		if not is_instance_valid(original): continue
		var layer: int = entry.layer
		var phase := fposmod(clock * 0.23 + _seed + float(layer) * 0.47, 1.0)
		var envelope := pow(sin(phase * PI), 1.4)
		var offset := Vector3.ZERO
		if layer > 0:
			var distance := lerpf(0.145, 0.012, smoothstep(0.0, 1.0, phase)) * span * gain
			offset = drift * distance * (1.0 if layer == 1 else -0.68)
			offset += up * distance * (0.28 if layer == 1 else -0.35)
		var copy: MeshInstance3D = entry.copy
		copy.global_transform = Transform3D(original.global_basis, original.global_position + offset)
		var material: ShaderMaterial = entry.material
		material.set_shader_parameter("mesh_to_field", inverse * original.global_transform)
		material.set_shader_parameter("hull_span", span)
		material.set_shader_parameter("return_weight", 0.58 if layer == 0 else envelope * 0.72)
	var radius_x: float = maxf(float(target.fx_transverse_extent(side)), span * 0.20) + span * 0.055 * gain
	var radius_y: float = maxf(float(target.fx_transverse_extent(up)), span * 0.11) + span * 0.055 * gain
	for i in range(_lenses.size()):
		var lens := _lenses[i]
		var bias := 0.98 + sin(clock * 0.74 + _seed * TAU + float(i) * 1.9) * 0.035
		var turn := sin(clock * 0.31 + float(i) * 2.1) * 0.045
		lens.global_transform = Transform3D(camera_basis * Basis(Vector3.BACK, turn) *
			Basis.from_scale(Vector3(radius_x * bias, radius_y * bias, span * 0.14)), center)


func set_state(clock: float, power: float, strength: float, weight: float, compensation: bool) -> void:
	for material in materials:
		material.set_shader_parameter("age", clock)
		material.set_shader_parameter("power", power)
		material.set_shader_parameter("strength", strength)
		material.set_shader_parameter("layer_weight", weight)
		material.set_shader_parameter("screen_compensation", compensation)


func _optic(mesh: Mesh, seed_value: float) -> MeshInstance3D:
	var material := ShaderMaterial.new()
	material.shader = OPTICS
	material.set_shader_parameter("detail_map", DETAIL)
	material.set_shader_parameter("seed", seed_value)
	materials.append(material)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


static func _blade(index: int) -> ArrayMesh:
	if _blades.has(index): return _blades[index]
	var angles: Array = [[0.19, 0.69], [1.12, 1.54], [1.77, 1.96]]
	var vertices := PackedVector3Array()
	var uv := PackedVector2Array()
	var indices := PackedInt32Array()
	for i in range(49):
		var u := float(i) / 48.0
		var angle: float = lerpf(angles[index][0], angles[index][1], u) * PI
		var taper := pow(sin(PI * u), 0.7)
		for j in range(2):
			var radius := 1.0 + (float(j) - 0.5) * 0.13 * taper
			vertices.append(Vector3(cos(angle) * radius, sin(angle) * radius, sin(angle * 1.8) * 0.28))
			uv.append(Vector2(u, j))
		if i < 48:
			var k := i * 2
			indices.append_array(PackedInt32Array([k, k + 1, k + 2, k + 1, k + 3, k + 2]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_blades[index] = mesh
	return mesh


static func _collect_meshes(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and node.mesh != null: result.append(node)
	for child in node.get_children(): _collect_meshes(child, result)


static func _first_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and node.mesh != null: return node
	for child in node.get_children():
		var found := _first_mesh(child)
		if found != null: return found
	return null
