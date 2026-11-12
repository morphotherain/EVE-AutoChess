extends Node3D
## 单船护盾：常驻壳 + 预先布置在壳面上的贴花锚点。
##
## 设计（用户口径）：
##   1. 贴花本来就贴在护盾上，平时不显形；
##   2. 敌方攻击特效打到附近时，把命中点**吸附**到最近的锚点上，
##      曳光线因此永远从这几个固定点打进来，不会均匀散开；
##   3. 不做「每次命中重算贴花位置 / 张角」——那是每发子弹的开销。
##      锚点位置、网格、UV 全在 setup 时建一次，命中只做一次点积比较。

const DECAL_SHADER := preload("res://scripts/visual/fx_shield_decal.gdshader")
const SHELL_SHADER := preload("res://scripts/visual/fx_shield_shell.gdshader")
const ATLAS := preload("res://assets/vfx/advent_shield_impact_atlas.png")

const PATCH_SEGMENTS := 14
## 单个贴花占护盾表面积的比例；锚点数量 = ceil(1 / coverage)
## （8% → 13 个锚点；5% → 20 个）。
const TARGET_COVERAGE := 0.08
const PATCH_ASPECT := 1.22
## 锚点数量上限：再密就只是多花顶点，战场机位下分辨不出来。
const MAX_ANCHORS := 48

## 锚点数量规则（用户 2026-10-21 定案）：
##   上下左右各 2 个 + 船艏 5 + 引擎 5 = 18；
##   船体偏长/偏宽再补 2~3 个；
##   单船硬上限 20 —— 不再按吨位递增。
const BASE_ANCHORS := 18
const HARD_MAX_ANCHORS := 20

## 运行时可改的贴花配色。所有新建锚点读取这三色。
static var decal_mid_color := Color(0.05, 0.30, 1.00, 1.0)
static var decal_high_color := Color(0.32, 0.70, 1.00, 1.0)
static var decal_core_color := Color(0.94, 0.99, 1.00, 1.0)
## 船艏 / 引擎各自的最低锚点数
const BOW_MIN := 5
const STERN_MIN := 5

## 吸附上限：来向与最近锚点夹角超过这个角度就不显示贴花。
## 目的是避免「打在背面、贴花却跳到正面」的违和。
##
## ⚠️ 实测（2026-10-21，18 锚点）：25° 会丢弃 37% 的护盾命中（7/19），太浪费。
##    18 个均匀锚点的 Voronoi 半径约 37°，所以 25° 必然砍掉一大片。
##    35° 既接近覆盖半径、又远小于 45°（不会跳到对面），定为默认。
const SNAP_MAX_ANGLE_DEG := 25.0

## 「垂直船」名单：船体高瘦、锚点要集中在上部。
## ⚠️ 不能用包围盒判（模型被归一化到同一长度，各船 AABB 几乎一样），
##    只能按船型显式登记。新增这类船时往这里加。
const VERTICAL_SHIPS := [&"myrmidon"]

var axes := Vector3.ONE
var coverage := 0.0
var anchor_count := 0
var radius_u := 0.0
var radius_v := 0.0
var lifetime := 1.15

## 开发期：可见壳，用来确认贴花贴在哪。正式效果关掉。
var show_shell := false
var _shell: MeshInstance3D = null

## 调试：把每个锚点画成小球，用来肉眼核对布点。
static var debug_markers := false
var _marker_root: Node3D = null

## 锚点：{dir(单位球方向), node, mat, t}
var _slots: Array = []
var total_hits := 0
var snap_reuse := 0
## 因超过吸附上限被丢弃的命中数（调参用）
var rejected := 0

## 按船体长宽比补点：细长的船（长轴/次轴 > 2.6）补 3，普通补 2。
func _target_count() -> int:
	var d := [axes.x, axes.y, axes.z]
	d.sort()
	var ratio := float(d[2]) / maxf(float(d[1]), 0.001)
	var n := BASE_ANCHORS
	if ratio > 2.6:
		n += 3
	elif ratio > 2.0:
		n += 2
	return mini(n, HARD_MAX_ANCHORS)

