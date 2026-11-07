extends Node
## 存档格式版本号工具（⛔ 用 preload 常量，别裸写 class_name —— 无头跑没有类缓存）。
const SAVE_SCHEMA := preload("res://scripts/core/eve_save_schema.gd")
## 对局存档（2#2）。
const RUN_STORE := preload("res://scripts/core/eve_run_store.gd")
## 战斗语义 id（2#5）——⛔ 新 class_name 无头下不在类缓存里，必须 preload。
const CIDS := preload("res://scripts/core/eve_combat_ids.gd")
## 舰队装配器（2⑦ 从 battle_scene 抽出的装配逻辑）。
const FLEET_FACTORY := preload("res://scripts/scene/eve_fleet_factory.gd")
## 拖放布阵控制器（2⑦ 从 battle_scene 抽出的拖放交互）。
const DEPLOY := preload("res://scripts/scene/eve_deploy_controller.gd")


## 代码审查（2026-10-10）修复项的**回归自检** —— 无头跑，退出码 = 有无失败。
##
## 这些用例直接对着 `EVE-AutoChess_代码审查报告` 里 R01–R05 的「最小复现」写，
## 修完之后它们必须**转成阻断式回归断言**（报告「修复顺序与发布验收」第 2 条）。
##
## 覆盖：
##   R01  重开清空事件选择（新局可再次选同一事件）
##   R02  打捞 5 艘上限守恒（逐艘下单也不超；钱、在途、交付三者守恒）
##   R03  我方残骸用真实星级（不套敌方关卡倍率）
##   R04  三连合成继承永久强化（`buffs` 不丢）
##   R05  黑市保底在**下一节点**落地（不再被普通刷新覆盖）
##   FIRE 连射循环内目标死亡后立即停手（kills 不重复、unit_destroyed 只发一次）
##
## 跑法：
##   "$GODOT_BIN" --headless \
##     --path . --quit-after 4000 \
##     res://tools/verify_review_fixes.tscn

var _pass := 0
var _fail := 0


