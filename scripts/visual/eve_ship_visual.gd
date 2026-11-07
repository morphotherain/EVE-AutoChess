extends Node3D
class_name EveShipVisual

## EVE 自走棋 —— 舰船可视节点
##
## 舰体有两条路：
##   ① **真实模型**（默认）：`EveShipModel.instantiate(ship.ship_key)`
##      加载 `res://assets/ships3d/<id>.glb` —— 52 艘官方网格 + 官方贴图。
##   ② **程序化占位体**（退回）：模型缺失时用方块堆出工业几何舰体。
##      这条路径**必须保留**：没有它，任何一艘船缺资产就会变成一个空白节点，
##      而且会安静地失败 —— 恰恰是"点了惩罚者级上来别的船"那种事故的温床。
##
## ⚠️ 模型与立绘的关联靠 **ship_key（= 船表 id）**，不是靠名字相似：
##    立绘 `assets/ships/<id>.png`、模型 `assets/ships3d/<id>.glb`，
##    两个地方都传同一个 `ship.ship_key`，结构上不可能取到别的船。
##    对账工具：`tools/verify_ship_assets.tscn`（会把 52 个 glb 载进来量尺寸）。
##
## 变更清单（接真实模型版）：
##   - _build_hull() 改为分流：有模型走 _build_hull_model()，否则 _build_hull_boxes()
##   - 新增 _build_hull_model()：按 max_dim_m 归一化缩放 + 长轴对齐到 +Z
##   - 新增常量 HULL_REF_LENGTH / MODEL_YAW_FIX
##   - 血条 / 标签 / 姿态 / 朝向跟随 等外层逻辑一行未动

var ship: EveShip = null
var hull_root: Node3D = null
var label_root: Node3D = null
## 舰体模型根（`Model_<key>`）—— 只给 `hull_world_aabb()` 用。
## ⚠️ 别拿 `hull_root` 代替它：`hull_root` 下还挂着护盾特效与喷口，
##    量出来的包围盒会把护盾椭球算进去（比船体大一圈，见 2026-11-07 实测）。
var model_root: Node3D = null

var _shield_bar: MeshInstance3D = null
var _armor_bar: MeshInstance3D = null
var _hull_bar: MeshInstance3D = null
var _name_label: Label3D = null
var _stance_label: Label3D = null
## 敌我识别（2026-10-27）
##   方案 D：血条外框染阵营色 + 名字前 ▲/◆ 徽标
##   方案 B：名牌底板（半透明深色托住名字）+ 左侧阵营色条
## 两个方案都实装了，用 team_id_mode 切换对比。
var _team_frame: MeshInstance3D = null
var _team_frame_mat: StandardMaterial3D = null
var _name_plate: MeshInstance3D = null
var _name_stripe: MeshInstance3D = null
## 敌我识别模式：0 = 关 · 1 = 方案D · 2 = 方案B
var team_id_mode := 1

## ── 敌我识别配色（方案 D）─────────────────────────────────
## ★ 2026-10-27 用户：「颜色不是很喜欢，去掉荧光色」。
##   原来那组是 (0.35,0.95,1.00) 青 / (1.00,0.32,0.26) 红 ——
##   饱和度和明度都顶到格，在暗星空上像霓虹灯，久看刺眼。
##   现在换成**低饱和金属色**：钢蓝 / 砖红，压暗但保留足够对比度。
##
## 双编码仍然保留：色相 + 明度都错开。红蓝在色盲视角下可能同亮度，
## 所以敌方的红更暗、我方的蓝更亮，不靠单一通道判断。
const TEAM_OWN := Color(0.44, 0.64, 0.80)      ## 我方：钢蓝
const TEAM_FOE := Color(0.78, 0.40, 0.33)      ## 敌方：砖红

var _last_pos: Vector3 = Vector3.ZERO
var _visual_scale: float = 1.0

## ── 舰艏对齐（**红线 46**：舰艏 ≡ 前进方向 ≡ 速度方向）──────────────
##
## 见 `sync_from_body()` 上方那段长注释。这里只说数据：
##   · `_bow_local` / `_up_local` —— 模型空间里「哪根轴是舰艏 / 哪根轴是船背」
##   · `_bow_align` —— setup 时**烘焙一次**的常量矩阵 C，
##     把「零姿态下的 (舰艏, 船背, 侧向)」整体搬到标准基 `(−Z, +Y, +X)`。
##     有了 C，运行时只要 `Basis.looking_at(速度方向, 上)` 左乘 C 就得到目标姿态，
##     **不需要**知道这艘船的模型长轴在 X 还是 Y、舰艏朝哪端。
##   · `_facing_quat` —— 当前姿态（就是本节点的 quaternion）。
##
## ⚠️ 旧的 `var _facing: float`（绕 Y 的偏航角）**已删除**：它只有一个自由度，
##    舰艏轴不在水平面时**数学上无解**（见红线 46），留着就是事故的种子。
var _bow_local := Vector3(1.0, 0.0, 0.0)
var _up_local := Vector3(0.0, 1.0, 0.0)
var _bow_align := Basis.IDENTITY
var _facing_quat := Quaternion.IDENTITY
var _has_align := false

## 是否处于「布阵态」—— 棋盘显形时为 true，船会放大 BOARD_EXAGGERATION 倍。
##
## 由 EveBattleArena.set_ships_board_mode() 统一驱动（别在别处直接改）。
var board_mode := false

## 米 → 世界单位 的换算系数。
## ⚠️ 仿真层(body.position)用的是【米】，Node3D 用的是【世界单位】。
##    1 世界单位 = 1000 米（相机架在 ~170 单位高，对应 170km 的战场视野）。
##    少了这层换算，舰船会被摆到几十万单位外，相机完全看不到。
const METERS_PER_UNIT := 1000.0

## 真实模型归一化后的目标船长（世界单位）。
## 与程序化占位体的基准船长**取同一个值**，两条路出来的体量才一致，
## 缺模型的船不会突然变成另一个大小。
const HULL_REF_LENGTH := 2.6

## glb 里舰船的长轴是 **+X**（Blender 侧 orient_ship 把长轴对齐到 +X，
## glTF 的 Y-up 转换只动 Y/Z，X 不变）；而本节点的朝向约定是 **长轴 +Z**
## （_build_hull_boxes 与 sync_from_body 的 atan2(v.x, v.z) 都是按 +Z 设的）。
## 所以绕 Y 转 −90°：+X → +Z。
##
## ⚠️ 这只是**基准**，不是全船共用的最终值 —— 它假设「52 艘的长轴都在 +X
##    且舰艏都朝 +X」，实测**两层都不成立**：
##      · condor / raven / tristan 的长轴不在 X 上 ⇒ 会斜着飞
##      · 另有 25 艘舰艏在主轴反向 ⇒ 会倒着飞
##    逐艘修正走 `EveShipYawTable`（那边是唯一真相源，含用户逐艘目视标定的名单）。
##    本常量保留，因为它仍是那 20 艘「本来就对」的船的全部修正量。
## ⚠️ 这个值必须靠**截图**确认，不能靠推理 —— 方向猜反了船会横着飞，
##    而尺寸、血条、位置全都正常。
const MODEL_YAW_FIX := -PI / 2.0

## 舰船模型的视觉缩放系数
##
## ⚠️ 先理清三个尺度，否则一定调错：
##    1. 真实物理长度：护卫舰约 40 m，巡洋舰约 130 m（EVE 信号半径量级）
##    2. 基准网格：_build_hull() 里的船体长 2.6「世界单位」
##    3. 战场尺度：1 世界单位 = 1000 m，交战包围盒约 15~40 世界单位
##
##    也就是说基准网格 (2.6) 已经是「视觉尺度」了，不需要再放大。
##    真实比例会是 130m/1000 = 0.13 单位 —— 那个才需要 ~20x 夸张，
##    但我们没有按真实比例建模，所以这里只用 ~2.0 做细调。
##
##    实测教训：曾把它填成 12（误以为要从真实米换算），
##    结果单船长 31 单位 > 战场半宽 20 单位，一艘船糊满整个屏幕；
##    后来矫枉过正改成 0.75，单船缩到只有几个像素、和血条比例失衡。
##
## 目标：舰船读得出轮廓，但一屏能装下整支舰队。
##   改这个常数前请先看 eve_battle_arena.gd 的 deploy_standoff_ratio ——
##   两者共同决定构图，单独调一个必然顾此失彼（踩过两次坑）。
##   实测 CHANGELOG：
##     12.0  -> 单船长 47 单位 > 战场半宽，一艘船糊满屏（错在把「米→世界单位」当成缩放系数）
##     0.75  -> 矫枉过正，单船只剩几个像素，和血条比例失衡
##     2.0   -> 又偏大，船体互相遮挡并溢出画幅边缘
const VISUAL_EXAGGERATION := 1.20

## 血条 / 文字 的独立缩放系数
##
## 与 VISUAL_EXAGGERATION 解耦的理由：血条和文字是「信息层」，
## 它的尺寸要跟着「船在屏幕上的大小」走，而不是跟着船体放大倍数走。
## 取 1.0 时，血条宽度 ≈ 1.3 x 吨位系数，约为巡洋舰船长的 1/4 —— 恰到好处。
const BAR_SCALE := 1.0

## ── 布阵态放大倍率（用户 2026-09-20 要求）────────────────────────
##
## 原话：「现在舰船在棋盘上太小了，给我放大三倍看看，最小也要放大两倍」。
##
## 实测依据（probe_view，1920×1080，我方部署区取景 frame_own_zone，
## 一格在屏幕上 56 px）：
##     VISUAL_EXAGGERATION 1.20                  → 船长 22 px = **0.39 格**
##     乘 2 → 2.40                               → 船长 43 px = 0.77 格
##     乘 3 → 3.60                               → 船长 65 px = 1.16 格
## 0.39 格意味着棋盘上 5 艘船加起来还没铺满 2 格 —— 既看不清轮廓，
## 也点不中（拖拽命中半径 PICK_RADIUS=60px，而船才 22px 长）。
##
## ⚠️ 为什么是「布阵态专属」而不是直接改 VISUAL_EXAGGERATION：
##    战斗态的 1.20 是与 deploy_standoff_ratio 一起调出来的构图
##    （见 eve_battle_arena.gd 那段说明），单改一个必然顾此失彼。
##    而布阵时棋盘是静止的「布阵台」，
##    玩家此刻要的就是「看清自己在拖哪一艘」—— 两个场景诉求不同，
##    所以拆成两个态，由 set_board_mode() 切换。
##
## ⚠️ 3.0 的代价（如实记录，**2026-11-07 用实测量测校正过**）：
##    公式推算：最大一艘战列 `灾难级`（系数 1.4175）⇒
##    2.6 × 1.4175 × 1.2 × 3 ≈ **13.3 世界单位 = 2.21 格**。
##    ⚠️ 但**实测**（1920×1080 棋盘取景，只量 `Model_*` 子树的投影 AABB）
##    战列 abaddon 的世界包围盒 z = **20.51 单位 = 3.42 格**，投影 108×284 px
##    —— 比公式推算大 1.5 倍。
##    [WHY] 公式里的 2.6「基准船长」只是船体主段，模型自身还带着伸出的艏艉/翼板；
##          「看着多大」是 AABB 说了算，不是主段长度说了算。
##    [SRC] `docs/方案-准备阶段棋盘模式-2026-11-07.md` 第 7.3 / 7.4 节
##    ⇒ 实测口径下，战列摆在最后一行时船尾会越过棋盘下沿约 130px（被商店面板压住）。
##    若要「绝不跨格」，上限是 2.0（0.77 格）。改这一个数即可；
##    ⛔ 但别改成「按船大小钳制倍率」—— 那会破坏吨位可比性（2026-09-28 定案）。
const BOARD_EXAGGERATION := 3.0

## 血条与标签悬浮在船体上方的基准高度（本地空间，会再乘 label_root.scale）
const LABEL_HEIGHT := 0.95

## 血条基准宽度（本地空间，会再乘 label_root.scale）
## ⚠️ 修改后必须同步 _set_bar() 里的左对齐补偿 —— 两处用的是同一个常量。
const BAR_WIDTH := 1.60

## ── 朝向跟随（红线 46 → 45 轮改为「朝目标优先」）─────────────────
##
## 舰艏追**目标方向**（无目标时追速度方向）的**每帧插值权重**（四元数 slerp）。
## 越大转得越快、越小越"重"。
##
## ⚠️ 45 轮从 `0.12` 调到 `0.40` —— **理由是量化的，不是手感**：
##   旧值 0.12 在「环绕 + 目标机动」下，转向角速度**追不上目标方位的漂移**，
##   真窗口实测 `bow·敌向` 稳态只有 **0.81~0.89**（≈27~36° 滞后）——
##   用户 45 轮投诉的「舰艏和敌人方向垂直，不是相对的」正是这个。
##   （⚠️ 用户说"垂直"是**画面上长期观察到的印象**；实测是 27~36°，不是 90°。）
##   0.28 → 最低 0.964（≈15°）仍偶有超阈；**0.40 → 最低稳定在 0.99 以上**（≈8° 以内）。
##   调 1.0 = 硬跟（会抖，且失去"船有惯性"的观感）；**上限建议不超过 0.5**。
##   量化判据见 `tools/probe_bow_to_target.tscn`（① 有目标时 `bow·敌向` 最低值）。
const FACING_LERP := 0.40

## 低于这个速度（**米/秒**）就不更新朝向。
## 阈值存在的理由：速度趋 0 时方向本身是数值噪声，跟着抖会让船原地抽搐。
const MOVE_EPS := 1.0

## ── ★ 46 轮：舰艏「角速度上限」────────────────────────────────────
##
## 物理依据（用户 46 轮的论断，这里给工程形式）：
##   「车头方向」= **车身朝向**，是**独立于速度**的自由度；
##   改它只有一条路径 —— **转向**，而转向**需要时间**（有角速度上限）。
##   "前进/后退"不改车头方向（倒车时车头仍朝前）。`aim_dir` 就是这个车身朝向。
##
## 为什么光有 `FACING_LERP` 不够（实测证据）：
##   slerp 权重是"比例趋近"，**不设上限** ⇒ 当输入信号本身跳变时，
##   一帧内就会被拉走一大截。实测 `probe_brake_flip`：
##     · `aim_dir` 相邻采样跳 53.3° / 28.3° / 44.3°（**换目标瞬间**：
##       `target_id` 从 A 船变 B 船 ⇒ `tgt.pos − ship.pos` 整根向量换向）；
##     · 舰艏跳幅 49.1° / 26.1° / 40.5° —— **与信号完全同步**，
##       说明跳变是输入的**直接下游**，不是插值不稳。
##   ⇒ 用户看到的会是"船头啪地甩过去"，非常出戏。
##
## 本闸门做的事：把 slerp 的结果**再限一次速** ——
##   单帧转角不得超 `FACING_MAX_DEG_PER_SEC / 60`。
##   它是**钳位（clamp）不是缩放**：正常小角度完全不受影响，
##   只有异常大角才被截断 ⇒ 对既有 52 艘的稳态观感**零变化**。
##
## 取值论证：EVE 里巡洋舰的角速度量级约 **10~30 °/s**（转 180° 需 6~18 秒）。
##   取 `90.0 °/s` = 转 180° 需 2 秒 —— 比 EVE 实船快，但足以：
##     ① 让 `FACING_LERP 0.40` 的正常跟随（每帧约 1.3°，远低于闸门）**不受影响**；
##     ② 把 50° 级的"换目标甩头"压成一段 **0.55 秒的可见转向动画**。
##   ⚠️ 这个值只影响**突变**；稳态 `bow·敌向` 由 `FACING_LERP` 决定，不受它影响。
const FACING_MAX_DEG_PER_SEC := 90.0

