extends RefCounted

## 一场战斗彻底收束（含未布阵 / 时限判负两条路径）。
## 多人对战用它结算掉血：只挂 sim.battle_finished 会漏掉判负路径。
signal battle_over(winner_team: int, own_alive: int, foe_alive: int)

## 战斗阶段（BATTLE）—— 状态机三拆之二。
##
## ══════════════════════════════════════════════════════════════════
##  它负责什么
## ══════════════════════════════════════════════════════════════════
##  · 开战：摆上敌方视觉 → 建模拟器（注入种子）→ 接三条 sim 信号 → 切顶条。
##  · 推进：`sim.step` + 日志桥接 + 火力渐增提示 + 视觉位置同步。
##  · 收束：战斗结束 / 未布阵判负 / 时限归零判负 —— **三条路都汇到 `finished()`**，
##    再交给结算阶段模块（`eve_phase_resolve.arm_result`）。
##
## ⚠️⚠️ **状态归属**：这 4 个字段是**本模块**的：
##      `sd_announced` · `timeout_forfeit` · `_enemy_visuals_spawned` · `_logged_count`
##    前两个是**契约**（验收脚本 `_battle.get/set("_sd_announced"/"_timeout_forfeit")`）
##    ⇒ 主控用 get/set 透传属性暴露，脚本一个字不用改。
##
## ⚠️ 依赖**显式注入**：
##    · `run` / `hud` / `audio` / `arena` 稳定对象直接传；
##    · `sim` **不是**本模块自持（它是契约成员，验收要 `_battle.get("sim")`）
##      ⇒ 用 `_get_sim` 现取；建好的新模拟器由 `start()` **返回**给主控去存。
##    · `_own_ships` / `_enemy_ships` 会被重建 ⇒ Callable 现取；
##    · 战斗表现两条线（击毁特效 / 开火特效）留在主控（它们是"看"的，不是"算"的）
##      ⇒ 用 Callable 交给这里接线。

var sd_announced := false
var timeout_forfeit := false
var enemy_visuals_spawned := false
var _logged_count := 0

var _run: EveRunState = null
var _hud: EveHudRoot = null
var _audio: EveAudio = null
var _arena: EveBattleArena = null
var _resolve = null
var _get_sim: Callable = Callable()
var _own_ships_cb: Callable = Callable()
var _enemy_ships_cb: Callable = Callable()
## [versus] settle hook handed over by the battle scene.
var _versus_hook: Callable = Callable()
## ★ 2026-10-27：现取「上场下标映射」（fleet 下标 → `run.field` 下标）。
##   结算时用它把阵亡的我方舰船翻译成 `field` 下标，交给 `resolve_battle()` 删。
var _own_field_index_cb: Callable = Callable()
var _on_unit_destroyed_cb: Callable = Callable()
var _on_shot_fired_cb: Callable = Callable()


func setup(p_run: EveRunState, p_hud: EveHudRoot, p_audio: EveAudio,
		p_arena: EveBattleArena, p_resolve, p_get_sim: Callable,
		p_own_ships: Callable, p_enemy_ships: Callable,
		p_own_field_index: Callable,
		p_on_unit_destroyed: Callable, p_on_shot_fired: Callable) -> void:
	_run = p_run
	_hud = p_hud
	_audio = p_audio
	_arena = p_arena
	_resolve = p_resolve
	_get_sim = p_get_sim
	_own_ships_cb = p_own_ships
	_enemy_ships_cb = p_enemy_ships
	_own_field_index_cb = p_own_field_index
	_on_unit_destroyed_cb = p_on_unit_destroyed
	_on_shot_fired_cb = p_on_shot_fired


## 准备阶段每次都把「敌方视觉已生成」的标记清掉（重开 / 新节点都要重新生成）。
## [versus] the battle scene hands us its settle callable here.
func set_versus_hook(cb: Callable) -> void:
	_versus_hook = cb


func reset_visuals() -> void:
	enemy_visuals_spawned = false


# ══════════════════════════════════════════════════════════════════
#  开战
# ══════════════════════════════════════════════════════════════════

