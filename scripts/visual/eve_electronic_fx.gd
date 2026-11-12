extends Node3D

## Persistent presentation only. Simulation snapshots own all relationships and
## remaining jam time; material flow never causes or extends an EW state.
const ART := preload("res://assets/vfx/combat/electronic/electronic_assets.gd")
const SOURCE := ART.DATA
const FLOW := preload("res://scripts/visual/fx_ew_flow.gdshader")
const FIELD := preload("res://scripts/visual/fx_ew_field.gdshader")
const LINK_FLOW := preload("res://scripts/visual/fx_ew_link.gdshader")
const SUPPRESSION := preload("res://scripts/visual/eve_suppression_field.gd")
const RELEASE_TIME := 0.24
var _clock: float = 0.0
var _relations: Dictionary = {}
var _suppressed: Dictionary = {}
var _jams: Dictionary = {}
var _attempts: Array[Dictionary] = []
var _screen_compensation: bool = true
var _submeshes: Dictionary = {}
var _effect_maps: Dictionary = {}
var _suppression_link_style: int = 0


func sync_state(snapshot: Dictionary, visuals: Dictionary) -> void:
	var seen_links: Dictionary = {}
	var receivers: Dictionary = {}
	for value in snapshot.get("relations", []):
		var source_id: int = int(value.get("source_id", -1))
		var target_id: int = int(value.get("target_id", -1))
		var strength: float = clampf(float(value.get("strength", 0.0)), 0.0, 1.0)
		var source: Node3D = _visual(visuals, source_id)
		var target: Node3D = _visual(visuals, target_id)
		if source == null or target == null or strength <= 0.0:
			continue
		var key: String = "%d:%d" % [source_id, target_id]
		seen_links[key] = true
		if not _relations.has(key):
			_relations[key] = _make_link(source_id, target_id, source, target)
		var group: Dictionary = _relations[key]
		group.ending = false
		group.strength = strength
		group.source = weakref(source)
		group.target = weakref(target)
		if not receivers.has(target_id) or strength > float(receivers[target_id].strength):
			receivers[target_id] = {"source_id": source_id, "source": source,
				"target": target, "strength": strength}
	for key in _relations.keys():
		if not seen_links.has(key):
			_relations[key].ending = true
		else:
			var link: Dictionary = _relations[key]
			link.target_weight = 1.0 if int(receivers[link.target_id].source_id) == int(link.source_id) else 0.50
	for target_id in receivers:
		var receiver: Dictionary = receivers[target_id]
		if not _suppressed.has(target_id):
			_suppressed[target_id] = _make_receiver(int(target_id), receiver.target)
		var group: Dictionary = _suppressed[target_id]
		group.ending = false
		group.strength = receiver.strength
		group.source_id = receiver.source_id
		group.source = weakref(receiver.source)
		group.target = weakref(receiver.target)
	for target_id in _suppressed.keys():
		if not receivers.has(target_id):
			_suppressed[target_id].ending = true
	var seen_jams: Dictionary = {}
	for value in snapshot.get("jams", []):
		var target_id: int = int(value.get("target_id", -1))
		var remaining: float = float(value.get("remaining", 0.0))
		var target: Node3D = _visual(visuals, target_id)
		if target == null or remaining <= 0.0:
			continue
		seen_jams[target_id] = true
		if not _jams.has(target_id):
			_jams[target_id] = _make_jam(target_id, target)
		var group: Dictionary = _jams[target_id]
		group.ending = false
		group.remaining = remaining
		group.target = weakref(target)
	for target_id in _jams.keys():
		if not seen_jams.has(target_id):
			_jams[target_id].ending = true
	# A snapshot may arrive while paused; anchors do not wait for a positive dt.
	advance(0.0)


func attempt(event: Dictionary, visuals: Dictionary) -> void:
	var source_id: int = int(event.get("source_id", -1))
	var target_id: int = int(event.get("target_id", -1))
	var source: Node3D = _visual(visuals, source_id)
	var target: Node3D = _visual(visuals, target_id)
	if source == null or target == null:
		return
	if bool(event.get("success", false)) and _jams.has(target_id):
		# A refresh adds fine detail to an existing continuous field, not a flash.
		_jams[target_id].refresh = 0.55 if bool(event.get("refreshed", false)) else 0.22
		_jams[target_id].source = weakref(source)
		advance(0.0)
		return
	var group: Dictionary = _base_group("EwSourceAttempt_%d" % source_id)
	group.family = "jam"
	group.source = weakref(source)
	group.target = weakref(target)
	group.left = 0.32
	group.life = 0.32
	group.success = bool(event.get("success", false))
	group.seed = float(int(event.get("visual_seed", 0)) % 997) / 997.0
	var part: Dictionary = _native_part(group, "jam", "source", group.node)
	group.emitter = part.host
	_attempts.append(group)
	advance(0.0)


func set_screen_compensation(enabled: bool) -> void:
	_screen_compensation = enabled
	for groups in [_relations, _suppressed, _jams]:
		for group in groups.values():
			for material in group.materials:
				material.set_shader_parameter("screen_compensation", enabled)
	for group in _attempts:
		for material in group.materials:
			material.set_shader_parameter("screen_compensation", enabled)


