extends Node3D

## Four rebuilt weapon families with shared shield/hull contact feedback.
## Electronic warfare uses persistent state-driven fields alongside weapon FX.
const Profiles := preload("res://scripts/visual/eve_weapon_fx_profiles.gd")
const WEAPON_AUDIO := preload("res://scripts/core/eve_weapon_audio.gd")
const BAND := preload("res://scripts/visual/fx_combat_band.gdshader")
const BURST := preload("res://scripts/visual/fx_combat_burst.gdshader")
const AURA := preload("res://scripts/visual/fx_combat_aura.gdshader")
const EXHAUST := preload("res://scripts/visual/fx_missile_exhaust.gdshader")
const MISSILE_IMPACT := preload("res://scripts/visual/eve_missile_impact.gd")
const DRONE_SQUADRON := preload("res://scripts/visual/eve_drone_squadron.gd")
const DRONE_CONTACT := preload("res://scripts/visual/fx_drone_contact.gdshader")
const ELECTRONIC := preload("res://scripts/visual/eve_electronic_fx.gd")
const EXHAUST_NOISE := preload("res://assets/vfx/combat/scourge/caustic_05c.png")
const TRAIL := preload("res://scripts/visual/fx_missile_trail.gdshader")
const LASER_BODY := preload("res://scripts/visual/fx_laser_body.gdshader")
const LASER_WAKE := preload("res://scripts/visual/fx_laser_wake.gdshader")
const EVE_IMPACT := preload("res://scripts/visual/fx_eve_impact.gdshader")
const KINETIC_ROUND := preload("res://scripts/visual/fx_kinetic_round.gdshader")
const HYBRID_WAKE := preload("res://scripts/visual/fx_hybrid_wake.gdshader")
const DEBRIS := preload("res://scripts/visual/fx_debris.gdshader")
const IMPACT_FIRE := preload("res://assets/vfx/combat/impact_fire.png")
const IMPACT_FIRE_FLOW := preload("res://assets/vfx/combat/impact_fire_flow.png")
const IMPACT_SPLASH := preload("res://assets/vfx/combat/impact_splash.png")
const IMPACT_SPLASH_FLOW := preload("res://assets/vfx/combat/impact_splash_flow.png")
const IMPACT_ELECTRIC := preload("res://assets/vfx/combat/impact_electric.png")
const IMPACT_ORANGE_RAMP := preload("res://assets/vfx/combat/impact_orange_ramp.png")
const IMPACT_HEAT_RAMP := preload("res://assets/vfx/combat/impact_heat_ramp.png")
const BEAM_MAP := preload("res://assets/vfx/combat/beam_profile.png")
const ELECTRIC_MAP := preload("res://assets/vfx/combat/electric_mask.png")
const PULSE_MAP := preload("res://assets/vfx/combat/pulse_stream.png")
const METERS_PER_UNIT := 1000.0
const MAX_FX := 140
const SCREEN_MAX_SCALE := 12.0
const SCREEN_MIN_PIXELS := {
	BAND: 18.0, AURA: 48.0, BURST: 28.0,
	KINETIC_ROUND: 10.0, LASER_BODY: 32.0, LASER_WAKE: 18.0, HYBRID_WAKE: 24.0, EVE_IMPACT: 32.0,
}
const FX_ENABLED_DEFAULT := true
const MISSILE_BURST_INTERVAL := 0.18
const MISSILE_COAST_TIME := EveCombatCore.MISSILE_COAST_TIME
const MISSILE_GLOW_RISE_TIME := 0.68
# Match the launch transient to the visibly lit jet, after the silent cold coast.
const MISSILE_AUDIO_IGNITION_POWER := 0.20
const MISSILE_AUDIO_IGNITION_BRIGHTNESS := 0.18
# Shared damage-feed semantics, independent of the new weapon art direction.
const QUALITY_COLORS: Array[Color] = [
	Color(0.44, 0.52, 0.56), Color(0.62, 0.70, 0.72), Color(0.70, 0.82, 0.86),
	Color(0.55, 0.78, 0.82), Color(0.35, 0.70, 0.90),
	Color(0.85, 0.68, 0.28), Color(0.95, 0.45, 0.30),
]
static var shield_decal_mid_color := Color(0.05, 0.30, 1.0)
static var shield_decal_high_color := Color(0.32, 0.70, 1.0)
var fx_enabled := true
var screen_compensation := true
var paused := false
var playback_rate := 1.0
var _clock := 0.0
var _serial := 0
var _fx: Array[Dictionary] = []
var _flights: Dictionary = {}
var _cannon_salvos: Array[Dictionary] = []
var _ribbon_mesh: PlaneMesh
var _quad_mesh: QuadMesh
var stats := {"laser": 0, "hybrid": 0, "proj": 0, "missile": 0, "suppression": 0, "jam": 0, "destruction": 0, "drone": 0}
var laser_tint := Color(1.0, 0.80, 0.38)
var electronic: Node3D
var _electronic_visuals: Array[WeakRef] = []
var _electronic_relations := {}
var _suppression_link_style := 0
var weapon_audio: Node

func _ensure_weapon_audio() -> void:
	if weapon_audio != null: return
	weapon_audio = WEAPON_AUDIO.new()
	weapon_audio.name = "WeaponAudio"
	add_child(weapon_audio)


func sync_weapon_audio(ships: Array[EveShip], active: bool) -> void:
	_ensure_weapon_audio()
	weapon_audio.sync_charges(ships, active and fx_enabled)


func _ensure_electronic() -> void:
	if electronic != null: return
	electronic = ELECTRONIC.new()
	electronic.name = "ElectronicFields"
	add_child(electronic)
	electronic.set_screen_compensation(screen_compensation)
	electronic.set_suppression_link_style(_suppression_link_style)


func set_suppression_link_style(style: int) -> void:
	_suppression_link_style = clampi(style, 0, 1)
	if electronic != null:
		electronic.set_suppression_link_style(_suppression_link_style)


func sync_electronic_state(snapshot: Dictionary, visuals: Dictionary) -> void:
	if not fx_enabled: return
	_ensure_electronic()
	electronic.sync_state(snapshot, visuals)
	var suppressed := {}
	var jammed := {}
	var active := {}
	for relation in snapshot.get("relations", []):
		var key := "%d:%d" % [relation.source_id, relation.target_id]
		active[key] = true
		if not _electronic_relations.has(key): stats.suppression += 1
		suppressed[relation.target_id] = maxf(float(suppressed.get(relation.target_id, 0.0)), float(relation.strength))
	for state in snapshot.get("jams", []): jammed[state.target_id] = state.remaining
	_electronic_relations = active
	_electronic_visuals.clear()
	for id in visuals:
		var visual: Node3D = visuals[id]
		if not is_instance_valid(visual): continue
		visual.set_electronic_status(float(suppressed.get(id, 0.0)), float(jammed.get(id, 0.0)))
		_electronic_visuals.append(weakref(visual))


func electronic_attempt(event: Dictionary, visuals: Dictionary) -> void:
	if not fx_enabled: return
	_ensure_electronic()
	electronic.attempt(event, visuals)
	if bool(event.success): stats.jam += 1

func _mesh_setup() -> void:
	if _quad_mesh == null:
		_quad_mesh = QuadMesh.new()
		_quad_mesh.size = Vector2.ONE
		_ribbon_mesh = PlaneMesh.new()
		_ribbon_mesh.orientation = PlaneMesh.FACE_Z
		_ribbon_mesh.size = Vector2.ONE
		_ribbon_mesh.subdivide_depth = 32

func set_timing(is_paused: bool, rate: float = 1.0) -> void:
	paused = is_paused
	playback_rate = maxf(0.0, rate)

func set_screen_compensation(enabled: bool) -> void:
	screen_compensation = enabled
	if electronic != null: electronic.set_screen_compensation(enabled)
	for group in _fx:
		for mat in group.materials:
			if SCREEN_MIN_PIXELS.has(mat.shader) or mat.shader == TRAIL:
				mat.set_shader_parameter("screen_compensation", enabled)
	for flight in _flights.values():
		for round in flight.rounds:
			if is_instance_valid(round.trail):
				round.trail.material_override.set_shader_parameter("screen_compensation", enabled)


func _screen_geometry_scale(at: Vector3, world_size: float, minimum_pixels: float) -> float:
	if not screen_compensation:
		return 1.0
	var camera := get_viewport().get_camera_3d()
	if camera == null or camera.is_position_behind(at):
		return 1.0
	var a := camera.unproject_position(at)
	var right := camera.global_basis.x.normalized()
	var b := camera.unproject_position(at + right * world_size)
	var pixels_per_world := a.distance_to(camera.unproject_position(at + right))
	var far_weight := smoothstep(1.0 / 36.0, 1.0 / 18.0, 1.0 / maxf(pixels_per_world, 0.001))
	return lerpf(1.0, clampf(minimum_pixels / maxf(a.distance_to(b), 0.001), 1.0, 6.0), far_weight)


func active_count() -> int:
	return _fx.size() + _flights.size() + (electronic.active_count() if electronic != null else 0)

func _group(life: float, label: String) -> Dictionary:
	_mesh_setup()
	while _fx.size() >= MAX_FX:
		var old: Dictionary = _fx.pop_front()
		if is_instance_valid(old.node):
			old.node.queue_free()
	var node := Node3D.new()
	node.name = label
	add_child(node)
	var result := {"node": node, "t": 0.0, "life": life, "materials": [],
		"moving": [], "fresh": true, "paths": [], "markers": []}
	_fx.append(result)
	return result

