extends Node3D

## Strikecraft visual choreography. No HP, targeting or damage authority.
## The FX owner advances this with the same pause/rate clock as the weapons.
const CATALOG := preload("res://assets/vfx/combat/drones/drone_models.gd")
const WEAPON_PROFILES := preload("res://scripts/visual/eve_weapon_fx_profiles.gd")
const HULL := preload("res://scripts/visual/ship_hull.gdshader")
const NATIVE_HULL := preload("res://scripts/visual/fx_drone_native_hull.gdshader")
const HULL_ENERGY := preload("res://scripts/visual/fx_drone_hull_energy.gdshader")
const EXHAUST := preload("res://scripts/visual/fx_drone_exhaust.gdshader")
const TRAIL := preload("res://scripts/visual/fx_drone_wake.gdshader")
const MOTE := preload("res://scripts/visual/fx_drone_mote.gdshader")
const ENGINE_GLOW := preload("res://scripts/visual/fx_combat_burst.gdshader")
const MUZZLE := preload("res://scripts/visual/fx_drone_muzzle.gdshader")
const NOISE := preload("res://assets/vfx/combat/scourge/caustic_05c.png")
const FLASH := preload("res://assets/vfx/combat/scourge/explosionflash_01a.png")
const SPEED_FACTOR := 1.20
const RECALL := 12.8 / SPEED_FACTOR
const DOCK_TIME := 5.2 / SPEED_FACTOR
const DURATION := RECALL + DOCK_TIME + 0.8
const WAKE_LIFE := 0.32 / SPEED_FACTOR
static var _hull_materials := {}
static var _jet_mesh: CylinderMesh
static var _glow_mesh: QuadMesh
var rounds_fired := 0
var drones: Array[Dictionary] = []
var _source: WeakRef
var _target: WeakRef
var _fx: WeakRef
var _axis := Vector3.RIGHT
var _side := Vector3.BACK
var _anchor := Vector3.ZERO
var _last_age := 0.0
var _radius := 2.0
var model_index := 0
var _model: Dictionary

static func _material(model: Dictionary) -> Material:
	if _hull_materials.has(model.key):
		return _hull_materials[model.key]
	if model.native_ar:
		var mat := ShaderMaterial.new()
		mat.shader=NATIVE_HULL
		mat.set_shader_parameter("albedo_roughness",model.textures.d)
		mat.set_shader_parameter("normal_tex",model.textures.n)
		mat.set_shader_parameter("glow_tex",model.textures.e)
		_hull_materials[model.key]=mat
	else:
		var mat := ShaderMaterial.new()
		mat.shader = HULL
		for pair in [["albedo_tex", model.textures.d], ["spec_tex", model.textures.s],
			["normal_tex", model.textures.n], ["emissive_tex", model.textures.e]]:
			mat.set_shader_parameter(pair[0], pair[1])
		mat.set_shader_parameter("has_emissive", true)
		mat.set_shader_parameter("emissive_energy", 1.5)
		mat.set_shader_parameter("albedo_lift", EveShipMaterial.ALBEDO_LIFT)
		_hull_materials[model.key]=mat
	return _hull_materials[model.key]

static func create_hull(model: Dictionary) -> MeshInstance3D:
	var hull := MeshInstance3D.new()
	hull.mesh = model.mesh
	hull.material_override = _material(model)
	hull.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Reverse the OBJ export's axis conversion, then align native +Z bow to -Z.
	hull.basis = Basis(Vector3.UP, PI) * Basis(Vector3.RIGHT, PI * 0.5)
	hull.scale = Vector3.ONE * float(model.scale)
	hull.position = -(Basis(Vector3.UP, PI) * model.center) * float(model.scale)
	return hull