func set_suppression_link_style(style: int) -> void:
	var next_style: int = clampi(style, 0, 1)
	if next_style == _suppression_link_style:
		return
	_suppression_link_style = next_style
	# Only an explicit comparison switch rebuilds source/link artwork. Keep
	# this Dictionary, strongest-wins receivers, ECM nodes and texture clock.
	for key in _relations.keys():
		var previous: Dictionary = _relations[key]
		var source: Node3D = _live(previous.source)
		var target: Node3D = _live(previous.target)
		if source == null or target == null:
			_erase(_relations, key)
			continue
		var replacement: Dictionary = _make_link(int(previous.source_id),
			int(previous.target_id), source, target)
		for field in ["power", "ending", "strength", "refresh", "seed",
				"layer_weight", "target_weight", "started"]:
			replacement[field] = previous[field]
		_relations[key] = replacement
		_free_group(previous)
	advance(0.0)


func advance(dt: float) -> void:
	var step: float = maxf(dt, 0.0)
	_clock += step
	for key in _relations.keys():
		var group: Dictionary = _relations[key]
		var source: Node3D = _live(group.source)
		var target: Node3D = _live(group.target)
		if source == null or target == null:
			_erase(_relations, key)
			continue
		_update_power(group, step)
		if group.ending and float(group.power) <= 0.0001:
			_erase(_relations, key)
			continue
		_place_link(group, source, target)
		_update_materials(group)
	for target_id in _suppressed.keys():
		var group: Dictionary = _suppressed[target_id]
		var target: Node3D = _live(group.target)
		var source: Node3D = _live(group.source)
		if target == null:
			_erase(_suppressed, target_id)
			continue
		if source == null:
			# Another live source can own the same strongest-wins receiver field.
			var next_strength: float = -1.0
			for relation in _relations.values():
				if int(relation.target_id) == int(target_id) and not relation.ending:
					var candidate: Node3D = _live(relation.source)
					if candidate != null and float(relation.strength) > next_strength:
						source = candidate
						next_strength = float(relation.strength)
						group.source = weakref(candidate)
						group.source_id = relation.source_id
						group.strength = relation.strength
		if source == null:
			_erase(_suppressed, target_id)
			continue
		_update_power(group, step)
		if group.ending and float(group.power) <= 0.0001:
			_erase(_suppressed, target_id)
			continue
		_place_receiver(group, source, target)
		_update_materials(group)
	for target_id in _jams.keys():
		var group: Dictionary = _jams[target_id]
		var target: Node3D = _live(group.target)
		if target == null:
			_erase(_jams, target_id)
			continue
		_update_power(group, step)
		if group.ending and float(group.power) <= 0.0001:
			_erase(_jams, target_id)
			continue
		_place_jam(group, target)
		_update_materials(group)
	for index in range(_attempts.size() - 1, -1, -1):
		var group: Dictionary = _attempts[index]
		var source: Node3D = _live(group.source)
		var target: Node3D = _live(group.target)
		group.left = float(group.left) - step
		if source == null or target == null or float(group.left) <= 0.0:
			_free_group(group)
			_attempts.remove_at(index)
			continue
		var phase: float = 1.0 - float(group.left) / float(group.life)
		group.power = sin(phase * PI) * (0.32 if group.success else 0.17)
		_place_emitter(group.emitter, source, target)
		_update_materials(group)


func active_count() -> int:
	return _relations.size() + _suppressed.size() + _jams.size() + _attempts.size()


func clear() -> void:
	for groups in [_relations, _suppressed, _jams]:
		for group in groups.values():
			_free_group(group)
		groups.clear()
	for group in _attempts:
		_free_group(group)
	_attempts.clear()


func _visual(visuals: Dictionary, id: int) -> Node3D:
	var visual: Node3D = visuals.get(id)
	if not is_instance_valid(visual) or not visual.has_method("fx_center_world"):
		return null
	return visual if _alive(visual) else null


func _live(reference: WeakRef) -> Node3D:
	var visual: Node3D = reference.get_ref()
	return visual if is_instance_valid(visual) and _alive(visual) else null


func _alive(visual: Node3D) -> bool:
	if not visual.is_inside_tree() or not visual.visible:
		return false
	var ship: Variant = visual.get("ship")
	return ship == null or bool(ship.alive)


func _base_group(label: String) -> Dictionary:
	var root: Node3D = Node3D.new()
	root.name = label
	add_child(root)
	return {"node": root, "materials": [], "entries": [], "parts": [], "power": 0.0,
		"ending": false, "strength": 0.35, "refresh": 0.0, "seed": 0.0,
		"layer_weight": 1.0, "target_weight": 1.0, "started": _clock, "family": "suppression"}


