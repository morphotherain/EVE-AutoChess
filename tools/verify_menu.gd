extends Node

## user:// 迁移（主菜单 `_ready` 会随启动调一次）—— 验收里必须关掉写盘
const EveUserDir := preload("res://scripts/core/eve_user_dir.gd")
## 对局存档（「继续上局」入口的可见性靠它）—— 审查 2#2。
const RUN_STORE := preload("res://scripts/core/eve_run_store.gd")

## 主界面自检（无头）
##
## 跑法：
##   "$GODOT_BIN" --headless \
##     --path . --quit-after 600 \
##     res://tools/verify_menu.tscn
##
## ── 为什么必须有一条"反向注入"的断言 ──────────────────────────────
##  只断言"三条长条都在"这种正向事实，写错了表也照样绿。
##  本文件至少要有两条**刻意造错**才能通过的检查：
##    ① 待开发难度的按钮必须 disabled（否则玩家点下去会静默无反应）
##    ② 「开始」只在 open 的难度上可点（锁定档点它不许切场景）
##
## ⚠️ 关键不变量禁用 assert（release 会被剥离）⇒ 一律 push_warning + 计数。

const MENU_SCENE := preload("res://scenes/main_menu.tscn")
const TIERS := preload("res://scripts/data/eve_campaign_tiers.gd")

const BATTLE_SCENE := "res://scenes/battle_scene.tscn"
const MENU_PATH := "res://scenes/main_menu.tscn"

var _pass: int = 0
var _fail: int = 0
var _menu: Variant = null


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("PASS  %s" % what)
	else:
		_fail += 1
		push_warning("[verify_menu] FAIL  %s" % what)
		print("FAIL  %s" % what)


func _step_run_entry() -> void:
	print("[6] 对局存档入口（继续上局）")
	# ⚠️ 会真的写/删 `user://run.cfg` ⇒ 先存字节，结束时原样还原。
	var snap := _read_raw(RUN_STORE.PATH)
	RUN_STORE.persist = true
	RUN_STORE.session_active = true
	# ① 按钮节点**恒存在**（只切 visible）—— 结构稳定，不受存档影响
	var btn0: Button = _menu.get("_continue_btn")
	_ok(btn0 != null, "主菜单有「继续上局」按钮节点")
	# ② 无档 ⇒ 不可见
	RUN_STORE.clear()
	var menu_a: Variant = MENU_SCENE.instantiate()
	add_child(menu_a)
	var ba: Button = menu_a.get("_continue_btn")
	_ok(ba != null and not ba.visible, "★ 无存档 ⇒ 「继续上局」不可见")
	menu_a.queue_free()
	# ③ 有档 ⇒ 可见
	RUN_STORE.save_run({"node_index": 3, "coin": 9, "run_seed": 1, "phase": 0})
	var menu_b: Variant = MENU_SCENE.instantiate()
	add_child(menu_b)
	var bb: Button = menu_b.get("_continue_btn")
	_ok(bb != null and bb.visible, "★ 有存档 ⇒ 「继续上局」可见")
	menu_b.queue_free()
	# 收尾：不写盘 + 原样还原玩家档
	RUN_STORE.session_active = false
	_restore_raw(RUN_STORE.PATH, snap)


func _step_settings_close() -> void:
	print("[7] 设置窗 ✕ 关闭（主菜单档案）")
	var sw: Variant = _menu.get("_settings")
	_ok(sw != null, "主菜单有设置窗实例")
	if sw == null:
		return
	# 主菜单的设置窗**只切 `visible`** —— 先确保是关的，再打开
	if bool(sw.get("visible")):
		_menu.call("_toggle_settings")
	_menu.call("_toggle_settings")
	_ok(bool(sw.get("visible")), "「设置」→ 设置窗打开")
	var cb: Control = sw.get("_close_btn")
	_ok(cb != null, "★ 设置窗标题栏有 ✕（在折叠按钮右边）")
	if cb != null:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = true
		ev.position = cb.size * 0.5
		cb.gui_input.emit(ev)
	_ok(not bool(sw.get("visible")), "★★ 点 ✕ ⇒ 设置窗关闭（主菜单的 closed 接线正确）")


