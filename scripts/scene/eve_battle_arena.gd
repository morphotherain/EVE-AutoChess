extends Node3D
class_name EveBattleArena

## EVE 自走棋 —— 战斗竞技场（3D 场景根）
##
## 职责：承载 3D 星空、舰船实例、特效层，并对外提供「世界坐标 <-> 屏幕坐标」转换。
## 无格子棋盘：所有位置都是连续空间坐标，靠距离判定，不靠格位。
##
## 变更清单（初版）：
##   - 深空环境（程序化星云 + 星点）
##   - 战术相机（俯视 35 度三分之四视角）
##   - 舰船占位体（胶囊 + 朝向指示，后续换真实模型）
##   - 射程环 / 锁定连线 / 命中特效的容器

@export var arena_radius: float = 120.0          ## 战场半径（世界单位）
@export var deploy_own_z: float = 45.0           ## 己方部署带 z（世界单位）
@export var deploy_enemy_z: float = -45.0        ## 敌方部署带 z（世界单位）

## 世界单位 → 米 的比例
##
## ⚠️ 这个值决定「部署距离」是否落在武器射程内，进而决定战斗能否收敛。
##    实测数据：世界单位 1.0 ≈ 1000 m。
##    ±45 世界单位 = 90 km，而武器射程只有 7.5~26 km
##    → 开局全部船都在射程外 → 整段接敌纯直线 → 角速度恒为 0 → 追踪机制失效。
##
##    所以部署带必须收窄到「接敌距离约等于 1.5 倍最远射程」：
##    最远射程 26 km → 期望接敌间距 ~39 km → 单侧 ±19.5 km ≈ ±19.5 世界单位。
@export var world_unit_in_meters: float = 1000.0
## 部署间距 = 该比例 x 射程中位数
##
## ⚠️ 这个值同时影响【战斗收敛】和【画面构图】，是全局最敏感的常数：
##
##   战斗侧：间距必须让「大部分船」开局就接近射程。
##           数值表射程中位数 13km，若 ratio=1.5 -> 间距 19.5km，
##           已经超出中位数射程，多数船要飞很久才能开火。
##   构图侧：间距就是画面纵深。间距越大，相机被逼得越远，舰船越小。
##           实测 ratio=1.5 时相机距离 52 单位，巡洋舰仅占画幅宽 24%（过大且拥挤），
##           且纵深 62 单位远超横向 29 单位，构图被拉成一条竖线。
##
##   取 1.15 后：间距 15km（仍在远射程船火力范围内，保留接敌过程），
##   纵深收到 48 单位，与横向 26 单位比例协调，舰船读得出轮廓。
@export var deploy_standoff_ratio: float = 1.15

## ── 背景（可替换）──────────────────────────────────────────────────
##
## 背景完全由 EveBackgroundLibrary 驱动，本场景不再硬编码任何贴图。
## 换背景有两种方式：
##   ① 编辑器里改下面这个 id（下拉选，见 _get_background_id_options）
##   ② 运行时调 arena.set_background("caldari_c06")
##
## 可用的 id 见 scripts/visual/eve_background_library.gd 的 builtin_entries()。
## 想加新背景：丢个【2:1 等距柱状】全景图进 assets/backgrounds/，
## 在库里加一条 —— 不用改本文件。
##
## ⚠️ 参考程序的背景是【天空盒】（全屏三角 + 球面反投影，见 EveBackground），
##    所以只接受等距柱状全景图。非 2:1 的普通构图图会被球面拉伸变形。
@export_enum("caldari_c07", "caldari_c02", "gallente_g03", "amarr_a03",
	"nebula_duo", "caldari_c06", "plain_deep")
## 默认用【加达里 C07】（2026-09-20 由 C02 换上）。
##
## 换的原因：用户反馈「天空盒还是太暗了」。量化后确实成立 ——
##   C02 全景均值 37.0/255、p50 仅 18（大片近黑）、明暗比 25.4×；
##   C07 均值 106.6、p50 102、明暗比 4.7×。**差近 3 倍**。
##
## ⚠️ intensity 一律保持 0.86 不变（用户明确要求「亮度不要改」）——
##    变亮【完全来自换图本身】，没有靠 intensity 补偿。
##    ⇒ 以后要更亮/更暗，优先换图，不要先动 intensity。
##
## C02 保留在库里没删（想换回去只改这一行）。C07 仍是加达里色系，
## 与 HUD 的青蓝强调色协调这一点没变。
var background_id: String = "caldari_c07"

## 背景亮度倍率（覆盖库里的默认值；-1 表示用库里的值）
@export var background_intensity_override: float = -1.0

signal ship_visual_ready(ship_id: int, node: Node3D)

var ships_layer: Node3D          ## 舰船容器
var fx_layer: Node3D             ## 特效容器（连线、爆炸）
var battle_fx: Node3D = null     ## 打击特效驱动器（阶段 D；挂在 fx_layer 下）
var range_layer: Node3D          ## 射程环容器（可开关）

var camera: Camera3D
## 相机头灯（挂在 camera 下）—— 见 _build_camera 里的说明
var camera_headlight: DirectionalLight3D = null
var background: EveBackground    ## 可替换背景渲染器
## 11 × 11 棋盘（默认隐藏 —— 用户定稿：格子只在拖动舰船时显形）
var board: EveBoard = null
## 备战席的 3D 舰船层 —— ⚠️ **2026-09-23 起停用，恒为 null**。
##
## 备战席改画 2D 立绘（EveBenchRail）之后不再需要它。保留这个成员而不删掉，
## 是为了让 battle_scene 里那些 `if arena.bench_stage != null` 守卫自然跳过；
## 恢复方法与朝向标定步骤见 _ready() 里那段注释。
##
## ⚠️ 类型刻意标 Node 而不是 EveBenchStage：本工程在无头模式下遇到
##    「class_name 全局类名跨脚本解析时还没就绪」的问题（`orion_cam` 同一条理由），
##    而这里已经不需要它的类型信息了。
##
## ⚠️ 它当年不在 ships_layer 里，也**不参与** _ship_nodes 的取景包围盒 ——
##    否则取景会把屏幕最下面一排「HUD 装饰」算进战场尺寸，镜头被越拉越远。
var bench_stage: Node = null
## 轨道相机控制器 —— 手感的唯一来源（拖拽/滚轮/复位都在它里面）
##
## ⚠️ 类型标注用 Node 而不是 EveOrbitCamera：
##    无头模式下 class_name 注册的全局类名可能在跨脚本解析时还没就绪，
##    写成 EveOrbitCamera 会报 "Could not find type"。
##    访问成员一律走下面的常量里的具体方法，语义不受影响。
var orion_cam: Node = null
var _ship_nodes: Dictionary = {}

const SHIP_SCENE_SCRIPT := preload("res://scripts/visual/eve_ship_visual.gd")
const BACKGROUND_SCRIPT := preload("res://scripts/visual/eve_background.gd")
const ORBIT_CAMERA_SCRIPT := preload("res://scripts/scene/eve_orbit_camera.gd")
const BOARD_SCRIPT := preload("res://scripts/scene/eve_board.gd")
# ⚠️ 2026-09-23 停用：备战席改画 2D 立绘后不再需要 3D 备战层。
#    脚本文件保留在磁盘上（便于回退），但这里不再 preload ——
#    不 preload 它就不会被编译，避免「一个已停用的文件」还能让整个工程编译失败。
# const BENCH_STAGE_SCRIPT := preload("res://scripts/scene/eve_bench_stage.gd")
const BATTLE_FX_SCRIPT := preload("res://scripts/visual/eve_battle_fx.gd")


func _ready() -> void:
	_build_environment()
	_build_background()
	_build_camera()
	# 背景需要相机才能做「背景板跟随」和「far 校验」，所以放在相机之后绑定
	background.bind_camera(camera)
	set_background(background_id)

	ships_layer = Node3D.new()
	ships_layer.name = "Ships"
	add_child(ships_layer)

	fx_layer = Node3D.new()
	fx_layer.name = "Effects"
	add_child(fx_layer)
	# 打击特效（阶段 D）：曳光 / 命中爆点 / 击毁爆炸。
	# ⚠️ 挂在 fx_layer【下面】而不是直接挂 arena —— 清场时能整块回收，
	#    而且语义上「特效属于特效层」这件事在场景树里看得见。
	battle_fx = BATTLE_FX_SCRIPT.new()
	battle_fx.name = "BattleFx"
	fx_layer.add_child(battle_fx)

	range_layer = Node3D.new()
	range_layer.name = "RangeRings"
	range_layer.visible = false   ## 默认关闭（用户要求）
	add_child(range_layer)

	# 11×11 棋盘（默认隐藏）
	board = BOARD_SCRIPT.new()
	board.name = "Board"
	add_child(board)
	board.configure(EveShipDatabase.CELL_METERS, world_unit_in_meters)

	# ── 备战席 3D 舰船层：2026-09-23 起【停用】────────────────────────
	# 用户口径：「把备战席的船也改为 2D 立绘卡牌吧，现在这样特别别扭，
	#             尤其是放上去的模型朝向还不一样」
	#
	# 备战席上的船现在由 HUD 侧的 EveBenchRail 在自己的 _draw() 里画
	# **官方立绘**（res://assets/ships/<id>.png），一次性解决三件事：
	#   ① 朝向 —— 官方渲染图统一机位，不存在「有的横躺有的竖着」；
	#   ② 压暗 —— HUD 画在 3D 之上，格底曾把站在格子里的 3D 船蒙黑；
	#   ③ 清晰度 —— 立绘是抠像+归一化过的图，比缩放的 3D 模型更易辨认。
	#
	# ⚠️ 这里**故意不删 bench_stage 成员**（保持 null）：eve_battle_scene.gd
	#    里还有若干 `if arena.bench_stage != null` 的守卫，保持 null 让它们
	#    自然跳过，比逐处删掉更不容易漏改（漏改的症状是启动即 Parse Error）。
	#
	# ── 想回退到 3D 备战席，按这三步 ──────────────────────────────
	#   ① 取消下面三行的注释（BENCH_STAGE_SCRIPT 的 preload 也要一起恢复）
	#   ② battle_scene 里 `hud.set_bench_fleet(...)` 换回
	#      `arena.bench_stage.update_fleet(run.bench_entries())`（外加 != null 守卫）
	#   ③ 先解决朝向：跑 tools/probe_ship_yaw.tscn，它会把 52 艘船各自
	#      的未排序 AABB 打出来 —— 长轴在 X 还是 Z 决定了要不要补 90°；
	#      剩下的船头/船尾 180° 分歧用 ship_yaw_override 表人工点掉。
	#
	# bench_stage = BENCH_STAGE_SCRIPT.new()
	# bench_stage.name = "BenchStage"
	# add_child(bench_stage)


## 镜头跟踪舰队包围盒的【焦点】，但绝不覆盖角度
##
## ⚠️⚠️ 这是第十轮最重要的一条架构约束（改动前务必读完）：
##
##   旧实现每帧做三件事：算包围盒 → 摆相机位置 → _apply_camera_angles()
##   把 rotation.x/y 强行钉回常量。第三件事是致命伤：
##   玩家拖拽转过的角度会在下一帧被抹掉 —— 表现为「转不动，一松手弹回去」。
##
##   现在把职责彻底拆开：
##     ① 本函数只负责算【焦点】（舰队包围盒中心）并喂给轨道相机；
##     ② 角度/距离完全归 EveOrbitCamera 管，本函数一个字节都不碰。
##
##   跟随做两档平滑：
##     - 焦点位置：时间常数 0.8s 的 lerp（避免单船微动导致画面抽搐）
##     - 视距基准：只在包围盒跨度变化 >6% 时更新（避免缩放基准抖动）
var _cam_focus := Vector3.ZERO
var _cam_focus_initialized := false
var _cam_last_span := Vector2.ZERO
## 视角锁定的舰船 id（-1 = 不锁，跟随整支舰队）。
## 2026-10-27 用户定案：双击某艘船 => 视角中心锁到它；双击空中 => 回默认。
var _cam_lock_id := -1
## 布阵取景的焦点是否已初始化（棋盘显形的那一刻直接落到目标，之后才 lerp）
var _board_focus_init := false
## 棋盘取景模式：0 = 我方部署区（拖放用）/ 1 = 整块棋盘（按 B 检查用）
var _board_frame_mode := 0