func _make_link(source_id: int, target_id: int, source: Node3D, target: Node3D) -> Dictionary:
	var group: Dictionary = _base_group("SuppressionLink_%d_%d" % [source_id, target_id])
	group.source_id = source_id
	group.target_id = target_id
	group.source = weakref(source)
	group.target = weakref(target)
	group.seed = fmod(float(source_id * 17 + target_id * 31), 97.0) / 97.0
	group.link_style = _suppression_link_style
	var family: String = "painter_link" if _suppression_link_style == 0 else "tractor_link"
	group.emitter = _native_part(group, family, "source", group.node).host
	var path: Node3D = Node3D.new()
	path.name = "NativePainterStretch" if _suppression_link_style == 0 else "NativeTractorStretch"
	group.node.add_child(path)
	group.path = path
	group.stretch_part = _native_part(group, family, "stretch", path)
	if _suppression_link_style == 0:
		group.target_part = _native_part(group, family, "target", group.node)
	else:
		# Combine the complete tractor wavefronts with only the original
		# target-painter inner subtree: its authored tree/beam4 is the quiet,
		# continuous spine through the native tractor's large texture gaps.
		group.spine_part = _native_part(group, "painter_link", "stretch", path, 65)
		group.spine_part.host.name = "NativePainterInnerSpine"
		group.spine_part.host.scale = Vector3(0.07, 0.07, 1.0)
	return group


func _make_receiver(target_id: int, target: Node3D) -> Dictionary:
	var group: Dictionary = _base_group("SuppressionReceiver_%d" % target_id)
	group.target_id = target_id
	group.target = weakref(target)
	group.seed = fmod(float(target_id * 29), 101.0) / 101.0
	var art := SUPPRESSION.new()
	group.node.add_child(art)
	art.configure_receiver(target, float(group.seed))
	group.suppression_art = art
	group.materials = art.materials
	return group


func _make_jam(target_id: int, target: Node3D) -> Dictionary:
	var group: Dictionary = _base_group("JamField_%d" % target_id)
	group.family = "jam"
	group.target_id = target_id
	group.target = weakref(target)
	group.remaining = 0.0
	group.seed = fmod(float(target_id * 43), 103.0) / 103.0
	group.target_part = _native_part(group, "jam", "target", group.node)
	group.emitter = _native_part(group, "jam", "source", group.node).host
	var path: Node3D = Node3D.new()
	path.name = "NativeUtilityEcmStretch"
	group.node.add_child(path)
	group.path = path
	group.stretch_part = _native_part(group, "jam", "stretch", path)
	group.emitter.hide()
	path.hide()
	return group


func _effect(family: String) -> Dictionary:
	if _effect_maps.has(family):
		return _effect_maps[family]
	var facts: Dictionary = SOURCE.effects[family]
	var nodes: Dictionary = {}
	for node in facts.nodes:
		nodes[int(node.id)] = node
	var meshes: Dictionary = {}
	for mesh in facts.meshBindings:
		meshes[int(mesh.meshNode)] = mesh
	var result: Dictionary = {"facts": facts, "nodes": nodes, "meshes": meshes, "family": family}
	_effect_maps[family] = result
	return result


func _native_part(group: Dictionary, family: String, role: String, parent: Node3D,
		native_root: int = -1) -> Dictionary:
	var effect: Dictionary = _effect(family)
	var host: Node3D = Node3D.new()
	host.name = "Native_%s_%s" % [family, role]
	parent.add_child(host)
	var fit: Node3D = Node3D.new()
	fit.name = "WholeAssetNormalization"
	host.add_child(fit)
	var part: Dictionary = {"host": host, "fit": fit, "modifiers": [], "body": [], "meshes": [], "nodes": {},
		"role": role, "family": family, "native_root": native_root, "native_fit": Transform3D.IDENTITY}
	_build_native_node(native_root if native_root >= 0 else int(effect.facts.roles[role]), effect, fit, group, part)
	var box: AABB = _body_bounds(part)
	if part.body.is_empty() and family == "painter_link":
		# This original destination has only two gradient flares. Fit their
		# authored frames as a group, rather than leaving native 5000-unit quads.
		box = _instances_bounds(part, part.meshes)
	if not part.body.is_empty() or (family == "painter_link" and not part.meshes.is_empty()):
		if role == "stretch":
			# EVE stretch artwork carries its native Y-axis mesh into local Z.
			# Fit the WHOLE authored subtree, preserving child transforms/UVs.
			var cross_size: float = maxf(maxf(box.size.x, box.size.y), 0.001)
			var axial_size: float = maxf(box.size.z, 0.001)
			var negative: bool = absf(box.position.z) > absf(box.end.z)
			var direction: float = -1.0 if negative else 1.0
			var origin_z: float = box.end.z / axial_size if negative else -box.position.z / axial_size
			part.native_fit = Transform3D(Basis.from_scale(Vector3(1.0 / cross_size,
				1.0 / cross_size, direction / axial_size)),
				Vector3(-box.get_center().x / cross_size, -box.get_center().y / cross_size, origin_z))
		else:
			# Flare quads have a large mostly-black authored border. Their frame
			# must not shrink the actual vortex/cone content into a tiny point.
			var extent: float = maxf(maxf(box.size.x, box.size.y), maxf(box.size.z, 0.001))
			part.native_fit = Transform3D(Basis.from_scale(Vector3.ONE / extent), -box.get_center() / extent)
	fit.transform = part.native_fit
	host.set_meta("native_part", part)
	group.parts.append(part)
	return part


