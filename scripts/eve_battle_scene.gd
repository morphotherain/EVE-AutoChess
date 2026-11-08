extends Node

## EVE 自走棋 —— 战斗场景主控（阶段 A：一局状态机已接通）
##
## ══════════════════════════════════════════════════════════════════
##  它在整局里的位置
## ══════════════════════════════════════════════════════════════════
##
##     EveRunState（数字与规则）  ←──  本文件负责「把数字变成船和窗口」
##              │                      和「把玩家的点击变回数字」
##              └──→ HUD（把数字变成字）
##
## 一局的四个阶段（曾经这里只有一个「打完 4 秒自动重开」）：
##
##     PREP     准备：布阵 + 商店 + 买船 + 加速等级 + 倒计时
##     BATTLE   战斗：锁定操作（只有相机可动）
##     RESOLVE  结算：漏船扣信标 / 发经验发钱 / 推进节点
##     ENDING   结局：通关 / 撤离
##
## ── 这一版删掉了什么，为什么 ──────────────────────────────────
##   `auto_restart_delay = 4.0` 的**自动重开**被删掉了。
##   自走棋的节奏是「我准备好了才开打」；自动重开把玩家从决策者降级成观众。
##   这一行不改，后面加多少经济系统都救不回来（路线文档 §2 阶段 A）。
##
##   `own_size / enemy_size` 两个导出参数也删了 —— 舰队不再随机抽，
##   而是「玩家买的船」和「节点表指定的编组」。
##
## 变更清单（阶段 A）：
##   - begin_prep / start_battle / resolve_battle 三段拆分（所有后续的插槽）
##   - 五条线全部接上：买 / 刷新 / 加速等级 / 锁定 / 开战
##   - 备战席（数据 + 3D 舰船层）· 上场（阶段 A 自动部署）
##   - 顶条：信标常驻 + 阶段名 + 开战按钮文案随阶段变
##   - 战斗时限改由节点表给（45 / 55 / 70 秒）

const ARENA_SCRIPT := preload("res://scripts/scene/eve_battle_arena.gd")
const HUD_SCRIPT := preload("res://scripts/ui/eve_hud_root.gd")
const RUN_STATE_SCRIPT := preload("res://scripts/core/eve_run_state.gd")
## [versus] multiplayer trio
const MATCH_STATE_SCRIPT := preload("res://scripts/core/eve_match_state.gd")
const MATCH_PLAYER_SCRIPT := preload("res://scripts/core/eve_match_player.gd")
const AI_BRAIN_SCRIPT := preload("res://scripts/core/eve_ai_brain.gd")
const VNET_SCRIPT := preload("res://scripts/net/eve_versus_net.gd")
const VTR_SCRIPT := preload("res://scripts/net/eve_versus_transport.gd")
## 跨网走隧道时必须用 **ENet(UDP 27015)** —— 隧道的 port-forward 只映射这一个端口。
## ⛔ 别把隧道模式改成 TCP：实测 easytier 在 --no-tun 下 TCP 流转发不通
##    （连上本地监听器后立刻 ECONNRESET，服务端一次 ACCEPT 都没有）。
const VENET_SCRIPT := preload("res://scripts/net/eve_ddz_transport.gd")
const TUNNEL_ENET_PORT := 27015
## ★ 2026-10-28 中转模式（`scripts/net/eve_udp_relay.gd`）：
## 本机转发器占 27015（接住加入方的 ENet 包），房主的 ENet 服务端用 **27016** 错开。
const RELAY_ENET_PORT := 27016
const RELAY_SCRIPT := preload("res://scripts/net/eve_udp_relay.gd")
## ★ 2026-10-28 零门槛：中继地址内置（见 `scripts/net/eve_net_config.gd` 顶注）。
const NETCFG := preload("res://scripts/net/eve_net_config.gd")
## 对局存档（`user://run.cfg`）—— 见 `EveRunStore` 顶注。
const RUN_STORE := preload("res://scripts/core/eve_run_store.gd")
const TIERS := preload("res://scripts/data/eve_campaign_tiers.gd")
## 舰队装配（把 run 的名单变成 EveShip 实例）—— 从本文件搬出的纯装配逻辑。
const FLEET_FACTORY := preload("res://scripts/scene/eve_fleet_factory.gd")
## 拖放布阵控制器 —— 从本文件搬出的整个拖放交互（见其顶注）。
const DEPLOY := preload("res://scripts/scene/eve_deploy_controller.gd")
## 设置窗桥接器 —— 「设置意图 → 子系统」的唯一落点（见其顶注）。
const SETTINGS_BRIDGE := preload("res://scripts/scene/eve_settings_bridge.gd")
## ★ 状态机三拆之一：结算 / 结局阶段（自持计时器与结算 payload，见其顶注）。
const PHASE_RESOLVE := preload("res://scripts/scene/eve_phase_resolve.gd")
## ★ 状态机三拆之二：战斗阶段（自持火力渐增标志 / 时限判负标志 / 日志游标 / 敌方视觉标记）。
const PHASE_BATTLE := preload("res://scripts/scene/eve_phase_battle.gd")
## ★ 状态机三拆之三：准备阶段里可独立的那块 = 事件节点四选一。
const PHASE_PREP := preload("res://scripts/scene/eve_phase_prep.gd")
## ★ 2026-10-10 i18n：文案取词入口（见 eve_text.gd 顶注）。
const T := preload("res://scripts/core/eve_text.gd")
const AUDIO_SCRIPT := preload("res://scripts/core/eve_audio.gd")
## ★ 字号缩放（2026-10-07）：只动字、不动版面（见 eve_font.gd）
const FONT := preload("res://scripts/ui/eve_font.gd")
## ★ 窗口分辨率档（2026-10-07）：桌面端才有；无头 / 移动端内部直接返回。
const RESOLUTION := preload("res://scripts/ui/eve_resolution.gd")

## 准备阶段时长（秒）。
##
## ⚠️ 交接文档只规定了【战斗时限】（§5.2：遭遇 45 / 精英 55 / BOSS 70），
##    **没有**规定准备阶段多长。这里的 30 秒是本工程侧的取值（云顶同量级）。
##    它不是一个随便的数字：准备倒计时是「买 / 存 / 刷新 / 升级 四选一」
##    这个互斥决策的压力来源 —— 钱只有一个，没有倒计时就没有取舍。
##    要调就调这一个数。
const PREP_SECONDS := 30.0

## 结算展示时长（秒）。
##
## ⚠️ **阶段 D 起这条路径已经退居二线**：正常情况下结算由
##    `EveResult` 结算页停住，等玩家点「继续 · 下一节点」。
##    这个常量只剩一个用途 —— 无头验收 / 调试脚本如果显式设了
##    `_resolve_timer`，仍按定时器收尾（保证旧脚本不用全改）。
##    正常玩法下 `_resolve_timer` 恒为 -1.0，这一行永远不会触发。
const RESOLVE_SECONDS := 3.5

## 结算弹窗的延迟（秒）—— 打完最后一艘船之后，等这么久才弹结算页。
##
## ══════════════════════════════════════════════════════════════════
##  为什么需要这个延迟（2026-10-01 用户要求）
## ══════════════════════════════════════════════════════════════════
##  用户原话：「每回合的结算弹窗需要在舰船被击毁后的一秒后弹出」。
##
##  没有它的话：最后一艘敌舰被击毁的**同一帧**，结算页就盖了上来 ——
##  玩家看不到那条开火线、也看不到击毁爆炸（爆炸寿命 0.75 秒），
##  「我把最后一艘打爆了」这个最有成就感的瞬间被一个弹窗吃掉了。
##
##  ⚠️ 取值 1.0 是用户指定的，别顺手改成 0.5「因为更快」——
##     击毁爆炸的寿命就是 0.75 秒，1.0 才刚好让它完整播完。
##
##  ⚠️ 计时用**真实 delta**（`_process` 里减），不是 `sim.elapsed`：
##     战斗此刻已经结束，`sim.step()` 不再被调用，`elapsed` 冻住了。
##     用 elapsed 计时的话计时器永远归零 ⇒ 结算页永远不弹。（这是本工程
##     反复踩过的那类「停摆变量当计时源」的坑。）
## ★ 2026-10-10：真值搬进 `eve_phase_resolve.gd`（`POPUP_DELAY`），这里只是别名。
##   ⚠️ 保留这个常量名是因为**验收脚本**读 `BATTLE_SCRIPT.RESULT_POPUP_DELAY`。
const RESULT_POPUP_DELAY := PHASE_RESOLVE.POPUP_DELAY

## 全局时间倍率（调试用：2.0 = 战斗快进一倍）
@export var time_scale: float = 1.0

## 单帧最多推进的真实时间（秒）。卡顿一帧时只补这么多，
## 避免一帧里补算几十个 tick（每个 tick 还会触发一串开火回调）越补越卡。
const MAX_FRAME_DT := 0.1

## 准备倒计时归零是否自动开战。
##
## 默认开（云顶口径：准备阶段结束就开打）。
## 想让「准备阶段无限长、只等玩家点开战」时置 false ——
## 调试布阵 / 录素材时用得上。
@export var auto_start_on_timeout: bool = true

var arena: EveBattleArena
var hud: EveHudRoot
var run: EveRunState
## [versus] the room; null = single player.
var versus: EveMatchState = null
## 联机：本回合已打完，正处在「只可打捞」的结算等待里。
## 该标志为 true 时，进下一回合**只**由回合倒计时触发。
var _versus_await_result := false
var sim: EveBattleSimulator = null
## 音频层（阶段 D 子项 ④）。三条总线 + 节流 + 可断言计数器。
var audio: EveAudio

## 上一次播过的倒计时秒数 —— 只在「秒数变了」时才响滴答。
##
## ⚠️ 不记这个的话，准备阶段 30 秒会按帧触发 tick（60fps × 30s = 1800 次）。
##    节流窗口能压住音量，但压不住「本该一秒一响」这个语义。
var _last_tick_second := -1
## ⚠️ 开战读秒（3/2/1）**没有**自己的状态变量 —— 它就挂在准备阶段倒计时的
##    最后 3 秒上（见 `_tick_countdown_sfx`）。
##    早期版本想在 `start_battle()` 里同帧连播 3/2/1：三声挤在一帧里根本听不出
##    读秒，是假实现；而真要「战前等 3 秒」又属于玩法改动。挂在准备倒计时上
##    既真读秒、又不改战斗时序。别把 `play_countdown` 挪回 start_battle。

## ⛔ 2026-10-01 删除：原来有个 `_leaked`（打完后还活着的敌舰）当「漏网」判据，
##    结算时按「漏了几艘」扣信标。整套机制已删 —— 现在信标只按「输没输」扣。
##    仍然需要「打完后敌方还剩几艘」这个数，但只在结算函数里当局部变量用。

## 暂停态（2026-09-28 起是【全局】暂停：PVE 准备 / 战斗都要能停）。
##
## ⚠️ 唯一写入口 = `set_paused()`。直接 `_paused = x` 会漏掉
##    遮罩显隐与设置窗按钮回写 —— 出现「场上停了、按钮还写着暂停」，
##    且不报错。`restart_run()` 是唯一的例外（硬重置，见那里的注释）。
var _paused := false
## 舰队装配器（持有跨敌我的 id 计数器 + 上场下标映射）。见 eve_fleet_factory.gd。
var _fleet := FLEET_FACTORY.new()
## 拖放布阵控制器（持有拖动状态；`_drag` 与它共享同一个字典对象）。见其顶注。
var _deploy := DEPLOY.new()
## 设置窗桥接器（设置意图 → arena/audio/run/store 的唯一落点）。见其顶注。
var _settings_ctl := SETTINGS_BRIDGE.new()
## 结算 / 结局阶段模块（自持 `resolve_timer` / `popup_timer` / 结算 payload）。
var _resolve_phase := PHASE_RESOLVE.new()
## 战斗阶段模块（自持 `sd_announced` / `timeout_forfeit` / 日志游标 / 敌方视觉标记）。
var _battle_phase := PHASE_BATTLE.new()
## 准备阶段模块（事件节点四选一；`begin_prep` 本身留在主控，见其顶注）。
var _prep_phase := PHASE_PREP.new()
var _own_ships: Array[EveShip] = []
## 与 _own_ships 一一对应的 run.field_entries() 下标。
##
## ⚠️ 为什么不直接「_own_ships 的下标 == field 下标」：
##    `EveFleetFactory.build_own` 里遇到造不出来的船会 `continue` 跳过，那一跳之后两个数组就错位了。
##    拖放要用它把「屏幕上点是哪艘船」翻译成「上前名单的第几项」，
##    错一位的后果是「拖 A 船，B 船飞过去」——玩家会以为整个交互坏了。
var _own_field_index: Array[int] = []
var _enemy_ships: Array[EveShip] = []
## ★★ 2026-10-10（2⑦ 状态机三拆）：事件节点的 3 个状态字段**搬进了
##    `eve_phase_prep.gd`**（`_prep_phase`），下面三个只是**透传属性** ——
##    验收脚本 `_battle.get("_pending_event")` / `get("_ship_pick_cache")` 因此不用改。
##
## ⚠️ `_ship_pick_cache` 里塞的是**条目本体**（引用），选完直接改它 ——
##    不记"第几格"：那样上下场一换位就指错人。
var _pending_event: StringName:
	get:
		return _prep_phase.pending_event
	set(v):
		_prep_phase.pending_event = v

## ★ 2026-10-28 联机事件回合：已经处理过的回合号（0 = 还没处理过）。
## 用来保证「一回合只弹一次事件面板」—— 选完会重入 `begin_prep()` 建队。
var _v_event_round := 0

## ★ 2026-11-07（新手模式）：入口弹框与「本次进入游戏已经问过」的标记。
## ⚠️ `_novice_asked` 挡的是**局内重开**（R / 再来一局）：那是同一局游戏的延续，
##    再问一次只是打扰；想换就回主菜单重新进关卡。
var _novice_ask: EveConfirmDialog = null
var _novice_asked := false

var _ship_pick_cache: Array:
	get:
		return _prep_phase.ship_pick_cache
	set(v):
		_prep_phase.ship_pick_cache = v
## ★★ 2026-10-10（2⑦ 状态机三拆）：结算/结局阶段的 4 个状态字段**搬进了
##    `eve_phase_resolve.gd`**（`_resolve_phase`），下面 4 个只是**透传属性**。
##
## ⚠️ 用属性而不用普通成员，是为了让**验收脚本一行都不用改** ——
##    `verify_run` 里到处是 `_battle.get("_result_popup_timer")` /
##    `_battle.set("_pending_result", …)`。
##    （实测确认：`Object.get()` / `Object.set()` 都会调用 GDScript 属性访问器。）
##
## ⚠️ 两个计时器**方向相反**，别合并：
##    `_resolve_timer` = 结算页**收起**（老逻辑，正常玩法恒 -1，只有验收显式设）；
##    `_result_popup_timer` = 结算页**弹出**的延迟（> 0 = 数据已算好、页还没弹，
##    验收断言的正是这个中间态）。
var _resolve_timer: float:
	get:
		return _resolve_phase.resolve_timer
	set(v):
		_resolve_phase.resolve_timer = v

var _result_popup_timer: float:
	get:
		return _resolve_phase.popup_timer
	set(v):
		_resolve_phase.popup_timer = v

## 延迟弹出期间攒下的结算数据（到点交给结算页）。
## ⚠️ 必须**先算好存下来**而不是到点再算：`resolve_battle()` 会就地改
##    `run.beacon`，隔 1 秒再调一次会**再扣一遍血**。
var _pending_result: Dictionary:
	get:
		return _resolve_phase.pending_result
	set(v):
		_resolve_phase.pending_result = v

## `build_payload()` 最近一次的产物（`_pending_result` 的同一份引用）。
## 单独留一个名字是为了让「组装」与「消费」在代码里分得开。
var _result_payload: Dictionary:
	get:
		return _resolve_phase.payload
	set(v):
		_resolve_phase.payload = v
## 上一次重建舰队时的「上场名单 + 棋盘格」指纹。
## 买到新船 / 三连合成 / 拖放调位都会变 —— 变了就得把舰队重新造一遍，
## 否则玩家花了钱或挪了位，战场上却不出现对应的变化。
var _last_field_sig := ""
## ★ 2026-10-30：战斗播报用「本艘船上一次看到的护盾/装甲是否还在」。
## 键 = ship.id，值 = {"shield": bool, "armor": bool}。
## ⚠️ `shot_fired` 不带「打在盾上还是甲上」的信息（见 `_hit_layer` 的说明），
##    所以「破盾 / 破甲」只能靠**状态由有变无**那一发给出来 —— 这是唯一
##    不需要改模拟器信号签名的做法。每回合舰队重建时清空（id 会换）。
var _layer_seen: Dictionary = {}
## 只有名单（不含格号）的指纹 —— 决定要不要打那一行「上场 n／m 艘」日志
var _last_roster_sig := ""
## 上一次打过的「生效羁绊」组合 —— 只在变化时打日志
var _last_synergy_sig := ""
## Web 试玩：初始舰队是否已经发放过（只发一次，后续回合不重复送）。
var _web_starter_done := false
## 正在重建舰队（begin_prep 期间）—— 这期间不要再被 changed 信号触发一次重建
## 正在重建舰队 / 装载面板 —— 这期间 `_refresh_run_ui` 不要再重建一次。
## ★ 2026-10-10（2⑦）：真值搬进 `_prep_phase`，这里透传（事件节点也读写它）。
var _busy: bool:
	get:
		return _prep_phase.busy
	set(v):
		_prep_phase.busy = v

## 拖动状态。空字典 = 没在拖。
##
## ⚠️ 刻意用【一份字典】而不是一堆 _drag_xxx 变量：
##    拖动是「要么全有要么全无」的状态。拆成 source / index / ship_key / screen
##    四个独立变量之后，取消路径上漏清一个就会留下「拿到一半」的中间态 ——
##    这是拖放交互最经典的 bug 来源（表现为下一次点击莫名其妙地开始拖东西）。
##    键：source(&"bench"/&"field") / index / ship_key / star / cost / name /
##        color / screen
##
## ⚠️★ 这个字典**与 `_deploy`（拖放控制器）共享同一个对象**：控制器只对它
##    `clear()` / `merge()`，⛔ 不重新赋值 ⇒ 本变量永远指向那份拖动状态
##    （验收脚本 `verify_run` 直接 `_battle.get("_drag")` 读它）。
var _drag: Dictionary = {}


## [versus] round clock: accumulate while fighting, forfeit on timeout.
func _versus_tick(delta: float) -> void:
	if versus == null or versus.finished:
		return
	# ★ 2026-10-28 房主权威：**还没开赛就什么都不跑** ——
	#   否则加入方在「等待房主」期间自己的回合时钟已经开始走，
	#   120 秒到点还会判自己负（正是这次要修的「各有各的节奏」）。
	if _vawait_start and not _vstarted:
		return
	if versus.round_kind() == EveMatchState.RoundKind.CAROUSEL:
		# ★ 2026-10-28 联机事件回合：没有战斗，但**表要照常走**。
		#   改之前这里是 `return`（时钟完全不动）⇒ 一旦事件面板选完，
		#   玩家就卡在该回合（点开战才会结算，而事件回合又不该打）。
		#   现在：面板还没选完就停表（决策无时限），选完后照常倒计时，
		#   到点由房主推进到下一回合。
		if _v_event_round != versus.global_round():
			return
		versus.round_elapsed += delta
		_refresh_versus_clock()
		if versus.round_timed_out():
			_versus_advance_round()
		return
	versus.round_elapsed += delta
	_refresh_versus_clock()   # every frame, this is a countdown
	# ★ 准备阶段每秒把当前编制发一次。
	#   为什么不是只在开打时发：玩家可能在准备期任意时刻改布阵，
	#   而且「0 艘 ⇒ 判负」那条路根本不走 start_battle()，只在开打时发会漏。
	if _autodeploy and run.phase == EveRunState.Phase.PREP and run.field.is_empty():
		# 让本地玩家也吃一次 AI 的准备逻辑（买船 + 上阵），只为验收。
		var b := AI_BRAIN_SCRIPT.new("inferno")
		b.take_prep_turn(run)
	if _vonline and run.phase == EveRunState.Phase.PREP:
		var now_ms := Time.get_ticks_msec()
		if now_ms - _vfleet_last_ms >= 1000:
			_vfleet_last_ms = now_ms
			_versus_broadcast_fleet()
	# ★ 联机结算期：本回合已打完，正在「只可打捞」的等待里。
	#   倒计时归零才是进下一回合的唯一信号。
	if _versus_await_result:
		if _versus_is_authority() and versus.round_elapsed >= EveMatchState.ROUND_TIME:
			_versus_advance_round()
		return
	if not versus.round_timed_out():
		return
	# ★ 2026-10-28：超时判负/推进只由权威（单机 / 房主）做 ——
	#   加入方数到 120 秒只负责把顶条读成 0:00，等房主的 ROUND。
	if not _versus_is_authority():
		return
	# No winner in time. If the simulator is still running it has its
	# own sudden death, so let it finish normally.
	var sim = _get_sim.call()
	if sim != null and not sim.finished:
		return
	_settle_versus_timeout()


## 回合推进的权威：单机 / 房主。
##
## ★ 2026-10-28 房主权威（用户：「需要房主点击开始游戏各个玩家才能开始游戏」
##   「各有各的节奏，这不对」）：加入方**不再自己判到点**，
##   只跟房主广播的 ROUND 走（见 `_versus_net_tick`）。
func _versus_is_authority() -> bool:
	return not _vonline or _vhost


## Timeout with no simulator running at all.
## 联机唯一推进点：回合倒计时归零（或打完时时钟已耗尽）才进下一回合。
## ★ 2026-10-28：只有权威（单机 / 房主）能推进；房主推进后广播 ROUND 给加入方。
func _versus_advance_round() -> void:
	if versus == null or versus.finished:
		return
	if not _versus_is_authority():
		return
	_versus_await_result = false
	versus._next_round()
	versus.round_elapsed = 0.0
	_refresh_versus_hud()
	_versus_announce_round()
	if versus.finished:
		_versus_finish()
		return
	begin_prep()


func _settle_versus_timeout() -> void:
	if versus == null or versus.finished:
		return
	if not _versus_is_authority():
		return
	var me: int = -1
	for i in versus.players.size():
		var q = versus.players[i]
		if q != null and not q.is_ai:
			me = i
			break
	if me < 0:
		return
	if versus.round_kind() == EveMatchState.RoundKind.PVP:
		var opp: int = versus.human_opponent()
		if opp >= 0:
			versus.apply_outcome({"a": me, "b": opp, "winner": opp, "a_alive": 0, "b_alive": 0})
	else:
		versus.apply_outcome({"a": me, "b": -1, "a_won": false, "a_alive": 0, "b_alive": 0})
	versus.round_elapsed = 0.0
	versus._next_round()
	_refresh_versus_hud()
	_versus_announce_round()
	if versus.finished:
		_versus_finish()
		return
	begin_prep()