func _process(delta: float) -> void:
	# ★ 2026-10-27（用户：「血条堆叠」）：屏幕空间标签避让。
	# ⚠️ 放在布阵分支**之前**：布阵态要跳过，但战斗态的标签必须在
	#    下面任何 `return` 之前更新完（否则画面上会残留上一帧的偏移）。
	if board == null or not board.visible:
		_declutter_labels()
	# ── 棋盘可见时（= 布阵阶段）：取景交给棋盘，不做舰队跟随 ──────────
	# 理由：玩家此刻关心的是「格子在哪」，跟着舰队包围盒走会让 66 单位宽的
	# 棋盘被裁掉一半 —— 而看不到全盘的棋盘等于没有。
	#
	# ⚠️ 但**必须走平滑收敛**，不能硬设：
	#    棋盘是在玩家正拖着船的那一刻显形的（_begin_drag_visual），
	#    镜头这时如果「啪」地推近，手感会断，而且落点判断会瞬间错位。
	#    收敛时间常数 0.45s —— 比环绕对齐（0.25s）略慢，读起来是
	#    「镜头推过去」，不是「镜头跳过去」。
	#
	# ⚠️ 这里曾经是 `if board.visible: return`（直接不做任何取景）。
	#    后果是布阵时的取景完全继承上一场战斗的舰队包围盒 ——
	#    商店随机出的船不同，射程就不同，部署带就不同，镜头距离就不同。
	#    于是「棋盘多大」变成一个玩家无法预期、也无法复现的量（实测同一
	#    场景两次运行能差一倍）。现在它由棋盘自己决定，恒定可比。
	if board != null and board.visible:
		_apply_board_framing_smooth(delta)
		return
	# ── 开战运镜进行中（2 秒）：相机由剧本站位接管，舰队跟随【让位】──────
	# ⚠️ 必须 return 掉整段跟随：跟随每帧会 set_focus_point + 改 max_range，
	#    和运镜抢方向盘 ⇒ 观感是"镜头一边俯冲一边被拽向舰队中心"。
	# ⚠️ 这个分支绝不能漏掉「结束条件」：`step_battle_shot` 走完 2 秒会自己
	#    调 `_finish_shot()` 清标记。若那条路径断了，相机会被永远钉死在这一帧。
	if _shot_active:
		step_battle_shot(delta)
		return
	_board_focus_init = false
	var fleet := _measure_fleet()
	if not bool(fleet["ok"]):
		return
	var min_v: Vector3 = fleet["min"]
	var max_v: Vector3 = fleet["max"]

	var center: Vector3 = fleet["center"]
	# ★ 焦点朝近排偏一点 ⇒ 整支舰队在画面上抬（见 CAMERA_FOCUS_NEAR_BIAS）
	center.z += (max_v.z - min_v.z) * CAMERA_FOCUS_NEAR_BIAS
	# 取景半宽：含边距，并【强制一个最小取景范围】。
	#
	# ⚠️ 为什么要强制下限（踩坑记录）：
	#    战斗一旦接敌，双方会收拢到很小的区域（实测包围盒只剩 24 x 14 单位）。
	#    若完全按包围盒取景，镜头就会一路推近，舰船在屏幕上越放越大，
	#    最后几艘船糊满整个画面 —— 看起来像「模型太大了」，
	#    其实是「镜头贴太近了」。这是个很容易误判的现象。
	#    给一个最小取景范围，保证任何时候都能看到一块完整的战场。
	var half_x := maxf((max_v.x - min_v.x) * 0.5, CAMERA_MIN_HALF_X) * CAMERA_FIT_MARGIN
	var half_z := maxf((max_v.z - min_v.z) * 0.5, CAMERA_MIN_HALF_Z) * CAMERA_FIT_MARGIN
	var span := Vector2(half_x, half_z)

	# 视距基准：只在变化超过阈值时更新，且照样走平滑。
	# ⚠️ 阈值不能省 —— 包围盒每帧都在微动，若直接跟，zoom 会持续被拉扯，
	#    玩家刚滚出来的视距会被系统慢慢改掉，手感变「黏」。
	if _cam_last_span == Vector2.ZERO or _cam_last_span.distance_to(span) > _cam_last_span.length() * 0.06:
		_cam_last_span = span
		# ★ CAMERA_FIT_SCALE：实测「不切船」的最大推近档（见该常量顶注）
		var want_range := _fit_range(min_v, max_v)
		# 视距基准本身也做一点平滑，避免「接敌瞬间视距跳一下」
		orion_cam.set_max_range(lerpf(
				float(orion_cam.get_max_range()), maxf(20.0, want_range),
				clampf(delta / 0.6, 0.0, 1.0)))

	if not _cam_focus_initialized:
		_cam_focus = center
		_cam_focus_initialized = true
	else:
		_cam_focus = _cam_focus.lerp(center, clampf(delta / 0.8, 0.0, 1.0))

	# 视角锁定：焦点跟这艘船走，不跟舰队包围盒
	if _cam_lock_id >= 0:
		var ln = _ship_nodes.get(_cam_lock_id, null)
		if ln != null and is_instance_valid(ln):
			# 锁定用更快的时间常数（0.35s）：单船机动比舰队重心活跃
			_cam_focus = _cam_focus.lerp(ln.position, clampf(delta / 0.35, 0.0, 1.0))
			orion_cam.set_focus_point(_cam_focus)
			return
		# 锁的船没了（被击毁）=> 自动解锁，回默认跟随
		_cam_lock_id = -1

	orion_cam.set_focus_point(_cam_focus)


## 玩家是否已经手动转过视角 / 缩放过
##
## 用于「自动取景」和「手动操作」的仲裁：
## 玩家一旦动过，就不再自动重置角度（否则会和玩家的意图打架）。
func camera_user_touched() -> bool:
	if orion_cam == null:
		return false
	return absf(float(orion_cam.get("zoom")) - 1.0) > 0.0001 \
			or absf(float(orion_cam.get("yaw")) - (-0.58)) > 0.0001 \
			or absf(float(orion_cam.get("pitch")) - 0.72) > 0.0001


# ------------------------------------------------------------------ 环境

## 「通透」参数组 —— 对齐参考程序 eve-fit-lab 的渲染规则。
##
## ── 参考程序到底怎么渲染背景的（已从 app.asar 抽出 combat-webgl-renderer.js 逐行确认）
##
##   它的环境着色器【全文只有 12 行】，核心两行是：
##       vec3 color = textureLod(uEnvironment, uv, 0.0).rgb;
##       outColor   = vec4(color * uIntensity, 1.0);
##   而且 `gl.clearColor(0,0,0,0)`，intensity 默认 0.86、clamp 到 [0.1, 1.5]。
##
##   也就是说它【没有雾、没有 glow、没有 tonemap、没有 ambient】，
##   就是「采样贴图 → 乘强度 → 输出」这么直给。
##
## ── 为什么我们之前「朦」（实测折损链）
##
##   背景强度      0.86  ->  0.55          ×0.64
##   tonemap      直出  ->  FILMIC        ×0.42   （Uncharted2 曲线把 0.86 压到 0.36）
##   雾（背景板）  无    ->  0.00004       ×0.73   （8000 距离透射率仅 0.726）
##   glow         无    ->  0.35          （横向模糊，直接毁掉星点的锐利感）
##   ─────────────────────────────────────────────
##   合计只剩约 0.40 倍亮度，明暗结构被压平了一大半 —— 这就是「朦」。
##
## ── 本次改动策略
##
##   ① tonemap 改 LINEAR —— 关不掉，但 LINEAR 是最接近「直出」的一档。
##      不用 AGX/FILMIC，它们都是「为了电影感主动压对比度」的曲线。
##   ② 雾默认【关闭】。雾在太空里本来就是假的，参考程序没有是对的。
##      想开的话把 fog_density 调到 0.000008 量级（背景板透射率能到 0.94），
##      并且【必须】让球幕/背景板 disable_fog（它们的材质里已经设了）。
##   ③ glow 关掉 bloom 分量（bloom 是全局模糊，就是「朦胧」本体）。
##      glow 本身保留一点点给舰船引擎/武器提供辉光，但不许参与背景。
##   ④ ambient 能量下调 —— 0.55 会把舰船暗面整个抬起来，对比度被拉平。
##   ⑤ 背景强度上调到参考程序的 0.86 水平（见 eve_background_library.gd）。
const FOG_DENSITY_CALM := 0.000004

## ── 环境光 / 反射的总开关（2026-09-20 修「船太暗」）────────────────────
##
## ══════════════════════════════════════════════════════════════════
##  为什么船会暗到「一块黑」
## ══════════════════════════════════════════════════════════════════
##  可见背景是 EveBackground 画的**球幕**，而 Environment 的
##  background_mode 是 BG_COLOR。于是 `reflected_light_source` 取的是
##  **一块近黑纯色**（0.012,0.020,0.028）—— 也就是说：
##    · 金属件（金饰 metallic 0.80~0.95）**没有任何东西可反射** → 只能靠
##      两盏平行光的直接照明，背光面直接掉到 0；
##    · 环境光只有 0.28 且颜色很暗，等于没有补光。
##  实测（tools/probe_v3look，差分取船像素、1920×1080）：
##    现状 亮度均值 101 / **最暗的 10% 像素 = 4**（近黑，大片船体没有细节）
##
## ── 修法：让天空盒参与 IBL（Image-Based Lighting）────────────────
##  给 Environment 挂一个 Sky（材质 = 当前背景的等距柱状全景），
##  并把 ambient / reflected 两个来源都指向它。
##  ⚠️ **background_mode 保持 BG_COLOR 不变** —— 可见背景仍然由球幕画，
##     这个 Sky 只喂 PBR。所以「天空盒亮度」那条铁律一个字没动，
##     实测差值图里星空区域与改动前逐像素相同。
##
##  实测提升（同机位同船，只改这一项 + 主光 + 头灯）：
##    最暗面 p10  4 → 31（×7.8，船体暗部终于有细节）
##    亮度均值   101.4 → 112.8（×1.11 —— 不靠整体曝光糊脸，
##                              而是把原本全黑的那一片抬起来）
##  对比：单独把环境光拉到 0.95 只到 p10=10、单独把主光翻倍只到 p10=11 ——
##        都比不上「让金属有东西可反射」这一条。
##
## ── 补一次【备战席态】的验收（2026-09-20 晚，tools/probe_bench_light）──
##  ⚠️ 上面那组数是**布阵态 · 相机推近 ×2 · 舰船 ×3** 量的 —— 那一档天然更亮
##     （离镜头近、头灯打满）。但流程改成「买入 → 只进备战席」之后，
##     **备战席才是玩家停留最久的视区**（要在上面挑船、比船）。
##     所以必须单独量一次非布阵态，否则等于没验。
##
##  做法：同一次运行、同一机位（战场默认取景 96.9 单位）、同一批船
##        （备战席 5 艘）、同为非布阵态，唯一变量 = 光照方案；
##        并各出一张「隔离图」（隐藏可见球幕，画面只剩船）以便精确统计。
##  结果（船体掩膜 = 两张并集 16585 px）：
##    · 近黑像素占比   **66.6% → 0.0%**（改前三分之二的船体是纯 0/255）
##    · 同一掩膜内     p50 5 → 31（×6.2）· p75 22 → 46（×2.09）
##                     · p90 55 → 73（×1.33）· 均值 24.6 → 46.1（×1.87）
##  → 备战席态同样是「有东西可反射」，不只是布阵态好看。
##
## ⚠️ 兜底：纯色背景（plain_deep，没有全景图）时退回「颜色环境光」，
##    否则会挂一个纯黑 Sky，船比现在还暗。
## ⚠️ 2026-09-21 实测更正 —— 本常量**几乎拧不动船**
##
##   旧注释在这里写「sky 是主贡献项，提升最直接」，那是**错的**。
##   同机位同船只拧这一个旋钮，量船体掩膜内的 p50：
##       0.00 → 32.3 · 0.50 → 32.3 · **4.00 → 32.3**（8 倍，分位一动不动）
##   SSIM 也只从 1.0000 掉到 0.9993（对照：头灯 5 倍会掉到 0.9963）。
##
##   原因：`ambient_light_energy` 只驱动**漫反射**环境光，而舰船金属度实测
##   0.63~0.87（加达里）/ 0.00~0.95（艾玛），漫反射只占 (1−metallic) 那一小份；
##   天光对金属的贡献走的是**镜面**那条路 —— `reflected_light_source = SKY`，
##   而它**不吃** `ambient_light_energy`，吃的是
##   `PanoramaSkyMaterial.energy_multiplier`（当前 0.86，与背景库对齐）。
##
##   ⇒ 想调「船借天光有多亮」，改的是 Sky 材质的 energy_multiplier，
##     不是这里。本常量保留原值只是为了不要再动一次已验证的光照配比。
##
##   ⚠️ 真正把船从「一团没有细节的剪影」里救出来的是**材质侧的船壳提亮**
##     （`EveShipMaterial.ALBEDO_LIFT`）—— 纯灯光最多只能把 p50 从 32 抬到 47。
##     根因是金属的镜面 F0 = ALBEDO，深色 albedo 就是深色镜子，见那边注释。
const IBL_AMBIENT_ENERGY := 0.50     ## Sky 作环境光时的能量（**对船几乎无效**，见上）
const AMBIENT_FALLBACK := Color(0.28, 0.34, 0.40)
const AMBIENT_FALLBACK_ENERGY := 0.55
## 主光能量。0.55 → 0.95：配合 IBL 一起提，但**不**单独承担提亮
const SUN_ENERGY := 0.95
## 相机头灯能量（见 _build_camera 里那段说明）
const HEADLIGHT_ENERGY := 0.40

## 是否启用「太空尘雾」。默认 false —— 对齐参考程序。
## 想要一点大气纵深时置 true，并确保密度在 0.000004 量级。
@export var enable_space_fog: bool = false

## 后处理模式：0 = 通透（对齐参考程序）/ 1 = 氛围（保留 glow+雾）
@export_enum("通透", "氛围")
var render_mood: int = 0

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.012, 0.020, 0.028)   # 近黑深空底
	# 环境光 / 反射的**真源是天空盒**，由 _update_ibl_sky() 在 set_background
	# 里按当前背景设好（见 IBL_AMBIENT_ENERGY 那一整段说明）。
	# 这里给的只是「还没有背景时」的兜底值。
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = AMBIENT_FALLBACK
	env.ambient_light_energy = AMBIENT_FALLBACK_ENERGY
	# ⚠️ tonemap 关不掉，但 LINEAR 是最接近「直出」的一档
	#    FILMIC/AGX 都会主动压对比度，是「朦」的主要来源之一
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	# 雾：默认关闭（对齐参考程序）。太空里本来就没有大气散射。
	if enable_space_fog:
		env.fog_enabled = true
		env.fog_light_color = Color(0.10, 0.15, 0.18)
		env.fog_density = FOG_DENSITY_CALM
		env.fog_sun_scatter = 0.15
	else:
		env.fog_enabled = false

	# glow：只留一点点给舰船引擎辉光，绝对不许有 bloom（bloom = 全局模糊 = 朦胧本体）
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_bloom = 0.0          # ⚠️ 之前是 0.08，这个值就是「胧」的元凶
	env.glow_hdr_threshold = 1.0  # 只有超过 1.0 的过曝区才发光，背景够不到
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE

	# 拉一点对比度和饱和度回来，补偿 LINEAR 下的平淡。
	#
	# ⚠️ 这两个值要克制：
	#    contrast 太高会把星云的暗部压死（本来就接近黑，再压就丢结构），
	#    1.05 是「肉眼能看出更立体、但暗部仍在」的临界。
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.05
	env.adjustment_saturation = 1.08
	env.adjustment_brightness = 1.0

	# 参考程序完全没有这些 —— 保持关闭，别手贱打开
	env.ssao_enabled = false
	env.ssil_enabled = false
	env.sdfgi_enabled = false
	env.volumetric_fog_enabled = false

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)

	# 主光：冷色柔散光（模拟远处恒星）
	#
	# ⚠️ 能量 0.55 → 0.95 是 2026-09-20 与 IBL 一起改的（见 SUN_ENERGY）。
	#    单独调它没用：实测只把主光翻倍，最暗面 p10 才从 4 涨到 11 ——
	#    因为「暗」的来源是**没有环境可反射**，不是主光不够。
	var sun := DirectionalLight3D.new()
	sun.light_color = Color(0.62, 0.72, 0.80)
	sun.light_energy = SUN_ENERGY
	sun.rotation_degrees = Vector3(-42, 28, 0)
	sun.shadow_enabled = false
	add_child(sun)

	# 补光：暖色（引擎余辉方向）
	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.55, 0.40, 0.28)
	fill.light_energy = 0.18
	fill.rotation_degrees = Vector3(35, -140, 0)
	fill.shadow_enabled = false
	add_child(fill)

	# ⚠️ 原来的 _build_starfield()（900 颗程序化星点 + 星云壳层）已移除。
	#    原因：它是「假星空」，一旦接上真全景图就会和真星空打架 ——
	#    球幕上本来就有星点，再叠 900 个程序星星，近处会出现两层不同密度的星。
	#    如果以后想要程序星点，正确做法是给球幕贴图之后【再】叠，
	#    且数量降到 100 以内当「镜头附近的浮尘」，而不是当星空用。