func _build_native_node(id: int, effect: Dictionary, parent: Node3D,
		group: Dictionary, part: Dictionary) -> void:
	var facts: Dictionary = effect.nodes.get(id, {})
	if facts.is_empty():
		return
	var node: Node3D = Node3D.new()
	node.name = "%s_%d" % [String(facts.get("name", "NativeTransform")), id]
	parent.add_child(node)
	var translation: Vector3 = _v3(facts.get("translation", [0, 0, 0]))
	var scaling: Vector3 = _v3(facts.get("scaling", [1, 1, 1]))
	var rotation_values: Array = facts.get("rotation", [0, 0, 0, 1])
	var rotation: Quaternion = Quaternion(float(rotation_values[0]), float(rotation_values[1]),
		float(rotation_values[2]), float(rotation_values[3])).normalized()
	node.transform = Transform3D(Basis(rotation) * Basis.from_scale(scaling), translation)
	part.nodes[id] = node
	var modifier: int = int(facts.get("modifier", 0))
	if modifier == 1 or modifier == 100:
		part.modifiers.append({"node": node, "modifier": modifier, "position": translation,
			"scale": scaling, "rotation": rotation})
	var mesh_id: int = int(facts.get("mesh", -1))
	if effect.meshes.has(mesh_id):
		var mesh_facts: Dictionary = effect.meshes[mesh_id]
		for area in mesh_facts.areas:
			var material_facts: Dictionary = effect.facts.materials[str(int(area.effectNode))]
			var material: ShaderMaterial = _native_material(group, part, effect, material_facts, int(area.effectNode))
			var instance: MeshInstance3D = MeshInstance3D.new()
			instance.name = "NativeArea_%d" % int(area.areaNode)
			instance.mesh = _area_mesh(mesh_facts, area)
			instance.material_override = material
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			node.add_child(instance)
			part.meshes.append(instance)
			if material_facts.shader != "flare":
				part.body.append(instance)
		# Native module ECM's actual moire/caustic material is layered over the
		# SAME utilityc vortex surface. No substitute geometry or line mask.
		if part.family == "jam" and part.role == "target" and mesh_id == 54:
			var reference: Dictionary = _effect("jam_reference")
			var detail: MeshInstance3D = MeshInstance3D.new()
			detail.name = "NativeModuleEcmMoireArea6"
			detail.mesh = _area_mesh(mesh_facts, mesh_facts.areas[0])
			detail.material_override = _native_material(group, part, reference,
				reference.facts.materials["6"], 6)
			detail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			node.add_child(detail)
	for child in facts.get("children", []):
		_build_native_node(int(child), effect, node, group, part)


func _area_mesh(mesh_facts: Dictionary, area: Dictionary) -> ArrayMesh:
	var key: String = "%s:%d:%d" % [mesh_facts.baked, int(area.index), int(area.count)]
	if _submeshes.has(key):
		return _submeshes[key]
	var original: ArrayMesh = ART.RESOURCES[mesh_facts.baked]
	var subset: ArrayMesh = ArrayMesh.new()
	for index in range(int(area.index), mini(int(area.index) + int(area.count), original.get_surface_count())):
		subset.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, original.surface_get_arrays(index))
	_submeshes[key] = subset
	return subset


