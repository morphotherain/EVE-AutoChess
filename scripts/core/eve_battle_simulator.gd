extends RefCounted
class_name EveBattleSimulator

## EVE 自走棋 —— 战斗模拟器
##
## 把 combat_core（数学）+ destiny_motion（物理）串成一场完整战斗。
## 固定步长推进，可脱离渲染层运行（便于无头回归测试）。
##
## 变更清单（初版）：
##   - 固定 30Hz 步进
##   - 自动索敌（就近目标 + 射程优先）
##   - 锁定流程（锁定时间由扫描分辨率与信号半径决定）
##   - 开火判定（角速度驱动命中率）
##   - 电容管理（激光炮耗电，干涸后停修理）
##   - 战斗日志输出（供 HUD 消费）

signal unit_destroyed(ship: EveShip)
signal shot_fired(attacker: EveShip, target: EveShip, hit: bool, quality: int, damage: float)
signal battle_finished(winner_team: int)

const TICK_RATE := 30.0
const FIXED_STEP := 1.0 / TICK_RATE
## ★ 2026-10-10（审查 2#5）：战斗语义 id + `_extra` 键名常量（见 `EveCombatIds`）。
const CIDS := preload("res://scripts/core/eve_combat_ids.gd")
const MAX_TICKS := 30 * 180   ## 最长 180 秒，超时判平
##
## 为什么是 180 秒而不是 120 秒：
##   实测一局 5v6 在 120 秒时只打完约 2 艘船 —— 因为接敌本身要 15~30 秒，
##   加上锁定 3.5 秒、命中率 ~43%、抗性削减 35%，
##   实际有效 DPS 远低于账面。180 秒对应「接敌 + 两轮集火」的完整节奏，
##   也是玩家能接受的自走棋单回合时长上限。
##
## ★ 2026-10-01 起：**超时一律判负**（原来是按剩余总血量判胜负）。
##   配合【火力渐增】一起看 —— 后者的目的因此变得更单纯：
##   不是"保证比分出高低"，而是**给玩家在时限内清场的机会**。
##   （时限本身来自节点表：遭遇 45s / 精英 55s / BOSS 70s。）

## 火力渐增（sudden death）起始时间与最大倍率
##
## 实测调参记录（5v5 镜像局）：
##   START=90s / MAX=4x  -> 102.6s 首杀，180s 收尾时剩 3v1（胜负明确，但仍超时）
##   START=75s / MAX=5x  -> 首杀提前到 ~85s，能在 180s 内彻底打完
##
## 取 75s 的理由：前 75 秒足够展示接敌/锁定/走位等战术行为，
## 之后进入收尾，既不浪费观众耐心，也保证结局由中盘优势决定。
##
## ⚠️ 2026-09-20（阶段 A）改为**按本场时限的比例**，不再写死绝对秒数。
##    原因：节点的战斗时限来自节点表（遭遇战 45s / 精英 55s / BOSS 70s），
##    写死的 75s 起点在这些时限下永远不会触发，"火力渐增保证收尾"这一层保护
##    就整个失效了。
## 改成比例后：不论时限多长，前 X% 是正常的 EVE 战斗节奏，剩下线性放大到 5 倍。
##
## ★ 2026-10-01：超时改成"一律判负"之后，这一层的作用变成
##    **给玩家一个在时限内清场的机会** —— 没有它，45 秒里连两轮集火都打不完，
##    每一局都会超时判负。
##
## ★★ 2026-10-31（用户：「TTK 要缩短，指的是舰队对轰时间」）：
##    0.60 → **0.45** —— 渐增提前到时限的 45% 开始。
##    为什么不是继续加伤害：实测伤害再 ×1.6，联机 6v6 只从 39.8s 降到 34.1s，
##    单机 N8 完全不动（30.1s → 30.3s）。真正的杠杆是「什么时候开始加速」，
##    不是「加速到多少」。遭遇战 45s ⇒ 20.2s 开始涨（原 27s）。
##    ⚠️ 代价：前 45% 之外都是"非正常"节奏，观感上后半场更短。
##    这是用户明确取舍过的一侧（要快），⛔ 别为了"好看"调回去。
const SUDDEN_DEATH_FRACTION := 0.45  ## 时限的前 45% 正常打，之后开始放大
const SUDDEN_DEATH_MAX_MULT := 5.0   ## 到时限时伤害放大到 5 倍

## ★ 2026-10-01：去掉「时限耗尽判负」之后，**收敛由火力渐增保证** ——
##   过了时限，伤害在 5 倍基础上继续涨（每秒 +OVERTIME_RAMP），封顶
##   SUDDEN_DEATH_HARD_CAP。血量有限而倍率无上限 ⇒ 必然在有限时间内分出胜负。
const OVERTIME_RAMP := 0.75          ## 超时后每秒再多涨多少倍
const SUDDEN_DEATH_HARD_CAP := 20.0

## 安全网：极端情况（理论上到不了）下强制收尾，避免一场战斗永远不结束。
## 按**剩余总血量**判 —— 这时候确实谁也打不死谁，比"一律判负"讲道理。
const HARD_STOP_MULT := 3.0

## ★★ 时限换算 —— **全工程唯一**把 max_ticks 换成秒的地方。
##
## ⚠️ 2026-10-01 修了一个真 bug：超时判定原来写 `tick >= max_ticks`，
##    而 `tick` 是**按帧累加**的（`_advance_one_tick` 里 `tick += 1`），
##    `elapsed` 才是**按秒累加**的。两者只在 30fps 时相等 ——
##    60fps 下 tick 跑到 1350 只用了约 22 秒，顶条（按 elapsed 显示）
##    却还剩 23 秒 ⇒ 玩家看到「还剩 20 多秒却判我超时」。
##
##    ⛔ 判定**必须**用秒（本函数），不许再用 tick —— 帧率一变就错位。
func time_limit_seconds() -> float:
	return float(max_ticks) / TICK_RATE

## 本场的 tick 上限。由 `set_time_limit()` 按节点时限设置；
## 不设时回落到 MAX_TICKS（180 秒），保证旧的调试脚本行为不变。
var max_ticks: int = MAX_TICKS


## 设置本场战斗时限（秒）。由 EveBattleScene 在开打前按节点表调用。
##
## ⚠️ 下限 10 秒：时限太短会让「接敌」都跑不完，
##    结果变成两队在射程外站桩 —— 那不是"快"而是"坏"。
func set_time_limit(seconds: float) -> void:
	max_ticks = maxi(int(10.0 * TICK_RATE), int(seconds * TICK_RATE))


## ★ 2026-11-07（新手模式）：「这一场没有时限」。
##
## [WHY] 只把顶条倒计时藏起来是不够的 —— 本类还有两道**按时间**的收束：
##   ① `damage_multiplier()`：时限的 45% 起火力渐增（这是**收敛保证**，保留）；
##   ② `_check_outcome()` 的 `HARD_STOP_MULT` 安全网：到 3 倍时限还没分出胜负
##      就按剩余血量强制收场。
##   新手模式的口径是「只有战场上分出胜负才结束」，所以 ② 必须关掉；
##   ① 保留（它只放大伤害，不结束战斗，否则两队可能在射程外干瞪眼几分钟）。
##
## ⚠️ `set_time_limit()` 仍要照常调用 —— 火力渐增的曲线基准是它，
##    关掉它会让渐增从第 0 秒就开始（战斗变成一开场就 5 倍伤害）。
var no_timeout: bool = false


func set_no_timeout(on: bool) -> void:
	no_timeout = on


## 设置敌方思考等级（0~3）。由难度档决定，开打前调用。
func set_ai_level(level: int) -> void:
	ai_level = clampi(level, 0, 3)


## 当前时间点的伤害倍率（供 _fire_once 使用）
##
## 设计意图：时限的前 `SUDDEN_DEATH_FRACTION`（当前 45%）是完全正常的 EVE
## 战斗节奏（接敌 / 锁定 / 试探），让玩家看清各船的表现；之后进入「加速收尾」，
## 把伤害放大，**让清场这件事在时限内变得可能**。
## ⚠️ 注释里**不写死百分数**：这个值调过两次（0.60 → 0.45），
##    写死的地方全都在下次调参时变成了假话。
##
## ★ 2026-10-01（第二次改）：**超时不再判负**（用户：「自走棋就该打到被击毁」）。
##   这一层于是回到它本来的职责：**保证战斗收敛** ——
##   时限后伤害继续涨（5 → 20 倍），双方血量有限 ⇒ 必然分出胜负。
func damage_multiplier() -> float:
	var limit := time_limit_seconds()
	var start := limit * SUDDEN_DEATH_FRACTION
	if elapsed <= start:
		return 1.0
	var span := maxf(1.0, limit - start)
	var t := clampf((elapsed - start) / span, 0.0, 1.0)
	if elapsed <= limit:
		return lerpf(1.0, SUDDEN_DEATH_MAX_MULT, t)
	# ★ 过了时限**继续涨**（不封顶意义上）⇒ 战斗必然收敛，不需要硬判负。
	return minf(SUDDEN_DEATH_MAX_MULT + (elapsed - limit) * OVERTIME_RAMP,
			SUDDEN_DEATH_HARD_CAP)

## 战斗日志（HUD 消费）
##
## ★ 2026-10-28（用户：「战斗日志要标注敌方我方的船发生的变化，要做个区分」）：
##   `team` = 这条日志说的是**哪一方的船**（0 我方 / 1 敌方 / -1 不分阵营）。
##   ⛔ 别从文案里反推 —— 两边船名会重名（我方也买茶隼级），只能由写入侧带过来。
class LogEntry:
	var time: float
	var category: StringName   ## fire / damage / break / system / economy
	var text: String
	var team: int
	func _init(p_time: float, p_cat: StringName, p_text: String, p_team: int = -1) -> void:
		time = p_time
		category = p_cat
		text = p_text
		team = p_team

## ★ 2026-10-23：敌方「思考等级」0~3（只影响 team == 1，我方永远按 0 打）。
## 口径见 `EveCampaignTiers.DIFFICULTIES` 的 `ai_level` 注释。
## ⚠️ 它改的是**选目标的打分**，不改任何人的数值 —— 难度来自决策，不来自加成。
var ai_level: int = 0

var ships: Array[EveShip] = []
var elapsed: float = 0.0
var tick: int = 0
var finished: bool = false
var winner_team: int = -1
var log_entries: Array[LogEntry] = []
var _next_target_refresh: float = 0.0
var _ship_by_id: Dictionary = {}

## ★★ 2026-10-10（审查 #4）：**战斗随机数由模拟器自持**。
##   ⛔ 旧实现用全局 `randf()` —— 它受全局状态 / `randomize()` 影响，
##   同一个种子打不出同一场战斗（`eve_run_state` 与斗地主都用带种子的 RNG，
##   代码注释里也强调"回归要能复现"，唯独命中判定不能复现）。
##   ⇒ 命中判定一律走 `rng.randf()`；`set_seed()` 注入种子即可**完整复现**。
##   ⚠️ 默认**不**在 `setup()` 里 randomize —— 无头自检需要确定性；
##      正式游玩由主控显式调 `randomize_seed()`（见 `eve_battle_scene` 建局处）。
var rng := RandomNumberGenerator.new()

## 时间累加器（秒）—— ★ 2026-10-10（审查 2#1）：**固定步长必须真固定**。
##   旧 `step(dt)` 把 `dt` 切成块、**把切剩的零头当成一个更短的 tick** 直接喂给物理
##   ⇒ 帧率或 `time_scale` 一变，战斗结果就变，无法复现。
##   现在：时间先进累加器，只按整 `FIXED_STEP` 出 tick，零头留到下一次。
var _accum: float = 0.0

## 单次 `step()` 最多补的 tick 数 —— 防"死亡螺旋"（卡一帧后每帧补几十 tick，
## 越补越卡）。超出部分**丢弃**：宁可战斗慢一点，也不要卡成雪球。
const MAX_TICKS_PER_STEP := 8
const _STEP_EPS := 1e-6

## 索敌/开火的分频调度（借鉴参考实现：不同系统跑不同频率）
const TARGET_REFRESH_INTERVAL := 5.0 / TICK_RATE   ## 每 5 tick
const LOCK_REFRESH_INTERVAL := 5.0 / TICK_RATE