# ------------------------------------------------------------------ 背景

func _build_background() -> void:
	background = BACKGROUND_SCRIPT.new()
	background.name = "Background"
	add_child(background)


## 换背景 —— 运行时唯一入口
##
## 返回是否成功。id 无效或贴图缺失时保持原背景不变（不黑屏、不中断战斗）。
##
## 用法：
##   arena.set_background("amarr_a03")     # 切官方艾玛星云（默认，转到哪都好看）
##   arena.set_background("gallente_g03")  # 切官方盖伦特星云（暗调、低干扰）
##   arena.set_background("caldari_c02")   # 切官方加达里星云（蓝云 + 红星云核）
##   arena.set_background("caldari_c06")   # 切参考程序同款星空
##   arena.set_background("plain_deep")    # 切纯色兜底
func set_background(id: String) -> bool:
	if background == null:
		return false
	var e := EveBackgroundLibrary.find(id)
	if e == null:
		push_warning("未知背景 id：%s" % id)
		return false
	# 允许场景侧覆盖亮度（方便在不改库的情况下单独调某张图）
	if background_intensity_override >= 0.0:
		e.intensity = background_intensity_override
	var ok := background.apply_entry(e)
	if ok:
		background_id = e.id
		# 纯色模式时把 Environment 的底色也一起设上，避免残留上一张图的色调
		if e.mode == EveBackgroundLibrary.Mode.MODE_NONE:
			_apply_plain_background_color()
		# 背景换掉 → 喂给 PBR 的 IBL 天空也要跟着换（船的反射/环境光来自它）
		_update_ibl_sky()
	return ok


## 在可用背景之间循环（调试 / 演示用）
func cycle_background(delta: int = 1) -> String:
	if background == null:
		return ""
	var id := background.cycle(delta)
	if id != "":
		background_id = id
	return id


## 当前背景 id
func current_background_id() -> String:
	return background.current_id() if background != null else ""


## 实时调背景亮度（视觉调试用，免改文件重跑）
func set_background_intensity(v: float) -> void:
	if background != null:
		background.set_intensity(v)


func _apply_plain_background_color() -> void:
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we != null and we.environment != null:
		we.environment.background_color = Color(0.012, 0.020, 0.028)


## 把「当前背景的全景图」做成 Environment 的 Sky，**只用于环境光与反射**。
##
## ══════════════════════════════════════════════════════════════════
##  ⚠️ 这不是「再画一层天空」——可见背景仍然是 EveBackground 的球幕
## ══════════════════════════════════════════════════════════════════
##  两个东西各管一头，互不覆盖：
##    · EveBackground 的球幕 → **看得见的**星云（background_mode = BG_COLOR）
##    · Environment.sky      → **喂给 PBR 的**环境贴图（反射 + 漫反射）
##  所以这条改动**没有碰「天空盒亮度」那条铁律**：实测差值图里
##  星空区域与改动前逐像素相同，变的只有舰船自己。
##
## 动机与实测数据见 IBL_AMBIENT_ENERGY 上面那一整段。
##
## ⚠️ 已知取舍（如实记录）：这里用的是**未旋转**的全景图，而球幕那边
##    会按条目自己的 sky_pitch_bias 摆天球。所以环境光/反射的「哪边亮」
##    与玩家看到的星云位置可能差几十度。
##    对漫反射（环境光）几乎无感 —— 星云是弥散的；
##    对金属的高光方向有影响，但目前没有可对照的基准，不做无依据的旋转。
##    要修的话：把 EveBackground 的天球矩阵同样作用到 Sky.sky_rotation。
func _update_ibl_sky() -> void:
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null or we.environment == null:
		return
	var env := we.environment

	var e := EveBackgroundLibrary.find(background_id)
	var path := "" if e == null else e.path
	var tex: Texture2D = null
	if not path.is_empty() and ResourceLoader.exists(path):
		tex = load(path)

	if tex == null:
		# 纯色背景 / 贴图缺失 → 退回颜色环境光。
		# ⚠️ 这里**必须**把 sky 置空：留一个没有材质的 Sky 比没有 Sky 更黑。
		env.sky = null
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = AMBIENT_FALLBACK
		env.ambient_light_energy = AMBIENT_FALLBACK_ENERGY
		return

	var pm := PanoramaSkyMaterial.new()
	pm.panorama = tex
	# 与背景库一致的 0.86 —— 让 IBL 的「亮度口径」和看得见的星云对齐
	pm.energy_multiplier = 0.86
	var sky := Sky.new()
	sky.sky_material = pm
	# 256 够用：环境光/反射都要经过粗糙度卷积，用不上 1K 的原图分辨率
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = IBL_AMBIENT_ENERGY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY


# ------------------------------------------------------------------ 相机
#
# ⚠️ 第十轮改造：从「固定俯角 + 自动取景」升级为「EVE 官方轨道相机」
#
#   手感实现全部在 scripts/scene/eve_orbit_camera.gd 里（含算法出处与
#   参数表的完整说明）。本文件只做三件事：
#     ① 建相机节点并绑定控制器
#     ② 计算焦点 / 视距基准（跟随）
#     ③ 把输入事件转给控制器
#
#   旧实现在这里有两组常量（CAMERA_PITCH_DEG / CAMERA_YAW_DEG）和一个
#   _apply_camera_angles()，它们每帧把角度钉死 —— 那是实现轨道相机的
#   直接障碍，已全部移除。角度现在只由 EveOrbitCamera 管。

## 目标画幅宽高比 1920x1080。
##
## ⚠️ 这里用常量而非取真实视口比例，是为了让「取景距离」可复现：
##    无头截图与实机窗口的 viewport 尺寸可能不同，
##    若跟着 viewport 变，调好的构图换台机器就崩。
const CAMERA_ASPECT := 1.7778

func _build_camera() -> void:
	camera = Camera3D.new()
	camera.name = "TacticalCamera"
	camera.fov = 48.0
	camera.near = 0.5
	camera.far = 20_000.0
	camera.current = true
	add_child(camera)

	# ── 相机头灯（2026-09-20 加，为了「船太暗」）──────────────────────
	# ⚠️ 为什么必须【挂在相机下】：平行光的方向就是它自己的 -Z 轴，
	#    而 Camera3D 也沿 -Z 看 —— 所以挂在相机下 = 光永远从镜头方向打过来。
	#    玩家/相机转到哪一侧，哪一侧就是亮的。
	#    这是 3/4 战术视角下唯一能保证「任何机位都看得见船体轮廓」的做法：
	#    固定方向的主光一转视角就会把船打成剪影。
	#
	# 实测（tools/probe_v3look）：单独加它，最暗面 p10 从 4 提到 15。
	# 它是**补光**不是主光 —— 能量压在 HEADLIGHT_ENERGY(0.40)，
	# 再高会把船体的明暗层次（也就是「体积感」）压平。
	camera_headlight = DirectionalLight3D.new()
	camera_headlight.name = "CameraHeadlight"
	camera_headlight.light_color = Color(0.86, 0.90, 0.96)
	camera_headlight.light_energy = HEADLIGHT_ENERGY
	camera_headlight.shadow_enabled = false
	camera.add_child(camera_headlight)

	orion_cam = ORBIT_CAMERA_SCRIPT.new()
	orion_cam.name = "OrbitCamera"
	add_child(orion_cam)
	orion_cam.bind_camera(camera)
	# 开局视距基准：先按部署带给一个保守值，frame_battlefield() 会修正
	orion_cam.set_range_from_half_extent(
		maxf(meters_to_world(arena_radius), CAMERA_MIN_HALF_X) * CAMERA_FIT_MARGIN,
		maxf(meters_to_world(
			maxf(absf(deploy_own_z), absf(deploy_enemy_z)) + 15_000.0), CAMERA_MIN_HALF_Z) * CAMERA_FIT_MARGIN)
	orion_cam.reset()
	frame_battlefield()


## 自动取景 —— 把当前【实际存在的】舰船全部装进画面
##
## ⚠️ 为什么不用固定部署带来取景：
##    战争开始后舰队会收拢，按部署带取景会导致「船挤在中间一小坨」。
##    正确做法是按【当前所有存活舰船的实际包围盒】取景。
##
## ⚠️ 本函数【不动角度】—— 只把焦点和视距基准摆正。
##    角度归 EveOrbitCamera 管；调用 reset() 才回默认机位。
##    所以「开局取景」和「玩家转过视角后继续战斗」这两件事不冲突。
##
## 参数 fit_all=false 时只做一次「按部署带的保守取景」（开局用）。
func frame_battlefield(fit_ships: bool = false) -> void:
	if orion_cam == null:
		return

	var half_x: float
	var half_z: float
	var center := Vector3.ZERO

	if fit_ships and not _ship_nodes.is_empty():
		var min_v := Vector3(INF, INF, INF)
		var max_v := Vector3(-INF, -INF, -INF)
		var any := false
		for node in _ship_nodes.values():
			if not is_instance_valid(node) or not node.visible:
				continue
			any = true
			min_v = min_v.min(node.position)
			max_v = max_v.max(node.position)
		if not any:
			frame_battlefield(false)
			return
		center = (min_v + max_v) * 0.5
		center.z += (max_v.z - min_v.z) * CAMERA_FOCUS_NEAR_BIAS
		half_x = maxf((max_v.x - min_v.x) * 0.5, CAMERA_MIN_HALF_X) * CAMERA_FIT_MARGIN
		half_z = maxf((max_v.z - min_v.z) * 0.5, CAMERA_MIN_HALF_Z) * CAMERA_FIT_MARGIN
	else:
		# 开局：按部署带取景
		half_x = maxf(meters_to_world(arena_radius), CAMERA_MIN_HALF_X) * CAMERA_FIT_MARGIN
		half_z = maxf(meters_to_world(
			maxf(absf(deploy_own_z), absf(deploy_enemy_z)) + 15_000.0), CAMERA_MIN_HALF_Z) * CAMERA_FIT_MARGIN

	# ⚠️ `_cam_last_span` 一律存**未乘 CAMERA_FIT_SCALE 的原始半跨度** ——
	#    与 `_process` 跟随、棋盘取景（那两处都不乘）同一口径，否则首帧会多触发一次重新取景。
	orion_cam.set_range_from_half_extent(
			half_x * CAMERA_FIT_SCALE, half_z * CAMERA_FIT_SCALE)
	orion_cam.set_focus_point(center)
	_cam_focus = center
	_cam_focus_initialized = true
	_cam_last_span = Vector2(half_x, half_z)


## ── 视角中心选择（2026-10-27 用户定案）──────────────────────
##
## 双击某艘船 ⇒ 视角中心锁到它（船继续机动，镜头跟着走）
## 双击空中   ⇒ 解除锁定并回默认机位
##
## ⚠️ 锁定只改**焦点**，不动角度与视距 —— 玩家自己转的角度、
##    滚出来的缩放都不被覆盖。锁的船被击毁时自动解锁。

## 锁定到指定舰船 id；id 无效 / 已不存在时返回 false
func set_camera_lock(ship_id: int) -> bool:
	if ship_id < 0 or not _ship_nodes.has(ship_id):
		_cam_lock_id = -1
		return false
	var nd = _ship_nodes.get(ship_id, null)
	if nd == null or not is_instance_valid(nd):
		_cam_lock_id = -1
		return false
	_cam_lock_id = ship_id
	# 立刻把焦点挪到船身上，再交给 _follow_camera 平滑跟随
	_cam_focus = nd.position
	return true


## 解除视角锁定（不动机位）
func clear_camera_lock() -> void:
	_cam_lock_id = -1


## 当前锁定的舰船 id（-1 = 没锁）
func camera_lock_id() -> int:
	return _cam_lock_id


## 复位相机到默认机位（双击中键 / 调试用）
func reset_camera() -> void:
	if orion_cam == null:
		return
	# 回默认机位 = 同时解除视角锁定
	_cam_lock_id = -1
	_cam_focus_initialized = false
	# 运镜中按复位：运镜立刻作废（复位的意思就是"别演了"）
	_shot_active = false
	_shot_t = 0.0
	orion_cam.reset()
	if board != null and board.visible:
		frame_board()
	else:
		frame_battlefield()


# ------------------------------------------------------------------ 打击特效（阶段 D）


## 开火线（黄色细线，一次开火亮一条 · 两端连着开火方与被打击方）
func fx_tracer(from_meters: Vector3, to_meters: Vector3, hit: bool,
		quality: int = 3) -> void:
	if battle_fx != null:
		battle_fx.spawn_tracer(from_meters, to_meters, hit, quality)


## 统一设置炮击亮痕颜色。
func set_artillery_colors(core: Color, edge: Color) -> void:
	if battle_fx != null and battle_fx.has_method("set_artillery_colors"):
		battle_fx.set_artillery_colors(core, edge)

## 统一设置所有舰船护盾贴花颜色。
func set_shield_decal_colors(mid: Color, high: Color, core: Color = Color(0.94, 0.99, 1.0, 1.0)) -> void:
	for node in _ship_nodes.values():
		if node != null and is_instance_valid(node) and node.has_method("set_shield_decal_colors"):
			node.set_shield_decal_colors(mid, high, core)

## 炮击攻击特效（长条亮痕，头部停在护盾锚点）
func fx_artillery(from_meters: Vector3, to_meters: Vector3, quality: int = 3) -> void:
	if battle_fx != null:
		battle_fx.spawn_artillery(from_meters, to_meters, quality)