func _craft(index: int) -> Dictionary:
	var root := Node3D.new()
	root.name = "%sDrone%d" % [_model.name,index + 1]
	add_child(root)
	var hull := create_hull(_model)
	root.add_child(hull)
	var energy := ShaderMaterial.new()
	energy.shader = HULL_ENERGY
	energy.set_shader_parameter("glow_map", _model.textures.e)
	energy.set_shader_parameter("normal_map", _model.textures.n)
	energy.set_shader_parameter("craft_transform", hull.transform)
	energy.set_shader_parameter("seed", float(index) * 0.31)
	# The comparison and other drones retain the cached, static material.
	hull.material_override = hull.material_override.duplicate()
	hull.material_override.next_pass = energy
	if _jet_mesh == null:
		_jet_mesh = CylinderMesh.new()
		_jet_mesh.height = 1.0
		_jet_mesh.top_radius = 0.029
		_jet_mesh.bottom_radius = 0.029
		_jet_mesh.radial_segments = 24
		_jet_mesh.rings = 24
		_jet_mesh.cap_top = false
		_jet_mesh.cap_bottom = false
	var jets: Array[Dictionary] = []
	for i in range(_model.boosters.size()):
		var nozzle: Dictionary = _model.boosters[i]
		for sheath in range(2):
			var jet := MeshInstance3D.new()
			jet.mesh = _jet_mesh
			jet.quaternion = Quaternion(Vector3.UP, nozzle.direction)
			jet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var mat := ShaderMaterial.new()
			mat.shader = EXHAUST
			mat.set_shader_parameter("turbulence", NOISE)
			mat.set_shader_parameter("seed", float(index * 13 + i * 3))
			mat.set_shader_parameter("sheath", float(sheath))
			jet.material_override = mat
			root.add_child(jet)
			jets.append({"node": jet, "material": mat, "nozzle": nozzle.position,
				"direction":nozzle.direction,"radial":clampf(float(nozzle.radius)*2.0/0.021,0.45,1.3),"sheath": sheath})
	var trails: Array[Dictionary] = []
	var glows: Array[Dictionary] = []
	# The most widely separated real nozzles retain two curved world trails.
	var pair := Vector2i(0,0)
	var separation := -1.0
	for i in range(_model.boosters.size()):
		for j in range(i+1,_model.boosters.size()):
			var distance:float=_model.boosters[i].position.distance_squared_to(_model.boosters[j].position)
			if distance>separation:
				separation=distance
				pair=Vector2i(i,j)
	for i in [pair.x, pair.y]:
		if _glow_mesh == null:
			_glow_mesh=QuadMesh.new()
			_glow_mesh.size=Vector2.ONE
		var glow:=MeshInstance3D.new()
		glow.mesh=_glow_mesh
		glow.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		glow.position=_model.boosters[i].position+_model.boosters[i].direction*0.025
		glow.scale=Vector3.ONE*0.22
		glow.custom_aabb=AABB(Vector3.ONE*-2.0,Vector3.ONE*4.0)
		var glow_mat:=ShaderMaterial.new()
		glow_mat.shader=ENGINE_GLOW
		glow_mat.set_shader_parameter("shape",0)
		glow_mat.set_shader_parameter("tint",Color(0.12,0.68,1.0))
		glow_mat.set_shader_parameter("age",0.05)
		glow_mat.set_shader_parameter("lifetime",1.0)
		glow_mat.set_shader_parameter("screen_min_px",9.0)
		glow_mat.set_shader_parameter("screen_max_scale",4.0)
		glow.material_override=glow_mat
		root.add_child(glow)
		glows.append({"node":glow,"material":glow_mat})
		var trail := MeshInstance3D.new()
		trail.name = "EngineTrail%d" % i
		trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := ShaderMaterial.new()
		mat.shader = TRAIL
		mat.set_shader_parameter("width", 0.085)
		mat.set_shader_parameter("screen_min_px", 2.0)
		mat.set_shader_parameter("screen_max_scale", 3.0)
		trail.material_override = mat
		add_child(trail)
		trails.append({"node": trail, "material": mat,
			"nozzle": _model.boosters[i].position, "direction": _model.boosters[i].direction, "history": []})
	var muzzle: Array[Dictionary] = []
	var shot_scale := WEAPON_PROFILES.drone_round_scale()
	for layer in range(3):
		var flash := MeshInstance3D.new()
		flash.mesh = _glow_mesh
		flash.position = Vector3(0, 0, -0.30)
		var size: float = [1.4, 0.9, 1.9][layer] * shot_scale
		flash.scale = Vector3.ONE * size
		flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		flash.custom_aabb = AABB(Vector3.ONE * -2.0, Vector3.ONE * 4.0)
		var flash_mat := ShaderMaterial.new()
		flash_mat.shader = MUZZLE
		flash_mat.set_shader_parameter("layer", layer)
		flash_mat.set_shader_parameter("flash_atlas", FLASH)
		flash_mat.set_shader_parameter("flow_map", NOISE)
		flash_mat.set_shader_parameter("seed", float(index) * 1.37)
		flash_mat.set_shader_parameter("lifetime", [0.16, 0.13, 0.18][layer])
		flash_mat.set_shader_parameter("energy", [2.1, 1.0, 0.70][layer])
		flash_mat.set_shader_parameter("screen_min_px", clampf(size * (10.0 if layer == 2 else 14.0), 12.0, 32.0))
		flash_mat.set_shader_parameter("screen_max_scale", 8.0)
		flash_mat.set_shader_parameter("billboard", true)
		flash.material_override = flash_mat
		root.add_child(flash)
		flash.hide()
		muzzle.append({"node": flash, "material": flash_mat, "size":size})
	var particles := MultiMeshInstance3D.new()
	particles.name = "ShedEngineMotes"
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.multimesh = MultiMesh.new()
	particles.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	particles.multimesh.use_custom_data = true
	particles.multimesh.mesh = _glow_mesh
	particles.multimesh.instance_count = 48
	particles.multimesh.visible_instance_count = 0
	var particle_mat := ShaderMaterial.new()
	particle_mat.shader = MOTE
	particle_mat.set_shader_parameter("screen_min_px", 1.3)
	particle_mat.set_shader_parameter("screen_max_scale", 3.0)
	particles.material_override = particle_mat
	add_child(particles)
	return {"node": root, "jets": jets, "trails": trails, "glows":glows,"energy":energy,
		"muzzle":muzzle,"last_shot":-100.0,"muzzle_offset":Vector3.ZERO,"muzzle_direction":_axis,
		"particles":particles,"particle_material":particle_mat,"motes":[],"emission_tick":-1,
		"volleys":[],"boost":0.0,
		"delay": float(index) * 0.24,
		"launch_life": 2.10 + float(index) * 0.08,
		"phase": &"waiting", "bank": 0.0,"bank_velocity":0.0,"throttle":0.0,"speed":0.0,"forward": _axis,
		"last_pos": Vector3.ZERO, "shot_index": 0, "shots": [], "index": index}