## 准备结束 → 锁定操作 → 开打。返回**新建的模拟器**（主控负责存进它的 `sim`）。
func start() -> EveBattleSimulator:
	if _run.phase != EveRunState.Phase.PREP:
		return null
	var own: Array = _own_ships_cb.call()
	var enemy: Array = _enemy_ships_cb.call()
	if own.is_empty():
		# ⚠️ 2026-09-20 起「买船」不再自动上场，所以空手上阵成了一种
		#    玩家真会踩到的状态（云顶里也是）。挡下来，并说清楚下一步做什么 ——
		#    只说「没有船」而不说「去哪儿拿船」，玩家会以为按钮坏了。
		var hint := T.t("BATTLE_NO_DEPLOY",
				"场上一艘船都没有 —— 从备战席拖一艘到棋盘上")
		if _run.bench.is_empty():
			hint = T.t("BATTLE_NO_SHIP",
					"一艘船都没有 —— 先在商店买一艘，再从备战席拖到棋盘上")
		_hud.append_log({"time": 0.0, "category": &"hint", "text": hint})
		return null

	_run.set_phase(EveRunState.Phase.BATTLE)
	_hud.set_phase(1)
	_hud.set_start_button(T.t("BATTLE_ONGOING", "交战中"), false)
	# 阶段 D④：开战读秒在准备阶段倒计时的**最后 3 秒**由 `_tick_countdown_sfx`
	# 播（3 / 2 / 1）。这里**不**同帧假播 —— 三声挤一帧听不出读秒。
	# ⚠️ 若玩家自己点「开战」，就不会听到这 3 声（倒计时还没走到 3），
	#    这是刻意的：读秒是「自动开战」的预告，不是强制前摇。

	# ── 阶段 D①：开战镜头 ──
	# 推近 + 平滑偏到一个更有动感的方位（细节与取值依据见 arena.begin_battle_shot）。
	# ⚠️ 在【建模拟器之前】调：这一下不能等第一帧，否则玩家会看到
	#    「先打了两下、镜头才推过去」。
	# ★ 敌方视觉在**开战这一刻**才生成（准备阶段战场上看不到敌舰）
	if not enemy_visuals_spawned:
		for ship in enemy:
			_arena.spawn_ship_visual(ship)
		# ⚠️ 生成后必须补一次瞬时姿态：`setup()` 不写 rotation ⇒ 不补的话
		#    敌舰会以 Identity 姿态出场（船头乱指，红线 54）。
		#    此时 `ships_board_mode` 已是 false（它只在拖拽期间为真）⇒ 尺寸正确。
		_arena.snap_ships(enemy)
		enemy_visuals_spawned = true

	_arena.begin_battle_shot()
	_hud.clear_damage()
	# 阶段 C 收尾：点了「开战」就是玩家不想再读那行进场词了 —— 立刻收掉，
	# 别让它继续挂在交战画面上（它自己的 4.2 秒寿命还在跑）。
	_hud.hide_entry()

	var limit := _run.battle_seconds()
	var sim := EveBattleSimulator.new()
	# ★ 2026-10-10（审查 #4）：给战斗注入种子 ⇒ 固定种子的一局「商店+战斗」全可复现。
	#   随机局（`battle_seed()==0`）走 `randomize_seed()`，与旧行为一致（每场都不同）。
	if int(_run.battle_seed()) == 0:
		sim.randomize_seed()
	else:
		sim.set_seed(int(_run.battle_seed()))
	sim.setup(own, enemy)
	# ⚠️ 时限必须在 setup 之后设 —— setup 会把它重置回默认 180s
	sim.set_time_limit(limit)
	# ★ 2026-11-07（新手模式）：关掉「3 倍时限按剩余战力强制收场」这道安全网。
	#   ⚠️ `set_time_limit()` **照常要调** —— 火力渐增的曲线基准是它；
	#      不清零它、只关安全网，战斗才会「打到一方全灭为止」而不是"永远打不完"。
	#      详见 `EveBattleSimulator.set_no_timeout()` 的注释。
	var untimed := bool(_run.novice_mode)
	sim.set_no_timeout(untimed)
	# ★ 2026-10-23：敌方思考等级随难度档走（0~3）。只改选目标的打分，不改数值。
	sim.set_ai_level(int(_run.difficulty_row().get("ai_level", 0)))
	sim.unit_destroyed.connect(_on_unit_destroyed_cb)
	# [versus] wrap finished so the match layer also sees the result.
	# The wrapper runs AFTER the single-player settle (connect order), so
	# resolve_battle / salvage / result window all behave exactly as before.
	sim.battle_finished.connect(func(wt: int) -> void:
		finished(wt)
		if _versus_hook.is_valid():
			_versus_hook.call(wt))
	# ── 阶段 D②③：命中反馈 + 伤害数字 ──
	# ⚠️ 这一行同样是「少了它一切照跑、只是什么都看不见」的类型。
	#    verify_run 的 `_step_d_hit` 直接数 arena.battle_fx.active_count()
	#    与 hud.damage_feed.active_count()，就是为了捕获这种静默断线。
	sim.shot_fired.connect(_on_shot_fired_cb)

	# 顶条的倒计时切成「战斗时限」
	#
	# ★ 2026-11-07（新手模式）：传 0 ⇒ 顶条不读秒（写「不限时」），
	#   `_on_stage_timer_expired` 那条「时限归零判负」也就永远不会被触发。
	_hud.set_stage(_run.node_index,
			T.t("BATTLE_STAGE", "%s · 交战") % _run.stage_label(),
			0.0 if untimed else limit)

	_logged_count = 0
	sd_announced = false
	timeout_forfeit = false
	sync_log()
	_hud.append_log({"time": 0.0, "category": &"system",
			"text": T.t("BATTLE_START",
						"开战：我方 %d 艘 vs 敌方 %d 艘 · 打到一方全灭为止（%ds 后火力渐增）")
					% [own.size(), enemy.size(), int(limit)]})
	return sim