func _ready() -> void:
	# ★ 2026-10-10 i18n：**必须早于任何 UI 构建** —— 文案是建的时候取词的。
	T.apply_saved()
	randomize()
	# ★ 字号缩放必须在**建 UI 之前**装好 —— HUD 的每一处字号都在建立时就算定，
	#   晚了第一帧会闪一下旧字号（`reapply()` 能补救，但没必要让它闪）。
	FONT.load_from_settings()
	# ★ 窗口分辨率（2026-10-07）：读盘并应用。
	#   ⚠️ 在**建 UI 之前** —— 窗口尺寸一变，设计空间就变了（非 16:9 的档会产生
	#      居中偏移），HUD 首次铺窗口时要拿到新值。桌面端才有；无头/移动端内部返回。
	RESOLUTION.apply_from_settings(get_window())

	# 3D 竞技场
	arena = ARENA_SCRIPT.new()
	arena.name = "Arena"
	add_child(arena)

	# 音频层（阶段 D 子项 ④）。放在 Arena 之后、HUD 之前 ——
	# 顺序无关紧要，但集中在一处便于看出「场景里的几层是谁」。
	audio = AUDIO_SCRIPT.new()
	audio.name = "Audio"
	add_child(audio)

	# HUD（CanvasLayer 保证浮在 3D 之上）
	var layer := CanvasLayer.new()
	layer.name = "HudLayer"
	add_child(layer)
	hud = HUD_SCRIPT.new()
	hud.name = "Hud"
	layer.add_child(hud)
	# 真实数据已经接上，演示内容一律关掉（HUD 侧默认已是 false，这里再钉一次）
	hud.demo_content = false

	# ── 设置窗桥接器接线（阶段一：arena/hud/audio 已就绪）──
	# ⚠️ `run` 建得更晚（只有「加币」用它）⇒ 阶段二 `bind_run()`。
	# ⚠️ 暂停/重开/回主界面/刷 UI 是**主控自己的动作** ⇒ 传 Callable 回调。
	_settings_ctl.setup(arena, hud, audio, _deploy,
			_get_paused_state, set_paused, restart_run, _do_back_to_menu, _refresh_run_ui)

	# ⚠️ 2026-09-23：原先这里要把 HUD 的 RECT_BENCH 交给 arena.bench_stage，
	#    让 3D 舰船踩在轨道线上。备战席改画 2D 立绘后，这件事归 EveBenchRail
	#    自己管（立绘就在它的 _draw() 里），**不再需要跨「2D HUD → 3D 场景」
	#    递坐标** —— 那一步正是当年多个「两份坐标漂移」事故的来源。
	#    留此注释是为了说明「这里曾经有一行 configure」而不是被误删。

	# ── HUD 信号 ──
	hud.stance_changed.connect(_on_stance_changed)
	hud.range_rings_toggled.connect(_on_range_rings_toggled)
	hud.start_battle_requested.connect(_on_start_battle_requested)
	hud.settings_requested.connect(_settings_ctl.open)
	hud.shop_buy_requested.connect(_on_shop_buy)
	# ★ 2026-11-07：商店卡「第一下 = 看档案」（第二次点击才下单）。
	# ⚠️ 少这一行 = 卡片亮金边、状态栏写「再点一次购买」，右上档案却一动不动。
	hud.shop_preview_requested.connect(_on_shop_preview)
	hud.shop_refresh_requested.connect(_on_shop_refresh)
	hud.shop_levelup_requested.connect(_on_shop_levelup)
	hud.shop_lock_toggled.connect(func(on: bool): run.set_shop_locked(on))
	hud.salvage_requested.connect(_on_salvage)
	# ★ 打捞区两段接线（2026-10-04 改版：逐艘点，无浮层）
	hud.salvage_pick_one.connect(_on_salvage_pick_one)
	hud.salvage_pick_zero.connect(_on_salvage_pick_zero)
	hud.salvage_section_closed.connect(_on_salvage_section_closed)
	hud.stage_timer_expired.connect(_on_stage_timer_expired)
	# 事件四选一（阶段 C）：面板点选 → 这里落地。
	# ⚠️ 少了这一行，面板会**看起来完全正常**（4 张卡、悬停、点击高亮都对），
	#    但点下去什么都不发生 —— 因为信号发出来没人接。verify_run 的
	#    `_step_event_choose` 就是为这类「静默断线」设的（实测捕获过一次）。
	hud.event_option_chosen.connect(_prep_phase.on_event_chosen)
	hud.event_ship_picked.connect(_prep_phase.on_event_ship_picked)
	# 舰船抽奖（2026-10-31 · 炼狱专属）：同款「静默断线」风险 ——
	# 少这两行，抽奖窗的按钮看着能点、点下去什么都不发生，节点也永远推不动。
	hud.lottery_draw_requested.connect(_prep_phase.on_lottery_draw)
	hud.lottery_finished.connect(_prep_phase.on_lottery_finished)

	# ── 阶段 D：结算页 / 设置窗 ──
	# ⚠️ 与上面 event_option_chosen 同款风险 —— 少一行就是「按钮看着能点、
	#    点下去什么都不发生」。verify_run 的 `_step_d_*` 会走控件自身通道验它。
	hud.result_next_requested.connect(_resolve_phase.on_result_next)
	hud.result_end_requested.connect(_resolve_phase.on_result_end)
	hud.settings_background_changed.connect(_settings_ctl.on_background)
	hud.settings_mood_changed.connect(_settings_ctl.on_mood)
	hud.settings_fog_toggled.connect(_settings_ctl.on_fog)
	hud.settings_board_toggled.connect(_settings_ctl.on_board)
	hud.settings_camera_reset.connect(_settings_ctl.on_camera_reset)
	hud.settings_restart.connect(_settings_ctl.on_restart)
	hud.settings_back_to_menu.connect(_settings_ctl.on_back_to_menu)
	# ── 阶段 D+（2026-09-28）：暂停 / 音量 ──
	#
	# ⚠️ 与上面同款风险 —— 少一行就是「按钮看着能点、点下去什么都不发生」。
	#    暂停尤其危险：按下去没反应的话，玩家会以为游戏卡死了。
	hud.settings_pause_toggled.connect(_settings_ctl.on_pause)
	hud.settings_volume_changed.connect(_settings_ctl.on_volume)
	hud.settings_mute_toggled.connect(_settings_ctl.on_mute)
	# 暂停遮罩上的「继续」按钮（设置窗被关掉时的唯一鼠标出口）
	hud.pause_resume_requested.connect(func(): set_paused(false))
	# ⚠️ DEBUG-ONLY: 加币信号（与 settings_window.add_coins_requested 对应）
	hud.settings_add_coins.connect(_settings_ctl.on_add_coins)
	# 全刷请求（hud.refresh() 触发）
	hud.refresh_requested.connect(_refresh_run_ui)

	# ── 读盘：把上一次的设置应用到这一局 ──
	#
	# ⚠️ 必须在**信号连好之后**做：设置窗是 hud 的子节点，它的 _ready 比这里早，
	#    在它自己 _ready 里 emit 的话没人接得到（connect 还没执行）⇒ 静默失效。
	_settings_ctl.apply_saved()

	# ── 一局状态机 ──
	run = RUN_STATE_SCRIPT.new()
	run.name = "RunState"
	add_child(run)
	run.log_event.connect(_on_run_log)
	run.offers_changed.connect(_on_offers_changed)
	run.changed.connect(_refresh_run_ui)
	run.phase_changed.connect(_on_phase_changed)
	run.run_ended.connect(_resolve_phase.on_run_ended)

	# ★ 结算/结局阶段模块接线（此时 run / hud / audio / arena 都在）。
	_resolve_phase.setup(run, hud, audio, arena, _get_sim, begin_prep, restart_run,
			_refresh_salvage_area, _maybe_confirm_leftover_wrecks, _own_stats)

	# ★ 战斗阶段模块接线（它的 `start()` 负责建模拟器，并把三条 sim 信号接到该接的地方）。
	_battle_phase.setup(run, hud, audio, arena, _resolve_phase, _get_sim,
			_get_own_ships, _get_enemy_ships, _get_own_field_index,
			_on_unit_destroyed, _on_shot_fired)
	# [versus] 多人结算挂在 battle_over 上，**不是** sim.battle_finished。
	#  ⚠️ 三条收束路径里只有「模拟器打完」那条有 sim 信号；
	#     「未布阵判负」「时限判负」是直接调 finished() 的 ⇒ 挂 sim 会漏。
	#     实测：准备倒计时到点、场上 0 艘 ⇒ 判负了但多人血量没掉。
	_battle_phase.battle_over.connect(_versus_settle)

	# ★ 准备阶段模块接线（事件节点四选一）。
	_prep_phase.setup(run, hud, _resolve_phase, _refresh_run_ui, _clear_field, begin_prep)

	# 设置窗桥接器**阶段二**：`run` 到位（只有「加币」按钮用它）。
	_settings_ctl.bind_run(run)

	# ── 拖放控制器接线 ──
	# ⚠️ `_own_ships` / `_own_field_index` 会被**重新赋值**（重建舰队）⇒ 传 Callable
	#    让它每次现取，⛔ 别把当前数组塞进去（那就永远是旧数组了）。
	_deploy.setup(run, arena, hud, _drag,
			_get_own_ships, _get_own_field_index, _refresh_run_ui, _log_synergies)

	# 等一帧让 HUD 完成布局
	await get_tree().process_frame

	hud.clear_log()
	# ★ 2026-10-10（审查 2#2）：「继续上一局」—— 主菜单的入口会置 `resume_requested`。
	#    ⚠️ 是**显式**恢复，不是"进来就自动顶掉新开局"：拿不到/读不出档就照常开新局。
	if RUN_STORE.resume_requested:
		# 2026-10-26：先读档，成功才清 pending_difficulty。
		# 旧写法一进来就清 —— 读档失败往下走时难度已被吞掉，
		# 只能沿用 run.difficulty_id 旧值（实测：菜单选炼狱，进游戏是简单）。
		var saved := RUN_STORE.load_run()
		if not saved.is_empty() and run.from_dict(saved):
			RUN_STORE.resume_requested = false
			RUN_STORE.pending_difficulty = ""
			# ★★ 2026-10-25：**货架必须显式推一次给 HUD**。
			#   `from_dict()` 刻意不发 `offers_changed`（那条信号会重摇商店），
			#   而 HUD 的商店卡只在 `offers_changed` 时重建 ⇒ 读档后商店一片空白，
			#   玩家看到「继续上局 = 商店没了」（真机实报）。
			#   ⛔ 别改成「读档后 roll_shop()」—— 那会把玩家存盘时那批货换掉。
			hud.set_shop_offers(run.offers)
			hud.append_log({"time": 0.0, "category": &"system",
					"text": "继续上一局：节点 %d／%d · %s"
					% [run.node_index, EveNodeTable.TOTAL, run.stage_label()]})
			begin_prep()
			return
	# 读档没成功也把标志清掉（别每局都试一次），但难度选择要保留
	RUN_STORE.resume_requested = false
	# ★ 主菜单选的难度档（默认「简单」）；存档恢复走上面的分支，不看这里。
	if RUN_STORE.pending_difficulty != "":
		run.difficulty_id = String(TIERS.difficulty(
				RUN_STORE.pending_difficulty).get("id", "simple"))
		RUN_STORE.pending_difficulty = ""
	run.start_run()
	# [versus] build the room only when the menu asked for it.
	# After start_run(): each AI needs its own independent run.
	if int(RUN_STORE.pending_versus_ai) > 0:
		_setup_versus(int(RUN_STORE.pending_versus_ai))
	elif String(RUN_STORE.pending_versus_role) != "":
		# ★ 2026-10-27：从联机大厅进来的真人局。
		#  ⚠️ 目前**远端玩家还是由 AI 顶替**（回合同步层未接完）：
		#     大厅握手、座位、开始信号都是真的 TCP；但对手的编制/操作
		#     还没从网络同步过来。这里先把「人数」对上，跑通整条回合流程。
		# ★ 按房间座位表建局：ai 位 = 电脑补位，其余（真人位）当前也暂由 AI 顶替
		#   （远端编制同步未接完）。
		var slots: Array = RUN_STORE.pending_versus_slots
		var ai_n := 0
		for sl in slots:
			if String((sl as Dictionary).get("kind", "")) == "ai":
				ai_n += 1
		if ai_n <= 0:
			ai_n = maxi(1, int(RUN_STORE.pending_versus_seats) - 1)
		print("[versus] 房间座位 %d 个，其中电脑 %d 个（role=%s）"
				% [slots.size() if not slots.is_empty() else 0, ai_n,
				String(RUN_STORE.pending_versus_role)])
		# ★ 按**座位表**建局，不是按 AI 个数。
		#   远端真人也必须是玩家表里的一员，否则 PvP 永远轮不到和他打
		#   （配对只在玩家表内部做）。座位下标 == 玩家下标，两台机器才对得上。
		# ★★ 隧道路径用**固定座位表**：房主 0 / 加入方 1 / 电脑 2,3。
		#   为什么固定：大厅在隧道模式下没有房间通道（房间握手要等 ENet 起来），
		#   而建局必须在进战场时立刻完成 ⇒ 双方先约定同一张表。
		#   ⚠️ 因此隧道模式目前是「1 PC 房主 + 1 手机加入 + 2 电脑」，
		#      要支持多真人再加入方座位号协商。
		var my_seat := int(RUN_STORE.pending_versus_my_seat)
		if bool(RUN_STORE.pending_versus_tunnel) or bool(RUN_STORE.pending_versus_relay):
			slots = [
				{"kind": "human", "name": "房主"}, {"kind": "human", "name": "玩家 2"},
				{"kind": "ai", "name": "电脑 3"}, {"kind": "ai", "name": "电脑 4"},
			]
			my_seat = 0 if String(RUN_STORE.pending_versus_role) == "host" else 1
			RUN_STORE.pending_versus_my_seat = my_seat
			print("[versus] 隧道路径：固定座位表（我 = %d）" % my_seat)
		_setup_versus_by_slots(slots, my_seat)
		_versus_online_setup()
	RUN_STORE.pending_versus_role = ""
	RUN_STORE.pending_versus_ai = 0
	# ★ 2026-10-28 房主权威：联机进战场后**不自己开第 1 回合** ——
	#   房主等对端连上（或宽限到点）后广播 START；加入方收到 START 才开。
	#   单机 `_vawait_start` 恒 false ⇒ 走原来的 `begin_prep()`，行为不变。
	if _vawait_start:
		_begin_versus_wait()
	else:
		_open_run_or_ask_novice()


## ★ 2026-11-07（玩家反馈 · 用户定案）：正式进入任务关卡时问一次「新手模式」。
##
## 新手模式做什么（唯一真源 = `EveRunState.novice_mode` 的注释）：
##   准备阶段不读秒、不自动开战、不会因为"没布阵"判负；
##   战斗阶段不判超时，只有一方被打光才结束；
##   结算页本来就要玩家点「继续」，天然不限时。
##
## ⚠️ 只在**真实会话**问（`RUN_STORE.session_active`）：40 多个探针 / 自检
##    直接加载本场景，弹一个模态框会把它们整条流程卡死在第一帧。
## ⚠️ 联机（`versus != null`）不问：那边整套回合时钟由 `EveMatchState.ROUND_TIME`
##    驱动，关掉倒计时房间就永远不推进。
## ⚠️ 问过就不再问（`_novice_asked`）：局内重开沿用上一局的选择。
func _open_run_or_ask_novice() -> void:
	if _novice_asked or versus != null or not RUN_STORE.session_active:
		begin_prep()
		return
	_novice_asked = true
	if _novice_ask == null:
		_novice_ask = EveConfirmDialog.new()
		_novice_ask.name = "NoviceAsk"
		# ⚠️ 文案自带 `\n` 且每行都短：`EveConfirmDialog` 的文案行**不开 autowrap**
		#    （原因见那个文件的顶注 ③：autowrap 在容器里会把最小宽度塌成一个字）。
		_novice_ask.setup(
				"新手模式",
				"这一局要开新手模式吗？\n"
				+ "开：取消所有倒计时，你决定何时开战\n"
				+ "不开：按标准节奏（准备 30 秒 · 交战有时限）",
				"开启新手模式", "标准节奏")
		_novice_ask.confirmed.connect(_on_novice_chosen.bind(true))
		_novice_ask.cancelled.connect(_on_novice_chosen.bind(false))
		# ⚠️ 必须挂在 **HUD 根**（一个铺满视口的 Control）上，⛔ 不是场景根：
		#    本场景根是 Node3D，Control 挂上去不参与 2D 布局（弹框会不可见）。
		hud.add_child(_novice_ask)
	# ⚠️ 等一帧再开：弹框按「铺满父级 + 居中」摆放，而 HUD 的尺寸是首帧排版
	#    之后才定的 —— 同一帧 open 会按 0×0 居中，弹框跑到左上角。
	await get_tree().process_frame
	# ⚠️⚠️ 弹框期间顶条必须**先归零**：`CommandBar.time_left` 的默认值是 24 秒，
	#    以前由 `begin_prep()` 立刻覆盖掉；现在开局被弹框挡了一下，那 24 秒会
	#    照常走完并触发 `stage_timer_expired` ⇒ 玩家还在读弹框，`run.field` 是空的
	#    ⇒ `forfeit_no_deploy()` 直接判负。这一行 + `_process` 里那条早退，
	#    两道都要（只靠这一行的话，别的路径把时间设回去就又漏了）。
	hud.set_stage(run.node_index, run.stage_label(), 0.0)
	_novice_ask.open_dialog()


## 弹框的出口（两个按钮都走这里）。
func _on_novice_chosen(on: bool) -> void:
	if run != null:
		run.novice_mode = on
	hud.append_log({"time": 0.0, "category": &"system",
			"text": "新手模式：%s" % ("开启 —— 全程不限时，你说了算"
					if on else "关闭 —— 标准节奏（准备 30 秒 / 交战有时限）")})
	begin_prep()


## 本局是否「全程不限时」。
##
## ⚠️ 联机再挡一次：`novice_mode` 在联机入口不会被置真（弹框根本不弹），
##    这里把「万一存档串味」也关死 —— 联机关掉倒计时 = 房间永远停滞。
func _untimed() -> bool:
	return run != null and run.novice_mode and versus == null


# ══════════════════════════════════════════════════════════════════
#  阶段一：准备
# ══════════════════════════════════════════════════════════════════

## Web 试玩版：开局送 3 艘船并直接摆上棋盘（**只在网页包、只发一次**）。
##
## [WHY] 网页试玩没有新手引导。玩家抓开页面看到空棋盘、空备战席，
##       点「开战」只会得到一句「场上一艘船都没有」，然后关掉页面。
##       送一支能直接开打的最小舰队，「打开网页 → 半分钟内看见战斗」才成立。
## [NOTE] 判据是 `web` 功能标签 ⇒ 桌面 / 安卓照旧从零开始，数值平衡一点不动。
## [PITFALL] 必须落在 `begin_prep()` 里 `_build_own_fleet()` **之前** ——
##       舰队是每回合从 `run.field` 现搭的，晚一步这一回合仍然是空的。
func _seed_web_starter_fleet() -> void:
	if _web_starter_done or not OS.has_feature("web"):
		return
	_web_starter_done = true
	if run == null or not run.field.is_empty():
		return
	# 兜底补星币到能买 3 艘 1 费船。⛔ 不多送：星币是玩法资源，白给会毁掉前几回合的决策。
	run.coin = maxi(run.coin, 6)
	# 我方部署区 = 棋盘下 4 行（`EveRunState._cell_ok`：row 7..10）。
	# 取第 9 行三格，站位正对敌方，开战运镜里也在画面内。
	var cells: Array[Vector2i] = [Vector2i(9, 3), Vector2i(9, 5), Vector2i(9, 7)]
	var placed := 0
	for i in run.offers.size():
		if placed >= cells.size():
			break
		var offer = run.offers[i]
		if offer == null or not (offer is Dictionary) or (offer as Dictionary).is_empty():
			continue
		if not bool(run.buy(i).get("ok", false)):
			continue
		# `buy()` 把船塞进备战席末尾，紧接着就上阵。
		var r := run.deploy_from_bench(run.bench.size() - 1, cells[placed].x, cells[placed].y)
		if bool(r.get("ok", false)):
			placed += 1
	print("[web] 初始舰队已上阵 %d 艘（星币 %d）" % [placed, run.coin])


## 进入准备阶段：清场 → 造双方舰队 → 摆位 → 刷 HUD → 起倒计时
##
## ⚠️ 这里【不建模拟器】。准备阶段不该有战斗推进 ——
##    舰队只是站在那里，等玩家说「开打」。
func begin_prep() -> void:
	# [versus] AI players take their prep turn first.
	# One round = one call; the auto-start countdown path is covered too.
	if versus != null:
		_run_ai_prep_turns()
		_refresh_versus_hud()
		versus.round_elapsed = 0.0   # fresh clock every round
		# ★★ 2026-10-28 用户：「这个事件…同时适用于联机对战，适用于所有事件回合」。
		#
		#  联机的事件回合 = `RoundKind.CAROUSEL`（每阶段第 4 回合，云顶选秀位），
		#  ⛔ 不是 `EveNodeTable` 的 4/10/14 —— 联机跑的是另一套 17 回合表，
		#  `run.node_index` 在联机里根本不推进。两套都走同一张 `EveEventTable`，
		#  所以新事件在单机 / 联机自动都能抽到，不需要第二份数据。
		#
		#  ⚠️ 同一回合只弹一次：选完会重入本函数建队，`_v_event_round` 记着
		#     已经处理过的回合号 ⇒ 不会反复弹面板。
		#  ⚠️ 折扣计时用 `set_event_clock(global_round())` 写真实回合号
		#     （见 `EveRunState.event_clock()` 的说明）。
		run.set_event_clock(versus.global_round())
		var gr := versus.global_round()
		if versus.round_kind() == EveMatchState.RoundKind.CAROUSEL and _v_event_round != gr:
			_v_event_round = gr
			_prep_phase.versus_event = true
			# 事件面板不要压在棋盘上（2026-11-07：棋盘改为准备阶段常驻，
			# 不主动收会在事件 UI 后面亮着）。
			arena.hide_board()
			_prep_phase.enter_event_node()
			return
		_prep_phase.versus_event = false
	# match over? then rank and stop driving rounds
	# 事件节点（4 / 10 / 14）：没有战斗，进来就开面板。
	#
	# ⚠️ 放在函数**最前面**分派，而不是在后面加一个 if：
	#    事件节点没有敌方编组，一旦先跑了建队那一段，
	#    compute_deploy_z(我方, []) 就要拿到一支空舰队去算接敌距离。
	#    分派在最前面 = 那一段永远不会被事件节点走到。
	if run.phase != EveRunState.Phase.ENDING and EveNodeTable.is_event(run.node_index):
		# 同上：棋盘常驻后，事件节点必须显式收起。
		arena.hide_board()
		_prep_phase.enter_event_node()
		return

	_busy = true
	# ★ 2026-10-30：新一回合的舰船 id 会重排 ⇒ 上一回合的「盾/甲是否还在」作废。
	#   不清的话，新船 id 若撞上旧 id，第一发就会被误判成「破盾」。
	_layer_seen.clear()
	run.set_phase(EveRunState.Phase.PREP)
	hud.set_phase(0)
	hud.set_selling(false)
	hud.set_bench_drag(-1)
	_resolve_timer = -1.0
	# 阶段 D：进准备阶段 = 上一场彻底翻篇。结算页收起、残留的爆炸/飘字清掉。
	# ⚠️ 不清的话，上一场最后一秒的爆炸会飘在下一轮的布阵台上（残留 0.75 秒）。
	hud.hide_result()
	hud.clear_damage()
	arena.fx_clear()

	arena.clear_ships()
	_seed_web_starter_fleet()
	_own_ships = _build_own_fleet()
	_enemy_ships = _build_enemy_fleet()

	# 部署带按双方实际射程自动计算 —— 保证开局接敌距离落在武器射程附近。
	# 这是战斗能收敛的前提（详见 EveBattleArena.compute_deploy_z 的说明）。
	var dz := arena.compute_deploy_z(_own_ships, _enemy_ships)
	arena.deploy_own_z = float(dz[0])
	arena.deploy_enemy_z = float(dz[1])
	# 棋盘对齐到本节点的接敌线（细节与「棋盘不是等比地图」这个事实见
	# EveBattleArena.align_board_to_line 的说明）
	arena.align_board_to_line(arena.deploy_own_z)

	# ★★ 2026-11-07（玩家反馈「准备的时候视角不变，直接使用棋盘模式」）：
	#    这里原来是 `frame_battlefield()`（斜 3/4 视角看双方舰队），棋盘只在
	#    玩家**拿起船**时才由拖放控制器显形。于是每拖一艘船，镜头就要
	#    41.3° → 75° → 41.3° 翻一次；一回合拖五六艘 = 翻十几次。
	#
	#    现在改成**进准备阶段就进棋盘模式**，整个准备期间镜头不动。
	#    收起棋盘只发生在两个时刻：开战（`start_battle()`）与事件节点。
	#
	# ⚠️ `show_board_for_deploy()` 内部已经做了三件事，别在外面重复：
	#      ① 棋盘显形 ② yaw 对齐棋盘正对位 + 俯角切 BOARD_VIEW_PITCH
	#      ③ `reset_battle_zoom()` 把开战运镜改过的视距还原
	#    ⚠️ 但**不调 `reset_camera()`** —— 玩家自己转过的观察角度仍然保留，
	#       只是 yaw 会被对齐到棋盘（棋盘要正对着看，这是棋盘模式的必然）。
	#
	# ⚠️⚠️ 视距必须还原（2026-09-20 阶段 D 回归的修复，别删）：
	#    开战运镜把视距推近过，不还原的话下一轮布阵时棋盘格投影会整体下移，
	#    格 (8,5) 正好落进商店窗的出售区矩形里 ⇒ 玩家的船「拖到格子上」却**卖掉**。
	#    详见 EveBattleArena.reset_battle_zoom() 的说明。
	#
	# ★ 布阵放大常驻：玩家 2026-11-07 反馈「拖动的时候有放大很好，
	#   但不拖的时候太小」⇒ 放大跟随「棋盘是否可见」，不再跟随「是否在拖」。
	arena.show_board_for_deploy()
	arena.set_ships_board_mode(true)

	_place_fleet(_own_ships, 0)
	_place_fleet(_enemy_ships, 1)
	for ship in _own_ships:
		arena.spawn_ship_visual(ship)
	# ★ 2026-10-01：**敌方视觉不在这里生成**。
	#
	#   用户原话：「我知道云顶之弈打怪回合那些怪会优先出现在战场上，
	#             但这个我还是想像 PVP 回合一点，所以想把流程改为
	#             在玩家点击开战之后才出现。」
	#
	#   ⚠️ 只推迟 **`spawn_ship_visual`** 这一步。数据层照旧：
	#      `_build_enemy_fleet()` 正常建队、`_place_fleet(_enemy_ships, 1)`
	#      也照旧写 `ship.body.position` —— 因为 `compute_deploy_z()` 要靠
	#      敌方射程算接敌距离，这条不变量不能断。
	#      （`arena.snap_ships/_sync_ships` 对没有视觉的船是 null 跳过，安全。）
	_battle_phase.reset_visuals()
	# ★ 53 轮：布阵阶段**必须显式同步一次姿态**（红线 54 配套）。
	#
	# ⚠️ 为什么以前是漏的、以及漏了为什么"看着还行"：
	#   `_process` 的 `PREP` 分支**只走倒计时**（`hud.tick_stage` + `_tick_countdown_sfx`），
	#   **不调 `arena.sync_ships()`** —— 那句话在 `BATTLE` 分支里。
	#   而 `spawn_ship_visual()` → `setup()` 只会：① 由 `_build_hull_model` 定 `model.basis`
	#   ② 把**节点** `position` 设成 `body.position / 1000`。
	#   节点的**旋转（`quaternion`）在 `setup` 里从头到尾没被写过** ⇒ 停在
	#   `Quaternion.IDENTITY`（`_facing_quat` 的初值）。
	#   ⇒ 布阵阶段玩家看到的朝向 = **Identity 姿态**，与 `SHIP_AXES` 毫无关系！
	#     它"看着像朝前"纯属偶然（Identity 恰好接近某些船的正确姿态），
	#     而不同船的正确姿态各不相同 ⇒ **布阵画面里船头乱指**。
	#
	# ⚠️ 敌方那次同步（下方 `sync_ships(_enemy_ships)`）是 47 轮为"部署带变了要重摆位置"
	#    加的，只覆盖敌方；我方**从来没有**在布阵阶段同步过。
	#
	# ⇒ 修法：摆完 + 生成完，**对全舰队同步一次**（我方 + 敌方）。
	#    `delta` 传 `1.0/60.0`（一个标准帧）：布阵态下 `aim_dir` 已由
	#    `_place_fleet` 写死为朝敌，`slerp` 权重 `FACING_LERP=0.12` 会让姿态
	#    **只走到 12%** —— 这是唯一需要在调用点显式处理的事。
	#    见下方 `_snap_fleet_facing()` 的做法与理由。
	_snap_fleet_facing()
	_last_field_sig = _field_signature()
	_last_roster_sig = _roster_signature()

	# HUD
	_refresh_run_ui()
	# ★ 2026-11-07（新手模式）：传 0 ⇒ 顶条**不读秒**，`tick()` 见到
	#   `time_left <= 0` 就原地返回 ⇒ `_on_stage_timer_expired` 永不触发
	#   ⇒ 不会自动开战、也不会因为"场上 0 艘"判负。玩家点「开战」才开打。
	hud.set_stage(run.node_index, run.stage_label(),
			0.0 if _untimed() else PREP_SECONDS)
	# 阶段 C 收尾：节点进场字幕（4.2 秒后自己淡出，见 eve_entry_banner.gd）。
	#
	# ⚠️ 只有战斗类节点弹 —— 事件节点（4/10/14）的进场词已经是事件面板的引导语
	#    （`_enter_event_node` 传给 show_event 的 line 参数），
	#    同一句话同一时刻出现两处会互相打脸。
	hud.show_entry(run.node_index, run.node_type(), run.entry_line())
	hud.set_loss_cost(run.loss_preview())
	hud.set_fleet(_own_ships)
	_refresh_barrier_ui()
	# ★ 联机事件回合没有战斗 ⇒ 按钮换成「进入下一回合」（直接推进，不开打）。
	if versus != null and versus.round_kind() == EveMatchState.RoundKind.CAROUSEL:
		hud.set_start_button(T.t("PREP_NEXT_ROUND", "▶ 进入下一回合"), true)
	else:
		hud.set_start_button("✦ 开战", true)
	_log_synergies()

	hud.append_log({
		"time": 0.0, "category": &"system",
		"text": "节点 %d／%d · %s · 敌方「%s」%d 艘 · %s" % [
			run.node_index, EveNodeTable.TOTAL, run.stage_label(),
			run.enemy_comp_name(), run.enemy_comp_size(),
			"不限时" if _untimed() else "时限 %ds" % int(run.battle_seconds()),
		],
	})
	hud.append_log({
		"time": 0.1, "category": &"hint",
		"text": run.current_node().get("line", ""),
	})
	_restore_dossier(hud.get_selected_ship())
	_busy = false
	# ★ 2026-10-10（审查 2#2）：**每次进入新的准备阶段前存一次对局**。
	#   选这个时机是因为它正是「一个节点结束了、下一个节点刚开始」——
	#   存档里不会停在"战斗打到一半"这种没法恢复的中间态。
	#   ⚠️ 只有真实会话才写盘（`EveRunStore._write_allowed()`）：
	#      40 多个 probe/verify 直接加载本场景，不设闸就会把玩家的一局覆盖掉。
	_save_run_progress()