func configure(fx: Node3D, source: Node3D, target: Node3D, selected_model: int = 0) -> void:
	model_index=posmod(selected_model,CATALOG.MODELS.size())
	_model=CATALOG.MODELS[model_index]
	_fx = weakref(fx)
	_source = weakref(source)
	_target = weakref(target)
	_anchor = target.fx_center_world()
	_axis = (_anchor - source.fx_center_world()).normalized()
	_side = _axis.cross(Vector3.UP).normalized()
	_radius = clampf(target.fx_hull_span() * 0.50 + 1.25, 3.8, 4.6)
	for i in range(3):
		var drone := _craft(i)
		var sign_value := -1.0 if i == 1 else 1.0
		var radius := _radius * (1.0 + float(i - 1) * 0.055)
		var height := float(i - 1) * 0.22
		# Two straight attack/transit lanes with wide return arcs. Gun aim never
		# changes the flight path or requests braking near the target.
		var left:=-4.5
		var right:=0.4
		var middle:=(left+right)*0.5
		var points:Array[Vector3]=[Vector3(left,0,-radius),Vector3(middle,0,-radius),Vector3(right,0,-radius)]
		for angle in [-60.0,-30.0,0.0,30.0,60.0,90.0]:
			var radians:=deg_to_rad(angle)
			points.append(Vector3(right+cos(radians)*radius,0.80*cos(radians)*cos(radians),sin(radians)*radius))
		points.append(Vector3(middle,0,radius))
		points.append(Vector3(left,0,radius))
		for angle in [120.0,150.0,180.0,210.0,240.0]:
			var radians:=deg_to_rad(angle)
			points.append(Vector3(left+cos(radians)*radius,0.60*cos(radians)*cos(radians),sin(radians)*radius))
		for j in range(points.size()):
			points[j]=Vector3(points[j].x,height+0.35+points[j].y,points[j].z*sign_value)
		var curve := Curve3D.new()
		curve.bake_interval = 0.04
		for j in range(points.size() + 1):
			var k := j % points.size()
			var previous:=points[(k + points.size() - 1) % points.size()]
			var next:=points[(k + 1) % points.size()]
			var tangent := (next - previous) / 6.0
			# Periodic cubic B-spline: position, tangent and curvature are continuous.
			curve.add_point((previous+points[k]*4.0+next)/6.0, -tangent, tangent)
		drone.curve = curve
		_build_arc_table(drone)
		drone.cruise_speed=(6.0+float(i)*0.12)*SPEED_FACTOR
		drone.loop_period=float(drone.path_length)/float(drone.cruise_speed)
		drone.entry=_loop_motion(drone,0.0)
		drone.start = _bay(source, i)
		drone.dock = drone.start
		# A rest-to-cruise launch, with enough time to reach the lane without
		# overspeed followed by a conspicuous brake just before opening fire.
		drone.launch_life=maxf(2.1/SPEED_FACTOR,2.0*drone.start.distance_to(_world(drone.entry.p))/float(drone.cruise_speed))
		drone.last_pos = drone.start
		drone.node.position = drone.start
		var initial_forward:Vector3=(_sample(drone,float(drone.delay)+0.08)-drone.start).normalized()
		drone.node.quaternion = Quaternion(Basis.looking_at(initial_forward,Vector3.UP))
		drone.forward=initial_forward
		for lap in range(3):
			for pulse in range(6):
				var at := float(drone.delay) + float(drone.launch_life) + float(lap)*float(drone.loop_period)+0.04+float(pulse)*0.075
				if at < RECALL:
					drone.shots.append(at)
					if pulse == 0: drone.volleys.append(at)
		drones.append(drone)
	advance(0.0)