func _read_raw(p: String) -> PackedByteArray:
	if not FileAccess.file_exists(p):
		return PackedByteArray()
	var f := FileAccess.open(p, FileAccess.READ)
	return f.get_buffer(f.get_length()) if f != null else PackedByteArray()


func _restore_raw(p: String, b: PackedByteArray) -> void:
	if b.is_empty():
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
		return
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f != null:
		f.store_buffer(b)


func _ready() -> void:
	# ⛔ 验收**不许**去搬玩家的真实存档目录（主菜单 `_ready` 会调迁移）
	EveUserDir.persist = false
	print("=".repeat(62))
	print("主界面自检")
	print("=".repeat(62))

	_step_project()
	_step_table()
	_step_build()
	_step_switch()
	_step_lock()
	_step_nested_modes()
	_step_run_entry()
	_step_settings_close()

	print("")
	print("RESULT passed=%d failed=%d" % [_pass, _fail])
	if _fail > 0:
		print("⚠️ 有失败项 —— 见上面的 FAIL 行")
	# ★ 2026-10-10（审查 R07）：失败 ⇒ 非零退出码（CI 靠它拦回归）
	get_tree().quit(1 if _fail > 0 else 0)


# ------------------------------------------------------------------ 步骤

## [7] 两层侧栏：自走棋[任务关卡·无尽模式·联机对战] / 娱乐总汇 / 版权声明。
## ★ 2026-10-28：疆域占位行已删（用户：「删除主菜单疆域选项，其他按钮顺势上移」）。
## 判据盯三件事：可见行顺序、父项的展开收起、父项无卡片时右侧的回落。
func _step_nested_modes() -> void:
	print("[7] 两层侧栏（自走棋 → 三个玩法 / 娱乐总汇 / 版权声明）")
	var ids := PackedStringArray()
	for m in _menu._modes:
		ids.append(String((m as Dictionary)["id"]))
	# ★ 2026-11：星舰万象棋接入为**第一层第一项**，自走棋顺势下移一格。
	_ok(ids == PackedStringArray(["starchess", "autochess", "campaign",
			"endless", "versus", "cardroom", "credits"]),
			"★ 可见行顺序（实际 %s）" % str(ids))
	# 疆域删除后：第一项原本是自走棋；星舰万象棋接入后它退到第 2 位。
	_ok(_mode_index("territory") < 0, "★ 疆域选项已删除")
	_ok(String((_menu._modes[0] as Dictionary)["id"]) == "starchess",
			"★ 星舰万象棋升为第一项")
	_ok(_mode_index("autochess") == 1,
			"★ 自走棋退到第 2 位（其他按钮顺势下移）")
	# 星舰万象棋的「开始」必须真的切到它自己的场景（红线 9：不许点了没反应）
	# 注意：直接改 _mode_idx 再还原，不要调 _on_mode_pressed ——
	#   自走棋默认是展开的，点它一次会折叠，后面所有展开/收起断言都会跟着错。
	var sc_prev_idx: int = _menu._mode_idx
	_menu._mode_idx = _mode_index("starchess")
	_ok(_menu.target_scene_for_start() == "res://scenes/starchess/sc_lobby.tscn",
			"★ 星舰万象棋 ⇒ 进它自己的大厅（实际「%s」）"
					% _menu.target_scene_for_start())
	_menu._mode_idx = sc_prev_idx
	var ai := _mode_index("autochess")
	_ok(ai >= 0 and bool((_menu._modes[ai] as Dictionary).get("parent", false)),
			"「自走棋」是父项")
	_ok(bool(_menu._expanded), "默认展开子项")
	_ok(_menu._mode_btns.size() == _menu._modes.size(), "按钮数 == 可见行数")
	_ok(String((_menu._modes[_mode_index("versus")] as Dictionary)["name"]) == "联机对战",
			"原「多人对战」已改名「联机对战」")
	_ok(String((_menu._modes[_mode_index("endless")] as Dictionary)["name"]) == "无尽模式",
			"「无尽模式」在第二层（自走棋子项）")
	# 子项可选中：无尽模式 ⇒ 右侧换成它的卡片
	_menu._on_mode_pressed(_mode_index("endless"))
	_ok(_menu._strip_panels.size() == 1,
			"选中无尽模式 ⇒ 右侧 1 张卡（实际 %d）" % _menu._strip_panels.size())
	# 点父项（已展开）⇒ 收起；子项行消失，选中回落到父项，右侧回落任务关卡内容
	_menu._on_mode_pressed(_mode_index("autochess"))
	_ok(not bool(_menu._expanded), "点父项（已展开）⇒ 收起")
	# 收起后 = 星舰万象棋 / 自走棋 / 娱乐总汇 / 版权声明 = 4 行
	# （接入星舰万象棋前是 3 行；它占第一层，收起自走棋子项不影响它）
	_ok(_menu._modes.size() == 4, "收起后可见行 = 4（实际 %d）" % _menu._modes.size())
	_ok(String((_menu._modes[_menu._mode_idx] as Dictionary)["id"]) == "autochess",
			"收起后选中回落到父项")
	_ok(_menu._strip_panels.size() == TIERS.DIFFICULTIES.size(),
			"★ 父项无卡片 ⇒ 右侧回落显示任务关卡（%d 条，实际 %d）"
					% [TIERS.DIFFICULTIES.size(), _menu._strip_panels.size()])
	# 再点父项 ⇒ 展开并自动选中「任务关卡」
	_menu._on_mode_pressed(_mode_index("autochess"))
	_ok(bool(_menu._expanded), "再点父项 ⇒ 重新展开")
	_ok(String((_menu._modes[_menu._mode_idx] as Dictionary)["id"]) == "campaign",
			"★ 展开后自动选中任务关卡")
	# 疆域已删：原来这里断言「疆域可选中 / 有 1 张待开发卡 / 不可开始」，
	# 现在改为钉「它不存在」（见上面 [7] 开头两条）。
	# 收尾：回到任务关卡，免得影响后续步骤
	_menu._on_mode_pressed(_mode_index("campaign"))


