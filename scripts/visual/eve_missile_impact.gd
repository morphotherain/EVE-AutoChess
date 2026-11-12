extends Node3D

## Heavy warhead impact staging over Scourge's original luminous assets.
## The owner supplies age: no separate timer, RNG or damage callback lives here.
const ORIGINAL := preload("res://assets/vfx/combat/scourge/scourge_source.gd")
const SOURCE := ORIGINAL.DATA
const MESH_SHADER := preload("res://scripts/visual/fx_scourge_mesh.gdshader")
const PARTICLE_SHADER := preload("res://scripts/visual/fx_scourge_particle.gdshader")
const REFRACTION_SHADER := preload("res://scripts/visual/fx_scourge_refraction.gdshader")
const VOLUME_SHADER := preload("res://scripts/visual/fx_torpedo_volume.gdshader")
const FIRE_ATLAS := preload("res://assets/vfx/combat/impact_fire.png")
const FIRE_FLOW := preload("res://assets/vfx/combat/impact_fire_flow.png")
const CONE := preload("res://assets/vfx/combat/scourge/cone.obj")
const WAVE := preload("res://assets/vfx/combat/scourge/wave.obj")
const HALO_A := preload("res://assets/vfx/combat/scourge/halo_a.obj")
const HALO_B := preload("res://assets/vfx/combat/scourge/halo_b.obj")
# Let the irregular explosion carry the silhouette; rings stay subordinate.
const DURATION := 1.35
const COMPRESSION_TIME := 0.075
const BODY_SCALE := 1.20
const HALO_SIZE_SCALE := 0.48
const HALO_RADIANCE_SCALE := 0.16
static var _quad: QuadMesh
var lifetime := DURATION
var materials: Array[ShaderMaterial] = []
var _cone: MeshInstance3D
var _halos: Array[MeshInstance3D] = []
var _waves: Array[MeshInstance3D] = []
var _refraction: ShaderMaterial
var _cone_yaw := 0.0
var _wave_yaw := 0.0
var _random_offset := 0.0
var _lobes: Array[Dictionary] = []

static func texture(file: String) -> Texture2D:
	return ORIGINAL.TEXTURES[file]

static func _v4(a: Array) -> Vector4:
	return Vector4(a[0], a[1], a[2], a[3])

func _mesh(mesh: Mesh, id: String, label: String) -> MeshInstance3D:
	var facts: Dictionary = SOURCE.materials[id]
	var mat := ShaderMaterial.new()
	mat.shader = MESH_SHADER
	for i in range(1, 4):
		mat.set_shader_parameter("diffuse_%d" % i, texture(facts.textures["DiffuseMap%d" % i]))
		mat.set_shader_parameter("transform_%d" % i, _v4(facts.params.get("TextureTransform%d" % i, [0, 0, 1, 1])))
		mat.set_shader_parameter("scroll_%d" % i, _v4(facts.params.get("TextureScroll%d" % i, [0, 0, 0, 0])))
	mat.set_shader_parameter("mask_map", texture(facts.textures.MaskMap))
	mat.set_shader_parameter("mask_transform", _v4(facts.params.get("MaskTransform", [0, 0, 1, 1])))
	var color: Array = facts.params.DiffuseColor
	mat.set_shader_parameter("tint", _v4(color))
	materials.append(mat)
	var mi := MeshInstance3D.new()
	mi.name = label
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.custom_aabb = mesh.get_aabb().grow(0.05)
	add_child(mi)
	return mi