## 每帧（假定 60 FPS）允许的最大转角 —— 探针按同样公式校验。
static func facing_max_step_deg(delta: float) -> float:
	return FACING_MAX_DEG_PER_SEC * maxf(delta, 1.0 / 240.0)


func setup(p_ship: EveShip) -> void:
	ship = p_ship
	# ★ 2026-09-28：体型 = 吨位档基准 × 档内按真实长轴微调（逐船，见 scale_for_ship）。
	#   ⚠️ 旧写法是 `_scale_for_class(ship.ship_class)` 的 3 档 match，
	#      **战巡 / 战列掉进 `_` 默认 1.0** ⇒ 巡洋(1.35) 反而比战列(1.00) 大。
	_visual_scale = scale_for_ship(ship.ship_key, ship.ship_class)

	hull_root = Node3D.new()
	hull_root.name = "Hull"
	add_child(hull_root)
	_build_hull()

	label_root = Node3D.new()
	label_root.name = "Labels"
	add_child(label_root)
	# ★ 2026-10-27（用户：「血条堆叠」）：标签层**脱离船体旋转**。
	#   理由见 `_sync_label_transform()`；不设 top_level 的话，
	#   屏幕空间的垂直避让偏移会跟着船体的俯仰/滚转一起歪。
	label_root.top_level = true
	_build_bars()
	_build_labels()
	# 敌我识别（必须在 _build_labels 之后：要改它刚建好的标签颜色）
	_build_team_id()
	# 指挥层标记（2026-10-27）：谁领头 / 谁被集火
	_build_command_badges()

	# 船体与信息层的缩放。两种态的差异见 BOARD_EXAGGERATION 的说明，
	# 实现在 _apply_scale() 里（切换布阵态时也要走同一条路径，别抄第二份）。
	_apply_scale()

	_last_pos = ship.body.position
	position = ship.body.position / METERS_PER_UNIT
	_sync_label_transform()

	# 护盾壳：开发期可见，用来确认贴花落在壳面的哪里
	_ensure_shield_fx()

	# ★ 2026-10-27：先跑一次血量/标签判定 —— 否则布阵态的满血船会带着
	#   「默认可见」的三条满血条出场（血条现在只在关键船 / 受伤船显示）。
	_update_bars()


## 切换「布阵态」—— 棋盘显形/隐藏时由 arena 广播下来。
##
## 幂等：重复设同值不会重复乘（这里每次都是**按基准重算**，不是累乘）。
func set_board_mode(on: bool) -> void:
	if board_mode == on:
		return
	board_mode = on
	_apply_scale()
	# ★ 2026-10-27：布阵态不做屏幕避让（格子布局本来就分得开），
	#   ⇒ 进布阵时把避让偏移与降透明度归零，避免残留上一场的位置。
	if on:
		_label_offset = 0.0
		_label_offset_want = 0.0
		_label_dim = 1.0
		_label_dim_want = 1.0
		_apply_label_dim()
		_sync_label_transform()


## 把基准缩放写进 hull_root / label_root。
##
## ⚠️ 一律「按基准重算」而不是「乘一个增量」——
##    累乘的写法在「连续开关两次」后就会漂到 9 倍，
##    而且不会报错，只会表现为「船莫名其妙变巨了」。
func _apply_scale() -> void:
	if hull_root == null:
		return
	var mul := BOARD_EXAGGERATION if board_mode else 1.0
	hull_root.scale = Vector3.ONE * (_visual_scale * VISUAL_EXAGGERATION * mul)
	# ⚠️ label_root 用独立的 BAR_SCALE，不与船体共用系数。
	#    原因：船体被放大了 VISUAL_EXAGGERATION 倍，
	#    如果血条只乘 _visual_scale，血条相对船体就会显得越来越短、
	#    最后缩成船肚子上的一条小杠（实测过：船变大后血条反而看不懂）。
	#    但也不能乘满 VISUAL_EXAGGERATION，否则标签会盖住半个战场。
	#    布阵态跟着乘 mul：那时玩家在「看清这一艘」，信息层放大是收益。
	if label_root != null:
		label_root.scale = Vector3.ONE * (_visual_scale * BAR_SCALE * mul)


## 船体在**世界空间**的包围盒 —— 「玩家眼睛看到的那个轮廓」。
##
## ★ 2026-11-07 为什么要它（拖放互换）：
##   布阵态舰船放大 3 倍后，船体在屏幕上远大于它占的那一格
##   （战列实测竖跨 3.4 格、投影 284px）。玩家按「把 A 拖到 B 身上」的直觉松手时，
##   指针往往落在 B 的**邻格**，于是 A 被放到旁边 —— 看起来像「互换没生效」。
##   ⇒ 用这个包围盒做「指针是否指着这艘船」的判据，比按格判定符合直觉。
##
## ⚠️ 只遍历 `model_root`（`Model_<key>`）：
##    `hull_root` 下还有 `ShieldImpacts`（护盾椭球，比船体大一圈）与喷口，
##    混进来会让"船"凭空大一号，吸船范围跟着虚胖。
## ⚠️ 返回的是**世界单位**（渲染层），不是仿真层的米。
func hull_world_aabb() -> AABB:
	# ⚠️ 用 `is_instance_valid`，不能写 `== null`：
	#    占位体那条分支里 `model` 已经 `queue_free()`，留下的是"非 null 的
	#    已释放对象"，`== null` 判为 false，接着递归就会访问野指针。
	#    那种船没有真实模型 ⇒ 返回空盒 = 不参与"吸到船体"（按格判定照旧）。
	if not is_instance_valid(model_root):
		return AABB()
	var acc := AABB()
	var has := false
	var stack: Array[Node] = [model_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var a: AABB = mi.global_transform * mi.get_aabb()
			if has:
				acc = acc.merge(a)
			else:
				acc = a
				has = true
		for ch in n.get_children():
			stack.append(ch)
	return acc if has else AABB()


# ------------------------------------------------------------------ 舰体

## ══════════════════════════════════════════════════════════════════
##  ★ 舰船体型刻度（用户 2026-09-28 定案）
## ══════════════════════════════════════════════════════════════════
##
## ── 用户口径（原话）──────────────────────────────────────────────
##    「以现在暴君级的大小为最大、因卡萨斯级的大小为最小，中间分 10 级：
##      护卫=1、驱逐=3、巡洋=6、战巡=8、战列=10」
##
## ── 为什么必须**两步**：吨位定基准 → 档内按真实长轴微调 ──────────
##    真实长轴在 EVE 里**跨吨位乱序**（实测全库 52 艘）：
##      巡洋 奥格诺 175 m  **比驱逐 阿尔格斯 239 m 还短**
##      护卫 伐木者 172 m  ≈ 巡洋 奥格诺
##    ⇒ 只按真实米数排 ⇒ 会出现「巡洋比驱逐小」。所以**吨位必须先定基准**。
##
## ── 档内带宽上限是**几何决定**的，不是审美选的 ────────────────────
##    相邻档不重叠要求 基准₁×(1+S) ≤ 基准₂×(1−S)
##    ⇒ S ≤ (基准₂−基准₁)/(基准₁+基准₂)，逐对算：
##      护卫/驱逐 9.36% · 驱逐/巡洋 11.37% · 巡洋/战巡 6.36% · **战巡/战列 5.66%**
##    最紧的是「战巡/战列」⇒ 取 **5%**（留一点余量）。
##    ⚠️ 取 10% 会有 3 处重叠（出现「巡洋 > 战巡」「战巡 > 战列」），
##       正是用户原先抱怨的那个毛病。
##
## ⚠️ 2026-10-27：**缩到 2%**。上面那套上限算的是「长度」，而 2026-10-27 起
##    屏幕最长轴还多乘了一个「体积等效」倍率（见下），最紧的「战巡/战列」
##    只剩 6% 余量 ⇒ 原来的 ±5% 会把它吃光（探针 ④ 段实测重叠 0.22）。
##    缩到 ±2% 后四段全部不重叠。「档内微调」本来就是锦上添花，
##    而「档与档要分得开」才是用户的核心诉求 —— 两害相权取其轻。
const CLASS_SCALE_SPREAD := 0.02

## ══════════════════════════════════════════════════════════════════
##  ★ 2026-10-27：体型口径从「只钉最长轴」改成「体积等效尺度」
## ══════════════════════════════════════════════════════════════════
##
## ── 用户原话 ─────────────────────────────────────────────────────
##   「我现在发现巡洋，尤其是暴君等船那是真的大，比战列都大，
##     把区别改大一点」
##
## ── 病根 ─────────────────────────────────────────────────────────
##   旧口径把**最长轴**钉到档基准长，宽/高照真实比例走
##   ⇒ 敦实的船白赚体积。实测（跑 `tools/probe_ship_bulk.tscn`）：
##     暴君级（巡洋）体积指数 21.7 vs 地狱天使级（战列）5.11 —— 差 4.2 倍，
##     而两者屏幕**长度**只差 1.27 倍。
##   ⇒ 玩家看到的「大」是**体积**，不是长度 —— 只钉长度治不了。
##
## ── 新口径 ───────────────────────────────────────────────────────
##   定义「体积等效尺度」 E = 长^w × 体积^((1-w)/3)（单位：米），再取
##      屏幕最长轴 = 档基准 × (真实长 / E)
##   即「E 相同 ⇒ 屏幕上看着一样大」。
##
##   ★ 关键化简（`tools/probe_ship_bulk.tscn` ⑤ 段有推导与实测）：
##       体积指数 = 档基准³ × c^w ，其中 c = 横梁×高度/长轴²（「紧缩度」）
##     ⇒ 同档内的体积差**只**由 c 决定；档与档之间**只**由档基准决定。
##     ⇒ 档序不重叠的充要条件：3·ln(B_hi/B_lo) ≥ w · ln(c_max_lo / c_min_hi)
##       左＝可调的档差，右＝形状噪声（w 是它的系数）。
##
##   ⚠️ **w 是硬上限，不是口味问题**。实测（探针 ⑤ 段「相邻档允许的最大 w」，
##     当时档差 1.94 倍 / 档内 ±5%）：护卫→驱逐 0.222 · 驱逐→巡洋 0.760 ·
##     巡洋→战巡 0.163 · **战巡→战列 0.145**。最紧的一段由
##     「布鲁提克斯级（c=0.41）↔ 鹏鲲级（c=0.039）」决定 —— 紧缩度差 10.5 倍。
##   ⇒ 档差与档内微调**一起**放大这段噪声：档内 ±5% 等价于给每个档再多
##     乘一个 1.11 倍的不确定量，于是「战巡→战列」那一步必须再放大 1.24 倍
##     才压得住，线性档梯根本给不出（要 HIGH/LOW ≈ 8 倍，荒谬）。
##   ⇒ 最终定案：**w = 0.10 + 档内微调缩到 ±2% + 档梯拉到 2.4 倍**。
##     探针 ④ 段实测：四段档序**全部不重叠**，且各留 6%~25% 余量。
##
##   ⚠️ 有意接受的代价：同档内不同船的**长度**差变大（最长轴只按 0.30 次方
##      跟随紧缩度）—— 例：战列舰 3.84~8.09，巡洋舰 2.47~5.72。
##      因为「同档一样大」现在指**体积**一样大，细长的船只能靠更长来凑。
##      要连长度也压平，只能改成「沿舰轴非均匀缩放（压细横截面）」，
##      那是另一套实现（要逐艘知道舰轴），暂不做。
const SIZE_BLEND := 0.10

## 等级 1 / 等级 10 的**目标体积等效尺度**（米，不含 VISUAL_EXAGGERATION）。
## ⚠️ 2026-10-27 起这两个数**不再等于屏幕长度**（旧口径下是 2.184 / 4.212）：
##    屏幕最长轴 = 本值 × (真实长 / E)，逐船不同。名字保留是为了少动调用方。
const TIER_ANCHOR_LOW := 1.25
const TIER_ANCHOR_HIGH := 3.00

## 吨位 → 10 级刻度（未登记返回 0 ⇒ 调用方必须显式报错，禁隐式默认）
static func tier_level(cls: int) -> int:
	match cls:
		EveShip.Class.FRIGATE:        return 1
		EveShip.Class.DESTROYER:      return 3
		EveShip.Class.CRUISER:        return 6
		EveShip.Class.BATTLE_CRUISER: return 8
		EveShip.Class.BATTLESHIP:     return 10
		_:                            return 0


## 该吨位档的**基准体积等效尺度**（米，不含 BOARD_EXAGGERATION）。
## ⚠️ 自 2026-10-27 起它**不是**屏幕长度 —— 见 `TIER_ANCHOR_LOW` 的说明。
static func tier_base_length(cls: int) -> float:
	var lv := tier_level(cls)
	if lv <= 0:
		return 0.0
	return TIER_ANCHOR_LOW + (TIER_ANCHOR_HIGH - TIER_ANCHOR_LOW) \
			* float(lv - 1) / 9.0


## 单艘船的**屏幕最长轴**（世界单位，不含 BOARD_EXAGGERATION）
##   = 档基准 × (1 + SPREAD × (2u − 1)) × (真实长 / E)
## 最后那一项就是 2026-10-27 新增的「体积等效」修正 —— 敦实船被压小。
static func target_hull_length(id: StringName, cls: int) -> float:
	var base := tier_base_length(cls)
	if base <= 0.0:
		return 0.0
	var L := base * (1.0 + CLASS_SCALE_SPREAD * (2.0 * tier_slot_u(id, cls) - 1.0))
	var e := size_metric(id)
	if e <= 0.0:
		return L
	return L * max_dim_m(id) / e


## 「体积等效尺度」E = 长^SIZE_BLEND × 体积^((1−SIZE_BLEND)/3)（米）。
## 0 表示索引里查不到该船（调用方必须显式退回，别静默给默认值）。
static var _size_metric_cache: Dictionary = {}
static func size_metric(id: StringName) -> float:
	if _size_metric_cache.has(id):
		return _size_metric_cache[id]
	var out := 0.0
	var a := max_dim_m(id)
	if a > 0.0:
		var v := volume_m3(id)
		if v > 0.0:
			out = pow(a, SIZE_BLEND) * pow(v, (1.0 - SIZE_BLEND) / 3.0)
	_size_metric_cache[id] = out
	return out


## 真实包围盒体积（m³）＝ 三轴之积。`ShipAsset.dims` 已排序，取最大者当长轴。
static var _volume_cache: Dictionary = {}
static func volume_m3(id: StringName) -> float:
	if _volume_cache.has(id):
		return _volume_cache[id]
	var out := 0.0
	for a in EveShipAssetIndex.all():
		if a == null:
			continue
		if StringName(a.id) != id:
			continue
		var b := 0.0
		var h := 0.0
		var l := 0.0
		var k := 0
		for v in a.dims:
			match k:
				0: b = float(v)
				1: h = float(v)
				2: l = float(v)
			k += 1
		if k >= 3 and b > 0.0 and h > 0.0 and l > 0.0:
			out = b * h * l
		break
	_volume_cache[id] = out
	return out


## 该船的真实最长轴（m）—— 转发 `EveShipModel`，加一层 0 保护。
static func max_dim_m(id: StringName) -> float:
	return maxf(0.0, EveShipModel.max_dim_m(id))


## 档内位置 u ∈ [0,1]：0 = 本档真实长轴最短，1 = 最长。
## 同吨位的船**只有这一项**不同 —— 这就是「按实际长轴微调」的全部来源。
static func tier_slot_u(id: StringName, cls: int) -> float:
	var span := tier_real_span(cls)
	if span.y <= span.x:
		return 0.5
	var r := EveShipModel.max_dim_m(id)
	if r <= 0.0:
		return 0.5
	return clampf((r - span.x) / (span.y - span.x), 0.0, 1.0)


## 本吨位档的「真实长轴」跨度 `[最短, 最长]`（米）—— 扫索引一次并缓存。
##
## ⚠️ **不写死**：船表增删或改尺寸后自动跟着变（写死就会漂）。
static var _tier_span_cache: Dictionary = {}
static func tier_real_span(cls: int) -> Vector2:
	if _tier_span_cache.has(cls):
		return _tier_span_cache[cls]
	var lo := INF
	var hi := -INF
	for a in EveShipAssetIndex.all():
		if a == null:
			continue
		if int(EveShip.CLASS_BY_COST.get(int(a.cost), -1)) != cls:
			continue
		var m := 0.0
		for v in a.dims:
			m = maxf(m, v)
		if m > 0.0:
			lo = minf(lo, m)
			hi = maxf(hi, m)
	var out := Vector2(lo, hi) if hi > 0.0 else Vector2.ZERO
	_tier_span_cache[cls] = out
	return out


## `_visual_scale` = 目标船长 / (HULL_REF_LENGTH × VISUAL_EXAGGERATION)
##
## ⚠️ 未登记的吨位档**不许静默退回 1.0**（那会让船悄悄变成"默认大小"）：
##    必须打日志点名，与红线「禁隐式默认」一致。
static func scale_for_ship(id: StringName, cls: int) -> float:
	var L := target_hull_length(id, cls)
	if L <= 0.0:
		push_warning("EveShipVisual: 吨位档 %d 未登记体型（id=%s）⇒ 退回 1.0" % [cls, id])
		print("[EveShipVisual] 吨位档未登记体型：cls=%d id=%s" % [cls, id])
		return 1.0
	return L / (HULL_REF_LENGTH * VISUAL_EXAGGERATION)


## ⚠️ 2026-09-28 已**删除**旧的 `_scale_for_class()`（3 档 match）。
##    它只写了 FRIGATE/DESTROYER/CRUISER，**战巡与战列掉进 `_` 默认 1.0**
##    ⇒ 巡洋(1.35) 比战列(1.00) 还大 —— 正是用户报的「暴君级比所有船都大」。
##    替换为上面的 `scale_for_ship()`（吨位档基准 + 档内按真实长轴微调）。
##    ⚠️ 别再把「按吨位给一个数」的写法加回来：同吨位也要有真实长轴的微差。


## 舰体分流：有真实模型就用真实模型，否则退回程序化占位体。
##
## ⚠️ 两条路**都必须**在末尾调 `_capture_bow_axes()` 烘焙对齐矩阵 ——
##    少了这一步 `_has_align` 为 false，`sync_from_body` 会整段跳过，
##    船就静止在 setup 姿态一动不动（不报错，只是"这船怎么不转身"）。
func _build_hull() -> void:
	var model := EveShipModel.instantiate(ship.ship_key)
	if model != null:
		_build_hull_model(model)
	else:
		_build_hull_boxes()


## 记下「零姿态」的舰艏轴 / 船背轴，并烘焙常量对齐矩阵 C（红线 46）。
##
## `geo_basis` = 几何体在本节点局部空间里的**纯旋转**（必须已经正交归一化，
## 见红线 41 —— 带缩放的 basis 读出来会把方向拉歪）。
##
## ⚠️ 为什么必须在 setup 时烘焙、而不是每帧重算：
##    C 是**常量**，每帧重算是白白烧 CPU；更重要的是它把「这艘船的长轴在
##    模型 X 还是 Y、舰艏在 + 端还是 − 端」这类**只有标定表知道的信息**
##    一次性吸收掉，运行时代码因此可以对 52 艘船**完全无差别**。
static func _make_align(bow0: Vector3, up0: Vector3) -> Basis:
	# up0 可能因为浮点/标定残差与 bow0 不完全垂直 ⇒ 先正交化，
	# 否则 Basis() 里会塞进一个非正交基，Quaternion(basis) 会给出歪的四元数。
	var b := bow0.normalized()
	var u := up0 - b * b.dot(up0)
	if u.length_squared() < 1e-8:
		u = Vector3.UP - b * b.dot(Vector3.UP)
		if u.length_squared() < 1e-8:
			u = Vector3(0.0, 0.0, 1.0) - b * b.dot(Vector3(0.0, 0.0, 1.0))
	u = u.normalized()
	var l := b.cross(u).normalized()
	# P：列 = 当前零姿态的三根轴；Q：列 = 目标标准基（Godot 前向 = −Z）
	var p := Basis(b, u, l)
	var q := Basis(Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0), Vector3(1.0, 0.0, 0.0))
	return q * p.transposed()   # C·bow0 = −Z，C·up0 = +Y，C·lat0 = +X