func setup(own_ships: Array[EveShip], enemy_ships: Array[EveShip]) -> void:
	ships.clear()
	_ship_by_id.clear()
	log_entries.clear()
	elapsed = 0.0
	tick = 0
	finished = false
	winner_team = -1
	_accum = 0.0
	_next_target_refresh = 0.0
	_target_switches = 0
	# ★ 2026-10-27：阵型/集火状态也要重置 —— 复用同一个模拟器重开一局时，
	#   上一场的旗舰与集火目标会**静默地留在身上**（新船 id 恰好撞上就串味）。
	_flagship.clear()
	_focus_target.clear()
	# ★ 2026-10-28：站位方位也要重置（见 `_station_dir`）。
	_station_dir.clear()
	_station_x.clear()
	# 时限回到默认（180s），由调用方决定是否用 set_time_limit() 收窄。
	# ⚠️ 必须在这里重置而不是依赖新实例 —— 复用同一个模拟器重开一局时，
	#    上一场的时限会静默地留在身上。
	max_ticks = MAX_TICKS

	for s in own_ships:
		ships.append(s)
	for s in enemy_ships:
		ships.append(s)
	for s in ships:
		_ship_by_id[s.id] = s

	_log(&"system", "战斗开始：%d v %d" % [own_ships.size(), enemy_ships.size()])


## 注入战斗随机种子 ⇒ 同一 `setup()` + 同种子 + 同调用序列 = **逐 tick 同结果**。
## 用于回归、战斗回放与将来的联机同步（只需同步"种子 + 输入"）。
func set_seed(s: int) -> void:
	rng.seed = s


## 让本场战斗随机（正式游玩的默认路径；无头自检**不要**调它）。
func randomize_seed() -> void:
	rng.randomize()


## 推进一帧（**按真实时间**）：时间进累加器，只出整 tick。
##
## ★ 2026-10-10（审查 2#1）：旧实现 `remaining = dt` 再 `minf(FIXED_STEP, remaining)`
##   —— 零头会变成一个更短的 tick 直接进物理 ⇒ 结果随帧率/时间倍率漂移。
##   现在零头留在 `_accum` 里等下一帧凑够，**每次 tick 的 dt 恒等于 `FIXED_STEP`**。
## ⚠️ 单帧 tick 数有上限（`MAX_TICKS_PER_STEP`），超出**丢弃**积压。
func step(dt: float = FIXED_STEP) -> void:
	if finished or dt <= 0.0:
		return
	_accum += dt
	var n := 0
	while _accum + _STEP_EPS >= FIXED_STEP and not finished:
		_advance_one_tick(FIXED_STEP)
		_accum -= FIXED_STEP
		n += 1
		if n >= MAX_TICKS_PER_STEP:
			_accum = 0.0        # 丢弃积压：防"卡一帧 ⇒ 每帧补几十 tick"的死亡螺旋
			break
	if _accum < 0.0:
		_accum = 0.0


## ★★ 2026-10-27：**渲染插值系数**（0..1）—— 给视觉层用来做插值渲染。
##
## ══════════════════════════════════════════════════════════════════
##  为什么必须有它（用户报的「舰船小幅高频抖动、看不清、发糊」）
## ══════════════════════════════════════════════════════════════════
##  仿真跑 **30 Hz**（`TICK_RATE`），渲染跑 60~240 Hz，而视觉层原来
##  `position = body.position` —— 也就是**直接写上一 tick 的位置**。
##  ⇒ 两次 tick 之间的那几帧，画面**完全静止**，然后一帧跳过去。
##
##  实测（`tools/probe_jitter.tscn`，4v4 巡洋，1 世界单位 ≈ 46.5 px）：
##      · 每 tick 位移 ≈ 54~59 m（**2.5~2.7 px**），峰值 85 m（3.97 px）
##      · 60 fps  → **50% 的渲染帧画面完全没动**，动的那帧跳 3.6~6.8 px
##      · 144 fps → **79% 的帧没动**
##      · 240 fps → **88% 的帧没动**
##      · 仿真自身 0% 速度方向反转（**不是物理在振荡，纯粹是呈现层的跳变**）
##  「静止几帧 + 一次跳几像素」被眼睛读成抖动/发糊，在高刷屏上尤其明显。
##
##  本函数返回的就是那个「当前处在两次 tick 之间的哪个位置」：
##      alpha = 0 → 刚走完一次 tick（应显示 `previous_position` 一侧）
##      alpha = 1 → 下一次 tick 即将发生
##  ⚠️ 调用方（`EveBattleArena.sync_ships`）用它做
##     `previous_position.lerp(position, alpha)`，代价是**画面比仿真晚一个 tick**
##     （33 ms），这是固定步长 + 插值渲染的标准取舍，肉眼无感；换来的是连续运动。
##
##  ⚠️⚠️ 战斗结束后**必须返回 1.0**：那时 `step()` 已不再推进、`_accum` 冻在某个
##     残值上，若继续按它插值，画面会永远停在"离最终位置差一点"的地方 ——
##     表现就是「结算那一刻所有船同时往回缩几像素」。
func interp_alpha() -> float:
	if finished:
		return 1.0
	return clampf(_accum / FIXED_STEP, 0.0, 1.0)


## 明确「跑满这段时间」—— **无单帧上限**，仅供无头验收 / 快进使用。
##
## ⚠️ 与 `step()` 的区别只有上限：`step()` 是"每帧最多补 8 tick 跟住真实时间"，
##    本函数是"把这段时间全部跑完"。⛔ 别接到 UI 的每帧循环上。
func run_seconds(seconds: float) -> void:
	if finished or seconds <= 0.0:
		return
	_accum += seconds
	while _accum + _STEP_EPS >= FIXED_STEP and not finished:
		_advance_one_tick(FIXED_STEP)
		_accum -= FIXED_STEP


func _advance_one_tick(dt: float) -> void:
	elapsed += dt
	tick += 1

	# --- 1. 索敌（分频：每 5 tick） ---
	if elapsed >= _next_target_refresh:
		_next_target_refresh = elapsed + TARGET_REFRESH_INTERVAL
		_refresh_targets()

	# --- 2. 电容 + 修理 ---
	for ship in ships:
		if not ship.alive:
			continue
		_update_capacitor(ship, dt)
		EveCombatCore.repair(
			ship.hp, ship.max_hp, ship.passive_shield,
			ship.active_shield, ship.active_armor, ship.active_hull,
			ship.cap_dry, dt
		)

	# --- 2b. ★ 后勤舰：给友军修（2026-10-01 用户定案）---
	#
	# ⚠️ 为什么必须**紧跟在自修之后**、且单独一轮循环：
	#    ① 紧跟在后面：同一帧里「先扣护盾（被打）→ 再自修 → 再被友军修」
	#       的顺序是确定的，验收才能定死数字。放到运动/开火之后就变成
	#       「本帧打进去的伤害这一帧就被修掉」，读数会随帧序漂。
	#    ② 单独一轮：需要「全队的血」都更新完才挑得出最该修的那一艘。
	#       混在上面那个 for 里，先遍历到的后勤舰会按**上一帧**的血选目标。
	#
	# ⚠️ 目标选择：**同层百分比最低的友军（含自己）**。
	#    · 用「百分比」而不是「绝对差值」—— 否则后勤舰永远在给大船修，
	#      小船被放生（大船掉 100 点绝对值远大于小船掉 50 点，但小船
	#      可能已经掉了一半血）。这条是自走棋里最常见的「奶妈不奶脆皮」。
	#    · ★ **含自己**（2026-10-01 改，原先排除）：敌方总是先打最近的单位，
	#      而后勤就站在前排 ⇒ 大多数局面里**只有后勤自己在掉血**。
	#      排除自己会让它全程空转（实测可修窗口 0/724 帧）。
	#      详见 `_pick_repair_target` 的说明。
	_replenish_own_ships(ships, dt)

	# --- 3. 运动 ---
	for ship in ships:
		if not ship.alive:
			continue
		_apply_motion(ship, dt)
		EveDestinyMotion.integrate_body(ship.body, ship.body.acceleration, dt)

	# --- 3b. ★ 2026-10-31 电子战：锁定减伤 + 干扰 ---
	#
	# ⚠️ 必须排在「4. 锁定与开火」**之前**：本帧掷中的干扰要立刻让目标这一帧
	#    就开不了火。放到开火之后，被干扰的船会多打出一轮（玩家看到的是
	#    「明明被干扰了还在开火」）。
	# ⚠️ 也必须排在「3. 运动」之后：减伤跟着**当前**锁定关系走，
	#    而锁定关系在 `_refresh_targets`（第 1 步）里刚更新过。
	_ew_step(dt)

	# --- 4. 锁定与开火 ---
	for ship in ships:
		if not ship.alive:
			continue
		_update_lock(ship, dt)
		if ship.locked:
			_try_fire(ship, dt)

	# --- 5. 胜负判定 ---
	_check_outcome()


# ------------------------------------------------------------------ 索敌

## 46 轮：**换目标次数**（tick 级累计）—— 防抖的量化指标。
## 用途：`tools/probe_brake_flip.tscn` 判据④。
## 抖动会表现为这个数字巨大（逐帧换目标 ⇒ 3000 帧 × 5 艘 = 1.5 万量级），
## 加了迟滞后应显著下降（目标稳定在几十~几百）。
var _target_switches := 0

## ══════════════════════════════════════════════════════════════════
##  阵型与集火（2026-10-27 用户定案）
## ══════════════════════════════════════════════════════════════════
##
## 用户原话：「阵型环绕，我觉得得学习一下EVE，需要选出一艘船来领头，
##           让我方其他船都跟随它一起动，然后一起集火一艘船」
##
## 三条定案（用户选定）：
##   ① 旗舰 = **吨位最高且活着的那艘**（死了当场改选，不设继任仪式）
##   ② **敌我双方都生效**（不是只给我方的加成）
##   ③ 全队集火**同一艘船**
##
## ── 为什么旗舰要选「吨位最高」而不是「血最多 / 随便一艘」────────────
##   · 吨位最高的船是全场**最慢**的 ⇒ 其余船都比它快 ⇒ **一定跟得上**。
##     反过来（旗舰选最快的护卫）会出现「旗舰跑前面、战列掉队」。
##   · 也是血最厚的 ⇒ 不会频繁猝死、编队不会反复改选。
##
## ── 为什么集火目标由**旗舰点名**、而不是全队投票 ─────────────────
##   · 投票永远投不出稳定多数（每艘船的最佳目标不同），会在两个候选
##     之间来回倒 —— 那是 45/46 轮刚修掉的「舰艏乱摆」的同一种病。
##   · 旗舰点名 = EVE 里的 FC（舰队指挥）叫火，玩家一眼能看懂。
##   ⚠️ 代价（有意接受）：旗舰的射程决定了全队的接敌距离。射程更短的船
##      够不着时会**脱队自己去打**（见 `_follow_formation`）—— 这是必须的，
##      否则短射程船会被队形钉在射程外，一枪不开、战斗也不收敛。
##
## ⚠️ 槽位间距沿用 `EveBattleArena.default_formation()` 的 8 km / 6 km ——
##    开局阵列与运动阵列**同一套尺度**，否则一开打队形会「缩一下」。
##    8 km 远大于两船半径之和（最大 220+220 m）⇒ 不会互相挤。
const FORMATION_COL_STEP := 8_000.0   ## 横向槽距（米）
const FORMATION_ROW_STEP := 6_000.0   ## 纵向槽距（米）
const FORMATION_COLS := 3             ## 每排几列（居中，与开局阵列同宽）

## 全队集火目标的**换目标迟滞**（比例），比单舰的 1.5% 宽得多。
##
## 为什么必须更宽：全队一起换目标 = **全员重新锁定**（锁定 3.5 秒里一枪不放）。
## 单舰抖一下只是丢一艘船的节奏，全队抖一下是整齐地掉一整轮火力。
const FOCUS_SWITCH_MARGIN := 0.15

# ══════════════════════════════════════════════════════════════════
#  层位（2026-10-30 行为重做）
# ══════════════════════════════════════════════════════════════════
#
# 阵型不再「全员一个平面」，而是按定位分前 / 中 / 后三层：
#   前排 = 攻击型护卫、驱逐（自己压上，见 `_advance_with_formation`）
#   中排 = 巡洋、战列（稳守，正面顶住）
#   后排 = 后勤、电子战（远离敌人；⚠️ 只挪站位，射程数值不动）
const LAYER_FRONT := 0
const LAYER_MID := 1
const LAYER_BACK := 2

## 前排槽位沿「远离敌人」方向的前移量（米，负 = 朝敌人）。
const LAYER_OFFSET_FRONT := -5_000.0
## 后排 · 电子战的槽位后移量（米）。
const LAYER_OFFSET_EW := 4_000.0
## 后排 · 后勤的槽位后移量（米）。比电子战更靠后：它是全队唯一的续航。
const LAYER_OFFSET_BACK := 7_000.0