func _vector(local_vector:Vector3) -> Vector3:
	return _axis*local_vector.x+Vector3.UP*local_vector.y+_side*local_vector.z

func _geometry(drone:Dictionary,q:float) -> Dictionary:
	var curve:Curve3D=drone.curve
	var segment:=mini(int(q),curve.point_count-2)
	var u:=clampf(q-float(segment),0.0,1.0)
	var p0:=curve.get_point_position(segment)
	var p1:=p0+curve.get_point_out(segment)
	var p3:=curve.get_point_position(segment+1)
	var p2:=p3+curve.get_point_in(segment+1)
	var v:=3.0*(1.0-u)*(1.0-u)*(p1-p0)+6.0*u*(1.0-u)*(p2-p1)+3.0*u*u*(p3-p2)
	var a:=6.0*(1.0-u)*(p2-2.0*p1+p0)+6.0*u*(p3-2.0*p2+p1)
	return {"v":v,"a":a}

func _build_arc_table(drone:Dictionary) -> void:
	var curve:Curve3D=drone.curve
	var table:Array[Dictionary]=[]
	var distance:=0.0
	var previous_speed:=0.0
	for k in range((curve.point_count-1)*64+1):
		var q:=float(k)/64.0
		var geometry:=_geometry(drone,q)
		var speed:float=geometry.v.length()
		if k>0:
			var midpoint:=_geometry(drone,q-0.5/64.0)
			distance+=(previous_speed+4.0*float(midpoint.v.length())+speed)/(6.0*64.0)
		previous_speed=speed
		table.append({"s":distance,"q":q,"v":1.0/speed,"a":-float(geometry.v.dot(geometry.a))/pow(speed,4.0)})
	drone.arc_table=table
	drone.path_length=distance