## 烘焙「零姿态对齐矩阵」C'（红线 46）。
##
## ═══ ★★ 46 轮修正：必须把 `geo_basis` **吸收进 C'**（旧版漏乘，全库倒飞）═══
##
## 旧版（45 轮）写的是：
##     `_bow_align = _make_align(geo_basis * bow_local, geo_basis * up_local)`
## 它的契约是「`_bow_align · (geo_basis · bow_local) = −Z`」——
## **输入是 `geo` 变换【之后】的向量**。
##
## 而运行时 `sync_from_body` 用的是：
##     `target = Basis.looking_at(f, UP) * _bow_align`
## 再把它当成**节点旋转**去乘**模型局部轴** `bow_local`
## （`geo` = 挂在 `hull_root` 下那层 `model` 节点的 `basis`，
##  即 `Basis.from_euler(0, MODEL_YAW_FIX + extra_yaw, 0) * AXIS_REMAP`）。
##
## ⇒ **两个空间不一致**：C' 期待「geo 之后」，运行时却喂「geo 之前」。
##   实测后果（`tools/probe_mbuy46.tscn` 逐艘对拍）：
##     `bow_local=(0,0,1)` → `geo*bow=(0,0,−1)` → `[旧] L·C·bow_local = (0,0,+1)`
##     ⇒ `dot(目标方向) = −1.000` = **舰艏正对反向**（背对敌人）。
##   ⚠️ 而且这个 bug **不会被静态体检抓到**：`probe_accept43e` 走的是
##     `R_y·M·bow_model = −Z` 那条路（与 `geo` 完全一致 ⇒ 52/52 全过），
##     两条路**各算各的**才是病根。**这是「机器验过 ≠ 实机对」的第 6 例。**
##
## 修法：**把 `geo_basis` 乘进 C'** ⇒  C' = C · geo_basis
##   于是 `C' · bow_local = C · (geo·bow_local) = −Z`，
##   而 `target · bow_local = looking_at(f)·(C'·bow_local) = looking_at(f)·(−Z) = f` ✔
##   ⇒ `_bow_align` 的作用域从「geo 之后」搬到「模型原始空间」，
##     与 `sync_from_body` 里 `target * _bow_local` 的用法对齐。
## ★ 48 轮：`geo_basis` 由调用方传入**不含全局滚转**的零姿态基
##   （见 `zero_pose_basis_no_roll()` 与 `_capture_bow_axes` 的说明）。
##   ⚠️ 若把滚转也传进来，运行时 `target = looking_at(f,UP)·C` 会把它**再还原回去**
##      ⇒ 滚转对屏幕姿态**完全无效**（48 轮实测：世界量 `up·天` 恒 +1.000 不变）。
func _capture_bow_axes(geo_basis: Basis, bow_local: Vector3, up_local: Vector3) -> void:
	_bow_local = bow_local
	_up_local = up_local
	_bow_align = _make_align(geo_basis * bow_local, geo_basis * up_local)
	_has_align = true