## **全局收敛闸**：开打多少秒后全线放弃阵型、直接压上（「决战」）。
##
## 为什么必须有：玩家报的现象是「打着打着互相避战，拖到时间结束被判负」。
## 阵型本身不产生位移收益，但两支都在锚定的舰队会各自停在射程边缘，
## 一旦双方的 `optimal_range` 交叠得不好，就会出现「谁都够不着谁」的僵局。
##
## ★★ 2026-10-31（用户定案，B 方案「分层站位」的配套）：
##   「开战 30 秒后还是没结果，主力舰就接近吧」⇒ 20 → **30**。
##   前 30 秒：战列线按各自射程分层（战列 25~30 km、护卫自己压到 5~10 km 缠斗）；
##   30 秒后：全线压上，把没分出胜负的局收掉。
##   ⚠️ 名字从 `CONVERGE_AFTER` 改成 `MAIN_PUSH_AFTER`，是因为语义变了：
##      旧语义是「全队怕避战」的保险，新语义是「主力舰的决战时刻」。
##   ⚠️ 代价：遭遇战时限只有 45 s ⇒ 留给决战 15 s。实测没出现超时
##      （见 `docs/玩家反馈-分层站位-2026-10-31.md` 的对比表）；
##      如果哪天遭遇战开始超时，**先回这个值**，别去动伤害。
const MAIN_PUSH_AFTER := 30.0

## **单舰沉默闸**：一艘船连续多少秒没开火 ⇒ 视为「够不着 / 被卡射程外」，自己扑上去。
const SILENT_PUSH_SECONDS := 4.0

## team → EveShip：本队旗舰（吨位最高的活船）。每刷新周期重算，死了自动改选。
## 用 Dictionary 而不是定长数组：team 现在只有 0/1，但别把队数焊死。
var _flagship: Dictionary = {}
## team → EveShip：本队集火目标（旗舰「点名」的结果）。
## 缺键 / 值为 null = 本队没点名 ⇒ 退回「各自按 `_score_target` 挑」的老逻辑。
var _focus_target: Dictionary = {}

## 本队旗舰（供 HUD / 探针 / 验收读取）。无 ⇒ null。
func flagship_of(team: int) -> EveShip:
	return _flagship.get(team)

## 本队集火目标（供 HUD / 探针 / 验收读取）。无 ⇒ null。
func focus_target_of(team: int) -> EveShip:
	return _focus_target.get(team)


func _refresh_targets() -> void:
	# ★ 2026-10-27：先重算「谁领头 + 集火谁」，再据此指派目标。
	_refresh_command()
	for ship in ships:
		if not ship.alive:
			continue
		# ★ 2026-10-27：**全队集火** —— 本队有集火目标时一律打它。
		var focus: EveShip = _focus_target.get(ship.team)
		if focus != null and focus.alive:
			if ship.target_id != focus.id:
				_set_target(ship, focus)
			continue
		# 兜底：本队没集火目标（旗舰或敌人已打光）⇒ 回到各自评分。
		var best: EveShip = null
		var best_score := -INF
		var cur_score := -INF
		var cur: EveShip = _ship_by_id.get(ship.target_id)
		for other in ships:
			if not other.alive or other.team == ship.team:
				continue
			if not _is_valid_target(other):
				continue
			var dist := ship.body.position.distance_to(other.body.position)
			var score := _score_target(ship, other, dist)
			if other == cur:
				cur_score = score
			if score > best_score:
				best_score = score
				best = other
		# ★★ 46 轮：**换目标迟滞（hysteresis）** —— 真正的防抖在这里。
		#
		#   为什么必须放在"比较"这一步、而不是 `_score_target` 的粘性项里：
		#     `_score_target` 的粘性只给**当前目标**加分，但**每 tick 重新比较**
		#     时它仍可能被另一个候选反超（两个候选评分接近时反复拉锯）
		#     ⇒ 实测 `slasher` **逐帧翻目标**（`[W2]` 抓到的
		#       `aim=(-0.99,0,-0.17)` ↔ `(0.35,0,0.94)`，相差 133°）
		#     ⇒ 舰艏被 slerp 平滑到"两个目标的中间" ⇒ 实机看着就是
		#       **舰艏与敌人垂直**（用户 45 轮投诉的真根因）。
		#   做法：新目标必须**显著优于**当前目标（超出 `SWITCH_MARGIN`）才允许换。
		#     比例用**相对**裕度（1.5%）而不是绝对分 —— 因为
		#     `W_IN_RANGE`(1e7) 是主要量级，绝对分差不好定。
		#   ⚠️ 三条仍然允许**立刻换**（迟滞不该造成"死锁在尸体上"）：
		#     ① 当前目标不可用（死了 / 不在 `_ship_by_id` 里）；
		#     ② 新目标**够得着**而当前目标**够不着**（先打能打的）；
		#     ③ 本次比较里当前目标根本没参与评分（`cur_score` 仍是 −INF）。
		const SWITCH_MARGIN := 0.015
		var best_reach := best != null and _in_reach(ship, best)
		var cur_reach := cur != null and cur.alive and _in_reach(ship, cur)
		var must_switch := cur == null or not cur.alive or cur_score <= -INF \
				or (best_reach and not cur_reach)
		# ★ 2026-10-10（审查 #5）：裕度必须按 **|cur_score|** 算。
		#   旧式 `cur_score * (1 + MARGIN) + 1` 在**负分**时（目标不在射程内，
		#   分数主要由 `-dist` 决定 ⇒ 很常见）会把阈值**拉低** ⇒ 反而更容易换目标，
		#   甚至换到一个**更差**的候选上 —— 防抖在负分场景完全失效。
		#   正分时 `cur + |cur|·M + 1` ≡ `cur·(1+M) + 1`，**行为逐位不变**。
		#   ⚠️ `cur_score` 可能是 -INF（本轮未参与评分）⇒ 不能对它取 abs（会 NaN）；
		#      那种情况由 `must_switch` 兜住，这里给个 INF 阈值即可。
		var threshold := INF
		if cur_score > -INF:
			threshold = cur_score + absf(cur_score) * SWITCH_MARGIN + 1.0
		if best != null and best.id != ship.target_id \
				and (must_switch or best.id == -1 \
				or best_score > threshold):
			_set_target(ship, best)

	# ★ 45 轮：**每 tick 刷新「舰艏该朝哪」** —— 视觉层只读 `body.aim_dir`。
	#
	# 为什么必须在这里写、而不是在视觉层自己选目标：
	#   · 选目标（换目标）与「舰艏指哪」是**两个不同的生命周期**：
	#     前者只在换目标时变（`best.id != target_id`），后者**每 tick 都要更新**
	#     （目标在动 ⇒ 方向一直在变）。分开写才不会漏帧。
	#   · 用户 45 轮实机诉求：「船的舰艏和敌人方向全部是垂直的，不是相对的」
	#     —— 真因是红线 46 让舰艏 = **速度方向**，而默认战术是 `orbit_thrust`
	#     （环绕）⇒ 速度方向**天然垂直**于视线 ⇒ 舰艏看着就是"横着飞"。
	#     EVE 玩家的正确直觉 = **舰艏朝向敌人**（朝向才是 EVE 太空战的语言）。
	#   · ⚠️ 目标死了 / 目标 id 丢失 ⇒ 写 **零向量**（视觉层据此退回"朝速度方向"），
	#     不要保留上一帧的旧方向（那会让船"盯着尸体看"）。
	#
	# ★★ 46 轮修正：`aim_dir` **必须投影到水平面（XZ）**，丢掉 Y 分量 ★★
	#
	#   病象（实测 `tools/probe_brake_flip.tscn` 逐帧抓到的现场）：
	#     同一艘 slasher 相邻帧的 `aim` 在
	#       `(-0.02, -0.73, 0.68)` ↔ `(-0.02, +0.57, -0.82)` 之间**垂直跳变**。
	#   ⇒ `|aim.y|` 高达 0.73 意味着「敌人在我正下方 47°」——
	#     而棋盘作战里**所有舰船都在同一平面**，这显然不是玩家看到的画面。
	#   为什么会有 Y：`Body.position` 是**完整 3D**（`EveDestinyMotion` 无 Y 约束）
	#     ⇒ 初始高度差 + 机动 / 环绕的切向都会贡献 Y，且**逐帧噪声很大**
	#     ⇒ 归一化后放大成"大幅俯仰"。
	#   后果：`Basis.looking_at(f, UP)` 要一边偏航一边**抬头/低头**
	#     ⇒ 舰艏的**水平投影**与「敌人在哪个方向」对不上
	#     ⇒ 实机上看着就是用户 45 轮描述的「**舰艏和敌人方向垂直**」。
	#     （⚠️ 这才是那条投诉的完整根因链：`aim_dir` 语义 + Y 污染 两件事叠加。）
	#
	#   修法：**在写入侧**（唯一真相源）把方向拍平到 XZ 平面。
	#     · 太空战在盘面上是**平面作战** ⇒ 舰艏只需要水平朝向，这是正确的语义；
	#     · 拍平后 `f` 恒 ⊥ UP ⇒ `looking_at` 的退化兜底分支**永不触发**；
	#     · 视觉层因此不需要知道任何"盘面语义"（红线 40：语义只在一处表达）。
	#   ⚠️ 拍平后若水平分量恰好为 0（敌人在正上方/正下方，理论上不该发生）
	#     ⇒ 长度退化 ⇒ 写零向量，视觉层退回"朝速度方向"，绝不写 NaN。
	for ship in ships:
		if not ship.alive or ship.body == null:
			continue
		var tgt: EveShip = _ship_by_id.get(ship.target_id)
		if tgt != null and tgt.alive and tgt.body != null:
			var d := tgt.body.position - ship.body.position
			d.y = 0.0
			ship.body.aim_dir = d.normalized() if d.length_squared() > 1e-12 else Vector3.ZERO
		else:
			ship.body.aim_dir = Vector3.ZERO


## 目标是否「够得着」= 距离在 optimal + falloff 之内。
##
## 46 轮抽出成独立函数，因为「够不着就换人」这条规则现在被**两处**引用
## （`_score_target` 的粘性衰减 + `_refresh_targets` 的换目标迟滞），
## 口径必须**只有一份**（红线 40：复刻必然漂移）。
func _in_reach(ship: EveShip, other: EveShip) -> bool:
	if other == null or other.body == null:
		return false
	var dist := ship.body.position.distance_to(other.body.position)
	return dist <= ship.optimal_range + ship.falloff


# ------------------------------------------------------------ 指挥层（旗舰 / 集火）

## 唯一换目标的落点 —— 锁状态必须**整组**重置，别在调用点各写一份。
##
## ⚠️ `locked = false` + `lock_elapsed = 0` 是必须的：换了目标还留着 `locked`
##    会让船对着新目标**立刻开火**（旧锁定被"继承"过去），
##    等于集火换目标零成本 —— 那会让集火强到破坏平衡。
## ⚠️ 只在**真的换了**的时候计数与记日志（`_target_switches` 是防抖指标，
##    重复设同一个目标是常态，不能算进去，否则那个数字立刻失去意义）。
func _set_target(ship: EveShip, tgt: EveShip) -> void:
	if tgt == null or ship.target_id == tgt.id:
		return
	ship.target_id = tgt.id
	ship.locked = false
	ship.lock_elapsed = 0.0
	_target_switches += 1
	_log(&"system", "%s 锁定目标：%s" % [ship.ship_name, tgt.ship_name], ship.team)


## 重算「谁领头 + 集火谁」。每 `TARGET_REFRESH_INTERVAL` 跑一次（与索敌同频）。
##
## ⚠️ 必须**先算完两队的指挥、再统一指派目标** —— 否则先处理的那一队
##    会按「对方还没点名」的状态挑目标，两队结果不对称（我方先跑就占便宜）。
##    这个函数只写 `_flagship` / `_focus_target`，⛔ 不碰任何 `target_id`。
func _refresh_command() -> void:
	# ⚠️ 先把上一轮的集火目标存下来再清空 —— 迟滞的**记忆**就在它身上。
	#    直接 `clear()` 会让 `_name_focus` 每次都看到 `cur == null`
	#    ⇒ 每轮重新选、迟滞完全失效（全队跟着抖动换目标）。
	var prev: Dictionary = _focus_target.duplicate()
	_flagship.clear()
	_focus_target.clear()
	for team in _team_ids():
		_flagship[team] = _elect_flagship(team)
	for team in _team_ids():
		var flag: EveShip = _flagship.get(team)
		if flag == null:
			continue
		_focus_target[team] = _name_focus(flag, team, prev.get(team))
	# ★ 2026-10-27：把指挥层结果**镜像到盘面语义字段**（视觉层只读 `EveShip`）。
	#   ⚠️ 必须整场重刷一遍（而不是只给新旗舰/新目标置位）—— 否则旧旗舰
	#      卸任后 `is_flagship` 会永久留在身上，盘面上就有两个"指挥舰"。
	for s in ships:
		s.is_flagship = false
		s.is_focused = false
	for team in _team_ids():
		var flag2: EveShip = _flagship.get(team)
		if flag2 != null:
			flag2.is_flagship = true
		var focus2: EveShip = _focus_target.get(team)
		if focus2 != null:
			focus2.is_focused = true