# ══════════════════════════════════════════════════════════════════
#  推进
# ══════════════════════════════════════════════════════════════════

## 战斗阶段的一帧。⛔ 只管「算」的部分：顶条倒计时与读秒音是 PREP/BATTLE 共用的，
## 留在主控的分派器里。
func tick(delta: float) -> void:
	var sim = _get_sim.call()
	if sim != null and not sim.finished:
		sim.step(delta)
		sync_log()
		check_sudden_death()
	if sim != null:
		# ★ 2026-10-27：传 `interp_alpha()` —— 仿真 30 Hz、渲染 60~240 Hz，
		#   不插值的话中间那几帧画面完全静止、再一帧跳几像素（用户报的"抖动/发糊"）。
		_arena.sync_ships(sim.ships, delta, sim.interp_alpha())


## 把模拟器新产生的日志搬进 HUD（只搬增量的那一截）。
func sync_log() -> void:
	var sim = _get_sim.call()
	if sim == null:
		return
	if _logged_count >= sim.log_entries.size():
		return
	for i in range(_logged_count, sim.log_entries.size()):
		_hud.append_log(sim.log_entries[i])
	_logged_count = sim.log_entries.size()


## ★ 火力渐增的开始提示（时限的 `SUDDEN_DEATH_FRACTION` 处触发一次）。
##
## ⚠️⚠️ 2026-10-04 修的真 bug：原来这里直接调
##    `hud.set_stage(..., 0.0)` 把顶条倒计时**当场归零** ——
##    而火力渐增在**时限的固定比例**就开始（当时 `SUDDEN_DEATH_FRACTION=0.60`）：
##    遭遇战 45s → 27s 触发，顶条还剩 18s；精英战 55s → 33s，还剩 22s。
##    ⇒ 用户实机看到「明明战斗还剩 20 多秒，结果一下就归零了」。
##    （现值为 0.45 ⇒ 遭遇战 20.2s 触发，道理不变，只是更早。）
##
##    正确行为：火力渐增只是**伤害放大机制**的开始，跟倒计时**没有任何关系**
##    —— 只发一条日志，倒计时让它自然走完。
##
## ⚠️ 抽成独立方法不为好看：verify_run 要直接调它，断言「调完之后
##    顶条的 time_left 一个字都没变」—— 内联在 `_process` 里就测不到了。
func check_sudden_death() -> void:
	if sd_announced:
		return
	var sim = _get_sim.call()
	if sim == null:
		return
	if sim.damage_multiplier() > 1.0:
		sd_announced = true
		# ★ 2026-11-07：新手模式没有时限，"或时限归零"那句是假话 —— 换一条。
		var untimed := bool(sim.no_timeout)
		_hud.append_log({"time": sim.elapsed, "category": &"system",
				"text": "火力渐增 —— 伤害开始放大，直到一方被击毁（本局不判超时）" if untimed
						else T.t("BATTLE_ESCALATE",
						"火力渐增 —— 伤害开始放大，直到一方被击毁或时限归零")})