## 挂上官方 3D 模型（`assets/ships3d/<id>.glb`）。
##
## 这里只做两件事：**归一化缩放** 与 **长轴对齐**。
## 材质**已经在 EveShipModel.instantiate() 里还原过了** ——
## glb 的金属度/粗糙度是退化的（glTF 表达不了 Blender 的 ColorRamp 中间节点），
## 由 EveShipMaterial 换成 `ship_hull.gdshader` 复现那条 ramp，详见该类注释。
##
## 缩放为什么必须按每艘船算，不能给个常数：
##   EVE 的模型真实尺寸横跨 40 m（护卫）~ 1600 m（泰坦），差 40 倍。
##   给常数系数的话，要么护卫舰小到看不见，要么战列舰糊满整屏。
##   做法与 2D 立绘一致 —— **先归一化到统一参照长，再按吨位档放大**
##   （2D 那边按 alpha 包围盒归一化，见 MEMORY；3D 这边按 max_dim_m）。
func _build_hull_model(model: Node3D) -> void:
	model_root = model
	var span_m := EveShipModel.max_dim_m(ship.ship_key)
	if span_m <= 0.001:
		# 索引里查不到尺寸（理论上不会：索引 52 行齐全）→ 退回占位体，
		# 别用猜出来的缩放把船摆成巨人或跳蚤。
		model.queue_free()
		# ⚠️ 必须清掉引用：`queue_free()` 是**延迟**删除，指针会变成"非 null 的
		#    已释放对象"——`if model_root == null` 判不出来，再去 `.get_children()`
		#    就是访问野指针。`hull_world_aabb()` 因此改用 `is_instance_valid()` 判。
		model_root = null
		_build_hull_boxes()
		return
	# ⚠️⚠️ 这里**绝对不能**乘 METERS_PER_UNIT —— 踩过，症状是「一层巨大的
	#     平面几何体罩住整个镜头、天空盒被挡死、船只剩几个像素的白点」。
	#
	#     两个尺度必须分清：
	#       ① 仿真层：body.position 用【米】，除以 METERS_PER_UNIT(1000)
	#          才变成世界单位 → 这是 sync_from_body 里那一次换算，**只有那一处**。
	#       ② 模型层：glb 的坐标本来就是米，而 **Godot 里 1 glb 米 = 1 世界单位**，
	#          导入后 mesh 的尺寸直接就是「世界单位」数（巡洋舰 ≈ 300 单位）。
	#     所以「让船在屏幕上长 2.6 世界单位」只需要 `2.6 / span`。
	#     乘了 1000 就等于把船放大一千倍 —— 但它**不会报错**，
	#     看起来只是「天怎么黑了」，极难往单位上想。
	var s := HULL_REF_LENGTH / span_m
	hull_root.add_child(model)

	# ══════════════════════════════════════════════════════════════════
	#  ★★★ 47 轮最重大修正：**把 glb 内层网格的旋转提升到根节点** ★★★
	# ══════════════════════════════════════════════════════════════════
	#
	# ── 病根（2026-09-27 实测）────────────────────────────────────
	#  官方 glb 的结构**从来不是**「根 = 几何体」：
	#
	#      abaddon.glb
	#        └─ abaddon  [Node3D, basis = 单位阵]        ← 我们当成 model
	#             └─ Abaddon [MeshInstance3D, basis = R_y(180°)]   ← 几何体真身
	#
	#  实测 52 艘里**内层旋转逐艘不同**（`probe_innerrot47` 普查）：
	#      R_y(180°) 30 艘 · R_x(90°) 3 艘（catalyst/kestrel/slasher）
	#      · 120° 斜轴 2 艘（myrmidon/tristan）…
	#
	#  而 `SHIP_AXES`（`bow:+Z` 之类）说的是**网格空间**的轴，
	#  我们的 `M` / `yaw` 却全写在**根节点空间** ⇒ 两者差着那一层，
	#  于是**每艘偏的量都不一样** —— 这正是用户实机看到的
	#  「舰艏没有指向敌人，而且每艘船的舰艏指向都很不一样，很乱」。
	#
	# ── 为什么以前所有探针都是绿的（红线 40 的第 7 次现形）──────
	#  探针算的是 `v.quaternion * (model.basis * bow_local)`，
	#  而 `_bow_align` 就是照这两个值构造的 ⇒ **必然**为 1.000。
	#  它没算进「model 下面还有一层 mesh 节点」。
	#  用 `mesh.global_transform.basis`（引擎自己连乘）重测，
	#  立刻变成 **0.000**（舰艏与敌向垂直）—— 与用户 45 轮的描述逐字吻合。
	#
	# ── 修法：把内层旋转搬上来 ───────────────────────────────────
	#  `model.basis` 之后就被写成 `R_y(yaw) * M`（整体赋值，会覆盖），
	#  所以要在**写 basis 之前**把 mesh 的旋转先乘进 M，
	#  并把 mesh 自身清成单位阵 —— 几何体的世界朝向**逐像素不变**，
	#  但从此「根节点空间 ≡ 网格空间」，`SHIP_AXES` 终于作用在正确的空间。
	var mesh_rot := _bake_mesh_rotation(model)

	# ══════════════════════════════════════════════════════════════════
	#  ★★ 53 轮：`mesh_rot` **单一读源**收口（红线 53a）★★
	# ══════════════════════════════════════════════════════════════════
	#
	# ── 53 轮普查结论（`tools/probe_meshrot53`，全库 52 艘）────────────
	#   `_bake_mesh_rotation()` 的返回值与 `mesh_rot_of()` 缓存**当前完全一致**
	#   （0/52 分叉，且两个口径代进 `zero_pose_basis` 都 `52/52` 朝敌）。
	#   ⇒ 这不是一个"正在发作的 bug"，但**是一个真实的结构隐患**：
	#
	#   · `mesh_rot_of(id)`（静态缓存）  —— 实例化 glb，取 `_first_mesh()`
	#                                       （**第一个** MeshInstance3D），只读它
	#   · `_bake_mesh_rotation(model)`  —— 遍历 `model.get_children()`（**一层**），
	#                                       把所有非单位旋转的子节点 basis **累乘**
	#
	#   52 艘的 glb 都是「根 Node3D → 一个带旋转的子 MeshInstance3D」的
	#   单层单节点结构 ⇒ 两者等价。**但结构一旦变成多层/多旋转子节点就会分叉**，
	#   而分叉的表现正是 47 轮那条「**逐艘各异的乱**」——极难定位。
	#
	# ── 为什么以前的 assert 拦不住它（这是本条最该记住的点）──────────
	#   旧代码是 `assert(mesh_rot.is_equal_approx(mesh_rot_of(...)), ...)`，
	#   而 **`assert` 在 release 构建里被整个剥离**（Godot 官方行为）⇒
	#   玩家跑的 release 版里，分叉了**一声不响**。
	#   ⇒ 把"关键不变量"压在 `assert` 上 = 只在开发机上有效，等于没查。
	#
	# ── 收口做法（两条）──────────────────────────────────────────────
	#   ① **计算只走 `zero_pose_basis()` 一条路**（它内部调 `mesh_rot_of()`），
	#      `_bake_mesh_rotation()` 的返回值**降级为纯校验量**，不进任何算式。
	#      这样"生产"与"工具/探针"（都调 `zero_pose_basis`）**必然同源**。
	#   ② 校验改用**运行时分支 + 明确日志**（release 也生效），并且**不只报错、
	#      还要指明是哪艘船**——排障时一眼看到船名比看到回溯有用得多。
	#      ⚠️ 用 `_mesh_rot_mismatch_reported` 去重：这个函数在布阵期会反复调用
	#         （每次重建舰队都走一遍 `setup`），不去重会把日志刷爆。
	_warn_if_mesh_rot_diverges(ship.ship_key, mesh_rot)
	model.basis = zero_pose_basis(ship.ship_key)
	# ⚠️ 别退回「只转 MODEL_YAW_FIX」—— 那是全船共用一个值的旧写法，
	#    对长轴歪的船（斜着飞）、舰艏反向的船（倒着飞）以及上轴不在 Y 的船
	#    （滚转）都是错的。逐艘修正表是唯一真相源。
	#
	#    最终朝向 = R_y(−90° + θ) ∘ M，其中 M 是 AXIS_REMAP 的轴对齐，
	#    对绝大多数船 M = 单位阵；对 catalyst/kestrel 等滚转船，M 先把
	#    舰艏/舰背转到 +X/+Y，再做 yaw。
	#    用 basis 直接乘（而不是先 rotate_x 再 rotate_y），避免 local 轴串味。
	#
	# ⚠️ **顺序不能换**：先写 basis 再写 scale。`basis =` 是整体赋值（旋转+
	#    缩放一起换），如果先 `scale =` 再 `basis =`，缩放会被**静默清成 1**
	#    —— 船以 glb 原始尺寸（几百个世界单位）出现，不报错，只是「天黑了」。
	#
	model.scale = Vector3.ONE * s
	model.name = "Model_%s" % String(ship.ship_key)

	# ⚠️ 烘焙「舰艏对齐」常量矩阵（红线 46）。
	#    `model.basis` 里已经含了缩放 s ⇒ **必须** `.orthonormalized()` 再读方向
	#    （红线 41：带缩放的 basis 直接拿来当旋转用，方向是错的，且不报错）。
	#
	# ⚠️⚠️ **48 轮：这里必须用 `zero_pose_basis_no_roll()`，不能用 `model.basis`**。
	#    原因（实测踩过）：`C` 的契约是「把**零姿态**三轴送到 −Z/+Y/+X」，
	#    运行时算式是 `节点.quaternion = looking_at(f, UP) · C`，之后几何体
	#    **还要**再乘 `model.basis`（含全局滚转）。
	#    ⇒ 若 `C` 用含滚转的基烘焙，滚转被 `C` 吸收、运行时又被那一乘还原，
	#      两者抵消 ⇒ **滚转对屏幕姿态完全无效**（实测世界量 `up·天` 恒 +1.000）。
	#    ⇒ 滚转只表达在 `model.basis` 这一层；`C` 只管正交对齐。
	#    （`model.basis` 与 `zero_pose_basis_no_roll` 的差异**只有**全局滚转一项，
	#      见 `zero_pose_basis()` 的实现，两者同源不会漂移。）
	_capture_bow_axes(
		zero_pose_basis_no_roll(ship.ship_key).orthonormalized(),
		EveShipYawTable.bow_axis(ship.ship_key),
		EveShipYawTable.up_axis(ship.ship_key))


## ══════════════════════════════════════════════════════════════════════
##  ★ 47 轮：**零姿态算式** —— 唯一真相源，任何探针 / 工具都必须调它
## ══════════════════════════════════════════════════════════════════════
##
## ── 为什么必须抽成静态函数（红线 40）──────────────────────────────
##  此前「游戏里舰艏零姿态指向哪」这条算式在三处**各写了一份**：
##    · `_build_hull_model`（生产）
##    · `tools/probe_bow_box._axis_dir_to_world`（标定工具）
##    · `tools/probe_accept43e`（静态体检）
##  三份各自漂移过一次（39 轮的 `AXIS_REMAP` 缺失、47 轮的 `mesh_rot` 缺失），
##  每次都表现为「**机器全绿、实机全乱**」。现在收敛到这一个函数。
##
## ── 算式（★ 47 轮第二次修正：`MODEL_YAW_FIX` 已并入 M）────────────
##      `basis = R_y(extra_yaw(id)) · M · mesh_rot(id)`
##
##  ⚠️ 为什么 `MODEL_YAW_FIX(−90°)` **从算式里消失了**：
##    那一层 −90° 是工程早期"把 glb 长轴 +X 转到 +Z"的老补偿，
##    与 `AXIS_REMAP` 的 M **表达的是同一个自由度**（红线 27：只许一处）。
##    早期这么写没出问题纯属巧合（那时 M 恰好在对称位上），
##    47 轮 mesh_rot 显式化之后两份补偿会**叠加成错**。
##    ⇒ 现在 −90° **已经吸收进 `AXIS_REMAP` 表**（`tools/probe_remap47` 重算），
##      M 自己就含那 90°。**别再把它加回算式。**
##
##  其中 `mesh_rot` = glb **内层网格节点**自带的旋转（逐艘不同，见
##  `_bake_mesh_rotation`）。**漏掉它 = 47 轮那个"逐艘各异的乱"。**
##
##  ⚠️ `mesh_rot` 需要**加载 glb 才能读**（不是常量表）⇒ 这里用 `EveShipModel`
##     临时实例化一次并缓存。缓存键 = ship_id，进程内只算一次。
## ★★ 48 轮 · **全局滚转 180°**（用户实机裁决：舰船腹部朝上）。
##
## ═══ 为什么需要它 ═══
##  用户 48 轮实机反复确认：「舰船腹部朝上」（不是舰艏错、不是左右错，就是**翻了个肚皮**）。
##  而 48 轮的四层代码验证 + 实机世界量都显示 `up · (0,1,0) = +1.000`
##  ⇒ 结论：**代码里的 `up` 与用户眼里的「船背」正好差 180°**。
##
##  ⚠️ 为什么不去改 `SHIP_AXES` 的 up 符号？
##    因为那是**用户交互式标定台逐艘点出来的**（`pose_table.json`，52 艘），
##    翻了它等于宣布用户标定全错、要重标一遍 —— 用户明确拒绝「做第二遍」。
##
##  ═══ 为什么是 `R_z` 而不是 `R_y` ═══
##  三种 180° 语义完全不同（红线 37）：
##    · `R_y(180°)`（= 已有的 `GLOBAL_180`）= 原地转身，**修不了肚皮**；
##    · `R_x(180°)` = 翻跟头（舰艏上下翻 + 侧向也翻）；
##    · `R_z(180°)` = **绕机身长轴滚转** ⇒ 舰艏方位不动、左右互换、**上下颠倒** ✔
##  症状「舰艏方位正常、只是腹朝天」精确对应 `R_z(180°)`。
##
##  ═══ 作用点（红线 27：同一个 180° 只许一处）═══
##  在 `zero_pose_basis` 的**最右**乘 —— 即模型空间内的滚转，
##  对 `bow` / `up` / `side` 同时生效，不依赖任何表的符号约定。
##  ⇒ 表、工具、`AXIS_REMAP` **一律不动**（用户裁决：不改工具、不改环境）。
##
##  ⚠️ 关掉它只需把这里改成 `false` —— 一行回滚。
##
## ═══════════════════════════════════════════════════════════════════════
##  ★★★ 53 轮（第三版）· **已关闭 —— 实测证明这一刀是错的** ★★★
## ═══════════════════════════════════════════════════════════════════════
##  53 轮用 `tools/probe_roll53.tscn` 做了「含滚转 / 不含滚转」两栏全库普查
##  （**全部调生产函数**，零复刻，红线 40）。结果：
##
##      合计 52 艘
##        含滚转（即 `true`）  不达标：52   ← 52/52 船背朝 −Y = 全库肚皮朝天
##        不含滚转（即 `false`）不达标： 0   ← 52/52 舰艏朝敌 + 船背朝天
##
##  ⇒ 这一刀**不是**在修某几艘船，它**本身就是病**：
##    它把本来正确的 52 艘一次性全翻成肚皮朝天。
##
##  ═══ 为什么 48 轮会觉得"需要它" ═══
##  48 轮的现场是：运行时姿态链 `节点.quaternion = looking_at(f,UP)·C` 里的
##  `C`（`_capture_bow_axes` 烘焙）用的是 `zero_pose_basis_no_roll`，
##  而几何体自己又乘 `model.basis`（含滚转）⇒ 两处错位造成的**合成症状**，
##  被误读成"`up` 字段差 180°"，于是拿一刀全局滚转去补。
##  真正的病根是 `C` 与 `model.basis` 的基不一致（见 `zero_pose_basis_no_roll`
##  上方那段 48 轮实测记录）——**不是** `up` 符号，也不是缺一个全局滚转。
##
##  ═══ 为什么 `false` 才是对的 ═══
##  `zero_pose_basis_no_roll = R_y(yaw) · M · mesh_rot`，
##  其中 `M = AXIS_REMAP` 由 `SHIP_AXES`（**用户 52 艘逐艘标定的真值**，
##  `pose_table.json`，红线 51d）反解而来。
##  既然 `M` 已经把「舰艏轴」送到 −Z、「船背轴」送到 +Y，
##  再叠一个 `R_z(180°)` 就是**多此一举地把它翻回去**。
##
##  ⚠️ 若将来某几艘**单独**报"肚皮朝天"，正确修法是改那几艘的
##     `SHIP_AXES`（重跑标定台），**不是**把这个全局开关打开 ——
##     打开就是拿 52 艘的正确去换热那几艘。
const GLOBAL_ROLL_180 := false

## 滚转轴（模型空间）。机身长轴对应世界 Z（红线 42：敌人恒在 −Z）
## ⇒ 绕模型空间的「世界 Z 轴」滚。
const GLOBAL_ROLL_AXIS := Vector3(0.0, 0.0, 1.0)


## 零姿态基：`R_y(yaw) · M · mesh_rot` · 【可选全局滚转】。
##
##  ⚠️ 滚转必须乘在**最右**（模型空间侧）：
##      `R_z(180°) · bow = −bow` 若乘在左边则会把舰艏也翻掉 ⇒ 变成"倒着飞"。
##      正确位置 ⇒ 舰艏方位不变、只有上下/左右互换（正是用户要的"翻正肚皮"）。
static func zero_pose_basis(ship_id: StringName) -> Basis:
	var yaw := EveShipYawTable.extra_yaw(ship_id)
	var m := EveShipYawTable.axis_remap(ship_id)
	var out := Basis.from_euler(Vector3(0, yaw, 0)) * m * mesh_rot_of(ship_id)
	if GLOBAL_ROLL_180:
		out = Basis.from_euler(GLOBAL_ROLL_AXIS * PI) * out
	return out


## **不含全局滚转**的零姿态基 —— 专供 `_capture_bow_axes` 烘焙对齐矩阵 `C`。
##
## ⚠️⚠️ 48 轮实测（这个坑必须记住）：
##   `C` 的契约是「把**零姿态**三轴送到 −Z/+Y/+X」，运行时是
##       `节点.quaternion = looking_at(f, UP) · C`
##   之后几何体**还要**再乘 `model.basis`（= `zero_pose_basis`，含滚转）。
##
##   ⇒ 若烘焙 `C` 时**已经**用了含滚转的基，`C` 会把滚转"吸收"进去，
##     运行时那一乘又把它还原 ⇒ **滚转对屏幕姿态完全无效**
##     （48 轮实测症状：加 `GLOBAL_ROLL_180` 后世界量 `up·天` 仍是 +1.000 不变）。
##   ⇒ 滚转只该出现在 `model.basis` 那一层（几何体自己的姿态），
##     `C` 只负责"把舰艏对准目标方向 + 船背朝天"这个正交化动作。
static func zero_pose_basis_no_roll(ship_id: StringName) -> Basis:
	var yaw := EveShipYawTable.extra_yaw(ship_id)
	var m := EveShipYawTable.axis_remap(ship_id)
	return Basis.from_euler(Vector3(0, yaw, 0)) * m * mesh_rot_of(ship_id)


## 全局滚转矩阵（identity 或 `R_z(180°)`）—— 给需要显式合成的地方用。
static func global_roll() -> Basis:
	if not GLOBAL_ROLL_180:
		return Basis.IDENTITY
	return Basis.from_euler(GLOBAL_ROLL_AXIS * PI)