## 本场出现过的队伍 id（排序后返回，保证指挥层的处理顺序**确定**）。
func _team_ids() -> Array:
	var seen := {}
	for s in ships:
		seen[s.team] = true
	var out := seen.keys()
	out.sort()
	return out


## 旗舰选举：**吨位最高**的活船；吨位并列则取 id 最小（结果确定、可复现）。
##
## ⚠️ 用 `ship_class`（吨位档）而不是 `cost`：两者现在同源，但语义上
##    「谁大谁领头」看的是舰级，cost 是经济字段（将来可能被羁绊改成 0 费）。
func _elect_flagship(team: int) -> EveShip:
	var best: EveShip = null
	for s in ships:
		if not s.alive or s.team != team:
			continue
		if best == null:
			best = s
			continue
		if s.ship_class > best.ship_class:
			best = s
		elif s.ship_class == best.ship_class and s.id < best.id:
			best = s
	return best


## 旗舰「点名」集火目标：按**旗舰自己的**评分挑，全场只有它一个人有权决定。
##
## ★ 迟滞比单舰宽得多（`FOCUS_SWITCH_MARGIN`）—— 全队换目标 = 全员重新锁定。
##   做法与 `_refresh_targets` 的单舰迟滞同构：
##     ① 当前点名死了 / 不存在 ⇒ 立刻重选；
##     ② 新候选必须显著优于当前点名（超出裕度）才允许换。
##   ⚠️ 这里**不用** `_is_valid_target` 的额外过滤 —— 集火目标只需要「活着 + 敌对」，
##      反正够不着的船会脱队自己去打（见 `_advance_with_formation`）。
func _name_focus(flag: EveShip, team: int, cur: EveShip) -> EveShip:
	# 上一轮的点名还有效吗？（死了 / 不在场上 ⇒ 重选）
	if cur != null and (not cur.alive or not _ship_by_id.has(cur.id)):
		cur = null
	var best: EveShip = null
	var best_score := -INF
	var cur_score := -INF
	for other in ships:
		if not other.alive or other.team == team:
			continue
		if not _is_valid_target(other):
			continue
		var score := _score_target(flag, other,
				flag.body.position.distance_to(other.body.position))
		if other == cur:
			cur_score = score
		if score > best_score:
			best_score = score
			best = other
	if best == null:
		return cur
	if cur == null:
		return best
	# 迟滞：新候选要显著更优才换（负分时按 |cur| 缩放，与单舰口径一致）
	var threshold := cur_score + absf(cur_score) * FOCUS_SWITCH_MARGIN + 1.0
	if best != cur and best_score > threshold:
		_log(&"system", "旗舰 %s 集火点名：%s" % [flag.ship_name, best.ship_name], flag.team)
		return best
	return cur


## 跟随用的**槽位世界坐标**（米）—— 以旗舰位置与航向为基准。
##
## ── 阵型形状 ─────────────────────────────────────────────────────
##   槽位排成「旗舰**身后**的网格」：
##        F  F  F          ← 旗舰（前排正中）
##        o  o  o          ← 第 1 排跟班
##        o  o  o          ← 第 2 排跟班
##   所以跟班全部在旗舰**后方** —— 这既是「跟随」的字面含义，
##   也保证旗舰永远第一个接敌（它是血最厚的，正该如此）。
##
## ── 朝向基准 ─────────────────────────────────────────────────────
##   `basis_z` = 全队要去的方向（本队集火目标方向）。**不是**旗舰的速度方向 ——
##   旗舰开局静止、速度为零，用速度当基准会退化（`normalized()` 变 NaN）。
##   ⚠️ 用集火目标方向还有一个好处：**全队朝同一个方向摆**，
##      不会出现「各自朝各自的目标、队形散成放射状」。
##
## ⚠️ 返回裸坐标（米），⛔ 不保证不重叠 —— 重叠由间距常量避免：
##    `FORMATION_COL_STEP`(8 km) 远大于两船半径和（最大 440 m）。
static func formation_slot(flag: EveShip, basis_z: Vector3, index: int,
		cols: int = FORMATION_COLS) -> Vector3:
	var fwd := basis_z
	fwd.y = 0.0
	if fwd.length_squared() <= 1e-12:
		# 退化兜底：朝敌方半场（我方 base 在 -z 侧，故 +z 是"往前"）
		fwd = Vector3(0.0, 0.0, 1.0 if flag.team == 0 else -1.0)
	fwd = fwd.normalized()
	# 右向量 = forward × UP（右手系，Y 向上）
	var right := fwd.cross(Vector3.UP)
	if right.length_squared() <= 1e-12:
		right = Vector3.RIGHT
	right = right.normalized()

	# 槽位序号 → (col, row)：index 0 = 第一排正中，向两侧铺开
	var col := index % cols
	var row := index / cols
	var half := (cols - 1) * 0.5
	var off_side := (float(col) - half) * FORMATION_COL_STEP
	var off_back := float(row + 1) * FORMATION_ROW_STEP
	return flag.body.position - fwd * off_back + right * off_side


## 目标评分 —— 决定「打谁」。
##
## ⚠️ 这是让战斗收敛的关键，不能只按距离排。
## 只按距离会出问题：射程短的护卫舰去追最远的巡洋舰，
## 结果所有船挤在中间地带，谁都打不着谁（实测卡在 9km 空转 120 秒）。
##
## 评分维度（由高到低权重）：
##   1. 能否打到：射程内的目标绝对优先（这是唯一的硬约束）
##   2. 打了有没有用：优先能破防的（抗性低 / 自身伤害高的目标）
##   3. 威胁度：优先血少的（先集火秒掉，形成数量优势滚雪球）
##   4. 距离：同样条件下就近
func _score_target(ship: EveShip, other: EveShip, dist: float) -> float:
	const W_IN_RANGE := 10_000_000.0
	const W_THREAT := 1_000_000.0
	const W_SQUISHY := 500.0
	# ★ 46 轮：**不要指望调大这个值来防抖**（试过，无效）。
	#   实测把它提到 `20_000_000`（= 2 × W_IN_RANGE）后，`slasher` **仍然逐帧
	#   翻目标** —— 因为 `_refresh_targets` 每 tick 重新比较，另一个候选
	#   只要在某一项上多拿一点就能反超。防抖的正确位置 = 换目标**比较**那一步
	#   （见 `_refresh_targets` 的 `SWITCH_MARGIN` 迟滞）。
	#   这里保留 5 万只作为"轻微偏好"，别删：删了会让 `W_SQUISHY` 等
	#   次要项主导排序，实测更容易抖。
	const W_STICKY := 50_000.0

	var score := -dist

	# 1. 射程：能在 optimal+falloff 内打到才算「够得着」
	if dist <= ship.optimal_range + ship.falloff:
		score += W_IN_RANGE
		# 越靠 optimal 越好（falloff 边缘命中率衰减严重）
		var range_quality := 1.0 - clampf(
			(dist - ship.optimal_range) / maxf(1.0, ship.falloff), 0.0, 1.0)
		score += W_IN_RANGE * 0.2 * range_quality

	# 2. 威胁：优先集火残血目标（数量优势是自走棋胜负手）
	var hp_ratio := other.total_hp() / maxf(1.0, other.total_max_hp())
	score += W_THREAT * (1.0 - hp_ratio) * 0.5

	# 3. 好打程度：目标信号半径越大越容易被炮塔命中
	score += W_SQUISHY * float(other._extra.get(CIDS.X_SIGNATURE, 40.0))

	# ★ 2026-10-23：难度 = 敌方「会打」的等级（只对 team == 1 生效）。
	#
	#   ai_level 1（普通）：**先杀后勤**。
	#     后勤船一枪不开，但每 2 秒给友军回一层血；放任不管等于白打。
	#     这一条逼玩家「买了后勤就得护住它」，乱堆一队杂船会被逐个点掉。
	if ship.team == 1 and ai_level >= 1 and other.is_logistics:
		score += W_THREAT * 0.9
	#   ai_level 3（炼狱）：**优先高输出目标**（每点命中收益最大）。
	#     和「集火残血」叠加后，会先把能打疼它的船拆掉，而不是啃肉盾。
	if ship.team == 1 and ai_level >= 3:
		var dps := other.weapon_damage / maxf(0.1, other.weapon_cycle)
		score += W_THREAT * 0.35 * clampf(dps / 200.0, 0.0, 1.0)

	# 4. 粘性：轻微偏好当前目标。
	#    ⚠️ 46 轮结论：**防抖不能靠这里**（实测把它从 5 万提到 2000 万仍然逐帧翻
	#       目标 —— 因为每 tick 重新比较时，另一个候选仍可能反超）。
	#       真正的迟滞在 `_refresh_targets` 的 `SWITCH_MARGIN`。
	#       这里保留一个小权重即可，别删（删了会让 `W_SQUISHY` 等次要项
	#       主导排序，实测更容易抖）。
	if other.id == ship.target_id:
		score += W_STICKY

	return score


## 目标是否合法（基础筛选，避免极端不合理的追猎）
func _is_valid_target(_other: EveShip) -> bool:
	# 目前不做额外限制：即使够不着也先锁定并前往，否则会站着不动
	# 未来可加：旗舰优先、保护己方残血等规则
	return true


func _update_lock(ship: EveShip, dt: float) -> void:
	if ship.locked:
		return
	var target: EveShip = _ship_by_id.get(ship.target_id)
	if target == null or not target.alive:
		ship.target_id = -1
		return
	ship.lock_elapsed += dt
	if ship.lock_elapsed >= ship.lock_total:
		ship.locked = true


# ------------------------------------------------------------------ 电子战

## ★★ 2026-10-31（用户定案）：电子战 = **锁定减伤 + 干扰**，每 tick 重算。
##
##   ① 减伤（写 `outgoing_mult`）：电子船**正锁定的那一艘**输出 ×(1 − reduce)。
##      多艘电子船锁同一个目标 ⇒ 取**最强**（`minf`），不是连乘 ——
##      6 艘叠乘会把目标削到 0 输出，那是秒杀，不是用户要的「减伤」。
##   ② 干扰（写 `jam_disabled`）：每 `JAM_CYCLE` 秒独立掷一次 `jam_chance`，
##      命中 ⇒ 目标 `JAM_DURATION` 秒不能开火。**概率按船独立掷**，
##      所以多艘电子船压同一目标时等效概率近似相加 —— 用户说的「可叠加」。
##
## ⚠️ 为什么干扰不是「每发都掷」：护卫开火间隔 0.6 秒，6 艘电子船每发各掷
##    5~10% ⇒ 目标每秒被掷十几次，几乎永久哑火。5 秒一个周期 ≈ EVE 里
##    一架 ECM 的锁定周期，也是「玩家能看懂发生了什么」的最短尺度。
##
## ⚠️ `outgoing_mult` 每帧从 1.0 重算，⛔ 不要累乘 —— 锁定关系每 5 tick 就可能换
##    （换目标 / 目标被打死），累乘会让旧目标的减伤永远消不掉。
func _ew_step(dt: float) -> void:
	# ① 复位到「没有电子战影响」
	for ship in ships:
		ship.outgoing_mult = 1.0

	# ② 逐艘电子船：给它的锁定目标挂减伤，并掷干扰
	for ship in ships:
		if not ship.alive or not ship.is_ew:
			continue
		var tgt: EveShip = _ship_by_id.get(ship.target_id)
		if tgt == null or not tgt.alive:
			# 目标没了就补半个周期，避免换到新目标时立刻掷一次（白送一次判定）
			ship.jam_timer = maxf(ship.jam_timer, EveShip.JAM_CYCLE * 0.5)
			continue
		if ship.ew_lock_reduce > 0.0:
			tgt.outgoing_mult = minf(tgt.outgoing_mult, 1.0 - ship.ew_lock_reduce)
		if ship.jam_chance > 0.0:
			ship.jam_timer -= dt
			if ship.jam_timer <= 0.0:
				ship.jam_timer += EveShip.JAM_CYCLE
				if rng.randf() < ship.jam_chance:
					# ⚠️ 只在「从没被干扰」时记一条：连续干扰每 5 秒一次，
					#    每次都记会把 120 行的日志挤满，反而盖掉真正要紧的战报。
					#    判据必须在赋值**之前**读。
					var was_free := tgt.jam_disabled <= 0.0
					tgt.jam_disabled = maxf(tgt.jam_disabled, EveShip.JAM_DURATION)
					if was_free:
						_log(&"system", "%s 干扰 %s · %.0f 秒无法开火"
								% [ship.ship_name, tgt.ship_name, EveShip.JAM_DURATION],
								tgt.team)

	# ③ 递减禁火倒计时（放最后：本帧刚命中的那艘也从**下一帧**开始扣）
	for ship in ships:
		if ship.jam_disabled > 0.0:
			ship.jam_disabled = maxf(0.0, ship.jam_disabled - dt)