## 把当前这一局写进对局存档（`EveRunStore` 自己判断该不该写）。
func _save_run_progress() -> void:
	if run == null:
		return
	RUN_STORE.save_run(run.to_dict())


## 上场名单指纹（船 id + 星级 + 棋盘格）。
##
## ⚠️ 一定要带格号：阶段 B 之后「把一艘船挪到另一格」不改变名单，
##    但舰队必须重建（船要出现在新格子里）。只比 id:star 的话，
##    拖放会「编制变了、船没动」，玩家立刻发现。
func _field_signature() -> String:
	var parts := PackedStringArray()
	for e in run.field_entries():
		var c = e.get("cell", Vector2i(-1, -1))
		var cs := "auto"
		if c is Vector2i and c.x >= 0:
			cs = "%d.%d" % [c.x, c.y]
		parts.append("%s:%d@%s" % [String(e.get("ship_key", "")), int(e.get("star", 1)), cs])
	return ",".join(parts)


## 只有名单（不含格号）的指纹 —— 用来决定「要不要打那一行上场日志」。
## 拖一次就打一次「上场 5／5 艘」是纯噪音。
func _roster_signature() -> String:
	var parts := PackedStringArray()
	for e in run.field_entries():
		parts.append("%s:%d" % [String(e.get("ship_key", "")), int(e.get("star", 1))])
	return ",".join(parts)


## 准备阶段买到新船 / 三连合成 / 拖放调位 → 我方舰队重建。
##
## ⚠️ 这条链必须存在，否则「买船」只是一个让星币变少的按钮 ——
##    买到的东西不出现在战场上，玩家五分钟内就会发现这是个假系统。
##    重建范围刻意只到「我方 + 重新摆位」：
##    敌方不重建（他们的数值与玩家的购买无关），只跟着新的部署带挪个位置。
func _respawn_own_fleet() -> void:
	# ★ 2026-10-30（玩家反馈「档案只显示乱跳的那一艘，不是点中的」）：
	#   重建前记下「玩家正在看哪一艘（型号 + 星级）」。
	#   ⚠️ 不能记实例：`_build_own_fleet()` **每次全新造实例**，旧引用一定不在
	#      新数组里（按实例匹配 = 永远匹配不上 = 白记）。
	#   ⚠️ 也不能不记就保留：卖船 / 换阵容时被选中的那艘会从场上消失，
	#      档案还挂着它 ⇒ 显示一艘不存在的船（血量还是满的，看着像正常）。
	var prev: EveShip = hud.get_selected_ship() if hud != null else null
	for s in _own_ships:
		arena.remove_ship_visual(s.id)

	_own_ships = _build_own_fleet()
	_last_field_sig = _field_signature()

	var dz := arena.compute_deploy_z(_own_ships, _enemy_ships)
	arena.deploy_own_z = float(dz[0])
	arena.deploy_enemy_z = float(dz[1])
	arena.align_board_to_line(arena.deploy_own_z)
	_place_fleet(_own_ships, 0)
	_place_fleet(_enemy_ships, 1)
	for ship in _own_ships:
		arena.spawn_ship_visual(ship)
	# 敌方的位置也变了（部署带跟着玩家舰队的射程中位数走），
	# 让它们的可视节点从 body 重新同步一次
	arena.sync_ships(_enemy_ships)
	# ★ 53 轮：我方新生成的节点**必须补一次瞬时姿态**（红线 54）。
	#   `spawn_ship_visual` → `setup()` 不设 rotation ⇒ 新买的船会是 Identity 姿态
	#   （= 朝向乱）。布阵期 `_process` 不跑 `sync_ships` ⇒ 不补就一直是错的。
	#   ⚠️ 这里覆盖全舰队（不只新船）：反正只是赋值，且能纠正任何残留。
	_snap_fleet_facing()

	hud.set_fleet(_own_ships)
	hud.set_loss_cost(run.loss_preview())
	_refresh_barrier_ui()
	_log_synergies()
	if _roster_signature() != _last_roster_sig:
		_last_roster_sig = _roster_signature()
		hud.append_log({
			"time": 0.0, "category": &"deploy",
			"text": "上场 %d／%d 艘：%s" % [
				_own_ships.size(), run.field_limit(),
				", ".join(FLEET_FACTORY.names_of(_own_ships)),
			],
		})
	_restore_dossier(prev)


## 给拖放控制器现取「会被重新赋值」的两个数组（见 `_deploy.setup` 的注释）。
func _get_own_ships() -> Array[EveShip]:
	return _own_ships


func _get_own_field_index() -> Array[int]:
	return _own_field_index


## 把右上档案窗落回「玩家正在看的那一艘」；它已不在场上才退回第 1 艘。
##
## ★ 2026-10-30（玩家反馈：「准备阶段点击舰船，档案不会跟着换，只会显示
##   战斗中最后点的那一个」）—— 这条反馈有**两个**成因，一个是拖放吃掉了
##   点击（见 `EveDeployController.TAP_SLOP`），另一个就是这里：
##   `_respawn_own_fleet()` 与 `begin_prep()` 都无条件 `show_ship(_own_ships[0])`，
##   于是玩家每买一张牌 / 每进一个回合，档案就自己翻回第 1 艘。
##
## ⚠️ 匹配用「型号 + 星级」而**不是实例**：舰队每次重建都是全新实例
##    （`_build_own_fleet()`），按实例比一定匹配不上。
## ⚠️ `prev` 为 null（从没选过）⇒ 落第 1 艘，保证档案不空着。
func _restore_dossier(prev: EveShip) -> void:
	if hud == null or _own_ships.is_empty():
		return
	var pick: EveShip = _own_ships[0]
	if prev != null:
		for s in _own_ships:
			if String(s.ship_key) == String(prev.ship_key) and s.star == prev.star:
				pick = s
				break
	hud.show_ship(pick)


## 给结算阶段模块现取模拟器（它在开战时才建、重开时置空）。
func _get_sim():
	return sim


## 给战斗阶段模块现取敌方舰队（每次重建都会换数组）。
func _get_enemy_ships() -> Array[EveShip]:
	return _enemy_ships


## 给准备阶段模块：清空战场 + 三个指纹归零（进事件节点时用）。
func _clear_field() -> void:
	arena.clear_ships()
	_own_ships.clear()
	_enemy_ships.clear()
	_last_field_sig = ""
	_last_roster_sig = ""


## 给结算阶段模块现取「我方存活 / 总数」（结算 payload 要这两个数）。
func _own_stats() -> Dictionary:
	return {"alive": _alive_count(0), "total": _own_ships.size()}


## 玩家舰队 = 上场名单
##
## ⚠️ 装配逻辑已搬到 `EveFleetFactory.build_own`（纯数据 → 实例，与场景树无关）。
##    这里只补一件本场景才知道的事：把「上场下标映射」抄进 `_own_field_index`
##    （拖放要用）。数值叠加顺序的说明见装配器顶注。
func _build_own_fleet() -> Array[EveShip]:
	var out := _fleet.build_own(run)
	_own_field_index = _fleet.last_idx_map
	return out


## 把本节点生效的羁绊写进日志（只在档位组合变化时打，免得变成噪音）
func _log_synergies() -> void:
	if run == null:
		return
	var act := run.active_synergies()
	var parts := PackedStringArray()
	for a in act:
		parts.append("%s=%d" % [String(a["member"]), int(a["n"])])
	var sig := ",".join(parts)
	if sig == _last_synergy_sig:
		return
	_last_synergy_sig = sig
	for a in act:
		var line := "羁绊生效：%s %d／%d —— %s" % [
				String(a["member"]), int(a["n"]),
				EveTraitTable.max_tier(a["group"]), String(a["text"])]
		var pending: PackedStringArray = a.get("pending", PackedStringArray())
		if not pending.is_empty():
			# ⚠️ 未实装的特殊机制必须写出来。让玩家以为「凑齐就有效果」比不生效更糟。
			line += "（特殊机制未实装：%s）" % ", ".join(pending)
		hud.append_log({"time": 0.0, "category": &"economy", "text": line})


## 敌方舰队 = 节点表指定的编组（EveEnemyComps）
##
## ⚠️ 装配逻辑在 `EveFleetFactory.build_enemy`（与玩家那条链共用 id 计数器）。
## 敌方舰队。联机模式下 PvP 回合用**对手送来的编制**造船。
func _build_enemy_fleet() -> Array[EveShip]:
	if versus == null:
		return _fleet.build_enemy(run)
	var kind := versus.round_kind()
	if kind == EveMatchState.RoundKind.PVP:
		var opp: int = versus.human_opponent()
		if opp < 0:
			return [] as Array[EveShip]
		# ★ 真联机：对手是真人时，他的编制是网络送来的（本地没有他的 run）。
		var remote := _versus_remote_entries(opp)
		if not remote.is_empty():
			print("[versus-net] PvP 用网络编制 seat=%d n=%d" % [opp, remote.size()])
			return _fleet.build_from_entries(remote, 1)
		var pr = versus.players[opp]
		if pr == null or pr.run == null:
			return [] as Array[EveShip]
		return _fleet.build_own(pr.run, 1)
	var src: int = versus.pve_source_node()
	if src > 0:
		run.comp_source_node = src
	return _fleet.build_enemy(run)


## ★ 53 轮：布阵阶段的**瞬时姿态快照**（红线 54）。
##
## ── 为什么必须存在 ────────────────────────────────────────────────
##  ① **布阵阶段没有每帧姿态同步**：`_process` 的 `PREP` 分支只走倒计时
##     （`hud.tick_stage` + `_tick_countdown_sfx`），`arena.sync_ships()` 在
##     `BATTLE` 分支里 ⇒ 布阵期视觉节点**一次都不会被同步姿态**。
##  ② `spawn_ship_visual()` → `setup()` **只设 position，不设 rotation**
##     ⇒ 节点 `quaternion` 停在 `Quaternion.IDENTITY`。
##  ③ 于是布阵画面里的朝向 = **Identity 姿态**，与 `SHIP_AXES` 无关
##     —— 这正是「摆到战斗区时朝向乱」的真根因。
##
## ── 为什么是 `snap_ships` 而不是 `sync_ships` ─────────────────────
##  `sync_ships` 走 `slerp(want, FACING_LERP=0.12)`，**单次只走 12%**。
##  布阵期只同步一次 ⇒ 12% ≈ 看着没转。必须用瞬时版
##  （`EveShipVisual.snap_facing()`，姿态算式与 `sync_from_body` 同源，只是不做插值）。
##
## ⚠️ 与下方敌方那次 `sync_ships(_enemy_ships)` 的关系：
##    那次是 47 轮为「部署带变了要重摆**位置**」加的，**只覆盖敌方**、
##    且走平滑版（位置是直接赋值、不受 slerp 影响 ⇒ 位置正确；姿态则只走 12%）。
##    现在由本函数统一接管**姿态**；敌方那次保留（它管位置，职责不重叠）。
func _snap_fleet_facing() -> void:
	arena.snap_ships(_own_ships)
	arena.snap_ships(_enemy_ships)


## 摆放舰队（己方 z 正、敌方 z 负）
##
## ⚠️ 位置有【两个来源】，优先级明确：
##    ① 玩家摆过的船（entry 里有 cell）→ 棋盘格 → 世界坐标（arena.board_cell_to_meters）。
##       这是阶段 B 的拖放部署；玩家说什么就是什么。
##    ② 其余（敌方全部、我方的空位）→ arena.default_formation() 的通用阵列。
##    本文件不自己算 x/z：站位算法只有 arena 一份真相源（路线文档 §3①）。
##
## ★★ 53 轮：**布阵阶段一律显式朝敌方**（用户裁决，红线 54）★★
##
## ── 用户原话（53 轮）─────────────────────────────────────────────
##   「在初始状态下，肯定是一律朝着正前方啊，但我怕的是又是把**朝着玩家操作
##     方向**当做是朝前，这就相当尴尬了。」
##   「'正前方' 是相机看向的方向……敌人是离我越来越近的，我是朝着 −Z 看。」
##   「初始状态，就是我把舰船摆到战斗区的时候的状态。」
##
## ── 定案口径（无歧义版）─────────────────────────────────────────
##   · 「正前方」= **世界 −Z**（= 我方相机看出去的方向 = 敌人阵地）。
##     理由：棋盘局部轴与世界轴同向（`eve_board.row_z0()` 的 row 0 在 −Z），
##     相机 `yaw≈0` 时 `cos(0)=1` ⇒ 相机架在 **+Z 侧**朝 −Z 看 ⇒ 画面上方 = −Z。
##     ⚠️ 判据是「**绝对世界方向**」，与玩家操作 / 拖放 / 镜头转动**完全无关**
##     —— 这正是用户担心的那个坑，这里用"写死常量"从源头堵掉。
##   · 「初始状态」= **布阵 / 准备阶段**（船刚被摆到战斗区、还没开打）。
##   · 开打之后：`aim_dir` 改由 `_refresh_targets()` 每 tick 写「朝锁定目标」，
##     **不再**由本函数决定（本函数的结果会被第一 tick 覆盖）。
##
## ── 为什么必须写 `aim_dir` 而**不是**像以前那样只写 `velocity` ──────
##   ⚠️⚠️ 旧写法（53 轮前）：
##       `ship.body.velocity = facing_dir * max_speed * 0.15`   # 注释写"初始朝向"
##   **这是"意图与实现错位"的典型**：
##     · `velocity` 是**速度**，不是朝向；布阵阶段 `aim_dir == 0`
##       ⇒ `sync_from_body` 走**兜底分支** `f = v̂`
##       ⇒ 朝向**碰巧**对（因为 velocity 恰好指敌方），但这是**巧合不是契约**；
##     · 更糟的是 `velocity` 会被**战斗积分衰减**（`integrate_body` 的阻尼项）：
##       一旦衰减到 `MOVE_EPS` 以下，`f` 变零向量 ⇒ `_has_align` 整段跳过
##       ⇒ 该船的旋转**永远停在 `setup` 时的初始姿态**（不报错，只是"这船不转身"）。
##   ⇒ 正确做法 = **显式写 `aim_dir`**（走"有目标"那条确定分支），
##     与开打后的语义**同构**：`aim_dir` 就是「舰艏该朝哪」的唯一通道。
##     这样布阵态与战斗态**只有一处差异**（谁写 `aim_dir`），姿态链完全复用。
##
##   ⚠️ `velocity` 那行**保留**（原语义不变）：它是船的初始动量，
##     0.15 倍是"开战瞬间有个起步感"的观感调参，与朝向无关。
##     **别把朝向的职责塞回 velocity**（那就是旧写法的病根）。
func _place_fleet(fleet: Array[EveShip], team: int) -> void:
	# ★ 2026-10-27：敌方站位模板改由「编组自带 + 难度开关」共同决定。
	#   难度档 `enemy_formation = true`（普通 / 困难 / 炼狱）时，读当前编组的
	#   `formation`（普通档的编组来自 `EveEnemyPlans` 程序化配方，含 N9 的
	#   `STANDOFF`「保持距离」）；`false`（简单档）时传空 = 沿用通用阵列。
	#   ⛔ 别把这里退回「只有困难 / 炼狱才按阵型」—— 用户 2026-10-27 明确要
	#      N9 在**普通档**就站在隔离带后方两格。
	var formation := ""
	if team == 1 and bool(run.enemy_tier_row().get("enemy_formation", false)):
		formation = String(EveEnemyComps.by_id(run.enemy_comp_id()).get("formation", ""))
	var positions := arena.default_formation(fleet.size(), team, formation)
	# ⚠️ 这里必须显式标 Array，不能写 `var entries := ...`：
	#    `:=` 会按第一个分支把类型推断成 Array[Dictionary]，
	#    而 team == 1 时表达式给的是裸 []（Array）→ 运行时报
	#    「Trying to assign an array of type Array to Array[Dictionary]」，
	#    而且只在对局里跑起来才炸，静态检查看不出来。
	var entries: Array = run.field_entries() if team == 0 else []
	# 己方朝 −Z（敌方阵地），敌方朝 +Z（我方阵地）——绝对世界方向，与操作无关。
	var facing_dir := Vector3(0, 0, -1.0 if team == 0 else 1.0)
	for i in fleet.size():
		var ship := fleet[i]
		var pos: Vector3 = positions[i] if i < positions.size() else Vector3.ZERO
		if team == 0 and i < entries.size():
			var c = entries[i].get("cell", Vector2i(-1, -1))
			if c is Vector2i and c.x >= 0:
				pos = arena.board_cell_to_meters(c.x, c.y)
		ship.body.position = pos
		ship.body.previous_position = pos
		# ★ 53 轮：**朝向走 `aim_dir`**（唯一通道，与战斗态同构）。
		#   拍平到水平面（XZ）—— 与 `_refresh_targets()` 的写入口径**完全一致**
		#   （红线 46：`aim_dir` 必须是水平单位向量），布阵态与战斗态因此无缝衔接。
		ship.body.aim_dir = Vector3(facing_dir.x, 0.0, facing_dir.z).normalized()
		# 初始动量（观感：开战瞬间有个起步感）—— 与朝向无关，别混用。
		ship.body.velocity = facing_dir * ship.body.max_speed * 0.15


# ══════════════════════════════════════════════════════════════════
#  阶段二：战斗
# ══════════════════════════════════════════════════════════════════

## 准备结束 → 锁定操作 → 开打
## 准备结束 → 锁定操作 → 开打。
##
## ★ 2026-10-10（2⑦ 状态机三拆）：主体搬进 `eve_phase_battle.start()`，
##   它**返回**新建的模拟器。⚠️ 只有真的开打才覆盖 `sim` —— 空手上阵 / 非准备阶段
##   那两条早退路径返回 null，此时⛔ 不能把 `sim` 冲成 null（原来也不会）。
## [versus] keep AI economies in step when the human starts early.
##
## The round clock is shared, so starting early is allowed, but the AI
## runs must still earn gold / xp / wrecks for the round they just played.
func _versus_settle_ai_economy() -> void:
	if versus == null:
		return
	var kind := versus.round_kind()
	if kind == EveMatchState.RoundKind.CAROUSEL:
		return
	for q in versus.players:
		if q == null or not q.is_ai or q.run == null:
			continue
		if not q.is_alive():
			continue
		# settle with a draw-ish outcome: no beacon change here (the match
		# layer owns HP), this only advances their economy.
		if q.run.phase == EveRunState.Phase.PREP:
			# ⚠️ 第 5 个参数是 `Array[int]`（本场丢掉的船上场下标）。
			#    直接写字面量 `[]` 是**无类型 Array** ⇒ 运行时报
			#    「Array 与 Array[int] 元素类型不同」并中断这一帧的调用。
			#    它挂在 `start_battle()` 的最前面，所以表现是「倒计时一归零就报错」。
			var lost_field: Array[int] = []
			q.run.resolve_battle(0, [], [], 1.0, lost_field)
			q.run.advance()


func start_battle() -> void:
	# ★ 2026-10-28 联机事件回合：没有战斗 ⇒ 这个按钮 = 「进入下一回合」。
	#   权威（单机 / 房主）才推进；加入方点了也只会等房主的 ROUND 广播。
	if versus != null and versus.round_kind() == EveMatchState.RoundKind.CAROUSEL:
		if _versus_is_authority():
			_versus_advance_round()
		return
	# [versus] human started early -> AI still needs its economy
	_versus_settle_ai_economy()
	# [versus] 开打这一刻把本回合编制发出去（对手要拿它造船）
	_versus_broadcast_fleet()
	# ★ 真联机 PvP：**开打前**用对手送来的编制重建敌方舰队。
	#   为什么必须在这里：`begin_prep()` 是准备阶段**开始**就建队的，
	#   那一刻对手本回合的编制还没发过来（他要等准备阶段中途才发），
	#   于是只能先按本地 AI 占位 —— 到开打时再换成真的。
	_versus_rebuild_enemy_if_remote()
	# ★ 2026-11-07：棋盘改为准备阶段常驻 ⇒ **开战这一刻**是它该收起的地方。
	#   `hide_board()` 内部会一并做三件事（都必要）：
	#     ① 棋盘隐藏 ② 俯角回 DEFAULT_PITCH ③ **视距还回 DEFAULT_ZOOM**
	#   ⚠️ ③ 尤其别漏：不还的话下一轮布阵格 (8,5) 会落进商店出售区，
	#      船「拖到格子上」却卖掉。见 EveBattleArena.hide_board() 的说明。
	#   ⚠️ 必须在 `_battle_phase.start()` **之前** —— 开战运镜的起点取景
	#      是按"棋盘已收起"算的，顺序反了镜头会从布阵取景起飞。
	arena.hide_board()
	var s := _battle_phase.start()
	if s != null:
		sim = s


#  阶段三：结算
# ══════════════════════════════════════════════════════════════════

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
##    （判据 `damage_multiplier() > 1.0` 与「倒计时归零」根本不是同一件事，
##      2026-10-01 写这行时把两者混为一谈了。）
##
## ⚠️ 抽成独立方法不为好看：verify_run 要直接调它，断言「调完之后
##    顶条的 time_left 一个字都没变」—— 内联在 _process 里就测不到了。
func _check_sudden_death() -> void:
	_battle_phase.check_sudden_death()





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
static func battle_end_reason(own_empty: bool, enemy_alive: int, own_alive: int,
		timed_out: bool = false) -> String:
	# ★ 2026-10-10（2⑦）：判定表搬进 `eve_phase_battle.end_reason()`（同为静态）。
	#   ⚠️ 本函数是**对外契约**（`verify_run` 直接 `BATTLE_SCRIPT.battle_end_reason(...)`），
	#      ⛔ 不许删 / 改名。
	return PHASE_BATTLE.end_reason(own_empty, enemy_alive, own_alive, timed_out)





## `sim.battle_finished` 的处理器 —— 已搬进 `eve_phase_battle.finished()`（含打捞证据、
## 结束原因、扣血、结算音、交给结算模块的 `arm_result`）。
##
## ⛔ 主控的 `sim.battle_finished` 现在直接连到 `_battle_phase.finished`（见 `_ready`）。