func _step_project() -> void:
	print("[1] 工程入口")
	var main := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	_ok(main == MENU_PATH, "主场景 = 主界面（实际 %s）" % main)
	_ok(ResourceLoader.exists(BATTLE_SCENE), "对局场景存在（%s）" % BATTLE_SCENE)
	_ok(ResourceLoader.exists(MENU_PATH), "主界面场景存在")


func _step_table() -> void:
	print("[2] 难度表")
	_ok(TIERS.DIFFICULTIES.size() >= 3, "难度表至少 3 档（实际 %d）" % TIERS.DIFFICULTIES.size())
	_ok(TIERS.open_count() >= 1, "至少一档已开放（实际 %d）" % TIERS.open_count())
	# ⛔ id 不许用 pve/pvp —— 无尽模式也属于 PVE，做唯一 key 会一对多
	var bad := 0
	for r in TIERS.DIFFICULTIES:
		if String(r["id"]) in ["pve", "pvp"]:
			bad += 1
	_ok(bad == 0, "难度 id 没用分类标签 pve/pvp（违规 %d 条）" % bad)
	_ok(bool(TIERS.DIFFICULTIES[TIERS.default_index()]["open"]),
			"默认选中项是【已开放】的那一档")
	var brief: PackedStringArray = []
	for r in TIERS.DIFFICULTIES:
		brief.append("%s(%d回合,%s)" % [r["name"], int(r["rounds"]),
				"开" if bool(r["open"]) else "锁"])
	print("      档位：" + ", ".join(brief))