func _particles(kind: int, id: String, entries: Array, energy: float, label: String) -> void:
	if _quad == null:
		_quad = QuadMesh.new()
		_quad.size = Vector2.ONE
	var mat := ShaderMaterial.new()
	mat.shader = PARTICLE_SHADER
	mat.set_shader_parameter("kind", float(kind))
	mat.set_shader_parameter("energy", energy)
	if id == "44": mat.set_shader_parameter("grade", Vector3(0.12, 0.65, 1.30))
	elif id == "17": mat.set_shader_parameter("grade", Vector3(0.50, 0.80, 1.10))
	if not id.is_empty():
		var facts: Dictionary = SOURCE.materials[id]
		if kind == 0:
			mat.set_shader_parameter("atlas_grid", float(facts.params.AtlasInfo[0]))
			for pair in [["atlas", "TextureMap"], ["flow_atlas", "GradientMap"],
				["color_ramp", "ColorRampMap"], ["heat_ramp", "SelfIlluminationGradientMap"]]:
				mat.set_shader_parameter(pair[0], texture(facts.textures[pair[1]]))
		elif kind == 1:
			mat.set_shader_parameter("atlas", texture(facts.textures.MaskMap))
			mat.set_shader_parameter("layer_1", texture(facts.textures.TexMapLayer1))
			mat.set_shader_parameter("layer_2", texture(facts.textures.TexMapLayer2))
	materials.append(mat)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _quad
	mm.instance_count = entries.size()
	for i in range(entries.size()):
		var e: Dictionary = entries[i]
		var body_scale := BODY_SCALE if kind <= 1 else 1.0
		# Z is a velocity payload, read directly by the vertex shader. No normal
		# transform or inverse is used for these unlit camera-facing particles.
		mm.set_instance_transform(i, Transform3D(Basis(Vector3(e.size.x * body_scale, 0, 0),
			Vector3(0, e.size.y * body_scale, 0), e.velocity * body_scale), e.origin * body_scale))
		mm.set_instance_custom_data(i, Color(e.delay, e.life, e.rotation, e.energy))
	var instance := MultiMeshInstance3D.new()
	instance.name = label
	instance.multimesh = mm
	instance.material_override = mat
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.custom_aabb = AABB(Vector3(-5, -5, -5), Vector3(10, 10, 10))
	add_child(instance)

func _entry(size: Vector2, velocity: Vector3, delay: float, life: float,
		rng: RandomNumberGenerator, origin := Vector3.ZERO) -> Dictionary:
	return {"size": size, "velocity": velocity, "origin": origin,
		"delay": delay, "life": life, "rotation": rng.randf() * TAU, "energy": rng.randf_range(0.75, 1.1)}

