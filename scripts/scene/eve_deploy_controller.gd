extends RefCounted

## 拖放布阵控制器 —— 从 `eve_battle_scene.gd`（2400 行）里搬出的**整个拖放交互**。
##
## ══════════════════════════════════════════════════════════════════
##  一次拖动的完整生命周期（五个入口，别把逻辑散到别处去）
## ══════════════════════════════════════════════════════════════════
##     begin_drag   按下：这一下是想拿船，还是想转视角？
##     update_drag  移动：幽灵跟手 · 棋盘显形 · 落点高亮 · 写一句「松手会怎样」
##     end_drag     松手：按落点分派到 部署 / 换位 / 撤回 / 出售
##     cancel_drag  取消：ESC / 右键，等于落点「哪儿都不是」
##     finish_drag  收尾：拖动期间的所有临时状态在这里一次清干净（唯一出口）
##
## ⚠️⚠️ **拖动状态字典由主控持有**（`eve_battle_scene._drag`，验收脚本 `verify_run`
##     直接 `_battle.get("_drag")` 读它）⇒ 本控制器**只对它 `clear()` / `merge()`**，
##     ⛔ **绝不 `drag = {...}` 重新赋值**（重新赋值会让主控那个变量指向别的字典，
##     两边从此各说各话，症状是「拖到一半界面和状态对不上」）。
##
## ⚠️ 依赖是**显式注入**的（`setup()`），不是 `get_parent()` / 场景树查找：
##     · `run` / `arena` / `hud` 是**稳定对象**（主控 `_ready` 里各建一次，之后不换）。
##     · `_own_ships` / `_own_field_index` 会被**重新赋值**（重建舰队时）⇒ 用 Callable
##       回主控现取，⛔ 不能在这里缓存数组（缓存的是旧数组）。
##     · `_refresh_run_ui` / `_log_synergies` 是主控的收尾动作 ⇒ 用 Callable 回调。

## 屏幕上「点中一艘舰船」的判定半径（像素）。
## ⚠️ 单一来源：主控的「点击选中最近舰船」也用它（`DEPLOY.PICK_RADIUS`）——
##    ⛔ 别在两处各写一份 60.0。
const PICK_RADIUS := 60.0

## 「按下 → 松手」之间位移小于这个值 = **点选**，不是拖放（像素 · 画布空间）。
##
## ★★ 2026-10-30 修 bug（玩家反馈：「准备阶段点击舰船，档案不跟着换，
##    只显示战斗中最后点的那一个」）：
##
##    根因：按下就 `begin_drag` 成功，松手事件被主控 `_input()` 抢走并
##    `set_input_as_handled()` ⇒ `_unhandled_input` 里那条「松手 → `_try_select_at`」
##    **一次都走不到**。于是整个准备阶段只有「拖放」，没有「点选」：
##    档案永远停在上一次战斗中选中的那艘。
##    备战席同理（`begin_drag` 也认备战席格）。
##
##    修法就是这里：松手时若位移 < `TAP_SLOP`，当作一次点击 ——
##    收尾但不执行任何落点动作，把「选谁」交回主控。
##
## ⚠️ 阈值 14 的取法（夹在两头之间，别随手调）：
##    · 下界 = 触屏点击的真实抖动。Godot 把 touch 模拟成 mouse，按下/抬起的坐标
##      是采样点，手指"按一下"通常漂 5~10 px（画布空间）⇒ 阈值小于 10 = 手机上修不掉。
##    · 上界 = 半格。棋盘 11×11 在 1080p 画布上一格约 40 px，超过 20 就等于
##      「玩家想挪一格，却被当成点选」⇒ 拖放会变得时灵时不灵。
##    14 落在两者中间，两边都留了余量。
const TAP_SLOP := 14.0

## ★ 与主控**共享同一个字典对象**（见顶注）。空字典 = 没在拖。
var drag: Dictionary = {}

## 本次拖动点亮的棋盘是不是「自动的」（松手要还原）。
##
## ⚠️ 玩家用 KEY_B 手动开的棋盘不该被一次拖放顺手关掉 —— 他开棋盘是在核对格子。
##    所以只还原「因为这次拖动才亮起来」的棋盘。
var board_auto := false