# ------------------------------------------------------------------ 开火

func _try_fire(ship: EveShip, dt: float) -> void:
	var target: EveShip = _ship_by_id.get(ship.target_id)
	if target == null or not target.alive:
		ship.target_id = -1
		ship.locked = false
		return

	# 电容不足无法开火
	if ship.cap_max > 0.0 and ship.cap_dry:
		return

	# ★ 2026-10-31 电子战：被干扰 ⇒ 整舰哑火（用户定案「不能攻击 10 秒」）。
	# ⚠️ 返回前**不推进** `weapon_timer`：干扰结束时武器是**冷却完**的状态，
	#    解禁立刻能开火。若在这里扣 timer，10 秒干扰会变成「解禁了还要再等一个
	#    完整开火周期」，实际的停火时间就超过用户定的 10 秒了。
	if ship.jam_disabled > 0.0:
		return

	# 武器循环
	#
	# ⚠️⚠️ 循环内必须**每发都重新确认目标还活着**（2026-10-10 代码审查 · bug#3）：
	#    `_fire_once()` 击杀目标后**不会**改 `ship.target_id`，而 while 在
	#    「射速高 / 掉帧补 tick」时会连发多次 ⇒ 同一具尸体被反复"击杀"，
	#    `kills` 重复 +1、`unit_destroyed` 重复发（残骸与结算都跟着重复）。
	#    正常一帧一发时几乎不触发，只有补 tick 或高射速才暴露 —— 所以必须挡。
	ship.weapon_timer -= dt
	while ship.weapon_timer <= 0.0:
		ship.weapon_timer += maxf(0.1, ship.weapon_cycle)
		_fire_once(ship, target)
		if not target.alive:
			break


func _fire_once(ship: EveShip, target: EveShip) -> void:
	# ★ 2026-10-30：记「这一刻开过火」。单舰沉默闸（`SILENT_PUSH_SECONDS`）靠它判断
	#   这艘船是不是够不着 —— 放在函数最前面：开火这个动作本身就算「没被卡住」，
	#   打不打得中是另一回事。
	ship.last_fire_at = elapsed
	var motion := EveCombatCore.relative_motion(
		ship.body.position, ship.body.velocity,
		target.body.position, target.body.velocity
	)
	var distance: float = motion["distance"]
	var angular: float = motion["angular"]

	var multiplier := 0.0
	var hit := false
	var quality := EveCombatCore.HitQuality.MISS

	# ★ 2026-10-10（审查 2#5）：判据走 `ship.weapon_id`（稳定 id），
	#   不再拿 `_extra` 里的中文比 —— 拼错一个字不会报错，只会静默变成炮塔逻辑。
	if ship.weapon_id == CIDS.W_MISSILE:
		# 导弹必中，但伤害受爆炸半径/速度与目标信号/速度衰减
		var dmg_factor := EveCombatCore.missile_application(
			float(ship._extra.get(CIDS.X_EXPLOSION_RADIUS, 50.0)),
			float(ship._extra.get(CIDS.X_EXPLOSION_VELOCITY, 3000.0)),
			1.0,
			_effective_signature(target),
			target.body.velocity.length()
		)
		# 超出射程无伤害
		if distance > ship.optimal_range:
			return
		multiplier = dmg_factor
		hit = dmg_factor > 0.01
		quality = EveCombatCore.HitQuality.HIT
	else:
		# 炮塔：射程 x 追踪
		# 2026-10-27：把吨位差与目标阵型传进去（用户定案的命中率矩阵）
		var gap := ship.cost - target.cost
		var tgt_orbit := target.stance == EveCombatCore.Stance.ORBIT
		var app := EveCombatCore.turret_chance_to_hit(
			ship.optimal_range, ship.falloff, ship.tracking,
			ship.signature_resolution, _effective_signature(target),
			distance, angular, gap, tgt_orbit
		)
		var roll := rng.randf()
		var result := EveCombatCore.turret_hit_quality(float(app["chance"]), roll)
		hit = result["hit"]
		quality = result["quality"]
		multiplier = float(result["multiplier"])

	if not hit:
		shot_fired.emit(ship, target, false, EveCombatCore.HitQuality.MISS, 0.0)
		return

	# 结算伤害
	# ⚠️ 乘上 damage_multiplier()：90 秒后进入火力渐增，
	#    保证一局必定收尾（详见该函数的说明）。
	var raw_damage := ship.weapon_damage * multiplier * damage_multiplier()
	# ★ 2026-10-31 电子战：**输出侧**倍率。被电子船锁定的船打人不疼。
	#   ⚠️ 放在受击侧 `incoming_mult` 之前：两者是不同来源的独立乘数
	#      （电子战削「谁打的」，壁垒改「谁挨的」），顺序不影响结果，
	#      但读代码的人要能分清 —— ⛔ 别合并成一个字段。
	raw_damage *= ship.outgoing_mult
	# ★ 2026-10-31（玩家反馈：「2 个小护卫能 6 秒干掉满血战列」）：
	#   **吨位压制** —— 小口径打大吨位的伤害折扣。命中率不动（护卫打谁都是 100%，
	#   这是对的），削的是「打进装甲之后还剩多少」。说明与取值口径见
	#   `EveCombatCore.CLASS_PENETRATION` 的顶注。
	#   ⚠️ 位置在 `incoming_mult` 之前：两者一个按「谁打的」、一个按「谁挨的」，
	#     顺序不影响结果，但分成两行写是为了让下一处改动找得到落点。
	raw_damage *= EveCombatCore.class_penetration(ship.cost, target.cost)
	# ★ 2026-11-01：装甲墙（炼狱 BOSS）—— 按玩家舰队的同势力专注度，倍率 0.15~1.0 **连续**。
	#   与抗性分开乘：抗性按伤害类型逐层算，装甲墙是整船的机制折扣。
	#   ⚠️ 2026-10-24 起这里曾是 0.1 的二元开关，已被用户否掉（没有中间态）。
	raw_damage *= target.incoming_mult
	# ★ 2026-10-29（用户定案）：**每发独立掷一次穿盾**。
	#   掷中 ⇒ 这一发跳过护盾直接落装甲（甲抗战列因此能"硬啃"）。
	#   ⚠️ 只有护盾还在时才掷 —— 盾已经破了，掷不掷结果一样，
	#      白白消耗随机数会让同一颗种子下的战报跟以前对不上。
	var pierced := 0.0
	if ship.shield_pierce > 0.0 and float(target.hp.get(&"shield", 0.0)) > 0.0:
		if rng.randf() < ship.shield_pierce:
			pierced = 1.0
	var result := EveCombatCore.apply_damage(
		target.hp, target.resists, raw_damage, ship.weapon_profile, false,
		ship.armor_pierce, pierced
	)
	var applied := float(result["applied"])
	# ★ 2026-10-30：把「这一发穿了盾没有」记在被击中的船上，供播报条用
	#   （`shot_fired` 的信号签名保持不变 —— 改签名会牵动敌方/联机两条链路）。
	target.last_hit_pierced = pierced > 0.5

	ship.damage_dealt += applied
	target.damage_taken += applied

	if ship.cap_max > 0.0:
		ship.cap = maxf(0.0, ship.cap - ship.cap_use * 0.35)

	shot_fired.emit(ship, target, true, quality, applied)
	_log(&"fire", "%s → %s  %s  %.0f 伤害" % [
		ship.ship_name, target.ship_name, _quality_text(quality), applied
	], target.team)

	# 破层事件
	for layer in result["breaks"]:
		_log(&"break", "%s 的%s被击穿" % [target.ship_name, _layer_text(layer)], target.team)

	if target.hp[&"hull"] <= 0.0:
		target.alive = false
		ship.kills += 1
		_log(&"damage", "%s 已被摧毁" % target.ship_name, target.team)
		unit_destroyed.emit(target)


## 目标有效信号半径
func _effective_signature(target: EveShip) -> float:
	var sig := float(target._extra.get(CIDS.X_SIGNATURE, 40.0))
	return maxf(1.0, sig)


# ------------------------------------------------------------------ 运动

func _apply_motion(ship: EveShip, dt: float) -> void:
	var target: EveShip = _ship_by_id.get(ship.target_id)
	if target == null or not target.alive:
		# ★ 2026-10-27：没目标时**跟着旗舰走**（而不是原地停）。
		#   理由：本队集火目标死光的那一瞬，全队会一起僵在原地等下一次点名。
		#   点名周期只有 5 tick（≈0.17s，很短），但**运动是每 tick 都算的** ——
		#   不接管就会真真切切地刹一下车。另外脱队太远的船也需要时间归队。
		if _advance_with_formation(ship, dt):
			return
		# 无目标时缓慢停下
		ship.body.acceleration = -ship.body.velocity * 0.5
		return

	# ★★ 2026-10-27（用户定案）：**强制保持阵型，不许各自接战**。
	#   ⇒ 除旗舰外全员一律飞自己的槽位；旗舰由 `_flagship_advance` 负责
	#     把**整队**推到一个「人人够得着」的站位上。
	#   ⇒ 下面那段 spiral/command（各自扑向目标）**只有无旗舰时才会走到**：
	#     旗舰阵亡后到下一次指挥刷新的那 5 tick，或本队只剩一艘船。
	if _advance_with_formation(ship, dt, target):
		return

	# --- 兜底：本队没有旗舰（全队就剩它一艘 / 指挥层还没建起来）---
	# 这时"阵型"无从谈起，回到改版前的收敛路径（各自扑向主目标）。
	var want_range := ship.engagement_range(target.optimal_range)
	var distance := ship.body.position.distance_to(target.body.position)
	if distance > ship.optimal_range + ship.falloff:
		var accel_close := EveDestinyMotion.spiral_thrust(
			ship.body, target.body, want_range, elapsed, dt)
		ship.body.acceleration = accel_close
		return
	var accel := EveDestinyMotion.command_to_acceleration(
		ship.body, target.body, ship.stance, want_range,
		dt, elapsed
	)
	ship.body.acceleration = accel


## 本舰的定位档（`attack` / `defense` / `logistics` / `ew` / `command`）。
##
## ⚠️ 走 `EveShipDatabase.role_tag()`（唯一真源：电子战 > 加强型 > 后勤 > role 字段），
##    ⛔ 不要在模拟器里自己按 `cost` 或 `role_id` 再判一遍 —— 会与图鉴口径分叉。
func _role_tag_of(ship: EveShip) -> StringName:
	if ship == null:
		return &""
	return EveShipDatabase.role_tag(String(ship.ship_key))


## 本舰该排在**哪一层**（见 `LAYER_*`）。
##
## 判据顺序（前两条优先，因为它们由**数值**决定，改表也不会错）：
##   ① 有修量 ⇒ 后勤（`is_logistics_unit()`，与 HUD / 结算同一判据）
##   ② 电子战 ⇒ 后排
##   ③ 攻击型的护卫 / 驱逐 ⇒ 前排（它们要自己压上去）
##   ④ 其余 ⇒ 中排
func _role_layer(ship: EveShip) -> int:
	if ship == null:
		return LAYER_MID
	if ship.is_logistics_unit():
		return LAYER_BACK
	match _role_tag_of(ship):
		&"logistics":
			return LAYER_BACK
		&"ew":
			return LAYER_BACK
		&"attack":
			return LAYER_FRONT if ship.ship_class <= EveShip.Class.DESTROYER else LAYER_MID
		_:
			return LAYER_FRONT if ship.ship_class <= EveShip.Class.DESTROYER else LAYER_MID


## 本舰是否「**自行接战**」—— 即不等旗舰推队、自己扑向目标的小船。
##
## ★★ 2026-10-31（B 方案「分层站位」）：这个判据现在**有两处**要一致使用：
##   ① `_advance_with_formation()`：是 ⇒ 不飞槽位，自己压上；
##   ② `_fleet_station_distance()`：是 ⇒ **不参与**旗舰站位距离的计算。
##
##   ⚠️⚠️ ② 才是本轮的关键。原来站位取「全队**最短射程**」：
##      编队里只要有 1 艘护卫（reach 12 km），旗舰就被推到 12×0.72 ≈ 8.6 km，
##      再减排深 ⇒ 撞到 3 km 下限 ⇒ **战列被迫贴脸**。
##      贴脸 = 打环绕中的护卫 = 角速度爆表 = 命中率接近 0
##      ⇒ 玩家报的「战列打不中还手」就是这个。
##      分层之后：站位由**站战列线的船**（巡洋及以上）决定，小船自己冲上去缠斗
##      —— 与 EVE 的真实分工一致（大船保持距离，小船环绕）。
func _is_skirmisher(ship: EveShip) -> bool:
	if ship == null:
		return false
	return _role_layer(ship) == LAYER_FRONT and _role_tag_of(ship) == &"attack"