func _curve_point(drone:Dictionary,distance:float) -> Vector3:
	# Evaluate the actual periodic Bezier, not clamped baked interpolation at
	# the duplicated endpoint (which creates a curvature kick at each lap).
	var s:=fposmod(distance,float(drone.path_length))
	var table:Array=drone.arc_table
	var lo:=0
	var hi:=table.size()-1
	while hi-lo>1:
		var middle:int=(lo+hi)/2
		if float(table[middle].s)<=s: lo=middle
		else: hi=middle
	var a:Dictionary=table[lo]
	var b:Dictionary=table[hi]
	var span:float=b.s-a.s
	var q:=_blend(Vector3(a.q,0,0),Vector3(a.v,0,0),Vector3(a.a,0,0),
		Vector3(b.q,0,0),Vector3(b.v,0,0),Vector3(b.a,0,0),(s-float(a.s))/span,span).x
	var curve:Curve3D=drone.curve
	var segment:=mini(int(q),curve.point_count-2)
	return curve.sample(segment,clampf(q-float(segment),0.0,1.0))

static func _blend(p0:Vector3,v0:Vector3,a0:Vector3,p1:Vector3,v1:Vector3,a1:Vector3,u:float,seconds:float) -> Vector3:
	# Quintic Hermite matches position, velocity AND acceleration at both ends.
	var c1:=v0*seconds
	var c2:=a0*seconds*seconds*0.5
	var delta:=p1-p0-c1-c2
	var dv:=v1*seconds-c1-2.0*c2
	var da:=a1*seconds*seconds-2.0*c2
	var c3:=10.0*delta-4.0*dv+0.5*da
	var c4:=-15.0*delta+7.0*dv-da
	var c5:=6.0*delta-3.0*dv+0.5*da
	return p0+u*(c1+u*(c2+u*(c3+u*(c4+u*c5))))

static func _arc(u:float) -> float:
	# Outward clearance with zero position/velocity/acceleration at the joins.
	return 64.0*pow(u*(1.0-u),3.0)

func _loop_distance(drone:Dictionary,seconds:float) -> float:
	return fposmod(seconds*float(drone.cruise_speed),float(drone.path_length))

func _loop_motion(drone:Dictionary,seconds:float) -> Dictionary:
	var p:=_curve_point(drone,_loop_distance(drone,seconds))
	var before:=_curve_point(drone,_loop_distance(drone,seconds-0.035))
	var after:=_curve_point(drone,_loop_distance(drone,seconds+0.035))
	return {"p":p,"v":(after-before)/0.07,"a":(after-2.0*p+before)/(0.035*0.035)}

func _world(local_point: Vector3) -> Vector3:
	return _anchor + _axis * local_point.x + Vector3.UP * local_point.y + _side * local_point.z

func _bay(source: Node3D, index: int) -> Vector3:
	var side := _side * (-1.0 if index == 1 else 1.0)
	var from: Vector3 = source.fx_center_world() + side * (source.fx_hull_span() + 2.0) - _axis * 0.25
	# Explicit local presentation fallback: use a real hull surface as launch port.
	# This is not a claim that Sunesis/Vexor's native hangar animation is restored.
	return source.fx_contact_world(from, false) + side * 0.08 + Vector3.UP * float(index - 1) * 0.06

func _sample(drone: Dictionary, age: float) -> Vector3:
	var local_age := age - float(drone.delay)
	var launch_life: float = drone.launch_life
	if local_age <= 0.0:
		return drone.start
	if local_age < launch_life:
		var entry:Dictionary=drone.entry
		var departure := _side * (-1.0 if drone.index == 1 else 1.0)
		var u:=local_age/launch_life
		return _blend(drone.start,Vector3.ZERO,Vector3.ZERO,_world(entry.p),_vector(entry.v),_vector(entry.a),u,launch_life)+(departure*0.8+Vector3.UP*0.16)*_arc(u)
	return _world(_curve_point(drone,_loop_distance(drone,local_age-launch_life)))