func _step_build() -> void:
	print("[3] 构建")
	_menu = MENU_SCENE.instantiate()
	add_child(_menu)
	# ⚠️ 断言「按钮数 == 模式表项数」这个**不变量**，⛔ 不写死数字 ——
	#    2026-10-06 加「棋牌室」时，原来写死的 `== 3` 当场就红了（那不是在报 bug，
	#    是在报「我改了个合法的表」）。写死的期望值迟早变成噪音。
	_ok(_menu._mode_btns.size() == _menu._modes.size(),
			"左列按钮数 == 模式表项数（%d）" % _menu._mode_btns.size())
	# ★ 棋牌室：在表里、可点、不 locked（2026-10-06 立项）
	var ci0 := _mode_index("cardroom")
	_ok(ci0 >= 0, "模式表里有「棋牌室」")
	if ci0 >= 0:
		_ok(not bool(_menu._modes[ci0]["locked"]), "棋牌室不是 locked")
		var cc: Array = _menu._cards_of(ci0)
		# ⚠️ 2026-10-06 二次改：棋牌室改成**主菜单内的 2×2**（不再切独立场景），
		#    卡片从 1 张变 4 张；只有斗地主 open=true。
		_ok(cc.size() == 4, "棋牌室 4 张卡（实际 %d）" % cc.size())
		var open_n := 0
		for c in cc:
			if bool(c["open"]):
				open_n += 1
		_ok(open_n == 1 and bool(cc[0]["open"]),
				"只有斗地主可开始（可开始 %d 张，第 0 张=%s）"
				% [open_n, str(bool(cc[0]["open"]))])
	_ok(_menu._strip_panels.size() == TIERS.DIFFICULTIES.size(),
			"任务关卡出 %d 条难度长条（实际 %d）"
					% [TIERS.DIFFICULTIES.size(), _menu._strip_panels.size()])
	_ok(int(_menu._pick["campaign"]) == TIERS.default_index(),
			"默认选中第 %d 档" % TIERS.default_index())

	var bg: TextureRect = _menu.get_node_or_null("MenuBg") as TextureRect
	_ok(bg != null, "底图节点存在")
	if bg != null:
		_ok(bg.texture != null, "底图贴图已加载")
		if bg.texture != null:
			_ok(bg.texture.get_width() == 1920 and bg.texture.get_height() == 1080,
					"底图是 1920x1080（实际 %dx%d）"
					% [bg.texture.get_width(), bg.texture.get_height()])


## 按 id 查模式在列表里的下标（-1 = 没有）。
## 模式列表会增删，验收里**一律用它**定位，⛔ 不写死下标。
func _mode_index(id: String) -> int:
	for i in _menu._modes.size():
		if String(_menu._modes[i]["id"]) == id:
			return i
	return -1