## 结算 payload 的组装 / 结算页两个出口 / 节点推进 —— 都搬进
## `eve_phase_resolve.gd` 了（见其顶注）。主控只留 `battle_end_reason()`（静态契约）
## 与 `_round_music()`（HUD 阶段同步）。
##
## ⚠️ 4 个状态字段（两个计时器 + pending/payload）也住那边，本文件用**透传属性**暴露。


## ⚠️ 下面两个是**对外契约的薄委托**：验收脚本仍按老名字
##    `_battle.call("_popup_result")` / `call("_on_result_next")` 调它们
##    （2026-10-10 拆模块时**漏了这两个名字**，被 `verify_run` 当场抓出来）。
##    ⛔ 别删、别改名 —— 改名 = 那几条断言变成「调用不存在的方法」。
func _popup_result() -> void:
	_resolve_phase.popup()


func _on_result_next() -> void:
	_resolve_phase.on_result_next()


# ══════════════════════════════════════════════════════════════
#  阶段 C：事件节点（4 / 10 / 14）四选一 —— 已搬到 `scene/eve_phase_prep.gd`
# ══════════════════════════════════════════════════════════════
#
# ⚠️ 整个事件流（进节点 → 四选一 ⇄ 选 1 艘船 → 落地 → 推进）都在 `_prep_phase` 里。
#    主控只留一个入口 —— `begin_prep()` 的第一个分支要调它。
#
# ⚠️ `_pending_event` / `_ship_pick_cache` / `_busy` 三个字段的真值也在那边
#    （主控用透传属性暴露，见字段区的注释）。


## 进事件节点（`begin_prep` 的分支调用；实现见阶段模块）。
func _enter_event_node() -> void:
	_prep_phase.enter_event_node()


# ══════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if run == null:
		return
	# ★ 2026-11-07（新手模式）：入口弹框还开着 = 这一局**还没开始**，什么都不推进。
	#   ⚠️ 这是上面 `_open_run_or_ask_novice()` 里「把顶条归零」的第二道保险：
	#      没有它，任何一条把 `time_left` 设回正数的路径都会在弹框期间跑完倒计时，
	#      而那一刻 `run.field` 是空的 ⇒ 直接被判「未部署」。
	if _novice_ask != null and _novice_ask.is_open():
		return
	# [versus] round clock runs in every phase (prep time counts too)
	_versus_tick(delta)
	_versus_net_tick()
	# ⚠️ 暂停 = **整个推进停摆**，不只是战斗 sim：
	#    准备阶段的倒计时（`hud.tick_stage`）也必须停 ——
	#    否则「暂停了 30 秒，回来发现准备时间没了、自动开战了」，
	#    那是最让人恼火的一种假暂停。视觉同步（`arena.sync_ships`）同理：
	#    它在暂停期间照常跑的话，舰艏会继续转向、镜头插值继续走，
	#    画面看着在动而数字不动，玩家会以为暂停坏了。
	if _paused:
		return

	# ★ 2026-10-28 房主权威：还没开赛 ⇒ **不跑准备倒计时**。
	#   ⚠️ 少了这一行，加入方在等待期间 `hud.tick_stage()` 照样走到 0，
	#      然后 `_on_stage_timer_expired()` 按「场上 0 艘」直接判负 ——
	#      表现就是「房主还没点开始，手机这边先输了」。网络轮询在上面的
	#      `_versus_net_tick()` 里已经跑过了，这里早退不影响收 START。
	if _vawait_start and not _vstarted:
		return

	match run.phase:
		EveRunState.Phase.PREP:
			# 准备阶段：不推战斗，只走倒计时
			hud.tick_stage(delta)
			_tick_countdown_sfx()

		EveRunState.Phase.BATTLE:
			# ★ 2026-10-10（2⑦ 状态机三拆）：战斗推进（step / 日志 / 火力渐增 / 位置同步）
			#   搬进战斗阶段模块；顶条倒计时与读秒音是 PREP/BATTLE **共用**的，留在分派器。
			#   ⚠️ `_paused` 已在函数开头统一拦掉，这里不用再判一次。
			_battle_phase.tick(delta * time_scale)
			hud.tick_stage(delta)
			_tick_countdown_sfx()

		EveRunState.Phase.RESOLVE:
			# ★ 2026-10-10（2⑦ 状态机三拆）：整段推进搬进结算阶段模块
			#   （两个方向相反的计时器 + 位置同步，见 `eve_phase_resolve.tick`）。
			_resolve_phase.tick(delta)

		_:
			pass


func _alive_count(team: int) -> int:
	var pool: Array[EveShip] = _own_ships if team == 0 else _enemy_ships
	var n := 0
	for s in pool:
		if s.alive:
			n += 1
	return n


## 当前场上所有的船（准备阶段没有模拟器，所以要从两份名单拼）
func _all_ships() -> Array[EveShip]:
	var out: Array[EveShip] = []
	out.append_array(_own_ships)
	out.append_array(_enemy_ships)
	return out


# ══════════════════════════════════════════════════════════════════
#  日志桥接
# ══════════════════════════════════════════════════════════════════

## ★★ 2026-10-10（2⑦ 状态机三拆）：火力渐增标志 / 时限判负标志**搬进了
##    `eve_phase_battle.gd`**（`_battle_phase`），下面两个只是**透传属性** ——
##    验收脚本 `_battle.get/set("_sd_announced")` / `("_timeout_forfeit")` 因此不用改。
##
## ⚠️ 两个标志都在 `_battle_phase.start()` 里复位 —— 不复位的话上一场的标志会
##    污染下一场（「明明打赢了却显示时限耗尽」，极难排查的那种幽灵 bug）。
var _sd_announced: bool:
	get:
		return _battle_phase.sd_announced
	set(v):
		_battle_phase.sd_announced = v

var _timeout_forfeit: bool:
	get:
		return _battle_phase.timeout_forfeit
	set(v):
		_battle_phase.timeout_forfeit = v

## 战斗日志桥接（把模拟器新产生的日志搬进 HUD）—— 已搬进 `eve_phase_battle.sync_log()`。





func _on_run_log(text: String, category: StringName) -> void:
	hud.append_log({
		"time": sim.elapsed if sim != null else 0.0,
		"category": category,
		"text": text,
	})


# ══════════════════════════════════════════════════════════════════
#  状态机 → HUD
# ══════════════════════════════════════════════════════════════════

## 经济 / 等级 / 信标 / 上场上限 / 备战席 → HUD
## 装甲墙状态行（炼狱 BOSS 关）—— 只在第 15 关出现，其余节点/难度隐藏。
##
## ★★ 2026-11-01（用户定案，A 项）：改造前这个机制在界面上**零提示**，
##   玩家只能看到自己的伤害莫名其妙变成十分之一。
## ⚠️ 判定"要不要显示"的三个条件缺一不可：本档声明了 armor_pierce、
##    当前节点是 boss、hud 已经建好。前两个读 `run`，第三个判空。
func _refresh_barrier_ui() -> void:
	if hud == null or run == null:
		return
	var on := run.node_type() == &"boss" and run.key_mechanic() == "armor_pierce"
	hud.set_barrier(run.armor_break_power(), run.ARMOR_BREAK_NEED,
			run.boss_barrier_mult(), on)


func _refresh_run_ui() -> void:
	if run == null:
		return
	# ⚠️ 满级后经验没有去处（超频走星币），所以这里把「超频进度」当经验条显示。
	#    读数会是 "Lv.6 · 1 / 2" —— 语义是「超频档 1／2」，不是「等级经验 1/2」。
	var xp_now := run.xp_in_level()
	var xp_need := run.xp_need()
	if run.level >= EveRunState.MAX_LEVEL:
		xp_now = run.overtier
		xp_need = EveRunState.MAX_TIER - EveRunState.MAX_LEVEL
	hud.set_economy(run.coin, run.level, xp_now, xp_need,
			EveRunState.REFRESH_COST, EveRunState.BUY_XP_COST)
	hud.set_bench(run.bench_used(), EveRunState.BENCH_SLOTS)
	# ⚠️ 上限要用 run.beacon_max()：事件「信标增幅器」会把上限抬高 20。
	#    写死 START_BEACON 的话，顶条的信标色带（>60% 绿 / >30% 橙）就会按错的分母算，
	#    玩家看到的是「满血却是橙字」。
	hud.set_beacon(run.beacon, run.beacon_max())
	hud.set_shop_locked(run.shop_locked)
	# ★ 商店买卖闸门也在这里兜一次：`_on_phase_changed` 只在**变化时**触发，
	#   而开局第一个 PREP 是「本来就是 PREP」⇒ 那条路不会响。
	#   幂等（值没变直接 return），放这儿零成本。
	hud.set_shop_buy_enabled(run.phase == EveRunState.Phase.PREP)
	hud.set_augments(run.picked_event_info())
	# 打捞框：`salvage_info()` 是唯一输入源，值域 = ""/"list"/"repairing"
	# （C-P1-1 收口后的契约）。商店框是**只读看板**：把 "list" 渲染成
	# 空态引导（打捞入口在结算页）、"repairing" 渲染修复中；"list" 的真
	# 消费者是结算页打捞区。场景这一侧不重复判一遍「有没有残骸」——
	# 判据写两份必然分叉。
	hud.set_salvage(run.salvage_info())
	# ★ 2026-11-07（结算期卖船）：卖船会 `changed` ⇒ 这里必须把结算页的打捞区
	#   重推一次 —— 否则玩家卖完船，结算页还写着旧的「持有 N 星币」，
	#   会以为钱没到账（而残骸报价是按当前星币判的）。
	#   ⚠️ 只在 RESOLVE 调：其它阶段 `result_window` 是收起的，推了也看不见，
	#      白白重建一遍列表。
	if run.phase == EveRunState.Phase.RESOLVE:
		_refresh_salvage_area()
	# 备战席立绘（2D，画在 EveBenchRail 的格子里）。
	# ⚠️ 2026-09-23：入口从 arena.bench_stage.update_fleet 换成这里 ——
	#    3D 备战层已停用（原因与回退方法见 EveBenchStage 头注释）。
	#    对比一下旧写法：那条路径要经过「3D 场景 → 反投影 → 每帧重算 transform」，
	#    而现在只是一次「把名单交给 HUD 重绘」，链路短了一整层。
	hud.set_bench_fleet(run.bench_entries())

	# 上场名单变了 → 重建我方舰队（只在准备阶段做；战斗中重建会把正在打的船换掉）
	# ⚠️ 拖动期间也不重建：万一有哪条路径在拖动中 emit 了 changed，
	#    重建会把正被拖着的那艘船换掉，幽灵和真船对不上号。
	if not _busy and _drag.is_empty() and run.phase == EveRunState.Phase.PREP:
		if _field_signature() != _last_field_sig:
			_respawn_own_fleet()


func _on_offers_changed() -> void:
	hud.set_shop_offers(run.offers)


func _on_phase_changed(phase: int) -> void:
	# 阶段名由 begin_prep / start_battle / 结算各自设置（它们更清楚上下文），
	# 这里只兜一件事：战斗结束的那一帧把「开战」按钮收回来。
	if phase == EveRunState.Phase.BATTLE:
		hud.set_start_button("交战中", false)

	# ★ 2026-10-05：**商店买卖的阶段闸门**。
	#    商店面板是常驻的，非准备阶段卡片照样亮着 —— 点下去只会被
	#    `buy()` 以「只有准备阶段能买船」拒绝，而卡片本身毫无变化，
	#    玩家会当成「点了没反应 / 买了没到手」。
	#    ⇒ 非准备阶段把整排卡压暗并停发请求。
	hud.set_shop_buy_enabled(phase == EveRunState.Phase.PREP)

	# ★ 2026-11-07（玩家反馈：「一回合结算时要能卖船，不然钱不够打捞」）：
	#
	#   能力本来就有（`EveRunState.can_sell()` 放行 PREP + RESOLVE，拖到商店即卖），
	#   但**结算期玩家看不出来** —— 商店看起来只是"买不了"，没人会想到往那儿拖。
	#   ⇒ 结算期把商店**常亮成出售区**（橙底 + 「拖到此处出售」），再加一行日志。
	#
	#   ⚠️ `bench=false` 是必须的：备战席轨道的出售态会把格子里的船**整块遮掉**
	#      并写「拖到此处出售」，可它的落点判定是「撤回 / 换位」，出售区只有商店窗
	#      —— 两处都亮橙就是在骗玩家（详见 `EveHudRoot.set_selling` 的注释）。
	if versus == null:
		# ⚠️ 写成「按阶段赋值」而不是「进 RESOLVE 时打开」：从 RESOLVE 直接收束到
		#    ENDING（信标归零 / 通关）时不会经过 `begin_prep()`，只开不关的话
		#    结局页背后会永远挂着一块橙色出售区。
		hud.set_selling(phase == EveRunState.Phase.RESOLVE, false)
	if phase == EveRunState.Phase.RESOLVE and versus == null:
		hud.append_log({"time": 0.0, "category": &"hint",
				"text": "钱不够打捞？把船拖到下方商店即可出售换星币（结算期有效）"})

	# ── 阶段 D④：阶段环境音 + BGM 切换 ──
	#
	# ⚠️ 这是**唯一的**阶段音入口。begin_prep / start_battle / resolve 各自
	#    还会设 HUD 文案，但声音只在这里发一次 —— 否则「开战」会响两遍
	#    （一次来自这里、一次来自 start_battle 自己的提示音）。
	audio.play_phase(phase)
	# ★ 2026-10-10：守卫边境的 BGM 改成**按节点分段**，不再按准备/交战分曲。
	#
	# ⚠️ 为什么要这么改：准备→交战→结算**每个节点都要走一遍**，按阶段切曲
	#    意味着每回合都交叉淡入淡出两次（1.2s × 2），一场 15 节点淡 30 次 ——
	#    听感是「音乐一直在找方向」。分段后整局只在第 11 个节点换一次曲。
	match phase:
		EveRunState.Phase.PREP, EveRunState.Phase.BATTLE, EveRunState.Phase.RESOLVE:
			audio.play_music(_round_music())
		_:
			audio.play_music("")


## 守卫边境的 BGM 分段节点（前 10 个节点一段，第 11 起是终局段）。
##
## ⚠️ 写死成常量而不是由 `EveNodeTable.TOTAL` 算：分段点是**设计值**
##    （用户 2026-10-10 定），改它要连音源一起换，不是「节点数变了就跟着变」。
const MUSIC_ROUND_SPLIT := 10


## 按**当前节点**选 BGM 逻辑名（逻辑名 = 文件名去掉末尾 `_NN`，见 `EveAudio._scan_dir`）：
##    节点 1~10   → `"border"`        （`border_01.ogg`，80s 无缝循环）
##    节点 11~15  → `"border_final"`  （`border_final_01.ogg`，96s 无缝循环）
##
## ⚠️ 判据用 `run.node_index`（唯一真相源）而不是自己数阶段：
##    `EveRunState.advance()` 先 `node_index += 1` 再发 `phase_changed`，
##    所以这里读到的**已经是新节点**，第 11 节点那一帧就换曲。
func _round_music() -> String:
	return "border" if run.node_index <= MUSIC_ROUND_SPLIT else "border_final"


# ══════════════════════════════════════════════════════════════════
#  玩家操作
# ══════════════════════════════════════════════════════════════════

func _on_start_battle_requested() -> void:
	match run.phase:
		EveRunState.Phase.PREP:
			start_battle()
		EveRunState.Phase.RESOLVE:
			_resolve_phase.end_resolve()
		EveRunState.Phase.ENDING:
			restart_run()
		_:
			pass   # 战斗中点了没用


## 倒计时滴答音（阶段 D④）。
##
## ⚠️ 触发条件是「秒数**变了**」而不是「每帧」：
##    60fps 下每帧调一次 tick 音会变成一片噪音，而且和视觉上「数字在跳」
##    对不上。这里用 `_last_tick_second` 做去重，一秒一响。
##
## ⚠️ 只在最后 10 秒响。整段 30 秒的倒计时从头滴到尾会很烦 ——
##    急促的滴答是「要来不及了」的信号，从头响就等于没有信号。
##
## ⚠️ 准备阶段的最后 3 秒换成 `play_countdown`（3 / 2 / 1）：
##    滴答和读秒是**两件事** —— 滴答是「还在等」，读秒是「马上开打」，
##    音色必须分开，否则玩家分不出 5 秒和 2 秒的区别。
##
## ★★ 2026-10-31（玩家：「开战倒计时 最后 5 秒 给提示音吧」）：
##    实测（`tools/probe_prep_countdown_audio`）**每秒都在响、0 次缺源**，
##    所以玩家听到的不是「没响」而是「太小」—— 三个音源的电平是
##    tick −8.5dB / tick_urgent −14.0dB / BGM −13.8dB，最后 5 秒那个音色
##    反而比普通滴答轻 5.5dB，被 BGM 整个盖住。
##    ⇒ 修在音频层（`EveAudio.TICK_URGENT_DB` / `COUNT_VOICE_DB` 的增益补偿），
##      ⛔ 不要在这里再叠一层音量，否则两个旋钮互相抵消、下次没人找得到。 
func _tick_countdown_sfx() -> void:
	var sec := hud.stage_seconds_left()
	if sec <= 0:
		return
	if sec == _last_tick_second:
		return
	_last_tick_second = sec
	if run.phase == EveRunState.Phase.PREP and sec <= 3:
		audio.play_countdown(sec)
	elif sec <= 10:
		audio.play_tick(sec)


func _on_stage_timer_expired() -> void:
	# ★★ 战斗时限归零 ⇒ **判负**（2026-10-04 用户口径恢复）。
	#
	#   用户原话：「在我们的设计里面，归零是该直接判负并扣除信标HP的，
	#   惩罚很严重的。」
	#
	#   ⚠️ 口径史（别再改回去时找不到出处）：
	#   · 2026-10-01 曾按用户「自走棋就该打到被击毁」改成**超时不判负**，
	#     彼时火力渐增（60%→∞）负责保证战斗收敛；
	#   · 2026-10-04 用户明确「归零判负并扣信标 HP」—— **以后者为准**。
	#   ⇒ 火力渐增的职责随之变回「帮玩家**在时限内**清场」（60%→100% 渐增到
	#     5 倍），时限归零那一刻战斗直接结束，不存在「超时继续加伤」的阶段。
	#
	#   ⚠️ 走 `_battle_phase.finished(1)`（敌方胜）—— 与战败**同一条结算路径**：
	#      扣信标 / 连败 / 打捞 / 经验全走既有逻辑，⛔ 不另造第二份真相源。
	#      （同 `_forfeit_no_deploy` 的做法与理由。）
	if run.phase == EveRunState.Phase.BATTLE:
		_battle_phase.forfeit_timeout()
		return
	if run.phase != EveRunState.Phase.PREP:
		return
	# ★ 2026-10-01：准备时间到、**一条船都没上** ⇒ 直接判本节点负。
	#
	#   原行为是「什么都不做，停在那里」，用户原话：
	#   「倒计时完之后还没有拖船上棋盘，现在的状态是会暂停，没有任何动作，
	#     这不行，得改成直接判负，就是这一回合判我输。」
	#
	#   ⚠️ 顺手堵掉一条白嫖规则：原来"不布阵"既不用打、也不掉血 ——
	#      等于可以靠不操作无限拖延。
	if run.field.is_empty():
		print("[对局] 准备时间到 · 场上 0 艘 ⇒ 判负（节点 %d）" % run.node_index)
		_battle_phase.forfeit_no_deploy()
		return
	if not auto_start_on_timeout:
		hud.append_log({"time": 0.0, "category": &"hint",
				"text": "准备时间到（自动开战已关闭，布好阵后点「开战」）"})
		return
	hud.append_log({"time": 0.0, "category": &"system", "text": "准备时间结束 —— 自动开战"})
	# ★ 中央倒计时归零的「开战」闪字：放在真正开打这一刻，
	#   ⛔ 不能交给 overlay 自己看 time_left==0 —— 主控会立刻 `set_stage()` 换上新计时，
	#   overlay 下一帧读到的已经是新回合的 30s，闪字永远不触发。
	if versus != null and hud.has_method("play_countdown_flash"):
		hud.play_countdown_flash()
	start_battle()


## 未布阵判负 —— **走和正常战败完全同一条结算路径**。
##
## ⛔ 不另造一条「直接扣血 / 直接推进」的分支：那会变成第二份真相源 ——
##    扣血公式、连胜连败、残骸、经验……每加一条规则都要记得改两处。
##    这里只是喂给 `_battle_phase.finished(1)`：敌舰一艘没死，
##    它自己会走「未部署」这条结束原因，后面的扣血与推进全走既有逻辑。
## 未布阵判负 / 时限归零判负 —— 已搬进 `eve_phase_battle.forfeit_no_deploy()`
## 与 `forfeit_timeout()`（三条收束路径都汇到 `finished()`）。
##
## ⚠️ 本文件仍有一个调用方：`_on_stage_timer_expired()`（PREP / BATTLE **共用**的阶段
##    定时回调）—— 它按当前阶段分派到上面两个方法。


func _on_shop_buy(index: int) -> void:
	var r := run.buy(index)
	if not bool(r.get("ok", false)):
		hud.append_log({"time": 0.0, "category": &"hint",
				"text": String(r.get("reason", "买不了"))})


## 商店卡「第一下」→ 右上角舰船档案换成这艘船（**只读**，不扣钱）。
##
## ★ 2026-11-07（玩家反馈：「买船的时候，要能点开看属性」）：
##   卡片上只有「攻 / 防」两个数，护盾 / 结构 / 武器 / 射程 / 羁绊全看不到，
##   玩家只能先买下来再看 —— 买错了还得退。现在第一下看档案，第二下才下单。
##
## ⚠️ 用 `build_preview()` 现造一个**一次性** `EveShip`：报价是纯数据（和备战席
##    的船一样没有 3D 实体），而档案窗只吃 `EveShip`。
##    ⛔ 绝不能塞进 `_own_ships` —— 那会让它计进羁绊、还会被模拟器拿去打。
func _on_shop_preview(index: int) -> void:
	if run == null or run.phase != EveRunState.Phase.PREP:
		return
	if index < 0 or index >= run.offers.size():
		return
	var offer = run.offers[index]
	if not (offer is Dictionary) or (offer as Dictionary).is_empty():
		return
	var preview: EveShip = _fleet.build_preview(offer)
	if preview != null:
		hud.show_ship(preview)


func _on_shop_refresh() -> void:
	var r := run.refresh()
	if not bool(r.get("ok", false)):
		hud.append_log({"time": 0.0, "category": &"hint",
				"text": String(r.get("reason", "刷新失败"))})


func _on_shop_levelup() -> void:
	var r := run.levelup()
	if not bool(r.get("ok", false)):
		hud.append_log({"time": 0.0, "category": &"hint",
				"text": String(r.get("reason", "加速失败"))})


## ★★ 打捞区（2026-10-04 改版：按钮在结算页**下方**，逐艘直接点「打捞」）
##
## 版式依据（用户 2026-10-04 原话）：「我想把打捞做成这样在**后面的按钮**的，
## 现在在前面点选有点反直觉了」+ 两张参考图。
## ⇒ 不再是「顶部一个按钮 → 弹浮层 → 勾选 → 确认」两段式，
##   改成结算页下方直接展开列表，**每艘右侧一个「打捞」按钮，点哪艘算哪艘**。
##
## ⚠️ 另一条护栏（参考图 1 的红字）：「本回合不决定，这 N 艘残骸永久作废」
##    ⇒ 玩家点「继续 · 下一节点」时若还有残骸没处理，弹二次确认。

## 点某一艘的「打捞」按钮。
##
## ⚠️ 结算页可能在这一刻已被关掉（玩家先点了「继续」）——
##    那时 `phase` 已经不是 RESOLVE，`salvage_order()` 会自己拒绝，
##    这里只负责把拒绝理由报给玩家，不做任何状态假设。
func _on_salvage_pick_one(idx: int) -> void:
	if run == null:
		return
	var r := run.salvage_order([idx])
	if not bool(r.get("ok", false)):
		hud.append_log({"time": 0.0, "category": &"hint",
				"text": String(r.get("reason", "打捞失败"))})
		_refresh_salvage_area()
		return
	hud.append_log({"time": 0.0, "category": &"salvage",
			"text": "打捞 %s −%d ◆ · 下一节点到账（占 1 个货位）"
			% [", ".join(r.get("names", [])), int(r.get("paid", 0))]})
	_refresh_salvage_area()


## 点「关闭」→ **只收起打捞区**（不下单、不推进）。
##
## ⚠️ 残骸**仍在  里**，玩家可以在结算页继续点「继续 · 下一节点」
##    重新打开它（下次  会再推一次）。
func _on_salvage_section_closed() -> void:
	pass


## 确认「放弃剩余残骸」→ 关掉结算页、推进到下一节点。
##
## ⚠️ 这里**必须真的推进**，不能只刷新 UI：确认框是「放弃打捞并继续」的
##    唯一出口，不接上推进玩家就被卡在结算页（点「继续」只会再弹一次框）。
func _on_salvage_pick_zero() -> void:
	if run == null or run.phase != EveRunState.Phase.RESOLVE:
		return
	hud.hide_result()
	_resolve_phase.end_resolve()