func _recall_state(drone:Dictionary) -> Dictionary:
	var at:=RECALL+float(drone.delay)
	var p:=_sample(drone,at)
	var before:=_sample(drone,at-0.035)
	var after:=_sample(drone,at+0.035)
	var velocity:Vector3=(after-before)/0.07
	var acceleration:Vector3=(after-2.0*p+before)/(0.035*0.035)
	var turn:=Vector3(acceleration.x,0,acceleration.z).normalized()
	return {"p":p,"v":velocity,"a":acceleration,"arc":turn*2.6+_side*(-0.8 if drone.index==1 else 0.8)+Vector3.UP*0.6}

func _pose(drone: Dictionary, age: float) -> Vector3:
	var recall_start := RECALL + float(drone.delay)
	if age < recall_start:
		return _sample(drone, age)
	var state:Dictionary=drone.get("recall",{})
	if state.is_empty(): state=_recall_state(drone)
	var dock:Vector3=drone.dock
	var u := clampf((age - recall_start) / DOCK_TIME, 0.0, 1.0)
	return _blend(state.p,state.v,state.a,dock,Vector3.ZERO,Vector3.ZERO,u,DOCK_TIME)+state.arc*_arc(u)

func sync_display() -> void:
	var fx: Node3D = _fx.get_ref()
	if not is_instance_valid(fx):
		return
	for drone in drones:
		var scale_value: float = minf(2.25, fx._screen_geometry_scale(drone.node.global_position, 0.66, 10.0))
		drone.node.scale = Vector3.ONE * scale_value
		for trail in drone.trails:
			trail.material.set_shader_parameter("screen_compensation", fx.screen_compensation)
		for glow in drone.glows:
			glow.material.set_shader_parameter("screen_compensation",fx.screen_compensation)
		for muzzle in drone.muzzle:
			# Muzzle art has its own pixel compensation, independently of the
			# small original model's minimum-size compensation.
			muzzle.node.scale = Vector3.ONE * float(muzzle.size) / scale_value
			muzzle.material.set_shader_parameter("screen_compensation", fx.screen_compensation)
		drone.particle_material.set_shader_parameter("screen_compensation", fx.screen_compensation)

func _bank_target(drone: Dictionary, age: float, forward: Vector3, speed: float) -> float:
	if speed < 0.3: return 0.0
	# Roll leads the actual turn. The dorsal side faces the coming normal
	# acceleration, including the climbing/descending part of the broad arc.
	var at := age + 0.34
	var future := _pose(drone, at)
	var before := _pose(drone, at - 0.055)
	var after := _pose(drone, at + 0.055)
	var acceleration := (after - 2.0 * future + before) / (0.055 * 0.055)
	var right := forward.cross(Vector3.UP).normalized()
	return clampf(atan2(acceleration.dot(right), maxf(2.5, 8.5 + acceleration.y)), -1.18, 1.18)

func _boost_request(drone: Dictionary, age: float, acceleration: float) -> float:
	var requested := clampf(acceleration / 5.0, 0.0, 1.0)
	for volley in drone.volleys:
		var since: float = age - float(volley)
		var approach := smoothstep(-0.62, -0.30, since) * (1.0 - smoothstep(-0.08, 0.13, since))
		requested = maxf(requested, approach)
	return requested