# ══════════════════════════════════════════════════════════════════
#  收束（三条路都汇到这里）
# ══════════════════════════════════════════════════════════════════

## 结算原因 —— **纯函数**（三个事实进、一个字符串出）。
##
## ⚠️ 抽出来不是为了好看：四条分支里有两条（「未部署」「我方全灭」）在真实
##    对局里很难稳定复现（一条要等准备倒计时走完、一条要正好被打光），
##    抽成纯函数，自检才能四条一起钉住（`verify_run._step_d_result`）。
##
## ⛔ 2026-10-01：这个数原来叫 `leaked`（漏网），现在只表示「敌方还剩几艘」——
##    **它不再参与任何扣血计算**，只用来区分「这场为什么结束」。
##
## 判定顺序**不能换**：
##   ① `own_empty`        —— 只有「准备超时判负」这条路会为真（不经过模拟器）
##   ② `enemy_alive > 0`  —— 还有敌舰活着 ⇒ 我方被打光，或极罕见的僵持收场
##   ③ 剩下（=0）         —— 敌舰全死，含"平局"（双方同归于尽时也是 0）
##
## ⛔ 2026-10-01（第二次改）：这里原来返回「时限耗尽」。战斗已改为
##    **打到一方全灭为止**（超时不再判负），所以正常情况下
##    **只有「敌方全灭 / 我方全灭 / 未部署」三种**会出现。
## ★ 2026-10-11（i18n）：文案取词（见 `eve_text.gd` 顶注）。
const T := preload("res://scripts/core/eve_text.gd")

static func end_reason(own_empty: bool, enemy_alive: int, own_alive: int,
		timed_out: bool = false) -> String:
	if own_empty:
		return "未部署"
	# ★ 2026-10-04：时限归零判负恢复（用户口径），把「时限耗尽」分支加回来 ——
	#    玩家必须能从结算页一眼看出「我是超时输的」，而不是笼统的「拦截失败」。
	#    ⚠️ 顺序在 own_empty 之后：未部署判负是另一条路（PREP 归零），
	#       它不该被「时限耗尽」盖掉。
	if timed_out:
		return "时限耗尽"
	if enemy_alive > 0:
		return "我方全灭" if own_alive == 0 else "僵持收场"
	return "敌方全灭"


## 结束原因 → i18n key。
##
## ⚠️ `end_reason()` 的返回值是**显示源文**（⛔ 判定全在它的参数上：
##    `own_empty` / `enemy_alive` / `own_alive` / `timed_out`，没有一处比字符串）。
##    ⛔ 所以这张表**只做「源文 → key」的取词映射**，不是逻辑分支 ——
##      中文版逐字不变（verify_run 的 592 条断言一条都不用改）。
const REASON_KEYS := {
	"未部署": "BATTLE_REASON_NONE",
	"时限耗尽": "BATTLE_REASON_TIMEOUT",
	"我方全灭": "BATTLE_REASON_WIPED",
	"僵持收场": "BATTLE_REASON_STALEMATE",
	"敌方全灭": "BATTLE_REASON_CLEARED",
}

static func reason_txt(reason: String) -> String:
	if not REASON_KEYS.has(reason):
		return reason
	return T.t(String(REASON_KEYS[reason]), reason)


