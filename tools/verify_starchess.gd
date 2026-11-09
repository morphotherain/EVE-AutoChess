extends Node

## 星舰万象棋 —— 真实操作链路验收（无头）。
##
## [WHY] 直接调 _on_buy() 只能证明函数能跑，证明不了**信号接对了**。
##   本文件走真实链路：card_pressed.emit() / btn.pressed.emit()，
##   也就是玩家真的点下去时那条路。
##
## 跑法：
##   godot --headless --path . res://tools/verify_starchess.tscn

const BATTLE := "res://scenes/starchess/sc_battle.tscn"
const LOBBY := "res://scenes/starchess/sc_lobby.tscn"

var _pass: int = 0
var _fail: int = 0
var _scene: Node = null


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("PASS  %s" % what)
	else:
		_fail += 1
		push_warning("[verify_sc] FAIL  %s" % what)
		print("FAIL  %s" % what)


func _ready() -> void:
	# 必须等一帧：_ready 期间 current_scene 还在装配子节点，
	# 此时 root.add_child() 会被拒绝（"Parent node is busy setting up children"）。
	await get_tree().process_frame
	_run()


func _run() -> void:
	await _step_lobby()
	await _step_battle_buy()
	await _step_battle_deploy()
	await _step_reroll()
	await _step_upgrade()
	await _step_merge()
	await _step_battle_round()
	await _step_commanders()
	print("RESULT passed=%d failed=%d" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _wait(t: float) -> void:
	await get_tree().create_timer(t).timeout


func _load(path: String) -> Node:
	if _scene != null:
		_scene.queue_free()
		_scene = null
	var ps := load(path) as PackedScene
	_scene = ps.instantiate()
	get_tree().root.add_child(_scene)
	await _wait(0.25)
	return _scene


## 找对局场景里某个类型的节点（按名字找不到就用类型扫）
func _find_node(root: Node, cls_name: String) -> Node:
	for n in root.get_children():
		if n.get_script() != null and n.get_script().get_global_name() == cls_name:
			return n
		var deep := _find_node(n, cls_name)
		if deep != null:
			return deep
	return null


## ── 大厅：选指挥官 + 进对局
func _step_lobby() -> void:
	print("[1] 大厅：选指挥官 / 60 秒倒计时 / 可重复选")
	var s := await _load(LOBBY)
	_ok(s != null, "大厅场景可实例化")
	_ok(s.get("_picked") != null, "大厅有 _picked 状态")
	_ok(s.get("_time_left") != null and float(s.get("_time_left")) > 0.0,
			"倒计时在跑（剩余 %.1f）" % float(s.get("_time_left")))
	# 真实点选第 2 个指挥官
	s.call("_on_pick", 2)
	var picked: Array = s.get("_picked")
	_ok(int(picked[0]) == 2, "点选指挥官生效（picked[0]=%d）" % int(picked[0]))
	# 重复选：再点同一个必须仍然合法（不排除已选）
	s.call("_on_pick", 2)
	_ok(int((s.get("_picked") as Array)[0]) == 2, "指挥官允许重复选")


## ── 对局：买卡
func _step_battle_buy() -> void:
	print("[2] 买卡：点商店卡 -> 能量 -3 -> 进手牌")
	var s := await _load(BATTLE)
	_ok(s != null, "对局场景可实例化")
	var shop: Node = s.get("_shop_holder")
	_ok(shop != null and shop.get_child_count() == 4,
			"商店 4 张卡（实际 %d）" % (shop.get_child_count() if shop != null else -1))
	var e0 := int(s.get("_energy"))
	var hand0 := (s.get("_hand") as Array).size()
	var card: Node = shop.get_child(0)
	# ★ 真实链路：发卡片自己的信号（玩家点击走的就是这条路）
	card.emit_signal("card_pressed", 0)
	await _wait(0.1)
	_ok(int(s.get("_energy")) == e0 - 3,
			"买卡扣 3 能量（%d -> %d）" % [e0, int(s.get("_energy"))])
	_ok((s.get("_hand") as Array).size() == hand0 + 1,
			"买卡进手牌（%d -> %d）" % [hand0, (s.get("_hand") as Array).size()])
	# 能量不足时必须拒绝
	s.set("_energy", 1)
	var hand1 := (s.get("_hand") as Array).size()
	if shop.get_child_count() > 1:
		shop.get_child(1).emit_signal("card_pressed", 1)
		await _wait(0.1)
	_ok((s.get("_hand") as Array).size() == hand1, "能量不足时买卡被拒绝")


## ── 对局：上阵
func _step_battle_deploy() -> void:
	print("[3] 上阵：点手牌 -> 进入上阵区")
	var s := _scene
	var hand: Array = s.get("_hand")
	_ok(hand.size() > 0, "手牌里有卡（%d 张）" % hand.size())
	var holder: Node = s.get("_hand_holder")
	var units0 := (s.get("_units") as Array).size()
	# 注意：hand 与 _hand 是**同一个数组**（GDScript 的 Array 是引用类型），
	# 所以上阵后 hand.size() 也会变 —— 必须在调用前记下快照值。
	var hand_before := hand.size()
	# 手牌 holder 里第一个是 ScShopCard
	var target: Node = null
	for c in holder.get_children():
		if c.get_script() != null and _is_card(c):
			target = c
			break
	_ok(target != null, "手牌区存在可点击卡片")
	if target != null:
		target.emit_signal("card_pressed", 0)
		await _wait(0.1)
	_ok((s.get("_units") as Array).size() == units0 + 1,
			"上阵生效（%d -> %d）" % [units0, (s.get("_units") as Array).size()])
	_ok((s.get("_hand") as Array).size() == hand_before - 1,
			"上阵后手牌减少（%d -> %d）"
					% [hand_before, (s.get("_hand") as Array).size()])


## ── 刷新：免费一次，之后 1 费
func _step_reroll() -> void:
	print("[4] 刷新：首次免费，之后扣 1")
	var s := _scene
	s.set("_free_rerolls", 1)
	s.set("_energy", 5)
	var btn: Button = s.get("_reroll_btn")
	_ok(btn != null, "刷新按钮存在")
	btn.emit_signal("pressed")
	await _wait(0.1)
	_ok(int(s.get("_energy")) == 5, "首次刷新免费（能量仍 %d）" % int(s.get("_energy")))
	_ok(int(s.get("_free_rerolls")) == 0, "免费次数已用完")
	btn.emit_signal("pressed")
	await _wait(0.1)
	_ok(int(s.get("_energy")) == 4, "第二次刷新扣 1（能量 %d）" % int(s.get("_energy")))


## ── 升级
func _step_upgrade() -> void:
	print("[5] 升级：扣能量 -> 等级 +1 -> 上阵上限提高")
	var s := _scene
	s.set("_energy", 20)
	var lv0 := int(s.get("_level"))
	var cap0 := int(s.call("_cap"))
	var ubtn: Button = s.get("_upgrade_btn")
	_ok(ubtn != null, "升级按钮存在")
	ubtn.emit_signal("pressed")
	await _wait(0.1)
	_ok(int(s.get("_level")) == lv0 + 1, "升级生效（Lv%d -> Lv%d）" % [lv0, int(s.get("_level"))])
	_ok(int(s.call("_cap")) == cap0 + 1, "上阵上限提高（%d -> %d）" % [cap0, int(s.call("_cap"))])


## ── 合流：同名再买一次 -> +3
func _step_merge() -> void:
	print("[6] 合流：同名舰船 -> +3 级")
	var s := _scene
	var units: Array = s.get("_units")
	_ok(units.size() > 0, "已有上阵单位")
	if units.is_empty():
		return
	var first: Dictionary = units[0]
	var lv0 := int(first.get("level", 1))
	# 直接塞一张同名进手牌，再点它
	var hand: Array = s.get("_hand")
	hand.append(first.duplicate())
	s.call("_refresh_hand")
	await _wait(0.1)
	var holder: Node = s.get("_hand_holder")
	var target: Node = null
	for c in holder.get_children():
		if c.get_script() != null and _is_card(c):
			target = c
			break
	if target != null:
		var idx_in_hand := hand.size() - 1
		target.emit_signal("card_pressed", idx_in_hand)
		await _wait(0.1)
	var after: Dictionary = (s.get("_units") as Array)[0]
	_ok(int(after.get("level", 1)) == lv0 + 3,
			"合流 +3 级（%d -> %d）" % [lv0, int(after.get("level", 1))])


## ── 开战：进下一回合
func _step_battle_round() -> void:
	print("[7] 开战：结算 -> 下一回合 -> 能量回复")
	var s := _scene
	var r0 := int(s.get("_round"))
	s.set("_energy", 0)
	s.set("_units", [])
	# 找开战按钮（accent 那个）
	var go: Button = null
	for n in _all_buttons(s):
		if "开战" in n.text:
			go = n
			break
	_ok(go != null, "开战按钮存在")
	if go == null:
		return
	go.emit_signal("pressed")
	await _wait(0.3)
	# 战力为 0 会掉血；回合要么推进要么进结算
	var r1 := int(s.get("_round"))
	var life0 := int((s.get("_life") as Array)[0])
	_ok(r1 == r0 + 1 or life0 < 60,
			"开战有结果（回合 %d -> %d，血量 %d）" % [r0, r1, life0])
	# 回合推进时：能量必须回复、免费刷新必须重置（否则玩家第 2 回合会卡住）
	if r1 == r0 + 1:
		_ok(int(s.get("_energy")) == 6,
				"下一回合能量回复到 6（实际 %d）" % int(s.get("_energy")))
		_ok(int(s.get("_free_rerolls")) == 1,
				"下一回合免费刷新重置（实际 %d）" % int(s.get("_free_rerolls")))

	# ★ 反向断言：上阵已满时必须拒绝，⛔ 不能静默吞掉
	var s2 := await _load(BATTLE)
	s2.set("_level", 1)
	var cap := int(s2.call("_cap"))
	var fill: Array = []
	for i in range(cap):
		fill.append({"id": "x%d" % i, "name": "占位%d" % i, "level": 1, "atk": 1})
	s2.set("_units", fill)
	var overflow: Dictionary = {"id": "y", "name": "溢出舰", "level": 1, "atk": 1}
	(s2.get("_hand") as Array).append(overflow)
	var units_before := (s2.get("_units") as Array).size()
	s2.call("_on_deploy", (s2.get("_hand") as Array).size() - 1)
	_ok((s2.get("_units") as Array).size() == units_before,
			"上阵已满时拒绝上阵（上限 %d）" % cap)


func _all_buttons(root: Node) -> Array:
	var out: Array = []
	for n in root.get_children():
		if n is Button:
			out.append(n)
		out.append_array(_all_buttons(n))
	return out
## 判断是不是商店卡 —— ⚠️ 不要用 get_global_name()。
## 星舰模块**刻意不写 class_name**（全局类表在引擎启动时读，会让老客户端解析失败），
## 所以 get_global_name() 返回空串。改按脚本资源路径判断。
const CARD_PATH := "res://scripts/starchess/sc_shop_card.gd"


func _is_card(n: Node) -> bool:
	var sc: Script = n.get_script()
	if sc == null:
		return false
	return String(sc.resource_path) == CARD_PATH

## ── 指挥官表：必须在 scripts/ 下，不能依赖 data/（data 有 .gdignore 不进包）
func _step_commanders() -> void:
	print("[8] 指挥官表：6 条 / 字段齐全 / 不依赖 data/")
	const CMD := preload("res://scripts/starchess/sc_commanders.gd")
	var rows: Array = CMD.all()
	_ok(rows.size() == 6, "指挥官 6 条（实际 %d）" % rows.size())
	_ok(CMD.validate().is_empty(), "指挥官表自检通过（%s）" % str(CMD.validate()))
	# ★ 锁死坑：这张表必须**不在** data/ 下
	var path := String((CMD as Script).resource_path)
	_ok(not path.contains("/data/"), "指挥官表不在 data/ 下（%s）" % path)
	# 拿到的必须是副本，改它不能污染源表
	if not rows.is_empty():
		(rows[0] as Dictionary)["name"] = "被改过"
		_ok(str((CMD.all()[0] as Dictionary).get("name", "")) != "被改过",
				"all() 返回副本，不会污染源表")