## 命中爆点（`layer` = 真实受击层：shield / armor / hull）
##
## ⛔ 2026-10-27 **删除**：原来 quality ≥ 5 会给相机投喂震屏冲击量（`add_trauma`）。
##    用户裁决见 `eve_orbit_camera.gd::apply_to_camera()` 下方那段 ——
##    受击反馈不做相机单帧位移；将来要做的是「**被击中那艘船**后退 0.2~0.3 格」。
func fx_hit(pos_meters: Vector3, quality: int, layer: StringName = &"") -> void:
	if battle_fx != null:
		battle_fx.spawn_hit(pos_meters, quality, layer)


## 击毁爆炸
##
## ⛔ 2026-10-27 **删除**：原来这里给相机投喂 0.85 震屏（`add_trauma`）。
##    理由同上 —— 相机不参与打击感。
func fx_boom(pos_meters: Vector3) -> void:
	if battle_fx != null:
		battle_fx.spawn_boom(pos_meters)


## 清空特效（重开一局 / 清场时调）
func fx_clear() -> void:
	if battle_fx != null:
		battle_fx.clear()


# ------------------------------------------------------------------ 开战镜头（阶段 D / 2026-10-31 升格为 2 秒运镜）

## 开战运镜的总时长（秒）。
##
## ══════════════════════════════════════════════════════════════════
##  为什么是「运镜」而不是「一次推近」
## ══════════════════════════════════════════════════════════════════
##  玩家诉求原话：「两军对垒，是不是可以加个环绕的主将相互靠近的机制？」
##  用户定案走 B 方案（分层站位 + 30 秒主力压上），但玩家仍说"看不出来"。
##  A/B 数据也证明了这点：分层让主力在 24~30 秒多保持 4~5 km 距离，
##  而这个差距在 3/4 远视角下只有几个像素 —— **数值改了，观感没变**。
##
##  ⇒ 数值不动，改**观感**：开战这 2 秒把「两军对峙 → 主力压上」这件事
##    用镜头语言讲一遍。⛔ 不进 sim、不改任何战斗数值（TTK / 输出完全不变）。
##
## ── 三拍结构（缓动各不相同，这是"有电影感"和"镜头乱飞"的分界）──────
##
##   拍 ① 0.00 → 0.80s  拉高俯瞰   ease-out（快起慢收）
##        pitch 0.72 → 1.05，zoom ×0.74，焦点移到两军包围盒中点。
##        作用：一瞬间把"两军各站一边"这件事摆给玩家看。
##
##   拍 ② 0.80 → 1.20s  定住      （几乎静止）
##        只让俯角极缓慢回落 4%。作用：没有这 0.4 秒的停顿，
##        三拍会糊成一段连续运动，"对峙"就读不出来 —— 停顿才是重点。
##
##   拍 ③ 1.20 → 2.00s  俯冲切入   smoothstep（慢起→加速→稳收）
##        pitch → 0.64，yaw → BATTLE_VIEW_YAW(-0.34)，zoom → ×1.55。
##        作用：从高空斜切进接触线，正好在双方开火的那几秒落到近景。
##
## ── 为什么运镜期间 sim 照跑（不暂停）──────────────────────────────
##  暂停 2 秒 = 白送 2 秒给玩家看空镜，而 TTK 一点没变，纯亏。
##  照跑的话：俯瞰拍里能看到双方接近与首批曳光，俯冲拍落地即接战 —— 节奏反而更紧。
const BATTLE_SHOT_SECONDS := 2.0

## 拍 ① 结束时刻 / 拍 ② 结束时刻（秒）
const SHOT_KEY_PULL := 0.80
const SHOT_KEY_HOLD := 1.20

## 拍 ① 的拉远倍率（相对开战瞬间的 zoom）—— 小于 1 = 拉远。
##
## ⚠️ 别调太小（第一版 0.74 实测是个反例）：视距 23.9 → 32.3，
##    5 艘船在 1080p 上只剩 ~40px，**"两军"读不出来，只看见几个小点**。
##    而战场本来就这么大 —— 拉远不产生信息量，只会把船变小。
##    现在只做 10% 的轻微后撤，把"拉出空间感"这件事交给俯角（见 SHOT_PITCH_WIDE）。
const SHOT_PULLBACK_ZOOM := 0.90
## 拍 ① 的俯瞰俯角（弧度）。
##
## 默认 0.72（41°）是玩家平时看的 3/4 视角。抬到 0.95（54°）的意义：
## 视线更垂直 ⇒ 两军在**纵深方向**的分布被摊开在画面上（而不是叠在一起），
## "各站一边"这件事才读得出来。再往上抬（1.05 试过）船会变成顶视图、像棋子。
const SHOT_PITCH_WIDE := 0.95
## 拍 ③ 的收尾俯角 —— 比默认 0.72 **更低**（更贴地平视），压迫感来自这里
const SHOT_PITCH_PUSH := 0.64

## 玩家输入可以打断运镜的最早时刻（秒）。
##
## ⚠️ 不是 0 —— 开战那一下本身就是左键按下（点"开战"按钮），
##    0 会让运镜被同一个点击当场掐死（见 handle_camera_input 的说明）。
const SHOT_SKIP_AFTER := 0.15

## 开战取景的推近倍率（拍 ③ 的终点）。
##
## ══════════════════════════════════════════════════════════════════
##  为什么需要一个「开战推近」
## ══════════════════════════════════════════════════════════════════
##  准备阶段玩家在用 3/4 远视角看清整片战场；一旦开打，
##  交战会收拢到接敌线附近，那时候再用准备阶段的视距看，
##  船只有几个像素 —— 「打起来了」这件事在画面上是没发生的。
##
##  ── 取值依据（不是拍的）────────────────────────────────────────────
##  准备阶段视距基准走 `frame_battlefield()`：按部署带算，半跨约 40~60 世界单位。
##  而实测接敌后双方包围盒只剩 24 × 14 单位（见 `_process` 里
##  `CAMERA_MIN_HALF_X/Z` 那段踩坑记录）。
##  1.55 倍是「明显推近、但不至于让船飞出画幅」的档位 ——
##  它同时保证了 `_process` 的舰队跟随仍有意义（跟随会在此基础上再收一点）。
##
##  ⚠️ 单独改这个数不好用：它和 `_process` 里的跟随取景是叠加的。
##     想看「推近多少才够」时，看最终 `orion_cam.get_distance()`，
##     不要看这里的倍率。
const BATTLE_VIEW_ZOOM := 1.55

## 开战时的偏航角（弧度）—— 一个比默认 -0.58 更有「斜着切进去」动感的方位。
##
## ⚠️ 刻意**不等于** DEFAULT_YAW：如果开战那一刻转到的角度和玩家
##    随手复位后的角度一样，这次转镜头就等于没发生。
##    也不能转太多（超过 ±0.35 会让构图明显偏向一侧、远端舰船被挤出画幅）。
const BATTLE_VIEW_YAW := -0.34

## 运镜是否在进行中
var _shot_active := false
## 运镜已走时长（秒）
var _shot_t := 0.0

## 运镜起点（开战那一瞬间的实况位姿 —— 从玩家自己滚/转出来的角度起步，不硬跳）
var _shot_yaw0 := EveOrbitCamera.DEFAULT_YAW
var _shot_pitch0 := EveOrbitCamera.DEFAULT_PITCH
var _shot_zoom0 := EveOrbitCamera.DEFAULT_ZOOM
var _shot_focus0 := Vector3.ZERO
## 运镜中段的两个派生终点
var _shot_zoom_wide := EveOrbitCamera.DEFAULT_ZOOM
var _shot_zoom_end := EveOrbitCamera.DEFAULT_ZOOM
## 对峙焦点（两军包围盒中点）—— 运镜全程焦点钉在它上面，不跟单船抖
var _shot_focus_end := Vector3.ZERO


## 开战运镜：从当前机位开始，2 秒走完三拍。
##
## ⚠️ 调它之前必须已经 `snap_ships()` 过敌方视觉（EvePhaseBattle.start 的顺序就是
##    先 spawn + snap 再 begin_battle_shot）—— 否则两军包围盒只算到我方，
##    对峙焦点会偏在我方一侧，画面读起来像"镜头怼着自己人"。
func begin_battle_shot() -> void:
	if orion_cam == null:
		return
	_shot_yaw0 = float(orion_cam.get_yaw())
	_shot_pitch0 = float(orion_cam.get_pitch())
	_shot_zoom0 = maxf(0.001, float(orion_cam.get_zoom()))
	_shot_focus0 = orion_cam.get_focus()

	# ⚠️ 起点距离要从**当前实况**算，不能拿常量反推：
	#    准备阶段的 max_range 是按部署带算的，玩家滚过滚轮后 zoom 也不是默认值。
	var range0 := maxf(1.0, float(orion_cam.get_max_range()))
	var dist0 := range0 * EveOrbitCamera.DISTANCE_SCALE / maxf(0.55, _shot_zoom0)

	var fleet := _measure_fleet()
	if bool(fleet["ok"]):
		var c: Vector3 = fleet["center"]
		var min_v: Vector3 = fleet["min"]
		var max_v: Vector3 = fleet["max"]
		# 对峙焦点 = 两军包围盒中心 + 近排偏置（与 _process 跟随同口径）
		c.z += (max_v.z - min_v.z) * CAMERA_FOCUS_NEAR_BIAS
		_shot_focus_end = c
		# 拍③ 的推近距离**不能超过「按包围盒算出的合适距离」**。
		#
		# ⚠️⚠️ 这条是实测逼出来的（第一次跑探针就切船）：
		#    原来那版是死推 1.55 倍，在 5 艘小船的场面上直接把侧翼挤出画幅 ——
		#    因为旧版开战镜头**同时还有跟随在跑**（跟随会把 max_range 从部署带的
		#    52 压到 20 出头），而运镜期间跟随被屏蔽、max_range 冻结，
		#    两个 1.55 倍叠不到一起 ⇒ 死推 1.55 就成了"推过头"。
		#    现在按包围盒兜底：大编队照样推满 1.55，小编队自动收手。
		var fit_range := _fit_range(min_v, max_v)
		var dist_fit := fit_range * EveOrbitCamera.DISTANCE_SCALE / maxf(0.55, _shot_zoom0)
		var dist_end := clampf(dist0 / BATTLE_VIEW_ZOOM, dist_fit, dist0)
		_shot_zoom_end = clampf(
				range0 * EveOrbitCamera.DISTANCE_SCALE / maxf(1.0, dist_end),
				EveOrbitCamera.ZOOM_MIN, EveOrbitCamera.ZOOM_MAX)
	else:
		_shot_focus_end = _shot_focus0
		_shot_zoom_end = clampf(_shot_zoom0 * BATTLE_VIEW_ZOOM,
				EveOrbitCamera.ZOOM_MIN, EveOrbitCamera.ZOOM_MAX)

	_shot_zoom_wide = clampf(_shot_zoom0 * SHOT_PULLBACK_ZOOM,
			EveOrbitCamera.ZOOM_MIN, EveOrbitCamera.ZOOM_MAX)

	_shot_t = 0.0
	_shot_active = true


## 量一次场上【可见】舰船的包围盒。
##
## ⚠️ 运镜与跟随共用它，别各写一份 —— 两边算出来的中心差一点点，
##    运镜落地那一瞬间画面会抖一下（而且只在特定编队下复现）。
func _measure_fleet() -> Dictionary:
	var min_v := Vector3(INF, INF, INF)
	var max_v := Vector3(-INF, -INF, -INF)
	var any := false
	for node in _ship_nodes.values():
		if not is_instance_valid(node) or not node.visible:
			continue
		any = true
		min_v = min_v.min(node.position)
		max_v = max_v.max(node.position)
	if not any:
		return {"ok": false}
	return {"ok": true, "min": min_v, "max": max_v, "center": (min_v + max_v) * 0.5}


## 按包围盒算「装得下这些船」的视距基准（max_range）。
##
## 与 `_process` 跟随**同一口径**（同一组 CAMERA_MIN_HALF_* / CAMERA_FIT_MARGIN /
## CAMERA_FIT_SCALE）。运镜用它给拍③ 兜底，防止死推 1.55 倍把侧翼切出画幅。
func _fit_range(min_v: Vector3, max_v: Vector3) -> float:
	var half_x := maxf((max_v.x - min_v.x) * 0.5, CAMERA_MIN_HALF_X) * CAMERA_FIT_MARGIN
	var half_z := maxf((max_v.z - min_v.z) * 0.5, CAMERA_MIN_HALF_Z) * CAMERA_FIT_MARGIN
	return sqrt(half_x * half_x + half_z * half_z) * 2.0 * CAMERA_FIT_SCALE


## 运镜推进一帧。⛔ 只碰相机，一个字都不碰 sim / 视觉节点位置。
##
## `delta` 兜底同 EveOrbitCamera._step：无头模式 delta=0 会让运镜永远停在 t=0，
## 而 `_process` 的运镜分支是 **return** 掉的 ⇒ 跟随永远不恢复 ⇒ 相机彻底死住。
func step_battle_shot(delta: float) -> void:
	if not _shot_active or orion_cam == null:
		return
	var dt := maxf(delta, EveOrbitCamera.MIN_STEP_DELTA)
	_shot_t = minf(_shot_t + dt, BATTLE_SHOT_SECONDS)

	var t := _shot_t
	var yaw := _shot_yaw0
	var pitch := _shot_pitch0
	var zoom := _shot_zoom0
	var focus := _shot_focus0

	if t <= SHOT_KEY_PULL:
		# 拍 ①：快起慢收（out-quad）—— 拉出要"有力"，落在全景上要稳
		var k := t / SHOT_KEY_PULL
		var e := 1.0 - (1.0 - k) * (1.0 - k)
		pitch = lerpf(_shot_pitch0, SHOT_PITCH_WIDE, e)
		zoom = lerpf(_shot_zoom0, _shot_zoom_wide, e)
		focus = _shot_focus0.lerp(_shot_focus_end, e)
	elif t <= SHOT_KEY_HOLD:
		# 拍 ②：定住。只让俯角回落 4%（完全静止会像卡帧）
		var k := (t - SHOT_KEY_PULL) / maxf(0.001, SHOT_KEY_HOLD - SHOT_KEY_PULL)
		pitch = lerpf(SHOT_PITCH_WIDE, SHOT_PITCH_WIDE * 0.96, k)
		zoom = _shot_zoom_wide
		focus = _shot_focus_end
	else:
		# 拍 ③：smoothstep —— 慢起、加速、稳收（俯冲的重量感来自这个形状）
		var k := (t - SHOT_KEY_HOLD) / maxf(0.001, BATTLE_SHOT_SECONDS - SHOT_KEY_HOLD)
		var e := k * k * (3.0 - 2.0 * k)
		pitch = lerpf(SHOT_PITCH_WIDE * 0.96, SHOT_PITCH_PUSH, e)
		yaw = lerpf(_shot_yaw0, BATTLE_VIEW_YAW, e)
		zoom = lerpf(_shot_zoom_wide, _shot_zoom_end, e)
		focus = _shot_focus_end

	orion_cam.drive_pose(yaw, pitch, zoom, focus)

	if _shot_t >= BATTLE_SHOT_SECONDS:
		_finish_shot()