func setup(local_bounds: AABB, tier: int = 1, bow_dir: Vector3 = Vector3(0, 0, -1),
		ship_key: StringName = &"") -> void:
	_vertical_ship = VERTICAL_SHIPS.has(ship_key)
	_bow = bow_dir.normalized() if bow_dir.length_squared() > 1e-6 else Vector3(0, 0, -1)
	position = local_bounds.get_center()
	var half := local_bounds.size * 0.5
	var thin := 0
	if half.y < half[thin]: thin = 1
	if half.z < half[thin]: thin = 2
	var e := Vector3(1.10, 1.10, 1.10)
	e[thin] = 1.45
	axes = Vector3(maxf(half.x * e.x, 0.01), maxf(half.y * e.y, 0.01), maxf(half.z * e.z, 0.01))

	# 由覆盖率反推贴花张角（二分，因为大张角下平面近似不准）
	var lo := 0.02
	var hi := 1.2
	for _i in 28:
		var mid := (lo + hi) * 0.5
		if _measure_coverage(mid * PATCH_ASPECT, mid) < TARGET_COVERAGE:
			lo = mid
		else:
			hi = mid
	radius_v = (lo + hi) * 0.5
	radius_u = radius_v * PATCH_ASPECT
	coverage = _measure_coverage(radius_u, radius_v)
	# 锚点数按吨位档走（用户定案），不再由覆盖率反推；
	# 覆盖率只用来决定单个贴花的张角。
	anchor_count = _target_count()

	_build_shell()
	_build_anchors()
	print("[SHIELD] key=", ship_key, " vertical=", _vertical_ship, " axes=", axes, " anchors=", anchor_count)

func _build_shell() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 40
	mesh.rings = 20
	_shell = MeshInstance3D.new()
	_shell.name = "ShieldShell"
	_shell.mesh = mesh
	_shell.scale = axes
	_shell.visible = show_shell
	_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = SHELL_SHADER
	_shell.material_override = mat
	add_child(_shell)

## 运行时换贴花颜色，并立即同步已经存在的锚点。
func set_decal_colors(mid: Color, high: Color, core: Color = Color(0.94, 0.99, 1.0, 1.0)) -> void:
	decal_mid_color = mid
	decal_high_color = high
	decal_core_color = core
	for s in _slots:
		var mat := s.get("mat") as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter("color_mid", mid)
			mat.set_shader_parameter("color_high", high)
			mat.set_shader_parameter("color_core", core)

func set_shell_visible(on: bool) -> void:
	show_shell = on
	if _shell != null and is_instance_valid(_shell):
		_shell.visible = on

## 锚点调试小球可见性（运行时切换用；静态 debug_markers 只管「建造时要不要建」）。
func set_markers_visible(on: bool) -> void:
	if _marker_root == null:
		if not on:
			return
		_marker_root = Node3D.new()
		_marker_root.name = "AnchorMarkers"
		add_child(_marker_root)
		for i in _slots.size():
			_spawn_marker(_slots[i]["dir"], i)
	_marker_root.visible = on

## 船艏方向（hull_root 局部空间）
var _bow := Vector3(0, 0, -1)
var _vertical_ship := false

func _fib_point(i: int, n: int) -> Vector3:
	var y := 1.0 - 2.0 * (float(i) + 0.5) / float(n)
	var r := sqrt(maxf(0.0, 1.0 - y * y))
	var phi := float(i) * PI * (3.0 - sqrt(5.0))
	return Vector3(cos(phi) * r, y, sin(phi) * r)

## 从候选池里取离 target 最近的 n 个，并保证彼此至少隔开 min_sep
## （否则船艏 5 个会挤成一小撮）。
func _take_near(pool: Array, target: Vector3, n: int, min_sep: float, existing: Array = []) -> Array:
	var out: Array = []
	var cand := pool.duplicate()
	cand.sort_custom(func(a, b): return a.dot(target) > b.dot(target))
	for q in cand:
		if out.size() >= n:
			break
		var ok := true
		for r in out:
			if q.distance_to(r) < min_sep:
				ok = false
				break
		if ok:
			for r in existing:
				if q.distance_to(r) < min_sep:
					ok = false
					break
		if ok:
			out.append(q)
	return out

## 按用户口径布置锚点：
##   船艏 ≥5、引擎 ≥5，其余铺在船背/船腹；
##   垂直船（如弥尔米顿级）上半球更密，下半球往左右两侧分。
func _layout_dirs(count: int, vertical: bool) -> Array:
	var pool_n := count * 10
	var pool: Array = []
	for i in pool_n:
		pool.append(_fib_point(i, pool_n))

	var stern := -_bow
	var dirs: Array = []
	# 船艏 / 引擎各 5 个，彼此拉开
	dirs.append_array(_take_near(pool, _bow, BOW_MIN, 0.42, dirs))
	dirs.append_array(_take_near(pool, stern, STERN_MIN, 0.42, dirs))

	# 上下左右各 2 个（垂直船：上 3 / 下 1，下部让给左右）
	var up_n := 3 if vertical else 2
	var down_n := 1 if vertical else 2
	dirs.append_array(_take_near(pool, Vector3.UP, up_n, 0.35, dirs))
	dirs.append_array(_take_near(pool, Vector3.DOWN, down_n, 0.35, dirs))
	dirs.append_array(_take_near(pool, Vector3.RIGHT, 2, 0.35, dirs))
	dirs.append_array(_take_near(pool, Vector3.LEFT, 2, 0.35, dirs))

	# 其余：贪心最远点，保证在壳面上铺得开
	var guard := 0
	while dirs.size() < count and guard < count * 8:
		guard += 1
		var best := Vector3.ZERO
		var best_score := -1.0
		for q in pool:
			if dirs.has(q):
				continue
			var m := 2.0
			for d in dirs:
				m = minf(m, q.distance_to(d))
			if vertical:
				if q.y > 0.1:
					m *= 1.45                       # 上半球更密
				elif q.y < -0.1:
					m *= 0.65 + 0.55 * absf(q.x)    # 下部推向左右
			if m > best_score:
				best_score = m
				best = q
		if best_score < 0.0:
			break
		dirs.append(best)

	# 垂直船不再做额外拉伸：上面的「上 3 / 下 1」已经决定了上下分布，
	# 底部那一个点由 _take_near(DOWN) 选出，天然落在船腹正中偏一侧。
	return dirs