func _native_material(group: Dictionary, part: Dictionary, effect: Dictionary,
		facts: Dictionary, effect_id: int) -> ShaderMaterial:
	var material: ShaderMaterial = ShaderMaterial.new()
	var connector: bool = part.family == "painter_link" or part.family == "tractor_link"
	material.shader = FIELD if facts.shader == "flare" else (LINK_FLOW if connector else FLOW)
	var parameters: Dictionary = facts.parameters.duplicate(true)
	var bindings: Array[Dictionary] = []
	for parameter in facts.get("mutableParameters", {}):
		var parameter_id: int = int(facts.mutableParameters[parameter])
		for node in effect.nodes.values():
			if node.type != "TriValueBinding" or int(node.get("destinationObject", -1)) != parameter_id:
				continue
			var curve: Dictionary = effect.nodes.get(int(node.get("sourceObject", -1)), {})
			if not curve.has("keys"):
				# Original randconst expressions are instance constants, not
				# per-frame noise. Use the visual seed without touching combat RNG.
				if curve.get("type", "") == "Tr2CurveScalarExpression":
					var constant: float = float(group.seed)
					if String(curve.get("expression", "")).contains("? -1"):
						constant = -1.0 if constant > 0.5 else 1.0
					var values: Array = parameters.get(parameter, [1, 1, 1, 1]).duplicate()
					var attribute: String = String(node.get("destinationAttribute", "value.x"))
					var component: int = "xyzw".find(attribute.right(1))
					if component >= 0:
						values[component] = constant * float(node.get("scale", 1.0))
						parameters[parameter] = values
				continue
			bindings.append({"parameter": parameter, "attribute": node.get("destinationAttribute", "value"),
				"scale": float(node.get("scale", 1.0)), "offset": float(node.get("offset", 0.0)),
				"keys": curve["keys"]})
	if facts.shader == "flare":
		material.set_shader_parameter("gradient_map", ART.RESOURCES[facts.textures.GradientMap.baked])
	elif facts.shader == "texturecolor":
		material.set_shader_parameter("shader_mode", 2)
		material.set_shader_parameter("diffuse_1", ART.RESOURCES[facts.textures.DiffuseMap.baked])
		material.set_shader_parameter("texture_scaling", _v4(parameters.get("TextureScaling", [1, 1, 1, 1])))
		material.set_shader_parameter("texture_translation", _v4(parameters.get("TextureTranslation", [0, 0, 0, 0])))
	else:
		if connector:
			material.set_shader_parameter("shader_mode", 1 if facts.shader == "ubershadertwosided" else 0)
		material.set_shader_parameter("diffuse_1", ART.RESOURCES[facts.textures.DiffuseMap1.baked])
		material.set_shader_parameter("diffuse_2", ART.RESOURCES[facts.textures.DiffuseMap2.baked])
		material.set_shader_parameter("mask_map", ART.RESOURCES[facts.textures.MaskMap.baked])
		for index in range(1, 3):
			material.set_shader_parameter("transform_%d" % index,
				_v4(parameters.get("TextureTransform%d" % index, [0, 0, 1, 1])))
			var scroll: Vector4 = _v4(parameters.get("TextureScroll%d" % index, [0, 0, 0, 0]))
			if part.family == "tractor_link" and part.role == "stretch":
				# Preserve the original lateral swirl, reverse native suction's
				# longitudinal transport to communicate source -> suppressed ship.
				scroll.y = -scroll.y
			material.set_shader_parameter("scroll_%d" % index, scroll)
	var entry: Dictionary = {"material": material, "parameters": parameters,
		"bindings": bindings, "family": part.family, "role": part.role,
		"effect_id": effect_id, "curve_family": effect.family,
		"shader": facts.shader,
		"composite_spine": part.family == "painter_link" and int(part.native_root) == 65,
		"reference": effect.family == "jam_reference", "flare": facts.shader == "flare"}
	group.entries.append(entry)
	group.materials.append(material)
	material.set_shader_parameter("screen_compensation", _screen_compensation)
	return material


func _basis_towards(direction: Vector3, up_hint: Vector3 = Vector3.UP) -> Basis:
	var forward: Vector3 = direction.normalized()
	if forward.length_squared() < 0.00001:
		forward = Vector3.FORWARD
	var up: Vector3 = up_hint.normalized()
	if absf(forward.dot(up)) > 0.98:
		up = Vector3.FORWARD if absf(forward.z) < 0.98 else Vector3.RIGHT
	var right: Vector3 = up.cross(forward).normalized()
	return Basis(right, forward.cross(right).normalized(), forward)


func _place_link(group: Dictionary, source: Node3D, target: Node3D) -> void:
	var center: Vector3 = target.fx_center_world()
	var frame: Dictionary = source.fx_mount_frame_world(center)
	var origin: Vector3 = frame.origin
	var direction: Vector3 = (center - origin).normalized()
	var extent: float = maxf(float(target.fx_transverse_extent(direction)), 0.03)
	var end: Vector3 = center - direction * extent * 1.04
	var span: float = maxf(float(target.fx_hull_span()), 0.10)
	if group.family == "suppression":
		# Use the same exact hull query as the weapons, without the shield
		# surface. A continuing suppression link must reach the actual ship.
		end = target.fx_contact_world(origin, false)
		direction = (end - origin).normalized()
	var length: float = maxf(origin.distance_to(end), 0.01)
	if group.family == "suppression":
		var width: float = span * (0.40 if int(group.link_style) == 0 else 0.25)
		width *= _display_gain(center, span, 24.0)
		var basis: Basis = _basis_towards(direction, target.global_basis.y)
		group.path.global_transform = Transform3D(basis * Basis.from_scale(Vector3(width, width, length)), origin)
		if int(group.link_style) == 1:
			# Original curve79: native length in metres -> node34 scale.x/y.
			# It narrows short links without changing their axial endpoints.
			var part: Dictionary = group.stretch_part
			var driver: Node3D = part.nodes[34]
			var keys: Array = _effect("tractor_link").nodes[79]["keys"]
			var cross_scale: float = _sample_curve(keys, length * 1000.0)
			driver.scale = Vector3(cross_scale, cross_scale, 1.0)
		_update_native_modifiers(group.stretch_part)
		if group.has("spine_part"):
			_update_native_modifiers(group.spine_part)
		_place_emitter(group.emitter, source, target)
		if group.has("target_part"):
			var target_size: float = span * 0.70 * _display_gain(end, span, 22.0)
			var target_basis: Basis = Basis(Quaternion(Vector3.UP, -direction))
			group.target_part.host.global_transform = Transform3D(target_basis * Basis.from_scale(Vector3.ONE * target_size), end)
			_update_native_modifiers(group.target_part)
		return
	var width: float = span * 0.14 * _display_gain(center, span, 22.0)
	var basis: Basis = _basis_towards(direction, target.global_basis.y)
	group.path.global_transform = Transform3D(basis * Basis.from_scale(Vector3(width, width, length)), origin)
	_update_native_modifiers(group.stretch_part)
	_place_emitter(group.emitter, source, target)