var _run: EveRunState = null
var _arena: EveBattleArena = null
var _hud: EveHudRoot = null
var _own_ships_cb: Callable = Callable()
var _own_field_index_cb: Callable = Callable()
var _refresh_ui_cb: Callable = Callable()
var _log_synergies_cb: Callable = Callable()


## 主控 `_ready` 里接线一次。参数见顶注的「显式注入」。
func setup(p_run: EveRunState, p_arena: EveBattleArena, p_hud: EveHudRoot,
		p_drag: Dictionary, p_own_ships: Callable, p_own_field_index: Callable,
		p_refresh_ui: Callable, p_log_synergies: Callable) -> void:
	_run = p_run
	_arena = p_arena
	_hud = p_hud
	drag = p_drag
	_own_ships_cb = p_own_ships
	_own_field_index_cb = p_own_field_index
	_refresh_ui_cb = p_refresh_ui
	_log_synergies_cb = p_log_synergies


## 玩家手动开 / 关棋盘（KEY_B、设置窗的「棋盘」开关）。
##
## ⚠️ 这会把「自动点亮」标记清掉 ⇒ 松手时**不会**顺手把这块棋盘关掉 ——
##    玩家手动开的棋盘是在核对格子，不该被一次拖放夺走控制权。
func mark_board_manual() -> void:
	board_auto = false


## 按下左键时试着拿起一艘船。拿起来了 → true（本次左键从此归拖放）
##
## ★ 2026-10-28（用户：「打捞的时候钱不够，应该允许卖船换星币」）：
##   放行条件从「只有 PREP」改成 `run.can_sell()`（PREP + RESOLVE）。
##   结算期拿起船**只能**拖到商店出售 —— 布阵 / 撤回那条路在提示层就被掐掉。
func begin_drag(pos: Vector2) -> bool:
	if _run == null or not _run.can_sell():
		return false          # 战斗中锁操作，是阶段 A 就定下的规矩

	# ① 备战席：轨道几何只有 HUD 知道（格宽 = size.x / 8），所以问它落在第几格
	var bi := _hud.bench_slot_at(pos)
	var bench := _run.bench_entries()
	if bi >= 0 and bi < bench.size():
		_set_drag(make_drag(bench[bi], &"bench", bi))
		drag["start"] = pos
		drag["screen"] = pos
		_begin_drag_visual()
		return true

	# ② 我方场上舰船：屏幕距离最近的一艘
	var si := own_ship_at(pos)
	var fmap: Array = _own_field_index_cb.call()
	var ships: Array = _own_ships_cb.call()
	if si >= 0 and si < fmap.size():
		var fi: int = fmap[si]
		var entries := _run.field_entries()
		if fi >= 0 and fi < entries.size():
			_set_drag(make_drag(entries[fi], &"field", fi))
			# ★ 2026-11-07（结算期卖船）：记下 3D 实例 id —— 卖成功之后要把
			#   这艘船的视觉当场收掉（否则"卖了却还站着"）。下标做不到这件事：
			#   结算期 `run.field` 已被删过元素，`fi` 只是开战前的旧下标。
			if si < ships.size():
				drag["ship_id"] = int((ships[si] as EveShip).id)
			drag["start"] = pos
			drag["screen"] = pos
			_begin_drag_visual()
			return true

	return false


## 屏幕点选了我方第几艘（`_own_ships` 的下标；-1 = 没点中）
func own_ship_at(pos: Vector2) -> int:
	var ships: Array = _own_ships_cb.call()
	var best := -1
	var best_d := PICK_RADIUS
	for i in ships.size():
		var ship: EveShip = ships[i]
		if not ship.alive:
			continue
		var sp := _arena.world_to_screen(ship.body.position + Vector3(0, 4, 0))
		var d := sp.distance_to(pos)
		if d < best_d:
			best_d = d
			best = i
	return best