## 结束运镜并把相机交还给 `_process` 的舰队跟随（幂等）。
##
## ⚠️ 交接三件事缺一不可：
##   ① 清 `_shot_active` —— 否则 `_process` 永远走在运镜分支里（相机彻底死住）；
##   ② `_cam_focus` 对齐到运镜末位 —— 否则下一帧跟随从**旧焦点** lerp 过来，
##      观感是运镜落地后又"飘"一下；
##   ③ 清 `_cam_last_span` —— 强制下一帧重算视距基准（运镜期间视距没跟包围盒）。
func _finish_shot() -> void:
	if not _shot_active:
		return
	_shot_active = false
	_shot_t = BATTLE_SHOT_SECONDS
	if orion_cam != null:
		_cam_focus = orion_cam.get_focus()
	_cam_focus_initialized = true
	_cam_last_span = Vector2.ZERO


## 运镜是否进行中（验收 / 调试用）
func battle_shot_active() -> bool:
	return _shot_active


## 运镜进度 0~1（验收 / 调试用）
func battle_shot_progress() -> float:
	return clampf(_shot_t / BATTLE_SHOT_SECONDS, 0.0, 1.0)


## 回到准备/观察机位（结算、推进节点、重开时调）。
##
## ⚠️ 与 `frame_battlefield()` 的分工：
##    `frame_battlefield()` 只管「焦点 + 视距基准」，**不动角度**（它的注释写得很清楚）。
##    开战镜头改了角度，所以回来时必须补一次 `reset_zoom_only()` 把角度交还给默认位，
##    否则玩家会带着交战时的斜视角进入下一轮布阵，而布阵是要正对棋盘的。
##
## ⚠️ 这里**不调 reset()**（那会连焦点一起清掉），见上面那条分工。
func end_battle_shot() -> void:
	# 先无条件打断运镜（幂等）—— 战斗中重开 / 直接进结算都会走到这里
	_shot_active = false
	_shot_t = 0.0
	if orion_cam == null:
		return
	orion_cam.reset_zoom_only()
	orion_cam.set_yaw_target(EveOrbitCamera.DEFAULT_YAW)
	frame_battlefield()


# ------------------------------------------------------------------ 棋盘

## 显隐 11×11 棋盘。
##
## 用户定稿：格子【默认不显示】，只在拖动舰船布置时亮出来。
## 所以这个函数由拖拽逻辑调用，不要写死在 _ready 里。
##
## frame_mode：0 = 取景到我方部署区（拖放时用），1 = 取景到整块棋盘（按 B 检查用）
##
## ⚠️ 拖放路径【不要】走这个函数 —— 它会把镜头硬设到目标位（画面一跳）。
##    拖放走 show_board_for_deploy()（平滑推近）。这个函数留给
##    「需要立刻到位」的场合：调试开关、复位、无头验收。
func set_board_visible(on: bool, frame_mode: int = 0) -> void:
	if board == null:
		return
	board.set_board_visible(on)
	if not on:
		_board_focus_init = false
		frame_battlefield()
		return
	_board_frame_mode = frame_mode
	_apply_board_framing_now()


func toggle_board() -> bool:
	if board == null:
		return false
	# 手动开关（KEY_B）用整块棋盘的取景 —— 那是「检查格子」的用法
	set_board_visible(not board.visible, 1)
	return board.visible


## 布阵用：显形棋盘，并把镜头【平滑】推向我方部署区。
##
## 由 EveBattleScene._begin_drag_visual() 在玩家拿起舰船的那一刻调用。
## 与 set_board_visible 的唯一差别：这里**不硬设**取景，
## 只把「棋盘可见」这个状态立起来，取景由 _process 每帧收敛过去。
##
## ══════════════════════════════════════════════════════════════════
##  ⚠️⚠️ 必须**同时**把 zoom 还原（2026-09-20 阶段 D 回归的修复）
## ══════════════════════════════════════════════════════════════════
##  开战镜头把 zoom 乘了 BATTLE_VIEW_ZOOM（1.55，推近），
##  **而此前没有任何路径把它拉回来**。后果远比"镜头有点近"严重：
##    镜头停在开战取景时，棋盘格 (8,5) 投影到 y ≈ 1044，
##    而商店窗的出售区在 y 898~1067 —— **那一格被商店窗盖住了**。
##    玩家的实际体验：把船拖到那一格 → 判定成"拖到出售区" → **船被卖掉**。
##    验收脚本的症状更迷惑：三条看似无关的断言一起挂
##      （提示里没写行号 / 商店不该亮橙 / 拖放后上场数少了 1），
##    根因只有一个 —— **相机没有回到布阵取景**。
##
##  ⇒ 归位是「布阵显形」这个动作的一部分，不是可选项。
##    用 set_zoom_target 平滑收敛（硬设会让画面跳一下）。
func show_board_for_deploy() -> void:
	if board == null:
		return
	_board_frame_mode = 0
	board.set_board_visible(true)
	align_camera_to_board()
	# 把开战镜头的推近还原（幂等：已经在家的话这次调用等于空转）
	reset_battle_zoom()


## 收起棋盘。取景交回 _process 的舰队跟随（同样走平滑，不跳）。
func hide_board() -> void:
	if board == null:
		return
	board.set_board_visible(false)
	_board_focus_init = false
	# 俯角交还给默认位（2026-09-22）。
	# ⚠️ 与 align_camera_to_board 的 pitch 切换配对：只切过去不切回来，
	#    战斗/观察机位会一直挂着 75° 俯视 —— 表现是「打完一架镜头变成看天灵盖」，
	#    而且因为它是平滑收敛、不报错，很容易被当成「镜头手感变了」。
	if orion_cam != null:
		orion_cam.set_pitch_target(EveOrbitCamera.DEFAULT_PITCH)
	# ★★ 2026-11-07：**缩放也要还**（旧版只还了俯角，这是个真 bug）。
	#    布阵取景把 max_range 压到了 0.5046 倍，不还回来的症状远不止"镜头有点近"：
	#    棋盘格 (8,5) 会投影到 y≈1044，而商店出售区在 898~1067
	#    ⇒ 玩家的船「拖到格子上」却**被卖掉**。详见 reset_battle_zoom() 的说明。
	#
	#    [WHY] 必须在 hide_board 里做，而不是指望调用方：
	#    本次改动让「收起棋盘」多了一条触发路径（开战），
	#    靠每个调用点各自记得还 zoom，迟早漏一个。
	reset_battle_zoom()
	# 布阵放大是「棋盘态」的一部分 ⇒ 棋盘收起就退出来。
	# 同样放在这里而不是调用方，理由同上。
	set_ships_board_mode(false)


## 把开战镜头改过的 zoom 还原成默认值（幂等）。
##
## ⚠️ 单独抽出来是因为它有**两个**调用点，漏掉任一个都会复现「格子被商店窗盖住」：
##    ① `show_board_for_deploy()` —— 玩家拖船时（最常见的那条路）；
##    ② `begin_prep()` —— 战斗打完回到准备阶段（玩家不拖船也要正常）。
##    只做①的话，"打完一场什么都不做、直接按开战"的玩家镜头会一直贴着。
func reset_battle_zoom() -> void:
	# ★ 2026-10-31：运镜若还在跑（战斗极短 / 开战即重开），一并作废。
	#   漏掉这行的症状是「下一轮布阵时镜头还在自己飞」，而且只在
	#   "战斗不到 2 秒就结束"这一小概率路径上复现。
	_shot_active = false
	_shot_t = 0.0
	if orion_cam != null and orion_cam.has_method("set_zoom_target"):
		orion_cam.set_zoom_target(EveOrbitCamera.DEFAULT_ZOOM)


## 我方部署区的第一行（= 敌方区 4 行 + 隔离区 3 行）
const BOARD_OWN_ROW0 := EveBoard.ENEMY_ROWS + EveBoard.ISOLATION_ROWS


## 布阵取景的放大倍率（用户 2026-09-20：「船现在还是小……就拉大两倍棋盘」）。
##
## ══════════════════════════════════════════════════════════════════
##  ⚠️ 这个数的单位是「画面上的倍数」，**不是「棋盘的世界尺寸」**
## ══════════════════════════════════════════════════════════════════
##  先把一件事钉死，免得日后有人跑去改 cell：
##    **把棋盘的世界尺寸（cell）放大 N 倍，屏幕上【什么都不会变】。**
##    因为取景是从 board.half / board.cell 反解出来的（见 _board_framing），
##    棋盘世界尺寸翻倍 → 相机距离跟着翻倍 → 投影完全一样，
##    而舰船是固定世界尺寸，反而显得更小。
##    何况 cell 是「1 格 = 射程几公里」的换算基准（CELL_METERS = 6000，
##    见 eve_ship_database），动它会连带破坏「表里写射程 2 格」
##    与「场上真的隔 2 格」的一致性。
##  ⇒ 「拉大棋盘」唯一有意义、也唯一有效的做法是**改取景倍率**：
##    把要取景的半宽/半深除以 N —— 镜头推近 N 倍，
##    棋盘与舰船在画面上一起放大 N 倍，而 cell 与射程口径一个字没动。
##
##  ── 为什么需要它（为什么不能只继续放大舰船）──────────────────────
##  布阵态的舰船已经放大到 BOARD_EXAGGERATION = 3 倍（实测 0.5~3.4 格，
##  分吨位见 `docs/方案-准备阶段棋盘模式-2026-11-07.md` 7.3 节），
##  再往上加，邻格轮廓就会相交；而**整体推近**不改变任何相对比例，
##  却让「船 / 格 / 血条 / 幽灵标签」一起变大 —— 这才是「看不清」的正解。
##
## ── 取 1.80 之后画面里还剩什么（2026-09-22 备战席改版后重新标定）──
##  ⚠️ 本组数值**不是拍的**，由 `tools/probe_board_fit.tscn` 二维扫描得出：
##     俯角 × 倍率 × 焦点抬升 三者一起扫，判据是
##     「整盘纵向落进屏幕 [50, 760] 且横向不溢出 1920」。
##
##  旧版（zoom 2.0 / pitch 0.72 rad）的实测真相：
##     棋盘屏幕宽 **2946px**（两端各溢出 500+px）、纵向 176..1313（下方也溢出），
##     我方部署区第 8 行落在 y≈1010 —— **正好压进商店窗（898..1066）**，
##     也就是「拖船到格子上会被当成出售」那个隐患的几何根源。
##     ⇒ 旧版是「只看得到一部的假放大」，不是真的把棋盘摆进了画面。
##
##  新版（zoom 2.00 / pitch 1.05 rad / 焦点抬升 17.0 世界单位）实测（实机 1920×1080）：
##     横向 1055px（居中 432..1487）、纵向 **55..760**（下沿正好压住备战格带顶）、
##     单格 96px、整盘 11×11 **全部入画**、上沿 55 不与顶条(6..46)相交。
##     ⇒ 部署区第 8 行落在 y≈615，离商店窗 908 有 290px 余量。
##
##  为什么俯角要单独加大（0.72 → 1.05 rad, 41°→60°）：
##     俯角 41° 时棋盘是个 3.5:1 的扁条 —— 纵向想占 710px 就必然横向 2400px+。
##     俯角 60° 时棋盘接近方形（1.45:1），同样的纵向高度只需 1055px 宽。
##     继续加大俯角（>1.2 rad）棋盘反而更方（1.2:1），横向上限掉到 850px，
##     所以在「纵向填满 710px」这个约束下 **1.05 rad 就是横向最大的那个点**。
##     ⚠️ 这个俯角**只属布阵态**，战斗态的俯角仍是 EveOrbitCamera.DEFAULT_PITCH。
## 布阵取景倍率（**与 `EveOrbitCamera.DEFAULT_ZOOM` 联动，别单独改**）
##
## ══════════════════════════════════════════════════════════════════
##  ⚠️ 2026-09-28：用户实机手滚到满意（`DEFAULT_ZOOM` 1.0 → 3.320117），此处**同步抵消**
## ══════════════════════════════════════════════════════════════════
##  棋盘在屏幕上的**投影尺寸 ∝ `BOARD_VIEW_ZOOM × orion_cam.zoom`**：
##    取景距离 = max_range * 1.52 / zoom，而 max_range 由
##    `board.half * CAMERA_FIT_MARGIN / BOARD_VIEW_ZOOM` 而来
##    ⇒ 尺寸 ∝ BOARD_VIEW_ZOOM × zoom。
##  用户只要求**战斗区**的船变大，棋盘那一档（下面那些实测值）不许变：
##    2.0 × 1.0（旧）  =  0.6023884 × 3.320117（新）  =  2.0000000
##  ⇒ 所以这里跟着缩：`BOARD_VIEW_ZOOM = 2.0 / DEFAULT_ZOOM`。
##
##  ⚠️ 若只改一边 ⇒ 症状是「拖船时棋盘被放大 1.6 倍、上下两行出画」或
##     「棋盘变小、和备战格带脱开」。改完两边都要跑 `probe_board_real` 复核。
##
## ★★ 2026-11-07：俯角从 60° 改到 75°（用户拍板「要更正面」），这里同步重解。
##    推导：投影尺寸 ∝ ZOOM，75° 原始 bbox 高 842 而可用高度 705
##          ⇒ 新 ZOOM = 0.6023884 × 705 / 842 = 0.504567
##    实测（真窗口投影，设计坐标 1920×1080）：
##          bbox 844×728、单格 76.7px、top=56（不撞顶条 46）、bot=784
##          x[538,1382]（左右各留 ≥538，不出屏）
##    ⚠️ 与 60° 相比单格从 96.1 缩到 76.7（−20%），这是几何必然：
##       俯角越大棋盘越接近正方形，被纵向可用高度卡死 ⇒ 横向反而变窄。
##       所以「更正面」和「棋盘更大」是相反方向，别再试图同时要。
##    ⚠️ bot=784 比备战格带顶（760）低 24px，属可接受叠压（60° 时是 762，也只差 2px）。
##
## ★★ 2026-11-08：**重扫取景（上移 + 缩一档）**，用户拍板选「让棋盘上移」而不是
##    接受近端战列压进备战格带。
##    起因：0.504567 这档下，最后一行（row 10）上的战列船尾落到了 **y≈914** ——
##          不光压进备战格带（760..900），还顶进了商店窗（908..）。
##    ⚠️ 关键认识：**光"上移"是做不到的**。上沿当时只剩 10px 余量（56 vs 顶条底 46），
##       再往上 10px 就撞顶条；而船尾要离开格带需要上移 154px ⇒ 必须同时缩小。
##    方法：`zoom × lift` 二维网格扫描（zoom 0.36..0.56 / lift 8..30，步长 0.005/0.25），
##          判据两条，都用**实机像素**：
##            ① 棋盘上沿 >= 52（顶条底 46 + 6 余量）
##            ② 近端战列船尾 <= 756（备战格带顶 760 − 4 余量）
##          在满足 ①② 的前提下取**单格像素最大**（可读性最好）。
##    结果：可行前沿止于 zoom=0.440 —— 再大一点，为了把船尾抬进 756 就必须
##          把 lift 加到让上沿撞顶条，两个约束互相锁死。
##    实测（真窗口 1920×1080，只量 `Model_*` 子树，不含护盾椭球）：
##          zoom=0.440 / lift=20.00 ⇒ 单格 65.4px、bbox 719×621、
##          top=56.1、bot=676.9、**近端战列船尾 753.4**（备战格带顶 760）
##    ⇒ 代价：单格从 76.7 缩到 65.4（**−15%**），棋盘下沿离格带留 83px 空档
##      （那一带由近端舰船的船体自己填上，见 docs/img/board-frame-after-2026-11-08.png）。
##    ⚠️ 这是「船不压格带」和「格子尽量大」之间的**唯一交点**，不是美学选择：
##       想回到更大的格子，就必须重新接受船尾压进格带。
## ★★ 2026-11-08（第二次）：**俯角 75°→48°，倍率跟着重解到 0.690**。
##    起因：用户贴了两张实机截图，说 75° 「角度太难受」，另一张「舒服一点」。
##
##    [SRC] 参照图怎么量出来的（不是"看着像"）：
##      按棋盘格颜色分割 + 每行取最长连续段，拟合左右斜边的屏幕斜率，
##      得**梯形半张角**：用户喜欢那张 ≈ **22.5°**、75° 那张 ≈ **4.4°**。
##      半张角是纯几何量（= 棋盘两边向消失点收敛的速率），与窗口缩放无关，
##      所以它是"角度"这件事唯一可对齐的指纹。
##
##    [SRC] 反解（本侧实测校准过的等价式）：
##      tan(半张角) = 0.654 · zoom / tan(pitch)
##      —— 75°/0.44 代入得 0.0771（4.41°），实机量到 4.4°，误差 <1%。
##      定 pitch=48° ⇒ zoom = tan(22.5°)·tan(48°)/0.654 = 0.679。
##
##    ⚠️ **zoom 与 lift 强耦合，不能线性外推**：
##       lift 推近焦点 ⇒ 相机跟着平移 ⇒ 棋盘相对相机的距离变了 ⇒ 投影尺寸也变。
##       同一 zoom=0.679 下，lift 29.3→16 会让宽度从 1115 涨到 1273（+14%）。
##       ⇒ 必须二维网格扫描，改一个数就重扫，别用比例算。
##
##    [实测] 1920×1080 设计坐标，摆 3 艘战列在最末行（row 10）取最坏情况：
##      | 档            | 上沿 | 下沿 | 单格  | 半张角 | 船尾 | 判定        |
##      | 75°/0.440/20  |  56 |  677 |  65.4 |  4.4° |  753 | 现状        |
##      | 48°/0.690/28  |  57 |  605 | 104.4 | 22.1° |  726 | 完全不压格带 |
##      | 48°/0.690/24  |  78 |  661 | 108.5 | 22.1° |  790 | 压 34px ←取它|
##      | 48°/0.690/20  | 100 |  722 | 113.0 | 22.1° |  860 | 压 104px    |
##
##    ⇒ 取 **0.690 / lift 24**：单格 65.4→108.5（**+66%**），透视与参照图一致。
##      代价 = 最末行的战列船尾会压进备战格带上沿 **34px**（格带 760~900）。
##
##    ⚠️ 为什么不取「构图最像参照图」的 lift=20：那张下沿 722、船尾 860，
##       船尾会盖住第一排备战格约 3/4 高度 ⇒ 那几格点不动（功能伤害，不只是难看）。
##    ⚠️ 为什么不取「完全不压」的 lift=28：上沿 57 紧贴顶条、下沿 605，
##       棋盘与格带之间空 155px，画面重心明显偏上（用户看的就是这个"空"）。
##
##    ⛔ 换角度时必须三件套一起换（pitch / zoom / lift），
##       且必须用**末行摆战列**的极端阵型量 —— 空棋盘量不出船尾。
const BOARD_VIEW_ZOOM := 0.690