func _place_emitter(emitter: Node3D, source: Node3D, target: Node3D) -> void:
	var center: Vector3 = target.fx_center_world()
	var frame: Dictionary = source.fx_mount_frame_world(center)
	var origin: Vector3 = frame.origin
	var span: float = maxf(float(source.fx_hull_span()), 0.10)
	var size: float = span * 0.18 * _display_gain(origin, span, 18.0)
	# Native source/destination artwork is aligned to +Y towards the source.
	var direction: Vector3 = (origin - center).normalized()
	var basis: Basis = Basis(Quaternion(Vector3.UP, direction))
	emitter.global_transform = Transform3D(basis * Basis.from_scale(Vector3.ONE * size), origin)
	_update_native_modifiers(emitter.get_meta("native_part"))


func _place_receiver(group: Dictionary, source: Node3D, target: Node3D) -> void:
	var center: Vector3 = target.fx_center_world()
	group.node.global_transform = Transform3D(target.global_basis.orthonormalized(), center)
	var span: float = maxf(float(target.fx_hull_span()), 0.10)
	group.suppression_art.place_receiver(target, source, _clock, _display_gain(center, span, 30.0))


func _place_jam(group: Dictionary, target: Node3D) -> void:
	var center: Vector3 = target.fx_center_world()
	var basis: Basis = target.global_basis.orthonormalized()
	group.node.global_transform = Transform3D(basis, center)
	var span: float = maxf(float(target.fx_hull_span()), 0.10)
	var size: float = span * 1.05 * _display_gain(center, span, 24.0)
	group.target_part.host.scale = Vector3.ONE * size
	_update_native_modifiers(group.target_part)
	var source: Node3D = _live(group.source) if group.has("source") else null
	var showing_source: bool = source != null and not group.ending
	if showing_source:
		var ship: Variant = source.get("ship")
		showing_source = ship == null or int(ship.target_id) == int(group.target_id)
	group.emitter.visible = showing_source
	group.path.visible = showing_source
	if showing_source:
		_place_link(group, source, target)


func _body_bounds(part: Dictionary) -> AABB:
	return _instances_bounds(part, part.body)


func _instances_bounds(part: Dictionary, instances: Array) -> AABB:
	var first: bool = true
	var bounds: AABB = AABB()
	for instance in instances:
		var relative: Transform3D = part.host.global_transform.affine_inverse() * instance.global_transform
		var box: AABB = instance.mesh.get_aabb()
		for index in range(8):
			var point: Vector3 = relative * box.get_endpoint(index)
			if first:
				bounds = AABB(point, Vector3.ZERO)
				first = false
			else:
				bounds = bounds.expand(point)
	return bounds


func _update_native_modifiers(part: Dictionary) -> void:
	part.fit.transform = part.native_fit
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera != null:
		for modifier in part.modifiers:
			var node: Node3D = modifier.node
			var parent: Node3D = node.get_parent()
			node.transform = Transform3D(Basis(modifier.rotation) * Basis.from_scale(modifier.scale), modifier.position)
			if int(modifier.modifier) == 1:
				var final_scale: Vector3 = modifier.scale * parent.global_basis.get_scale()
				node.global_basis = camera.global_basis * Basis.from_scale(final_scale)
			else:
				var inverse: Basis = parent.global_basis.inverse()
				var forward: Vector3 = (inverse * (camera.global_position - part.host.global_position)).normalized()
				var right: Vector3 = (inverse * camera.global_basis.x).normalized()
				var up: Vector3 = forward.cross(right).normalized()
				if up.length_squared() > 0.0001:
					right = up.cross(forward).normalized()
					node.basis = Basis(right, up, forward) * Basis(modifier.rotation) * Basis.from_scale(modifier.scale)
	# Camera-aligned original subtrees may contain large native translations.
	# Recenter the entire normalized asset, preserving every relative layer.
	if part.role != "stretch" and not part.body.is_empty():
		var bounds: AABB = _body_bounds(part)
		part.fit.position -= bounds.get_center()


func _display_gain(at: Vector3, span: float, minimum_pixels: float) -> float:
	if not _screen_compensation:
		return 1.0
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null or camera.is_position_behind(at):
		return 1.0
	var pixels: float = camera.unproject_position(at).distance_to(
		camera.unproject_position(at + camera.global_basis.x.normalized() * span))
	return clampf(minimum_pixels / maxf(pixels, 0.001), 1.0, 1.65)


func _update_power(group: Dictionary, dt: float) -> void:
	if group.ending:
		group.power = move_toward(float(group.power), 0.0, dt / RELEASE_TIME)
	else:
		group.power = lerpf(float(group.power), 1.0, 1.0 - exp(-dt / 0.075))
	group.refresh = float(group.refresh) * exp(-dt / 0.14)
	group.layer_weight = lerpf(float(group.layer_weight), float(group.target_weight), 1.0 - exp(-dt / 0.12))