func _ready() -> void:
	await get_tree().process_frame
	print("═══ verify_review_fixes ═══")
	_t_r01_restart_clears_picks()
	_t_r02_salvage_cap()
	_t_salvage_state_domain()
	_t_r03_friendly_wreck_star()
	_t_r04_merge_keeps_buffs()
	_t_r05_black_market_pending()
	_t_fire_stops_on_death()
	_t_sim_seed_reproducible()
	_t_step_accumulator()
	_t_step_tick_cap()
	_t_targeting_stability()
	_t_save_schema_version()
	_t_run_save_roundtrip()
	_t_combat_ids()
	_t_fleet_factory()
	_t_deploy_rules()
	_t_swap_cells()
	print("")
	print("═══ RESULT passed=%d failed=%d ═══" % [_pass, _fail])
	print("VERIFY_DONE failed=%d" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  ✓ %s" % msg)
	else:
		_fail += 1
		print("  ✗ [FAIL] %s" % msg)


func _new_run(p_seed: int) -> EveRunState:
	var st: EveRunState = EveRunState.new()
	add_child(st)
	st.start_run(p_seed)
	return st


# ────────────────────────────────────────────────────────────── R01
func _t_r01_restart_clears_picks() -> void:
	print("── R01 重开清空事件选择 ──")
	var st := _new_run(11)
	st.field.clear()
	st.field.append({"ship_key": &"punisher", "star": 1, "cell": Vector2i(0, 0)})
	st.apply_event(&"weapon_tune", st.field_entries()[0])
	st.apply_event(&"beacon_repair")
	_ok(st.event_picks.size() == 2,
			"选 2 条事件后记录 = 2（实际 %d）" % st.event_picks.size())
	# 重开（**复用同一个 run 对象**，与 restart_run() 同款）
	st.start_run(12)
	_ok(st.event_picks.is_empty(),
			"★ R01 重开后事件记录清空（实际 %d 条）" % st.event_picks.size())
	_ok(st.can_pick_event(&"weapon_tune"),
			"★ R01 新局「武器调校」恢复可选")
	var again := st.apply_event(&"beacon_repair")
	_ok(not again.is_empty(), "★ R01 新局「紧急维修」能再次落地（不再是 0 选项）")


# ────────────────────────────────────────────────────────────── R02
func _t_r02_salvage_cap() -> void:
	print("── R02 打捞 5 艘上限守恒 ──")
	var st := _new_run(21)
	st.set_phase(EveRunState.Phase.RESOLVE)
	st.wrecks.clear()
	st.wrecks_display.clear()
	for i in 6:
		st.wrecks.append({"ship_key": &"punisher", "name": "惩罚者 %d" % i,
				"star": 1, "cost": 1, "team": 0})
		st.wrecks_display.append({"star": 1, "m": 1.0})
	st.coin = 50
	# 模拟 UI 的真实调用方式：**每点一艘调一次** `salvage_order([idx])`
	var bought_total := 0
	for i in 6:
		var r := st.salvage_order([0])
		if bool(r.get("ok", false)):
			bought_total += (r.get("bought", []) as Array).size()
	_ok(bought_total == 5,
			"★ R02 逐艘下单最多成交 5 艘（实际 %d）" % bought_total)
	_ok(st.repair_queue.size() <= 5,
			"★ R02 在途队列不超过 5（实际 %d）" % st.repair_queue.size())
	var spent := 50 - st.coin
	_ok(spent == st.repair_queue.size(),
			"★ R02 付费艘数 == 在途艘数（花 %d ◆ / 在途 %d 艘）"
			% [spent, st.repair_queue.size()])
	# 推进到下一节点：交付不许吞货
	var in_flight := st.repair_queue.size()
	st.advance()
	var delivered := 0
	for i in st.offers.size():
		var o = st.offers[i]
		if o is Dictionary and (o as Dictionary).has("from_node"):
			delivered += 1
	_ok(delivered == in_flight and st.repair_queue.is_empty(),
			"★ R02 交付 %d 艘（在途 %d）且队列清空，无静默丢失"
			% [delivered, in_flight])


# ────────────────────────────────────────────────────────────── C-P1-1
## ★ C-P1-1（2026-10-11 三源审查）：`salvage_info()` 的值域契约。
## 全部消费方（商店只读看板 / 结算页打捞区）都只认 ""/"list"/"repairing"；
## 这里用真实场景把值域钉死，防未来有人发明第四种 state 让 UI 静默走空。
func _t_salvage_state_domain() -> void:
	print("── C-P1-1 salvage_info() 值域契约 ──")
	# ① 有残骸待捡 ⇒ "list"（结算页打捞区消费；商店框按空态引导渲染）
	var st := _new_run(31)
	st.set_phase(EveRunState.Phase.RESOLVE)
	st.wrecks.append({"ship_key": &"punisher", "name": "惩罚者",
			"star": 1, "cost": 1, "team": 0})
	st.wrecks_display.append({"star": 1, "m": 1.0})
	var info := st.salvage_info()
	_ok(String(info.get("state", "")) == "list",
			"★ 有残骸 ⇒ state=\"list\"（旧注释写的 \"wreck\" 不是真实值域）")
	_ok((info.get("items", []) as Array).size() == 1, "\"list\" 携带 items 供结算页渲染")
	# ② 无残骸、有在途队列 ⇒ "repairing"
	var st2 := _new_run(32)
	st2.set_phase(EveRunState.Phase.RESOLVE)
	st2.repair_queue.append({"ship_key": &"punisher", "name": "惩罚者",
			"star": 1, "cost": 1, "evt": 1})
	var info2 := st2.salvage_info()
	_ok(String(info2.get("state", "")) == "repairing", "仅在途队列 ⇒ state=\"repairing\"")
	# ③ 两者皆无 ⇒ {}（空字典）
	var st3 := _new_run(33)
	st3.set_phase(EveRunState.Phase.RESOLVE)
	_ok(st3.salvage_info().is_empty(), "无残骸无队列 ⇒ {}（空态）")


# ────────────────────────────────────────────────────────────── R03
func _t_r03_friendly_wreck_star() -> void:
	print("── R03 我方残骸真实星级 ──")
	for sc in [1.0, 1.25, 1.30]:
		var st := _new_run(int(31 + round(sc * 10.0)))
		st.resolve_battle(1, [{"ship_key": &"punisher", "name": "惩罚者", "star": 2}],
				[{"star": 2, "atk_base": 13.0, "def_base": 90.0,
				  "shot": 13.0 * sc, "m": sc, "team": 0}], sc)
		var got := 0
		if st.wrecks.size() > 0:
			got = int((st.wrecks[0] as Dictionary).get("star", 0))
		_ok(got == 2,
				"★ R03 我方二星残骸在倍率 %.2f 下仍为 2★（实际 %d★）" % [sc, got])
	# 敌方残骸仍走既有规则（未放大时按 shot 反解）
	var st2 := _new_run(39)
	st2.resolve_battle(0, [{"ship_key": &"punisher", "name": "惩罚者", "star": 1}],
			[{"star": 1, "atk_base": 13.0, "def_base": 90.0,
			  "shot": 13.0, "m": 1.0, "team": 1}], 1.0)
	var foe_star := int((st2.wrecks[0] as Dictionary).get("star", 0)) if st2.wrecks.size() > 0 else 0
	_ok(foe_star == 1, "★ R03 敌方残骸（scale 1.0）仍判 1★（实际 %d★）" % foe_star)


# ────────────────────────────────────────────────────────────── R04
func _t_r04_merge_keeps_buffs() -> void:
	print("── R04 合成继承永久强化 ──")
	var st := _new_run(41)
	st.field.clear()
	st.bench.clear()
	# 强化放在**中间那一条**（防「只复制第一条材料」的伪修法）
	st.bench.append({"ship_key": &"punisher", "star": 1, "cell": Vector2i(-1, -1)})
	st.bench.append({"ship_key": &"punisher", "star": 1, "cell": Vector2i(-1, -1),
			"buffs": {"attack_pct": 0.08}})
	st.bench.append({"ship_key": &"punisher", "star": 1, "cell": Vector2i(-1, -1)})
	var merged := st._try_merge()
	var hit := 0
	for e in st.bench:
		if int(e.get("star", 1)) == 2:
			var b: Dictionary = e.get("buffs", {})
			if absf(float(b.get("attack_pct", 0.0)) - 0.08) < 0.0001:
				hit += 1
	_ok(merged, "三连合成发生")
	_ok(hit == 1,
			"★ R04 合成出来的 2★ 仍带 attack_pct=0.08（实际命中 %d 条）" % hit)


# ────────────────────────────────────────────────────────────── R05
func _t_r05_black_market_pending() -> void:
	print("── R05 黑市保底（待应用效果） ──")
	var st := _new_run(51)
	st.level = 1
	st.overtier = 0
	st.set_phase(EveRunState.Phase.RESOLVE)
	st.apply_event(&"black_market")
	st.advance()          # 推进到下一节点：普通 roll + 保底落地
	var hi := 0
	for d in st.offers:
		# ⚠️ 档次口径（见 `EveRunState.offer_tier`）：黑市同一次刷新还会把整批
		#    货架改成半价，`cost` 已被覆写，裸读会把"保底落地"误判成没落地。
		if EveRunState.offer_tier(d as Dictionary) >= 3:
			hi += 1
	_ok(hi >= 1,
			"★ R05 下一节点货架保底 ≥1 艘档次≥3（实际 %d 艘）—— 不再被覆盖" % hi)


# ─────────────────────────────────────────────────────── 连射停手（bug#3）
func _t_fire_stops_on_death() -> void:
	print("── 连射循环内目标死亡即停手 ──")
	var a := EveShipDatabase.instantiate_by_id("punisher", 0, 9911)
	var b := EveShipDatabase.instantiate_by_id("rifter", 1, 9912)
	_ok(a != null and b != null, "建船成功")
	if a == null or b == null:
		return
	var sim := EveBattleSimulator.new()
	sim.setup([a], [b])
	# 目标只剩 1 滴结构 ⇒ 命中即死；给攻击者一个**极小循环周期**，
	# 让一次 `_try_fire()` 里有大量射击机会（复现"补 tick / 高射速"）。
	b.hp[&"hull"] = 1.0
	b.hp[&"armor"] = 0.0
	b.hp[&"shield"] = 0.0
	a.weapon_cycle = 0.01
	a.weapon_timer = 0.0
	a.target_id = b.id
	var destroyed := [0]          # ⚠️ GDScript lambda 按**值**捕获局部变量 ⇒ 用数组（引用）累加
	sim.unit_destroyed.connect(func(_s) -> void: destroyed[0] += 1)
	# 直接连调 `_try_fire`（每次传入很大的 dt，等价于"一次补很多 tick"）
	for i in 8:
		sim._try_fire(a, 10.0)
		if not b.alive:
			break
	_ok(a.kills == 1,
			"★ FIRE 击杀只记 1 次（实际 kills=%d）—— 旧代码会重复 +1" % a.kills)
	_ok(destroyed[0] == 1,
			"★ FIRE unit_destroyed 只发 1 次（实际 %d）" % destroyed[0])


# ═══════════════════════════════════════════ 审查 #4 / 2#1：可复现 + 真固定步长
func _hp_sum(s: EveShip) -> float:
	return float(s.hp[&"shield"]) + float(s.hp[&"armor"]) + float(s.hp[&"hull"])


## 造一场「同 id 同编组」的 1v1，注入种子后推进固定 tick，返回可观测量。
func _seeded_run(seed_v: int, ticks: int) -> Dictionary:
	var a: EveShip = EveShipDatabase.instantiate_by_id("punisher", 0, 8101)
	var b: EveShip = EveShipDatabase.instantiate_by_id("rifter", 1, 8102)
	var own: Array[EveShip] = [a]
	var foe: Array[EveShip] = [b]
	var sim := EveBattleSimulator.new()
	sim.set_seed(seed_v)
	sim.setup(own, foe)
	for _i in ticks:
		sim.step(EveBattleSimulator.FIXED_STEP)
	return {"tick": sim.tick, "kills_a": a.kills, "kills_b": b.kills,
			"hp_a": _hp_sum(a), "hp_b": _hp_sum(b)}


func _t_sim_seed_reproducible() -> void:
	print("── #4 战斗随机数可复现 ──")
	var r1 := _seeded_run(12345, 900)
	var r1b := _seeded_run(12345, 900)
	_ok(r1 == r1b,
			"★ 同种子两次战斗**逐 tick 相同**（tick=%d · hp=%.1f/%.1f）"
			% [int(r1["tick"]), float(r1["hp_a"]), float(r1["hp_b"])])
	var r2 := _seeded_run(12346, 900)
	_ok(r1 != r2,
			"★ 换一个种子结果就不同（种子 12346 → hp=%.1f/%.1f）"
			% [float(r2["hp_a"]), float(r2["hp_b"])])


func _t_step_accumulator() -> void:
	print("── 2#1 真固定步长（时间累加器） ──")
	var a1: EveShip = EveShipDatabase.instantiate_by_id("punisher", 0, 8201)
	var b1: EveShip = EveShipDatabase.instantiate_by_id("rifter", 1, 8202)
	var o1: Array[EveShip] = [a1]
	var f1: Array[EveShip] = [b1]
	var s1 := EveBattleSimulator.new()
	s1.set_seed(7)
	s1.setup(o1, f1)
	# ① 一帧 1/30 与 两帧 1/60 ⇒ 必须**完全等价**（旧实现里 1/60 会变成更短的 tick）
	s1.step(EveBattleSimulator.FIXED_STEP)
	var one := {"tick": s1.tick, "elapsed": s1.elapsed}
	var a2: EveShip = EveShipDatabase.instantiate_by_id("punisher", 0, 8301)
	var b2: EveShip = EveShipDatabase.instantiate_by_id("rifter", 1, 8302)
	var o2: Array[EveShip] = [a2]
	var f2: Array[EveShip] = [b2]
	var s2 := EveBattleSimulator.new()
	s2.set_seed(7)
	s2.setup(o2, f2)
	s2.step(1.0 / 60.0)
	s2.step(1.0 / 60.0)
	_ok(s2.tick == one["tick"] and absf(s2.elapsed - float(one["elapsed"])) < 1e-9,
			"★ step(1/30) ≡ step(1/60)×2（tick %d vs %d · elapsed %.4f vs %.4f）"
			% [int(one["tick"]), s2.tick, float(one["elapsed"]), s2.elapsed])
	# ② 半帧不足一个 tick ⇒ 不出 tick，零头留到下一帧
	var a3: EveShip = EveShipDatabase.instantiate_by_id("punisher", 0, 8401)
	var b3: EveShip = EveShipDatabase.instantiate_by_id("rifter", 1, 8402)
	var o3: Array[EveShip] = [a3]
	var f3: Array[EveShip] = [b3]
	var s3 := EveBattleSimulator.new()
	s3.setup(o3, f3)
	s3.step(EveBattleSimulator.FIXED_STEP * 0.4)
	_ok(s3.tick == 0, "★ 不足一个 FIXED_STEP 不出 tick（实际 tick=%d）" % s3.tick)
	s3.step(EveBattleSimulator.FIXED_STEP * 0.6)
	_ok(s3.tick == 1, "★ 零头跨帧凑够 ⇒ 出 1 个 tick（实际 tick=%d）" % s3.tick)
	# ③ run_seconds：跑满（无单帧上限）
	var a4: EveShip = EveShipDatabase.instantiate_by_id("punisher", 0, 8501)
	var b4: EveShip = EveShipDatabase.instantiate_by_id("rifter", 1, 8502)
	var o4: Array[EveShip] = [a4]
	var f4: Array[EveShip] = [b4]
	var s4 := EveBattleSimulator.new()
	s4.setup(o4, f4)
	s4.run_seconds(1.0)
	_ok(s4.tick == 30 and absf(s4.elapsed - 1.0) < 1e-6,
			"★ run_seconds(1.0) ⇒ 30 tick / elapsed=1.0（实际 %d / %.4f）"
			% [s4.tick, s4.elapsed])


func _t_step_tick_cap() -> void:
	print("── 2#1 单帧 tick 上限（防死亡螺旋） ──")
	var a: EveShip = EveShipDatabase.instantiate_by_id("punisher", 0, 8601)
	var b: EveShip = EveShipDatabase.instantiate_by_id("rifter", 1, 8602)
	var own: Array[EveShip] = [a]
	var foe: Array[EveShip] = [b]
	var sim := EveBattleSimulator.new()
	sim.setup(own, foe)
	sim.step(10.0)          # 10 秒 = 300 tick 的时间量
	_ok(sim.tick <= EveBattleSimulator.MAX_TICKS_PER_STEP,
			"★ 一帧最多补 %d tick（实际 %d）—— 不会「卡一帧补几百 tick」"
			% [EveBattleSimulator.MAX_TICKS_PER_STEP, sim.tick])


func _t_targeting_stability() -> void:
	print("── #5 选目标稳定性（迟滞护栏） ──")
	var a: EveShip = EveShipDatabase.instantiate_by_id("punisher", 0, 8701)
	var e1: EveShip = EveShipDatabase.instantiate_by_id("rifter", 1, 8702)
	var e2: EveShip = EveShipDatabase.instantiate_by_id("rifter", 1, 8703)
	var own: Array[EveShip] = [a]
	var foe: Array[EveShip] = [e1, e2]
	var sim := EveBattleSimulator.new()
	sim.set_seed(99)
	sim.setup(own, foe)
	# 45/46 轮的原始病灶：`slasher` 逐帧翻目标、`_target_switches` 冲到"每帧一次"
	# （3000 帧 × 5 艘 ⇒ 万级）。这里用 900 tick 做护栏：切换次数必须远小于 tick 数。
	for _i in 900:
		sim.step(EveBattleSimulator.FIXED_STEP)
		sim._refresh_targets()
	_ok(int(sim._target_switches) <= 60,
			"★ 900 tick 内换目标 %d 次（护栏 ≤60；逐帧翻目标会是数百~上千）"
			% int(sim._target_switches))


# ═══════════════════════════════════════════════════════ 2#3 存档版本号
func _read_file(p: String) -> PackedByteArray:
	if not FileAccess.file_exists(p):
		return PackedByteArray()
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	return f.get_buffer(f.get_length())


func _restore_file(p: String, b: PackedByteArray) -> void:
	if b.is_empty():
		var abs := ProjectSettings.globalize_path(p)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(abs)
		return
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f != null:
		f.store_buffer(b)


## 盘上某个文件的**内容签名**（不存在 = ""）。
## ⛔ 判据用它代替 `has_run()`：后者会随"玩家有没有真档"而变（假红/假绿）。
func _file_sig(p: String) -> String:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return ""
	return f.get_buffer(f.get_length()).hex_encode()


func _t_save_schema_version() -> void:
	print("── 2#3 存档 schema_version ──")
	# ① 纯逻辑（无盘）
	var cf := ConfigFile.new()
	_ok(SAVE_SCHEMA.version(cf) == 0, "新档无版本号时读作 0")
	SAVE_SCHEMA.stamp(cf, 3)
	_ok(SAVE_SCHEMA.version(cf) == 3, "stamp 后读回 3")
	_ok(not SAVE_SCHEMA.needs_migration("x", 3, 3), "同版本 ⇒ 不迁移")
	_ok(SAVE_SCHEMA.needs_migration("x", 0, 3), "旧版本 0 ⇒ 要迁移（老档也读得进）")
	_ok(not SAVE_SCHEMA.needs_migration("x", 9, 3), "更高版本 ⇒ 不迁移（只警告，不写坏别人的档）")
	# ② 真存档往返：**老格式（无 meta）也读得对**；写盘会盖上版本号
	#    ⚠️ 全程快照 + 原样还原，绝不留在玩家的档上。
	var snap_p := _read_file(EveProgressStore.PATH)
	var old := ConfigFile.new()
	old.set_value(EveProgressStore.SECTION, "intro_seen", true)   # 老档：只有业务段
	old.save(EveProgressStore.PATH)
	var d := EveProgressStore.load_all()
	_ok(bool(d["intro_seen"]), "★ 老档（无 schema_version）仍能正确读出 intro_seen=true")
	EveProgressStore.save_all(d)
	var after := ConfigFile.new()
	after.load(EveProgressStore.PATH)
	_ok(SAVE_SCHEMA.version(after) == EveProgressStore.SCHEMA_VERSION,
			"★ 写盘后盖上 schema_version=%d（实际 %d）"
			% [EveProgressStore.SCHEMA_VERSION, SAVE_SCHEMA.version(after)])
	_restore_file(EveProgressStore.PATH, snap_p)
	# ③ 动态键的存档（窗口布局）也要盖版本号
	var snap_w := _read_file(EveWindowStore.PATH)
	var prev_persist := EveWindowStore.persist
	EveWindowStore.persist = true
	EveWindowStore.save_window("__verify_tmp__", {"x": 1.0, "y": 2.0})
	var wcf := ConfigFile.new()
	wcf.load(EveWindowStore.PATH)
	_ok(SAVE_SCHEMA.version(wcf) == EveWindowStore.SCHEMA_VERSION,
			"★ 窗口布局档也带 schema_version=%d（实际 %d）"
			% [EveWindowStore.SCHEMA_VERSION, SAVE_SCHEMA.version(wcf)])
	_restore_file(EveWindowStore.PATH, snap_w)
	EveWindowStore.persist = prev_persist


# ═══════════════════════════════════════════════════════ 2#2 对局存档
func _t_run_save_roundtrip() -> void:
	print("── 2#2 对局存档（to_dict / from_dict / store） ──")
	var snap := _read_file(RUN_STORE.PATH)
	# ① 造一局「有内容」的（数值 + 编制 + 事件 + 棋盘格 + 强化）
	var a := _new_run(2026)
	a.coin = 37
	a.level = 4
	a.xp = 9
	a.beacon = 61
	a.node_index = 5
	a.overtier = 2
	a.win_streak = 3
	a.lose_streak = 0
	a.shop_locked = true
	a.boss_attempts = 1
	a.event_picks.clear()
	a.event_picks.append(&"weapon_tune")
	a.field.clear()
	a.bench.clear()
	a.field.append({"ship_key": &"punisher", "star": 2, "cell": Vector2i(1, 2),
			"buffs": {"attack_pct": 0.08}})
	a.bench.append({"ship_key": &"condor", "star": 1, "cell": Vector2i(-1, -1)})
	a.phase = EveRunState.Phase.PREP
	var d := a.to_dict()
	# ② 还原到**另一个** run 上（模拟"关掉游戏再开")
	var b: EveRunState = EveRunState.new()
	add_child(b)
	_ok(b.from_dict(d), "from_dict 返回成功")
	_ok(b.coin == 37 and b.level == 4 and b.xp == 9 and b.beacon == 61,
			"★ 数值还原（币%d 等级%d 经验%d 信标%d）" % [b.coin, b.level, b.xp, b.beacon])
	_ok(b.node_index == 5 and b.overtier == 2 and b.win_streak == 3 and b.shop_locked,
			"★ 进度还原（节点%d 超频%d 连胜%d 锁店%s）"
			% [b.node_index, b.overtier, b.win_streak, str(b.shop_locked)])
	_ok(b.event_picks.size() == 1 and String(b.event_picks[0]) == "weapon_tune",
			"★ 事件记录还原（%s）" % str(b.event_picks))
	_ok(b.field.size() == 1 and int(b.field[0].get("star", 0)) == 2,
			"★ 场上编制还原（%d 艘）" % b.field.size())
	var cell_v: Vector2i = b.field[0].get("cell", Vector2i.ZERO)
	_ok(cell_v == Vector2i(1, 2),
			"★ 棋盘格号还原（ConfigFile 往返 Vector2i）：%s" % str(cell_v))
	# ★★ 2026-10-25：商店货架必须一起还原。
	#   症状：读档后商店一片空白 —— `from_dict()` 不发 `offers_changed`
	#   （那条信号会重摇），HUD 只在信号里重建卡片 ⇒ 数据在、界面空。
	#   这里守的是**数据这一半**；界面那一半由 battle_scene 读档后显式推一次
	#   `hud.set_shop_offers(run.offers)` 接上。
	_ok(b.offers.size() == a.offers.size() and b.offers.size() > 0,
			"★ 商店货架还原（%d 格，原 %d 格）" % [b.offers.size(), a.offers.size()])
	var same_offer := true
	for i in mini(a.offers.size(), b.offers.size()):
		var ka := String((a.offers[i] as Dictionary).get("ship_key", ""))
		var kb := String((b.offers[i] as Dictionary).get("ship_key", ""))
		if ka != kb:
			same_offer = false
	_ok(same_offer, "★ 货架逐格同船（不是读档时重摇的）")
	var bf: Dictionary = b.field[0].get("buffs", {})
	_ok(absf(float(bf.get("attack_pct", 0.0)) - 0.08) < 1e-6,
			"★ 永久强化还原（attack_pct=%.2f）" % float(bf.get("attack_pct", 0.0)))
	_ok(str(a.to_dict()) == str(d), "★ to_dict 幂等（同一局两次序列化一致）")
	# ③ store：闸门 / 往返 / 版本不符丢弃 / 删档
	RUN_STORE.persist = true
	# ⚠️ 判据是「**盘上签名不变**」，⛔ 不是 `not has_run()`：
	#    后者假设"自检开始前盘上没有对局存档"，而玩家机器上**常常有真档**
	#    （2026-10-11 就这样误红了一条，改的人还以为是自己改坏的）。
	#    改成比对签名后，无论盘上本来有没有档都成立，且**不会动玩家存档**。
	var sig_before := _file_sig(RUN_STORE.PATH)
	RUN_STORE.session_active = false
	RUN_STORE.save_run(d)
	_ok(_file_sig(RUN_STORE.PATH) == sig_before,
			"★ 非真实会话（session_active=false）**不写盘**（盘上签名不变）")
	RUN_STORE.session_active = true
	RUN_STORE.save_run(d)
	_ok(_file_sig(RUN_STORE.PATH) != sig_before, "★ 真实会话才写盘（签名变了）")
	_ok(RUN_STORE.has_run(), "★ 真实会话写完后 `has_run()` 为真")
	var back := RUN_STORE.load_run()
	_ok(int(back.get("coin", -1)) == 37 and int(back.get("node_index", -1)) == 5,
			"★ 从盘上读回（coin=%d node=%d）" % [int(back.get("coin", -1)), int(back.get("node_index", -1))])
	# 版本不符 ⇒ 丢弃（对局存档不做迁移）
	var cf := ConfigFile.new()
	cf.set_value(RUN_STORE.SECTION, RUN_STORE.KEY, d)
	SAVE_SCHEMA.stamp(cf, RUN_STORE.SCHEMA_VERSION + 1)
	cf.save(RUN_STORE.PATH)
	_ok(RUN_STORE.load_run().is_empty(), "★ schema_version 不符 ⇒ 丢弃（不迁移）")
	_ok(not RUN_STORE.has_run(), "★ 丢弃后旧档已删除")
	# 删档闸门：非真实会话不许删玩家档
	RUN_STORE.save_run(d)
	RUN_STORE.session_active = false
	RUN_STORE.clear()
	_ok(RUN_STORE.has_run(), "★ 非真实会话 `clear()` 也不许删玩家档（自检防污染）")
	RUN_STORE.session_active = true
	RUN_STORE.clear()
	_ok(not RUN_STORE.has_run(), "★ 真实会话 `clear()` 删档")
	RUN_STORE.session_active = false
	_restore_file(RUN_STORE.PATH, snap)


# ═══════════════════════════════════════════════════════ 2#5 战斗语义 id
func _t_combat_ids() -> void:
	print("── 2#5 中文不再当逻辑主键（武器/防御/定位 → id） ──")
	# ① 52 艘全部映射得出 id（映射表覆盖完整）
	var bad := 0
	var empty_ids := 0
	for row in EveShipTable.ROWS:
		var r: Array = row
		var w := CIDS.weapon_id_of(String(r[3]))
		var d := CIDS.defense_id_of(String(r[4]))
		var ro := CIDS.role_id_of(String(r[6]))
		if w == &"" or d == &"" or ro == &"":
			empty_ids += 1
			if empty_ids <= 3:
				print("      ✗ %s 映射出空 id（%s/%s/%s）" % [str(r[0]), w, d, ro])
		if not CIDS.unknown_values(String(r[3]), String(r[4]), String(r[6])).is_empty():
			bad += 1
	_ok(empty_ids == 0, "★ 52 艘的武器/防御/定位**全部**映射到非空 id")
	_ok(bad == 0, "★ 52 艘无未知取值（`unknown_values` 全过）")
	# ② 表校验走同一份白名单（⛔ 不再各写一份中文列表）
	_ok(EveShipTable.validate().is_empty(),
			"★ `EveShipTable.validate()` 无问题（白名单唯一来源）")
	# ③ ★ 牙齿：**故意写错一个字**，必须被抓到（旧写法会静默走 else 分支）
	var typo := CIDS.unknown_values("导弹炮", "盾抗", "后勤")
	_ok(typo.size() == 1 and String(typo[0]) == "武器=导弹炮",
			"★ 反向注入：武器写成「导弹炮」⇒ 报 1 条（实际 %d 条：%s）"
			% [typo.size(), ", ".join(typo)])
	_ok(CIDS.weapon_id_of("导弹炮") == &"",
			"★ 反向注入：错字的 id 为空（不会被当成任何已知武器）")
	# ④ 造一艘真船：typed 字段与派生字典一致（映射没漂）
	var s: EveShip = EveShipDatabase.instantiate_by_id("condor", 0, 9701)
	_ok(s != null and s.weapon_id == CIDS.W_MISSILE,
			"★ condor（小鹰级·导弹）的 `weapon_id` = missile")
	_ok(s != null and s.defense_id == CIDS.D_SHIELD and s.role_id == CIDS.R_ATTACK,
			"★ condor 的 `defense_id`=shield · `role_id`=attack")
	_ok(s != null and String(s.weapon_type) == CIDS.WEAPON_LABEL.get(s.weapon_id, ""),
			"★ id ↔ 中文显示名一致（%s ↔ %s）"
			% [s.weapon_id if s != null else "?", s.weapon_type if s != null else "?"])


# ────────────────────────────────────────────────────────────── 2⑦ 舰队装配器
## 装配逻辑从 2400 行主控里搬出后，必须能**只喂一个 run**就验（不必起战斗场景）。
## 顺带钉住两条最容易被后人改坏的不变量：id 唯一、下标映射不错位。
func _t_fleet_factory() -> void:
	print("── 舰队装配器（2⑦ 从 battle_scene 抽出的缝口）──")
	var st := _new_run(77)
	st.field.clear()
	st.field.append({"ship_key": &"punisher", "star": 1, "cell": Vector2i(0, 0)})
	st.field.append({"ship_key": &"executioner", "star": 2, "cell": Vector2i(1, 0)})

	var f = FLEET_FACTORY.new()
	var own: Array = f.build_own(st)
	_ok(own.size() == st.field_entries().size(),
			"build_own 逐条造出（%d／%d）" % [own.size(), st.field_entries().size()])
	_ok(f.last_idx_map.size() == own.size(),
			"★ idx_map 与返回数组同长（拖放靠它翻「场上→名单」下标）")
	var aligned := true
	for i in own.size():
		var fe: Dictionary = st.field_entries()[f.last_idx_map[i]]
		if String(fe.get("ship_key", "")) != String(own[i].ship_key):
			aligned = false
	_ok(aligned, "★ idx_map[i] 指向的名单项与 ships[i] 是同一艘（不错位 ⇒ 不会拖 A 飞 B）")
	_ok(int(own[1].star) == 2, "星级带过来（实测 %d）" % int(own[1].star))

	# id 跨两条链唯一（否则拖放/选中的按 id 查找会串到敌舰上）
	var enemy: Array = f.build_enemy(st)
	var seen := {}
	var dup := false
	for s in own + enemy:
		if seen.has(s.id):
			dup = true
		seen[s.id] = true
	_ok(not dup and seen.size() == own.size() + enemy.size(),
			"★ 敌我两支舰队实例 id 互不相同（共 %d 个）" % seen.size())

	var nm: PackedStringArray = FLEET_FACTORY.names_of(own)
	_ok(nm.size() == own.size() and nm[0] == own[0].ship_name,
			"names_of 与舰队一一对应")

	# apply_doctrine 是纯规则：远程环绕船强制拉开、交战距离兜底 ≥ 2km
	var probe: EveShip = EveShipDatabase.instantiate_by_id("punisher", 0, 9999)
	probe.stance = EveCombatCore.Stance.ORBIT
	probe.optimal_range = 25000.0
	probe.desired_range = 0.0
	FLEET_FACTORY.apply_doctrine(probe)
	_ok(probe.stance == EveCombatCore.Stance.KEEP,
			"★ 远程环绕（ORBIT）船被改成保持距离（KEEP）")
	_ok(probe.desired_range >= 2000.0,
			"★ 交战距离兜底 ≥ 2km（实测 %.0f）" % probe.desired_range)




# ────────────────────────────────────────────────────────────── 2⑦ 拖放规则
## 拖动控制器搬出后，「松手会怎样」的文案规则必须能**脱离拖拽上下文直接验** ——
## 被拒的静默路径要给「指对方向」的理由（红线：别摆「看着能点、点了没反应」）。
## 另外 `verify_run._step_b_drag` 已经从**主控侧**验证了「拖动状态字典共享」
## 这条集成不变量（它读 `_battle.get("_drag")`），这里只补纯规则。
func _t_deploy_rules() -> void:
	print("── 拖放控制器：落点文案规则（2⑦ 第二刀）──")
	var bench := &"bench"
	var field := &"field"
	var far := Vector2i(3, 2)

	var r := DEPLOY.resolve_hint(bench, true, false, {}, false, false, 0, 8, far, 12)
	_ok(bool(r["ok"]) and String(r["hint"]).contains("出售") and String(r["hint"]).contains("12"),
			"出售：文案带返还金额（%s）" % r["hint"])

	r = DEPLOY.resolve_hint(bench, false, true, {"ok": true}, false, false, 0, 8, far, 12)
	_ok(bool(r["ok"]) and String(r["hint"]) == "部署到 第 4 行第 3 列",
			"部署：写明确格号（%s）" % r["hint"])

	r = DEPLOY.resolve_hint(field, false, true, {"ok": true}, false, false, 0, 8, far, 12)
	_ok(bool(r["ok"]) and String(r["hint"]) == "移动到这里", "换位：移动到这里（%s）" % r["hint"])

	r = DEPLOY.resolve_hint(bench, false, true, {"ok": false, "reason": "该格已被占用"},
			false, false, 0, 8, far, 12)
	_ok(not bool(r["ok"]) and String(r["hint"]) == "该格已被占用",
			"★ 被拒：原样透出 RunState 的理由（%s）" % r["hint"])

	r = DEPLOY.resolve_hint(bench, false, true, {"ok": false}, false, false, 0, 8, far, 12)
	_ok(not bool(r["ok"]) and String(r["hint"]) == "不能放在这里",
			"★ 被拒且无理由：兜底「不能放在这里」（%s）" % r["hint"])

	r = DEPLOY.resolve_hint(field, false, false, {}, true, true, 0, 8, far, 12)
	_ok(bool(r["ok"]) and String(r["hint"]) == "撤回备战席", "撤回：撤回备战席（%s）" % r["hint"])

	r = DEPLOY.resolve_hint(field, false, false, {}, true, false, 8, 8, far, 12)
	_ok(not bool(r["ok"]) and String(r["hint"]).contains("已满") and String(r["hint"]).contains("8／8"),
			"★ 备战席满：报出 n／m（%s）" % r["hint"])

	r = DEPLOY.resolve_hint(bench, false, false, {}, true, false, 8, 8, far, 12)
	_ok(bool(r["ok"]) and String(r["hint"]) == "放回备战席", "放回：放回备战席（%s）" % r["hint"])

	r = DEPLOY.resolve_hint(bench, false, false, {}, false, false, 0, 8, far, 12)
	_ok(not bool(r["ok"]) and String(r["hint"]).contains("部署区"),
			"空白处：提示拖到部署区/商店（%s）" % r["hint"])

	# make_drag：返还 = cost × 3^(star-1)（与 RunState.sell_value 同口径）
	var db := EveShipDatabase.by_id("punisher")
	var cost := int(db.get("cost", 1))
	var d := DEPLOY.make_drag({"ship_key": &"punisher", "star": 3}, &"bench", 2)
	_ok(int(d["refund"]) == cost * 9,
			"make_drag 返还 = cost×3^(star-1)（%d = %d×9）" % [int(d["refund"]), cost])
	_ok(StringName(d["source"]) == &"bench" and int(d["index"]) == 2,
			"make_drag 带上来源与下标")

	# ghost_payload：字段映射（HUD 侧 _DragGhost.apply 的约定）
	var g := DEPLOY.ghost_payload({"name": "测试舰级", "star": 2, "cost": 3,
			"hint": "移动到这里", "hint_ok": true})
	_ok(bool(g["active"]) and String(g["name"]) == "测试舰级" and bool(g["hint_ok"]),
			"ghost_payload 字段映射正确（active/name/hint_ok）")

	# ★★ 2026-11-07 互换：落点有船时提示必须**点名对方**，不能还是「移动到这里」
	r = DEPLOY.resolve_hint(field, false, true,
			{"ok": true, "swap": true, "swap_name": "死亡旋涡级"},
			false, false, 0, 8, far, 12)
	_ok(bool(r["ok"]) and String(r["hint"]) == "与 死亡旋涡级 互换位置",
			"互换：点名对方（%s）" % r["hint"])
	r = DEPLOY.resolve_hint(bench, false, true,
			{"ok": true, "swap": true, "swap_name": "鲲鹏级"},
			false, false, 0, 8, far, 12)
	_ok(bool(r["ok"]) and String(r["hint"]).contains("鲲鹏级")
			and not String(r["hint"]).contains("部署到"),
			"互换：备战席起点也走互换文案（%s）" % r["hint"])


## 互换位子 —— 2026-11-07 玩家要求：
##   「棋盘上的船需要能互换位子。现在需要三个步骤去调位子，太过于麻烦。」
##
## 验四件事：① 场上↔场上 两艘格号对调、数量不变
##          ② 拖回自己那一格是合法 no-op（不该再报「这一格已经有船了」）
##          ③ 备战席→占用格：进场，被顶掉的回**腾出来的那个备战席格**，两边数量都不变
##          ④ 满员时照样能换（互换不占新人口 ⇒ 不能拿 field_limit 卡它）
##          ⑤ `preview_place` 与实做同口径（占用格 ok + swap；空格不带 swap）
func _t_swap_cells() -> void:
	print("── 互换位子（拖到已有船的格子）──")
	var st := _new_run(77)
	st.level = 4
	st.field.clear()
	st.bench.clear()
	st.field.append({"ship_key": &"punisher", "star": 1, "cell": Vector2i(8, 5)})
	st.field.append({"ship_key": &"kestrel", "star": 1, "cell": Vector2i(9, 2)})

	# ① 场上 ↔ 场上
	var r := st.move_field(0, 9, 2)
	_ok(bool(r.get("ok", false)) and bool(r.get("data", {}).get("swap", false)),
			"场上↔场上：允许落，且标了 swap")
	_ok(st.field[0].get("cell") == Vector2i(9, 2)
			and st.field[1].get("cell") == Vector2i(8, 5),
			"场上↔场上：两艘格号对调（%s / %s）" % [
				str(st.field[0].get("cell")), str(st.field[1].get("cell"))])
	_ok(st.field.size() == 2, "场上↔场上：上场数不变（%d）" % st.field.size())

	# ② 拖回自己那一格
	r = st.move_field(0, 9, 2)
	_ok(bool(r.get("ok", false)) and not bool(r.get("data", {}).get("swap", false)),
			"拖回自己格：ok 且不算 swap（旧版这里会报「这一格已经有船了」）")

	# ③ 备战席 → 占用的格
	st.bench.append({"ship_key": &"kestrel", "star": 2, "cell": Vector2i(-1, -1)})
	var bench_before := st.bench.size()
	var field_before := st.field.size()
	r = st.deploy_from_bench(0, 9, 2)          # (9,2) 上现在是 punisher
	_ok(bool(r.get("ok", false)) and bool(r.get("data", {}).get("swap", false)),
			"备战席→占用格：允许落，且标了 swap")
	_ok(st.bench.size() == bench_before, "备战席→占用格：备战席数量不变（%d）" % st.bench.size())
	_ok(st.field.size() == field_before, "备战席→占用格：上场数不变（%d）" % st.field.size())
	_ok(StringName(st.bench[0].get("ship_key", &"")) == &"punisher"
			and st.bench[0].get("cell") == Vector2i(-1, -1),
			"备战席→占用格：被顶掉的那艘回腾出来的备战席格（%s @ %s）" % [
				String(st.bench[0].get("ship_key", "?")), str(st.bench[0].get("cell"))])
	_ok(StringName(st.field[0].get("ship_key", &"")) == &"kestrel"
			and st.field[0].get("cell") == Vector2i(9, 2),
			"备战席→占用格：进场的那艘真的落在 (9,2)")

	# ④ 满员时照样能换
	st.field.clear()
	st.bench.clear()
	for i in st.field_limit():
		st.field.append({"ship_key": &"punisher", "star": 1, "cell": Vector2i(8, i)})
	st.bench.append({"ship_key": &"kestrel", "star": 1, "cell": Vector2i(-1, -1)})
	r = st.deploy_from_bench(0, 8, 3)
	_ok(bool(r.get("ok", false)) and bool(r.get("data", {}).get("swap", false)),
			"满员（%d／%d）时仍可互换 —— 换人不换人口" % [st.field.size(), st.field_limit()])
	_ok(st.field.size() == st.field_limit(), "满员互换后上场数不变（%d）" % st.field.size())

	# ⑤ 预览与实做同口径
	var pv := st.preview_place(8, 2, &"field", 0)
	_ok(bool(pv.get("ok", false)) and bool(pv.get("swap", false))
			and String(pv.get("swap_name", "")) != "",
			"预览：占用格可落 + 带 swap_name（%s）" % String(pv.get("swap_name", "")))
	var pv2 := st.preview_place(8, 3, &"bench", 0)
	_ok(bool(pv2.get("ok", false)) and bool(pv2.get("swap", false)),
			"预览：备战席→占用格也报 swap")
	var pv3 := st.preview_place(10, 9, &"field", 0)
	_ok(bool(pv3.get("ok", false)) and not bool(pv3.get("swap", false)),
			"预览：空格不带 swap")