## 布阵态的俯角（弧度）。**48°**（2026-11-08 第二次调整，75° 时用户嫌「太难受」）。
##
## 90° 做过实测但被否：正俯视下棋盘投影是正方形，纵向卡在 714px ⇒
## 横向只剩 714px（占屏 37%），单格 64.9px，比现在小 33%，两侧各空 600px。
##
## [WHY] 75° 的问题不是"斜"，而是**透视几乎消失**：半张角只剩 4.4°，
##       棋盘在屏幕上接近一个竖直矩形，"平铺在地面上"的读法完全丢了。
##       48° 给到 22.1°，近大远小重新成立 —— 这正是用户说"难受/舒服"的差别。
## [PITFALL] 降俯角的直接代价：**舰船船尾在屏幕上伸得更远**。
##       75° 时末行战列船尾只比棋盘下沿低 76px，48° 变成 **143px**（+88%）。
##       因为视角越接近水平，平躺的船身沿纵深方向的投影越长。
##       ⇒ 想同时满足「低俯角 + 船尾不压格带」，棋盘就只能做小（见 ZOOM 的实测表）。
const BOARD_VIEW_PITCH := 0.838

## 焦点沿 +z（往近端）的抬升量（世界单位）。
##
## 焦点投影恒在屏幕正中，所以「棋盘整体在画面上偏下」只能靠把焦点往近端推来纠正：
## 焦点推近 → 相机跟着推近 → 棋盘（在焦点远端侧）就抬到画面上去。
## 17.0 是实测扫描值 —— 它把「棋盘下沿贴住备战格带顶（760）」这件事一并解决了，
## 所以它**不是**一个可以随手调的美学数：改它就要重新跑 probe_board_real。
##
## ⚠️ 它与 BOARD_VIEW_ZOOM 是**耦合**的：倍率变大 → 棋盘变高 → 需要更大的抬升。
##    两个数一起改，然后重跑探针，别只改一个。
##
## ★★ 2026-11-07：随俯角 60°→75° 一起重扫。
##    实测斜率 9.72 px/单位（lift 每 +1 世界单位，棋盘整体上移 9.72px）。
##    令 top 从 184 落到 56 需要 (184−56)/9.72 = 13.23。
##    ⚠️ 这与旧值 17.0 不同，不要因为「看着差不多」就沿用它 —— 俯角变了，
##       同样的 lift 在屏幕上对应的像素位移也变了。
##
## ★★ 2026-11-08：随 zoom 0.504567→0.44 一起重扫到 **20.0**。
##    ⚠️ 别拿上面的 9.72 px/单位 直接换算：那条斜率是 60° 时代测的，
##       75° 下同样 lift 的屏幕位移更小，而且它与 zoom 耦合。
##       这次是**网格扫描**得出来的（详见 BOARD_VIEW_ZOOM 上方的 2026-11-08 段）。
##
## ★★ 2026-11-08（第二次）：随俯角 75°→48° / zoom 0.44→0.690 一起重扫到 **24.0**。
##    ⚠️ 这个数**不是**「上沿贴顶条」那个解（那是 28.0），而是**故意往下放 4 个单位**：
##       换取棋盘下沿从 605 落到 661，把下方那段 155px 的空档压到 99px。
##       判据不再是"上沿刚好 52"，而是三条同时成立：
##         ① 上沿 >= 52（顶条底 46 + 6）—— 78 ✓
##         ② 船尾压格带 <= 40px（可接受的轻微叠压）—— 34 ✓
##         ③ 棋盘下沿到格带的空档尽量小 —— 99px
##       ⛔ 若把 ③ 去掉（即要求船尾完全不压），下沿只能到 605、空档 155px，
##          画面重心明显偏上 —— 用户抱怨的就是这个观感。
const BOARD_FOCUS_LIFT := 24.0

## 运行时可覆盖的当前倍率（探针扫档用）。
## ⚠️ 正常玩法下恒等于 BOARD_VIEW_ZOOM —— 别把它当玩法开关在运行中改。
var board_view_zoom := BOARD_VIEW_ZOOM

## 运行时可覆盖的焦点抬升（探针扫档用）。
##
## [WHY] 与 `board_view_zoom` 同一口径：取景的**两个自由度**（多大 / 多高）
##       必须能在运行时各自扫，否则标定只能靠「改常量→重启→量一次」，
##       一次扫 20 个候选就是 20 次冷启动。
## [NOTE] 正常玩法下恒等于 BOARD_FOCUS_LIFT，别在运行中拿它当镜头开关。
var board_focus_lift := BOARD_FOCUS_LIFT


## 当前应有的棋盘取景：{half_x, half_z, focus}（世界单位）。
##
## 抽成一个函数，是为了让「立刻到位」与「每帧收敛」两条路径共用同一份几何 ——
## 两份算法迟早会漂，症状是「拖放时和按 B 时棋盘大小不一样」。
func _board_framing() -> Dictionary:
	if board == null:
		return {}
	var half_x: float
	var half_z: float
	var focus: Vector3
	if _board_frame_mode == 1:
		# 整块棋盘（按 B 检查用）—— **不乘 BOARD_VIEW_ZOOM**：
		# 这个模式存在的理由就是「看全 11×11」，推近等于把它自己的用途毁掉。
		var h: float = float(board.half) * CAMERA_FIT_MARGIN
		half_x = h
		half_z = h
		focus = board.position
	else:
		# 拖放用（2026-09-22 备战席改版后**与 mode 1 合并为同一取景**）。
		#
		# ⚠️ 为什么不再单独取「我方部署区」：
		#    用户的诉求是「备战席和棋盘放到一个位置」，而备战席格带是
		#    **紧贴棋盘近端**的一条带子。要让这层关系一眼看得懂，
		#    棋盘近端就必须在画面里 —— 而旧版把部署区放大到近端出画（y≈1010，
		#    压在商店窗上），玩家既看不到近端、也看不到格带与它的贴合。
		#    整盘入画后单格 153px，拖放精度完全够用（旧版是 267.9px 但大半在屏外）。
		var h2: float = float(board.half) * CAMERA_FIT_MARGIN
		half_x = h2
		half_z = h2
		focus = board.position
	# 焦点沿 +z 抬升 —— 把棋盘整体顶到屏幕上部，给底部的备战格带 + 商店腾位。
	# 数值来源见 BOARD_FOCUS_LIFT 的注释（扫描值，不是美学数）。
	focus += Vector3(0.0, 0.0, board_focus_lift)
	# [NOTE] 下限 0.2 而不是 0.5：2026-11-08 重扫取景时，为了让近端战列
	#        不再伸进备战格带，倍率需要降到 0.4 出头 —— 旧的 0.5 下限会
	#        把它**静默夹回去**（症状：改小常量后画面一点没变，还没有任何提示）。
	var z := clampf(board_view_zoom, 0.2, 6.0)
	return {"half_x": half_x / z, "half_z": half_z / z, "focus": focus}


## 立刻把取景设到当前目标。**画面会跳** —— 只给调试开关 / 复位 / 无头验收用。
func _apply_board_framing_now() -> void:
	if orion_cam == null:
		return
	var f := _board_framing()
	if f.is_empty():
		return
	var hx: float = f["half_x"]
	var hz: float = f["half_z"]
	var fv: Vector3 = f["focus"]
	orion_cam.set_range_from_half_extent(hx, hz)
	orion_cam.set_focus_point(fv)
	_cam_focus = fv
	_cam_focus_initialized = true
	_board_focus_init = true
	_cam_last_span = Vector2(hx, hz)


## 每帧向目标取景收敛（棋盘显形期间由 _process 调用）。
##
## 时间常数 0.45s：比环绕对齐（0.25s）略慢，读起来是「镜头推过去」。
func _apply_board_framing_smooth(delta: float) -> void:
	if orion_cam == null:
		return
	var f := _board_framing()
	if f.is_empty():
		return
	var hx: float = f["half_x"]
	var hz: float = f["half_z"]
	var fv: Vector3 = f["focus"]
	var want := sqrt(hx * hx + hz * hz) * 2.0
	orion_cam.set_max_range(lerpf(
			float(orion_cam.get_max_range()), maxf(20.0, want),
			clampf(delta / 0.45, 0.0, 1.0)))
	# 焦点的第一帧【直接落位】：否则会从上一场战斗的焦点一路「飞」过来，
	# 而棋盘显形是瞬时的，焦点却慢慢飘，看起来像画面在滑。
	if not _board_focus_init:
		_cam_focus = fv
		_board_focus_init = true
	else:
		_cam_focus = _cam_focus.lerp(fv, clampf(delta / 0.45, 0.0, 1.0))
	orion_cam.set_focus_point(_cam_focus)
	_cam_last_span = Vector2(hx, hz)


## 取景到整块棋盘（含边距）
##
## ⚠️ 棋盘现在可以被 align_board_to_line() 在 z 上挪走，
##    所以焦点必须取棋盘自己的位置，不能再写 Vector3.ZERO。
func frame_board() -> void:
	_board_frame_mode = 1
	_apply_board_framing_now()