func _curve_value(keys: Array, group: Dictionary, family: String) -> float:
	if keys.is_empty():
		return 1.0
	var hold_start: float = 1.0 if family == "suppression" else 0.5
	var hold_end: float = 2.0 if family == "suppression" else 9.5
	var end: float = 3.0 if family == "suppression" else 10.0
	if family == "jam_reference":
		hold_start = 0.75
		hold_end = 0.75
		end = 4.958333
	var time_scale: float = 2.0
	if family == "painter_link" or family == "tractor_link":
		# These independent native envelopes have different delayed plateaus:
		# painter inner75 reaches 1 at 1.006s; tractor77 ends at 5s, not 10s.
		# Hold each original plateau continuously while its relationship lives.
		var peak: float = -INF
		for key in keys:
			peak = maxf(peak, float(key.value))
		var found: bool = false
		for key in keys:
			if is_equal_approx(float(key.value), peak):
				if not found:
					hold_start = float(key.time)
					found = true
				hold_end = float(key.time)
		end = float(keys[-1].time)
		for key in keys:
			if float(key.time) > hold_end and is_zero_approx(float(key.value)):
				end = float(key.time)
				break
		time_scale = 1.0
	var time: float = minf((_clock - float(group.started)) * time_scale, hold_start)
	if group.ending:
		time = lerpf(hold_end, end, 1.0 - float(group.power))
	return _sample_curve(keys, time)


func _sample_curve(keys: Array, time: float) -> float:
	if keys.is_empty():
		return 1.0
	if time <= float(keys[0].time):
		return float(keys[0].value)
	for index in range(1, keys.size()):
		var b: Dictionary = keys[index]
		if time > float(b.time):
			continue
		var a: Dictionary = keys[index - 1]
		var length: float = maxf(float(b.time) - float(a.time), 0.0001)
		var u: float = clampf((time - float(a.time)) / length, 0.0, 1.0)
		if int(a.get("interpolation", 2)) == 0:
			return float(a.value)
		if int(a.get("interpolation", 2)) == 1:
			return lerpf(float(a.value), float(b.value), u)
		var u2: float = u * u
		var u3: float = u2 * u
		return (2.0 * u3 - 3.0 * u2 + 1.0) * float(a.value) + (u3 - 2.0 * u2 + u) * length * float(a.get("rightTangent", 0.0)) + (-2.0 * u3 + 3.0 * u2) * float(b.value) + (u3 - u2) * length * float(b.get("leftTangent", 0.0))
	return float(keys[-1].value)


func _update_materials(group: Dictionary) -> void:
	if group.has("suppression_art"):
		group.suppression_art.set_state(_clock, float(group.power), float(group.strength),
			float(group.layer_weight), _screen_compensation)
		return
	for entry in group.entries:
		var material: ShaderMaterial = entry.material
		var parameters: Dictionary = entry.parameters
		var fresnel: Vector4 = _v4(parameters.get("FresnelFactors", [1, 1, 0, 0]))
		var brightness: float = float(parameters.get("Brightness", 1.0))
		for binding in entry.bindings:
			var value: float = _curve_value(binding["keys"], group, entry.curve_family) * float(binding.scale) + float(binding.offset)
			if binding.parameter == "FresnelFactors" and binding.attribute == "value.y":
				fresnel.y = value
			elif binding.parameter == "Brightness":
				brightness = value
		if entry.family == "painter_link" or entry.family == "tractor_link":
			_update_link_material(entry, group, fresnel, brightness)
			continue
		var grade: Vector3 = Vector3(1.62, 0.36, 0.88)
		var energy: float = 1.05 if entry.role == "target" else 0.72
		var black_point: float = 0.0
		var content_gamma: float = 1.0
		var surface_feather: float = 0.0
		if entry.family == "jam" and not entry.flare:
			if entry.reference:
				# This native pass has Fresnel.y=.185, versus utilityc's 1.0.
				# Give its authored high-frequency moire a readable narrow peak.
				energy = 7.80
				grade = Vector3(1.65, 0.66, 1.17)
				black_point = 0.008
				content_gamma = 0.85
			elif entry.role == "target":
				energy *= 0.24 if int(entry.effect_id) == 56 else 2.40
				black_point = 0.075 if int(entry.effect_id) == 56 else 0.018
				content_gamma = 1.70 if int(entry.effect_id) == 56 else 1.10
			elif entry.role == "stretch":
				energy *= 0.35 if int(entry.effect_id) == 71 else 1.60
				black_point = 0.030
				content_gamma = 1.35
			else:
				energy *= 0.35 if int(entry.effect_id) == 7 else 1.10
				black_point = 0.045 if int(entry.effect_id) == 7 else 0.005
				content_gamma = 1.35 if int(entry.effect_id) == 7 else 0.90
		if entry.flare:
			energy *= 0.25 if entry.role == "source" else 0.38
			energy *= 0.06
		else:
			material.set_shader_parameter("fresnel_factors", fresnel)
			material.set_shader_parameter("content_black", black_point)
			material.set_shader_parameter("content_gamma", content_gamma)
			material.set_shader_parameter("surface_feather", surface_feather)
		material.set_shader_parameter("tint", _v4(parameters.get("DiffuseColor", [1, 1, 1, 1])))
		material.set_shader_parameter("brightness", brightness)
		material.set_shader_parameter("grade", grade)
		material.set_shader_parameter("energy", energy)
		material.set_shader_parameter("age", _clock)
		# Envelope holds its authored plateau, but texture time NEVER holds.
		material.set_shader_parameter("texture_time", _clock + float(group.seed) * 3.7)
		material.set_shader_parameter("power", float(group.power))
		material.set_shader_parameter("strength", float(group.strength))
		material.set_shader_parameter("layer_weight", float(group.layer_weight))
		material.set_shader_parameter("refresh", float(group.refresh))