## 阵型跟随：把 `ship` 开向它的位置。返回 `true` = 本 tick 的推力已定稿。
##
## ══════════════════════════════════════════════════════════════════
##  ★★ 强制保持阵型（用户 2026-10-27 定案：「不许各自接战」）
## ══════════════════════════════════════════════════════════════════
##
## ── 语义 ─────────────────────────────────────────────────────────
##   跟班：**永远**飞自己的槽位（旗舰身后 6~18 km 的网格位），无论打没打到人。
##   旗舰：由 `_flagship_advance` 负责，把**整队**推到「人人够得着」的站位上，
##         到位后锚定，全队从各自槽位开火 = EVE 的「战列线 / 锚定舰队」。
##
## ── ⚠️⚠️ 为什么必须让旗舰推到位、而不是让跟班自己扑上去 ────────────
##   「保持阵型」与「人人能开火」在几何上是对立的：槽位在旗舰**身后**
##   6~18 km ⇒ 如果旗舰只顾自己停在交战距离上，**短射程的跟班永远
##   够不着**（它的槽位比旗舰更远离敌人）。
##
##   这不是假设，是实测：第一版就是「逐舰判本舰够不着就走阵型」，结果
##   把战斗从 39.1s 拖到 **540.0s（14 倍）**—— 跟班排着队不开火。
##   第二版改成「全队接敌就解散阵型」（39s→63s，可接受），但**队形只露
##   3 秒**（真局开局 14 km，多数船一上来就在射程内）。
##
##   ⇒ 第三版（本版）：阵型**不解除**，改为**由旗舰把整队推进到
##      「最吃亏的那艘也够得着」的站位上**（`_fleet_covered` / `_fleet_station`）。
##      收敛由「旗舰一定持续推进直到覆盖」保证 —— 不依赖任何船脱队。
##      ⚠️ 代价如实记录：旗舰会**深入敌火**（它要替身后的跟班顶进射程），
##         旗舰阵亡更早 ⇒ 指挥权按吨位顺位移交（`_elect_flagship` 自动重选）。
##         这是"保持阵型"这条需求的直接代价，不是 bug。
func _advance_with_formation(ship: EveShip, dt: float,
		target: EveShip = null) -> bool:
	var flag: EveShip = _flagship.get(ship.team)
	if flag == null or flag.body == null:
		return false
	if flag == ship:
		# 旗舰：开路 / 锚定（见 `_flagship_advance`）
		if target == null:
			return false
		return _flagship_advance(flag, dt, target)

	# ══════════════════════════════════════════════════════════════
	#  ★★ 2026-10-30 行为重做（玩家反馈 / 用户定案）
	# ══════════════════════════════════════════════════════════════
	#  玩家原话：「攻击型护卫不往前顶，现在是谁被点名谁顶上去。
	#             删除以前定的大家要一起跑的行为逻辑，重新弄」。
	#  ⇒ 旧口径（2026-10-27「全队一律飞槽位、谁都不许各自接战」）**作废**。
	#    现在的分工：
	#      · 攻击型护卫 / 驱逐 → **自己压上去**（不跟队，见下面的 FRONT 分支）
	#      · 后勤 / 电子战       → 槽位整体后移（后排），射程数值不动
	#      · 其余               → 仍走槽位，但按层位做了前后偏移（前/中/后三排）
	#    另加两道**收敛闸**，专门治「互相避战拖到超时判负」。
	if target != null:
		# ① 攻击型的护卫 / 驱逐：接到目标就直接扑，不等旗舰把队推上来。
		#    ★ 2026-10-31：判据收进 `_is_skirmisher()` —— 同一个判据还要给
		#      `_fleet_station_distance()` 用（它不再参与站位距离）。两处必须同步，
		#      否则会出现「它不站线，但站位还按它算」的错位。
		if _is_skirmisher(ship):
			return false
		# ② 全局收敛闸：开打 N 秒后全员放弃阵型、直接压上。
		#    ⚠️ 这条是「不许避战到超时」的最后一道保险。
		#    ★★ 2026-10-31（用户定案）20 → **30 秒**：
		#      「开战 30 秒后还是没结果，主力舰就接近吧」。
		#      前 30 秒是真正的分层阵型战（战列线 + 小船缠斗），30 秒后是决战。
		#      ⚠️ 代价：遭遇战时限只有 45 s ⇒ 留给决战 15 s。
		#        实测（probe_duel + sim_winrate）没出现超时，见 docs 里的对比表；
		#        但如果哪天遭遇战开始超时，**先回这个值**，别去动伤害。
		if elapsed >= MAIN_PUSH_AFTER:
			return false
		# ③ 单舰沉默闸：4 秒没开过火 ⇒ 这艘船自己扑上去（够不着 / 被卡射程外）。
		if elapsed - ship.last_fire_at >= SILENT_PUSH_SECONDS:
			return false

	# 跟班：飞自己的槽位（层位偏移见下）
	var cols := _formation_cols(ship.team)
	var slot := formation_slot(flag, _fleet_heading(ship.team),
			_slot_index(ship, flag), cols)
	# ★ 2026-10-30：按层位把槽位沿「远离敌人」的方向前后挪 ——
	#   前排压上、中排不动、后勤/电子战退后排。
	#   ⚠️ 只挪**位置**，不碰任何射程数值（用户选的是 A2「改站位不改数值」）。
	if target != null:
		var away := ship.body.position - target.body.position
		away.y = 0.0
		if away.length_squared() < 1.0:
			away = Vector3(0.0, 0.0, 1.0 if ship.team == 0 else -1.0)
		away = away.normalized()
		var off := 0.0
		# ⚠️ 用 if 而不是 `match`：`match` 里写裸常量名有被当成「绑定变量」的风险
		#    （那样每个分支都会命中第一条），这里必须逐条比数值。
		var layer_now := _role_layer(ship)
		if layer_now == LAYER_FRONT:
			off = LAYER_OFFSET_FRONT
		elif layer_now == LAYER_BACK:
			off = LAYER_OFFSET_BACK if ship.is_logistics_unit() else LAYER_OFFSET_EW
		if not is_zero_approx(off):
			slot += away * off
	# ⚠️ 用 `goto_thrust`（定速接近 + 到点刹住）而不是 `follow_thrust`：
	#    `follow_thrust` 的语义是"与某艘船保持距离"（会跟着它绕圈），
	#    而我们要的是「站在**固定的相对位置**上」—— 那是 `goto_thrust` 的语义。
	#    ⚠️ 槽位是**每 tick 重算**的（旗舰在动、朝向也在变），所以它不是
	#       "一次性航点"：船会一路微调航向 —— 这正是"跟随"。
	ship.body.acceleration = EveDestinyMotion.goto_thrust(ship.body, slot, dt)
	return true


## 旗舰认为「已站到站位上」的容差（米）。
##
## ★★ 2026-10-28 修「护卫跑到边缘」时新增。见 `_flagship_advance` 的说明。
const STATION_SETTLE := 3_000.0

## 每队「站位方位」的平滑状态（team → 水平单位向量）。
##
## ★★ 2026-10-28（同上）：站位原来取「从目标指向旗舰**当前位置**」的实时方位。
##   那个方位会在两军擦身而过时**瞬间翻转 180°** ⇒ 站位跳到敌人另一侧
##   ⇒ 旗舰掉头冲回去 ⇒ 双方反复对穿、全队被拖着一路跑（用户报的"跑到边缘"）。
##   ⇒ 现在把它做成**有惯性、且不许绕过目标背后**的方位：
##      ① 每 tick 朝理想方位做指数平滑（时间常数 `STATION_AXIS_TAU`）；
##      ② 硬夹在「我方半场轴」（team0 = +Z，team1 = −Z）的 ±`STATION_AXIS_MAX_DEG` 锥内
##         —— 站到目标背后的几何结果是"两军互换阵地"，必须排除。
var _station_dir: Dictionary = {}

## 站位方位从旧值转到理想值的时间常数（秒）。
## ⚠️ 太小 = 没有惯性（擦身时抖动照旧）；太大 = 敌人绕侧翼时我方转不过来。
const STATION_AXIS_TAU := 1.5

## ★ 站位允许的横向偏移（米，= ±x）。
##   取 16 km：与 `FORMATION_MAX_COLS` 那条注释里的「战场取景横向跨度 ±16 km」同尺度。
##   没有它，敌人横向漂多少我方就追多少 —— 两军各自横着追对方的站位（实测 t=20
##   双方旗舰 z 只差 1.5 km、x 却差了 13.5 km），看起来同样是"跑到边缘去了"。
const STATION_MAX_LATERAL := 16_000.0

## ★ 站位横向跟随目标的**时间常数**（秒）。
##   横向不能像纵深那样"有多近就多近"：两队都在追对方的横向位置 ⇒ 共振，
##   实测会拉开 12 km+（护卫射程才 6 km，等于谁也别打谁），并在场地上横着滑。
##   ⇒ x 走慢速低通（4 s），把"互相追"压成缓慢平移。
const STATION_LATERAL_TAU := 4.0

## 横向低通的状态（team → 平滑后的 x，米）。
var _station_x: Dictionary = {}

## 站位方位允许偏离「我方半场轴」的最大角度（度）。
## 75° 意味着可以在敌**侧翼**站位，但绝不站到它背后。
const STATION_AXIS_MAX_DEG := 75.0


## 旗舰的运动：① 全队还没都能开火 ⇒ 推进到覆盖站位；② 已覆盖 ⇒ 锚定。
##
## ⚠️ 本函数是**收敛的唯一保证**：只要还有跟班够不着，旗舰就会继续推。
##    ⛔ 不要给它加"本舰已够得着就停"的提前退出 —— 那正是 14 倍回归的写法。
##
## ★★ 2026-10-28（用户报「护卫运动着运动着就跑到边缘去了」）：
##   原来的锚定条件**只有** `_fleet_covered()` —— 那是「**全员槽位**都够得着」。
##   它在队伍含深排船时**几何上永远不成立**：
##     第 3 排槽位在旗舰身后 18 km，护卫（1 格 = 6 km 射程）要够得着
##     ⇒ 要求旗舰距敌 ≤ 6 × 0.72 − 18 = **−10.8 km**（负距离，不可能）。
##   而 `_fleet_station_distance()` 自己又有 3 km 下限（不许旗舰撞进敌阵）。
##   ⇒ 两条口径互相矛盾：站位停在 3 km，覆盖恒为 false
##     ⇒ 旗舰**永不锚定、全程满推** ⇒ 两军直接对穿，
##       各跑到对方阵地后方，看起来就是「运动着运动着跑到边缘」。
##   实测（tools 探针，8 艘全护卫）：60 秒内旗舰从 z=+40 km 冲到 −15 km，
##   双方反复穿阵，队形散成 40 km。
##
##   ⇒ 现在补上第二条锚定路径：**旗舰已到达 `_fleet_station` 的站位**（容差内）
##     就锚定 —— 与 3 km 下限同口径，「到位」这件事有明确的几何判据。
##     `_fleet_covered()` 保留：它先成立时提前锚定，省掉最后一段微调。
## ★★ 2026-10-28（同上）：**锚定只看「在不在站位上」**，不再额外看 `_fleet_covered()`。
##   原来的锚定条件是「全覆盖 ⇒ 就地锚定」，而全覆盖**不代表站位正确**：
##   一旦跟班全灭（只剩旗舰），`_fleet_covered()` 恒为 true ⇒ 旗舰**就地锁死**，
##   停在哪儿算哪儿（实测残局旗舰把自己锁在 z=−14.5 km）。
##   ⇒ 判据换成几何位置：**离站位够近**才锚定，否则一律推进回站位。
##     `_fleet_covered()` 仍参与站位距离的计算（`_fleet_station_distance`），
##     只是不再单独构成"可以停"的理由。
func _flagship_advance(flag: EveShip, dt: float, target: EveShip) -> bool:
	if target == null or not target.alive:
		return false
	var station := _fleet_station(flag, target, dt)
	if flag.body.position.distance_to(station) <= STATION_SETTLE:
		# ★ 到位 ⇒ 旗舰锚定。整队站桩输出（战列线）。
		#   锚定的另一个好处：站位稳定 ⇒ 槽位不抖 ⇒ 跟班不来回追。
		flag.body.acceleration = -flag.body.velocity * 1.5
		return true
	# 还没到位 ⇒ 推到「最吃亏的那艘也刚好够得着」的站位上。
	flag.body.acceleration = EveDestinyMotion.goto_thrust(flag.body, station, dt)
	return true