## ★ 把 `run.salvage_info()` 推给结算页的打捞区（**唯一输入源**）。
##
## ⚠️ 顺带做一件容易被漏掉的事：**如果玩家还有残骸没处理就点「继续」，
##    必须拦一下**（用户参考图 1 的红字警告就是这个意思）。
##    这里只在「真的有残骸」时弹框 —— 没有残骸时静默推进，不给玩家添堵。
func _maybe_confirm_leftover_wrecks() -> void:
	if run == null:
		return
	var info := run.salvage_info()
	if String(info.get("state", "")) != "list" or run.wrecks.is_empty():
		return
	var res_win = hud.get("result_window")
	if res_win == null:
		return
	# ★ 2026-10-13：确认框 = `EveConfirmDialog`（EVE 窗口语言版）。
	#   ⛔ 别再 `res_win.get("_salvage_ask")` 去戳内置 `ConfirmationDialog` ——
	#      那是原生 OS 窗口（系统标题栏/字体/配色），已废弃（用户原话「丑哭了」）。
	#   文案与弹框都收口在 `EveResult.ask_abandon_salvage()`，主控只报个数。
	res_win.call("ask_abandon_salvage", run.wrecks.size())


## 重画打捞区（下单 / 取消后都要调）。
func _refresh_salvage_area() -> void:
	if hud == null or run == null:
		return
	var res_win = hud.get("result_window")
	if res_win == null:
		return
	# ⚠️ 结局页（ENDING）不给打捞区：局已经结束了，残骸没有意义。
	var ended := run.phase == EveRunState.Phase.ENDING
	res_win.refresh_salvage(run.salvage_info(), ended)
## ⚠️ 旧入口：商店面板那个小打捞框（`EveShop` 的 `_slv_box`）。
##    2026-10-04 起打捞搬到结算页，这里**只保留日志报错**，
##    不再下单 —— 免得两条路径都能扣钱、状态机却只认一条。
##    ⛔ 别删这个函数：`hud.salvage_requested` 仍连着它，删了会运行时报错。
func _on_salvage() -> void:
	if run == null:
		return
	var info := run.salvage_info()
	if String(info.get("state", "")) == "list":
		hud.append_log({"time": 0.0, "category": &"hint",
				"text": "打捞在**战斗结算页下方** —— 打完那页的「⚓ 打捞 残骸」区逐艘点"})
	else:
		hud.append_log({"time": 0.0, "category": &"hint",
				"text": "本回合没有可打捞的残骸"})


func restart_run() -> void:
	arena.clear_ships()
	# 阶段 D：重开一局要把特效与两个新面板都收干净
	arena.fx_clear()
	# 阶段 D④：音频也要收干净 —— 不清的话上一局的爆炸音会飘进新一局的布阵台，
	# 而且 `_last_tick_second` 会跨局残留（新一局第一次滴答被误判为「没变」）。
	audio.stop_all()
	audio.reset_stats()
	_last_tick_second = -1
	arena.end_battle_shot()
	hud.hide_result()
	hud.hide_settings()
	# ★★ 2026-10-30（玩家反馈 BUG）：在**事件节点**按 R 重开，事件面板会留在屏幕上。
	#
	#   实测链路：`run.start_run()` 已经把节点打回 1、星币打回 start_gold，
	#   但面板还开着 ⇒ 玩家在那张「节点 4 的四选一」上再点一下：
	#     `apply_event()` 落到**新的一局**上（增益生效）
	#     → 紧接着 `advance()` 给了一次节点收入（+5）
	#   于是新局开局 5 + 5 = 10 星币，还平白多一条增益。
	#   ⇒ 重开必须把事件面板与「事件态」一起收掉，不只是清 `_pending_event`。
	hud.hide_event()
	# ★ 2026-10-31：抽奖窗是**同一类中间态** —— 上一局停在抽奖窗就重开，
	#   新局会带着 `lottery_open = true`，于是下一个事件节点选完黑市情报时
	#   `on_lottery_finished` 的守卫会误判、节点推进的路径也会错。
	#   ⚠️ 窗口也必须收：它的 visible 是 HUD 自己的状态，不清就一直挂在新局上。
	_prep_phase.lottery_open = false
	hud.hide_lottery()
	_prep_phase.versus_event = false
	hud.clear_damage()
	hud.hide_entry()
	_fleet.reset()
	sim = null
	# 重开 = 硬重置：直接把暂停态清掉并撤遮罩。
	#
	# ⚠️ 不走 `set_paused(false)` —— 它在「本来就没暂停」时会 early return，
	#    而重开必须**无条件**保证遮罩是收起的（否则新一局开局就蒙着一层灰）。
	_paused = false
	hud.set_paused(false)
	hud.sync_settings_pause(false)
	# ★ 2026-10-10（2⑦）：结算阶段的两个计时器与攒下的数据一起归零。
	#   ⚠️ 不清的话：「上一局结束时正好处在延迟中 → 玩家点了结束本局 →
	#      1 秒后新一局的布阵台上弹出一张旧结算页」。
	_resolve_phase.reset()
	_last_field_sig = ""
	# ★ 2026-10-10（审查 R01）：场景侧的「待选事件 / 选船缓存」也必须清 ——
	#   否则上一局若正好停在「等玩家选一艘船」的中间态就重开，新局开局
	#   可能带着 `_pending_event` 进第一个事件节点（状态串味）。
	_pending_event = &""
	_ship_pick_cache.clear()
	_layer_seen.clear()
	# ★ 2026-10-10（审查 2#2）：重开 = 上一局作废 ⇒ 先把旧档删掉
	#   （随后 `begin_prep()` 会把**新的一局**存进去，所以「继续上一局」照样有）。
	RUN_STORE.clear()
	hud.clear_log()
	hud.set_selling(false)
	# ★ 2026-11-07：重开一局**沿用**上一局的新手模式（⛔ 不重新弹框）。
	#   `start_run()` 是「新的一局的完整初始态」，它会把这个字段清回 false，
	#   所以在这里显式把玩家的选择带过去。
	var keep_novice := run.novice_mode
	run.start_run()
	run.novice_mode = keep_novice
	begin_prep()


# ══════════════════════════════════════════════════════════════════
#  阶段 D：设置窗 —— 已搬到 `scripts/scene/eve_settings_bridge.gd`
# ══════════════════════════════════════════════════════════════════
#
# ⚠️ 13 个 `_on_settings_*` handler + `_apply_saved_settings` + `_sync_settings_ui`
#    现在都在 `_settings_ctl` 里（`eve_settings_bridge.gd`，见其顶注）：
#    它们只做「设置意图 → arena/audio/run/store 的落地」，与状态机无关。
#
# ⛔ 只有**暂停**留在本文件：`set_paused()` 与 `_paused` 是红线级的唯一写入口，
#    且验收直接读 `_battle.get("_paused")`；桥接器通过 `on_pause` 回调转调。
#
# ⚠️ HUD 信号在 `_ready` 里直接连到 `_settings_ctl.*`
#    —— 少连一行就是「按钮看着能点、点下去什么都不发生」。


## 桥接器回调：暂停态（**只读** —— 唯一写入口是本文件的 `set_paused`）。
func _get_paused_state() -> bool:
	return _paused


## 暂停 / 继续的**唯一入口**。
##
## ══ 三条路都走这里 ════════════════════════════════════════════════
##    设置窗的暂停按钮 · 键盘空格 · 暂停遮罩上的「继续」按钮。
##  三条路各写一遍 `_paused = x` 的后果是必然的：漏一个回写就出现
##  「场上停着、按钮写着暂停」或者「遮罩还在、游戏已经在跑」——
##  这类不一致**不报错**，只在玩家手里发作。
##
## ⚠️ 暂停是【全局】的：准备阶段也要能停（PVE 也要），
##    所以它不是「战斗 sim 的一个开关」，而是整个 `_process` 的闸门。
##
## ⛔ 2026-10-10：它**不**跟着设置窗那批 handler 一起搬去桥接器 ——
##    `_paused` 是主控自己的状态（验收直接读 `_battle.get("_paused")`），
##    桥接器只是通过 `on_pause` 回调转调到这里。
func set_paused(on: bool) -> void:
	if _paused == on:
		return
	_paused = on
	hud.set_paused(on)
	# ⚠️ 回写设置窗的按钮：键盘空格改的状态，窗自己不知道
	hud.sync_settings_pause(on)
	hud.append_log({"time": sim.elapsed if sim != null else 0.0,
			"category": &"system",
			"text": "已暂停 · 操作已锁定（空格 / 设置窗「继续对局」恢复）"
					if on else "继续"})


## 桥接器回调：「放弃本局 · 回主界面」的切场景动作
## （RefCounted 没有场景树 ⇒ 这句必须由主控执行）。
func _do_back_to_menu() -> void:
	print("[主控] 放弃本局 → 返回主界面")
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_stance_changed(ship: EveShip, stance: int) -> void:
	var visual := arena.get_ship_visual(ship.id)
	if visual and visual.has_method("refresh_stance"):
		visual.refresh_stance()
	hud.append_log({
		"time": sim.elapsed if sim != null else 0.0, "category": &"system",
		"text": "%s 切换姿态：%s" % [ship.ship_name, EveDestinyMotion.stance_label(stance)],
	})


func _on_unit_destroyed(ship: EveShip) -> void:
	# 选中船被摧毁时保留信息（显示为已损毁状态）—— 这里不改选中，
	# 因为战斗结束后玩家多半还想回看那艘船的数据。
	#
	# ── 阶段 D②：击毁反馈 ──
	# 爆炸挂在那艘船【当时的位置】上。ship.body.position 是米。
	arena.fx_boom(ship.body.position)
	# 阶段 D④：击毁爆炸音。放在视觉之后 —— 先看见再听见，
	# 顺序反了会觉得「声音提前了」（虽然间隔只有一帧）。
	# ⚠️ 一样要先喂模拟器时间，否则快进时被节流吞掉。
	if sim != null:
		audio.set_clock(float(sim.elapsed))
	audio.play_boom()
	hud.append_log({
		"time": sim.elapsed if sim != null else 0.0, "category": &"damage",
		"text": "%s 结构崩溃 · 爆炸解体" % ship.ship_name,
	})
	# ⚠️ 视觉节点此刻起不可见（sync_from_body 见到 alive=false 会隐藏它）。
	#    Label3D 不带 no_depth_test 的话会跟着一起消失，这里不做额外处理 ——
	#    船没了就是没了，留一个浮空的名字反而像 bug。


## 判定这一发打在**哪一层**（护盾 / 装甲 / 结构）。
##
## ⚠️ 这是**近似**，不是模拟器的原始层信息：
##    `shot_fired` 只带 `quality`，不带「打在盾上还是甲上」。
##    这里用**命中后剩余的 hp** 反推：
##      · 盾还有   ⇒ 盾在扛（shield）
##      · 盾空了、甲还有 ⇒ 装甲（armor）
##      · 都空了   ⇒ 结构（hull）
##    唯一不准的时刻是「一发刚好把盾打穿」—— 那一发会被判成 armor。
##    代价只是**一次闪光的颜色**，可接受；要做到严格正确得让 sim 把层信息
##    一起播出来（那是改信号签名，要同步验收，另排期）。
##
## ⛔ 不要用 `quality` 来猜层：品质 ≠ 层。一发 WRECKING 可能砸在满盾上，
##    一发普通命中可能已经在啃结构 —— 那正是「颜色读不出状态」的老毛病。
func _hit_layer(ship: EveShip) -> StringName:
	if ship == null:
		return &""
	if float(ship.hp.get(&"shield", 0.0)) > 0.001:
		return &"shield"
	if float(ship.hp.get(&"armor", 0.0)) > 0.001:
		return &"armor"
	return &"hull"


## 这一发在**播报条**上算什么事件：命中 / 穿透 / 破盾 / 破甲 / 击毁。
##
## ⚠️ 优先级是**有顺序**的，别调换：
##   ① 击毁（结构见底）最重 —— 它同时意味着前面几层已经没了，报「破甲」是误导；
##   ② 破层（盾/甲 由有变无）—— 只在这一发**跨过归零**时成立，
##      否则盾空之后的每一发都会被标成「破盾」，播报条就全是破盾；
##   ③ 穿透（`EveShip.last_hit_pierced`，由模拟器每发写入）；
##   ④ 落回「命中」。
func _feed_kind(target: EveShip) -> StringName:
	if target == null:
		return &"hit"
	var id := target.id
	var prev: Dictionary = _layer_seen.get(id, {"shield": true, "armor": true})
	var has_shield := float(target.hp.get(&"shield", 0.0)) > 0.001
	var has_armor := float(target.hp.get(&"armor", 0.0)) > 0.001
	var has_hull := float(target.hp.get(&"hull", 0.0)) > 0.001
	_layer_seen[id] = {"shield": has_shield, "armor": has_armor}
	if not has_hull:
		return &"kill"
	if bool(prev.get("shield", true)) and not has_shield:
		return &"shield"
	if bool(prev.get("armor", true)) and not has_armor:
		return &"armor"
	if target.last_hit_pierced:
		return &"pierce"
	return &"hit"


## 开火：画曳光 + 冒伤害数字（阶段 D②③）
##
## ⚠️ 这个回调在 **sim.step() 的一次调用里可能被触发上百次**
##    （固定步长的 tick 循环）。所以它里面【绝不能】做重活 ——
##    一切只是 add_child 一个 quad / 往数组里压一条记录。
##    verify_run 的 `debug_fast_forward_battle` 一次快进 90 秒，
##    就是靠这条约束才不会卡死。
func _on_shot_fired(attacker: EveShip, target: EveShip, hit: bool,
		quality: int, damage: float) -> void:
	if attacker == null or target == null:
		return
	# ★ 2026-10-21 火力引导：先把受击层算出来，好让曳光线指向「壳面」而不是船体中心。
	#   护盾还在时，视觉命中点取目标护盾朝向攻击者的那一面；
	#   否则仍用船体位置。
	var layer := _hit_layer(target)
	# ★ 2026-10-30：战斗播报（屏幕中央靠上 3 行）。**只播命中** ——
	#   miss 每秒几十次，播了就是把真正要读的结论冲掉。
	#   ⚠️ 这里只做「往数组里压一条」，与飘字同一条约束（见本函数顶注）。
	if hit:
		hud.push_damage_line(int(round(damage)), attacker.team == 0,
				_feed_kind(target), target.ship_name)
	var vis := arena.get_ship_visual(target.id)
	var aim: Vector3 = target.body.position
	if hit and layer == &"shield" and vis != null and vis.has_method("shield_impact_point"):
		aim = vis.shield_impact_point(attacker.body.position)
	if hit and layer == &"shield":
		# 护盾层：画炮击亮痕（攻击本身），头部停在壳面锚点上
		arena.fx_artillery(attacker.body.position, aim, quality)
	else:
		arena.fx_tracer(attacker.body.position, aim, hit, quality)
	# 阶段 D④：开火 + 命中音。
	#
	# ⚠️ 这两行的调用频率极高（一次 sim.step 里可能上百次），
	#    但 `play_fire` / `play_hit` 内部**第一件事就是查节流表**，
	#    被吞掉时只加一个计数器就返回 —— 不做任何采样加载或节点操作。
	#    所以这里的成本是「一次字典查表」，不会拖慢快进。
	#
	# ⚠️ 先把**模拟器时间**喂给音频层（见 EveAudio.set_clock）：
	#    节流必须按战斗时间来，否则快进 / 倍速时一整场只响一两声。
	if sim != null:
		audio.set_clock(float(sim.elapsed))
	audio.play_fire(quality)
	if not hit:
		# 未命中也有信息量（「打空了」），但不画爆点、不冒数字 ——
		# 一次齐射里 60% 是未命中，全冒出来会糊满整个屏幕。
		# 声音侧同理：未命中只响开火音，**不**响命中音 ——
		# ⚠️ 早期版本这里误调了 `play_hit(quality)`：品质 0 会去查 "miss" 音源，
		#    查不到就退回通用 "hit"，于是「打空了」反而播出一声命中 ——
		#    而且不报错。
		return
	audio.play_hit(quality)
	# ★ 视觉分层：护盾层不再画面积特效（蓝环已删），只留贴花；
	#   装甲/结构层仍走原来的爆点。
	arena.fx_hit(aim, quality, layer)
	if vis != null and vis.has_method("flash_hit"):
		vis.flash_hit(layer)
	# ★ 护盾层受击：在目标船的蛋形护盾上落一块曲面贴花。
	#   护盾本身不显形，只有贴花出现；来向取攻击者位置，
	#   所以贴花落在「面向敌人」的那一侧。
	#   ⚠️ 贴花的槽位上限由单个贴花的覆盖率推导（见 eve_shield_impact.gd），
	#      落进已有贴花角度范围内会复用那个槽位，不会无限堆节点。
	if layer == &"shield" and vis != null and vis.has_method("shield_hit_from"):
		vis.shield_hit_from(attacker.body.position)
	var sp := arena.world_to_screen(target.body.position + Vector3(0, 4, 0))
	hud.pop_damage(sp, damage, quality, true)


func _on_range_rings_toggled(enabled: bool) -> void:
	arena.range_layer.visible = enabled
	_settings_ctl.sync_ui()


# ══════════════════════════════════════════════════════════════════
#  验收 / 调试入口
# ══════════════════════════════════════════════════════════════════

## 把当前战斗一次性快进若干秒。
##
## ⚠️ 它会在一次调用里跑完几百个 tick，所以只在无头验收脚本里用，不要接到 UI 上。
## ⚠️ 2026-10-10：改用 `sim.run_seconds()` —— `step()` 现在**有单帧 tick 上限**
##    （防死亡螺旋），拿它快进会只走 8 tick。语义不变（跑满这段时间）。
func debug_fast_forward_battle(seconds: float) -> void:
	if sim == null or sim.finished:
		return
	sim.run_seconds(seconds)
	_battle_phase.sync_log()
	# ⚠️ 快进时把 `seconds` 当 delta 传：一次调用跑完了 `seconds` 秒的模拟，
	#    限速闸门就应按「这段时间的总可转角」放行，否则快进后舰艏会滞后于
	#    已经跑完的几百帧（验收脚本拿到的是"半路姿态"）。这是**有意的**。
	arena.sync_ships(sim.ships, seconds)


## 跳过结算等待（验收脚本用）。
##
## ⚠️ 阶段 D 之后 RESOLVE 阶段不再有定时器 —— 结算页会一直停着。
##    所以这个入口改为「等价于点一次结算页的继续按钮」，
##    而不是去等一个不存在的超时。旧脚本调用它得到的语义完全不变。
##
## ★ 2026-10-01：结算页现在有 1 秒的**延迟弹出**。如果在这一秒里调它，
##    `hud.hide_result()` 会作用在一张还没弹出来的页上（无害），但
##    `_pending_result` 会残留 ⇒ 下一回合的开场弹出一张旧结算页。
##    所以这里先 `_popup_result()` 把它消费掉，再走原路径收起并推进 ——
##    对调用方而言「跳过结算」的语义一字未变。
func debug_skip_resolve() -> void:
	if run != null and run.phase == EveRunState.Phase.RESOLVE:
		_resolve_phase.popup()
		hud.hide_result()
		_resolve_phase.end_resolve()


## 把结算弹窗的延迟一次性走完（验收脚本用）。
##
## ⚠️ 存在的理由：`_process` 里那一秒是靠**真实帧**累加的，而无头验收
##    在 `_step_battle_done` 里是一次性快进 90 秒（**一帧内**跑完），
##    中间根本没有帧过去 ⇒ 不主动催一下的话，那一秒要等到下一个
##    `_step_*` 的若干帧之后才走完，断言会读到「结算页还没弹」。
##    给验收一个显式入口，比让每个脚本各自 await 一堆帧稳得多。
func debug_flush_result_popup() -> void:
	_resolve_phase.popup()


# ══════════════════════════════════════════════════════════════════
#  输入
# ══════════════════════════════════════════════════════════════════
#
# ⚠️ 左键现在有三种含义，必须由同一个地方仲裁
#
#   ① 「在我方舰船 / 备战席上按下并拖动」= 拖放布阵（阶段 B5）
#   ② 「在空白处按下并拖动」            = 轨道相机转视角
#   ③ 「单击」                          = 选中最近舰船
#
#   仲裁顺序：先试 ①（拿得起来吗），拿不起来才交给 ② / ③。
#   顺序不能反 —— 反了就会出现「想拖船，结果转了视角」。
#
# ⚠️ 为什么「拖动期间」的事件收在 _input() 而不是 _unhandled_input()：
#   松手时指针很可能停在【商店窗】上（那里就是出售区）。窗口是 MOUSE_FILTER_STOP，
#   事件会被 GUI 吃掉，根本到不了 _unhandled_input ——
#   症状是「把船拖到商店上松手，什么都没发生，船还留在原地」。
#   _input() 在所有 GUI 之前拿到事件，拖动期间用它才稳。
var _cam_dragged := false

func _input(event: InputEvent) -> void:
	# ★★ 2026-11-08（玩家反馈「空格会重复上一次点过的按钮」）——空格前哨。
	#
	#    Godot 的 BaseButton 只要拿到键盘焦点，就在 `_gui_input` 里把
	#    「空格 / 回车」当自己的点击（focus_mode 默认 FOCUS_ALL）。
	#    鼠标点过「↻ 刷新」之后它就攥着焦点 ⇒ 按空格 = 又刷一次、还扣钱；
	#    点过「▲ 等级加速」⇒ 空格又升一级。
	#
	#    这里**只摘焦点、不吞事件**：`release_focus()` 之后按钮的
	#    `has_focus()` 为 false，它在 GUI 阶段就不认这个空格了；
	#    事件继续往下走，正常落到 `_unhandled_input()` 的暂停分支。
	#    ⛔ 千万别改成 `set_input_as_handled()` —— 那会连暂停一起吃掉。
	#
	#    HUD 侧另有一道（`eve_hud_root._on_gui_focus_changed`，拿到焦点即交还），
	#    两道互不冲突：焦点已空时 `gui_get_focus_owner()` 返回 null，这里什么也不做。
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_SPACE:
		var focus_owner := get_viewport().gui_get_focus_owner()
		if focus_owner is BaseButton:
			focus_owner.release_focus()
	# 只在「正在拖船」时抢事件；其余一概不碰（让相机与 GUI 各司其职）
	if _drag.is_empty():
		return
	if event is InputEventMouseMotion:
		_update_drag((event as InputEventMouseMotion).position)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			# ★★ 2026-10-30（玩家反馈「准备阶段点击舰船，档案不跟着换」）：
			#    `_end_drag()` 现在会回答「这一次到底是拖放还是点选」。
			#    点选 = 位移没超过 `TAP_SLOP`，拖放状态已就地收尾、数据一字未改
			#    ⇒ 这里补上那条原本走不到的「松手 → 选中」。
			# ⚠️ 必须是 `_end_drag` **之后**再选：拖动态还亮着棋盘/幽灵，
			#    先选会让 `set_ship` 的「展开档案」和拖动的收尾抢同一帧。
			var tapped := _end_drag(mb.position)
			get_viewport().set_input_as_handled()
			if tapped:
				_try_select_at(mb.position)
			return
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			_cancel_drag("已取消")
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		_cancel_drag("已取消")
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	# 左键先给相机仲裁
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_cam_dragged = false
				# ⓪ 双击优先：视角中心选择（船 ⇒ 锁到它；空处 ⇒ 回默认）
				#    ⚠️ 必须放在拿船判定**之前**还是**之后**？
				#    放后面 —— 拿船的判定先跑，双击自家人也会先进入拖放，
				#    与「拖放布阵」这条老交互不冲突。
				if mb.double_click and _try_begin_drag(mb.position):
					# 双击落在了可拖的船上：仍按拖放处理，不锁视角
					return
				if mb.double_click:
					_try_focus_at(mb.position)
					get_viewport().set_input_as_handled()
					return
				# ① 先试拿船（备战席 / 我方场上）。拿起来了 → 本次左键归拖放
				if _try_begin_drag(mb.position):
					return
				# ② 没拿起来 → 老行为：相机（它会开始记录拖拽距离）
				arena.handle_camera_input(event)
				return
			else:
				# 松开：先让相机收尾，再据「是否真拖过」决定要不要选船
				var cam_consumed := arena.handle_camera_input(event)
				if not cam_consumed:
					_try_select_at(mb.position)
				return

		# 滚轮 / 其他键：直接给相机（不影响选中）
		if arena.handle_camera_input(event):
			return

	elif event is InputEventMouseMotion:
		# 没在拖船、但棋盘可见时（KEY_B 手动开）：鼠标扫到哪格就高亮哪格
		if arena.board != null and arena.board.visible:
			var cell: Vector2i = arena.screen_to_cell(event.position)
			if cell.x >= 0:
				arena.board.highlight(cell.x, cell.y)
			else:
				arena.board.clear_highlight()
		if arena.handle_camera_input(event):
			return

	if event is InputEventKey and event.pressed and not event.echo:
		# ⚠️ 暂停期间**只放行空格**（唯一的解锁键）。
		#    R / C / B 一律吞掉 —— 遮罩管得住鼠标、管不住键盘，
		#    这条守卫就是键盘侧的那一半。放行它们等于开了个
		#    「暂停中偷偷重开一局 / 转镜头」的后门。
		if _paused and event.keycode != KEY_SPACE:
			return
		match event.keycode:
			KEY_SPACE:
				set_paused(not _paused)
			KEY_R:
				hud.append_log({"time": 0.0, "category": &"system", "text": "重开一局"})
				restart_run()
			KEY_C:
				# 手动复位机位（双击左键也可，见 arena.handle_camera_input）
				arena.reset_camera()
				hud.append_log({"time": sim.elapsed if sim != null else 0.0,
						"category": &"system", "text": "相机已复位"})
			KEY_B:
				# 棋盘开关（检查格子用）。真实玩法里由「拖起舰船」自动触发，
				# 这个手动入口保留 —— 它就是「棋盘现在归玩家管」的那条路径。
				var board_on := arena.toggle_board()
				# 玩家手动开的棋盘 = 「这一局棋盘归玩家管」⇒ 松手别去自动关它
				# （拖动控制器里记的那个「自动点亮」标记在这里清掉）。
				_deploy.mark_board_manual()
				# 阶段 D：设置窗开着的话把它那个「棋盘 [开/关]」按钮同步过来，
				# 否则窗里显示的和实际相反（下一次点击就会反着操作）。
				_settings_ctl.sync_ui()
				hud.append_log({"time": sim.elapsed if sim != null else 0.0,
						"category": &"system",
						"text": "棋盘 %s" % ("显示（11×11）" if board_on else "隐藏")})