func _update_link_material(entry: Dictionary, group: Dictionary, fresnel: Vector4, brightness: float) -> void:
	var material: ShaderMaterial = entry.material
	var authored: Vector4 = _v4(entry.parameters.get("DiffuseColor", [1, 1, 1, 1]))
	var native_peak: float = maxf(authored.x, maxf(authored.y, authored.z))
	# Local palette adaptation is explicit: multiplying native pure red by a
	# gold grade cannot create its missing green. Preserve authored HDR ratios.
	var palette: Vector3 = Vector3(1.0, 0.55, 0.13)
	var energy: float = 0.65
	var black_point: float = 0.0
	var gamma: float = 1.0
	var floor_signal: float = 0.0
	var id: int = int(entry.effect_id)
	if entry.family == "painter_link":
		if entry.role == "stretch":
			if id == 68:
				palette = Vector3(1.0, 0.82, 0.47)
				energy = 3.0
				# The floor follows the ORIGINAL beam4 mask, retaining its
				# authored narrow stem while moving caustics remain distinct.
				floor_signal = 0.07
				gamma = 0.90
			else:
				energy = 0.40
				black_point = 0.003
				gamma = 1.20
		elif entry.flare:
			energy = 0.22 if entry.role == "target" else 0.075
			if id == 43 or id == 55:
				palette = Vector3(1.0, 0.88, 0.64)
				energy = 0.55
		else:
			energy = 0.30 if id == 7 else (0.44 if id == 16 else 0.24)
	else:
		# Retain all five native tractor layers, calibrating its original
		# 30x/100x HDR tints individually so no layer floods the whole tube.
		if entry.role == "stretch":
			match id:
				38:
					energy = 0.36
					palette = Vector3(1.0, 0.57, 0.17)
					floor_signal = 0.035
					black_point = 0.025
					gamma = 1.25
				46:
					# Native caustic12 carries the large branching wavefronts.
					# Remove its low floor and retain bright separated ridges.
					energy = 0.95
					palette = Vector3(1.0, 0.82, 0.48)
					black_point = 0.025
					gamma = 1.12
				54:
					# Original 12x tiled caustics3 is the finer, cooler inner
					# structure; separate its small platinum peaks from bulk.
					energy = 0.24
					palette = Vector3(1.0, 0.96, 0.82)
					black_point = 0.018
					gamma = 1.05
				62:
					energy = 0.10
					black_point = 0.080
					gamma = 1.40
				70:
					# Two-sided original suction mesh and wavegradient form
					# the open terminal crown, not an opaque cone end cap.
					energy = 1.75
					palette = Vector3(1.0, 0.90, 0.62)
					black_point = 0.012
					gamma = 1.05
		else:
			energy = 0.28 if id == 7 else (0.25 if id == 15 else 0.18)
			if id == 15:
				palette = Vector3(1.0, 0.89, 0.64)
	if bool(entry.get("composite_spine", false)):
		energy *= 0.40
	material.set_shader_parameter("tint", Vector4(palette.x * native_peak,
		palette.y * native_peak, palette.z * native_peak, authored.w))
	material.set_shader_parameter("brightness", brightness)
	material.set_shader_parameter("grade", Vector3.ONE)
	material.set_shader_parameter("energy", energy)
	if not entry.flare:
		material.set_shader_parameter("fresnel_factors", fresnel)
		material.set_shader_parameter("content_black", black_point)
		material.set_shader_parameter("content_gamma", gamma)
		material.set_shader_parameter("minimum_signal", floor_signal)
	material.set_shader_parameter("age", _clock)
	material.set_shader_parameter("texture_time", _clock + float(group.seed) * 3.7)
	material.set_shader_parameter("power", float(group.power))
	material.set_shader_parameter("strength", float(group.strength))
	material.set_shader_parameter("layer_weight", float(group.layer_weight))
	material.set_shader_parameter("refresh", float(group.refresh))


func _v3(values: Array) -> Vector3:
	return Vector3(float(values[0]), float(values[1]), float(values[2]))


func _v4(values: Array) -> Vector4:
	return Vector4(float(values[0]), float(values[1]), float(values[2]), float(values[3]))


func _erase(groups: Dictionary, key: Variant) -> void:
	_free_group(groups[key])
	groups.erase(key)


func _free_group(group: Dictionary) -> void:
	if is_instance_valid(group.node):
		group.node.free()