## 组装拖动状态。各字段的含义见主控 `_drag` 的声明处。
static func make_drag(e: Dictionary, source: StringName, index: int) -> Dictionary:
	var key := String(e.get("ship_key", ""))
	var d := EveShipDatabase.by_id(key)
	var star := maxi(1, int(e.get("star", 1)))
	var cost := int(d.get("cost", 1))
	return {
		"source": source,
		"index": index,
		# ★ 2026-11-07：**条目本体（引用）**。结算期出售按它找，而不是按 `index`
		#   —— 见 `EveRunState.sell_entry()` 顶部的说明（下标在战后会指错人）。
		"entry": e,
		# 3D 实例 id（只有 field 起点会补）。卖成功之后用它收掉视觉。
		"ship_id": -1,
		"ship_key": key,
		"star": star,
		"cost": cost,
		"name": String(d.get("name", key)),
		"color": EveShip.FACTION_COLORS.get(int(d.get("faction", 0)), Color.GRAY),
		# 出售返还 = cost × 3^(star-1)（与 RunState.sell_value 同口径）
		"refund": cost * int(pow(3.0, float(star - 1))),
		# `start` = 按下的位置（判 tap 用，**不随鼠标更新**）
		# `screen` = 当前位置（幽灵跟手用）
		"start": Vector2.ZERO,
		"screen": Vector2.ZERO,
		"hint": "",
		"hint_ok": false,
	}


## 拿起之后的第一帧：幽灵现身 · 棋盘显形 · 备战席标记 + 那艘 3D 船先藏起来
func _begin_drag_visual() -> void:
	# 棋盘显形 + 布阵取景。
	# ⚠️ 走 arena.show_board_for_deploy()，**不走** arena.set_board_visible ——
	#    后者是把取景硬设到目标位；拖动途中画面「啪」地一跳，玩家立刻失去手感。
	#    show_board_for_deploy 只把「棋盘可见」立起来，
	#    取景（推近到 BOARD_VIEW_ZOOM 倍）由 arena._process 每帧收敛过去。
	if _arena.board != null:
		if not _arena.board.visible:
			board_auto = true
		_arena.show_board_for_deploy()
	# ── 布阵尺寸（2026-09-20 用户要求）──────────────────────────────
	# 舰船切到布阵态（放大 BOARD_EXAGGERATION 倍；实测 1× 下护卫只有 0.2~0.3 格 /
	# 20~30 px，连拖拽命中半径 PICK_RADIUS=60 都点不中）。
	# 幂等，连续拖拽重复调用无害。
	# [SRC] 分吨位实测见 docs/方案-准备阶段棋盘模式-2026-11-07.md 7.3 节
	_arena.set_ships_board_mode(true)
	# 从备战席拿的：格带上标出「这格被拿起了」，并让那一格**不画立绘**。
	# （EveBenchRail._draw 按 dragging_index 跳过该格，否则会和幽灵重叠成两艘；
	#  3D 版当年靠 bench_stage.set_hidden_index 做同一件事，已随 3D 层停用。）
	if StringName(drag["source"]) == &"bench":
		_hud.set_bench_drag(int(drag["index"]))
	update_drag(drag["screen"])


## 拖动中：幽灵跟手 · 落点高亮 · 把「松手会怎样」写进幽灵的第二行
func update_drag(pos: Vector2) -> void:
	if drag.is_empty():
		return
	# Grabbing is distinct from a tap: wait for actual motion before sounding it.
	if not bool(drag.get("audio_grabbed", false)) and not is_tap(pos):
		drag["audio_grabbed"] = true
		EveUiAudio.play("fleet.grab")
	drag["screen"] = pos

	var source := StringName(drag["source"])
	var index := int(drag["index"])
	var over_sell := _hud.sell_zone_rect().has_point(pos)
	var bi := _hud.bench_slot_at(pos)
	var cell: Vector2i = _drop_cell(pos)
	var on_mine := cell.x >= 0 and _arena.board != null and _arena.board.is_mine_zone(cell.x)

	# 落点判定所需的「事实」在这里现取（棋盘预览 / 备战席是否还有位），
	# 「怎么措辞」的规则交给纯函数 `resolve_hint` —— 那份文案是玩家可见的，
	# 单独可测（见 verify_battle_hint）。
	var pv: Dictionary = {}
	if on_mine:
		pv = _run.preview_place(cell.x, cell.y, source, index)
	var d := resolve_hint(source, over_sell, on_mine, pv, bi >= 0,
			_run.can_recall(), _run.bench_used(), EveRunState.BENCH_SLOTS,
			cell, int(drag["refund"]),
			_run.phase == EveRunState.Phase.PREP)
	drag["hint"] = d["hint"]
	drag["hint_ok"] = d["ok"]

	# 棋盘高亮：只高亮「真的落得下」的格子。
	# ⚠️ 无效格也给高亮的话，玩家会以为能放 —— 高亮本身就是一句承诺。
	if _arena.board != null:
		if on_mine and bool(d["ok"]):
			_arena.board.highlight(cell.x, cell.y)
		else:
			_arena.board.clear_highlight()

	# 出售区跟随高亮（只在指针真的进了商店窗时亮）
	_hud.set_sell_hot(over_sell)
	# 备战席：悬停格提示「松手就落这一格」
	_hud.set_bench_hover(-1 if over_sell else bi)
	_hud.set_drag_ghost(ghost_payload(drag))