## glb **内层网格节点**的旋转（逐艘不同）—— 只算一次后缓存。
##
## 典型值（47 轮普查）：`R_y(180°)` 30 艘 · `R_x(90°)` catalyst/kestrel/slasher
## · 120° 斜轴 myrmidon/tristan。没有子网格时返回单位阵（占位体 / 空壳）。
##
## ⚠️ 只取**第一个** MeshInstance3D 的旋转：那才是几何体，其余（碰撞 / 挂点）
##    不参与朝向。取多个会把无关节点串进来（"复刻漂移"）。
##
## ★ 47 轮：静态缓存**首次被触碰时**自动把 provider 注入给 `EveShipYawTable`
##   （见 `EveShipYawTable.set_mesh_rot_provider` 的说明）——
##   这样"谁先被调用"都不会漏注入，不需要各入口各写一遍。
static func _ensure_provider() -> void:
	if _provider_installed:
		return
	_provider_installed = true
	# ⚠️ 必须是**方法引用**，⛔ 不能是 lambda：provider 存在另一个脚本的 static var 里，
	#    lambda 直接持有本脚本函数的指针；退出时若本脚本先卸载，清理那个 static var
	#    就会访问已释放内存 ⇒ 进程段错误（打完一场战斗再关游戏即触发）。
	#    普通 Callable 只记对象 ID，对象没了只是失效，不会悬空。
	EveShipYawTable.set_mesh_rot_provider(Callable(EveShipVisual, &"mesh_rot_of"))

static func mesh_rot_of(ship_id: StringName) -> Basis:
	_ensure_provider()
	if _mesh_rot_cache.has(ship_id):
		return _mesh_rot_cache[ship_id]
	var out := Basis.IDENTITY
	var inst := EveShipModel.instantiate(ship_id, false)
	if inst != null:
		var mn := _first_mesh(inst)
		if mn != null:
			out = mn.transform.basis.orthonormalized()
		inst.free()
	_mesh_rot_cache[ship_id] = out
	return out


static func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var got := _first_mesh(c)
		if got != null:
			return got
	return null


## `ship_id → mesh_rot` 的进程内缓存（glb 加载不便宜，别每帧做）。
static var _mesh_rot_cache: Dictionary = {}

## 是否已把 `mesh_rot_of` 注入 `EveShipYawTable`（见 `_ensure_provider`）。
static var _provider_installed: bool = false


## 把 glb **内部网格节点**的旋转提升到根节点，并把它清成单位阵。
##
## ── 它解决的问题（47 轮，实测）──────────────────────────────────────
##  官方 glb 的结构是「根 Node3D（单位阵）→ 子 MeshInstance3D（自带旋转）」，
##  而且**每艘船的子节点旋转都不一样**：
##
##      R_y(180°)  → abaddon / incursus / omen / rifter / thorax … (30 艘)
##      R_x( 90°)  → catalyst / kestrel / slasher            ( 3 艘)
##      120° 斜轴  → myrmidon / tristan                       ( 2 艘)
##
##  以前我们只往**根节点**写 `R_y(yaw) * M`，网格却还带着自己那层 ⇒
##  两者叠加后「每艘船偏的量都不同」，实机表现为**逐艘各异的乱**。
##
## ── 为什么必须"提升"而不是"清掉" ─────────────────────────────────
##  ⚠️ 直接把网格的 basis 清成单位阵会**改变几何体朝向**（船会侧躺）。
##  正确做法是 **`根.basis ← 根.basis ∘ 网格.basis`，再把网格清成单位阵** ——
##  这是矩阵结合律上的恒等变形，几何体的世界朝向**逐像素不变**，
##  但从此「根节点空间 ≡ 网格空间」，`SHIP_AXES` 描述的就是根节点里的轴。
##
##  ── 返回什么 ─────────────────────────────────────────────────────
##  返回被提升上来的那层旋转（调用方乘进 `model.basis`）。
##  没有子网格（占位体路径 / 空壳）时返回单位阵 —— 不会破坏旧行为。
func _bake_mesh_rotation(model: Node3D) -> Basis:
	var mesh_rot := Basis.IDENTITY
	var lifted := 0
	for c in model.get_children():
		var n3 := c as Node3D
		if n3 == null:
			continue
		var b := n3.transform.basis.orthonormalized()
		if b.is_equal_approx(Basis.IDENTITY):
			continue
		mesh_rot = mesh_rot * b
		# 只清旋转，**保留子节点的位置与缩放**（有些 glb 用子节点缩放存比例）
		var t := n3.transform
		n3.transform = Transform3D(Basis.IDENTITY.scaled(t.basis.get_scale()), t.origin)
		lifted += 1
	if lifted > 0:
		_lifted_mesh_rot = mesh_rot.orthonormalized()
	return _lifted_mesh_rot


## 最近一次 `_bake_mesh_rotation()` 提升上来的旋转 —— 只给探针 / 排障读。
var _lifted_mesh_rot := Basis.IDENTITY


## 已报过 `mesh_rot` 分叉的 ship_id（去重，避免布阵期反复重建时刷爆日志）。
##
## `setup()` 在布阵阶段**每次重建我方舰队都会重新调一次**（买船 / 拖放 / 三连），
## 不去重的话同一艘船会刷几十行同样的警告，反而把别的信号淹掉。
static var _mesh_rot_mismatch_reported: Dictionary = {}


## ★ 53 轮：`mesh_rot` **单一读源**校验（release 也生效，替换旧的 `assert`）。
##
## ── 为什么必须有这个函数 ────────────────────────────────────────────
##  `zero_pose_basis()` 读 `mesh_rot_of()`，而 `_bake_mesh_rotation()` 是
##  **另一条独立读法**（前者取「第一个 MeshInstance3D」，后者「一层子节点累乘」）。
##  两者在 52 艘现行 glb 上一致（`tools/probe_meshrot53` 实测 0/52 分叉），
##  但**没有机制保证将来一致** —— 一旦 glb 换成多层结构就会分叉，
##  而分叉的症状是「逐艘各异的乱」，从画面上根本定位不到 `mesh_rot` 这一层。
##
## ── 为什么不用 `assert` ────────────────────────────────────────────
##  ⚠️ **`assert` 在 release 构建里被整个剥离**（Godot 官方行为）。
##  把一个关键不变量押在 `assert` 上 = 只在开发机有效、玩家那边静默失效。
##  这里改用普通分支 + `push_warning` + `print`：
##     · `push_warning` 进 Godot 的警告系统（编辑器 / 调试器可见）
##     · `print` 保证**无头 / release 下也能在 stdout 看到**（排障靠它）
##
## ── 判据与容差 ────────────────────────────────────────────────────
##  角度差 > `MESH_ROT_TOL_DEG` 才报。取 1.0°：
##    · 实测 52 艘的差角全是 `0.00°`，唯三带浮点残差的是三艘 `R_x(90°)` 船
##      （catalyst / kestrel / slasher，`0.04°` —— 正交化时的浮点误差），
##    · 1.0° 对「结构分叉」这种量级（至少 90°）有巨大裕度，
##      同时又不会被 0.04° 的残差误触发。
const MESH_ROT_TOL_DEG := 1.0

func _warn_if_mesh_rot_diverges(ship_id: StringName, baked: Basis) -> void:
	# 占位体路径 / 空壳：没有子网格 ⇒ 烘焙值恒为单位阵，与缓存一致，跳过。
	if baked.is_equal_approx(Basis.IDENTITY):
		return
	var cached := mesh_rot_of(ship_id)
	var deg := rad_to_deg(Quaternion(baked).angle_to(Quaternion(cached)))
	if deg <= MESH_ROT_TOL_DEG:
		return
	if _mesh_rot_mismatch_reported.has(ship_id):
		return
	_mesh_rot_mismatch_reported[ship_id] = true
	var msg := ("[红线 53a] `mesh_rot` 双读源分叉：%s 差 %.2f° —— " +
			"`_bake_mesh_rotation()`(一层子节点累乘) 与 `mesh_rot_of()`(首个 MeshInstance3D) " +
			"结果不一致。**几何体姿态会两边各转各的**（症状：逐艘各异的乱）。" +
			"排查：glb 是否变成了「多层 / 多个带旋转的子节点」结构。") % [
					String(ship_id), deg]
	push_warning(msg)
	print(msg)


## 用方块堆叠出「工业几何」舰体 —— 符合 EVE 的粗野主义设计语言。
##
## 这是**退回路径**：某艘船没有 3D 资产时用它顶上，
## 保证画面里仍有一艘「读得出轮廓、看得出血条归属」的船，而不是空白。
##
## ⚠️ 尺度约定：这里建模用的是「1 = 1 世界单位」。
##    基准船体长 HULL_REF_LENGTH 单位（约战场宽度的 1/15），再乘 _visual_scale
##    与 VISUAL_EXAGGERATION 得到最终大小 —— 与真实模型走同一条尺度口径。
func _build_hull_boxes() -> void:
	var base_color := ship.faction_color()
	var dark := base_color.darkened(0.45)
	var light := base_color.lightened(0.18)

	var hull_mat := StandardMaterial3D.new()
	hull_mat.albedo_color = base_color
	hull_mat.metallic = 0.65
	hull_mat.roughness = 0.72

	var plate_mat := StandardMaterial3D.new()
	plate_mat.albedo_color = dark
	plate_mat.metallic = 0.70
	plate_mat.roughness = 0.80

	var trim_mat := StandardMaterial3D.new()
	trim_mat.albedo_color = light
	trim_mat.metallic = 0.55
	trim_mat.roughness = 0.62

	# 主船体：长楔形（用多个方块削出棱角）
	_add_box(Vector3(0, 0, 0), Vector3(0.90, 0.32, 2.60), hull_mat)
	# 舰艏楔形（z 正方向为前）
	_add_box(Vector3(0, -0.03, 1.55), Vector3(0.62, 0.24, 0.80), hull_mat)
	# 侧舷装甲板（左右各一，略外凸）
	_add_box(Vector3(0.46, 0.02, -0.20), Vector3(0.16, 0.36, 1.80), plate_mat)
	_add_box(Vector3(-0.46, 0.02, -0.20), Vector3(0.16, 0.36, 1.80), plate_mat)
	# 背脊结构块（粗野主义的几何扶壁）
	_add_box(Vector3(0, 0.24, -0.30), Vector3(0.32, 0.18, 1.00), plate_mat)
	_add_box(Vector3(0, 0.36, -0.80), Vector3(0.20, 0.16, 0.40), trim_mat)
	# 舰桥（靠后）
	_add_box(Vector3(0, 0.22, 0.60), Vector3(0.26, 0.20, 0.32), trim_mat)
	# 引擎块（尾部）
	_add_box(Vector3(0, 0, -1.55), Vector3(0.54, 0.30, 0.36), plate_mat)

	_build_engines()

	# ⚠️ 占位体的建模约定是「**局部 +Z = 舰艏**」（见上面 `# 舰艏楔形（z 正方向为前）`），
	#    而战场约定是「敌人在世界 −Z」⇒ 不转 180° 的话占位体会**倒着飞**。
	#    ⚠️ 用 `rotation.y` 而**不是** `basis =`：后者会把 `_apply_scale()` 写进去的
	#    缩放一起清成 1（红线 25），占位体会以原始尺寸糊满整屏。
	hull_root.rotation.y = PI
	_capture_bow_axes(
		hull_root.basis.orthonormalized(),
		Vector3(0.0, 0.0, 1.0),   # 占位体舰艏 = 局部 +Z
		Vector3(0.0, 1.0, 0.0))   # 船背 = 局部 +Y


## 引擎光（派系色的暖色余辉）
func _build_engines() -> void:
	var glow_mat := StandardMaterial3D.new()
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.albedo_color = Color(0.55, 0.72, 0.92)
	glow_mat.emission_enabled = true
	glow_mat.emission = Color(0.45, 0.68, 0.95)
	glow_mat.emission_energy_multiplier = 2.2
	glow_mat.disable_fog = true

	for x in [-0.18, 0.18]:
		var nozzle := MeshInstance3D.new()
		var m := BoxMesh.new()
		m.size = Vector3(0.20, 0.16, 0.06)
		nozzle.mesh = m
		nozzle.material_override = glow_mat
		nozzle.position = Vector3(x, 0.0, -1.75)
		hull_root.add_child(nozzle)

	# 引擎光晕
	var omni := OmniLight3D.new()
	omni.light_color = Color(0.45, 0.68, 0.95)
	omni.light_energy = 0.6
	omni.omni_range = 4.2
	omni.position = Vector3(0, 0, -1.8)
	hull_root.add_child(omni)


# ------------------------------------------------------------------ 敌我识别

## 敌我识别 · 方案 D：血条外框染色 + 名字前阵营徽标。
##
## 为什么不用船底环（方案 A，用户否了）：多一层地面元素会让混战画面变忙，
## 而且船体翻滚时还要额外处理环的水平保持。方案 D 全部挂在 label_root 上，
## 跟随已有的 billboard 逻辑，一行同步代码都不用加。
func _build_team_id() -> void:
	if team_id_mode <= 0:
		return
	var mine := ship == null or ship.team == 0
	var col: Color = TEAM_OWN if mine else TEAM_FOE

	# ② 名字前加阵营徽标：▲ 我方 / ◆ 敌方
	#    ⚠️ 字形已核实：msyh / msyhbd / simsun 都有 U+25B2 与 U+25C6。
	#    ⚠️ 用「前缀 + 同色」而不是单独一个 Label3D：多一个节点就要多管一份
	#       位置同步，而 Label3D 的 billboard 是自带的，拆开反而容易错位。
	if _name_label != null:
		var mark := "\u25B2 " if mine else "\u25C6 "
		if not _name_label.text.begins_with(mark):
			_name_label.text = mark + _name_label.text
		_name_label.modulate = col
		_name_label.outline_modulate = Color(0.10, 0.02, 0.02, 0.92) if not mine \
				else Color(0.01, 0.06, 0.09, 0.92)

	if team_id_mode >= 2:
		_build_name_plate(col)

	# ① 血条外框：一个略大的空心矩形，染阵营色
	#    ⚠️ 用 QuadMesh 画「边框」而不是四个细长条：一个节点、一次绘制，
	#       且能跟着 label_root 一起 billboard / 缩放。
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.albedo_color = Color(col.r, col.g, col.b, 0.95)
	fm.emission_enabled = true
	fm.emission = col
	# ⚠️ 自发光压到 0.45：原来 1.1 在暗背景下会「发亮」，
	#    用户反馈就是这种荧光感。现在只保留一点点辉光，主要靠固有色。
	fm.emission_energy_multiplier = 0.45
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fm.billboard_keep_scale = true
	fm.disable_fog = true
	fm.cull_mode = BaseMaterial3D.CULL_DISABLED
	_team_frame_mat = fm
	var fq := QuadMesh.new()
	fq.size = Vector2(BAR_WIDTH + 0.10, 0.075 + 0.055)
	_team_frame = MeshInstance3D.new()
	_team_frame.name = "TeamFrame"
	_team_frame.mesh = fq
	_team_frame.material_override = fm
	_team_frame.position = Vector3(0, LABEL_HEIGHT + 0.08, -0.001)
	label_root.add_child(_team_frame)