## `sim.battle_finished` 的处理器。
##
## 「击毁」= 打完之后不活着的船 ⇒ 出残骸（打捞）。
## 「敌方存活」只用来判断**这场为什么结束**，⛔ 不再参与扣血
##    （2026-10-01 删掉「漏网」机制：信标只按「输没输」扣）。
##
## ⚠️ 2026-10-01：顺手把**结算那一刻**的原始属性证据抄下来。
##    理由见 `EveRunState.derive_wreck_tier()` 上方那段：
##    残骸要在结算后 1 秒才画出来，而这 1 秒里舰队会被重建 ⇒
##    事后再去读 `EveShip` 上的字段一定读不到。**只有此刻是准的。**
##
## ★★ 2026-10-01 用户口径：**敌我双方都捞**。原实现只把敌方阵亡者塞进来 ——
##    玩家原话：「打捞要么只打捞我方的，要么打捞敌我双方的，断然没有只打捞
##    敌方的道理」。⇒ 两边一起收，`_set_wreck_from()` 仍按**费用最高**挑一艘。
func finished(winner_team: int) -> void:
	var own: Array = _own_ships_cb.call()
	var enemy: Array = _enemy_ships_cb.call()
	var destroyed: Array = []
	var sources: Array = []
	var enemy_alive := 0
	var m_scale := _run.enemy_scale()
	var _collect := func(s: EveShip) -> void:
		destroyed.append(s)
		var sb: Dictionary = s._extra
		var atk0 := float(sb.get("attack", s.attack))
		var def0 := float(sb.get("armor_struct", 1.0))
		sources.append({
			"star": int(s.star),
			"atk_base": atk0,
			"def_base": def0,
			"shot": maxf(0.0, float(s.attack)),
			"m": m_scale,
			# ★ 2026-10-10（审查 R03）：把阵营一起记进证据。
			#   `_set_wreck_from()` 优先读 `e is EveShip`，但**传进来的是
			#   Dictionary 时**（回归探针、外部驱动）就只剩这里可查 ——
			#   缺它会把我方残骸当敌方 ⇒ 星级被敌方倍率错判。
			"team": int(s.team),
		})
	for s in enemy:
		if s.alive:
			enemy_alive += 1
		else:
			_collect.call(s)
	# ★ 我方阵亡者也要进打捞池（同一个 `_collect`，证据口径完全一致）。
	for s in own:
		if not s.alive:
			_collect.call(s)

	# ── 结束原因 ──（`timed_out` = 归零判负那条路置的位）
	var own_alive := _count_alive(own)
	var reason := end_reason(own.is_empty(), enemy_alive, own_alive, timeout_forfeit)

	# ★ 2026-10-27：算出阵亡的我方舰船在 `run.field` 里的**下标** ——
	#    交给 `resolve_battle()` 把它们从编队移除（否则下个准备阶段舰队一重建
	#    它们就"复活"了，见 `resolve_battle()` 里那段长注释）。
	# ⚠️ 映射用 fleet→field 的 idx_map：`own[i]` 对应 `field[idx_map[i]]`，
	#    两者**严格同下标对齐**（见 `EveFleetFactory.last_idx_map` 顶注）。
	#    `own` 为空（未部署判负）时自然得到空数组 ⇒ 不会误删别人的船。
	var lost_field: Array[int] = []
	var idx_map: Array = _own_field_index_cb.call()
	for i in own.size():
		if i >= idx_map.size():
			break
		if not (own[i] as EveShip).alive:
			lost_field.append(int(idx_map[i]))

	# ⚠️ 结算前的信标读数必须**先记下来** —— resolve_battle 会就地改 run.beacon，
	#    返回值里的 beacon 是结算后的值，光凭它算不出「掉了多少」。
	var beacon_before := _run.beacon
	var res := _run.resolve_battle(winner_team, destroyed, sources, m_scale, lost_field)

	# ── 阶段 D：开战镜头收回 ──
	# 推近是为了看交战，结算就该把构图还回来（不然结算页浮在一个贴脸的特写上）。
	_arena.end_battle_shot()
	# 阶段 D④：结算音。`resolve_battle` 已经算完，这里只是报告结果。
	_audio.play_resolve()

	_hud.set_phase(2)
	_hud.set_stage(_run.node_index, T.t("BATTLE_RESULT", "结算"), 0.0)
	_hud.set_start_button(T.t("BATTLE_RESULTING", "结算中…"), false)

	var text := T.t("BATTLE_DRAW", "平局")
	if winner_team == 0:
		text = T.t("BATTLE_WIN", "拦截成功")
	elif winner_team == 1:
		# ⛔ 这里原来写「被突破」，2026-10-01 改成「拦截失败」——
		#    「突破」这个词是跟着已删除的漏网机制来的，玩家看不懂。
		text = T.t("BATTLE_LOSE", "拦截失败")
	var sim = _get_sim.call()
	_hud.append_log({
		# ⚠️ `sim` 可能为 null（未布阵判负那条路径根本没有模拟器）——
		#    直接读 sim.elapsed 会崩，而且崩在结算里最难查。
		"time": 0.0 if sim == null else sim.elapsed,
		"category": &"economy" if winner_team == 0 else &"damage",
		"text": T.t("BATTLE_LOG",
					"%s（%s）· 我方存活 %d／%d · 信标 −%d（剩 %d）") % [
			text, reason_txt(reason), own_alive, own.size(),
			int(res.get("damage", 0)), _run.beacon,
		],
	})

	# ★ 2026-10-10（2⑦ 状态机三拆）：payload 组装 + 弹窗倒计时 + 「立刻弹」的分支
	#   全在结算模块里。`immediate` = 我方全灭 / 未部署时立刻弹 ——
	#   那时**没有**击毁爆炸可看，没必要让玩家干等一秒。
	#   ⛔ 这**不是**「胜利立刻弹」：胜利时存活 > 0，一定走满延迟 —— 那正是要看的爆炸。
	_resolve.arm_result(res, bool(res.get("won", false)), beacon_before,
			destroyed.size(), reason, own_alive == 0 or own.is_empty())

	# ★ 2026-10-27: finished() 的最后一句 —— 三条收束路径都汇到这里，
	#   所以多人结算挂这个信号（sim.battle_finished 只有模拟器那条有）。
	battle_over.emit(winner_team, own_alive, enemy_alive)