func advance(age: float) -> void:
	var dt := maxf(0.0, age - _last_age)
	_last_age = age
	var source: Node3D = _source.get_ref()
	var target: Node3D = _target.get_ref()
	var fx: Node3D = _fx.get_ref()
	if not is_instance_valid(source) or not is_instance_valid(target) or not is_instance_valid(fx):
		for drone in drones:
			drone.node.hide()
			drone.particles.hide()
			for trail in drone.trails:
				trail.node.hide()
				trail.history.clear()
		return
	_anchor = _anchor.lerp(target.fx_center_world(), 1.0 - exp(-dt * 6.5))
	for drone in drones:
		var local_age := age - float(drone.delay)
		var recall_start := RECALL + float(drone.delay)
		if age+0.3>=recall_start:
			drone.dock=_bay(source,int(drone.index))
		drone.phase = &"waiting" if local_age < 0.0 else (&"launch" if local_age < float(drone.launch_life) else (&"attack" if age < recall_start else &"recall"))
		if age>=recall_start and not drone.has("recall"):
			drone.recall=_recall_state(drone)
		if age >= recall_start + DOCK_TIME:
			drone.phase = &"docked"
		drone.node.visible = local_age >= 0.0 and drone.phase != &"docked"
		var p := _pose(drone, age)
		var velocity:=(_pose(drone,age+0.035)-_pose(drone,age-0.035))/0.07
		var speed:=velocity.length()
		var forward := velocity.normalized()
		if speed<0.12:
			forward = drone.forward
		var desired_bank := _bank_target(drone, age, forward, speed)
		var error:float=drone.bank-desired_bank
		var spring:float=(float(drone.bank_velocity)+11.0*error)*dt
		var decay:=exp(-11.0*dt)
		drone.bank=(error+spring)*decay+desired_bank
		drone.bank_velocity=(float(drone.bank_velocity)-11.0*spring)*decay
		var orientation := Quaternion(Basis.looking_at(forward, Vector3.UP)) * Quaternion(Vector3.FORWARD, float(drone.bank))
		drone.node.quaternion = drone.node.quaternion.slerp(orientation, 1.0 - exp(-dt * 18.0))
		drone.node.position = p
		var acceleration:float=(speed-float(drone.speed))/maxf(dt,0.001) if dt>0.0 else 0.0
		var requested:=clampf(0.32+speed/(7.0*SPEED_FACTOR)+acceleration*0.03,0.22,1.4)
		requested*=smoothstep(0.0,0.65,speed)
		if drone.phase == &"waiting" or drone.phase == &"docked":
			requested = 0.0
		drone.throttle=lerpf(float(drone.throttle),requested,1.0-exp(-dt*9.0))
		var throttle:float=drone.throttle
		var boost_target := _boost_request(drone, age, acceleration) if drone.node.visible else 0.0
		var blend_speed := 12.0 if boost_target > float(drone.boost) else 6.0
		drone.boost = lerpf(float(drone.boost), boost_target, 1.0 - exp(-dt * blend_speed))
		var boost: float = drone.boost
		drone.speed=speed
		for jet in drone.jets:
			var stretch := (0.18 + throttle * 0.70) * (1.28 if jet.sheath == 1 else 1.0) * (1.0 + boost * 0.12)
			var radial:float=jet.radial*(2.4 if jet.sheath == 1 else 1.0) * (1.0 + boost * (0.32 if jet.sheath == 1 else 0.18))
			jet.node.scale = Vector3(radial, stretch, radial)
			jet.node.position = jet.nozzle + jet.direction * stretch * 0.5
			jet.material.set_shader_parameter("age", age)
			jet.material.set_shader_parameter("power", throttle*2.8)
			jet.material.set_shader_parameter("boost", boost)
		for glow in drone.glows:
			glow.material.set_shader_parameter("energy",throttle*5.5*(1.0+boost*0.4))
			glow.material.set_shader_parameter("tint",Color(0.12,0.68,1.0).lerp(Color(0.38,0.86,1.0),boost))
			glow.node.scale = Vector3.ONE * 0.22 * (1.0 + boost * 0.16)
		for trail in drone.trails:
			trail.material.set_shader_parameter("opacity", 0.8 + throttle * 0.75)
		while int(drone.shot_index) < drone.shots.size() and age >= float(drone.shots[drone.shot_index]):
			if drone.phase == &"attack":
				var aim: Vector3 = target.fx_center_world() - p
				if forward.dot(aim.normalized()) > 0.45:
					var local_muzzle:=Vector3(0.04 if int(drone.shot_index) % 2 == 0 else -0.04,0.0,-0.28)
					fx.spawn_drone_round(drone.node.to_global(local_muzzle), target)
					drone.last_shot = age
					drone.muzzle_offset = local_muzzle
					drone.muzzle_direction = aim.normalized()
					rounds_fired += 1
			drone.shot_index = int(drone.shot_index) + 1
		drone.forward = forward
		drone.last_pos = p
		var shot_age: float = age - float(drone.last_shot)
		drone.energy.set_shader_parameter("age", age)
		drone.energy.set_shader_parameter("power", throttle)
		drone.energy.set_shader_parameter("boost", boost)
		drone.energy.set_shader_parameter("shot_flash", exp(-shot_age * 32.0))
		for muzzle in drone.muzzle:
			muzzle.node.visible = shot_age < 0.20
			muzzle.node.position = drone.muzzle_offset
			muzzle.material.set_shader_parameter("age", shot_age)
			muzzle.material.set_shader_parameter("cycle_age", age)
			muzzle.material.set_shader_parameter("firing_axis", drone.muzzle_direction)
			if not bool(muzzle.material.get_shader_parameter("billboard")):
				muzzle.node.quaternion = Quaternion(Vector3.BACK, (drone.node.global_basis.inverse() * drone.muzzle_direction).normalized())
		_update_trails(drone, age, fx)
	sync_display()