func _step_switch() -> void:
	print("[4] 切模式 / 切难度")
	# 无尽模式没有难度分级 ⇒ 只出一条
	# ⚠️ 按 **id 找下标**，⛔ 不写死位置 —— 模式列表会增删
	#    （加了棋牌室之后，原来的「第 2 个 = 无尽模式」就错了）。
	var endless := _mode_index("endless")
	_ok(endless >= 0, "模式表里有 endless")
	_menu._on_mode_pressed(endless)
	_ok(String(_menu._modes[endless]["id"]) == "endless", "切到无尽模式")
	_ok(_menu._strip_panels.size() == 1,
			"无分级的模式只出 1 条（实际 %d）" % _menu._strip_panels.size())

	_menu._on_mode_pressed(_mode_index("campaign"))
	_ok(_menu._strip_panels.size() == TIERS.DIFFICULTIES.size(),
			"切回任务关卡恢复 %d 条" % TIERS.DIFFICULTIES.size())



	_menu._pick["campaign"] = 1
	_menu._refresh_strips()
	_ok(_menu._strip_bars[1].visible and not _menu._strip_bars[0].visible,
			"选中第 2 档时只有第 2 条的亮条可见")

	# ⚠️ 这一段**必须放在本条步骤的最后**：它会把当前模式切到棋牌室，
	#    而棋牌室只有 1 张卡 ⇒ `_strip_panels` / `_strip_bars` 都只剩 1 条。
	#    放中间的话，上面访问 `[1]` 的断言会全部越界报错
	#    （实测踩过：passed 全绿、却刷了两条 SCRIPT ERROR）。
	# ★★ 棋牌室必须去**自己的场景** —— ⛔ 绝不能落进 battle_scene。
	#    这是本条步骤里最有价值的一句：`target_scene_for_start()` 是按
	#    「模式 id + 卡片」算去向的，棋牌室的卡片**没有 id 字段**，
	#    少一个分支就会被当成「非首次」而错误地进对局。
	var ci := _mode_index("cardroom")
	if ci >= 0:
		_menu._on_mode_pressed(ci)
		# ★★ 棋牌室必须是 **2 列**（= 2 行 2 列的方框形态，用户 2026-10-06 定的）
		_ok(_menu._strip_row.columns == 2,
				"棋牌室卡片区 2 列（实际 %d）" % _menu._strip_row.columns)
		_ok(_menu._card_h < 300.0,
				"棋牌室用矮方框而不是 470 高的竖条（实际高 %.0f）" % _menu._card_h)
		# ⚠️ 必须显式标注类型：`_menu` 是动态类型，`:=` 推不出来（实测报
		#    「Cannot infer the type of target」）。
		var target: String = _menu.target_scene_for_start()
		# ★ 棋牌室**留在主菜单**（不切场景）；但⛔ 绝不能落进 battle_scene。
		#   这条断言抓的是「少一个分支就会被当成非首次、错误进对局」那个隐患 ——
		#   反向注入验过：删掉分支后它会红，实测值为 battle_scene.tscn。
		# ★ 2026-10-06 P2：斗地主的牌局接上了 ⇒ 选中它**要进牌局场景**。
		#    ⛔ 但绝不能落进自走棋的对局场景（那才是最坏的一种错）。
		_ok(target == "res://scenes/doudizhu.tscn",
				"★ 斗地主 ⇒ 进牌局场景（实际「%s」）" % target)
		_ok(target != "res://scenes/battle_scene.tscn",
				"★ 棋牌室绝不进自走棋对局")
		# ★ 新行为：同一模式里**不同卡片去向不同** —— 选待开发的川麻必须不切场景
		_menu._pick["cardroom"] = 1
		var t2: String = _menu.target_scene_for_start()
		_ok(t2 == "", "★ 选中待开发的「川麻」⇒ 不切场景（实际「%s」）" % t2)
		_menu._pick["cardroom"] = 0


func _step_lock() -> void:
	print("[5] 锁定态（反向注入：这几条必须能抓到「按钮没禁用」这类错）")
	# ⚠️ **显式切回任务关卡**，⛔ 不依赖上一步的残留状态：
	#    `_step_switch` 最后停在了棋牌室，而棋牌室只有 1 张卡 ⇒
	#    这里访问 `_strip_panels[1]` 会越界报错。步骤之间应当彼此独立。
	var ci := _mode_index("campaign")
	_menu._on_mode_pressed(ci)
	var cards: Array = _menu._cards_of(ci)
	for i in cards.size():
		var btn: Button = _menu._strip_panels[i].find_child("Start", true, false) as Button
		_ok(btn != null, "第 %d 条有开始按钮" % (i + 1))
		if btn == null:
			continue
		var open := bool(cards[i]["open"])
		_ok(btn.disabled != open, "第 %d 条（%s）按钮 disabled=%s，与 open=%s 相反"
				% [i + 1, cards[i]["name"], btn.disabled, open])
		if open:
			_ok(btn.text.begins_with("▶"), "已开放档的按钮带 ▶ 前缀（实际 %s）" % btn.text)
		else:
			_ok(btn.text == "待开发", "未开放档按钮写「待开发」（实际 %s）" % btn.text)
			# 禁用按钮仍然 mouse_filter=STOP 会吃掉点击 ⇒ 必须让给父面板，
			# 否则"点这条待开发长条也选中它"会静默失效
			_ok(btn.mouse_filter == Control.MOUSE_FILTER_IGNORE,
					"第 %d 条禁用按钮把鼠标让给面板" % (i + 1))