## 锚点一次性建好网格。
func _build_anchors() -> void:
	var vertical: bool = _vertical_ship or axes.y >= maxf(axes.x, axes.z) * 1.05
	var dirs := _layout_dirs(anchor_count, vertical)
	for i in dirs.size():
		var dir: Vector3 = dirs[i]
		var mi := MeshInstance3D.new()
		mi.name = "ShieldAnchor_%d" % i
		mi.mesh = _build_patch(dir)
		mi.visible = false
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := ShaderMaterial.new()
		mat.shader = DECAL_SHADER
		mat.set_shader_parameter("atlas", ATLAS)
		mat.set_shader_parameter("atlas_size", 8)
		mat.set_shader_parameter("intensity", 60.0)
		mat.set_shader_parameter("color_mid", decal_mid_color)
		mat.set_shader_parameter("color_high", decal_high_color)
		mat.set_shader_parameter("color_core", decal_core_color)
		mi.material_override = mat
		add_child(mi)
		_slots.append({"dir": dir, "node": mi, "mat": mat, "t": lifetime,
			"vertices":mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]})
		if debug_markers:
			_spawn_marker(dir, i)

## 命中吸附：找离来向最近的锚点，点亮它。
## 每发子弹只做 anchor_count 次点积，没有任何网格生成或浮点三角运算。
func fire(local_pos: Vector3) -> void:
	total_hits += 1
	var snapped := _snap(local_pos)
	if snapped.is_empty():
		rejected += 1
		return
	var best = snapped["slot"]
	_activate_slot(best)


func fire_slot(index:int) -> void:
	if index<0 or index>=_slots.size(): return
	total_hits+=1
	_activate_slot(_slots[index])


func _activate_slot(best:Dictionary) -> void:
	if best.t < lifetime:
		snap_reuse += 1
	best.t = 0.0
	best.node.visible = true
	best["collapse_age"]=-1.0
	best.mat.set_shader_parameter("frame",0)
	best.mat.set_shader_parameter("intensity",75.0)


func nearest_slot(local_pos:Vector3) -> int:
	var relative:=local_pos-position
	if relative.length_squared()<1e-10 or _slots.is_empty(): return -1
	var incoming:Vector3=(relative/axes).normalized()
	var chosen:=0
	for i in range(1,_slots.size()):
		if _slots[i].dir.dot(incoming)>_slots[chosen].dir.dot(incoming): chosen=i
	return chosen


func point_on_slot(index:int,spread:Vector2=Vector2.ZERO) -> Vector3:
	# Interpolate the actual prebuilt triangle, not an estimated ellipsoid.
	# The main contact is the exact center vertex; secondary warheads may land
	# at different UVs within the same visible curved patch.
	var grid:Vector2=(spread.limit_length(0.85)*0.42+Vector2.ONE)*0.5*PATCH_SEGMENTS
	var x:=clampi(int(floor(grid.x)),0,PATCH_SEGMENTS-1)
	var y:=clampi(int(floor(grid.y)),0,PATCH_SEGMENTS-1)
	var u:=grid.x-float(x)
	var v:=grid.y-float(y)
	var vertices:PackedVector3Array=_slots[index].vertices
	var a:Vector3=vertices[y*(PATCH_SEGMENTS+1)+x]
	var b:Vector3=vertices[y*(PATCH_SEGMENTS+1)+x+1]
	var c:Vector3=vertices[(y+1)*(PATCH_SEGMENTS+1)+x+1]
	var d:Vector3=vertices[(y+1)*(PATCH_SEGMENTS+1)+x]
	return position+(a*(1.0-u)+b*(u-v)+c*v if u>=v else a*(1.0-v)+c*u+d*(v-u))


func collapse() -> void:
	# A broken shield releases only its already visible patches. No new sphere,
	# ring or blue blast is created around the ship.
	for slot in _slots:
		if slot.node.visible:
			slot["collapse_age"]=0.0