## 方案 B：名牌底板 + 左侧阵营色条。
##
## ══════════════════════════════════════════════════════════════════
##  三个必须处理的坑
## ══════════════════════════════════════════════════════════════════
##  ① **绘制顺序**：底板必须画在文字下面。文字 Label3D 的 `no_depth_test`
##     是 true（永远不被船体挡住），所以不能靠深度分层 —— 改用
##     `render_priority`：透明物体验完 priority 再比距离，
##     给底板 -1 就保证它先画、文字后画覆盖上去。
##  ② **底板宽度**：Label3D 不报告文字像素宽，只能估算。
##     口径 = 字符数 x 字号 x pixel_size（中文近似方块字，1 字 ≈ 1 字号宽），
##     再加固定余量给描边和徽标。估窄了会露馅，所以往宽给。
##  ③ **别让底板吃输入**：它是 MeshInstance3D，本来就不参与 GUI 命中，
##     但 `no_depth_test = true` 会让它画到船前面去 —— 看着像一层雾。
func _build_name_plate(col: Color) -> void:
	if _name_label == null:
		return
	# ② 估算文字宽：字符数 x 字号(32) x pixel_size(0.010) = 0.32/字
	var chars := _name_label.text.length()
	var tw := float(chars) * 0.32 + 0.34
	var th := 0.46
	var cy := 1.65

	# 底板
	var pm := StandardMaterial3D.new()
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pm.albedo_color = Color(0.055, 0.075, 0.105, 0.72)
	pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	pm.billboard_keep_scale = true
	pm.disable_fog = true
	pm.cull_mode = BaseMaterial3D.CULL_DISABLED
	pm.render_priority = -1        ## ① 先画，好让文字盖上来
	pm.no_depth_test = false
	var pq := QuadMesh.new()
	pq.size = Vector2(tw, th)
	_name_plate = MeshInstance3D.new()
	_name_plate.name = "NamePlate"
	_name_plate.mesh = pq
	_name_plate.material_override = pm
	_name_plate.position = Vector3(0, cy, 0)
	label_root.add_child(_name_plate)

	# 左侧色条
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.albedo_color = Color(col.r, col.g, col.b, 0.95)
	sm.emission_enabled = true
	sm.emission = col
	sm.emission_energy_multiplier = 0.35
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	sm.billboard_keep_scale = true
	sm.disable_fog = true
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	sm.render_priority = -1
	sm.no_depth_test = false
	var sq := QuadMesh.new()
	sq.size = Vector2(0.055, th)
	_name_stripe = MeshInstance3D.new()
	_name_stripe.name = "NameStripe"
	_name_stripe.mesh = sq
	_name_stripe.material_override = sm
	_name_stripe.position = Vector3(-tw * 0.5 + 0.028, cy, 0)
	label_root.add_child(_name_stripe)


func _add_box(pos: Vector3, size: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	mi.position = pos
	hull_root.add_child(mi)


# ------------------------------------------------------------------ 受击闪光

## 被命中时，船体整片泛一层色光（护盾青蓝 / 装甲琥珀 / 结构橙红）。
##
## ══════════════════════════════════════════════════════════════════
##  为什么用 `material_overlay` 而不是改材质
## ══════════════════════════════════════════════════════════════════
##  船体材质由 `EveShipMaterial` 按 **(ship_id, surface)** **静态缓存共享** ——
##  同型的两艘船拿到的是**同一个 ShaderMaterial 实例**。
##  直接改它的 emission / 颜色 ⇒ ① 全场同型船一起闪 ② 污染缓存，
##  下一艘同型船一出生就带着上次的闪光参数。
##
##  `material_overlay` 是 MeshInstance3D 上的**每实例**叠加层：
##  不碰底层材质、不需要 duplicate、天然一船一份。
##
## ══════════════════════════════════════════════════════════════════
##  为什么不用 Tween
## ══════════════════════════════════════════════════════════════════
##  战斗是**固定步长**推进的，`debug_fast_forward_battle()` 一次能跑几百 tick；
##  而 Tween 按**真实帧时间**走 ⇒ 快进时闪光会「卡住不灭」。
##  这里用 `_process` 自己推时间，并且**平时把 process 关掉**（零开销）：
##  只有真的闪起来的那 0.18 秒才进 `_process`。
##
## ⚠️ 本类原本**没有** `_process` —— 这是唯一的自持计时器，
##    新增别的东西请不要再开第二个，直接复用它。
## ⚠️ 血条挂在 `label_root`、不在 `hull_root` ⇒ 只叠船体，血条不会被刷白。
const FLASH_LIFE := 0.18
## 护盾 / 装甲的峰值不透明度
##
## ⚠️ 这里配的是**加法混合**（见 `_build_flash_layer`），不是普通 alpha：
##    普通 alpha 在亮背景（云层）上会被"冲淡"，实测 0.42 几乎看不出来；
##    加法混合是把颜色**加**到船体上 ⇒ 暗色船体明显发亮、亮部也不会糊成色块。
##    0.55 是出图调出来的：能一眼看出"被打了一下"，又不至于把船涂成剪影。
const FLASH_PEAK := 0.55
## 结构层更亮一点：这是「船真的要没了」的读数
const FLASH_PEAK_HULL := 0.68

var _flash_mat: StandardMaterial3D = null
var _flash_meshes: Array[MeshInstance3D] = []
var _flash_t: float = 0.0
var _flash_life: float = 0.0
var _flash_peak: float = 0.0
var _flash_count: int = 0


## 受击闪光入口。`layer` = &"shield" / &"armor" / &"hull"（传空按结构色）。
##
## ⚠️ 这个函数会被 `_on_shot_fired` **高频调用**（一次 `sim.step` 里可能几十次），
##    所以首次之后只做「重置计时 + 写一次颜色」，**绝不重复遍历网格**。
func flash_hit(layer: StringName = &"hull") -> void:
	if hull_root == null:
		return
	if _flash_mat == null:
		_build_flash_layer()
	if _flash_mat == null:
		return
	var col := Color(0.95, 0.50, 0.30)          # 结构：橙红
	if layer == &"shield":
		col = Color(0.38, 0.74, 1.00)           # 护盾：青蓝
	elif layer == &"armor":
		col = Color(0.95, 0.78, 0.34)           # 装甲：琥珀
	_flash_peak = FLASH_PEAK_HULL if layer == &"hull" else FLASH_PEAK
	_flash_mat.albedo_color = Color(col.r, col.g, col.b, _flash_peak)
	_flash_t = 0.0
	_flash_life = FLASH_LIFE
	_flash_count += 1
	set_process(true)


## 建一次叠加层。**所有船体网格共用同一个 overlay 材质实例** ⇒ 改 alpha 只写一次。
func _build_flash_layer() -> void:
	_flash_meshes.clear()
	_collect_hull_meshes(hull_root, _flash_meshes)
	if _flash_meshes.is_empty():
		return
	_flash_mat = StandardMaterial3D.new()
	_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# ★ 加法混合（不是普通 alpha）：受击是「船体被点亮」，不是「蒙一层色纸」。
	#   实测普通 alpha 0.42 在云层背景上完全看不出来（见文件顶部说明）。
	_flash_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_flash_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.0)
	# ⚠️ 必须 CULL_DISABLED：船的网格是闭合的，只渲染正面会让背面在掠射角露出缝隙
	_flash_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_flash_mat.disable_fog = true
	for mi in _flash_meshes:
		mi.material_overlay = _flash_mat


func _collect_hull_meshes(n: Node, out: Array[MeshInstance3D]) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c as MeshInstance3D)
		_collect_hull_meshes(c, out)


## 闪光计时。平时 `set_process(false)`，只有闪起来才进这里。
func _process(delta: float) -> void:
	if _flash_life <= 0.0:
		set_process(false)
		return
	_flash_t += delta
	var k := _flash_t / maxf(0.001, _flash_life)
	if k >= 1.0:
		_flash_life = 0.0
		if _flash_mat != null:
			_flash_mat.albedo_color.a = 0.0
		# ⚠️⚠️ **不摘 overlay**，只把 alpha 归零。2026-10-17 实测踩过：
		#    原来这里 `mi.material_overlay = null`，而 `flash_hit()` 只在
		#    **首次**（`_flash_mat == null`）才挂 —— 于是第一次闪光结束后
		#    材质被摘掉、再也挂不回去，**第二次起的闪光全部无效**且不报错。
		#    探针读数：第 1 张「已挂 overlay 1」，第 2/3 张「已挂 overlay 0」。
		#    实测船体网格只有 1 个（glb 是单 MeshInstance3D 多 surface），
		#    常驻一个 alpha=0 的 overlay 成本可以忽略 ⇒ 保留挂载最省心。
		set_process(false)
		return
	# 平方衰减：亮得快、灭得干脆（与 EveBattleFx 的淡出曲线同一口径）
	if _flash_mat != null:
		var f := 1.0 - k
		_flash_mat.albedo_color.a = _flash_peak * f * f


## 验收抓手：累计触发次数。
## ⚠️ 用**计数**而不是 `is_flashing()` 做断言 —— 快进时时间推进由渲染帧决定，
##    一帧内可能闪完几十次，靠状态断言会漏。
func flash_count() -> int:
	return _flash_count


# ------------------------------------------------------------------ 血条

## 三层血条：护盾（青）/ 装甲（琥珀）/ 结构（红），上下堆叠
##
## ⚠️ 这里的坐标是「夸张缩放前」的本地空间（单位 = 基准船长 2.6 的倍数）。
##    因为 label_root 会整体乘 VISUAL_EXAGGERATION，所以这些值要按小尺度给。
func _build_bars() -> void:
	var top := LABEL_HEIGHT
	_shield_bar = _make_bar(Vector3(0, top + 0.20, 0), Color(0.35, 0.70, 0.90))
	_armor_bar = _make_bar(Vector3(0, top + 0.08, 0), Color(0.85, 0.68, 0.28))
	_hull_bar = _make_bar(Vector3(0, top - 0.04, 0), Color(0.82, 0.32, 0.28))
	for bar in [_shield_bar, _armor_bar, _hull_bar]:
		label_root.add_child(bar)