## 指针落点 → 目标格。**拖动高亮与松手动作共用这一个入口**（同源原则：
## 高亮就是承诺，只能有一个地方决定"落在哪"）。
##
## ★★ 2026-11-07「吸到船体」（玩家要的是「把 A 拖到 B 身上」）：
##   布阵态舰船放大 3 倍后，船体在屏幕上远大于它占的那一格
##   （战列实测竖跨约 3.4 格、投影 284px，见 docs 第 7.3 节）。
##   玩家按直觉把 A 按在 B 的船体上松手时，指针的**格**经常是 B 的邻格甚至空行
##   ⇒ A 被放到旁边，看起来像「互换没生效」。
##   所以：指针落在某艘船**投影出来的轮廓**里时，目标就算那艘船的格子。
##
## ⛔ 只在准备阶段吸。结算期棋盘已收起、船只是画面残留，
##   吸过去会把「拖去出售」的手感弄钝（结算期本来也不允许挪位）。
## ⚠️ 先判「指针压在谁的格子上」：那是最具体的答案（含空格），
##    只有落在空子上才去问"是不是指着某艘船的轮廓"。
##
## ⚠️⚠️ 两条**不许吸**的红线（都是踩得到的）：
##   ① 指针**不在棋盘上**（格号 x < 0 = 备战席 / 商店 / 画外）⇒ 直接返回。
##      否则「拖回备战席」会被船体吸走变成"挪回棋盘"，那是功能倒退。
##   ② 指针格与那艘船的格子**相邻**（±1 行/列内）⇒ 不吸。
##      「把这艘挪到它旁边」是最常见的动作，而相邻格常常正好被它的船体盖住；
##      吸过去就会变成互换 —— 手感比"没吸"更糟。
##      只有隔了 ≥2 格还落在船体轮廓里，才说明玩家真的是在指那艘船。
func _drop_cell(pos: Vector2) -> Vector2i:
	var cell: Vector2i = _arena.screen_to_cell(pos)
	if _run == null or _run.phase != EveRunState.Phase.PREP:
		return cell
	if _arena.board == null:
		return cell
	# 红线①：不在棋盘上，一律按原样返回
	if cell.x < 0:
		return cell
	if _arena.board.is_mine_zone(cell.x) and _run.field_index_at(cell.x, cell.y) >= 0:
		return cell
	var dragged_id := int(drag.get("ship_id", -1))
	var ships: Array = _own_ships_cb.call()
	var fmap: Array = _own_field_index_cb.call()
	var entries := _run.field_entries()
	for i in ships.size():
		if i >= fmap.size():
			break
		var ship: EveShip = ships[i]
		if ship == null or not ship.alive:
			continue
		if int(ship.id) == dragged_id:
			continue
		var visual = _arena.get_ship_visual(ship.id)
		if visual == null or not is_instance_valid(visual) \
				or not visual.has_method("hull_world_aabb"):
			continue
		var bb: AABB = visual.hull_world_aabb()
		if bb.size == Vector3.ZERO:
			continue
		if not _screen_rect(bb).has_point(pos):
			continue
		var fi: int = fmap[i]
		if fi < 0 or fi >= entries.size():
			continue
		var c = entries[fi].get("cell", Vector2i(-1, -1))
		if not (c is Vector2i) or c.x < 0:
			continue
		# 红线②：相邻格不吸
		if maxi(absi(int(c.x) - cell.x), absi(int(c.y) - cell.y)) <= 1:
			return cell
		return c
	return cell