## 取景到【我方部署区】（下 4 行）—— 拖动布阵时用这个。
##
## ⚠️ 为什么不取整块棋盘：棋盘 11 格 = 66 km 宽，取整块会把镜头推得很远，
##    舰船缩成几个像素，玩家根本看不清自己在拖哪艘。
##    只取我方 4 行的纵深（横向仍给满，保证最左最右两列也够得着）——
##    再叠上 BOARD_VIEW_ZOOM（默认 2.0）就是最终的布阵取景。
func frame_own_zone() -> void:
	_board_frame_mode = 0
	_apply_board_framing_now()


## 布阵机位：让棋盘「正对镜头」的相机偏航角（弧度）。
##
## ══════════════════════════════════════════════════════════════════
##  ⚠️ 为什么需要一个与 EVE 默认机位不同的角度（2026-09-20 用户提出）
## ══════════════════════════════════════════════════════════════════
##  用户原话：「我觉得棋盘歪着很奇怪……现在歪着去操作相当奇怪，
##             云顶之弈是这样教你的？」
##
##  实测（tools/probe_view，1920×1080，取景整块棋盘）：
##     yaw = -0.58（EVE 默认）→ 近端横边倾斜 **-27.7°**，一格投影 39.0×34.6 px
##                               且呈**菱形** —— 鼠标落点判断非常别扭
##     yaw =  0.00（本常量）  → 近端横边 **完全水平**（dy = +0.0），
##                               一格投影 43.5×29.5 px，横平竖直
##
##  ── 为什么对齐到 0 是「零副作用」的 ──────────────────────────────
##  棋盘是【世界轴对齐】的矩形，歪的根源在相机不在棋盘。
##  而**棋盘可见的整段时间里，玩家左键都在拖船**（转视角也是左键拖拽，
##  被拖放逻辑吃掉了），所以这段时间本来就不存在「玩家想转视角」的需求。
##  于是：棋盘显形的那一刻把偏航平滑对齐过来，玩家拿完船想回 3/4 视角，
##  拖一下空白处即可 —— 战斗视角、星云构图一律不受影响。
##
##  ⚠️ 想让它「稍微歪一点但比 27.7° 收敛」时，改这一个值即可，
##     不必再去动 EveOrbitCamera 的 DEFAULT_YAW（那是全局默认机位，
##     改了会连战斗构图一起改掉）。
const BOARD_VIEW_YAW := 0.0


## 把相机偏航【平滑】对齐到棋盘正对位。
##
## 由拖放逻辑在「拿起舰船、棋盘显形」的那一刻调用。
## 走的是 EveOrbitCamera 的 target/current 收敛（约 0.25 秒转正），
## 不是硬赋值 —— 硬赋值会让画面「啪」地跳一下。
func align_camera_to_board() -> void:
	if orion_cam == null:
		return
	orion_cam.set_yaw_target(BOARD_VIEW_YAW)
	# 俯角也要切到布阵档（2026-09-22 加）。
	# ⚠️ 只切 yaw 是不够的：41° 俯角下棋盘是 3.5:1 的扁条，纵向占不满棋盘的位子，
	#    实测纵向只到 691px 而横向要 2416px（溢出）。60° 时棋盘接近方形，
	#    同样的纵向高度只需 1683px。见 BOARD_VIEW_PITCH 的注释。
	orion_cam.set_pitch_target(BOARD_VIEW_PITCH)


## 把棋盘在 z 上对齐到本节点的接敌线。
##
## ══════════════════════════════════════════════════════════════════
##  ⚠️ 这里记录一处【阶段 B 才暴露出来的几何事实】，不是随手加的偏移
## ══════════════════════════════════════════════════════════════════
##  `default_formation()` 给的接敌线只有 **2~3 格** 远
##  （间距 = deploy_standoff_ratio 1.15 × 射程中位数 ≈ 14 km ≈ 2.3 格），
##  而棋盘按用户定稿画了 4/3/4 共 11 行 —— 双方各占 4 行、中间隔 3 行 = 7 格 = 42 km。
##
##  **两者差 3 倍。棋盘不可能是这个战场的等比地图。**
##  所以棋盘的角色明确为「我方布阵台」：
##    对齐口径 = **我方接敌线落在第 8 行中心**。
##    于是默认阵型的两排（前沿 = 线前 6 km、主力 = 线本身）
##    正好压在我方第 7、8 行里 —— 玩家看到自己的船在自己的区域，是对的。
##
##  ⚠️ 副作用（如实记录，没有藏）：
##    因为双方开局只隔约 2.3 格，**敌方的起始线会落在隔离带里（第 6 行附近）**，
##    棋盘最上面那 4 行「敌方出现区」实际上是空的。
##    要让敌方区真正被用到，必须把接敌距离拉到 6~7 格（36~42 km），
##    代价是画面纵深翻倍 + 接敌时间约 +20 s。
##    **这是设计侧的取舍，工程不擅自改** —— 现状是：棋盘上「隔离带」= 真实的
##    无人区，双方开局就贴在无人区的两侧（它们确实是贴着的）。
func align_board_to_line(line_meters: float) -> void:
	if board == null:
		return
	var row8_local: float = board.row_z0(8) + board.cell * 0.5
	board.position.z = line_meters / maxf(1.0, world_unit_in_meters) - row8_local


## 棋盘格中心 → 世界坐标（米）。
##
## 拖放落格的收敛点：玩家松手在某一格，船就落在那一格的中心。
## 棋盘本身带一个 z 偏移（align_board_to_line），所以这里必须走 to_global，
## 不能再用「格坐标 × 换算系数」那种直算。
func board_cell_to_meters(row: int, col: int) -> Vector3:
	if board == null:
		return Vector3.ZERO
	var local: Vector3 = board.cell_center(row, col)
	var world: Vector3 = board.to_global(local) if board.is_inside_tree() \
			else board.position + local
	return world * world_unit_in_meters


## 屏幕坐标 → 格（越界返回 Vector2i(-1, -1)）
func screen_to_cell(screen_pos: Vector2) -> Vector2i:
	if board == null:
		return Vector2i(-1, -1)
	# ⚠️ 单位链（只有两条，记牢）：
	#    screen_to_world 从相机射线求 y=0 平面的交点 → 得到的是【世界单位】
	#    （project_ray_origin/normal 都在渲染空间里，不是米）
	#    world_to_cell 吃的正是【棋盘本坐标】= 世界单位
	#    所以这里**不做任何单位换算**，只需要减掉棋盘的位移。
	#
	#    少掉 to_local 的症状是「鼠标指着第 7 行，高亮却出现在第 5 行」，
	#    而且四个角都错得一样多 —— 很容易被误当成相机问题。
	#    详见 align_board_to_line 的说明。
	var world_u := screen_to_world(screen_pos)
	var local := board.to_local(world_u) if board.is_inside_tree() else world_u
	return board.world_to_cell(local)


# ------------------------------------------------------------------ 输入

## 相机输入入口 —— 由上层（eve_battle_scene.gd）统一分发
##
## 返回 true 表示事件已被相机消费，上层不应再拿它做别的事。
##
## ⚠️ 为什么不让相机自己在 _unhandled_input 里处理：
##    因为「左键按下」有两个含义（转视角 / 选中舰船），必须由同一个地方
##    按「拖了多少像素」来仲裁。分散在两个节点里各收一份事件，
##    就会出现「转视角的同时还切了选中船」这种叠加故障。
func handle_camera_input(event: InputEvent) -> bool:
	if orion_cam == null:
		return false
	# ★ 2026-10-31：运镜期间玩家一动手，运镜【就地】结束并交还控制权。
	#
	#   ⚠️ 为什么必须给这条出路：2 秒运镜对"每回合都点开战"的老玩家是负担，
	#      而镜头正在飞的时候硬拖视角会让人以为游戏卡住了。
	#   ⚠️ 为什么加 0.15 秒防抖：开战那一下本身就是左键按下（点按钮），
	#      没有防抖的话运镜会被同一个点击当场掐死 —— 表现是"开战镜头从来没演过"，
	#      而且只在"用鼠标点按钮"时复现、用快捷键开战时正常，极难定位。
	if _shot_active and _shot_t > SHOT_SKIP_AFTER:
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			_finish_shot()
	# 双击 = 复位机位（对齐参考程序的 dblclick 行为）
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT:
			reset_camera()
			return true
	return orion_cam.handle_input(event)


## 取景边距。太小会让边上的船贴着画框，太大会把镜头推远、舰船变小。
const CAMERA_FIT_MARGIN := 1.18

## 最小取景半宽/半深（世界单位）—— 镜头不会比这个更近
##
## 战斗收拢后包围盒可能只有 12 x 7 单位，若按它取景，镜头会怼到脸上。
## 这两个值对应「一块能容纳整场对峙的最小战场」：
##   半宽 18 -> 画幅宽 36 单位，刚好放下 4 列阵型（横向 24 单位）加机动余量
##   半深 14 -> 画幅深 28 单位，够两军拉开一个接敌距离
const CAMERA_MIN_HALF_X := 18.0
const CAMERA_MIN_HALF_Z := 14.0

## ★ 2026-10-25 · **默认视距收紧**（用户：「默认摄影机距离舰船太远，舰船显得太小」）
##
## ══════════════════════════════════════════════════════════════════
##  这两个数是「能再推近多少」的实测上限，不是随手取的
## ══════════════════════════════════════════════════════════════════
##  量法（`tools/probe_cam_framing.tscn`：船体网格 AABB 经 `global_transform` 逐角点投影，
##  取整支舰队的外接框）：
##    收紧前视距 29.46 ⇒ 5 艘船在 1920×1080 上单船仅 171~181px 宽。
##    以屏幕中心等比放大，**不切船的极限约 1.5 倍**（近排船底在 y≈1076 触界）。
##  ⇒ `CAMERA_FIT_SCALE = 0.80` ⇒ 实测视距 19.7（= **1.50 倍**），
##     单船 236~257px，舰队外接框 x 48..1657 / y 289..1050，一艘都不出画。
##
##  ⛔ 别再往下调（0.5 = 2 倍）：实测 2 倍时舰船横向占宽 2138px > 1920，
##     最外侧两艘直接切出左右边框，近排整排掉到屏幕外。
##     —— 那是「更大的船」换「看不见的船」。真要更大的船只能改阵型间距或俯角。
const CAMERA_FIT_SCALE := 0.80

## 焦点朝**近排**偏的比例（占舰队包围盒纵深）。
##
## ⚠️ 为什么偏：近排船投影在下方，而现在最下面一排正好压在备战席（y≥760）上。
##    把焦点朝近排挪一点 ⇒ 整支舰队在画面上**上移**，让船浮在备战席上方，
##    同时腾出底部空间，上面那条 `CAMERA_FIT_SCALE` 才能真的用满。
const CAMERA_FOCUS_NEAR_BIAS := 0.18

## 相机最近距离下限（世界单位）—— 防止舰队收拢成一点时镜头怼到脸上
const CAMERA_MIN_DIST := 14.0

# ── 已移除的旧相机数学（第十轮）────────────────────────────────────
#
# 下面三个函数随「固定俯角」模型一起被删掉了，留一条注释说明去向，
# 免得日后有人翻历史版本时一头雾水：
#
#   _solve_camera_distance(half_x, half_z)
#       → 旧职责：按包围盒反解「能装下它的相机距离」。
#       → 新职责：由 EveOrbitCamera.max_range + DISTANCE_SCALE/zoom 给出。
#         逻辑差别：旧的是「几何反解」（精确但只能自动），
#         新的是「雷达量程 + 缩放系数」（统一口径，且可被滚轮覆盖）。
#
#   _camera_offset_dir()
#       → 旧职责：按固定俯角给出相机相对焦点的单位偏移。
#       → 新职责：EveOrbitCamera.apply_to_camera() 里的球面坐标公式
#         (sin(yaw)cos(pitch), sin(pitch), cos(yaw)cos(pitch))。
#
#   _apply_camera_angles()
#       → 旧职责：每帧把 rotation.x/y 钉回常量。
#       → 【彻底删除，不再有任何等价物】。这是轨道相机的直接障碍：
#         它会让玩家拖拽的角度在下一帧被抹掉。
#         角度现在只由 EveOrbitCamera 在 apply_to_camera() 里经 look_at 设置。


# ------------------------------------------------------------------ 舰船

## 在战场上生成一艘船的可视节点
func spawn_ship_visual(ship: EveShip) -> Node3D:
	var visual: Node3D = SHIP_SCENE_SCRIPT.new()
	visual.name = "Ship_%d" % ship.id
	ships_layer.add_child(visual)
	visual.setup(ship)
	# 布阵途中重建舰队时，新船必须继承当前的布阵态 ——
	# 否则「放大 3 倍」只对拖动前就存在的船生效，刚放下的那艘还是原尺寸。
	if ships_board_mode and visual.has_method("set_board_mode"):
		visual.set_board_mode(true)
	_ship_nodes[ship.id] = visual
	ship_visual_ready.emit(ship.id, visual)
	return visual


## 布阵态开关 —— 棋盘显形/隐藏时由拖放逻辑广播给**所有**舰船可视节点。
##
## 用户 2026-09-20：「现在舰船在棋盘上太小了」。布阵时船放大
## EveShipVisual.BOARD_EXAGGERATION 倍（实测量化见那边的常量说明）。
##
## ⚠️ 状态存在这里而不是只存各 visual 里：布阵途中会重建我方舰队，
##    新节点出生时要知道「现在是不是布阵态」（见 spawn_ship_visual）。
var ships_board_mode := false


func set_ships_board_mode(on: bool) -> void:
	ships_board_mode = on
	for node in _ship_nodes.values():
		if is_instance_valid(node) and node.has_method("set_board_mode"):
			node.set_board_mode(on)


func get_ship_visual(ship_id: int) -> Node3D:
	return _ship_nodes.get(ship_id)


## 单独移除一艘船的视觉节点。
##
## 准备阶段玩家买了新船要重建我方舰队时用 —— 那时候不能调 clear_ships()，
## 因为它会把敌方的视觉节点也一起清掉。
func remove_ship_visual(ship_id: int) -> void:
	var n = _ship_nodes.get(ship_id)
	if n != null and is_instance_valid(n):
		n.queue_free()
	_ship_nodes.erase(ship_id)