## 全队是否**人人都够得着**主目标（用各自的位置/槽位判）。
##
## ⚠️ 用**槽位**而不是实际位置判跟班：船在往槽位飞的路上会短暂路过
##    火力范围，按实际位置判会过早认为"覆盖了" ⇒ 旗舰提前锚定 ⇒
##    跟班到位后其实够不着 ⇒ 又要重新推进 ⇒ 抖。
func _fleet_covered(team: int, target: EveShip) -> bool:
	var flag: EveShip = _flagship.get(team)
	if flag == null or flag.body == null or target == null or target.body == null:
		return true
	var heading := _fleet_heading(team)
	var cols := _formation_cols(team)
	for s in ships:
		if not s.alive or s.team != team:
			continue
		var p: Vector3 = s.body.position
		if s != flag:
			p = formation_slot(flag, heading, _slot_index(s, flag), cols)
		if p.distance_to(target.body.position) > s.optimal_range + s.falloff:
			return false
	return true


## 旗舰应该停在哪 —— 使**站战列线的船**里最吃亏的那艘（射程最近 + 站位最深）刚好够得着。
##
## 几何：槽位在旗舰身后 `(row+1)*FORMATION_ROW_STEP`。旗舰落点距敌 `S` 时，
## 深度为 `d` 的跟班距敌 ≈ `S + d`。要它够得着：
##     S + d ≤ reach  ⇒  S ≤ reach − d
## 全队取最小 ⇒ 旗舰要**顶到最靠里**的那一个约束上。
##
## ★★ 2026-10-31（B 方案「分层站位」）：**自行接战的船不参与这个 min**。
##
##   旧口径是「全队所有人取 min」⇒ 编队里只要有 1 艘护卫（reach 12 km），
##   旗舰就被算到 `12×0.72 − 排深`，直接撞 3 km 下限 ⇒ **战列被迫贴脸**。
##   而贴脸打环绕中的护卫，角速度爆表、命中率接近 0
##   ⇒ 玩家报的「战列打不中还手」正是这个。
##
##   新口径：只有**站线的船**（巡洋及以上）决定站位；小船自己扑上去（`_is_skirmisher`）。
##   这既是 EVE 的真实分工，也保证「战列的射程优势真的存在」。
##
##   ⚠️ 兜底：如果**全队都是**自行接战的小船（纯护卫队），没有任何站线船 ⇒
##      退回旧口径（全员取 min）。否则 `best` 会是 INF，站位无从算起。
##   ⚠️ 这一条推翻的是 2026-10-27「全队统一站位」的一半 —— 见 `_is_skirmisher()` 的说明。
func _fleet_station_distance(team: int, target: EveShip) -> float:
	var flag: EveShip = _flagship.get(team)
	var best := INF          # 只统计站线船
	var all_best := INF      # 兜底：全队都算（纯小舰队用这个）
	var cols := _formation_cols(team)
	for s in ships:
		if not s.alive or s.team != team:
			continue
		var depth := 0.0
		if s != flag and flag != null:
			var idx := _slot_index(s, flag)
			depth = float(idx / cols + 1) * FORMATION_ROW_STEP
		var limit := (s.optimal_range + s.falloff) * FORMATION_RANGE_MARGIN - depth
		all_best = minf(all_best, limit)
		if not _is_skirmisher(s):
			best = minf(best, limit)
	if all_best == INF:
		return FORMATION_MIN_STANDOFF
	if best == INF:
		# 纯小舰队：没人站线 ⇒ 老口径
		return maxf(all_best, FORMATION_MIN_STANDOFF)
	return maxf(best, FORMATION_MIN_STANDOFF)


## 旗舰的**站位点**（世界坐标）：距敌 `need` 米、站我方半场一侧，带防抖与中线夹持。
func _fleet_station(flag: EveShip, target: EveShip, dt: float = 0.0) -> Vector3:
	var need := _fleet_station_distance(flag.team, target)
	# ★★ 2026-10-31（B 方案的必要补丁）**只进不退**。
	#
	#   站位是 `目标位置 + 方向 × need` —— 一个**相对敌人**的量。
	#   两支舰队都按这个算 ⇒ 对称后撤：我退到距你 24km，你也退到距我 24km
	#   ⇒ 稳定间距 = 2×need = 48km > 战列射程 34km
	#   ⇒ **两军各自站在射程外互相够不着**（实测：前 12 秒只开了 1 炮，
	#     验收 `开火节流真的在吞` 因此挂掉，是这条几何错误的报警）。
	#
	#   分层站位把 need 从「护卫的 8.6km」抬到「巡洋/战列的 24km」之后，
	#   这个陷阱才第一次变得致命（旧口径 need 小，翻倍也还在射程内）。
	#   ⇒ 限制：need 取不到比**当前距离**更远。已经比站位更近的，就地停住，
	#     绝不为了「保持射程」往回退。两军因此只会越来越近，不会互相躲。
	var cur := flag.body.position.distance_to(target.body.position)
	need = minf(need, cur)
	# ── 方位：理想 = 从目标指向旗舰当前位置；再做「有惯性 + 不许绕后」的处理 ──
	var home := Vector3(0.0, 0.0, 1.0 if flag.team == 0 else -1.0)
	var ideal := flag.body.position - target.body.position
	ideal.y = 0.0
	if ideal.length_squared() < 1.0:
		ideal = home
	ideal = ideal.normalized()
	ideal = _clamp_to_home_cone(ideal, home)
	# 指数平滑：把「擦身而过时的 180° 翻转」摊成几秒的缓慢转向
	var prev: Vector3 = _station_dir.get(flag.team, ideal)
	var k := 1.0 - exp(-maxf(dt, 0.0) / maxf(0.01, STATION_AXIS_TAU))
	var dir := prev.lerp(ideal, k)
	if dir.length_squared() < 1e-6:
		dir = ideal
	dir = _clamp_to_home_cone(dir.normalized(), home)
	_station_dir[flag.team] = dir
	var station := target.body.position + dir * need
	# ★★ 2026-10-28（同上）**中线夹持** —— 这条才是「不再跑到边缘」的真正钉子。
	#
	#   站位公式是「目标位置 + 我方半场方向 × need」，锚点在**敌人**身上。
	#   而两队都在推进 ⇒ 这是个正反馈：我冲过去、你冲过来，各追着对方的站位跑，
	#   一路把战场拖到对方半场甚至屏幕外（实测全护卫局 60s 内旗舰从 z=+40 km
	#   冲到 z=−15 km，两队反复穿阵）。
	#   ⇒ 站位**永远不许越过中线**（team0 = z≥0，team1 = z≤0）。
	#     两军都在中线相遇，谁先到谁先停；敌人越线也不会把我方拖过去。
	#     距敌因此只会**更近**（更容易开火），不会更远 —— 不存在打不着的问题。
	if flag.team == 0:
		station.z = maxf(station.z, 0.0)
	else:
		station.z = minf(station.z, 0.0)
	# ★ 横向同理：不许被敌人带着横着追出去（先慢速低通，再夹边界）。
	var want_x := target.body.position.x
	var prev_x: float = _station_x.get(flag.team, want_x)
	var kx := 1.0 - exp(-maxf(dt, 0.0) / STATION_LATERAL_TAU)
	var sx := lerpf(prev_x, want_x, kx)
	sx = clampf(sx, -STATION_MAX_LATERAL, STATION_MAX_LATERAL)
	_station_x[flag.team] = sx
	station.x = clampf(sx, -STATION_MAX_LATERAL, STATION_MAX_LATERAL)
	return station


## 把方位夹进「本方半场轴」的 ±`STATION_AXIS_MAX_DEG` 锥内。
static func _clamp_to_home_cone(dir: Vector3, home: Vector3) -> Vector3:
	var lim := deg_to_rad(STATION_AXIS_MAX_DEG)
	var ang := home.angle_to(dir)
	if ang <= lim:
		return dir
	if ang >= PI - 1e-4:
		# 正好反向（擦身而过那一瞬）：直接取半场轴，别让 slerp 走任意一侧
		return home
	return home.slerp(dir, lim / ang).normalized()


## 旗舰站位距敌的**最小允许值**（米）—— 等于 `min(reach_i × margin − depth_i)`。
##
## ⚠️ 下限 3 km：极端情况（一堆短射程护卫排在深槽）会算出接近 0 甚至负数，
##    那等于让旗舰撞进敌阵。宁可让个别跟班够不着（它会一直飞槽位、等旗舰
##    推进），也不要旗舰自杀式冲脸。
const FORMATION_MIN_STANDOFF := 3_000.0

## ★★ 射程安全余量 —— 站位要让跟班落在 **reach × 本值** 上，不是正好 `reach`。
##
## ⚠️ 为什么必须有它（实测数据，不是保险起见）：
##    第一版把站位算成「最深的跟班**刚好**够得着」= `station = reach − depth`。
##    后果：跟班常年停在**射程边界**上，敌人的一点机动就把它甩出射程 ⇒
##    实测「在射程内比例」只有 **9%~68%**（5 个跟班的局常常只有 9%），
##    战斗被拖到 151.5s（接近 180s 兜底）。
##
##    取 0.72 = 让最深的跟班停在射程的 72% 处 ⇒ 留 28% 的机动空间。
##    ⚠️ 代价：旗舰要多顶 28% 的射程进去 ⇒ 它挨打更早。
##       这是「保持阵型」的直接代价，不是 bug（见 `_advance_with_formation` 的说明）。
##    ⚠️ 不要调到 1.0 以上变成"退后"：旗舰退后会把它自己推出射程。
const FORMATION_RANGE_MARGIN := 0.72


## 全队朝向基准 —— 决定阵型**往哪摆**。
##
## ── 优先级（顺序有讲究，别调换）──────────────────────────────────
##   ① 旗舰**正在移动** ⇒ 用旗舰的**速度方向**。
##      理由：那正是「领头船要往哪去」；而且速度是惯性积分的产物，
##      天生平滑 ⇒ 槽位不会抖。
##   ② 旗舰**停着**（开局静止 / 已到位）⇒ 用本队**集火目标方向**。
##      理由：速度为零时方向退化（`normalized()` 会给 NaN），
##      而"全队朝敌人摆好"正是开局该有的样子。
##   ③ 两者都没有 ⇒ 零向量，由 `formation_slot` 自己兜底（朝敌方半场）。
##
## ⚠️ 为什么**不能**只用集火目标方向：目标一旦贴到旗舰脸上（点射距离），
##    这个方向会随两船的微小相对速度乱转 ⇒ 槽位跟着转 ⇒ 全队在原地画圈。
##    `velocity` 优先就天然避开这种近距离噪声。
func _fleet_heading(team: int) -> Vector3:
	var flag: EveShip = _flagship.get(team)
	if flag == null or flag.body == null:
		return Vector3.ZERO
	var v := flag.body.velocity
	v.y = 0.0
	if v.length() > flag.body.max_speed * 0.05:
		return v
	var focus: EveShip = _focus_target.get(team)
	if focus == null or not focus.alive or focus.body == null:
		return Vector3.ZERO
	var d := focus.body.position - flag.body.position
	d.y = 0.0
	return d


## 本舰在队形里的槽位序号：按**射程升序 + id 升序**排（射程越短排得越靠前）。
##
## ══════════════════════════════════════════════════════════════════
##  ⚠️ 为什么排序键是**射程**而不是吨位（这是实测逼出来的）
## ══════════════════════════════════════════════════════════════════
##  槽位越靠后 = 离敌人越远（`depth = (row+1) × ROW_STEP`）。
##  如果按吨位排（原来的写法），**护卫舰排在最后排** —— 而护卫的射程最短，
##  站在 18 km 深处的槽位上它**永远够不着**任何目标。
##
##  实测（`probe_formation`，N9 编组 15 艘）：「在射程内比例」只有 **9%**，
##  也就是说九成的跟班只是排队跟着、全程一枪不开，战斗被拖到 151.5s。
##
##  ⇒ 改成**射程短的排前面**（槽位浅、离敌近），射程长的排后面（槽位深、
##    正好用掉它们的射程优势）。这是 EVE 舰队「近战船压前、远战舰压后」
##    的同一条几何逻辑，不是审美选择。
##
## ⚠️ 排序必须**稳定可复现**：射程相同再按 id 升序，否则同一帧内
##    两艘同型船的槽位会互换 ⇒ 它们互相撞位 ⇒ 队形抖。
func _slot_index(ship: EveShip, flag: EveShip) -> int:
	var mates: Array[EveShip] = []
	for s in ships:
		if s.alive and s.team == ship.team and s != flag:
			mates.append(s)
	mates.sort_custom(func(a: EveShip, b: EveShip) -> bool:
		var ra := a.optimal_range + a.falloff
		var rb := b.optimal_range + b.falloff
		if not is_equal_approx(ra, rb):
			return ra < rb
		return a.id < b.id)
	return maxi(0, mates.find(ship))