func _make_bar(pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(BAR_WIDTH, 0.075)
	mi.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.7
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.disable_fog = true
	mi.material_override = mat
	mi.position = pos
	return mi


# ------------------------------------------------------------------ 标签

func _build_labels() -> void:
	_name_label = Label3D.new()
	_name_label.text = ship.ship_name
	_name_label.font_size = 32
	_name_label.pixel_size = 0.010
	_name_label.modulate = Color(0.82, 0.90, 0.94)
	_name_label.outline_size = 6
	_name_label.outline_modulate = Color(0.02, 0.03, 0.04, 0.9)
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_label.position = Vector3(0, 1.65, 0)
	_name_label.no_depth_test = true
	label_root.add_child(_name_label)

	_stance_label = Label3D.new()
	_stance_label.text = EveDestinyMotion.stance_label(ship.stance)
	_stance_label.font_size = 24
	_stance_label.pixel_size = 0.009
	_stance_label.modulate = Color(0.55, 0.68, 0.74)
	_stance_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_stance_label.position = Vector3(0, 1.42, 0)
	_stance_label.no_depth_test = true
	label_root.add_child(_stance_label)


# ------------------------------------------------------------------ 同步

## 每帧从物理体同步位置与朝向
##
## ══════════════════════════════════════════════════════════════════
##  ⚠️⚠️ **红线 46（2026-09-26 第二十二轮定案）**：舰艏 ≡ 前进方向 ≡ 速度方向
## ══════════════════════════════════════════════════════════════════
##
##  ── 旧做法（**已作废，别再回去**）──────────────────────────────────
##  `rotation.y = lerp_angle(_facing, atan2(v.x, v.z) + PI, 0.12)`
##
##  它**只有一个自由度**（绕世界 Y 的偏航角）。几何后果：
##      bow = R_y(φ) · bow0
##  R_y 只能改变 bow0 的**水平投影方位**，改不动它的 **Y 分量**。
##  ⇒ 只要某艘船 setup 后的舰艏轴 `bow0` 不在水平面（`bow0.y ≠ 0`），
##     `φ` 取**任何值**都到不了目标 —— **这是数学上的无解，不是调参问题**。
##     实测 52 艘里 `myrmidon` / `tristan` 正是 `bow0 = (0,−1,0)`（舰艏朝下），
##     于是它们无论怎么改偏移量都"修不好"（第 21 轮踩的就是这个）。
##
##  ── 3D 游戏里的标准解法：**用「前向 + 上向」构造完整基** ──────────
##  这就是 `look_at()` / `Basis.looking_at()` 的数学本质，也是飞船、飞机、
##  角色的通用做法。它有两个约束方向、覆盖整个旋转群 SO(3)，
##  **任何** bow0 都能转到**任何**目标方向：
##
##      ① 目标：让 舰艏 → f（速度方向），同时 船背 → 世界上方（船不侧翻）
##      ② 构造 W = Basis.looking_at(f, UP)   （Godot 约定：-Z 指向 f）
##      ③ 左乘常量 C = _bow_align            （setup 时烘焙，见 _make_align）
##         使得 C·bow0 = −Z、C·up0 = +Y
##      ④ target = W·C  ⇒  target·bow0 = W·(−Z) = f  ✔ 严格相等，不是近似
##      ⑤ 用四元数 slerp 平滑过去（slerp 沿最短弧，±π 边界**不会绕圈**）
##
##  为什么 ⑤ 用 slerp 而不是继续用 lerp_angle：
##     `lerp_angle` 只插值一个标量角，用不上；四元数 slerp 是它在 SO(3) 上的
##     对应物。**Godot 只有 `lerp_angle` 和 `Quaternion.slerp`，
##     不存在 `lerp_angle_toward`**（第 21 轮为它付过一次解析失败的代价）。
##
##  ── 对已有 50 艘是"零变化"的（这点很重要）─────────────────────────
##  那 50 艘的 bow0 本来就是 `(0,0,−1)`（水平、朝敌）、up0 = `(0,1,0)`（背朝天）
##  ⇒ 此时 W·C 与旧的 R_y(φ) **给出同一个旋转**（绕 Y 转，上轴不动）
##  ⇒ 视觉上与旧版**逐帧一致**，不会"改完全库都变了"。
##  真正被修好的只有那 2 艘死锁船。
##
##  ── 平滑与滞后 ────────────────────────────────────────────────────
##  slerp 的权重是 `FACING_LERP`（0.12）⇒ 转弯时舰艏**滞后**于速度方向，
##  这是**有意的**：真船有惯性。想"硬跟"就把它调成 1.0（代价是会抖）。
##  稳态（速度方向不变）下滞后收敛到 0 ⇒ **严格** bow = v。
##
##  跑过：红线 46 · 2026-09-26 第二十二轮（用户：「船头明确需要朝着前进方向」）
##
## ── 渲染插值（2026-10-27）────────────────────────────────────────
## `alpha` = **渲染插值系数**（0..1，见 `EveBattleSimulator.interp_alpha()`）。
##
## ⚠️⚠️ 为什么需要它（2026-10-27 用户报的「舰船小幅高频抖动、看不清、发糊」）：
##   仿真 30 Hz、渲染 60~240 Hz。原来这里直接 `position = body.position` ⇒
##   两次 tick 之间的那几帧**画面完全静止**，然后一帧跳过 2.5~4 px
##   （实测 144 fps 下 **79% 的渲染帧画面纹丝不动**，见 `tools/probe_jitter.tscn`）。
##   ⇒ 在 `previous_position` 与 `position` 之间线性插值，运动立刻变连续。
##   代价：画面比仿真晚一个 tick（33 ms），这是固定步长 + 插值渲染的标准取舍。
##
## ⚠️ 默认 `1.0` = **直接取本 tick 位置（旧行为）** —— 布阵 / 快进 / 验收脚本
##    走默认值，位置仍然与 `body.position` **严格相等**，老断言一条都不用改。
func sync_from_body(body: EveDestinyMotion.Body, alive: bool, delta: float = 1.0 / 60.0, alpha: float = 1.0) -> void:
	# 米 → 世界单位（渲染层唯一的单位换算点）
	var p: Vector3 = body.position
	if alpha < 1.0:
		p = body.previous_position.lerp(body.position, clampf(alpha, 0.0, 1.0))
	position = p / METERS_PER_UNIT

	# 舰艏跟随速度方向 —— 完整旋转对齐，见上方红线 46
	# ★★★ 45 轮：**舰艏的朝向来源改为「目标方向优先」**（用户实机诉求）。
	#
	# ── 用户原话（45 轮）────────────────────────────────────────────
	#   「我实机看了一下，船的舰艏和敌人方向全部是垂直的，不是相对的，
	#     现在在棋盘上的舰船应该顺时针转 90 度」
	#
	# ── 真因：不是表错了，是**朝向语义选错了** ────────────────────
	#   22 轮把「舰艏 ≡ 速度方向」定成红线 46，数学上完美（`bow·v̂ = 1.000000`），
	#   但**默认战术恰恰是环绕**（`EveDestinyMotion.orbit_thrust`，见
	#   `command_to_acceleration` 的默认分支）⇒ 推力带强切向分量 ⇒ 速度方向
	#   **天然垂直**于「船→敌」的视线 ⇒ 于是每艘船都**横着飞**（侧身对着敌人）。
	#   ⚠️ 这正是「机器验过 ≠ 实机对」的又一例：`probe_bow_align` 只测
	#     `bow·v̂`，它**永远为 1**，测不出"速度方向本身就不是用户想要的方向"。
	#
	# ── 修法：跟 EVE Online 的真实做法对齐 ─────────────────────────
	#   ① **有目标**（`body.aim_dir` 非零，由模拟层每 tick 写入）
	#      ⇒ `f = aim_dir`：**舰艏指着敌人**（炮口/舰艏同向，视觉语言统一）
	#   ② **无目标**（零向量：还没索敌 / 目标已死）
	#      ⇒ `f = v̂`：退回"舰艏朝速度方向"（红线 46 的原始语义，此时是唯一的线索）
	#   ⚠️ `aim_dir` 由 `eve_battle_simulator._refresh_targets()` 唯一写入 ——
	#     视觉层**不许**自己再选一次目标（红线 40：复刻必然漂移）。
	var v := body.velocity
	var aim := body.aim_dir
	var f := Vector3.ZERO
	if aim.length_squared() > 1e-12:
		f = aim.normalized()
	elif v.length() > MOVE_EPS:
		f = v.normalized()
	if _has_align and f.length_squared() > 1e-12:
		# `Basis.looking_at` 在 f ∥ up 时退化（叉积为零）⇒ 拿当前姿态的 up 兜底。
		# 太空战里 f 基本水平、触发不到，但一旦有垂直机动，不兜底就是 NaN 姿态。
		#
		# ⚠️⚠️ **51 轮实测：这个兜底只覆盖了「f ∥ UP」，还有第二个退化点没覆盖** ⚠️⚠️
		#   `tools/probe_real51`（走生产 setup、读引擎渲染的 `mesh.global_transform`）
		#   逐艘实测结论（全库 52 艘）：
		#     · `aim = (0,0,−1)`（**朝敌**，红线 42 的实战常态）⇒ **52/52 全对**
		#     · `aim = (1,0,0)` / `(0.707,0,0.707)`               ⇒ **全对**
		#     · `aim = (0,0,+1)`（**朝我方**）                     ⇒ **全库偏 90°**
		#   症状：`bow` 落到**横向**（如 kestrel 报 `−X` 而表是 `+Z`），
		#         而 `up`（船背）**完全不变** ⇒ 不是滚转，是**水平面内被转了 90°**。
		#   真因：`Basis.looking_at(f, up)` 构造 `f × up` 时，`f` 沿 **±Z** 会令
		#         该叉积落在 **±X**，而**符号随 `f.z` 翻号** ⇒ `looking_at(+Z)` 相对
		#         `looking_at(−Z)` 多出一个绕 Y 的 180°（等价于把 `C` 的「−Z→f」
		#         契约打成「−X→f」）⇒ 舰艏落横向。
		#   ⇒ **实战不触发**（敌人恒在 −Z、船朝敌 ⇒ `f ≈ −Z`），故**本轮不改逻辑**
		#     （用户裁决：以工具定的为准，不引入未验证的改动）。
		#   ⇒ 若将来出现「船朝 +Z 时横着飞」，根因就在这里：
		#     兜底应改为判「`f` 与 `up_ref` **共线**」并换一个不共线的参考，例如
		#         `if absf(f.dot(up_ref)) > 0.999: up_ref = <f 的正交补>`
		#     而不是只在 `up_ref = UP` 上判。
		var up_ref := Vector3.UP
		if absf(f.dot(up_ref)) > 0.999:
			up_ref = (_facing_quat * Vector3.UP).normalized()
			if absf(f.dot(up_ref)) > 0.999:
				up_ref = (_facing_quat * Vector3(0.0, 0.0, -1.0)).normalized()
		var target := Basis.looking_at(f, up_ref) * _bow_align
		var want := Quaternion(target)
		var next := _facing_quat.slerp(want, FACING_LERP)
		# ★ 46 轮：**角速度闸门** —— slerp 的结果再限一次速。
		#   理由见 `FACING_MAX_DEG_PER_SEC` 上方：`aim_dir` 在**换目标瞬间**
		#   会整根向量换向（实测 53.3°/28.3°/44.3°），slerp 一帧被拉走一大截
		#   ⇒ 船头"啪"地甩过去。真实车辆转头需要时间，这里就是那个时间上限。
		#   ⚠️ 是 **clamp 不是 lerp**：正常跟随（每帧约 1.3°）远低于闸门 ⇒
		#      对稳态 `bow·敌向` 零影响（那由 FACING_LERP 决定）。
		#
		# ⚠️⚠️ **53 轮修正：`Quaternion.angle_to()` 返回的是「半角」，要 ×2** ⚠️⚠️
		#   Godot 的 `Quaternion.angle_to(q)` 与 `Quaternion.get_angle()` 一样，
		#   返回的是**四元数在 4D 单位球上的夹角 θ**，而它对应的**实际 3D 旋转角
		#   是 2θ**（`q` 与 `−q` 表示同一旋转 ⇒ 四元数空间是 3D 旋转的**双覆盖**）。
		#   ⇒ 旧写法 `rad_to_deg(q1.angle_to(q2))` 报出的角**只有真实旋转角的一半**
		#     ⇒ 闸门实际放行的是 **2 × cap**，等于把 `FACING_MAX_DEG_PER_SEC`
		#     悄悄改成了 **180°/s 而不是 90°/s**（注释与实现不一致，且不报错）。
		#   实测（`tools/probe_jump53.tscn` 逐帧三层次定位）：开打瞬间
		#   `algos`/`catalyst`/`slasher`/`burst` 单帧真实转 **3.05°**，
		#   而按 doc 口径的闸门应只放行 1.50° ⇒ 超 2 倍，正是这个半角造成的。
		#   ⇒ 乘 2 恢复真实角度语义。
		var step_deg := rad_to_deg(_facing_quat.angle_to(next)) * 2.0
		var cap_deg := facing_max_step_deg(delta)
		if step_deg > cap_deg and step_deg > 1e-6:
			next = _facing_quat.slerp(next, cap_deg / step_deg)
		_facing_quat = next.normalized()
		# ⚠️ 写 `quaternion` 而不是 `basis`：后者会连带把缩放一起赋值。
		#    本节点 scale 恒为 1（船体缩放挂在 hull_root 上），但用 quaternion
		#    是唯一"只动旋转"的写法，将来谁在节点上加了缩放也不会被清掉。
		quaternion = _facing_quat

	visible = alive

	if not alive:
		return

	# 标签避让：偏移/透明度都走平滑（arena 每帧给的是「目标值」）。
	# ⚠️ 不平滑会在两艘船交错的瞬间看到名字「跳层」。
	var k := clampf(delta / 0.10, 0.0, 1.0)
	_label_offset = lerpf(_label_offset, _label_offset_want, k)
	_label_dim = lerpf(_label_dim, _label_dim_want, k)
	_sync_label_transform()

	_update_bars()
	_update_command_badges()


## ★ 53 轮：**瞬时**把舰艏摆到 `aim_dir`，不走 slerp 平滑。
##
## ── 为什么需要它（与 `sync_from_body` 的分工）──────────────────────
##  `sync_from_body` 是**每帧**调用，用 `slerp(want, FACING_LERP=0.12)` 做平滑，
##  单帧只走 12% —— 这对"战斗中跟随目标"是**正确的**（真船有惯性，转弯要时间）。
##
##  但**布阵阶段**是另一回事：玩家把船摆到战斗区的那一刻，期待的是
##  「**一眼看出所有船都朝敌人**」的整齐排面，不是"船慢慢转过去"。
##  而布阵阶段每帧不调 `sync_from_body`（`_process` 的 PREP 分支只走倒计时）
##  ⇒ 只同步一次、只走 12% ⇒ **看着像没转**。
##
##  本函数就是给这种"需要一个确定的初始姿态"的场合用的：
##  一次算到目标姿态，不做插值、不受 `FACING_LERP` / 角速度闸门影响。
##
## ── 与 `sync_from_body` 的一致性（红线 40：不许复刻）───────────────
##  姿态算式**逐字同源**：同样是 `looking_at(f, up_ref) · _bow_align`，
##  同样的 `up_ref` 退化兜底。**唯一差异是不做 slerp**（直接赋值）。
##  ⇒ 两个函数的"目标姿态"必然一致，不会出现"布阵一次姿态、开打另一个姿态"。
##
## ── 调用时机 ──────────────────────────────────────────────────────
##  只许在**需要一个确定初始姿态**的场合调（布阵 / 复位 / 验收脚本）。
##  ⚠️ **战斗循环里不要调它** —— 那等于把转弯的惯性去掉了，船头会"啪"地瞬移。
func snap_facing(body: EveDestinyMotion.Body, alive: bool = true) -> void:
	position = body.position / METERS_PER_UNIT
	var v := body.velocity
	var aim := body.aim_dir
	var f := Vector3.ZERO
	if aim.length_squared() > 1e-12:
		f = aim.normalized()
	elif v.length() > MOVE_EPS:
		f = v.normalized()
	if _has_align and f.length_squared() > 1e-12:
		# 与 `sync_from_body` 同款退化兜底（理由见那边）——
		# ⚠️ 这里同样只覆盖「f ∥ UP」，未覆盖「f 沿 ±Z」那个点（51 轮实测留档）。
		#    布阵态的 `f` 恒为 ±Z（朝敌/朝我），**正好踩在未覆盖的退化点上**。
		var up_ref := Vector3.UP
		if absf(f.dot(up_ref)) > 0.999:
			up_ref = (_facing_quat * Vector3.UP).normalized()
			if absf(f.dot(up_ref)) > 0.999:
				up_ref = (_facing_quat * Vector3(0.0, 0.0, -1.0)).normalized()
		var target := Basis.looking_at(f, up_ref) * _bow_align
		_facing_quat = Quaternion(target).normalized()
		quaternion = _facing_quat
	visible = alive
	# 标签层是 top_level，位置不会自动跟着 `position` 走 ⇒ 这里显式同步一次。
	_sync_label_transform()


func _update_bars() -> void:
	var s_max: float = maxf(0.001, ship.max_hp[&"shield"])
	var a_max: float = maxf(0.001, ship.max_hp[&"armor"])
	var h_max: float = maxf(0.001, ship.max_hp[&"hull"])

	# ★ 2026-10-27（用户：「血条堆叠」）：血条不再是常驻元素。
	#   显示条件 = **关键船** 或 **已经掉过血**（受伤本身就是玩家要看的信息）。
	#   ⇒ 开局满血的普通船只剩名字，屏幕上少掉大量横向长条。
	var key := _is_key_ship()
	# ⚠️ hp 是 Dictionary 取值（Variant）⇒ 这里必须显式标 bool，否则推断失败。
	var hurt: bool = float(ship.hp[&"shield"]) < s_max - 0.5 \
			or float(ship.hp[&"armor"]) < a_max - 0.5 \
			or float(ship.hp[&"hull"]) < h_max - 0.5
	var show_bars: bool = key or hurt

	_set_bar(_shield_bar, ship.hp[&"shield"] / s_max, show_bars)
	_set_bar(_armor_bar, ship.hp[&"armor"] / a_max, show_bars)
	_set_bar(_hull_bar, ship.hp[&"hull"] / h_max, show_bars)
	if _team_frame != null:
		_team_frame.visible = show_bars

	_stance_label.text = EveDestinyMotion.stance_label(ship.stance)
	# 「保持距离」这类姿态每艘船基本一样 ⇒ 只给关键船显示，其余留名字就够。
	_stance_label.visible = key
	_apply_label_dim()


func _set_bar(bar: MeshInstance3D, fraction: float, allow: bool = true) -> void:
	if bar == null:
		return
	var f := clampf(fraction, 0.0, 1.0)
	bar.visible = allow and f > 0.001
	if not bar.visible:
		return
	# 用缩放模拟血条长度（锚点靠左）
	# 血条基准宽度见 BAR_WIDTH（_make_bar 与这里必须一致）
	bar.scale.x = f
	bar.position.x = -(BAR_WIDTH * (1.0 - f)) * 0.5


## ══════════════════════════════════════════════════════════════════
##  指挥层标记（2026-10-27 用户定案：「两个都标」）
## ══════════════════════════════════════════════════════════════════
##
##  ① **旗舰环**（`_flag_badge`）：本队吨位最高的那艘，跟着它走的那一圈。
##  ② **集火环**（`_focus_badge`）：敌方全队正在集火的目标。
##
## ── 为什么用 TorusMesh 而不是 Label3D 字形 ────────────────────────
##   字形依赖字体：项目只保证 msyh/msyhbd/simsun，几何符号（⌖ ✛ ◎）在
##   这些字体里**未必存在**，缺字会静默画成豆腐块。环是纯几何，零风险。
##   ⚠️ 已核实过的只有 U+25B2 / U+25C6（见 `_build_team_id` 的注释），
##      连它们都靠人工核过 —— 不要再赌第三个字形。
##
## ── 两个环怎么区分（否则玩家以为是同一个东西的两态）────────────────
##   位置 + 大小 + 颜色**三重错开**：
##     旗舰：**船体上方**（y=2.35）、半径小（0.22）、暖金
##     集火：**名字上方**（y=2.00）、半径大（0.34）、砖红
##   三重都不同 ⇒ 即便色觉异常也分得开（不靠单一通道）。
##
## ── 与 `EveShip.is_flagship / is_focused` 的关系（红线 40）──────────
##   本层**只读**那两个字段（每帧 `sync_from_body` 里刷可见性），
##   ⛔ 不自己判断"谁吨位最高" —— 那必然与模拟器漂移。
const FLAG_BADGE_COLOR := Color(0.95, 0.78, 0.32)   ## 暖金（指挥）
const FOCUS_BADGE_COLOR := Color(0.92, 0.36, 0.30)  ## 砖红（被集火）
const FLAG_BADGE_Y := 2.35
const FOCUS_BADGE_Y := 2.00
const FLAG_BADGE_R := 0.22
const FOCUS_BADGE_R := 0.34

var _flag_badge: MeshInstance3D = null
var _focus_badge: MeshInstance3D = null


# ------------------------------------------------------------------ 标签精简 / 避让
##
## ══════════════════════════════════════════════════════════════════
##  用户 2026-10-27：「血条堆叠，看看怎么解决」
## ══════════════════════════════════════════════════════════════════
##
##  两件事一起做（用户选定「两者都做」）：
##    ① **精简**：常驻的只有**舰船名字**。血条与「保持距离」只在
##       **关键船**上显示 —— 关键船 = 本队旗舰 / 被集火目标 / 玩家镜头锁定；
##       另外**掉过血**的船自动补血条（受伤本身就是玩家要看的信息）。
##       ⇒ 满血的普通船只剩一行名字，重叠概率从源头上大降。
##    ② **避让**：竞技场每帧把所有标签组投影到屏幕上，重叠的按重要性
##       从上往下排成阶梯（实现在 `eve_battle_arena.gd::declutter_offsets`）。
##       本文件只负责「报告自己的屏幕包围盒」和「接受世界 Y 偏移」。
##
##  ⚠️ 偏移的单位是**世界单位**（arena 已经按相机投影换算过），
##     不是像素 —— 因为这里只能改 3D 节点的位置。

## 玩家镜头锁定本舰（由 arena 每帧写入；视觉层不自己判「谁被锁定」）。
var _cam_lock := false
## 避让偏移：当前值（每帧向目标平滑）与目标值（arena 写）。
var _label_offset := 0.0
var _label_offset_want := 0.0
## 降透明度：标签挤到层数上限之外时压暗，避免「一堆名字糊成一团」。
var _label_dim := 1.0
var _label_dim_want := 1.0
## 上一次真正写进材质的透明度（见 `_apply_label_dim` 的缓存说明）。
var _label_dim_applied := -1.0

## 标签组在世界空间的包围盒（x 以标签轴心为 0；单位 = 世界单位，已乘 label_root.scale）。
##
## arena 用它做屏幕空间重叠检测。宽度取「名字估算宽」与「血条宽」的较大者。
##
## ⚠️ 高度**按当前实际可见的元素**算，不是固定给满：
##    精简后大多数普通船只剩一行名字（1.49~1.81），若仍按满高（0.87~1.90）
##    报给避让算法，两艘船明明隔得开也会被判重叠、白白推开。
func label_block_world() -> Rect2:
	if label_root == null:
		return Rect2()
	var s: float = label_root.scale.y
	var chars := 0
	if _name_label != null:
		chars = _name_label.text.length()
	var half_w := maxf(BAR_WIDTH, float(chars) * 0.32) * 0.5 * s
	# 名字常驻：font_size 32 × pixel_size 0.010 = 0.32 世界高，中心 y=1.65
	var bottom := 1.49
	var top := 1.81
	if _stance_label != null and _stance_label.visible:
		bottom = minf(bottom, 1.31)         # 姿态：24×0.009=0.216，中心 1.42
	if _hull_bar != null and _hull_bar.visible:
		bottom = minf(bottom, 0.87)         # 最底一条血条（hull）
	# 指挥环比名字更高（旗舰 y=2.35 r=0.22 ⇒ 上沿 2.57）
	if (_flag_badge != null and _flag_badge.visible) \
			or (_focus_badge != null and _focus_badge.visible):
		top = maxf(top, FLAG_BADGE_Y + FLAG_BADGE_R)
	return Rect2(Vector2(-half_w, bottom * s), Vector2(half_w * 2.0, (top - bottom) * s))


## 镜头锁定标记（arena 每帧写；只影响标签是否常驻显示血条/姿态）。
func set_label_camera_lock(on: bool) -> void:
	_cam_lock = on


## 避让结果（世界 Y 偏移，正 = 向上）。arena 每帧写。
## ⚠️ 只在战斗态生效 —— 布阵态在 `set_board_mode()` 里归零。
func set_label_offset_world(y: float) -> void:
	_label_offset_want = y


## 标签不透明度（1 = 正常；挤到层数外时 arena 会给 < 1 的值压暗）。
func set_label_dim(a: float) -> void:
	_label_dim_want = clampf(a, 0.0, 1.0)


## 「关键船」= 需要常驻完整标签的船。只读盘面字段（红线 40：不复刻判定）。
func _is_key_ship() -> bool:
	return ship != null and (_cam_lock or ship.is_flagship or ship.is_focused)


## 把标签层摆到「船位置 + 世界 Y 偏移」，并**清零旋转**。
##
## ⚠️ 为什么要清零旋转：label_root 是 top_level（见 setup），它不再继承船体的
##    俯仰/滚转。否则避让的垂直偏移会跟着船体歪，且船俯冲时名字会与血条错开。
func _sync_label_transform() -> void:
	if label_root == null or not is_inside_tree():
		return
	label_root.global_position = global_position + Vector3(0.0, _label_offset, 0.0)
	label_root.global_rotation = Vector3.ZERO


## 把「当前透明度」写进名字与血条材质（两者是各船独立的实例，不会串色）。
##
## ⚠️ 带缓存（`_label_dim_applied`）：稳态下 `_label_dim` 恒为 1，逐帧重写
##    材质纯属浪费（20 艘 × 60 帧 = 每秒上千次无意义写入）。
func _apply_label_dim() -> void:
	if is_equal_approx(_label_dim_applied, _label_dim):
		return
	_label_dim_applied = _label_dim
	if _name_label != null:
		var c: Color = _name_label.modulate
		c.a = _label_dim
		_name_label.modulate = c
	for bar in [_shield_bar, _armor_bar, _hull_bar]:
		if bar == null:
			continue
		var mat := bar.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color.a = _label_dim
	if _team_frame_mat != null:
		_team_frame_mat.albedo_color.a = 0.95 * _label_dim


func _build_command_badges() -> void:
	_flag_badge = _make_badge(FLAG_BADGE_COLOR, FLAG_BADGE_R, FLAG_BADGE_Y, "FlagBadge")
	_focus_badge = _make_badge(FOCUS_BADGE_COLOR, FOCUS_BADGE_R, FOCUS_BADGE_Y, "FocusBadge")


## 一个「朝天平躺的细环」——billboard 后正对相机，读作十字准星式的圈。
##
## ⚠️ `billboard_mode` 与 `billboard_keep_scale` 必须同时开：
##    只开 billboard 会让环跟着 `label_root` 的非等比缩放飞尺寸。
func _make_badge(col: Color, radius: float, y: float, nm: String) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(col.r, col.g, col.b, 0.92)
	mat.emission_enabled = true
	mat.emission = col
	# ⚠️ 压到 0.5：与血条外框同一个理由（`_build_team_id` 里那段）——
	#    满自发光在暗星空上会变成霓虹灯，用户明确否掉了荧光感。
	mat.emission_energy_multiplier = 0.5
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.disable_fog = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var tm := TorusMesh.new()
	tm.inner_radius = radius * 0.78
	tm.outer_radius = radius
	# ⚠️ Godot 的 TorusMesh 环体躺在 **XZ 平面**（轴 = +Y）。
	#    billboard 会把网格的 **+Z** 转向相机 ⇒ 环会**侧对**相机（看成一条线）。
	#    ⇒ 先绕 X 转 90° 把环立到 XY 平面，billboard 后才是正圆。
	tm.rings = 12
	tm.ring_segments = 6

	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = tm
	mi.material_override = mat
	mi.position = Vector3(0.0, y, 0.0)
	mi.rotation.x = PI * 0.5
	mi.visible = false          # 由 sync_from_body 每帧按 ship 的字段点亮
	label_root.add_child(mi)
	return mi


## 每帧刷新两个标记的可见性（唯一入口，别在别处直接动 `visible`）。
##
## ⚠️ 必须在**存活检查之后**调（船沉了就不该有指挥环）；
##    调用点在 `sync_from_body` 的 `if not alive: return` 之后。
func _update_command_badges() -> void:
	if _flag_badge != null and ship != null:
		_flag_badge.visible = ship.is_flagship
	if _focus_badge != null and ship != null:
		_focus_badge.visible = ship.is_focused


## 外部改姿态时刷新标签
func refresh_stance() -> void:
	if _stance_label:
		_stance_label.text = EveDestinyMotion.stance_label(ship.stance)

# ------------------------------------------------------------------ 护盾受击

const SHIELD_IMPACT_SCRIPT := preload("res://scripts/visual/eve_shield_impact.gd")

var _shield_fx: Node3D = null

func _all_meshes(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		out.append(root)
	for c in root.get_children():
		out.append_array(_all_meshes(c))
	return out

## 舰艏方向，换算到 hull_root 局部空间（锚点布置要用它定「船艏 5 个点」）。
func _hull_bow_dir() -> Vector3:
	if hull_root == null:
		return Vector3(0, 0, -1)
	var world_bow: Vector3 = global_transform.basis * _bow_local
	var local: Vector3 = hull_root.global_transform.basis.inverse() * world_bow
	if local.length_squared() < 1e-8:
		return Vector3(0, 0, -1)
	return local.normalized()

## 船体几何在 hull_root 局部空间里的包围盒（模型已归一化到 HULL_REF_LENGTH）。
func _hull_local_bounds() -> AABB:
	var box := AABB()
	var have := false
	var inv := hull_root.global_transform.affine_inverse()
	for mi in _all_meshes(hull_root):
		var a: AABB = inv * mi.global_transform * mi.get_aabb()
		if not have:
			box = a
			have = true
		else:
			box = box.merge(a)
	if not have:
		box = AABB(Vector3(-1.3, -0.45, -0.65), Vector3(2.6, 0.9, 1.3))
	return box

## 建护盾节点（含可见壳）。每艘船在 setup 时就建好，
## 这样「所有船都有壳」而不是「被打过才有壳」。
func _ensure_shield_fx() -> void:
	if _shield_fx != null and is_instance_valid(_shield_fx):
		return
	if hull_root == null:
		return
	_shield_fx = SHIELD_IMPACT_SCRIPT.new()
	_shield_fx.name = "ShieldImpacts"
	hull_root.add_child(_shield_fx)
	_shield_fx.setup(_hull_local_bounds(), tier_level(ship.ship_class), _hull_bow_dir(), ship.ship_key)

## 火力引导：把攻击者位置换算成护盾壳面上的一点（世界米）。
## 曳光线与命中点都用它，于是火炮看起来打在壳上，而不是打在船体中心。
func shield_impact_point(world_meters: Vector3) -> Vector3:
	_ensure_shield_fx()
	if _shield_fx == null:
		return world_meters
	var local := hull_root.to_local(world_meters / METERS_PER_UNIT)
	var axes: Vector3 = _shield_fx.axes
	if axes.x < 1e-6:
		return world_meters
	# 吸附到最近的固定锚点：曳光线因此只从这几个点打进来
	var dir: Vector3 = _shield_fx.anchor_dir_for(local)
	if dir == Vector3.ZERO:
		# 没有锚点落在吸附范围内 ⇒ 不做假吸附，曳光线仍指向船体
		return world_meters
	var on_shell: Vector3 = _shield_fx.anchor_world_local(dir)
	return hull_root.to_global(on_shell) * METERS_PER_UNIT

## 护盾壳 / 锚点调试小球的可见性（AI 桥与调试面板用）。
func set_shield_shell_visible(on: bool) -> void:
	_ensure_shield_fx()
	if _shield_fx != null and _shield_fx.has_method("set_shell_visible"):
		_shield_fx.set_shell_visible(on)


func set_shield_markers_visible(on: bool) -> void:
	_ensure_shield_fx()
	if _shield_fx != null and _shield_fx.has_method("set_markers_visible"):
		_shield_fx.set_markers_visible(on)


## 运行时修改本船护盾贴花配色。
func set_shield_decal_colors(mid: Color, high: Color, core: Color = Color(0.94, 0.99, 1.0, 1.0)) -> void:
	_ensure_shield_fx()
	if _shield_fx != null and _shield_fx.has_method("set_decal_colors"):
		_shield_fx.set_decal_colors(mid, high, core)

## 护盾命中入口：world_meters 是攻击者的世界坐标（米）。
func shield_hit_from(world_meters: Vector3) -> void:
	if hull_root == null or not is_inside_tree():
		return
	_ensure_shield_fx()
	if _shield_fx == null:
		return
	_shield_fx.fire(hull_root.to_local(world_meters / METERS_PER_UNIT))