func configure(rng: RandomNumberGenerator) -> void:
	lifetime = DURATION
	_cone_yaw = rng.randf() * TAU
	_wave_yaw = rng.randf() * TAU
	_random_offset = rng.randf_range(1.0, 4.0)
	_cone = _mesh(CONE, "153", "ScourgeCone")
	_halos = [_mesh(HALO_A, "187", "GravitonHaloA"), _mesh(HALO_B, "196", "GravitonHaloB")]
	_waves = [_mesh(WAVE, "169", "ScourgeWaveA"), _mesh(WAVE, "169", "ScourgeWaveB")]
	var warp := MeshInstance3D.new()
	warp.name = "ScourgeHaloRefraction"
	warp.mesh = HALO_B
	warp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_refraction = ShaderMaterial.new()
	_refraction.shader = REFRACTION_SHADER
	_refraction.set_shader_parameter("normal_map", texture(SOURCE.materials["205"].textures.NormalMap1))
	_refraction.set_shader_parameter("mask_map", texture(SOURCE.materials["205"].textures.MaskMap))
	warp.material_override = _refraction
	_halos[1].add_child(warp)
	# The native halo B has animated random texture offsets shared across layers.
	for key in ["transform_1", "transform_2"]:
		_halos[1].material_override.set_shader_parameter(key, Vector4(_random_offset, _random_offset, 3.0, 0.1))
	# A compact contact is readable before the main charge releases. No HP
	# delay, timer, camera freeze or simulated penetration is introduced here.
	var compression: Array = [
		_entry(Vector2(0.52, 0.52), Vector3.ZERO, 0.0, 0.15, rng),
		_entry(Vector2(1.25, 0.035), Vector3.ZERO, 0.005, 0.12, rng)]
	_particles(3, "", compression, 2.4, "HeavyContactCompression")
	var flash: Array = [_entry(Vector2(1.65, 1.65), Vector3(0, 0.8, 0), COMPRESSION_TIME, 0.44, rng)]
	_particles(0, "17", flash, 0.35, "ScourgePrimaryFlash")
	var splash: Array = [_entry(Vector2(2.6, 2.6), Vector3(0, 1.8, 0), COMPRESSION_TIME + 0.015, 0.56, rng)]
	_particles(0, "44", splash, 0.95, "ScourgeSplashCrown")
	var secondary: Array = []
	for i in range(3):
		var radial := Vector3(rng.randf_range(-1, 1), rng.randf_range(0.2, 0.7), rng.randf_range(-1, 1)).normalized()
		secondary.append(_entry(Vector2.ONE * rng.randf_range(1.0, 1.4), radial * 1.5,
			COMPRESSION_TIME + 0.025 + float(i) * 0.018, 0.48, rng, radial * 0.10))
	_particles(0, "249", secondary, 1.0, "ScourgeDirectionalFlashes")
	var volume_quad := QuadMesh.new()
	volume_quad.size = Vector2.ONE
	var hot_lobes := [
		{"offset": Vector3.ZERO, "size": Vector3(1.8, 1.65, 1.8), "delay": COMPRESSION_TIME},
		{"offset": Vector3(-0.32, 0.10, 0.26), "size": Vector3(1.05, 1.10, 1.05), "delay": 0.105},
		{"offset": Vector3(0.20, 0.25, -0.32), "size": Vector3(0.85, 0.90, 0.85), "delay": 0.13}]
	for i in range(hot_lobes.size()):
		var lobe := MeshInstance3D.new()
		lobe.name = "HeavyBlastLobe%d" % i
		lobe.mesh = volume_quad
		lobe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := ShaderMaterial.new()
		mat.shader = VOLUME_SHADER
		mat.set_shader_parameter("atlas", FIRE_ATLAS)
		mat.set_shader_parameter("flow_atlas", FIRE_FLOW)
		mat.set_shader_parameter("seed", rng.randf() * TAU)
		mat.set_shader_parameter("delay", hot_lobes[i].delay)
		lobe.material_override = mat
		materials.append(mat)
		add_child(lobe)
		_lobes.append({"node": lobe, "offset": hot_lobes[i].offset,
			"size": hot_lobes[i].size, "delay": hot_lobes[i].delay})
	var wisps: Array = []
	for i in range(8):
		var radial := Vector3(rng.randf_range(-1, 1), rng.randf_range(0.1, 0.9), rng.randf_range(-1, 1)).normalized()
		wisps.append(_entry(Vector2.ONE * rng.randf_range(0.28, 0.50), radial * rng.randf_range(2.0, 4.0),
			rng.randf_range(0.13, 0.20), rng.randf_range(0.35, 0.60), rng, radial * 0.12))
	_particles(1, "223", wisps, 0.9, "ScourgeCausticWisps")
	var jets: Array = []
	for i in range(15):
		# Local +Y faces the incoming weapon. Ejecta spread across the contact
		# plane and back towards the attacker, rather than through the shield.
		var angle := rng.randf() * TAU
		var radial := Vector3(cos(angle), rng.randf_range(0.15, 0.65), sin(angle)).normalized()
		jets.append(_entry(Vector2(rng.randf_range(0.04, 0.07), rng.randf_range(0.30, 0.65)),
			radial * rng.randf_range(5.0, 10.5), rng.randf_range(0.09, 0.14), rng.randf_range(0.30, 0.65), rng))
	_particles(2, "", jets, 1.6, "ScourgeHeadedJets")
	var flares: Array = [
		_entry(Vector2(1.1, 1.1), Vector3.ZERO, COMPRESSION_TIME, 0.19, rng),
		_entry(Vector2(2.6, 0.055), Vector3.ZERO, COMPRESSION_TIME, 0.12, rng)]
	_particles(3, "", flares, 0.85, "ScourgeContactFlares")
	advance(0.0)