## 每帧把模拟层的位置同步到可视层
##
## ★ 46 轮：额外传 `delta` —— 视觉层要用它做**舰艏角速度限速**
##   （`EveShipVisual.FACING_MAX_DEG_PER_SEC`）。限速依赖时间步长才能做到
##   「与帧率无关」；不传 delta 就只能假定 60 FPS，掉帧时会转得变慢。
##
## ★★ 2026-10-27：再加 `alpha` —— **渲染插值系数**（见
##   `EveBattleSimulator.interp_alpha()`）。战斗循环传 `sim.interp_alpha()`，
##   消除「30 Hz 仿真 ⇒ 渲染帧静止若干帧后一次跳几像素」的抖动。
##   ⚠️ 默认 `1.0` = 老行为（位置 = 本 tick 位置），布阵 / 快进 / 验收脚本不用改。
func sync_ships(ships: Array[EveShip], delta: float = 1.0 / 60.0,
		alpha: float = 1.0) -> void:
	for ship in ships:
		var visual: Node3D = _ship_nodes.get(ship.id)
		if visual == null:
			continue
		visual.sync_from_body(ship.body, ship.alive, delta, alpha)


## ★ 53 轮：**瞬时**把舰队姿态摆到 `body.aim_dir`（不走 slerp 平滑）。
##
## 与 `sync_ships` 的分工见 `EveShipVisual.snap_facing()` 的说明：
##   · `sync_ships`      —— 每帧、平滑（战斗循环用）
##   · `snap_ships`      —— 一次、瞬时（布阵 / 复位 / 验收脚本用）
##
## ⚠️ 布阵阶段必须走这个而不是 `sync_ships`：
##    布阵期 `_process` 的 PREP 分支**不调** `sync_ships` ⇒ 只同步一次，
##    走 `sync_ships` 只会让姿态挪 12%（`FACING_LERP`）⇒ 看着像没转。
func snap_ships(ships: Array[EveShip]) -> void:
	for ship in ships:
		var visual: Node3D = _ship_nodes.get(ship.id)
		if visual == null:
			continue
		visual.snap_facing(ship.body, ship.alive)


## 只释放**一艘**船的可视节点（真联机 PvP 重建敌方舰队时用）。
## ⚠️ 不能用 `clear_ships()`：那会连我方一起清掉。
func free_ship_visual(ship_id: int) -> void:
	var node = _ship_nodes.get(ship_id, null)
	if node != null and is_instance_valid(node):
		node.queue_free()
	_ship_nodes.erase(ship_id)


func clear_ships() -> void:
	for node in _ship_nodes.values():
		if is_instance_valid(node):
			node.queue_free()
	_ship_nodes.clear()


# ------------------------------------------------------------------ 标签避让

## 屏幕空间标签避让参数（2026-10-27 用户：「血条堆叠」）。
##
## ⚠️ 这是「治」不是「藏」：名字常驻（用户定案），重叠靠**推开**解决。
##    层数上限 5 = 同一处最多排 5 行；再多的压暗 —— 继续往上推会顶出画面，
##    比堆叠更难读。
const LABEL_DECLUTTER_STEP_PX := 15.0
const LABEL_DECLUTTER_MAX_LAYERS := 5
const LABEL_DECLUTTER_DIM := 0.35


## 给一组屏幕矩形分配垂直偏移（像素，正 = 向上）。
##
## 纯函数：不碰节点、不看相机 —— 验收脚本可以直接喂矩形断言（红线 40 友好）。
## `priorities[i]` 越大越优先留在原位（被集火 > 旗舰 > 普通船）。
## 返回与输入**同序**的 Array[Dictionary]：{shift: float, dim: float}。
static func declutter_offsets(rects: Array, priorities: Array,
		step_px: float = LABEL_DECLUTTER_STEP_PX,
		max_layers: int = LABEL_DECLUTTER_MAX_LAYERS) -> Array:
	var n := rects.size()
	var out: Array = []
	out.resize(n)
	if n == 0:
		return out
	var order: Array = []
	for i in range(n):
		order.append(i)
	# 高优先级先占位；同优先级按屏幕高度从上往下排。
	order.sort_custom(func(a, b):
		if priorities[a] != priorities[b]:
			return priorities[a] > priorities[b]
		var ra: Rect2 = rects[a]
		var rb: Rect2 = rects[b]
		return ra.position.y < rb.position.y)
	var placed: Array = []
	for i in order:
		var r: Rect2 = rects[i]
		var shift := 0.0
		var layer := 0
		# ⚠️ 超过层数上限后**继续推开**（叠在一起更难看），只是把透明度压下去。
		#    break 只防极端拥挤（几十块同点）时的长循环 ——
		#    早期版本把循环条件写成 `layer < max_layers`，结果是「推满 5 层就停，
		#    再检查还撞不撞」，而那时 r 通常已经推到一个不撞的位置 ⇒
		#    `dim` 永远算成 1，上限形同不存在（实测 9 块同点只压暗 3 块）。
		while _rect_hits(r, placed):
			shift += step_px
			r.position.y -= step_px
			layer += 1
			if layer > 12:
				break
		var dim := 1.0 if layer < max_layers else LABEL_DECLUTTER_DIM
		placed.append(r)
		out[i] = {"shift": shift, "dim": dim}
	return out


## 是否与已占位的矩形相撞。
##
## ⚠️ 用 `Rect2.intersects()` 的**默认**口径（`include_borders = false`）：边贴边
##    不算撞。这样才能靠 15px 步长把 14px 高的标签一块一块排开 ——
##    早期版本在这里 `grow(2)` 想留 2px 间隙，结果步长 15 减高度 14 只剩 1px，
##    永远判撞 ⇒ 每块都被推到层数上限、集体压暗（血条照样糊成一片）。
static func _rect_hits(r: Rect2, placed: Array) -> bool:
	for q in placed:
		if r.intersects(q as Rect2):
			return true
	return false


## 每帧一次：屏幕投影 → 重叠检测 → 世界 Y 偏移（交给各船的标签层平滑）。
##
## ⚠️ 只在**非布阵态**调用：布阵按格子排列本来就分得开，而且布阵期不跑
##    `sync_from_body` ⇒ 偏移不会生效，算了也是空转。
func _declutter_labels() -> void:
	if camera == null:
		return
	var rects: Array = []
	var prios: Array = []
	var refs: Array = []       ## 与 rects 同序：[{node, wpp}]
	for node in _ship_nodes.values():
		if not is_instance_valid(node) or not node.visible:
			continue
		if not node.has_method("label_block_world"):
			continue
		var block: Rect2 = node.label_block_world()
		if block.size.x <= 0.0 or block.size.y <= 0.0:
			continue
		var base: Vector3 = node.label_root.global_position
		var center := base + Vector3(0.0, block.position.y + block.size.y * 0.5, 0.0)
		# 相机背后的点 unproject 会给出无意义值 ⇒ 跳过（本来也看不见）
		if camera.is_position_behind(center):
			continue
		var p := camera.unproject_position(center)
		# 用「世界 +1 单位」投影出的像素差算 px/世界单位 —— 把相机朝向也算进去。
		var px_per_world := p.distance_to(
				camera.unproject_position(center + camera.global_transform.basis.y))
		if px_per_world < 1e-4:
			continue
		var size_px: Vector2 = block.size * px_per_world
		rects.append(Rect2(p - Vector2(size_px.x * 0.5, size_px.y * 0.5), size_px))
		var locked: bool = node.ship != null and node.ship.id == _cam_lock_id
		node.set_label_camera_lock(locked)
		var pri := 0
		if node.ship != null:
			if node.ship.is_focused:
				pri += 4
			if node.ship.is_flagship:
				pri += 2
		if locked:
			pri += 2
		prios.append(pri)
		refs.append({"node": node, "wpp": 1.0 / px_per_world})
	if refs.is_empty():
		return
	var res: Array = declutter_offsets(rects, prios)
	for i in range(refs.size()):
		var d: Dictionary = res[i]
		refs[i].node.set_label_offset_world(float(d.shift) * float(refs[i].wpp))
		refs[i].node.set_label_dim(float(d.dim))


# ------------------------------------------------------------------ 坐标转换

## 【米】坐标 → 屏幕坐标（选中舰船 / 拖放命中判定用）
##
## ⚠️ 参数是**米**（仿真层单位，也就是 body.position / board_cell_to_meters 的口径），
##    不是世界单位 —— 换算在函数内部完成。
##    理由：唯一的消费者 unproject_position 要世界单位，而所有调用方手里只有米。
##    把换算钉在这里，调用方就只剩一种单位，不可能记错。
##
##    （2026-09-20 修：原来把米直接喂给 unproject_position，差 1000 倍。
##      症状是「点船选不中、场上舰船拖不动」，而且不报错、不崩溃。）
func world_to_screen(sim_meters: Vector3) -> Vector2:
	if camera == null:
		return Vector2.ZERO
	return camera.unproject_position(vec_to_world(sim_meters))


## 【世界单位】→ 屏幕像素。
##
## ⚠️ 与 `world_to_screen` 的区别只在一件事：那个吃的是**米**（仿真层口径，
##    内部会 `vec_to_world` 换算），这个吃的是**渲染层世界单位**
##    （= 视觉节点 `global_position` / AABB 那一套）。混用会得到一个
##    看起来"大致在附近、但一直偏"的坐标 —— 这种偏差最难查。
##
## ★ 2026-11-07 新增：拖放要判断「指针是不是指着这艘船的轮廓」，
##    而轮廓来自视觉层的 `hull_world_aabb()`，所以需要这条不换算的通道。
func world_unit_to_screen(w: Vector3) -> Vector2:
	if camera == null:
		return Vector2.ZERO
	return camera.unproject_position(w)


## 屏幕坐标 → 【世界单位】坐标（相机射线与 y=0 平面的交点）
##
## ⚠️ 返回的是**世界单位**，不是米 —— 因为 project_ray_origin/normal
##    本身就工作在渲染空间里。需要米的地方请显式乘 world_unit_in_meters。
##    拖放那条链（screen_to_cell）要的是世界单位，所以它直接用，不换算。
func screen_to_world(screen_pos: Vector2) -> Vector3:
	if camera == null:
		return Vector3.ZERO
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 1e-6:
		return Vector3.ZERO
	var t := -origin.y / dir.y
	return origin + dir * t


## 部署区限制：把点夹到己方部署带内
func clamp_to_deploy_zone(pos: Vector3, team: int) -> Vector3:
	var z_center := deploy_own_z if team == 0 else deploy_enemy_z
	var out := pos
	out.z = clampf(pos.z, z_center - 16.0, z_center + 16.0)
	out.x = clampf(pos.x, -arena_radius, arena_radius)
	out.y = 0.0
	return out


## 生成一组默认阵型（无格子：直接给世界坐标）
## 自走棋的「站位」在这里就是连续坐标，不是格位
## 按实际舰队射程计算部署带
##
## ⚠️ 单位约定（全工程统一）：
##   仿真层（body.position / optimal_range）一律用【米】。
##   渲染层（Node3D 位置）才做 米 → 世界单位 缩放，系数 world_unit_in_meters。
##   本函数返回的是【米】，直接喂给 body.position。
##
## ⚠️ 为什么用【中位数】而不是【最大值】：
##   数值表里射程跨度极大（5km ~ 42km）。若按最远的那艘算部署，
##   一艘 42km 的导弹舰会把全队部署拉到 63km 外，
##   导致 5km 射程的护卫舰要飞 50 多秒才能接敌 —— 一局开局就废掉。
##   用中位数保证「大部分船」开局就在合理接敌距离。
##
## 返回 [己方 z, 敌方 z]（米）。
func compute_deploy_z(own_fleet: Array, enemy_fleet: Array) -> Array:
	var ranges: Array[float] = []
	for s in own_fleet + enemy_fleet:
		if s != null:
			ranges.append(float(s.optimal_range))
	if ranges.is_empty():
		ranges.append(20_000.0)
	ranges.sort()
	# 中位数
	var mid := ranges.size() / 2
	var median := ranges[mid] if ranges.size() % 2 == 1 \
			else (ranges[mid - 1] + ranges[mid]) * 0.5
	# 但最长射程的船也不能被完全忽视：给它一个上限保护
	var longest := ranges[ranges.size() - 1]
	var basis := minf(maxf(median, 12_000.0), longest)

	var standoff_m := basis * deploy_standoff_ratio
	var half_m := standoff_m * 0.5
	# 夹在战场半径内（arena_radius 是世界单位，换算成米比较）
	half_m = clampf(half_m, 6_000.0, arena_radius * world_unit_in_meters * 0.6)
	return [half_m, -half_m]


## 部署阵型（返回【米】坐标，直接喂给 body.position）
##
## ⚠️ 注意单位：这里是米，不是世界单位。
##    世界单位只用于 Node3D 渲染，换算见 meters_to_world()。
func default_formation(count: int, team: int, formation: String = "") -> Array[Vector3]:
	# ★ 2026-10-23：敌方站位模板（FRONT/BACK/SPREAD/ESCORT/WEDGE）从这里开始生效。
	# ⚠️ 站位算式只有一份真相源 = EveEnemyComps.formation_positions()，
	#    本函数只负责把「我方 z 中心 / 方向符号」交给它。
	var z_center := deploy_own_z if team == 0 else deploy_enemy_z
	var sign_z := -1.0 if team == 0 else 1.0
	if formation != "":
		return EveEnemyComps.formation_positions(formation, count, z_center, sign_z)
	var out: Array[Vector3] = []
	# 阵型间距按「米」给。
	# ⚠️ 间距决定开局画面观感：太大会让镜头被迫拉远，舰船缩成小点。
	#    实测 12km/8km 时包围盒宽约 36km，镜头拉到能装下 40 单位，
	#    单船只剩几个像素。收到 8km/6km 后仍是标准自走棋 4 列布局，
	#    但画面明显更聚焦。
	var col_step := 8_000.0
	var row_step := 6_000.0
	for i in count:
		var row := i / 4
		var col := i % 4
		var x := (float(col) - 1.5) * col_step
		var z := z_center + sign_z * float(row) * row_step
		out.append(Vector3(x, 0.0, z))
	return out


## 米 → 世界单位（仅渲染层使用）
func meters_to_world(meters: float) -> float:
	return meters / maxf(1.0, world_unit_in_meters)


## 米坐标 → 世界单位坐标（仅渲染层使用）
func vec_to_world(meters_vec: Vector3) -> Vector3:
	return meters_vec / maxf(1.0, world_unit_in_meters)