func _material(shader: Shader, group: Dictionary, life: float, delay: float = 0.0) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("age", 0.0)
	mat.set_shader_parameter("lifetime", life)
	mat.set_shader_parameter("delay", delay)
	if SCREEN_MIN_PIXELS.has(shader):
		mat.set_shader_parameter("screen_compensation", screen_compensation)
		mat.set_shader_parameter("screen_min_px", SCREEN_MIN_PIXELS[shader])
	group.materials.append(mat)
	return mat

func _band(group: Dictionary, a: Vector3, b: Vector3, style: int,
		width: float, tint: Color, life: float, energy: float = 2.0,
		curve: Vector2 = Vector2.ZERO, delay: float = 0.0, phase: float = 0.0) -> ShaderMaterial:
	var mat := _material(BAND, group, life, delay)
	mat.set_shader_parameter("point_a", a)
	mat.set_shader_parameter("point_b", b)
	mat.set_shader_parameter("width", width)
	mat.set_shader_parameter("screen_min_px", clampf(width * 48.0, 8.0, 32.0))
	mat.set_shader_parameter("style", style)
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("energy", energy)
	mat.set_shader_parameter("seed", phase)
	mat.set_shader_parameter("bend", curve)
	mat.set_shader_parameter("beam_map", BEAM_MAP)
	mat.set_shader_parameter("electric_map", ELECTRIC_MAP)
	mat.set_shader_parameter("pulse_map", PULSE_MAP)
	mat.set_shader_parameter("pattern_reference",group.get("pattern_reference",0.0))
	var mi := MeshInstance3D.new()
	mi.mesh = _ribbon_mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Shader builds world-space path outside the unit source mesh bounds.
	var box := AABB(a.min(b), a.max(b) - a.min(b))
	box = box.grow(maxf(width * SCREEN_MAX_SCALE, curve.length()) + 2.0)
	mi.custom_aabb = box
	group.node.add_child(mi)
	_bind_path(group, mi, mat)
	return mat

func _aura(group: Dictionary, a: Vector3, b: Vector3, width: float, tint: Color,
		life: float, energy: float, style: int = 0, curve := Vector2.ZERO,
		delay: float = 0.0, phase: float = 0.0) -> ShaderMaterial:
	var mat := _material(AURA, group, life, delay)
	for pair in [["point_a", a], ["point_b", b], ["width", width], ["tint", tint],
			["energy", energy], ["style", style], ["bend", curve], ["seed", phase]]:
		mat.set_shader_parameter(pair[0], pair[1])
	mat.set_shader_parameter("screen_min_px", clampf(width * 12.0, 28.0, 96.0))
	mat.set_shader_parameter("pattern_reference",group.get("pattern_reference",0.0))
	var mi := MeshInstance3D.new()
	mi.mesh = _ribbon_mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.custom_aabb = AABB(a.min(b), a.max(b) - a.min(b)).grow(width * SCREEN_MAX_SCALE * 1.4 + curve.length())
	group.node.add_child(mi)
	_bind_path(group, mi, mat)
	return mat


func _bind_path(group: Dictionary, node: MeshInstance3D, mat: ShaderMaterial,
		follow: bool = true, freeze_after: float = -1.0) -> void:
	if not bool(group.get("path_stage", false)):
		return
	var basis := _basis_for((group.b - group.a).normalized())
	var a: Vector3 = mat.get_shader_parameter("point_a")
	var b: Vector3 = mat.get_shader_parameter("point_b")
	group.paths.append({"node": node, "material": mat,
		"offset_a": basis.transposed() * (a - group.a),
		"offset_b": basis.transposed() * (b - group.b),
		"padding": float(mat.get_shader_parameter("width")) * SCREEN_MAX_SCALE * 1.5 + 2.0,
		"follow": follow, "freeze_after": freeze_after, "frozen": false})


func _bind_marker(group: Dictionary, node: MeshInstance3D, fraction: float) -> void:
	if not group.has("anchors"):
		return
	var basis := _basis_for((group.b - group.a).normalized())
	var mat := node.material_override as ShaderMaterial
	var firing: Vector3 = mat.get_shader_parameter("firing_axis")
	group.markers.append({"node": node, "fraction": fraction,
		"offset": basis.transposed() * (node.position - group.a.lerp(group.b, fraction)),
		"oriented": not bool(mat.get_shader_parameter("billboard")),
		"firing": firing.length_squared() > 0.01})
	if not group.hit and group.weapon==&"hybrid" and fraction>0.0:
		group.markers[-1]["graze_fraction"] = fraction / group.miss_fraction


func sync_attachments() -> void:
	for group in _fx:
		if not is_instance_valid(group.node) or not group.has("anchors") or group.anchors.is_empty():
			continue
		var source = group.anchors.get("source_visual")
		var target = group.anchors.get("target_visual")
		var a: Vector3 = group.a
		var b: Vector3 = group.b
		var aim: Vector3 = target.fx_center_world() if is_instance_valid(target) and target.visible else b
		if is_instance_valid(source) and source.visible:
			if group.anchors.has("source_mount_index"):
				a = source.fx_cannon_mount_world(aim, int(group.anchors.source_mount_index))
			else:
				a = source.fx_mount_world(aim)
			if group.anchors.has("source_focus_clearance"):
				var axis: Vector3=(aim-source.fx_center_world()).normalized()
				a=source.fx_center_world()+axis*(source.fx_transverse_extent(axis)+float(group.anchors.source_focus_clearance))
		if is_instance_valid(target) and target.visible:
			if not group.hit:
				b = _miss_endpoint(group,a,target)
			else:
				b = target.fx_contact_world(a,group.shield,Vector2.ZERO,group.get("shield_slot",-1))
		if a.distance_squared_to(b) < 0.000001:
			continue
		group.a = a
		group.b = b
		var direction := (b - a).normalized()
		var basis := _basis_for(direction)
		for path in group.paths:
			if path.frozen:
				continue
			var pa: Vector3 = a + basis * path.offset_a
			var pb: Vector3 = b + basis * path.offset_b
			path.material.set_shader_parameter("point_a", pa)
			path.material.set_shader_parameter("point_b", pb)
			if not group.hit and group.weapon==&"laser":
				path.material.set_shader_parameter("miss_fraction",group.miss_fraction)
			path.node.custom_aabb = AABB(pa.min(pb), pa.max(pb) - pa.min(pb)).grow(path.padding)
			# A laser wake captures the final powered path once. Later ship motion
			# cannot drag the spent light through space or reopen its source.
			path.frozen = not path.follow or (path.freeze_after >= 0.0 and group.t >= path.freeze_after)
		for marker in group.markers:
			var fraction: float = marker.graze_fraction*group.miss_fraction if marker.has("graze_fraction") else marker.fraction
			marker.node.position = a.lerp(b, fraction) + basis * marker.offset
			if marker.oriented:
				marker.node.quaternion = Quaternion(Vector3.BACK, direction)
			if marker.firing:
				marker.node.material_override.set_shader_parameter("firing_axis", direction)