func curve(name: String, t: float) -> float:
	var keys: Array = SOURCE.curves[name]
	if t <= float(keys[0].time):
		return float(keys[0].value)
	for i in range(1, keys.size()):
		var b: Dictionary = keys[i]
		if t <= float(b.time):
			var a: Dictionary = keys[i - 1]
			var span := float(b.time) - float(a.time)
			var u := (t - float(a.time)) / span
			if int(a.interpolation) == 0:
				return float(a.value)
			if int(a.interpolation) == 1:
				return lerpf(float(a.value), float(b.value), u)
			var u2 := u * u
			var u3 := u2 * u
			return (2 * u3 - 3 * u2 + 1) * float(a.value) + (u3 - 2 * u2 + u) * span * float(a.rightTangent) + (-2 * u3 + 3 * u2) * float(b.value) + (u3 - u2) * span * float(b.leftTangent)
	return float(keys[-1].value)

func advance(age: float) -> void:
	var t := maxf(0.0, age - COMPRESSION_TIME) * 6.0 / (lifetime - COMPRESSION_TIME)
	var released := smoothstep(COMPRESSION_TIME, COMPRESSION_TIME + 0.025, age)
	for mat in materials:
		mat.set_shader_parameter("age", age)
		if mat.shader == MESH_SHADER:
			mat.set_shader_parameter("source_time", t)
	for lobe in _lobes:
		var elapsed: float = maxf(0.0, age - float(lobe.delay))
		var expansion := 0.12 + 0.88 * (1.0 - exp(-elapsed * 17.0))
		lobe.node.visible = age >= float(lobe.delay) and elapsed < 0.55
		lobe.node.scale = lobe.size * expansion
		lobe.node.position = lobe.offset * expansion * (1.0 + elapsed * 1.1) + Vector3.UP * (0.18 + minf(elapsed, 0.55) * 1.1)
	var cone_scale := maxf(0.00001, curve("uberBillboardCone_Scale", t)) * 0.55
	_cone.basis = Basis(Vector3.UP, _cone_yaw) * Basis(Vector3.RIGHT, -PI * 0.5)
	_cone.scale = Vector3(1.275, 1.275, 0.1387) * cone_scale * BODY_SCALE
	_cone.material_override.set_shader_parameter("brightness", maxf(0.0, curve("uberBillboardCone_Brightness_and_display", t)) * 0.8 * released)
	_cone.material_override.set_shader_parameter("reveal", curve("uberBillboardCone_Translate", t))
	var halo_scale := maxf(0.00001, curve("HaloWave_Scale", t)) * curve("scaleHaloWaveAgain", t)
	var halo_brightness := sqrt(maxf(0.0, curve("HaloWave_Brightness", t)) / 16.0)
	_refraction.set_shader_parameter("source_time", t)
	_refraction.set_shader_parameter("strength", halo_brightness * HALO_RADIANCE_SCALE * released)
	for i in range(2):
		var halo := _halos[i]
		halo.basis = Basis(Vector3.RIGHT, PI * 0.5)
		halo.scale = Vector3.ONE * 12.6 * halo_scale * HALO_SIZE_SCALE
		halo.material_override.set_shader_parameter("brightness", halo_brightness * 3.0 * HALO_RADIANCE_SCALE * released)
	var wave_scale := maxf(0.00001, curve("wave2_scale", t))
	var travel := curve("wave2_translate", t) * 2.4 * wave_scale * BODY_SCALE
	for i in range(2):
		var sign_value := 1.0 if i == 0 else -1.0
		var orientation := Basis(Vector3.UP, _wave_yaw) * Basis(Vector3.RIGHT, sign_value * 0.124) * Basis(Vector3.RIGHT, -sign_value * PI * 0.5)
		_waves[i].basis = orientation
		_waves[i].scale = Vector3(0.1445, 0.4646, 0.4646) * wave_scale * BODY_SCALE
		_waves[i].position = Basis(Vector3.UP, _wave_yaw) * Vector3(0, 0, sign_value * travel)
		_waves[i].material_override.set_shader_parameter("brightness", sqrt(maxf(0.0, curve("wave2_brightness", t)) / 32.0) * 2.5 * released)