## 世界空间包围盒 → 屏幕矩形（8 个角都投一次，取 min/max）
##
## ⚠️ 相机后面的角必须跳过：`unproject_position` 对身后的点会给出**镜像坐标**，
##    不跳过的话包围盒会突然横跨整个屏幕，吸船范围就变成"全屏"。
func _screen_rect(bb: AABB) -> Rect2:
	# ⚠️ 用 arena 自己的 `camera`，不要 `orion_cam.camera`
	#    —— 两者现阶段是同一个，但 `camera` 是 arena 的公开接口
	#    （`world_to_screen` 也是它），走接口才不会在换相机时悄悄失效。
	var cam: Camera3D = _arena.get("camera")
	if cam == null:
		return Rect2()
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for k in 8:
		var p := bb.position + Vector3(
			bb.size.x if (k & 1) != 0 else 0.0,
			bb.size.y if (k & 2) != 0 else 0.0,
			bb.size.z if (k & 4) != 0 else 0.0)
		if cam.is_position_behind(p):
			continue
		var s: Vector2 = _arena.world_unit_to_screen(p)
		mn = mn.min(s)
		mx = mx.max(s)
	if mn.x == INF:
		return Rect2()
	return Rect2(mn, mx - mn)


## 「松手会怎样」的**纯规则**：把所有落点的分支收在这一处，输入是事实、输出是文案。
##
## ⚠️ 这是**玩家可见文案的唯一来源** —— 被拒的静默路径必须给「指对方向」的理由
##    （红线：⛔ 别摆「看着能点、点了没反应」的东西）。单独抽出来是为了能脱离
##    拖拽上下文直接断言每个分支。
## `can_place` = 当前阶段允许布阵吗（只有 PREP 允许）。
## ★ 2026-10-28 新增：结算（打捞）期允许拿起船去卖，但不允许布阵 ——
##   此时除了出售以外的落点必须直接说「只能出售」，
##   ⛔ 别让棋盘上还亮着「部署到 第 8 行第 5 列」，松手却被拒。
static func resolve_hint(source: StringName, over_sell: bool, on_mine: bool,
		place: Dictionary, on_bench: bool, can_recall: bool,
		bench_used: int, bench_max: int, cell: Vector2i, refund: int,
		can_place: bool = true) -> Dictionary:
	if over_sell:
		return {"hint": "出售 · 返还 ◆%d" % refund, "ok": true}
	if not can_place:
		return {"hint": "结算阶段只能拖到商店出售", "ok": false}
	if on_mine:
		var ok := bool(place.get("ok", false))
		if ok:
			# ★★ 2026-11-07：落点有船 ⇒ 互换。
			#    ⚠️ 必须**点名**「与谁换」：只说「移动到这里」的话，玩家看不出
			#    这一格有船、也看不出他的船会被顶去备战席（名额不变但位置变了）。
			#    这是唯一一处能提前告诉他的地方。
			if bool(place.get("swap", false)):
				return {"hint": "与 %s 互换位置" % String(place.get("swap_name", "该船")),
						"ok": true}
			if source == &"bench":
				return {"hint": "部署到 第 %d 行第 %d 列" % [cell.x + 1, cell.y + 1], "ok": true}
			return {"hint": "移动到这里", "ok": true}
		var why := String(place.get("reason", ""))
		return {"hint": why if why != "" else "不能放在这里", "ok": false}
	if on_bench:
		if source == &"field":
			if can_recall:
				return {"hint": "撤回备战席", "ok": true}
			return {"hint": "备战席已满（%d／%d）" % [bench_used, bench_max], "ok": false}
		return {"hint": "放回备战席", "ok": true}
	return {"hint": "拖到下方部署区 · 或拖到商店出售", "ok": false}


## 幽灵要显示的内容（与 HUD 侧 `_DragGhost.apply` 的字段约定一致）
static func ghost_payload(d: Dictionary) -> Dictionary:
	return {
		"active": true,
		"name": String(d.get("name", "—")),
		"star": int(d.get("star", 1)),
		"cost": int(d.get("cost", 1)),
		"color": d.get("color", Color.GRAY),
		"hint": String(d.get("hint", "")),
		"hint_ok": bool(d.get("hint_ok", false)),
		"screen": d.get("screen", Vector2.ZERO),
	}