## 未布阵判负 —— **走和正常战败完全同一条结算路径**。
##
## ⛔ 不另造一条「直接扣血 / 直接推进」的分支：那会变成第二份真相源 ——
##    扣血公式、连胜连败、残骸、经验……每加一条规则都要记得改两处。
##    这里只是喂给 `finished(1)`：敌舰一艘没死，它自己会走「未部署」这条结束原因。

func forfeit_no_deploy() -> void:
	_hud.append_log({"time": 0.0, "category": &"damage",
			"text": T.t("BATTLE_FORFEIT_NONE",
						"准备时间结束 —— 未部署任何舰船，本节点判负")})
	finished(1)


## ★ 战斗时限归零判负（2026-10-04 恢复）。
##
## ⚠️ 三个必须：
##   ① `sim.finished = true` 停掉模拟器 —— 不停的话主控的 BATTLE 分支
##      还会继续 `sim.step()`，结算页都弹出来了战斗还在打（幽灵战斗）。
##   ② `timeout_forfeit = true` —— 让结算页显示「时限耗尽」而不是「我方全灭」
##      （此刻我方往往还有活船，不标记的话 reason 会算成「僵持收场」，看不懂）。
##   ③ 走 `finished(1)` —— 扣信标走的是既有战败公式，
##      ⛔ 不在这里手写「直接扣 N 点」（第二份真相源）。
func forfeit_timeout() -> void:
	var sim = _get_sim.call()
	if sim != null:
		sim.finished = true
	timeout_forfeit = true
	_hud.append_log({"time": 0.0, "category": &"damage",
			"text": T.t("BATTLE_FORFEIT_TIMEOUT",
						"战斗时限归零 —— 未能在时限内清场，本节点判负")})
	finished(1)


static func _count_alive(pool: Array) -> int:
	var n := 0
	for s in pool:
		if s.alive:
			n += 1
	return n