## 找最近锚点；若最近的也超出 SNAP_MAX_ANGLE_DEG，返回空字典。
## 每发只做 anchor_count 次点积 + 一次 acos，没有网格生成。
func _snap(local_pos: Vector3) -> Dictionary:
	var rel := local_pos - position
	if rel.length_squared() < 1e-10 or _slots.is_empty():
		return {}
	var unit := Vector3(rel.x / axes.x, rel.y / axes.y, rel.z / axes.z).normalized()
	var best = _slots[0]
	var best_dot := -2.0
	for s in _slots:
		var d: float = s.dir.dot(unit)
		if d > best_dot:
			best_dot = d
			best = s
	if best_dot < cos(deg_to_rad(SNAP_MAX_ANGLE_DEG)):
		return {}
	return {"slot": best, "dir": best.dir}

## 给定来向，返回被吸附到的那个锚点的单位球方向。
## 火力引导靠它，曳光线终点才会落在固定点上。
## 返回吸附到的锚点方向；超出上限返回 Vector3.ZERO（调用方据此回退到船体位置）。
func anchor_dir_for(local_pos: Vector3) -> Vector3:
	var snapped := _snap(local_pos)
	if snapped.is_empty():
		return Vector3.ZERO
	return snapped["dir"]

func anchor_world_local(dir: Vector3) -> Vector3:
	return position + Vector3(dir.x * axes.x, dir.y * axes.y, dir.z * axes.z)

func _measure_coverage(ru: float, rv: float) -> float:
	var n := 20
	var du := 2.0 * ru / float(n)
	var dv := 2.0 * rv / float(n)
	var omega := 0.0
	for j in range(n):
		var v := -rv + (float(j) + 0.5) * dv
		for i in range(n):
			var u := -ru + (float(i) + 0.5) * du
			var d := 1.0 + u * u + v * v
			omega += du * dv / pow(d, 1.5)
	return omega / (4.0 * PI)

func _build_patch(unit: Vector3) -> ArrayMesh:
	var tu := Vector3.RIGHT - unit * Vector3.RIGHT.dot(unit)
	if tu.length() < 0.01:
		tu = Vector3.FORWARD - unit * Vector3.FORWARD.dot(unit)
	tu = tu.normalized()
	var tv := unit.cross(tu).normalized()
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var seg := PATCH_SEGMENTS
	for j in range(seg + 1):
		var v := -radius_v + 2.0 * radius_v * float(j) / float(seg)
		for i in range(seg + 1):
			var u := -radius_u + 2.0 * radius_u * float(i) / float(seg)
			var q := (unit + tu * u + tv * v).normalized()
			verts.append(Vector3(q.x * axes.x, q.y * axes.y, q.z * axes.z))
			normals.append(Vector3(q.x / axes.x, q.y / axes.y, q.z / axes.z).normalized())
			uvs.append(Vector2(float(i) / float(seg), float(j) / float(seg)))
	for j in range(seg):
		for i in range(seg):
			var a := j * (seg + 1) + i
			var b := a + 1
			var c := a + seg + 2
			var d := a + seg + 1
			idx.append(a); idx.append(b); idx.append(c)
			idx.append(a); idx.append(c); idx.append(d)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## 调试标记：小黄球，位置与锚点一致。
func _spawn_marker(dir: Vector3, idx: int) -> void:
	if _marker_root == null:
		_marker_root = Node3D.new()
		_marker_root.name = "AnchorMarkers"
		add_child(_marker_root)
	var mesh := SphereMesh.new()
	mesh.radius = 0.05
	mesh.height = 0.1
	mesh.radial_segments = 6
	mesh.rings = 3
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = Vector3(dir.x * axes.x, dir.y * axes.y, dir.z * axes.z)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.2)
	mat.no_depth_test = true
	mi.material_override = mat
	_marker_root.add_child(mi)

func _process(delta: float) -> void:
	advance(delta)


func advance(delta: float) -> void:
	for s in _slots:
		if not s.node.visible:
			continue
		s.t += delta
		var collapse_age:float=s.get("collapse_age",-1.0)
		if collapse_age>=0.0:
			collapse_age+=delta
			s.collapse_age=collapse_age
			if collapse_age>=0.28:
				s.node.visible=false
				continue
		var k: float = s.t / lifetime
		if k >= 1.0:
			s.node.visible = false
			continue
		s.mat.set_shader_parameter("frame", int(clampf(k, 0.0, 0.999) * 63.0))
		var env := 1.0
		if k < 0.12:
			env = lerpf(1.25, 1.0, k / 0.12)
		else:
			env = pow(1.0 - (k - 0.12) / 0.88, 1.6)
		var release:float=1.0-smoothstep(0.04,0.28,collapse_age) if collapse_age>=0.0 else 1.0
		s.mat.set_shader_parameter("intensity", 60.0 * clampf(env, 0.0, 1.4)*release)