## 本次按下到松手算不算「点选」而不是「拖放」。
##
## ⚠️ `start` 由 `begin_drag` 写入、**不跟着鼠标走**（`screen` 才跟）。
##    拿不到 `start`（万一有旧路径只写 screen）就退回 screen —— 那时恒为 tap，
##    最坏情况是「拖了一下没生效」，比「点了完全不反应」更容易被发现。
func is_tap(pos: Vector2) -> bool:
	if drag.is_empty():
		return false
	var start: Vector2 = drag.get("start", drag.get("screen", pos))
	return start.distance_to(pos) <= TAP_SLOP


## 松手：按落点分派动作。整个拖放**唯一的生效点**。
##
## 落点优先级：出售区 → 棋盘格 → 备战席轨道 → 什么都不做（静默放回）。
##
## 返回 **true = 这一次是「点选」**（位移 ≤ `TAP_SLOP`）：已经收尾、**数据一个字节
## 都没动**，调用方应该接着做「选中这艘船」。false = 真拖放，动作已执行。
##
## ⚠️ 点选必须**跳过落点动作**，不能"先原地落一下再选"：
##    玩家只是点一下，不该产生任何编制写入与日志。
##    （2026-11-07 之前这条后果更严重：场上的船原地 `move_field` 到自己格子被
##     `_cell_taken()` 判成占用 ⇒ 点一下却收到一句「这一格已经被船了」。
##     现在「落点有船 = 互换」之后自己拖自己已是合法 no-op，但那条日志仍是噪音，
##     所以这条规则不变：点选 ≠ 拖放。）
func end_drag(pos: Vector2) -> bool:
	if drag.is_empty():
		return false
	if is_tap(pos):
		finish_drag()
		return true
	var source := StringName(drag["source"])
	var index := int(drag["index"])
	# ⚠️ `finish_drag()` 会清空 drag ⇒ 这三个必须在它之前取出来。
	#   `entry` = 拖起来的那条编队数据（结算期出售按它找，不看下标）。
	var entry: Dictionary = drag.get("entry", {})
	var ship_id := int(drag.get("ship_id", -1))
	var resolve_stage := _run.phase == EveRunState.Phase.RESOLVE
	# ⚠️ 落点格也必须在 `finish_drag()` **之前**算：`_drop_cell()` 要读 `drag` 里的
	#    `ship_id` 来排除"被拖的那一艘自己"（否则它的轮廓会被当成吸船目标，
	#    结果永远是"落回原格"）。`finish_drag()` 之后 drag 就空了。
	var cell_hit: Vector2i = _drop_cell(pos)
	# ⚠️ 顺序不能反：**先清拖动状态，再执行落点动作**。
	#    因为动作会 emit changed，而 _refresh_run_ui 在「拖动中」是跳过舰队重建的。
	#    先动作后清理的话：船确实上前了（数据对了），但战场上不会出现它 ——
	#    要等下一次 changed 才补上，玩家看到的现象是「松手没反应」。
	finish_drag()

	var res: Dictionary = {"ok": false, "reason": ""}
	if _hud.sell_zone_rect().has_point(pos):
		# 出售。日志（含返还金额）由 RunState 自己发，这里不重复写一行
		if source == &"bench":
			res = _run.sell_from_bench(index)
		elif resolve_stage:
			# ★★ 2026-11-07 修 bug（玩家反馈「结算时卖船，卖的却是另一艘」）：
			#   战斗结束时 `resolve_battle()` 把阵亡的船从 `run.field` 删掉了，
			#   而 `index` 来自**开战前**算的映射 ⇒ 整体前移，卖错人。
			#   结算期一律按条目本体找（`sell_entry` 用 is_same 认对象）。
			res = _run.sell_entry(entry)
		else:
			res = _run.sell_from_field(index)
		# ★ 2026-11-07：结算期卖掉场上的船 ⇒ 3D 视觉当场收掉。
		#   不处理的话「船还在原地站着」，玩家会以为没卖出去（要等下个准备阶段
		#   整队重建才消失）。同时钉 `alive = false`，让拾取 / 存活计数也跳过它。
		if bool(res.get("ok", false)) and source == &"field" and resolve_stage:
			_drop_sold_visual(ship_id)
	else:
		var cell := cell_hit
		var on_mine := cell.x >= 0 and _arena.board != null and _arena.board.is_mine_zone(cell.x)
		if on_mine:
			if source == &"bench":
				res = _run.deploy_from_bench(index, cell.x, cell.y)
			else:
				res = _run.move_field(index, cell.x, cell.y)
		elif source == &"field" and _hud.bench_slot_at(pos) >= 0:
			res = _run.recall_to_bench(index)
		# else：备战席里的船放回备战席 / 丢在空白处 → 静默放回，不打日志

	# 被拒时把原因告诉玩家（这是唯一一处「为什么没生效」的出口）
	if not bool(res.get("ok", false)):
		var why := String(res.get("reason", ""))
		if why != "":
			_hud.append_log({"time": 0.0, "category": &"hint", "text": why})
		elif _hud.bench_slot_at(pos) < 0:
			EveUiAudio.play("fleet.invalid")

	# 兜底再刷一次：RunState 的 changed 已经刷过一遍，这次是给
	# 「动作被拒但界面仍需回正」（例如高亮、备战席 hover）收尾。
	_refresh_ui_cb.call()
	_log_synergies_cb.call()
	return false