## 点击选中最近的舰船（屏幕距离 60px 内）
## 找出屏幕上离 pos 最近的那艘活船（够得着 PICK_RADIUS 才算）
func _pick_ship_at(screen_pos: Vector2) -> EveShip:
	var best: EveShip = null
	var best_dist := DEPLOY.PICK_RADIUS
	for ship in _all_ships():
		if not ship.alive:
			continue
		var sp := arena.world_to_screen(ship.body.position + Vector3(0, 4, 0))
		var d := sp.distance_to(screen_pos)
		if d < best_dist:
			best_dist = d
			best = ship
	return best


func _try_select_at(screen_pos: Vector2) -> void:
	# ── ① 备战席 ────────────────────────────────────────────────────
	# 备战席的船是**纯数据**（`{"ship_key","star"}`）画在 2D 轨道上，
	# 3D 场景里根本没有它 ⇒ `_pick_ship_at()` 永远点不中。
	# 而档案窗收起态的文案写的就是「战场 / 备战席 / 商店卡 任一处点选即可」
	# —— 备战席必须能点，⛔ 否则是「写了能点但点不动」。
	if hud != null and run != null:
		var bi := hud.bench_slot_at(screen_pos)
		var bench := run.bench_entries()
		if bi >= 0 and bi < bench.size():
			var preview: EveShip = _fleet.build_preview(bench[bi])
			if preview != null:
				hud.show_ship(preview)
			return
	# ── ② 3D 战场 ───────────────────────────────────────────────────
	var best := _pick_ship_at(screen_pos)
	if best != null:
		hud.show_ship(best)


## 双击：视角中心选择（2026-10-27 用户定案）
##
## 双击某艘船 ⇒ 视角中心锁到它（船继续机动，镜头跟着走）
## 双击空中   ⇒ 解除锁定并回默认机位
##
## ⚠️ 与「拖放布阵」不冲突：拿船的判定在 _unhandled_input 里**先**跑，
##    拿起来了本次左键就归拖放，根本走不到这里。
func _try_focus_at(screen_pos: Vector2) -> void:
	var ship := _pick_ship_at(screen_pos)
	if ship != null:
		if arena.set_camera_lock(ship.id):
			hud.show_ship(ship)
			_log_focus(ship)
		return
	# 点到空处：解锁 + 回默认机位
	arena.clear_camera_lock()
	arena.reset_camera()


func _log_focus(ship: EveShip) -> void:
	if hud != null and hud.has_method("append_log"):
		hud.append_log({"time": 0.0, "category": &"system",
				"text": "视角锁定：%s★%d" % [ship.ship_name, ship.star]})


# ══════════════════════════════════════════════════════════════════
#  拖放布阵（阶段 B5）—— 已搬到 `scripts/scene/eve_deploy_controller.gd`
# ══════════════════════════════════════════════════════════════════
#
# ⚠️ 整个拖放交互（按下 / 移动 / 松手 / 取消 / 收尾）现在在 `_deploy` 里，
#    本文件只留**四个薄委托** —— 它们同时是
#      ① 场景输入回调（`_input` / `_unhandled_input`）的入口，
#      ② 验收脚本（`verify_run` 直接 `_battle.call(...)`）的入口，
#    属**对外契约** ⇒ ⛔ 不许改名 / 删。
#
#    拖动状态仍然住在本文件的 `_drag`（与 `_deploy` 共享同一个字典对象）。


## 按下左键时试着拿起一艘船。拿起来了 → true（本次左键从此归拖放）
func _try_begin_drag(pos: Vector2) -> bool:
	return _deploy.begin_drag(pos)


## 拖动中：幽灵跟手 · 落点高亮 · 写「松手会怎样」
func _update_drag(pos: Vector2) -> void:
	_deploy.update_drag(pos)


## 松手：按落点分派到 部署 / 换位 / 撤回 / 出售
##
## 返回 **true = 这一次其实是「点选」**（按下到松手没怎么动，见
## `EveDeployController.TAP_SLOP`）⇒ 什么都没改，调用方该接着做「选中」。
func _end_drag(pos: Vector2) -> bool:
	return _deploy.end_drag(pos)


## 取消：ESC / 右键
func _cancel_drag(msg: String = "") -> void:
	_deploy.cancel_drag(msg)


# ══════════════════════════════════════════════════════════════════
#  AI 操作面（2026-10-26）—— 外部 AI 驱动本局的唯一入口
# ══════════════════════════════════════════════════════════════════
#
# 红线（与 `scripts/core/eve_ai_api.gd` 顶注同源）：
#   · 每个动作都走**玩家点击的同一条代码路径**（HUD 信号 → 同一个 handler），
#     不另造第二份真相源；规则只在 EveRunState 里判一次。
#   · 返回值统一 Dictionary（ok / reason），AI 靠 reason 知道「为什么没生效」。
#   · ⛔ 不许在这里做规则判断，也不许直接改 run 的字段绕过判定。
#
# 这一节的方法同时是 `ai_*` 桥的落地点，改名要同步改 eve_ai_api.gd。


func ai_kind() -> String:
	return "battle"


## 全量快照（AI 的「眼睛」）。构造在 eve_ai_api.build_battle_snapshot，
## 这里只做转发 —— 场景树里谁被找到就让谁自己报，API 不认场景。
func ai_snapshot() -> Dictionary:
	return EveAiBridge.battle_snapshot(self)


func ai_own_ships() -> Array[EveShip]:
	return _get_own_ships()


func ai_enemy_ships() -> Array[EveShip]:
	return _get_enemy_ships()


func ai_is_paused() -> bool:
	return _paused


## ── 经济 / 商店 ──────────────────────────────────────────────
func ai_buy(index: int) -> Dictionary:
	if run.phase != EveRunState.Phase.PREP:
		return {"ok": false, "reason": "只有准备阶段能买船"}
	var r := run.buy(index)
	return _ai_result(r)


func ai_refresh() -> Dictionary:
	if run.phase != EveRunState.Phase.PREP:
		return {"ok": false, "reason": "只有准备阶段能刷新"}
	return _ai_result(run.refresh())


func ai_levelup() -> Dictionary:
	if run.phase != EveRunState.Phase.PREP:
		return {"ok": false, "reason": "只有准备阶段能买经验"}
	return _ai_result(run.levelup())


func ai_set_shop_lock(on: bool) -> Dictionary:
	run.set_shop_locked(on)
	hud.set_shop_locked(run.shop_locked)
	return {"ok": true}


## ── 布阵（与拖放控制器走同一批 RunState 入口）────────────────
func ai_deploy(bench_index: int, row: int, col: int) -> Dictionary:
	if run.phase != EveRunState.Phase.PREP:
		return {"ok": false, "reason": "只有准备阶段能布阵"}
	var r := run.deploy_from_bench(bench_index, row, col)
	var out := _ai_result(r)
	_refresh_run_ui()
	return out


func ai_move(field_index: int, row: int, col: int) -> Dictionary:
	if run.phase != EveRunState.Phase.PREP:
		return {"ok": false, "reason": "只有准备阶段能调位"}
	var r := run.move_field(field_index, row, col)
	var out := _ai_result(r)
	_refresh_run_ui()
	return out


func ai_recall(field_index: int) -> Dictionary:
	if run.phase != EveRunState.Phase.PREP:
		return {"ok": false, "reason": "只有准备阶段能撤回"}
	var r := run.recall_to_bench(field_index)
	var out := _ai_result(r)
	_refresh_run_ui()
	return out


func ai_sell_bench(bench_index: int) -> Dictionary:
	var r := run.sell_from_bench(bench_index)
	var out := _ai_result(r)
	_refresh_run_ui()
	return out


func ai_sell_field(field_index: int) -> Dictionary:
	var r := run.sell_from_field(field_index)
	var out := _ai_result(r)
	_refresh_run_ui()
	return out


## 姿态。⚠️ HUD 那条 `stance_changed` 信号**至今没有发射方**（UI 未接），
## 所以这里直接写 ship.stance 再刷可视 —— 与舰队出厂时改 stance 是同一条数据路径。
func ai_stance(ship_id: int, stance: int) -> Dictionary:
	if stance < 0 or stance > 4:
		return {"ok": false, "reason": "stance 只接受 0~4（接近/保持/环绕/风筝/手动）"}
	var found: EveShip = null
	for s in _get_own_ships():
		if s.id == ship_id:
			found = s
			break
	if found == null:
		return {"ok": false, "reason": "找不到 id=%d 的我方船" % ship_id}
	found.stance = stance
	var visual := arena.get_ship_visual(ship_id)
	if visual != null and visual.has_method("refresh_stance"):
		visual.refresh_stance()
	return {"ok": true, "data": {"id": ship_id, "stance": stance}}


## ── 流程 ────────────────────────────────────────────────────
func ai_start_battle() -> void:
	_on_start_battle_requested()


func ai_pause(on: bool) -> void:
	set_paused(on)


func ai_restart() -> void:
	restart_run()


func ai_back_to_menu() -> void:
	_do_back_to_menu()


func ai_fast_forward(seconds: float) -> void:
	debug_fast_forward_battle(seconds)


## 事件节点状态：四选一开着 / 选船面板开着 / 可选哪些 / 正在等谁选船。
## AI 靠它决定是发 event_choose 还是发 event_ship。
func ai_event_state() -> Dictionary:
	var pick_open := false
	if hud != null and hud.has_method("ship_pick_is_open"):
		pick_open = bool(hud.call("ship_pick_is_open"))
	return {
		"open": bool(hud.event_is_open()) if hud != null else false,
		"ship_pick_open": pick_open,
		# ★ 2026-10-31（炼狱专属抽奖）：这个窗口开着时**节点不会推进**，
		#   AI 必须发 `lottery` 才算走完事件 —— 不给这个字段，
		#   AI 会看到"事件已选、但面板全关、节点不动"，然后无限重试。
		"lottery_open": bool(_prep_phase.lottery_open),
		"options": run.event_options() if run != null else [],
		"pending_event": String(_prep_phase.pending_event),
	}


## 事件四选一。⚠️ 同样要返回真实结果（无效 / 已获取过会被拒）。
func ai_event_choose(id: StringName) -> Dictionary:
	if run == null:
		return {"ok": false, "reason": "run 未就绪"}
	if not run.can_pick_event(id):
		return {"ok": false, "reason": "这条增益选不了（已获取过或 id 无效）"}
	_prep_phase.on_event_chosen(id)
	return {"ok": true, "data": {"id": String(id)}}


## 事件节点选船。⚠️ 面板没开 / 下标越界都要说清楚。
func ai_event_ship(index: int) -> Dictionary:
	if _prep_phase.pending_event == &"":
		return {"ok": false, "reason": "当前没有等待选船的事件"}
	if index < 0 or index >= _prep_phase.ship_pick_cache.size():
		return {"ok": false, "reason": "选船下标越界（0~%d）" % (_prep_phase.ship_pick_cache.size() - 1)}
	_prep_phase.on_event_ship_picked(index)
	return {"ok": true, "data": {"index": index}}


## 抽奖窗：一次调用走完「抽取 + 点完成」。
##
## ★ 2026-10-31（炼狱专属）：AI 侧不需要"许愿"这个玩法层的东西 ——
##   它的价值全在玩家身上（许愿命中返币）。所以 AI 走空愿望，
##   直接拿 `LOTTERY_DRAW_TIMES`（= 1）艘船并推进节点。
## ⚠️ 必须**同时**返回抽到的船：AI 靠它更新自己的备战席认知，
##   只回 `{ok:true}` 会让它对"凭空多了一艘船"一无所知。
##
## ⚠️ 签名从 `(wish1, wish2)` 改成 `(wish_key, wish_star)`：
##    池子合并成一个之后，"两个愿望"这个概念已经没有对应的池了。
func ai_lottery_draw(wish_key: StringName = &"", wish_star: int = 0) -> Dictionary:
	if not bool(_prep_phase.lottery_open):
		return {"ok": false, "reason": "当前没有抽奖窗"}
	_prep_phase.on_lottery_draw(wish_key, wish_star)
	# 抽完立刻点「完成」（= 推进节点）。AI 没有"看完结果再点"的节奏需求。
	_prep_phase.on_lottery_finished()
	return {"ok": true, "data": {
		"bench": run.bench_entries() if run != null else [],
		"node": int(run.node_index) if run != null else 0,
	}}


func ai_result_next() -> void:
	_resolve_phase.on_result_next()

func ai_result_end() -> void:
	_resolve_phase.on_result_end()


## 打捞第 index 艘。
## ⚠️ 必须把 `run.salvage_order()` 的**真实结果**返回去：
##    早版本这里无条件 `return {"ok": true}`，把游戏的拒绝也吞了 ——
##    外部 AI 以为每发都成功，对着同一个下标无限重试，
##    而残骸没清空时「继续」又会一直弹确认框 ⇒ 死循环（实测卡死 454 秒）。
func ai_salvage(index: int) -> Dictionary:
	if run == null:
		return {"ok": false, "reason": "run 未就绪"}
	var r := run.salvage_order([index])
	var out := _ai_result(r)
	if not bool(out.get("ok", false)):
		# 被拒时同步一次打捞区，让下一次读到最新的残骸列表
		_refresh_salvage_area()
	return out


func ai_salvage_zero() -> void:
	_on_salvage_pick_zero()


## ── 确认框（残骸没捞完就点「继续」会弹的那个）────────────────
##
## ⚠️ 2026-10-26 实测：AI 在 RESOLVE 里反复发 result_next 却卡住不动，
##    真因就是这个弹窗在等一次确认 —— 没有这个口，AI 永远过不去结算。
func ai_dialog_state() -> Dictionary:
	var open := false
	if hud != null and hud.has_method("salvage_ask_open"):
		open = bool(hud.call("salvage_ask_open"))
	return {
		"salvage_ask_open": open,
		"any_open": open,
	}


func ai_dialog_confirm() -> Dictionary:
	if hud != null and hud.has_method("salvage_ask_open") and bool(hud.call("salvage_ask_open")):
		hud.call("confirm_salvage_ask")
		return {"ok": true}
	return {"ok": false, "reason": "没有开着的确认框"}


func ai_dialog_cancel() -> Dictionary:
	if hud != null and hud.has_method("salvage_ask_open") and bool(hud.call("salvage_ask_open")):
		hud.call("cancel_salvage_ask")
		return {"ok": true}
	return {"ok": false, "reason": "没有开着的确认框"}


## ── 相机 / 取景 ─────────────────────────────────────────────
func ai_camera(args: Dictionary) -> Dictionary:
	if arena == null or arena.orion_cam == null:
		return {"ok": false, "reason": "相机未就绪"}
	var cam: Node = arena.orion_cam
	if args.has("yaw"):
		cam.set_yaw_target(deg_to_rad(float(args["yaw"])))
	if args.has("pitch"):
		cam.set_pitch_target(deg_to_rad(float(args["pitch"])))
	if args.has("zoom"):
		cam.set_zoom_target(float(args["zoom"]))
	if args.has("focus"):
		var f: Array = args["focus"]
		if f.size() == 3:
			cam.set_focus_point(Vector3(float(f[0]), float(f[1]), float(f[2])))
	return {"ok": true, "data": {
		"yaw": rad_to_deg(cam.get_yaw()),
		"pitch": rad_to_deg(cam.get_pitch()),
		"zoom": cam.get_zoom(),
	}}


## AI：视角中心选择（与鼠标双击同一条路径，供无头验证）
##   focus_ship = <ship_id>  ⇒ 锁到那艘船
##   focus_ship = -1        ⇒ 解锁
##   focus_at = [x, y]      ⇒ 按屏幕坐标双击（船 / 空处自动分流）
func ai_focus(args: Dictionary) -> Dictionary:
	if arena == null:
		return {"ok": false, "reason": "竞技场未就绪"}
	if args.has("focus_ship"):
		var sid := int(args["focus_ship"])
		if sid < 0:
			arena.clear_camera_lock()
		else:
			var ok := arena.set_camera_lock(sid)
			if not ok:
				return {"ok": false, "reason": "没有这艘船 id=%d" % sid}
	if args.has("focus_at"):
		var f: Array = args["focus_at"]
		if f.size() == 2:
			_try_focus_at(Vector2(float(f[0]), float(f[1])))
	return {"ok": true, "data": {
		"lock_id": arena.camera_lock_id(),
		"focus": [arena.orion_cam.get_focus().x, arena.orion_cam.get_focus().y, arena.orion_cam.get_focus().z],
	}}


func ai_frame(mode: String) -> Dictionary:
	if arena == null:
		return {"ok": false, "reason": "竞技场未就绪"}
	match mode:
		"board":
			arena.frame_board()
		"own":
			arena.frame_own_zone()
		_:
			arena.frame_battlefield()
	return {"ok": true}


## ── 特效调色（2026-10-21 那套颜色接口的 AI 入口）─────────────
func ai_colors(args: Dictionary) -> Dictionary:
	if arena == null:
		return {"ok": false, "reason": "竞技场未就绪"}
	if args.has("artillery_core") and args.has("artillery_edge"):
		arena.set_artillery_colors(_ai_color(args["artillery_core"]), _ai_color(args["artillery_edge"]))
	if args.has("decal_mid") and args.has("decal_high"):
		var core := _ai_color(args.get("decal_core", [0.94, 0.99, 1.0, 1.0]))
		arena.set_shield_decal_colors(_ai_color(args["decal_mid"]), _ai_color(args["decal_high"]), core)
	return {"ok": true}


## ── 调试可见性 ──────────────────────────────────────────────
func ai_shell(on: bool) -> Dictionary:
	for s in _get_own_ships():
		var v := arena.get_ship_visual(s.id)
		if v != null and v.has_method("set_shield_shell_visible"):
			v.set_shield_shell_visible(on)
	return {"ok": true}


func ai_markers(on: bool) -> Dictionary:
	for s in _get_own_ships():
		var v := arena.get_ship_visual(s.id)
		if v != null and v.has_method("set_shield_markers_visible"):
			v.set_shield_markers_visible(on)
	return {"ok": true}




# ══════════════════════════════════════════════════════════════════
#  AI 操作面 · 鼠标层（2026-10-26）
# ══════════════════════════════════════════════════════════════════
#
# 用户定案：**不准后台操作**。AI 必须像人一样挪鼠标、点按钮、拖船。
# 所以这一层不做任何「直接调 handler」，只做两件事：
#   ① `ai_ui_map()` —— 把界面上**所有可点东西的屏幕矩形**报出来（传感器）；
#   ② `ai_mouse_*()` —— 合成真正的 InputEvent，走 Godot 的输入管线，
#      并且 `Input.warp_mouse()` 让**真实光标也跟着动**（观众才看得见）。
#
# ⚠️ 为什么必须走输入管线而不是直接 emit pressed：
#    Control 的点击要经过 GUI 命中测试（_gui_input），直接 emit 会绕过
#    悬停态 / 按下态 / 焦点，很多按钮看着点了其实没反应；
#    而拖拽布阵走的是 `_input` → `_try_begin_drag` → `_end_drag`，
#    只有真的鼠标事件序列才能驱动。

## 界面上所有可点元素的屏幕矩形。
##
## 返回：
##   {
##     "buttons": [{"name": "...", "rect": [x,y,w,h], "path": "..."}],
##     "shop_cards": [{"index": i, "rect": [...]}],
##     "bench_slots": [{"index": i, "rect": [...]}],
##     "cells": [{"row": r, "col": c, "rect": [...]}],   # 只有可放置的格
##     "viewport": [w, h]
##   }
func ai_ui_map() -> Dictionary:
	var out := {
		"buttons": [],
		"shop_cards": [],
		"bench_slots": [],
		"event_cards": [],
		"cells": [],
		"viewport": [get_viewport().get_visible_rect().size.x,
				get_viewport().get_visible_rect().size.y],
	}
	if hud == null:
		return out

	# ① 所有可见 Button（带可读名字）
	var btns: Array[Button] = []
	_collect_buttons(hud, btns)
	for b in btns:
		if not b.is_visible_in_tree() or not b.mouse_filter == Control.MOUSE_FILTER_STOP:
			continue
		var r: Rect2 = b.get_global_rect()
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		(out["buttons"] as Array).append({
				"name": _btn_label(b),
				"rect": [r.position.x, r.position.y, r.size.x, r.size.y],
				"path": String(b.get_path()),
			})

	# ② 商店 5 张卡
	var shop = hud.get("shop_window")
	if shop != null and is_instance_valid(shop):
		var row = shop.get("_cards_row")
		if row != null:
			for i in (row as HBoxContainer).get_child_count():
				var c: Control = (row as HBoxContainer).get_child(i)
				# ⚠️ 商店卡是 PanelContainer（不是 Button）—— 按 Button 过滤会一张都采不到。
				if c.is_visible_in_tree():
					var cr: Rect2 = c.get_global_rect()
					(out["shop_cards"] as Array).append({
							"index": i,
							"rect": [cr.position.x, cr.position.y, cr.size.x, cr.size.y],
							"path": String(c.get_path()),
						})

	# ③ 备战席 8 格（ EveBenchRail.slot_center_x + 自身全局矩形 ）
	var rail = hud.get("bench_rail")
	if rail != null and is_instance_valid(rail) and rail.has_method("slot_center_x"):
		var rr: Rect2 = (rail as Control).get_global_rect()
		for i in 8:
			var cx: float = rail.call("slot_center_x", i)
			(out["bench_slots"] as Array).append({
					"index": i,
					"rect": [rr.position.x + cx - 40.0, rr.position.y,
						80.0, rr.size.y],
				})

	# ③b 事件 / 选船面板的四张卡（PanelContainer，不是 Button ⇒ 单独采）
	var ew = hud.get("event_window")
	if ew != null and is_instance_valid(ew) and (ew as Control).is_visible_in_tree():
		var cs = ew.get("_cards")
		if cs is Array:
			for i in (cs as Array).size():
				var w: Dictionary = (cs as Array)[i]
				var node: Control = w.get("root")
				if node == null or not is_instance_valid(node) or not node.is_visible_in_tree():
					continue
				var er: Rect2 = node.get_global_rect()
				(out["event_cards"] as Array).append({
						"index": i,
						"rect": [er.position.x, er.position.y, er.size.x, er.size.y],
						"path": String(node.get_path()),
					})

	# ④ 棋盘格（只给「放得下」的：我方区 + 非隔离）
	if arena != null and arena.board != null:
		for row in 11:
			if not arena.board.is_mine_zone(row):
				continue
			for col in 11:
				# ⚠️ 走**游戏自己的链**：board_cell_to_meters() → world_to_screen()。
				#   它与 screen_to_cell() 是同一套单位换算的反向，
				#   自己拼 to_global + unproject 会踩单位的坑（实测两种错法：
				#   全挤在 3px 内 / 飞到屏幕外几万像素）。
				var sp: Vector2 = arena.world_to_screen(arena.board_cell_to_meters(row, col))
				(out["cells"] as Array).append({
						"row": row, "col": col,
						"rect": [sp.x - 26.0, sp.y - 26.0, 52.0, 52.0],
					})
	return out




# ══════════════════════════════════════════════════════════════════
#  鼠标层 · 坐标校准（2026-10-26）
# ══════════════════════════════════════════════════════════════════
#
# 病象：光标明明在按钮上，点到的却是旁边那个；右上角一排按钮系统性偏移，
#       左侧模式栏又不偏。
#
# 根因（读 Godot 源码 + 实测确认）：
#   `Input.warp_mouse()` 走的是 **DisplayServer**，吃的是【窗口坐标】；
#   而 `Control.get_global_rect()` 给的是【视口坐标】。
#   两者之间隔着标题栏 / 边框 / 拉伸letterbox，差值随窗口大小变化
#   （本机 2064×1191 的窗口实测差 102px）。
#
# 解法：**不信任何一方的坐标，用命中测试反查**。
#   ① `ai_calibrate_mouse()` 用一个已知控件当靶子，量出「视口坐标 → warp 坐标」
#      的修正量，缓存起来；
#   ② 之后所有 warp 都先过这个修正；
#   ③ 点击 / 拖拽前再 `ai_verify_point()` 复核一次，偏了就再修。

## 视口坐标 → warp_mouse 坐标 的修正量（0,0 = 已经对齐）
var _mouse_fix := Vector2.ZERO
var _mouse_calibrated := false