func _update_trails(drone: Dictionary, age: float, fx: Node3D) -> void:
	for trail in drone.trails:
		var history: Array = trail.history
		if drone.node.visible:
			history.append({"p": drone.node.to_global(trail.nozzle), "t": age})
		while not history.is_empty() and age - float(history[0].t) > WAKE_LIFE:
			history.pop_front()
		trail.node.visible = history.size() > 1
		if history.size() > 1:
			var points := PackedVector3Array()
			for sample in history:
				# The wake records the actual flight path. No invented oscillation
				# or widening envelope after the straight engine jet.
				points.append(sample.p)
			trail.node.mesh = fx._polyline_mesh(points)
			trail.node.custom_aabb = trail.node.mesh.get_aabb().grow(2.0)
	_update_motes(drone, age, fx)

func _update_motes(drone: Dictionary, age: float, fx: Node3D) -> void:
	var tick := int(floor(age / 0.055))
	if drone.node.visible and float(drone.throttle) > 0.25 and tick != int(drone.emission_tick):
		drone.emission_tick = tick
		for i in range(drone.trails.size()):
			var trail: Dictionary = drone.trails[i]
			var seed := float(tick * 7 + i * 31 + int(drone.index) * 113)
			var side: Vector3 = drone.node.basis.x.normalized()
			var up: Vector3 = drone.node.basis.y.normalized()
			var backward: Vector3 = (drone.node.basis * trail.direction).normalized()
			drone.motes.append({"t":age,"p":drone.node.to_global(trail.nozzle)+backward*0.28,
				"v":backward*(0.35+0.15*sin(seed))+side*sin(seed*1.7)*0.7+up*cos(seed*2.3)*0.35,
				"length":0.035+0.05*(0.5+0.5*sin(seed*2.9)),"life":(0.24+0.12*(0.5+0.5*cos(seed)))/SPEED_FACTOR,
				"energy":float(drone.throttle)})
	while not drone.motes.is_empty() and age - float(drone.motes[0].t) > 0.38:
		drone.motes.pop_front()
	var mm: MultiMesh = drone.particles.multimesh
	var count := 0
	for mote in drone.motes:
		var seconds: float = age - float(mote.t)
		if seconds >= float(mote.life) or count >= mm.instance_count:
			continue
		var travel := (1.0 - exp(-seconds * 2.0)) * 0.5
		var basis: Basis = fx._basis_for(mote.v.normalized())
		basis = basis * Basis.from_scale(Vector3(0.025, mote.length, 1.0))
		mm.set_instance_transform(count, Transform3D(basis, mote.p + mote.v * travel))
		mm.set_instance_custom_data(count, Color(seconds / float(mote.life), mote.energy, 0, 1))
		count += 1
	mm.visible_instance_count = count