func _polyline_mesh(points: PackedVector3Array) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var tangents := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var distance := 0.0
	var distances: Array[float] = [0.0]
	for i in range(1, points.size()):
		distance += points[i].distance_to(points[i - 1])
		distances.append(distance)
	for i in range(points.size()):
		var prev := maxi(0, i - 1)
		var next := mini(points.size() - 1, i + 1)
		var tangent := (points[next] - points[prev]).normalized()
		for edge in range(2):
			vertices.append(points[i])
			tangents.append(tangent)
			uvs.append(Vector2(float(edge), distances[i] / maxf(0.001, distance)))
		if i > 0:
			var j := i * 2
			indices.append_array(PackedInt32Array([j - 2, j - 1, j, j - 1, j + 1, j]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = tangents
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _eve_sprite(group: Dictionary, at: Vector3, size: float, shader: Shader,
		life: float, delay: float = 0.0) -> ShaderMaterial:
	var mat := _material(shader, group, life, delay)
	mat.set_shader_parameter("screen_min_px", clampf(size * 14.0, 12.0, 56.0))
	mat.set_shader_parameter("screen_max_scale", 8.0)
	var mi := MeshInstance3D.new()
	mi.mesh = _quad_mesh
	mi.custom_aabb = _quad_mesh.get_aabb().grow(SCREEN_MAX_SCALE * 0.5)
	mi.material_override = mat
	mi.position = at
	mi.scale = Vector3.ONE * size
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	group.node.add_child(mi)
	return mat


func _rail_charge(group: Dictionary, a: Vector3, b: Vector3, size: float,
		tint: Color, rng: RandomNumberGenerator, _tier: int) -> void:
	# One continuous wake scatters small crops of the original lightning atlas.
	# No complete branch sprites placed at evenly spaced path anchors.
	group.life = maxf(group.life, 0.87)
	var mat := _material(HYBRID_WAKE, group, 0.62, 0.025)
	mat.set_shader_parameter("propagation_time", group.get("propagation_time", 0.0))
	mat.set_shader_parameter("atlas", IMPACT_ELECTRIC)
	mat.set_shader_parameter("point_a", a)
	mat.set_shader_parameter("point_b", b)
	mat.set_shader_parameter("width", size)
	mat.set_shader_parameter("effect_scale", size)
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("seed", rng.randf_range(0.0, 100.0))
	var mi := MeshInstance3D.new()
	mi.mesh = _ribbon_mesh
	mi.material_override = mat
	mi.custom_aabb = AABB(a.min(b), a.max(b) - a.min(b)).grow(size * SCREEN_MAX_SCALE)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	group.node.add_child(mi)
	_bind_path(group, mi, mat, false)


func _muzzle(group: Dictionary, at: Vector3, direction: Vector3, size: float,
		tint: Color, life: float, energy: float, delay: float = 0.0) -> void:
	var node := _burst(group, at + direction * size * 0.12, size, 2, tint, life, energy, delay)
	node.material_override.set_shader_parameter("firing_axis", direction)
	_bind_marker(group, node, 0.0)

func _burst(group: Dictionary, at: Vector3, size: float, shape: int, tint: Color,
		life: float, energy: float = 3.0, delay: float = 0.0,
		normal: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mat := _material(BURST, group, life, delay)
	mat.set_shader_parameter("shape", shape)
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("energy", energy)
	mat.set_shader_parameter("seed", float(_serial) * 0.73 + size)
	mat.set_shader_parameter("electric_map", ELECTRIC_MAP)
	mat.set_shader_parameter("billboard", normal.length_squared() < 0.01)
	mat.set_shader_parameter("firing_axis", Vector3.ZERO)
	mat.set_shader_parameter("screen_min_px", clampf(size * (10.0 if shape == 0 else 14.0), 12.0, 32.0))
	mat.set_shader_parameter("screen_max_scale", 8.0)
	var mi := MeshInstance3D.new()
	mi.mesh = _quad_mesh
	mi.custom_aabb = _quad_mesh.get_aabb().grow(SCREEN_MAX_SCALE * 0.5)
	mi.material_override = mat
	mi.position = at
	mi.scale = Vector3.ONE * size
	if normal.length_squared() > 0.01:
		mi.quaternion = Quaternion(Vector3.BACK, normal.normalized())
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	group.node.add_child(mi)
	return mi

func _basis_for(direction: Vector3) -> Basis:
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
	var side := direction.cross(up).normalized()
	return Basis(side, side.cross(direction).normalized(), direction)


func _laser(group: Dictionary, a: Vector3, b: Vector3, direction: Vector3,
		size: float, tint: Color, hit: bool, quality: int, layer: StringName,
		rng: RandomNumberGenerator) -> void:
	# Constant cross-section and hue along the beam. Endpoint white flashes
	# remain distinct, short interactions rather than the beam's halo profile.
	_aura(group, a, b, 2.9 * size, tint, 0.55, 0.080)
	_aura(group, a, b, 6.4 * size, tint, 0.62, 0.018)
	var mat := _material(LASER_BODY, group, 0.56)
	mat.set_shader_parameter("point_a", a)
	mat.set_shader_parameter("point_b", b)
	mat.set_shader_parameter("width", 0.66 * size)
	mat.set_shader_parameter("screen_min_px", 30.0 * size)
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("energy", 1.0)
	mat.set_shader_parameter("miss_fraction",group.get("miss_fraction",1.0))
	var body := MeshInstance3D.new()
	body.mesh = _ribbon_mesh
	body.material_override = mat
	body.custom_aabb = AABB(a.min(b), a.max(b) - a.min(b)).grow(size * SCREEN_MAX_SCALE)
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	group.node.add_child(body)
	_bind_path(group, body, mat)
	for path in group.paths:
		if path.material.shader == AURA:
			path.material.set_shader_parameter("hold_fraction", 0.60)
			path.material.set_shader_parameter("laser_cycle", true)
			path.material.set_shader_parameter("miss_fraction",group.get("miss_fraction",1.0))
	# Only sparse glints remain after the continuous beam loses power. They
	# coast along the captured path, with drag and independent finite lives.
	group.life = maxf(group.life, 1.00)
	var wake := _material(LASER_WAKE, group, 0.44, 0.54)
	for pair in [["point_a", a], ["point_b", b], ["width", 0.50 * size],
			["effect_scale", size], ["tint", tint], ["seed", rng.randf_range(0.0, 100.0)],
			["miss_fraction", group.get("miss_fraction", 1.0)]]:
		wake.set_shader_parameter(pair[0], pair[1])
	var wake_node := MeshInstance3D.new()
	wake_node.mesh = _ribbon_mesh
	wake_node.material_override = wake
	wake_node.custom_aabb = body.custom_aabb
	wake_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	group.node.add_child(wake_node)
	_bind_path(group, wake_node, wake, true, 0.54)
	group.path_stage = false
	# 2026-11-05 visual reference accepted by the user: retain the white
	# endpoint orb/flash and expanding ring independently of the beam halo.
	_muzzle(group, a, direction, 1.05 * size, tint, 0.11, 2.0)
	var source_orb := _burst(group, a, 2.6 * size, 0, tint, 0.56, 0.8)
	source_orb.material_override.set_shader_parameter("laser_cycle", true)
	_bind_marker(group, source_orb, 0.0)
	_bind_marker(group, _burst(group, a + direction * 0.12, 1.1 * size, 1, tint, 0.20, 1.3, 0.0, direction), 0.0)
	if not hit:
		return
	var quality_size := 0.70 + float(clampi(quality, 0, 6)) * 0.10
	var contact := _burst(group, b, 1.2 * size * quality_size, 3, tint, 0.56, 2.0)
	contact.material_override.set_shader_parameter("hold_fraction", 0.60)
	contact.material_override.set_shader_parameter("laser_cycle", true)
	_bind_marker(group, contact, 1.0)
	var target_orb := _burst(group, b, 2.1 * size, 0, tint, 0.58, 0.8)
	target_orb.material_override.set_shader_parameter("laser_cycle", true)
	_bind_marker(group, target_orb, 1.0)
	_bind_marker(group, _burst(group, b, 1.6 * size, 1, tint, 0.26, 1.2, 0.0, direction), 1.0)
	# Contact streaks carry the same spectrum as the luminous sheath.
	var basis := _basis_for(direction)
	for i in range(2 + int(quality >= 5)):
		var velocity := (-direction * rng.randf_range(0.8, 1.6) +
			basis.x * rng.randf_range(-1.6, 1.6) + basis.y * rng.randf_range(-1.2, 1.2)) * size
		_band(group, b, b + velocity * 0.08, 1, 0.035 * size, tint, 0.13, 0.6)
		var node: MeshInstance3D = group.node.get_child(group.node.get_child_count() - 1)
		group.moving.append({"node": node, "origin": Vector3.ZERO,
			"velocity": velocity, "size": 1.0, "delay": 0.0, "expand": false})

func _miss_endpoint(group: Dictionary, a: Vector3, target: Node3D) -> Vector3:
	var center: Vector3 = target.fx_center_world()
	var direction := (center-a).normalized()
	var basis := _basis_for(direction)
	if not group.has("miss_side"):
		var camera := get_viewport().get_camera_3d()
		var view_side := direction.cross((camera.global_position-center).normalized()) if camera!=null else basis.x
		group.miss_side = view_side.normalized() if view_side.length_squared()>0.001 else basis.x
	# Choose a readable side at emission, then retain that world-space direction
	# through the shot. Turning the camera does not swivel a flying miss around.
	var side: Vector3 = (group.miss_side-direction*group.miss_side.dot(direction)).normalized()
	var up := side.cross(direction).normalized()
	var clearance: float = target.fx_transverse_extent(side) + group.miss_margin
	var graze: Vector3 = center + side*clearance*group.miss_sign + up*group.miss_height
	# A near silhouette pass must stay a miss even as the hull turns. The
	# inexpensive native query checks the entire ray, not an estimated ellipsoid.
	for i in range(5):
		if target._fx_ray_surface(a,graze).is_empty():
			break
		clearance *= 1.25
		graze = center + side*clearance*group.miss_sign + up*group.miss_height
	var ray := (graze-a).normalized()
	var extension := maxf(60.0,a.distance_to(graze)*3.0)
	var camera := get_viewport().get_camera_3d()
	if camera!=null:
		var exit_distance := INF
		for plane in camera.get_frustum():
			var crossing = plane.intersects_ray(graze,ray)
			if crossing is Vector3:
				var distance: float = (crossing-graze).dot(ray)
				if distance>0.01:
					exit_distance=minf(exit_distance,distance)
		if is_finite(exit_distance):
			extension=maxf(extension,exit_distance*1.5+10.0)
	group.miss_fraction = a.distance_to(graze)/(a.distance_to(graze)+extension)
	group.miss_offset = graze-center
	return graze + ray*extension


func spawn_weapon(weapon: StringName, from_meters: Vector3, to_meters: Vector3,
		hit: bool, quality: int = 3, tier: int = 3, star: int = 1,
		logistics: bool = false, layer: StringName = &"armor",
		visual_seed: int = 0, anchors: Dictionary = {}) -> void:
	if not fx_enabled or not Profiles.WEAPONS.has(weapon): return
	if weapon == &"missile":
		_spawn_weapon_packet(weapon, from_meters, to_meters, hit, quality, tier, star, logistics, layer, visual_seed, anchors)
		return
	if from_meters.distance_squared_to(to_meters) < .001: return
	var count := Profiles.cannon_mount_count(tier)
	var salvo := {"weapon":weapon, "from":from_meters, "to":to_meters,
		"hit":hit, "quality":quality, "tier":tier, "star":star, "logistics":logistics,
		"layer":layer, "seed":visual_seed, "anchors":anchors.duplicate(),
		"count":count, "next":1, "t":0.0, "fresh":true, "mounts":[]}
	var source = anchors.get("source_visual")
	if is_instance_valid(source):
		salvo.mounts = source.fx_mount_frames_world(to_meters / METERS_PER_UNIT, count, true)
		if salvo.mounts.size() != count:
			push_error("Cannon salvo requires %d distinct authored mounts on %s; found %d" % [count, source.ship.ship_key, salvo.mounts.size()])
			return
	stats[String(weapon)] = int(stats[String(weapon)]) + 1
	_emit_cannon_packet(salvo, 0)
	_cannon_salvos.append(salvo)


func _emit_cannon_packet(salvo: Dictionary, index: int) -> void:
	var anchors: Dictionary = salvo.anchors.duplicate()
	var from_meters: Vector3 = salvo["from"]
	var to_meters: Vector3 = salvo["to"]
	var source = anchors.get("source_visual")
	var target = anchors.get("target_visual")
	if is_instance_valid(source):
		var aim: Vector3 = target.fx_center_world() if is_instance_valid(target) else to_meters / METERS_PER_UNIT
		if not salvo.mounts.is_empty():
			anchors.source_mount_index = int(salvo.mounts[index].mount_index)
			from_meters = source.fx_cannon_mount_world(aim, anchors.source_mount_index) * METERS_PER_UNIT
		else:
			from_meters = source.fx_mount_world(aim) * METERS_PER_UNIT
	else:
		anchors["source_visual"] = null
	if is_instance_valid(target) and bool(salvo.hit):
		to_meters = target.fx_contact_world(from_meters / METERS_PER_UNIT,
			salvo.layer == &"shield", Vector2.ZERO, int(anchors.get("shield_slot", -1))) * METERS_PER_UNIT
	elif not is_instance_valid(target):
		anchors["target_visual"] = null
	anchors["packet_index"] = index
	_spawn_weapon_packet(salvo.weapon, from_meters, to_meters, salvo.hit, salvo.quality,
		salvo.tier, salvo.star, salvo.logistics, salvo.layer, int(salvo.seed) + index, anchors)


func _process_cannon_salvos(dt: float) -> void:
	for i in range(_cannon_salvos.size() - 1, -1, -1):
		var salvo := _cannon_salvos[i]
		if salvo.fresh:
			salvo.fresh = false
		else:
			salvo.t = float(salvo.t) + dt
		while int(salvo.next) < int(salvo.count) and float(salvo.t) + .000001 >= float(salvo.next) * Profiles.CANNON_MOUNT_STAGGER:
			_emit_cannon_packet(salvo, int(salvo.next))
			salvo.next = int(salvo.next) + 1
		if int(salvo.next) >= int(salvo.count): _cannon_salvos.remove_at(i)


func _spawn_weapon_packet(weapon: StringName, from_meters: Vector3, to_meters: Vector3,
		hit: bool, quality: int = 3, tier: int = 3, star: int = 1,
		logistics: bool = false, layer: StringName = &"armor",
		visual_seed: int = 0, anchors: Dictionary = {}) -> void:
	if not fx_enabled or not Profiles.WEAPONS.has(weapon):
		return
	if weapon == &"missile":
		_serial += 1
		var missile_event := {"flight_id": -_serial, "from": from_meters, "to": to_meters,
			"tier": tier, "star": star, "logistics": logistics, "hit": hit,
			"duration": EveCombatCore.missile_flight_duration(from_meters.distance_to(to_meters)),
			"visual_seed": visual_seed, "preview": true, "quality": quality, "layer": layer}
		missile_event.merge(anchors)
		launch_missile(missile_event)
		return
	var a := from_meters / METERS_PER_UNIT
	var b := to_meters / METERS_PER_UNIT
	var span := a.distance_to(b)
	if span < 0.001:
		return
	_serial += 1
	var rng := RandomNumberGenerator.new()
	rng.seed = visual_seed if visual_seed != 0 else _serial * 179 + 7919
	var direction := (b - a).normalized()
	var basis := _basis_for(direction)
	var scale_factor := Profiles.scale_of(tier, star, logistics)
	var tint := Profiles.color_of(weapon)
	if weapon == &"laser":
		tint = laser_tint
	var group := _group(0.76, "Weapon_" + String(weapon))
	group.weapon = weapon
	group.hit = hit
	group.shield = layer == &"shield"
	group.anchors = anchors
	group.path_stage = true
	var target: Node3D = anchors.get("target_visual")
	if hit and group.shield and is_instance_valid(target):
		group.shield_slot=int(anchors.get("shield_slot",-1))
		if group.shield_slot<0: group.shield_slot=target.fx_shield_slot(a)
		b=target.fx_contact_world(a,true,Vector2.ZERO,group.shield_slot)
	if not hit:
		if is_instance_valid(target):
			group.miss_sign = -1.0 if rng.randf()<0.5 else 1.0
			group.miss_margin = rng.randf_range(0.12,0.24)*scale_factor
			group.miss_height = rng.randf_range(-0.12,0.12)*scale_factor
			group.pattern_reference = a.distance_to(target.fx_center_world())
			b = _miss_endpoint(group,a,target)
		else:
			b += basis.x * rng.randf_range(1.7, 2.8) * scale_factor
			b += basis.y * rng.randf_range(-1.0, 1.0)
	group.a = a
	group.b = b
	if not group.has("miss_fraction"):
		group.miss_offset = b - target.fx_center_world() if is_instance_valid(target) else Vector3.ZERO
	direction = (b-a).normalized()
	_ensure_weapon_audio()
	weapon_audio.fire(weapon, tier, visual_seed)
	if weapon == &"laser":
		_laser(group, a, b, direction, scale_factor, tint, hit, quality, layer, rng)
		return
	elif weapon == &"hybrid":
		# Keep the close-range timing at any distance, shared by the advancing
		# beam, its electrical wake and the contact flash.
		var travel := Profiles.HYBRID_ARRIVAL_TIME
		group.propagation_time = travel
		group.life = maxf(group.life, travel + 0.88)
		_band(group, a, b, 1, 0.22 * scale_factor, tint, 0.16, 1.6)
		_band(group, a, b, 1, 0.11 * scale_factor, tint, 0.42, 0.30)
		_aura(group, a, b, 0.85 * scale_factor, tint, 0.46, 0.085)
		_muzzle(group, a, direction, 0.9 * scale_factor, tint, 0.15, 2.2)
		var detail_fraction: float = group.get("miss_fraction",1.0)
		var count := 3 + clampi(tier, 1, 5)
		for i in range(count):
			var f := (float(i) + 0.7) / (float(count) + 0.7) * detail_fraction
			_bind_marker(group, _burst(group, a.lerp(b, f), (0.45 + f * 0.55) * scale_factor,
				1, tint, 0.20, 0.8, f * travel, direction), f)
		_rail_charge(group, a, a.lerp(b,detail_fraction), scale_factor, tint, rng, tier)
		for path in group.paths:
			path.material.set_shader_parameter("propagation_time", travel * (detail_fraction if path.material.shader == HYBRID_WAKE else 1.0))
	elif weapon == &"proj":
		_heavy_round(group, a, b, scale_factor, tint)
		_muzzle(group, a, direction, 1.15 * scale_factor, tint, 0.12, 1.5)

	group.path_stage = false
	if hit:
		_weapon_impact(group, b, direction, tint, scale_factor, quality, layer, rng, float(group.get("propagation_time", 0.0)) if weapon == &"hybrid" else a.distance_to(b) / 48.0)

func _drone_projectile(group: Dictionary, a: Vector3, b: Vector3, size: float, tint: Color) -> void:
	var life := (a.distance_to(b) + Profiles.DRONE_PACKET_LENGTH) / Profiles.DRONE_PACKET_SPEED
	var band := _band(group, a, b, 2, 0.23 * size, tint, life, 1.4)
	band.set_shader_parameter("packet_core", Vector3(1.05, 0.92, 1.22))
	var halo := _aura(group, a, b, size, tint, life, 0.20, 2)
	for mat in [band, halo]:
		mat.set_shader_parameter("finite_packet", true)
		mat.set_shader_parameter("packet_length", Profiles.DRONE_PACKET_LENGTH)
		mat.set_shader_parameter("packet_speed", Profiles.DRONE_PACKET_SPEED)

func _heavy_round(group: Dictionary, a: Vector3, b: Vector3, size: float,
		tint: Color, delay: float = 0.0, speed: float = 48.0) -> void:
	var life := a.distance_to(b) / speed + 0.10
	group.life = maxf(group.life, delay + life + 0.10)
	var mat := _material(KINETIC_ROUND, group, life, delay)
	for pair in [["point_a",a],["point_b",b],["width",0.24*size],
		["round_length",0.90*size],["speed",speed],["tint",tint],["energy",2.0]]:
		mat.set_shader_parameter(pair[0],pair[1])
	var mi := MeshInstance3D.new()
	mi.mesh = _ribbon_mesh
	mi.material_override = mat
	mi.custom_aabb = AABB(a.min(b),a.max(b)-a.min(b)).grow(size*3.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	group.node.add_child(mi)
	_bind_path(group,mi,mat,false)


func _weapon_impact(group: Dictionary, at: Vector3, direction: Vector3, tint: Color,
		size: float, quality: int, layer: StringName, rng: RandomNumberGenerator, delay: float = 0.0) -> void:
	var first_mat: int = group.materials.size()
	var first_mover: int = group.moving.size()
	group.life = maxf(group.life, delay + 0.55)
	var impact_tint := tint
	if layer == &"shield":
		impact_tint = tint.lerp(Color(0.20, 0.65, 1.0), 0.40)
	elif layer == &"hull":
		impact_tint = tint.lerp(Color(1.0, 0.30, 0.035), 0.45)
	var quality_scale := 0.70 + float(clampi(quality, 0, 6)) * 0.10
	_bind_marker(group, _burst(group, at, 1.2 * size * quality_scale, 3, impact_tint, 0.38, 2.0), 1.0)
	_bind_marker(group, _burst(group, at, 2.1 * size, 0, impact_tint, 0.48, 0.8), 1.0)
	_bind_marker(group, _burst(group, at, 1.6 * size, 1, impact_tint, 0.34, 1.2, 0.0, direction), 1.0)
	var basis := _basis_for(direction)
	for i in range(3 + int(quality >= 5)):
		var end := at - direction * rng.randf_range(0.20, 0.7) * size
		end += basis.x * rng.randf_range(-0.6, 0.6) * size
		end += basis.y * rng.randf_range(-0.5, 0.5) * size
		# World-space ejecta travel outwards, rather than static spoke stickers.
		_band(group, at, at + (end - at) * 0.25, 1, 0.065 * size, impact_tint, 0.22, 1.3)
		var spark: MeshInstance3D = group.node.get_child(group.node.get_child_count() - 1)
		var speed := (end - at) * 5.0
		group.moving.append({"node": spark, "origin": Vector3.ZERO,
			"velocity": speed, "size": 1.0, "delay": 0.0, "expand": false})

	for index in range(first_mat, group.materials.size()):
		group.materials[index].set_shader_parameter("delay",delay)
	for index in range(first_mover,group.moving.size()):
		group.moving[index].delay=delay


func _missile_body(scale_factor: float, seed_value: float) -> Dictionary:
	const BODY_SCALE := 0.48
	var root := Node3D.new()
	root.name = "HeavyMissileBody"
	add_child(root)
	root.scale = Vector3.ONE * scale_factor
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.54, 0.62, 0.70)
	metal.metallic = 0.65
	metal.roughness = 0.32
	var body := CylinderMesh.new()
	body.top_radius = 0.060 * BODY_SCALE
	body.bottom_radius = 0.060 * BODY_SCALE
	body.height = 0.42 * BODY_SCALE
	body.radial_segments = 8
	var nose := CylinderMesh.new()
	nose.top_radius = 0.0
	nose.bottom_radius = 0.060 * BODY_SCALE
	nose.height = 0.15 * BODY_SCALE
	nose.radial_segments = 8
	for entry in [[body, 0.0], [nose, -0.285]]:
		var mi := MeshInstance3D.new()
		mi.mesh = entry[0]
		mi.material_override = metal
		mi.rotation.x = -PI * 0.5
		mi.position.z = float(entry[1]) * BODY_SCALE
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
	for roll in [0.0, PI * 0.5]:
		var fin_mesh := BoxMesh.new()
		fin_mesh.size = Vector3(0.23, 0.016, 0.16) * BODY_SCALE
		var fin := MeshInstance3D.new()
		fin.mesh = fin_mesh
		fin.material_override = metal
		fin.position.z = 0.13 * BODY_SCALE
		fin.rotation.z = roll
		fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(fin)
	var plume := MeshInstance3D.new()
	plume.name = "ExhaustPressureJet"
	plume.mesh = _ribbon_mesh
	plume.custom_aabb = AABB(Vector3(-0.35, -0.35, 0.0), Vector3(0.7, 0.7, 1.65))
	plume.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var plume_mat := ShaderMaterial.new()
	plume_mat.shader = EXHAUST
	plume_mat.set_shader_parameter("power", 0.0)
	plume_mat.set_shader_parameter("brightness", 0.0)
	plume_mat.set_shader_parameter("nozzle_z", 0.21 * BODY_SCALE)
	plume_mat.set_shader_parameter("seed", seed_value)
	plume_mat.set_shader_parameter("turbulence", EXHAUST_NOISE)
	plume.material_override = plume_mat
	root.add_child(plume)
	var sheath := plume.duplicate() as MeshInstance3D
	sheath.name = "ExhaustSoftSheath"
	var sheath_mat := plume_mat.duplicate() as ShaderMaterial
	sheath_mat.set_shader_parameter("sheath", 1.0)
	sheath.material_override = sheath_mat
	root.add_child(sheath)
	var core := plume.duplicate() as MeshInstance3D
	core.name = "ExhaustWhiteHotCore"
	var core_mat := plume_mat.duplicate() as ShaderMaterial
	core_mat.set_shader_parameter("sheath", 2.0)
	core.material_override = core_mat
	root.add_child(core)
	# Keep the visible core at its normal response speed. Only its surplus HDR
	# radiance (which creates the intense optical glow) builds more slowly.
	var glow := core.duplicate() as MeshInstance3D
	glow.name = "ExhaustOpticalGlow"
	var glow_mat := core_mat.duplicate() as ShaderMaterial
	glow_mat.set_shader_parameter("sheath", 4.0)
	glow.material_override = glow_mat
	root.add_child(glow)
	var exhaust_materials: Array[ShaderMaterial] = [plume_mat, sheath_mat, core_mat, glow_mat]
	var auxiliary_jets: Array[MeshInstance3D] = []
	for index in range(3):
		# All four jets share the physical nozzle. The short auxiliary jets
		# spread 120 degrees around the main axis, rather than extending its trail.
		var angle := TAU * float(index) / 3.0
		var tilt := deg_to_rad(30.0)
		var direction := Vector3(cos(angle) * sin(tilt), sin(angle) * sin(tilt), cos(tilt))
		var jet := plume.duplicate() as MeshInstance3D
		jet.name = "ExhaustAuxiliary%d" % index
		jet.position = Vector3(0.0, 0.0, 0.21 * BODY_SCALE)
		jet.quaternion = Quaternion(Vector3.BACK, direction)
		var mat := plume_mat.duplicate() as ShaderMaterial
		mat.set_shader_parameter("nozzle_z", 0.0)
		mat.set_shader_parameter("sheath", 3.0)
		mat.set_shader_parameter("seed", seed_value + float(index) * 7.13)
		jet.material_override = mat
		root.add_child(jet)
		exhaust_materials.append(mat)
		auxiliary_jets.append(jet)
	var trail := MeshInstance3D.new()
	trail.name = "SpentExhaustTrail"
	trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var trail_mat := ShaderMaterial.new()
	trail_mat.shader = TRAIL
	trail_mat.set_shader_parameter("screen_compensation", screen_compensation)
	trail_mat.set_shader_parameter("screen_min_px", 10.0)
	trail_mat.set_shader_parameter("width", 0.32 * scale_factor)
	trail.material_override = trail_mat
	add_child(trail)
	root.hide()
	return {"node": root, "plume": plume_mat, "sheath": sheath_mat, "core": core_mat, "glow": glow_mat, "trail": trail,
		"exhaust_materials": exhaust_materials, "auxiliary_jets": auxiliary_jets,
		"history": [], "delay": 0.0, "launched": false, "ignited": false, "phase": &"waiting"}


func _missile_launch_frames(event: Dictionary, fallback: Vector3, aim: Vector3) -> Array[Dictionary]:
	var direction := (aim - fallback).normalized()
	var side := direction.cross(Vector3.UP).normalized()
	if side.length_squared() < 0.01: side = Vector3.RIGHT
	var inherited: Vector3 = event.get("source_velocity", Vector3.ZERO) / METERS_PER_UNIT
	var frames: Array[Dictionary] = []
	var source: Node3D = event.get("source_visual")
	if is_instance_valid(source) and source.visible:
		inherited = source.ship.body.velocity / METERS_PER_UNIT
		for mount in source.fx_mount_frames_world(aim, 3):
			frames.append({"origin": mount.origin, "outward": mount.normal, "inherited": inherited,
				"local_origin": source.to_local(mount.origin),
				"local_normal": source.global_basis.inverse() * mount.normal,
				"mount_index": mount.mount_index})
	if frames.is_empty():
		frames.append({"origin": fallback, "outward": side, "inherited": inherited, "mount_index": -1})
	return frames


func launch_missile(event: Dictionary) -> void:
	if not fx_enabled:
		return
	_mesh_setup()
	var a: Vector3 = event["from"] / METERS_PER_UNIT
	var b: Vector3 = event["to"] / METERS_PER_UNIT
	if not bool(event.hit):
		b += Vector3(1.4, 0.7, 0.0)
	if a.distance_squared_to(b) < 0.0001:
		return
	var id := int(event.flight_id)
	cancel_missile(id)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(event.get("visual_seed", 7919))
	var size := Profiles.scale_of(int(event.tier), int(event.star), bool(event.logistics))
	var flight := {"t": 0.0, "fresh": true, "life": float(event.duration), "a": a, "b": b,
		"size": size, "rounds": [], "event": event, "rng": rng,
		"resolved": false, "hit": bool(event.hit), "quality": 3, "layer": &"shield","shield_slot":-1}
	# Three sequential releases. The first arrival owns the existing one damage
	# settlement; the other two remain presentation rounds with later contacts.
	var launch_frames := _missile_launch_frames(event, a, b)
	for i in range(3):
		var round := _missile_body(size, rng.randf() * 100.0)
		round.launch_frame = launch_frames[i % launch_frames.size()]
		round.index = i
		round.delay = float(i) * MISSILE_BURST_INTERVAL
		round.arrival = float(event.duration) + float(round.delay)
		round.coast_time = minf(MISSILE_COAST_TIME, float(event.duration) * 0.46)
		round.origin = round.launch_frame.origin
		round.eject = round.launch_frame.outward
		round.drift_velocity = round.launch_frame.inherited + round.eject * size * 0.9
		round.patch = [Vector2.ZERO, Vector2(-0.14, 0.08), Vector2(0.12, -0.09)][i]
		round.landed = false
		round.node.position = round.origin
		round.node.quaternion = Quaternion(Vector3.FORWARD, (b - round.origin).normalized())
		flight.rounds.append(round)
	_flights[id] = flight
	stats.missile = int(stats.missile) + 1


func _begin_missile_round(flight: Dictionary, round: Dictionary) -> void:
	var source: Node3D = flight.event.get("source_visual")
	var frame: Dictionary = round.launch_frame
	var inherited: Vector3 = frame.inherited
	if is_instance_valid(source) and source.visible and frame.has("local_origin"):
		# Each release keeps its own native mount and follows the source's
		# current pose instead of reselecting between shots.
		round.origin = source.to_global(frame.local_origin)
		round.eject = (source.global_basis * frame.local_normal).normalized()
		inherited = source.ship.body.velocity / METERS_PER_UNIT
	else:
		round.origin = frame.origin + frame.inherited * float(round.delay)
		round.eject = frame.outward
	round.drift_velocity = inherited + round.eject * float(flight.size) * 0.9
	round.launched = true
	round.phase = &"coast"
	_ensure_weapon_audio()
	# Cold ejection is silent; powered flight and contact retain their own cues.
	var release := _group(0.10, "MissileColdEjection")
	_burst(release, round.origin, float(flight.size) * 0.24, 3, Color(0.55, 0.70, 0.85), 0.07, 0.35)


func _missile_motion(round: Dictionary, endpoint: Vector3, age: float) -> Dictionary:
	var coast: float = round.coast_time
	var drift: Vector3 = round.drift_velocity
	if age <= coast:
		return {"p": round.origin + drift * maxf(0.0, age), "v": drift}
	var duration := maxf(0.01, float(round.arrival) - float(round.delay) - coast)
	var s := clampf((age - coast) / duration, 0.0, 1.0)
	var start: Vector3 = round.origin + drift * coast
	# Integrate the inherited transverse velocity while progressively replacing
	# it with engine thrust. Position, velocity and acceleration match at ignition.
	var displacement: Vector3 = endpoint - start - drift * duration * 0.5
	var inertia_travel := s - s * s * s + 0.5 * s * s * s * s
	return {"p": start + drift * duration * inertia_travel + displacement * s * s * s,
		"v": drift * (1.0 - 3.0 * s * s + 2.0 * s * s * s) + displacement * (3.0 * s * s / duration)}


func _round_endpoint(flight: Dictionary, round: Dictionary) -> Vector3:
	var event: Dictionary = flight.event
	var target: Node3D = event.get("target_visual")
	if is_instance_valid(target):
		if bool(event.hit):
			var shield:bool=flight.layer==&"shield" if flight.resolved else (
				float(target.ship.hp.get(&"shield",0.0))>0.0 and not bool(event.get("pierced",false)))
			if round.index > 0 and float(target.ship.hp.get(&"shield", 0.0)) <= 0.0: shield = false
			if shield and flight.shield_slot<0: flight.shield_slot=target.fx_shield_slot(flight.a)
			return target.fx_contact_world(flight.a,shield,round.patch,flight.shield_slot if shield else -1)
		return target.fx_center_world() + Vector3(1.4, 0.7, 0.0)
	var basis := _basis_for((flight.b - flight.a).normalized())
	return flight.b + (basis.x * round.patch.x + basis.y * round.patch.y) * float(flight.size) * 0.40


func _process_flights(dt: float) -> void:
	for id in _flights.keys():
		if not _flights.has(id):
			continue
		var flight: Dictionary = _flights[id]
		if flight.fresh:
			flight.fresh = false
		else:
			flight.t = float(flight.t) + dt
		var event: Dictionary = flight.event
		var target_ship: EveShip = event.get("target_ship")
		if target_ship != null and not target_ship.alive:
			cancel_missile(int(id))
			continue
		var target: Node3D = event.get("target_visual")
		if is_instance_valid(target):
			var ship: EveShip = target.get("ship")
			if ship != null and not ship.alive:
				cancel_missile(int(id))
				continue
		# Preview uses the same cold launch and lead/secondary arrivals as combat.
		if not bool(flight.resolved) and float(flight.t) >= float(flight.life) and bool(event.get("preview", false)):
			resolve_missile(int(id), flight.b * METERS_PER_UNIT, bool(event.hit),
				int(event.get("quality", 3)), StringName(event.get("layer", &"shield")))
		var all_landed := true
		for round in flight.rounds:
			if bool(round.landed):
				continue
			all_landed = false
			var t := float(flight.t) - float(round.delay)
			round.node.visible = t >= 0.0
			if t < 0.0:
				continue
			if not bool(round.launched): _begin_missile_round(flight, round)
			var endpoint := _round_endpoint(flight, round)
			if bool(flight.resolved) and float(flight.t) >= float(round.arrival):
				_land_missile(flight, round, endpoint)
				continue
			var motion := _missile_motion(round, endpoint, t)
			var p: Vector3 = motion.p
			var tangent: Vector3 = motion.v.normalized()
			if tangent.length_squared() < 0.01: tangent = (endpoint - round.origin).normalized()
			var burn_age := t - float(round.coast_time)
			# The rack ejects the body sideways with its nose already facing the
			# attack direction. Engine thrust then overtakes the transverse drift.
			var engine_axis: Vector3 = (endpoint - round.origin).normalized()
			var facing_axis := engine_axis.slerp(tangent, smoothstep(0.16, 0.38, burn_age)).normalized()
			var display_scale := _screen_geometry_scale(p, 0.30 * float(flight.size), 6.0)
			round.node.scale = Vector3.ONE * float(flight.size) * display_scale
			round.node.position = p
			round.node.quaternion = Quaternion(Vector3.FORWARD, facing_axis)
			var thrust := smoothstep(0.0, EveCombatCore.MISSILE_IGNITION_TIME, burn_age) * (0.55 + smoothstep(0.10, 0.58, burn_age) * 1.35)
			# The main and auxiliary flames keep their original engine response.
			# Only the separate HDR glow pass uses this slower optical envelope.
			var glow_rise := smoothstep(0.0, MISSILE_GLOW_RISE_TIME, burn_age)
			var brightness := smoothstep(0.0, 0.12, burn_age) * lerpf(0.025, 1.0, glow_rise * glow_rise)
			for mat in round.exhaust_materials:
				mat.set_shader_parameter("age", t)
				mat.set_shader_parameter("power", thrust)
			round.glow.set_shader_parameter("brightness", brightness)
			if burn_age <= 0.0: continue
			round.phase = &"boost"
			if not bool(round.ignited) and thrust >= MISSILE_AUDIO_IGNITION_POWER and brightness >= MISSILE_AUDIO_IGNITION_BRIGHTNESS:
				round.ignited = true
				# The optical jet must be visibly lit, not merely producing low thrust.
				weapon_audio.fire(&"missile", int(event.tier), int(event.get("visual_seed", 0)) + int(round.index))
				round.engine_voice = weapon_audio.start_engine(int(event.tier), int(event.get("visual_seed", 0)) + int(round.index))
			var history: Array = round.history
			history.append({"p": p - tangent * 0.10 * float(flight.size) * display_scale, "t": float(flight.t)})
			while history.size() > 2 and (float(flight.t) - float(history[0].t) > 0.085
					or p.distance_to(history[0].p) > float(flight.size) * 1.25):
				history.pop_front()
			if history.size() >= 2:
				var points := PackedVector3Array()
				for sample in history:
					points.append(sample.p)
				round.trail.mesh = _polyline_mesh(points)
				round.trail.custom_aabb = round.trail.mesh.get_aabb().grow(8.0)
		if all_landed:
			_flights.erase(id)


func _land_missile(flight: Dictionary, round: Dictionary, at: Vector3) -> void:
	if bool(round.landed):
		return
	round.landed = true
	round.phase = &"landed"
	if weapon_audio != null:
		weapon_audio.stop_engine(round.get("engine_voice"))
		round.engine_voice = null
	if bool(flight.hit):
		var motion := _missile_motion(round, at, float(round.arrival) - float(round.delay))
		var blast := _missile_detonation(at, motion.v.normalized(), float(flight.size) * float(round.get("impact_scale",1.0)), flight.rng)
		if weapon_audio != null:
			var tier := int(flight.event.tier)
			var seed_value := int(flight.event.get("visual_seed", 0)) + int(round.index)
			if WEAPON_AUDIO.size_for(tier) == "large":
				# Contact first compresses; the heavy blast sounds when its main lobe opens.
				# Keeping this on the FX age also respects pause, speed and clear().
				blast.audio_cue = {"family": &"missile_hit", "tier": tier, "seed": seed_value,
					"delay": MISSILE_IMPACT.COMPRESSION_TIME + 0.025}
			else:
				weapon_audio.fire(&"missile_hit", tier, seed_value)
	if is_instance_valid(round.node):
		round.node.queue_free()
	round.node = null
	if is_instance_valid(round.trail):
		if round.trail.mesh != null:
			var tail := _group(0.14, "ExhaustRelease")
			round.trail.reparent(tail.node, true)
			var mat: ShaderMaterial = round.trail.material_override
			mat.set_shader_parameter("age", 0.0)
			mat.set_shader_parameter("lifetime", 0.14)
			tail.materials.append(mat)
		else:
			round.trail.queue_free()
	round.trail = null


func _impact_particle(group: Dictionary, at: Vector3, size: float,
		life: float, delay: float, rng: RandomNumberGenerator, splash: bool = false,
		energy: float = 2.4, temperature: float = 1.2) -> MeshInstance3D:
	var mat := _eve_sprite(group, at, size, EVE_IMPACT, life, delay)
	mat.set_shader_parameter("atlas", IMPACT_SPLASH if splash else IMPACT_FIRE)
	mat.set_shader_parameter("flow_atlas", IMPACT_SPLASH_FLOW if splash else IMPACT_FIRE_FLOW)
	mat.set_shader_parameter("color_ramp", IMPACT_ORANGE_RAMP)
	mat.set_shader_parameter("heat_ramp", IMPACT_HEAT_RAMP)
	mat.set_shader_parameter("rotation", rng.randf() * TAU)
	mat.set_shader_parameter("energy", energy)
	mat.set_shader_parameter("temperature", temperature)
	mat.set_shader_parameter("first_frame", 1.0 if splash else 8.0)
	mat.set_shader_parameter("last_frame", 32.0 if splash else 38.0)
	return group.node.get_child(group.node.get_child_count() - 1) as MeshInstance3D


func _missile_detonation(at: Vector3, direction: Vector3, size: float, rng: RandomNumberGenerator) -> Dictionary:
	var group := _group(MISSILE_IMPACT.DURATION, "HeavyMissileMainBlast")
	var blast_scale := size * 0.90
	var impact := MISSILE_IMPACT.new()
	impact.name = "HeavyKineticImpact"
	group.node.add_child(impact)
	impact.position = at
	# Original effect is axial; rotate its impact plane with the arrival vector.
	impact.quaternion = Quaternion(Vector3.UP, -direction)
	impact.scale = Vector3.ONE * blast_scale * _screen_geometry_scale(at, 2.0 * blast_scale, 52.0)
	impact.configure(rng)
	group.kinetic = impact
	group.blast_scale = blast_scale
	return group


func cancel_missile(id: int) -> void:
	if not _flights.has(id):
		return
	for round in _flights[id].rounds:
		if weapon_audio != null: weapon_audio.stop_engine(round.get("engine_voice"))
		if is_instance_valid(round.node):
			round.node.queue_free()
		if is_instance_valid(round.trail):
			round.trail.queue_free()
	_flights.erase(id)


func resolve_missile(id: int, at_meters: Vector3, hit: bool, quality: int, layer: StringName,
		shield_slot:int=-1) -> void:
	if not _flights.has(id):
		return
	var flight: Dictionary = _flights[id]
	if bool(flight.resolved):
		return
	flight.resolved = true
	flight.hit = hit
	flight.quality = quality
	flight.layer = layer
	if shield_slot>=0: flight.shield_slot=shield_slot
	flight.b = at_meters / METERS_PER_UNIT
	var contact:=_round_endpoint(flight, flight.rounds[0])
	_land_missile(flight, flight.rounds[0],contact)
	var target=flight.event.get("target_visual")
	if bool(flight.event.get("preview",false)) and hit and is_instance_valid(target):
		present_impact({"hit":true,"layer":layer,"layers":{layer:1.0},"breaks":[]},target,flight.a,contact)

# Older callers use the same new family renderer; no legacy material path remains.
func spawn_tracer(from_meters: Vector3, to_meters: Vector3, hit: bool, quality: int = 3) -> void:
	spawn_weapon(&"proj", from_meters, to_meters, hit, quality)

func spawn_artillery(from_meters: Vector3, to_meters: Vector3, quality: int = 3) -> void:
	spawn_weapon(&"laser", from_meters, to_meters, true, quality)

func set_artillery_colors(_core: Color, edge: Color) -> void:
	laser_tint = edge

func spawn_hit(pos_meters: Vector3, quality: int, layer: StringName = &"") -> void:
	if not fx_enabled:
		return
	var group := _group(0.35, "Contact")
	var tint := Color(0.25, 0.65, 1.0) if layer == &"shield" else Color(1.0, 0.42, 0.10)
	_burst(group, pos_meters / METERS_PER_UNIT, 0.9 + float(quality) * 0.08, 3, tint, 0.24, 3.5)

func spawn_boom(pos_meters: Vector3) -> void:
	if not fx_enabled:
		return
	var at := pos_meters / METERS_PER_UNIT
	var group := _group(0.85, "Reactor")
	_burst(group, at, 3.2, 2, Color(1.0, 0.28, 0.04), 0.42, 5.0)
	_burst(group, at, 5.0, 1, Color(1.0, 0.55, 0.12), 0.58, 2.0)


func present_impact(event: Dictionary, visual: Node3D, source: Vector3, contact: Vector3) -> void:
	if not fx_enabled or not event.hit or not is_instance_valid(visual):
		return
	visual.receive_impact(event,contact,source)
	var breaks:Array=event.get("breaks",[])
	if breaks.has(&"shield"):
		var shield:Node3D=visual.get("_shield_fx")
		if shield!=null:
			shield.collapse()
	if breaks.has(&"armor"):
		var group:=_group(0.85,"ArmorFracture")
		var normal:Vector3=(source-contact).normalized()
		var basis:=_basis_for(normal)
		var rng:=RandomNumberGenerator.new()
		rng.seed=int(event.get("visual_seed",1))*17+41
		var size:float=clampf(visual.fx_hull_span()*0.16,0.16,0.75)
		_burst(group,contact,size*2.4,3,Color(1.0,0.65,0.20),0.16,2.1)
		var shard_mesh:=PrismMesh.new()
		shard_mesh.size=Vector3.ONE
		for i in range(7):
			var mi:=MeshInstance3D.new()
			mi.mesh=shard_mesh
			mi.material_override=_material(DEBRIS,group,0.70,0.02)
			mi.material_override.set_shader_parameter("seed",float(i)*2.71)
			mi.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			group.node.add_child(mi)
			mi.position=contact
			mi.scale=Vector3(0.14,0.04,0.09)*size
			mi.rotation=Vector3(rng.randf()*TAU,rng.randf()*TAU,rng.randf()*TAU)
			group.moving.append({"node":mi,"origin":contact,"velocity":(normal*rng.randf_range(0.5,1.3)+basis.x*rng.randf_range(-1.0,1.0)+basis.y*rng.randf_range(-1.0,1.0))*size,
				"delay":0.02,"size":1.0,"expand":false,"rotation":mi.quaternion,"spin":Vector3(1,2,1),"drag":1.2})


func spawn_ship_destruction(visual: Node3D, tier: int = 3, seed_value: int = 1,
		velocity_meters := Vector3.ZERO) -> void:
	if not fx_enabled or not is_instance_valid(visual) or visual.hull_root == null:
		return
	stats.destruction = int(stats.destruction) + 1
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 15485863 + 71
	var group := _group(2.6, "HullDestruction")
	var snapshot:=Node3D.new()
	snapshot.name="DestroyedHull"
	# Copy geometry and attached engines, without duplicating the live shield's
	# script, atlas pool or per-hit material state into the wreck.
	for child in visual.hull_root.get_children():
		if child.name!=&"ShieldImpacts":
			snapshot.add_child(child.duplicate())
	group.node.add_child(snapshot)
	snapshot.global_transform = visual.hull_root.global_transform
	var drift := (velocity_meters / METERS_PER_UNIT).limit_length(0.9) * 0.18
	group.moving.append({"node": snapshot, "origin": snapshot.position, "velocity": drift,
		"size": 1.0, "delay": 0.0, "expand": false,
		"rotation": snapshot.quaternion, "spin": Vector3(0.025,0.012,0.07), "spin_delay": 0.20})
	# A mesh/material snapshot owns its death clock. No shared live-hull material
	# or business alive flag is changed, and the real ship labels disappear now.
	var crack_seed := float(seed_value % 997) * 0.13
	for mi in visual._all_meshes(snapshot):
		for surface in mi.mesh.get_surface_count():
			var original: Material = mi.get_active_material(surface)
			if original is ShaderMaterial:
				var material: ShaderMaterial = original.duplicate()
				material.set_shader_parameter("death_active", true)
				material.set_shader_parameter("death_seed", crack_seed)
				material.set_shader_parameter("death_center", mi.mesh.get_aabb().get_center())
				material.set_shader_parameter("death_extent", mi.mesh.get_aabb().size)
				material.set_shader_parameter("age", 0.0)
				mi.set_surface_override_material(surface, material)
				group.materials.append(material)
		if mi.material_overlay is StandardMaterial3D:
			mi.material_overlay=mi.material_overlay.duplicate()
			if not group.has("overlays"):
				group.overlays=[]
			group.overlays.append({"material":mi.material_overlay,"peak":mi.material_overlay.albedo_color.a})
	var center: Vector3 = visual.fx_center_world()
	var span: float = visual.fx_hull_span()
	var size := clampf(span * 0.40, 0.45, 2.3)
	var sites: Array = visual.fx_destruction_sites()
	var bow: Vector3 = (visual.global_basis * visual.get("_bow_local")).normalized()
	sites.sort_custom(func(a: Vector3,b: Vector3) -> bool: return (a-center).dot(bow) > (b-center).dot(bow))
	var count := 4 + clampi(tier,1,5)
	for i in range(count):
		var delay := 0.10 + float(i) * (0.043 + float(tier) * 0.003)
		var site_index := clampi(int(float(i)/float(count-1)*float(sites.size()-1)) + rng.randi_range(-1,1),0,maxi(0,sites.size()-1))
		var at: Vector3 = sites[site_index] if not sites.is_empty() else center
		at += drift * delay
		_impact_particle(group, at, size * rng.randf_range(0.55,0.90), 0.60, delay, rng, false, 3.0, 1.2)
		_burst(group, at, size * 0.52, 0, Color(1.0,0.82,0.40), 0.14, 2.5, delay)
	var main_time := 0.30 + float(tier) * 0.026
	_burst(group, center, size * 1.2, 0, Color(1.0,0.88,0.62), 0.19, 4.0, main_time)
	_burst(group, center, size * 3.3, 1, Color(1.0,0.55,0.15), 0.66, 1.0, main_time)
	for i in range(3):
		var offset := Vector3(rng.randf_range(-0.3,0.3),rng.randf_range(-0.25,0.25),rng.randf_range(-0.3,0.3))*size
		_impact_particle(group, center + offset, size * (1.4 + float(i)*0.22),
			0.86 + float(i)*0.13, main_time+float(i)*0.055, rng, false, 3.5, 1.2)
	# A restrained count of solid, tumbling plate fragments carries the silhouette
	# after the hot gas fades. They do not affect collision, loot or the simulator.
	var shard_mesh := BoxMesh.new()
	shard_mesh.size = Vector3.ONE
	for i in range(10 + tier * 2):
		var shard := MeshInstance3D.new()
		shard.mesh = shard_mesh
		shard.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := _material(DEBRIS, group, 1.8+rng.randf()*0.35, main_time)
		material.set_shader_parameter("seed", rng.randf()*100.0)
		shard.material_override = material
		group.node.add_child(shard)
		var origin: Vector3 = sites[rng.randi_range(0,sites.size()-1)] if not sites.is_empty() else center
		shard.position = origin
		shard.rotation = Vector3(rng.randf()*TAU,rng.randf()*TAU,rng.randf()*TAU)
		shard.scale = Vector3(rng.randf_range(0.04,0.11),rng.randf_range(0.012,0.025),rng.randf_range(0.02,0.06))*size
		var direction := (origin-center).normalized()
		if direction.length_squared()<0.001:
			direction=Vector3.RIGHT
		group.moving.append({"node":shard,"origin":origin,"velocity":direction*rng.randf_range(0.35,0.85)*size+drift,
			"delay":main_time,"size":1.0,"expand":false,"rotation":shard.quaternion,
			"drag":0.8,"spin":Vector3(rng.randf_range(-1.6,1.6),rng.randf_range(-1.6,1.6),rng.randf_range(-1.6,1.6))})


## Visual choreography only; gameplay owns deployment, targeting and damage.
func deploy_drone_squadron(source: Node3D, target: Node3D, model_index: int = 0) -> Node3D:
	if not fx_enabled or not is_instance_valid(source) or not is_instance_valid(target):
		return null
	var group := _group(DRONE_SQUADRON.DURATION, "DroneSquadron")
	var squadron := DRONE_SQUADRON.new()
	group.node.add_child(squadron)
	squadron.configure(self, source, target, model_index)
	group.drone_squadron = squadron
	stats.drone += 1
	return squadron


func spawn_drone_round(from: Vector3, target: Node3D) -> void:
	if not is_instance_valid(target):
		return
	var shield := float(target.ship.hp[&"shield"]) > 0.0
	var slot: int = target.fx_shield_slot(from) if shield else -1
	var contact: Vector3 = target.fx_contact_world(from, shield, Vector2.ZERO, slot)
	var flight:=from.distance_to(contact)/Profiles.DRONE_PACKET_SPEED
	var group := _group(flight+0.32, "DroneRound")
	group.weapon=&"drone"
	group.hit=true
	group.shield=shield
	group.shield_slot=slot
	group.a=from
	group.b=contact
	group.path_stage=true
	group.anchors={"target_visual":target}
	var tint:=Color(0.65,0.30,1.0)
	_drone_projectile(group, from, contact, Profiles.drone_round_scale(), tint)
	# A compact hot contact, original animated splash and directional ejecta.
	# These share the captured shield slot and arrival clock with the round.
	_bind_marker(group,_burst(group,contact,0.28,0,Color(0.85,0.65,1.0),0.085,5.0,flight),1.0)
	_bind_marker(group,_burst(group,contact,0.90,0,tint,0.24,1.15,flight),1.0)
	var splash := _eve_sprite(group,contact,0.95,DRONE_CONTACT,0.25,flight)
	splash.set_shader_parameter("atlas",IMPACT_SPLASH)
	splash.set_shader_parameter("flow_atlas",IMPACT_SPLASH_FLOW)
	splash.set_shader_parameter("energy",2.4)
	splash.set_shader_parameter("rotation",float(_serial)*1.7)
	splash.set_shader_parameter("screen_min_px",16.0)
	splash.set_shader_parameter("screen_max_scale",4.0)
	splash.set_shader_parameter("firing_axis",Vector3.ZERO)
	splash.set_shader_parameter("billboard",true)
	_bind_marker(group,group.node.get_child(group.node.get_child_count()-1),1.0)
	var direction:Vector3=(contact-from).normalized()
	var basis:=_basis_for(direction)
	for i in range(4):
		var phase:=float(i)*2.39996+float(_serial)*1.7
		var eject:=(-direction*0.38+basis.x*cos(phase)*0.65+basis.y*sin(phase)*0.55).normalized()
		_band(group,contact,contact+eject*0.09,1,0.035,tint,0.22,1.8,Vector2.ZERO,flight)
		var spark:MeshInstance3D=group.node.get_child(group.node.get_child_count()-1)
		spark.material_override.set_shader_parameter("screen_min_px",1.8)
		spark.material_override.set_shader_parameter("screen_max_scale",3.0)
		group.moving.append({"node":spark,"origin":Vector3.ZERO,"velocity":eject*(1.2+float(i)*0.24),
			"delay":flight,"size":1.0,"expand":false,"drag":3.4})
	_serial += 1
	group.path_stage=false
	group.drone_round = {"target": weakref(target), "from": from, "shield": shield,
		"slot": slot, "material": group.paths[0].material,"flight":flight,"landed":false}


func _advance_drone_round(group: Dictionary) -> void:
	var round: Dictionary = group.drone_round
	var target: Node3D = round.target.get_ref()
	if not is_instance_valid(target):
		group.node.hide()
		return
	# Launch positions stay in world space; only the receiving shield follows.
	if not round.landed and float(group.t)>=float(round.flight):
		round.landed=true
		if round.shield:
			target._ensure_shield_fx()
			target.get("_shield_fx").fire_slot(round.slot)


func clear_flights() -> void:
	for id in _flights.keys():
		cancel_missile(int(id))

func clear() -> void:
	_cannon_salvos.clear()
	clear_flights()
	if weapon_audio != null: weapon_audio.clear()
	if electronic != null: electronic.clear()
	_electronic_relations.clear()
	for ref in _electronic_visuals:
		var visual = ref.get_ref()
		if is_instance_valid(visual): visual.set_electronic_status(0.0, 0.0)
	_electronic_visuals.clear()
	for group in _fx:
		if is_instance_valid(group.node):
			group.node.queue_free()
	_fx.clear()

func _process(delta: float) -> void:
	if weapon_audio != null: weapon_audio.set_timing(paused, playback_rate)
	if not fx_enabled:
		clear()
		return
	if electronic != null: electronic.advance(0.0 if paused else delta * playback_rate)
	sync_attachments()
	for group in _fx:
		if group.has("drone_squadron"):
			group.drone_squadron.sync_display()
		if group.has("kinetic"):
			group.kinetic.scale = Vector3.ONE * float(group.blast_scale) * _screen_geometry_scale(
				group.kinetic.global_position, 2.0 * float(group.blast_scale), 52.0)
	if paused:
		# Camera changes still affect display size while simulation is frozen.
		for flight in _flights.values():
			for round in flight.rounds:
				if is_instance_valid(round.node):
					round.node.scale = Vector3.ONE * float(flight.size) * _screen_geometry_scale(round.node.global_position, 0.30 * float(flight.size), 6.0)
		return
	var dt := delta * playback_rate
	_clock += dt
	_process_cannon_salvos(dt)
	_process_flights(dt)
	for i in range(_fx.size() - 1, -1, -1):
		var group := _fx[i]
		if not is_instance_valid(group.node):
			_fx.remove_at(i)
			continue
		if group.fresh:
			group.fresh = false
		else:
			group.t = float(group.t) + dt
		if float(group.t) >= float(group.life):
			group.node.queue_free()
			_fx.remove_at(i)
			continue
		if group.has("audio_cue") and float(group.t) + 0.00001 >= float(group.audio_cue.delay):
			var cue: Dictionary = group.audio_cue
			if weapon_audio != null: weapon_audio.fire(cue.family, int(cue.tier), int(cue.seed))
			group.erase("audio_cue")
		for mat in group.materials:
			mat.set_shader_parameter("age", float(group.t) * float(group.get("material_time_scale", 1.0)))
		if group.has("kinetic"):
			group.kinetic.advance(float(group.t))
		if group.has("drone_squadron"):
			group.drone_squadron.advance(float(group.t))
		if group.has("drone_round"):
			_advance_drone_round(group)
		for overlay in group.get("overlays",[]):
			overlay.material.albedo_color.a=overlay.peak*pow(maxf(0.0,1.0-float(group.t)/0.18),2.0)
		for mover in group.moving:
			var t := maxf(0.0, float(group.t) - float(mover.delay))
			var drag: float = mover.get("drag",0.0)
			var travel := (1.0-exp(-drag*t))/drag if drag>0.0 else t
			mover.node.position = mover.origin + mover.velocity * travel
			if mover.has("spin"):
				var spin_time := maxf(0.0,t-float(mover.get("spin_delay",0.0)))
				mover.node.quaternion = Quaternion.from_euler(mover.spin * spin_time) * mover.rotation
			if bool(mover.get("expand", true)):
				mover.node.scale = Vector3.ONE * float(mover.size) * (1.0 + t * 0.8)