## 量一次坐标修正。用「第一个可见按钮」当靶子。
##
## 做法：把光标挪到靶子的报告中心，读 `gui_get_hovered_control()`。
## 命中 ⇒ 修正为 0；没命中 ⇒ 在附近网格里搜，找到命中的那一格，
## 用「实际命中位置 − 报告中心」当修正量。
## [versus] Battle over -> settle multiplayer damage and advance the round.
##
## Called from the resolve phase right after resolve_battle(), so the
## single-player beacon/salvage flow is untouched. In versus mode we
## additionally apply the TFT-style rule: the loser loses
## (opponent surviving ships) x (round weight) HP.
## [versus] build the room: 1 human (this scene run) + N AI players.
func _setup_versus(ai_count: int) -> void:
	var players: Array = []
	players.append(MATCH_PLAYER_SCRIPT.new(run, "你", false))
	var names := ["AI-铁猫", "AI-秃鹫", "AI-巨像", "AI-夜鹰",
		"AI-毒蝎", "AI-狂徒", "AI-幽灵"]
	for i in mini(ai_count, names.size()):
		var r2 = RUN_STATE_SCRIPT.new()
		r2.name = "AiRun_%d" % i
		add_child(r2)
		r2.start_run()
		var p2 = MATCH_PLAYER_SCRIPT.new(r2, String(names[i]), true)
		p2.brain = AI_BRAIN_SCRIPT.new("inferno")
		players.append(p2)
	versus = MATCH_STATE_SCRIPT.new(players, randi())
	print("[versus] room: 1 human + %d AI, %d rounds" % [ai_count, MATCH_STATE_SCRIPT.TOTAL_ROUNDS])
	_apply_versus_rules()
	# 结算页只留打捞：推进交给回合倒计时（心理博弈的一部分）。
	var rw = hud.get_node_or_null("Result")
	if rw != null and rw.has_method("set_versus_mode"):
		rw.set_versus_mode(true)
	hud.append_log({"time": 0.0, "category": &"system",
			"text": "联机对战：1 人类 + %d AI · %d 回合" % [ai_count, MATCH_STATE_SCRIPT.TOTAL_ROUNDS]})


## [versus] every AI player takes one prep turn. The human uses the mouse.
## 回合时钟下限校验。
##
## ⚠️ 2026-10-28 实测教训：把 `ROUND_TIME` 临时压到 12s 时，
##    **准备阶段（30s）还没走完时钟就归零** ⇒ 每回合直接超时推进，
##    一路冲到第 8 回合、一枪没打。
##    ⇒ 「倒计时是唯一裁判」的成立前提：时钟 > 准备 + 最长战斗时限。
func _versus_check_round_time() -> void:
	# ⚠️ 别把 60 写死：战斗时限的唯一真源是 `EveNodeTable.BATTLE_SECONDS`
	#    （2026-10-28 起统一 60s）。写死的话，以后改时限这里会继续"通过"，
	#    而实际已经退化。
	var need := PREP_SECONDS + EveNodeTable.BATTLE_SECONDS
	if EveMatchState.ROUND_TIME <= need:
		var msg := "回合时钟 %.0fs ≤ 准备 %.0fs + 战斗 %.0fs ⇒ 会退化成「永远判负」或「零打捞时间」" % [EveMatchState.ROUND_TIME, PREP_SECONDS, EveNodeTable.BATTLE_SECONDS]
		push_warning("[versus] " + msg)
		print("[versus] WARN " + msg)


## ★★ 联机对战的**通用规则**（2026-10-27 用户定案 + 2026-10-28 补漏）。
##
## 规则本身：**撤掉开战键，一切以倒计时为最终判断**；最后 10 秒中央放大读秒。
##
## ⛔ 为什么必须收成一个函数：这条规则曾在 `_setup_versus()`（1 人类 + AI）里
##    单独实现，而 `_setup_versus_by_slots()`（从联机大厅进局）**漏了**
##    ⇒ 用户从大厅进局又看见开战键，以为是「被人改回来了」。
##    ⇒ 以后新增任何建局路径，都只调这里，⛔ 别在各处重写那两行。
##
## ⚠️ 两道都要设：
##    ① `auto_start_on_timeout = true` —— 倒计时归零必须自动开战，
##       否则撤了按钮就变成「永远开不了打」。
##    ② 按钮整个藏起来 —— 不给任何人提前开打的入口（那是快进开关）。
##    ③ 中央倒计时只在联机开（单机仍要手动开战，大字会挡布阵）。
func _apply_versus_rules() -> void:
	auto_start_on_timeout = true
	# ★ 2026-10-28 用户定案：多人 PvE 回合的**电脑舰队**一律按炼狱档算
	#   （吃羁绊 · 按阵型站位 · 强度 ×1.40），与主菜单选的难度无关。
	#   ⚠️ 必须在 `begin_prep()` **之前**生效：敌方舰队是准备阶段建出来的。
	#   ⛔ 不改 `difficulty_id` —— 那会把玩家自己的收入 / 利息 / 败亡代价
	#      一起换成炼狱口径（多人经济仍按主菜单选的档走）。
	run.enemy_tier_override = EveMatchState.PVE_DIFFICULTY
	if hud == null:
		return
	if hud.has_method("set_start_visible"):
		hud.set_start_visible(false)
	if hud.has_method("set_round_countdown_active"):
		hud.set_round_countdown_active(true)


## 按座位表建局。`my_seat` = 本机占的那一位。
##
## ⚠️ 玩家数组**下标必须等于座位下标** —— 两台机器各自建局，
##    只有下标对齐，配对结果与血量才可能一致。
func _setup_versus_by_slots(slots: Array, my_seat: int) -> void:
	var players: Array = []
	for i in slots.size():
		var kind := String((slots[i] as Dictionary).get("kind", "ai"))
		if i == my_seat:
			players.append(MATCH_PLAYER_SCRIPT.new(run, "你", false))
			continue
		var r2 = RUN_STATE_SCRIPT.new()
		r2.name = "SlotRun_%d" % i
		add_child(r2)
		r2.start_run()
		var nm := ("电脑 %d" % (i + 1)) if kind == "ai" else ("玩家 %d" % (i + 1))
		# 远端真人本地也按「AI 位」处理：编制由网络送进来，
		# 本地那份 run 只用来记账（血量 / 存活）。
		var p2 = MATCH_PLAYER_SCRIPT.new(r2, nm, true)
		p2.brain = AI_BRAIN_SCRIPT.new("inferno")
		players.append(p2)
	_versus_check_round_time()
	versus = MATCH_STATE_SCRIPT.new(players, randi())
	print("[versus] 按座位建局：%d 位（我 = %d）" % [players.size(), my_seat])
	_apply_versus_rules()
	# 验收专用：--start-round=N 直接快进到第 N 回合（联机 PvP 验收要跳到 2-2）。
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--start-round="):
			var skip := int(a.split("=")[1])
			for k in maxi(0, skip - 1):
				versus._next_round()
			print("[versus] 快进到 round=%d（%s）" % [versus.global_round(), versus.round_label()])
			break


func _run_ai_prep_turns() -> void:
	if versus == null:
		return
	for pr in versus.players:
		if pr == null or not pr.is_ai or pr.brain == null:
			continue
		if not pr.is_alive():
			continue
		pr.brain.take_prep_turn(pr.run)


## [versus] 战斗结束 → 结算联机伤害并推进回合。
##
## ⚠️ `own_alive` / `foe_alive` 带默认值 **-1（= 未知，由本函数自己数）**：
##   `eve_phase_battle` 的 `battle_finished` 包装只传 `(winner_team)` 一个参数
##   （它认识 sim，不认识双方存活数），而 `_versus_settle` 原来要求 3 个参数 ⇒
##   运行时 `Invalid call ... Expected 3 argument(s)`，**整条结算链断掉**：
##   结算页、伤害分配、回合推进全都不执行（表现为「打完没反应」）。
##   ⇒ 少给参数时自己从模拟器数，调用方给就给。
## [versus] push round / kind / everyone HP into the command bar.
## [versus] match over -> rank everyone and report.
func _versus_finish() -> void:
	if versus == null:
		return
	var rows: Array = []
	for q in versus.players:
		if q == null:
			continue
		rows.append({
			"name": q.display_name, "hp": q.hp,
			"is_ai": q.is_ai, "alive": q.is_alive(),
		})
	# survivors first (higher HP wins), eliminated last
	rows.sort_custom(func(a, b):
		if bool(a["alive"]) != bool(b["alive"]):
			return bool(a["alive"])
		return int(a["hp"]) > int(b["hp"]))
	var line := ""
	for i in rows.size():
		var rr = rows[i]
		var tg := "[AI]" if bool(rr.get("is_ai", false)) else ""
		var st := "存活" if bool(rr.get("alive", false)) else "淘汰"
		line += "%d.%s%s(%s %d)  " % [i + 1, tg, String(rr.get("name","?")), st, int(rr.get("hp",0))]
	var msg := "联机对战结束 · " + line
	# Pop the ranking panel (the single-player result window is reused:
	# same frame, same buttons, only the content swaps).
	# The HUD does not forward show_result; the battle scene reaches the
	# window directly, so do the same for the ranking panel.
	var rw = hud.get_node_or_null("Result")
	if rw != null and rw.has_method("show_versus_ranking"):
		rw.show_versus_ranking(rows, versus.round_label())
	hud.append_log({"time": 0.0, "category": &"system", "text": msg})
	print("[versus] over: " + line)


## [versus] show the round clock in the command bar.
func _refresh_versus_clock() -> void:
	if versus == null or hud == null:
		return
	var cb = hud.get_node_or_null("CommandBar")
	if cb == null:
		return
	var left: float = maxf(0.0, EveMatchState.ROUND_TIME - versus.round_elapsed)
	var mm := int(left / 60.0)
	var ss := int(left) % 60
	if cb.has_method("set_versus_clock"):
		cb.set_versus_clock("%d:%02d" % [mm, ss], versus.round_timed_out())


func _refresh_versus_hud() -> void:
	if versus == null or hud == null:
		return
	var rows: Array = []
	for q in versus.players:
		if q == null:
			continue
		rows.append({
			"name": q.display_name, "hp": q.hp,
			"is_ai": q.is_ai, "alive": q.is_alive(),
		})
	var kind := versus.round_kind()
	var kn := "打怪"
	if kind == EveMatchState.RoundKind.PVP:
		kn = "PvP"
	elif kind == EveMatchState.RoundKind.CAROUSEL:
		kn = "事件"
	elif kind == EveMatchState.RoundKind.BOSS:
		kn = "BOSS"
	# Find the command bar by name instead of guessing a hud forwarder:
	# the bar lives at Hud/CommandBar/... and exposes set_versus().
	var cb = hud.get_node_or_null("CommandBar")
	if cb == null:
		# fall back to a search in case the path differs
		var st: Array[Node] = [hud]
		while not st.is_empty():
			var nd: Node = st.pop_back()
			if nd != hud and nd.has_method("set_versus"):
				cb = nd
				break
			for ch in nd.get_children():
				st.append(ch)
	if cb != null and cb.has_method("set_versus"):
		cb.set_versus(versus.round_label(), kn, rows)


func _versus_settle(winner_team: int, own_alive: int = -1, foe_alive: int = -1) -> void:
	if versus == null:
		return
	if own_alive < 0 or foe_alive < 0:
		own_alive = 0
		foe_alive = 0
		if sim != null:
			for s in sim.ships:
				if not s.alive:
					continue
				if s.team == 0:
					own_alive += 1
				else:
					foe_alive += 1
	var kind := versus.round_kind()
	if kind == EveMatchState.RoundKind.PVP:
		var opp: int = versus.human_opponent()
		if opp < 0:
			# bye round: no fight, no damage
			return
		var me: int = -1
		for i in versus.players.size():
			var pr = versus.players[i]
			if pr != null and not pr.is_ai:
				me = i
				break
		if me < 0:
			return
		var win := -1
		if winner_team == 0:
			win = me
		elif winner_team == 1:
			win = opp
		versus.apply_outcome({
			"a": me, "b": opp, "winner": win,
			"a_alive": own_alive, "b_alive": foe_alive })
	else:
		# PvE / BOSS: the human fights the scripted comp
		var me2: int = -1
		for i in versus.players.size():
			var pr2 = versus.players[i]
			if pr2 != null and not pr2.is_ai:
				me2 = i
				break
		if me2 < 0:
			return
		versus.apply_outcome({
			"a": me2, "b": -1, "a_won": (winner_team == 0),
			"a_alive": own_alive, "b_alive": foe_alive })
	# ★★ 2026-10-27 用户定案：结算页不推进，**推进由回合倒计时决定**。
	#  「如果它打完，倒计时也结束了，那就到下一回合，没时间让他选打捞」
	#  ⇒ 这里只登记「本回合已打完」，真正的 _next_round 在
	#     _versus_advance_round()（倒计时归零 / 或时钟已耗尽时立刻）里做。
	_refresh_versus_hud()
	# 房主权威血量广播（在任何提前 return 之前发，保证客户端总能收到）
	_versus_broadcast_sync()
	# match over -> rank everyone, then stop driving rounds so the
	# single-player EVACUATED ending does not mask the versus ranking.
	if versus.finished:
		_versus_finish()
		return
	_versus_await_result = true
	if versus.round_timed_out():
		# 打完的那一刻时钟也走完了 ⇒ 一秒都不给留，直接进下一回合。
		_versus_advance_round()
		return
	var pr3 := versus.progress()
	var hp_line := ""
	for i in versus.players.size():
		var q = versus.players[i]
		if q == null:
			continue
		hp_line += "%s=%d  " % [q.display_name, q.hp]
	hud.append_log({"time": 0.0, "category": &"system",
			"text": "[versus] %s-%d  |  %s" % [str(pr3.get("stage",0)), int(pr3.get("round",0)), hp_line]})

func ai_calibrate_mouse() -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "reason": "no viewport"}
	var target: Control = null
	var btns: Array[Button] = []
	_collect_buttons(hud if hud != null else self, btns)
	for b in btns:
		if b.is_visible_in_tree() and b.mouse_filter == Control.MOUSE_FILTER_STOP:
			target = b
			break
	if target == null:
		_mouse_calibrated = true
		_mouse_fix = Vector2.ZERO
		return {"ok": true, "data": {"fix": [0, 0], "note": "no target, assume aligned"}}

	var r: Rect2 = target.get_global_rect()
	var c := r.position + r.size * 0.5
	_mouse_fix = Vector2.ZERO
	if await _hit_at(c) == target:
		_mouse_calibrated = true
		return {"ok": true, "data": {"fix": [0, 0], "target": String(target.name)}}

	# 搜：以报告中心为原点，±160 范围内按 20px 网格找
	var best := Vector2.ZERO
	for ring in range(1, 9):
		var step := 20.0 * float(ring)
		for a in range(8):
			var ang := float(a) * PI * 0.25
			var p := c + Vector2(cos(ang), sin(ang)) * step
			if await _hit_at(p) == target:
				best = p - c
				break
		if best != Vector2.ZERO:
			break
	if best == Vector2.ZERO:
		# 找不到就保持 0，调用方会退化为螺旋搜索
		_mouse_calibrated = true
		return {"ok": true, "data": {"fix": [0, 0], "note": "target not found nearby"}}
	_mouse_fix = best
	_mouse_calibrated = true
	return {"ok": true, "data": {
		"fix": [best.x, best.y],
		"target": String(target.name),
		"reported_center": [c.x, c.y],
		"real_center": [c.x + best.x, c.y + best.y],
	}}



# ══════════════════════════════════════════════════════════════════
#  AI 操作的可视光标（不抢用户物理鼠标）
# ══════════════════════════════════════════════════════════════════
# 2026-10-27：用户要求「模拟鼠标操作，不是真的拿鼠标去操作」。
# 所以不再 warp 真实光标，改为在游戏内画一个指示器 —— 用户既看得见 AI 在点哪里，
# 又随时能拿回自己的鼠标。

var _cursor_layer: CanvasLayer = null
var _cursor_visual: ColorRect = null
var _cursor_on := true
## 光标托管：AI 注入事件后把 OS 光标还回用户原位。
## Godot 收到注入的 motion 会把 OS 光标同步过去（引擎行为，绕不开），
## 只能「用完即还」—— 用户随时能拿回自己的鼠标。
var _cursor_locked := false
var _cursor_home := Vector2.ZERO
## 还原窗口：注入事件后引擎会把 OS 光标同步过去，只能在随后几帧持续还原压住它。
var _cursor_restore_ms := 0.0


func _ensure_cursor_visual() -> void:
	if _cursor_visual != null and is_instance_valid(_cursor_visual):
		return
	_cursor_layer = CanvasLayer.new()
	_cursor_layer.layer = 128          # 压在 HUD 之上，但不吃输入
	add_child(_cursor_layer)
	var ring := ColorRect.new()
	ring.color = Color(1.0, 0.82, 0.15, 0.28)
	ring.size = Vector2(26, 26)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_layer.add_child(ring)
	_cursor_visual = ColorRect.new()
	_cursor_visual.color = Color(1.0, 0.92, 0.35, 0.95)
	_cursor_visual.size = Vector2(9, 9)
	_cursor_visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_layer.add_child(_cursor_visual)
	_cursor_visual.set_meta("ring", ring)


func _show_cursor(p: Vector2) -> void:
	if not _cursor_on:
		return
	_ensure_cursor_visual()
	if _cursor_visual == null:
		return
	var ring: ColorRect = _cursor_visual.get_meta("ring")
	_cursor_visual.position = p - _cursor_visual.size * 0.5
	ring.position = p - ring.size * 0.5


## 开始托管光标：记住用户当前光标位置，之后每次注入都还原到它。
func ai_cursor_lock(on: bool) -> Dictionary:
	_cursor_locked = on
	if on:
		_cursor_home = DisplayServer.mouse_get_position()
		_cursor_restore_ms = 0.0
	return {"ok": true, "data": {"home": [_cursor_home.x, _cursor_home.y], "locked": on}}


## 开关 AI 指示光标（验收 / 用户自己想看干净画面时用）
func ai_cursor_visible(on: bool) -> Dictionary:
	_cursor_on = on
	if not on and _cursor_visual != null and is_instance_valid(_cursor_visual):
		_cursor_visual.visible = false
		var ring: ColorRect = _cursor_visual.get_meta("ring")
		if ring != null:
			ring.visible = false
	return {"ok": true, "data": {"on": on}}


## 把光标挪到 (x,y) 并回报那一格到底命中谁。内部用。
func _hit_at(p: Vector2) -> Control:
	# ⛔ 不 warp 真实光标（不和用户抢鼠标），只推事件
	var m := InputEventMouseMotion.new()
	m.position = p
	m.global_position = p
	m.relative = Vector2.ZERO
	Input.parse_input_event(m)
	# 等两帧，让 hover 状态更新
	# （只等一帧会读到上一次的位置 —— 这就是「偏移」的另一个来源）
	await get_tree().create_timer(0.05).timeout
	var vp := get_viewport()
	return vp.gui_get_hovered_control() if vp != null else null


## 把光标挪到 (x,y) 并回报**真正命中**的控件（诊断用）。
func ai_hover(x: float, y: float) -> Dictionary:
	ai_mouse_move(x, y)
	await get_tree().create_timer(0.12).timeout
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "reason": "no viewport"}
	var c := vp.gui_get_hovered_control()
	var out := {"ok": true, "data": {
		"asked": [x, y],
		"hovered": String(c.name) if c != null else "",
		"hovered_text": (c.text.strip_edges() if (c is Button) else ""),
	}}
	if c != null:
		var gr: Rect2 = c.get_global_rect()
		out["data"]["hovered_rect"] = [gr.position.x, gr.position.y, gr.size.x, gr.size.y]
	return out


## 对外：光标挪到视口坐标 (x,y)（自动过修正量）。
func ai_mouse_move_vp(x: float, y: float) -> Dictionary:
	if not _mouse_calibrated:
		await ai_calibrate_mouse()
	return ai_mouse_move(x + _mouse_fix.x, y + _mouse_fix.y)


## 求某个棋盘格的**真实屏幕位置**。
##
## ⚠️ 为什么不直接用 ui_map 里的 rect：那张图是「设计空间」的投影，
##    而 warp_mouse 吃窗口坐标，且棋盘只在拖拽中才入画、取景还要收敛。##    所以这里用**游戏自己的反函数** `arena.screen_to_cell()` 当场验：
##    从 ui_map 给的估计位置出发螺旋搜，找到「screen_to_cell 真的返回这一格」的点。
##
## 前提：棋盘已入画（拖拽进行中）。没入画时返回估计值 + found=false。
func ai_cell_point(row: int, col: int) -> Dictionary:
	if arena == null or arena.board == null:
		return {"ok": false, "reason": "board 未就绪"}
	var guess := arena.world_to_screen(arena.board_cell_to_meters(row, col))
	var result := {"ok": true, "data": {
			"row": row, "col": col,
			"x": guess.x, "y": guess.y,
			"found": false,
		}}
	if not arena.board.visible:
		return result          # 棋盘没入画，只能用估计值
	var target := Vector2i(row, col)
	# 先试估计点
	if arena.screen_to_cell(guess) == target:
		(result["data"] as Dictionary)["found"] = true
		return result
	# 螺旋搜：格子约 52px，按 26px 步长扩 12 圈足够覆盖一整格
	for ring in range(1, 13):
		var step := 26.0 * float(ring)
		for a in range(8):
			var ang := float(a) * PI * 0.25
			var p := guess + Vector2(cos(ang), sin(ang)) * step
			if arena.screen_to_cell(p) == target:
				(result["data"] as Dictionary)["x"] = p.x
				(result["data"] as Dictionary)["y"] = p.y
				(result["data"] as Dictionary)["found"] = true
				return result
	return result


## 复核：这个视口坐标点是否真的命中目标控件。
func ai_verify_point(x: float, y: float, path: String) -> Dictionary:
	var n := get_node_or_null(NodePath(path))
	if n == null or not (n is Control):
		return {"ok": false, "reason": "no control " + path}
	var p := Vector2(x, y) + _mouse_fix
	var hit := await _hit_at(p)
	return {"ok": hit == n, "data": {"asked": [x, y], "fix": [_mouse_fix.x, _mouse_fix.y],
		"hit": String(hit.name) if hit != null else ""}}


## 按**节点路径**点某个控件（自带坐标校准，见 eve_main_menu.ai_ui_click 的说明）。
## AI 从 ui_map 拿到 path，这里负责「点什么中什么」。
func ai_ui_click_path(path: String) -> Dictionary:
	var n := get_node_or_null(NodePath(path))
	if n == null or not (n is Control):
		return {"ok": false, "reason": "找不到控件 %s" % path}
	var c := n as Control
	if not c.is_visible_in_tree():
		return {"ok": false, "reason": "控件不可见 %s" % path}
	var r: Rect2 = c.get_global_rect()
	var cx := r.position.x + r.size.x * 0.5
	var cy := r.position.y + r.size.y * 0.5
	var hit := Vector2(cx, cy)
	var calibrated := false

	# ⓿ 已经量过偏移 ⇒ 先试「中心 + 偏移」。
	#    对真正的 Button 再用命中测试复核一次（Button 的 mouse_filter 是 STOP，
	#    hover 能报出它）；PanelContainer 这类永远报不出来，就不复核，直接点。
	if _mouse_calibrated and _mouse_fix != Vector2.ZERO:
		var guess := Vector2(cx + _mouse_fix.x, cy + _mouse_fix.y)
		var need_check := c is BaseButton
		var ok_guess := true
		if need_check:
			ok_guess = await _hit_at(guess) == c
		if ok_guess:
			var res0: Dictionary = await ai_mouse_click(guess.x, guess.y)
			res0["data"]["path"] = path
			res0["data"]["calibrated"] = true
			return res0
		# 复核没过 ⇒ 落到下面的螺旋搜索（带上偏移量当起点）
		cx = guess.x - _mouse_fix.x
		cy = guess.y - _mouse_fix.y

	for ring in range(0, 10):
		var pts: Array = []
		if ring == 0:
			pts.append(Vector2(cx, cy))
		else:
			var step := 14.0 * float(ring)
			for a in range(8):
				var ang := float(a) * PI * 0.25
				pts.append(Vector2(cx + cos(ang) * step, cy + sin(ang) * step))
		for q in pts:
			ai_mouse_move(q.x, q.y)
			await get_tree().create_timer(0.05).timeout
			if get_viewport().gui_get_hovered_control() == c:
				hit = q
				calibrated = true
				break
		# 起点也是候选：即使 hover 复核不了（PanelContainer），也允许直接点中心
		if not calibrated and ring == 0:
			calibrated = true
		if calibrated:
			break
	var res: Dictionary = await ai_mouse_click(hit.x, hit.y)
	res["data"]["path"] = path
	res["data"]["calibrated"] = calibrated
	return res


## 用鼠标关掉设置窗（误点「≡」打开时用）。
##
## ⚠️ 为什么需要：开战按钮和设置按钮在顶条上紧邻，偏移算错就会点到设置；
##    设置窗开着时其它点击全被它吃掉，所以必须**自己关掉**才能继续。
func ai_close_settings() -> Dictionary:
	if hud == null or not hud.settings_is_open():
		return {"ok": true, "data": {"closed": false}}
	# 找设置窗里的 CloseBtn（EveWindow 头部右上角，20x18）
	var found: Control = null
	var stack: Array[Node] = [hud]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		if String(nd.name) == "CloseBtn" and nd is Control \
				and (nd as Control).is_visible_in_tree() \
				and (nd as Control).mouse_filter == Control.MOUSE_FILTER_STOP:
			found = nd as Control
			break
		for c in nd.get_children():
			stack.append(c)
	if found == null:
		return {"ok": false, "reason": "找不到设置窗的关闭按钮"}
	var res: Dictionary = await ai_ui_click_path(String(found.get_path()))
	await get_tree().create_timer(0.3).timeout
	res["data"]["closed"] = hud.settings_is_open() == false
	return res