## 本队的队形**列数** —— 让排数不超过 3，避免队形被拉得过于纵深。
##
## ⚠️ 纵深是**直接吃掉射程**的：`depth = (row+1) × 6 km`。
##   15 艘按 3 列排 ⇒ 5 排 ⇒ 最深 30 km，连战列舰都够不着自己的目标
##   （实测 N9/N15 那两个用例就是这种局面）。
##  ⇒ 列数随人数增长（`ceil(人数/3)`），排数恒 ≤ 3 ⇒ 最大纵深锁在 18 km。
##
## ⚠️ 列数上限 8：再多横向铺开会超出战场的取景（`probe_formation` 的布阵
##    横向跨度已经用到 ±16 km）。超出部分的船就挤在最后一排。
const FORMATION_MAX_COLS := 8
const FORMATION_MAX_ROWS := 3

func _formation_cols(team: int) -> int:
	var mates := 0
	for s in ships:
		if s.alive and s.team == team:
			mates += 1
	mates = maxi(0, mates - 1)          # 减去旗舰
	if mates <= FORMATION_COLS * FORMATION_MAX_ROWS:
		return FORMATION_COLS
	return clampi(int(ceilf(float(mates) / float(FORMATION_MAX_ROWS))),
			FORMATION_COLS, FORMATION_MAX_COLS)


# ------------------------------------------------------------------ 电容

func _update_capacitor(ship: EveShip, dt: float) -> void:
	# 开火时会额外耗电（已在开火时扣），这里跑回充与干涸状态机
	var result := EveCombatCore.update_capacitor(
		ship.cap, ship.cap_max, ship.cap_regen,
		ship.cap_use * 0.5, ship.cap_dry, dt
	)
	ship.cap = float(result["cap"])
	var was_dry := ship.cap_dry
	ship.cap_dry = bool(result["cap_dry"])
	if ship.cap_dry != was_dry:
		if ship.cap_dry:
			_log(&"system", "%s 电容干涸，主动修理停止" % ship.ship_name, ship.team)
		else:
			_log(&"system", "%s 电容已恢复" % ship.ship_name, ship.team)


# ------------------------------------------------------------------ ★ 后勤

## 后勤舰给友军修血。每 `logistics_cycle` 秒触发一次。
##
## ⚠️ 三条口径（改之前先读 `eve_ship_database.gd` 文件头的 A/B 两段）：
##   ① ★ **只修同队、且含自己**（2026-10-01 改，原先不含自己）——
##      「含自己」是 `_pick_repair_target()` 的命门，理由见该函数头长注释，
##      一句话：敌方恒先打最近 ⇒ 后勤站前排 ⇒ 只有后勤自己掉血 ⇒ 不含自己 = 全程空转。
##   ② 目标 = **同层百分比最低**的那一艘（不是绝对差值最低）。
##      绝对差值会让后勤舰永远盯着大船，脆皮被放生。
##   ③ 一帧最多修一艘（一个后勤舰一个目标）。
##      多目标会让「后勤越多越无敌」，整局会打不完（同 REPAIR_ACTIVE_SCALE 的教训）。
##
## ⚠️ 计时用 `dt` 累加而不是墙钟：验收在无头环境里按固定步长推进，
##    用墙钟会让「45 秒」这件事在测试与实际之间对不上
##    （红线 14「音频节流吃 sim.elapsed 不吃墙钟」是同一个道理）。
func _replenish_own_ships(ships_arr: Array, dt: float) -> void:
	# 只收集「能当后勤的活船」，先做完一轮再动手 —— 免得遍历中改状态。
	var medics: Array = []
	for s in ships_arr:
		if s.alive and s.is_logistics_unit():
			medics.append(s)
	if medics.is_empty():
		return
	for m in medics:
		m.logistics_timer -= dt
		if m.logistics_timer > 0.0:
			continue
		# 倒计时到点：**先重置再找目标**（找不到目标也不该把计时器留成负数，
		# 否则下一帧立刻再触发一次，节流形同虚设）。
		m.logistics_timer = m.logistics_cycle
		var t := _pick_repair_target(m, ships_arr)
		# ⚠️ 显式标注 float：`m` 来自无类型 Array ⇒ 它的方法返回 Variant，
		#    `:=` 推断会报 "Cannot infer the type"（踩过）。
		# ⛔ 这里**不能** `continue`：主修那层全队满血时，衍生层那一笔照样该出手
		#    （两支维修器是并行的，不是主修失败就整体作废）。
		if t != null:
			var gained: float = m.repair_ally(t)
			if gained > 0.0:
				_log(&"repair", "%s → %s %s +%d" % [
						m.ship_name, t.ship_name, _layer_text(m.logistics_layer),
						int(roundf(gained))], m.team)
		# ★ 2026-10-28：**紧跟着补一笔另一层**（护盾 ↔ 装甲，量 = 主修 × 3/7）。
		#   · 独立挑目标：那一层里最缺的友军，可以和上面那一笔是同一个人，也可以是别人
		#     —— 用户口径是「一层修盾、一层修甲」两条线并行，不是同一艘修两次。
		var t2 := _pick_repair_target(m, ships_arr, m.logistics_layer_secondary)
		if t2 == null:
			continue
		var gained2: float = m.repair_ally_secondary(t2)
		if gained2 > 0.0:
			_log(&"repair", "%s → %s %s +%d" % [
					m.ship_name, t2.ship_name, _layer_text(m.logistics_layer_secondary),
					int(roundf(gained2))], m.team)


## 挑一个最该修的友军。返回 null = 没有可修的。
##
## 判据 = **那一层的剩余百分比最低**，且未满血、未阵亡。
## ⚠️ 百分比用 `hp / max_hp`，两层各自的分母不同 —— 这是对的：
##    甲抗船的装甲池天生比盾抗船的厚，用同一把尺子量才是公平的。
##
## ★★ 2026-10-01 修：**候选集合改为「含自己在内」**。
##
## 旧版把自己排除在外（理由写着「自己的回充走原生路径，两套不叠加」）。
## 那条理由本身没错，但它导致了一个**真实的空转 bug**：
##
##   敌方索敌 `_score_target` 的主项是 `-dist` ⇒ **双方都先打最近的船**。
##   编队里后勤站位与攻击型一样靠前 ⇒ 后勤成了最近目标 ⇒ 两艘敌舰从开战
##   起全程锁死后勤（实测 f=0 到结束，敌1/敌2 的 `target_id` 一直是后勤）。
##   于是**队友全程一滴血都没掉**，而后勤自己又不能修自己
##   ⇒ 可修窗口 **0/724 帧 = 0.0%**，`repaired_total` 恒为 0。
##   ⇒ 修量调到 ×2 / ×4 / 周期减半 都还是 0（`probe_logi_throughput` 实测）。
##
## 云顶之弈的辅助单位（索拉卡 / 璐璐这类）**治疗目标包含自己**，正是因为
## 「最近的先被打」在那边同样成立 —— 辅助不能自保就会变成废人。
## 加上自己之后实测可修窗口 **0% → 20.7%**（同上探针）。
##
## ⚠️ 与原生回充的关系：两者**不冲突也不重复**。原生回充是 `EveCombatCore.repair()`
##    里那条 EVE 公式（`passive_shield` 峰值 2.0/s，只在护盾层）；
##    这里是每 `logistics_cycle` 秒一次的主动修理。一个是被动小水流、
##    一个是主动大剂量，叠在同一层上是**设计意图**（后勤能给自己续命），
##    不是重复计数 —— 血池是同一本账，谁写进去都算数，不存在"算了两次"。
## ★ 2026-10-28：`layer_override` 非空时改修那一层（后勤的第二支维修器用）。
##   传空 = 沿用 `medic.logistics_layer`（主修，原行为一字不变）。
func _pick_repair_target(medic: EveShip, ships_arr: Array,
		layer_override: StringName = &"") -> EveShip:
	var layer: StringName = medic.logistics_layer if layer_override.is_empty() else layer_override
	if layer.is_empty():
		return null
	var best: EveShip = null
	var best_frac := 1.0
	for s in ships_arr:
		# ⛔ 只排除「死的 / 敌方的」，**不再排除自己**（见上方说明）。
		if not s.alive:
			continue
		if s.team != medic.team:
			continue
		var cap := float(s.max_hp.get(layer, 0.0))
		if cap <= 0.0:
			continue
		var frac := clampf(float(s.hp.get(layer, 0.0)) / cap, 0.0, 1.0)
		if frac >= 0.999:
			continue                       # 满血不修（别浪费修理周期）
		if frac < best_frac:
			best_frac = frac
			best = s
	return best


# ------------------------------------------------------------------ 结算

func _check_outcome() -> void:
	var own_alive := 0
	var enemy_alive := 0
	for s in ships:
		if not s.alive:
			continue
		if s.team == 0:
			own_alive += 1
		else:
			enemy_alive += 1

	if own_alive == 0 and enemy_alive == 0:
		_finish(-1)
	elif enemy_alive == 0:
		_finish(0)
	elif own_alive == 0:
		_finish(1)
	elif not no_timeout and elapsed >= time_limit_seconds() * HARD_STOP_MULT:
		# ★ 2026-10-01（第二次改）：**取消超时判负**。
		#
		#   用户原话：「自走棋就该在时限内战斗，直到被击毁」
		#             「这个因素必须排除，这不对，非常不符合自走棋直觉」
		#   ⇒ 战斗只以**一方全灭**结束（上面三条分支）。收敛由火力渐增保证。
		#
		#   这里只剩**安全网**：真到了 3 倍时限还分不出（理论上不可能，
		#   那时伤害已经 20 倍），才按剩余血量强制收尾。
		#
		# ⚠️ 判定用 `elapsed`（秒），**不用 tick** —— tick 按帧累加，
		#    帧率一变就和顶条对不上（这正是本次修的那个 bug）。
		#
		# ★ 2026-11-07（新手模式）：`no_timeout` 时这道安全网**整个不生效**
		#   —— 用户口径是「只有战场上分出胜负才会结束」。此时收敛仍由
		#   火力渐增保证（`damage_multiplier` 超时后继续涨到 20 倍封顶），
		#   所以不会出现"永远打不完"。
		_log(&"system", "僵持过久 —— 按剩余战力判定收场")
		var own_hp := _total_hp_of_team(0)
		var foe_hp := _total_hp_of_team(1)
		_finish(0 if own_hp >= foe_hp else 1)


func _total_hp_of_team(team: int) -> float:
	var total := 0.0
	for s in ships:
		if s.alive and s.team == team:
			total += s.total_hp()
	return total


func _finish(team: int) -> void:
	if finished:
		return
	finished = true
	winner_team = team
	var text := "平局"
	if team == 0:
		text = "己方胜利"
	elif team == 1:
		text = "己方战败"
	_log(&"system", "战斗结束：%s（用时 %.1fs）" % [text, elapsed])
	battle_finished.emit(team)


# ------------------------------------------------------------------ 工具

## `team`：这条日志说的是哪一方的船（0 我方 / 1 敌方 / -1 不分阵营）。
## 见 `LogEntry.team` 的注释 —— 战斗日志窗靠它做左右阵营区分。
func _log(category: StringName, text: String, team: int = -1) -> void:
	log_entries.append(LogEntry.new(elapsed, category, text, team))
	# 限制日志长度，避免长局内存膨胀
	if log_entries.size() > 2000:
		log_entries = log_entries.slice(log_entries.size() - 1500)


static func _quality_text(q: int) -> String:
	match q:
		EveCombatCore.HitQuality.WRECKING: return "毁灭打击"
		EveCombatCore.HitQuality.SMASHING: return "重创"
		EveCombatCore.HitQuality.PENETRATING: return "穿透"
		EveCombatCore.HitQuality.HIT: return "命中"
		EveCombatCore.HitQuality.LIGHT: return "轻伤"
		EveCombatCore.HitQuality.BARELY: return "擦过"
		_: return "未命中"


static func _layer_text(layer: StringName) -> String:
	match layer:
		&"shield": return "护盾"
		&"armor": return "装甲"
		_: return "结构"


## 战斗统计（供结算面板）
func statistics() -> Dictionary:
	var total_dealt := 0.0
	for s in ships:
		total_dealt += s.damage_dealt
	return {
		"duration": elapsed,
		"ticks": tick,
		"winner": winner_team,
		"total_damage": total_dealt,
		"log_count": log_entries.size(),
	}