## 结算期卖掉场上的船之后，把它的 3D 视觉与「活着」标记一起收掉。
##
## ⚠️ 只在**结算期**走这条路：准备阶段的出售会让 `_refresh_run_ui` 重建整队
##    （那边自己会 `remove_ship_visual` + 重新摆位），这里再动就是抢活干。
## ⚠️ 找不到实例（`ship_id < 0` / 已经不在 `_own_ships` 里）就静默跳过 ——
##    数据那一侧已经卖掉了，视觉多留一帧不影响正确性，比这里崩了强。
func _drop_sold_visual(ship_id: int) -> void:
	if ship_id < 0:
		return
	for s in _own_ships_cb.call():
		if int((s as EveShip).id) == ship_id:
			(s as EveShip).alive = false
			break
	if _arena != null:
		_arena.remove_ship_visual(ship_id)


## 取消：ESC / 右键。落点当成「哪儿都不是」，一个字节的数据都不改。
func cancel_drag(msg: String = "") -> void:
	if drag.is_empty():
		return
	if msg != "":
		_hud.append_log({"time": 0.0, "category": &"hint", "text": msg})
	finish_drag()


## 收尾：拖动期间的所有临时状态，全在这里一次清干净。
##
## ⚠️ 以后每加一个「拖动时才会出现的副作用」，它的清理就写在这里 ——
##    只有这一个出口。这就是把拖动状态做成单份字典的收益。
func finish_drag() -> void:
	drag.clear()                                  # ⛔ 清空，不是重新赋值（见顶注）
	_hud.set_drag_ghost({})
	_hud.set_bench_drag(-1)
	_hud.set_bench_hover(-1)
	_hud.set_sell_hot(false)
	if _arena.board != null:
		_arena.board.clear_highlight()
	# ★★ 2026-11-07（玩家反馈）：「拖动的时候有放大，这很好，但不拖的时候太小」
	#    ⇒ 棋盘与布阵放大都改成**常驻**（由 `begin_prep()` 立起来，
	#      由 `hide_board()` 收回去），放下这一次**什么都不收**。
	#
	#    ⛔ 别把下面两行加回来：
	#         _arena.hide_board()
	#         _arena.set_ships_board_mode(false)
	#       它们的合并效果是「松手瞬间船缩回 1/3」—— 实测（真实分散布阵，1080p）：
	#         护卫 kestrel  86×64 px → 29×22 px
	#         驱逐 catalyst 143×48 px → 49×16 px
	#         战列 abaddon  108×284 px → 37×95 px
	#       护卫缩到 20~30px 就是玩家说的「太小看不清」。
	#       [SRC] 数据出自 docs/方案-准备阶段棋盘模式-2026-11-07.md 第 7.3 节
	#       （A/B 截图 docs/img/board-ab-1x.png / board-ab-3x.png）
	board_auto = false


## 把一份新状态**并入**主控持有的字典（⛔ 不能整体替换，见顶注）。
func _set_drag(fresh: Dictionary) -> void:
	drag.clear()
	drag.merge(fresh)