## 按名字 / 文字点按钮（战斗界面用）。
func ai_ui_click(query: String) -> Dictionary:
	var q := query.strip_edges()
	var all: Array[Button] = []
	if hud != null:
		_collect_buttons(hud, all)
	# ⚠️ 必须过滤「真实可见」：暂停遮罩里也有一个「继续」，名字一样但不该被点到
	#    （实测：点结算页的「继续 · 下一节点」结果命中了 PauseVeil 里的隐藏按钮）。
	var btns: Array[Button] = []
	for b in all:
		if b.is_visible_in_tree() and b.mouse_filter == Control.MOUSE_FILTER_STOP:
			btns.append(b)
	var pick: Button = null
	for b in btns:
		if String(b.name) == q:
			pick = b
			break
	if pick == null:
		for b in btns:
			if b.text.strip_edges() == q:
				pick = b
				break
	if pick == null:
		for b in btns:
			if q in b.text or q in String(b.name):
				pick = b
				break
	if pick == null:
		return {"ok": false, "reason": "找不到按钮「%s」" % query}
	return await ai_ui_click_path(String(pick.get_path()))


func _btn_label(b: Button) -> String:
	var t := b.text.strip_edges()
	if t != "":
		return t
	return String(b.name)


func _collect_buttons(n: Node, out: Array[Button]) -> void:
	if n is Button:
		out.append(n)
	for c in n.get_children():
		_collect_buttons(c, out)


## ── 合成鼠标事件 ─────────────────────────────────────────────
##
## ⚠️ 三步缺一不可：
##   ① `Input.warp_mouse()` 挪**真实光标**（观众看得见，且 GUI 命中测试用它）；
##   ② 先发一条 `InputEventMouseMotion`，让悬停态 / _process 里的跟随逻辑跟上；
##   ③ 再发 button down/up。直接发 down 会被当成「光标瞬移后猛点」，
##      某些 Control 的悬停高亮会跳。
func ai_mouse_move(x: float, y: float) -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "reason": "no viewport"}
	var p := Vector2(clampf(x, 0.0, vp.get_visible_rect().size.x),
			clampf(y, 0.0, vp.get_visible_rect().size.y))
	# ⛔ 不抢用户光标：只推事件，不 warp
	var m := InputEventMouseMotion.new()
	m.position = p
	m.global_position = p
	m.relative = Vector2.ZERO
	# ⛔ motion 走 parse_input_event（只更新 hover，不同步 OS 光标）；
	#    按钮走 push_input（才驱动 Button 按下）。两者混用是唯一不抢鼠标的组合。
	Input.parse_input_event(m)
	_show_cursor(p)
	return {"ok": true, "data": {"x": p.x, "y": p.y}}


## 走一条折线（拖拽 / 让人看见光标在移动）。
func ai_mouse_path(points: Array, hold: bool = false) -> Dictionary:
	if points.is_empty():
		return {"ok": false, "reason": "空路径"}
	for i in points.size():
		var pt: Vector2 = points[i]
		if hold and i == 0:
			_press(true)
		ai_mouse_move(pt.x, pt.y)
		# 每段之间空一拍，让光标「走得见」而不是闪现
		await get_tree().create_timer(0.03).timeout
	if hold:
		_press(false)
	return {"ok": true}


## 只按下 / 只松手（分阶段拖拽用）。
##
## ⚠️ 为什么需要拆开：棋盘只在**拖拽进行中**才入画
##    （`_begin_drag_visual()` → `show_board_for_deploy()`），取景还要平滑收敛。
##    所以布阵必须是四步：按下（棋盘出现）→ 等收敛 → 读格子 → 移动 → 松手。
##    一口气拖完（mouse_drag）在棋盘还没入画时就拿到了错误的格子坐标。
func ai_mouse_down(x: float, y: float, button: int = MOUSE_BUTTON_LEFT) -> Dictionary:
	ai_mouse_move(x, y)
	await get_tree().create_timer(0.05).timeout
	_press(true, button, Vector2(x, y))
	return {"ok": true, "data": {"x": x, "y": y}}


func ai_mouse_up(x: float, y: float, button: int = MOUSE_BUTTON_LEFT) -> Dictionary:
	_press(false, button, Vector2(x, y))
	return {"ok": true, "data": {"x": x, "y": y}}


func ai_mouse_click(x: float, y: float, button: int = MOUSE_BUTTON_LEFT) -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "reason": "no viewport"}
	var sz := vp.get_visible_rect().size
	var p := Vector2(clampf(x, 0.0, sz.x), clampf(y, 0.0, sz.y))
	# ⚠️ 必须先发一次 motion：GUI 的鼠标焦点要靠它建立，
	#    否则 press 送出去了但没人接收（商店卡就点不动）。
	#    motion 走 parse_input_event —— 只更新 hover，**不同步 OS 光标**。
	var mm := InputEventMouseMotion.new()
	mm.position = p
	mm.global_position = p
	mm.relative = Vector2.ZERO
	Input.parse_input_event(mm)
	_press(true, button, p)
	await get_tree().create_timer(0.06).timeout
	_press(false, button, p)
	if _cursor_locked:
		_cursor_restore_ms = 400.0
	_show_cursor(p)
	return {"ok": true, "data": {"x": p.x, "y": p.y}}


## 拖拽：从 a 按下，沿路径移动到 b，松手。布阵就用它。
func ai_mouse_drag(ax: float, ay: float, bx: float, by: float, steps: int = 12) -> Dictionary:
	ai_mouse_move(ax, ay)
	await get_tree().create_timer(0.08).timeout
	_press(true)
	await get_tree().create_timer(0.06).timeout
	var pts: Array = []
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		pts.append(Vector2(lerpf(ax, bx, t), lerpf(ay, by, t)))
	await ai_mouse_path(pts, false)
	await get_tree().create_timer(0.06).timeout
	_press(false)
	return {"ok": true}


## ⚠️ 坐标必须显式传进来，不能回读 vp.get_mouse_position()：
##    warp_mouse 之后要等几帧才反映到 Viewport._mouse_pos，回读会拿到旧位置。
func _press(down: bool, button: int = MOUSE_BUTTON_LEFT, p: Variant = null) -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var pos: Vector2 = p if p is Vector2 else vp.get_mouse_position()
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = down
	ev.position = pos
	ev.global_position = pos
	# ⚠️ button_mask 必须给：Godot 的 GUI 判定「按住」状态用它，
	#    缺了会出现「hover 命中了、press 也发了，但按钮不触发」。
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	# ⚠️ 用 Viewport.push_input 而不是 Input.parse_input_event：
	#    GUI（Control 命中 + Button 按下判定）走视口输入队列，
	#    实测 parse_input_event 能让 hover 变、但 press 不触发按钮。
	vp.push_input(ev, true)


## ── 内部 ────────────────────────────────────────────────────
func _ai_result(r: Dictionary) -> Dictionary:
	var out := r.duplicate()
	out["ok"] = bool(r.get("ok", false))
	return out


func _ai_color(v: Variant) -> Color:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	if v is String:
		return Color(String(v))
	return Color.WHITE


# ══════════════════════════════════════════════════════════════
#  真联机（真人）：回合编制交换
# ══════════════════════════════════════════════════════════════
#  开打那一刻每台机器广播 FLEET {seat, round, entries}；
#  收到别人的编制就存起来，PvP 时用它造船当对手。
#  ⚠️ 只同步「谁在场上 / 什么船 / 几星」—— 对手的 run 不在这台机器上，
#     羁绊只能用 apply_fleet_traits 近似（见 EveFleetFactory.build_from_entries）。
#  ⚠️ 血量/配对：各机器按**同一张座位表**本地推进（结果一致）；
#     房主权威校正（SYNC）还没接，见 _versus_net_tick 的 TODO。
var _vtr = null
var _vnet = null
var _vonline := false
var _vseat := 0
var _vhost := false
## 房主「开赛」前的等待宽限（毫秒）：等加入方的 ENet 连上；没人来就直接开。
##
## ★ 2026-10-28 房主权威：房主点「开始对战」后不是立刻开打，而是先等对端把
##   ENet 连上（最多这么久），然后把 START 广播出去、自己才开始第 1 回合。
##   ⚠️ 太短 ⇒ 慢一点的手机还没连上就已经开打（就是这次要修的问题）；
##      太长 ⇒ 房主一个人干等。1.5s 覆盖「手机 ENet 首次握手」的常见耗时。
const VERSUS_START_GRACE_MS := 1500

## 本机是否已**真正开始第 1 回合**（房主：发了 START；客户端：收到 START）。
var _vstarted := false
## 联机进战场后是否要先等 START（不跑倒计时、不判负）。
## 单机恒 false ⇒ 行为一个字节不变。
var _vawait_start := false
## 房主：ENet 起来之后是否已经看到过至少一个对端。
var _vpeer_seen := false
## 房主 ENet 起来的时刻（毫秒，算宽限用）。
var _vhost_up_ms := 0
## 客户端：ENet 是否已连上房主 / 上次重连的时刻（隧道里房主可能还没起服务端）。
var _vjoined := false
var _vjoin_retry_ms := 0
## 是否走隧道（决定客户端重连的目标与端口）。
var _vuse_tunnel := false
## 等房主开赛时的全屏提示层（只有加入方会看到）。
var _vwait_layer: CanvasLayer = null
## ★ 2026-10-28 中转模式：本机 UDP 转发器（`scripts/net/eve_udp_relay.gd`）与开关。
var _vrelay = null
var _vrelay_mode := false
## round -> {seat: Array entries}
var _vfleets := {}
## 上次广播编制的时刻（毫秒）。准备阶段每秒发一次，保证对手随时有最新快照。
var _vfleet_last_ms := 0
## 验收专用：`--autodeploy` 让本地玩家在准备阶段自动走一遍 AI 的准备回合，
## 这样无头跑联机时场上有船，编制不为空（正常玩没有这个参数）。
var _autodeploy := false


func _versus_online_setup() -> void:
	_autodeploy = OS.get_cmdline_user_args().has("--autodeploy")
	var role := String(RUN_STORE.pending_versus_role)
	if role == "":
		return
	_vonline = true
	_vhost = (String(RUN_STORE.pending_versus_role) == "host")
	_vseat = int(RUN_STORE.pending_versus_my_seat)
	var use_tunnel := bool(RUN_STORE.pending_versus_tunnel)
	## ★ 2026-10-28：中转模式 —— 两端都连公网 UDP 中继，手机因此不需要 TUN。
	var use_relay := bool(RUN_STORE.pending_versus_relay)
	RUN_STORE.pending_versus_relay = false
	_vrelay_mode = use_relay
	_vuse_tunnel = use_tunnel
	# ★ 2026-10-28 房主权威：**联机一律先等 START**（单机不进本函数，行为不变）。
	#   · 房主：等对端连上（宽限 `VERSUS_START_GRACE_MS`）后自己发 START；
	#   · 加入方：等房主广播的 START（隧道里房主可能还没点开始 ⇒ 要重连）。
	_vawait_start = true
	_vstarted = false
	_vnet = VNET_SCRIPT.new()
	# 隧道与中转都走 **ENet(UDP)**；只有局域网直连走 TCP 那套。
	if use_tunnel or use_relay:
		_vtr = VENET_SCRIPT.new()
	else:
		_vtr = VTR_SCRIPT.new()
	add_child(_vtr)
	_vtr.set_process(false)
	_vnet.attach_transport(_vtr)
	# 房主：看到对端连上就记一笔（宽限因此可以提前结束）
	if _vhost:
		_vtr.peer_joined.connect(func(pid: int):
			if pid != 1:
				_vpeer_seen = true
				print("[versus-net] 对端连上 peer=%d" % pid)
				# ★ 迟到加入：房主已经开赛了 ⇒ 立刻把 START / 当前回合补发一次，
				#   否则这台机器会一直停在「等待房主开始…」（它错过了那条广播）。
				if _vstarted:
					_versus_announce_round())
	else:
		_vtr.connected_ok.connect(func():
			_vjoined = true
			print("[versus-net] 已连上房主，等 START"))
	if use_relay:
		_start_relay_transport()
		return
	if use_tunnel:
		# 隧道已把对端的 27015 映射到本地 27015 ⇒ 双方都只连 127.0.0.1。
		if _vhost:
			var okh: bool = _vtr.host_start(TUNNEL_ENET_PORT)
			_vhost_up_ms = Time.get_ticks_msec()
			print("[versus-net] 隧道主机 ENet:%d ok=%s" % [TUNNEL_ENET_PORT, str(okh)])
		else:
			_vjoin_retry_ms = Time.get_ticks_msec()
			var okj: bool = _vtr.join("127.0.0.1", TUNNEL_ENET_PORT, _vjoin_retry_ms)
			print("[versus-net] 隧道加入 ENet:127.0.0.1:%d ok=%s" % [TUNNEL_ENET_PORT, str(okj)])
		return
	if _vhost:
		var ok: bool = _vtr.host_start(int(RUN_STORE.pending_versus_port))
		_vhost_up_ms = Time.get_ticks_msec()
		_vnet.host_setup(["你", "空位", "空位", "空位"], 1)
		print("[versus-net] host=%s seat=%d" % [str(ok), _vseat])
	else:
		var raw := String(RUN_STORE.pending_versus_addr)
		var ip := raw
		var port := int(RUN_STORE.pending_versus_port)
		var c := raw.rfind(":")
		if c > 0:
			ip = raw.substr(0, c)
			port = int(raw.substr(c + 1))
		_vjoin_retry_ms = Time.get_ticks_msec()
		var ok2: bool = _vtr.join(ip, port, _vjoin_retry_ms)
		print("[versus-net] join=%s %s:%d seat=%d" % [str(ok2), ip, port, _vseat])


## 中转模式：起本机转发器 + ENet。
##
## ★ 2026-10-28：手机不能建 TUN ⇒ 两端都主动连公网 UDP 中继（`eve_udp_relay.gd`）。
##   本机转发器占 **27015**；房主的 ENet 服务端错开用 **27016**，加入方 ENet 连 27015。
## ⚠️ 这里**不碰 EasyTier**：中转模式全程用户态 UDP，不需要管理员/虚拟网卡。
func _start_relay_transport() -> void:
	var rh := String(RUN_STORE.pending_versus_relay_host).strip_edges()
	var rp := int(RUN_STORE.pending_versus_relay_port)
	# ★ 2026-10-28 零门槛：大厅没带地址（空/0）⇒ 用**内置**服务器。
	#   ⇒ 玩家装完游戏什么都不用配，两端都只认房间码。
	if rh == "" or rp <= 0:
		rh = NETCFG.host()
		rp = NETCFG.port()
	var code := String(RUN_STORE.pending_versus_code)
	_vrelay = RELAY_SCRIPT.new()
	_vrelay.name = "UdpRelay"
	add_child(_vrelay)
	_vrelay.configure(rh, rp, code,
			RELAY_SCRIPT.SIDE_HOST if _vhost else RELAY_SCRIPT.SIDE_GUEST)
	var okb: bool = _vrelay.start(TUNNEL_ENET_PORT)
	print("[relay] 转发器 127.0.0.1:%d ok=%s · 中继 %s:%d · 房间 %s" % [
			TUNNEL_ENET_PORT, str(okb), rh, rp, code])
	if _vhost:
		_vrelay.set_fixed_local("127.0.0.1", RELAY_ENET_PORT)
		var okh: bool = _vtr.host_start(RELAY_ENET_PORT)
		_vhost_up_ms = Time.get_ticks_msec()
		print("[relay] 房主 ENet 127.0.0.1:%d ok=%s" % [RELAY_ENET_PORT, str(okh)])
	else:
		_vjoin_retry_ms = Time.get_ticks_msec()
		var okj: bool = _vtr.join("127.0.0.1", TUNNEL_ENET_PORT, _vjoin_retry_ms)
		print("[relay] 加入 ENet 127.0.0.1:%d ok=%s" % [TUNNEL_ENET_PORT, str(okj)])


## 联机：进战场后先「等 START」—— 不跑倒计时、不判负、不建舰队。
##
## ★ 2026-10-28 房主权威（用户：「需要房主点击开始游戏各个玩家才能开始游戏」
##   「各有各的节奏，这不对」）。
##   · 房主：等对端 ENet 连上（≤ `VERSUS_START_GRACE_MS`）就发 START；
##   · 加入方：等房主广播的 START；隧道/中继里房主可能还没点开始 ⇒ 每秒重连。
func _begin_versus_wait() -> void:
	if _vhost:
		_set_wait_text("等待玩家接入…")
		print("[versus] 房主：等对端 ENet 连上（最多 %d ms）后开赛" % VERSUS_START_GRACE_MS)
	else:
		_set_wait_text("等待房主开始…")


## 房主：把 START 广播出去，然后自己才开始第 1 回合。
##
## ⚠️ 必须**先广播、后 `begin_prep()`**：反过来的话自己这边的 30 秒准备先跑了，
##    而 START 还在路上 —— 两台机器的准备倒计时就从不同时刻起算（漂移的源头）。
func _versus_host_start() -> void:
	if _vstarted:
		return
	_vstarted = true
	_hide_wait_layer()
	if _vonline and _vtr != null:
		_vtr.broadcast({"kind": 4, "start": 1, "round": 0})
		print("[versus-net] START 广播（房主开赛）")
	begin_prep()


## 加入方：收到房主的 START 才开始第 1 回合。
func _versus_client_start() -> void:
	if _vstarted:
		return
	_vstarted = true
	_hide_wait_layer()
	print("[versus-net] START 收到 —— 跟随房主开赛")
	begin_prep()


## 房主：广播「新回合开始」。加入方只认这条，自己不再数到点。
func _versus_announce_round() -> void:
	if not _vonline or not _vhost or _vtr == null or versus == null:
		return
	_vtr.broadcast({"kind": 4, "start": 1, "round": _versus_round_no(),
			"stage": versus.stage, "round_no": versus.round})
	print("[versus-net] ROUND 广播 %s（global=%d）" % [versus.round_label(), _versus_round_no()])


## 加入方：跟随房主切到下一回合。
##
## ⚠️ 强制 `begin_prep()`：本机可能还在打/还在结算，房主已经进下一回合了 ——
##    房主权威下**以房主的节拍为准**，本机那份残留状态必须被重建掉。
func _versus_client_follow(st: int, rd: int) -> void:
	if versus == null or versus.finished:
		return
	versus.stage = maxi(1, st)
	versus.round = clampi(rd, 1, versus.rounds_in_stage())
	versus.round_elapsed = 0.0
	versus.reroll_pairings()
	_versus_await_result = false
	_refresh_versus_hud()
	print("[versus-net] 跟随房主进下一回合 %s" % versus.round_label())
	begin_prep()


## 等 START 的全屏提示（懒建；⛔ 只建一次）。
func _set_wait_text(t: String) -> void:
	if _vwait_layer == null:
		_vwait_layer = CanvasLayer.new()
		_vwait_layer.layer = 50
		add_child(_vwait_layer)
		var dim := ColorRect.new()
		dim.color = Color(0.02, 0.03, 0.04, 0.55)
		dim.set_anchors_preset(Control.PRESET_FULL_RECT)
		dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_vwait_layer.add_child(dim)
		var lb := Label.new()
		lb.name = "WaitLabel"
		lb.set_anchors_preset(Control.PRESET_FULL_RECT)
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lb.add_theme_color_override("font_color", Color(0.84, 0.95, 0.97))
		lb.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.04, 0.94))
		lb.add_theme_constant_override("outline_size", 4)
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		FONT.fs(lb, 30)
		_vwait_layer.add_child(lb)
	var l := _vwait_layer.get_node_or_null("WaitLabel") as Label
	if l != null:
		l.text = t
	_vwait_layer.visible = true


func _hide_wait_layer() -> void:
	if _vwait_layer != null:
		_vwait_layer.queue_free()
		_vwait_layer = null


## 本机这一回合的编制（网络用的最小集）。
func _versus_my_entries() -> Array:
	var out: Array = []
	for e in run.field_entries():
		out.append({"ship_key": String(e.get("ship_key", "")), "star": int(e.get("star", 1))})
	return out


func _versus_round_no() -> int:
	if versus == null:
		return 0
	return int(versus.global_round())


## 开打时广播自己的编制。
func _versus_broadcast_fleet() -> void:
	if not _vonline or _vnet == null or _vtr == null:
		return
	var r := _versus_round_no()
	var entries := _versus_my_entries()
	_vtr.broadcast({"kind": 8, "seat": _vseat, "round": r, "entries": entries})
	var by_round: Dictionary = _vfleets.get(r, {})
	by_round[_vseat] = entries
	_vfleets[r] = by_round
	print("[versus-net] 广播编制 seat=%d round=%d n=%d" % [_vseat, r, entries.size()])


## 真联机 PvP：用对手的网络编制重建敌方舰队（开打前调用）。
## 返回是否重建（没有对手编制时保持 prep 阶段那支占位舰队）。
func _versus_rebuild_enemy_if_remote() -> bool:
	if not _vonline or versus == null:
		return false
	if versus.round_kind() != EveMatchState.RoundKind.PVP:
		return false
	var opp: int = versus.human_opponent()
	if opp < 0:
		return false
	var entries := _versus_remote_entries(opp)
	if entries.is_empty():
		print("[versus-net] PvP 对手 seat=%d 的编制还没到，沿用占位舰队" % opp)
		return false
	for sh in _enemy_ships:
		arena.free_ship_visual(sh.id)
	_enemy_ships = _fleet.build_from_entries(entries, 1)
	_place_fleet(_enemy_ships, 1)
	for sh2 in _enemy_ships:
		arena.spawn_ship_visual(sh2)
	print("[versus-net] PvP 用对手(seat=%d)网络编制重建敌方舰队 n=%d" % [opp, _enemy_ships.size()])
	return true


## 房主权威：把全员血量广播出去，客户端以此为准覆盖本地结算。
##  ⚠️ 为什么还要 SYNC：客户端是**各自本地结算**的（响应快、不依赖网络），
##     一旦某台机器少算一回合，血量就会永久漂移。房主这份是唯一真值。
func _versus_broadcast_sync() -> void:
	if not _vonline or not _vhost or _vtr == null or versus == null:
		return
	var hp_arr: Array = []
	var al_arr: Array = []
	for pl in versus.players:
		hp_arr.append(int(pl.hp) if pl != null else 0)
		al_arr.append(pl != null and pl.is_alive())
	_vtr.broadcast({"kind": 9, "round": _versus_round_no(), "hp": hp_arr, "alive": al_arr})
	print("[versus-net] SYNC 发 round=%d hp=%s" % [_versus_round_no(), str(hp_arr)])


func _versus_net_tick() -> void:
	if not _vonline or _vtr == null:
		return
	# ★ 中转模式：先把本机转发器这一帧的包搬完 —— ENet 的收发都经过它。
	if _vrelay != null:
		_vrelay.poll()
	_vtr.poll()
	# ── 开赛闸门（房主权威）──
	if not _vstarted:
		if _vhost:
			# 对端连上就立刻开；没人来就等宽限到点（房主一个人也能玩）
			if _vpeer_seen or Time.get_ticks_msec() - _vhost_up_ms >= VERSUS_START_GRACE_MS:
				_versus_host_start()
		elif (_vuse_tunnel or _vrelay_mode) and not _vjoined:
			# 隧道里房主可能还没点「开始对战」（他的 ENet 服务端还没起）⇒ 每秒重连一次
			var now_ms := Time.get_ticks_msec()
			if now_ms - _vjoin_retry_ms >= 1000:
				_vjoin_retry_ms = now_ms
				_vtr.stop()
				_vtr.join("127.0.0.1", TUNNEL_ENET_PORT, now_ms)
				print("[versus-net] 重连房主 ENet:%d" % TUNNEL_ENET_PORT)
	for msg in _vnet.drain():
		var d: Dictionary = msg["d"]
		var kk := int(d.get("kind", -1))
		# ── 房主的开赛 / 换回合广播（客户端唯一推进源）──
		if kk == 4:
			if not _vhost and int(d.get("start", 0)) == 1:
				var rr4 := int(d.get("round", 0))
				if not _vstarted:
					_versus_client_start()
					# 迟到加入：房主补发的是「当前回合」而不是第 1 回合 ⇒ 跟上它
					if rr4 > 1:
						_versus_client_follow(int(d.get("stage", 0)), int(d.get("round_no", 0)))
				elif rr4 > _versus_round_no():
					_versus_client_follow(int(d.get("stage", 0)), int(d.get("round_no", 0)))
			continue
		if kk == 9 and not _vhost and versus != null:
			var hp_arr: Array = d.get("hp", [])
			for i in mini(hp_arr.size(), versus.players.size()):
				var pl = versus.players[i]
				if pl != null:
					pl.set_hp_sync(int(hp_arr[i]))
			_refresh_versus_hud()
			print("[versus-net] SYNC 收 round=%d hp=%s" % [int(d.get("round", 0)), str(hp_arr)])
			continue
		if kk != 8:
			continue
		var rr := int(d.get("round", 0))
		var by_round: Dictionary = _vfleets.get(rr, {})
		by_round[int(d.get("seat", -1))] = d.get("entries", [])
		_vfleets[rr] = by_round
		print("[versus-net] 收到编制 seat=%d round=%d n=%d" % [int(d.get("seat", -1)), rr,
			(d.get("entries", []) as Array).size()])


## PvP 时取对手这一回合的编制；还没到就返回空数组（调用方回退到脚本编组）。
func _versus_remote_entries(seat: int) -> Array:
	if not _vonline:
		return []
	var by_round: Dictionary = _vfleets.get(_versus_round_no(), {})
	return by_round.get(seat, [])
