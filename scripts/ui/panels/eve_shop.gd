extends "res://scripts/ui/eve_window.gd"

## EVE 自走棋 —— 商店（底中，全功能）
##
## V3 稿尺寸 1142 × 168。三段：
##   ① 经济区 124px   星币余额 / ↻ 刷新 / ▲ 升级 / ✦ 锁定加速列表
##   ② 卡槽   自适应   5 张等宽窄卡（用户明确要求「必须窄卡」，不许拉满成扁条）
##   ③ 打捞区  84px   待打捞残骸；玩家拿起备战席舰船时整窗化作出售区
##
## ── 出售区的两种表达（对应用户的两次修订）──────────────────────
##   ① 常态：右端 84px 是「待打捞」框；有打捞舰船时整框提亮（橙边 + 橙光）。
##   ② 拿起备战席舰船时：整个商店窗（含标题栏）变成橙色出售区。
##      理由见用户原话 —— 「区域再那么小是很影响操作的」，
##      所以热区从 84×140 放大到 1142×228。
##
## ── 卡面立绘 ──────────────────────────────────────────────────
##   资源 = 官方 1024px 渲染图 → 语义分割抠像 → 512×512 透明底画布，
##   落在 res://assets/ships/<id>.png，由 EveShipArt 统一取用并缓存。
##   缺图时 _CardArt 自动退回淡色机库剪影（不会留白框）。
##
## 变更清单（实装版）：
##   - 经济区（星币 / 刷新 / 升级 / 锁定）
##   - 5 张窄卡（派系色顶条 + 立绘 + 名称 + 费用 + 攻/甲）
##   - 打捞框三态（空 / 有残骸提亮 / 整窗出售区）
##   - buy_requested / refresh_requested / levelup_requested / salvage_requested 信号

signal buy_requested(offer_index: int)
## ★ 2026-11-07（玩家反馈：「买船的时候，要能点开看船的属性」）：
## 第一次点卡片**不下单**，先发这个信号让主控把右上角舰船档案换成这艘船。
signal preview_requested(offer_index: int)
signal refresh_requested()
signal levelup_requested()
signal lock_toggled(on: bool)
signal salvage_requested()

## ★ 2026-10-10（审查 2#5）：武器/防御 id（逻辑只认 id、不认中文）。
const CIDS := preload("res://scripts/core/eve_combat_ids.gd")
## ★ 2026-10-10（i18n）：术语取词（见 `eve_terms.gd` 顶注）。
const TERMS := preload("res://scripts/core/eve_terms.gd")
## ★ 2026-10-10（i18n）：文案取词（见 `eve_text.gd` 顶注）。
const T := preload("res://scripts/core/eve_text.gd")

const CARD_COUNT := 5

var coin: int = 0
var level: int = 1
var xp: int = 0
var xp_need: int = 0
var bench_used: int = 0
var bench_cap: int = 8
var refresh_cost: int = 2
var levelup_cost: int = 4
var locked: bool = false
var selling: bool = false

## 当前 5 个槽位的报价（EveShipDatabase 派生 Dictionary；{} = 空槽）
var _offers: Array = []

## ★ 阶段闸门：只有准备阶段为 true（见 `set_buy_enabled()`）。
##  false 时整排卡压暗且点击早退 —— 消灭「非准备阶段点卡没反应」。
var _buy_enabled: bool = true

## ★ 2026-11-07（玩家反馈：「买船的时候，得能点开看属性」）：
## **两段式下单** —— 第一次点卡片 = 选中并展开档案（金边 + 状态栏提示），
## 第二次点同一张才真的扣钱。
##
## [WHY] 卡片上只有「攻 / 防」两个数，玩家想知道护盾/结构/武器/射程/羁绊
##       就必须先买下来再看 —— 但买错了要退，等于逼玩家赌。
## [WHY] 不用「长按 / 右键」：手机上长按没有可见提示，新玩家永远发现不了；
##       而且这游戏的触摸会被模拟成鼠标，右键在触屏上根本不存在。
## [PITFALL] 所以 `_armed` 必须能被三条路清掉：换货（买走 / 刷新）、
##       离开准备阶段、以及**再点一次**（下单）。漏一条就会「卡片一直亮着金边」。
var _armed: int = -1

var _coin_label: Label
var _bench_label: Label
var _level_label: Label
var _cards_row: HBoxContainer
var _slv_box: Control
var _slv_head: Label
var _slv_body: VBoxContainer
## 打捞框状态：**只读看板两态**——"empty"（空态引导）/ "repairing"（已下单等到账）。
## ⚠️ C-P1-1 契约收口（2026-10-11）：数据源 `salvage_info()` 的真实值域是
##   ""(空) / "list" / "repairing"（见 eve_run_state.salvage_info）。"list"
##   （残骸挂在结算页）在本框**有意**按空态渲染——引导文案把玩家指去结算页。
##   旧注释写的 "wreck" 不是数据源值域（那是商店还能下单年代的遗留口径）。
## 具体含义与唯一输入源见 set_salvage() 的注释。
##
## （旧字段 `_slot_index: int` 已删除：它表达不了三态，只够表达「有 / 无」。
##   三态之后留着它就会出现「谁能改、谁在读」两套并列状态 —— 那是分叉的起点。）
var _slv_state: String = "empty"
## 已画出来的残骸世代号（`EveRunState.wreck_evt`）。
## ⚠️ 它是 `set_salvage()` 的**重画判据**：state 没变但换了一具残骸时，
##    只有它变了 ⇒ 靠它才不会把上一具的数值留在框上。见 set_salvage() 的注释。
var _slv_evt: int = 0
var _overlay: Control
var _refresh_btn: Button
var _levelup_btn: Button
var _lock_btn: Button


func _ready() -> void:
	window_title = T.t("SHOP_TITLE", "商店")
	density = Density.NORMAL
	super._ready()
	_build_header_extras()
	_build_contents()
	_build_overlay()


## 标题栏右侧再挂一个小字（EveWindow 只提供一格，商店要用两格）
func _build_header_extras() -> void:
	_level_label = Label.new()
	_level_label.text = "Lv.1 · 0 / 0"
	_level_label.add_theme_color_override("font_color", C_TEXT_FAINT)
	FONT.fs(_level_label, 10)
	_level_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_level_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(_level_label)

	_bench_label = _status_label


func _build_contents() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(row)

	row.add_child(_build_econ())

	_cards_row = HBoxContainer.new()
	_cards_row.add_theme_constant_override("separation", 8)
	_cards_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_cards_row)

	row.add_child(_build_salvage())


# ------------------------------------------------------------------ ① 经济区

func _build_econ() -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(124, 0)
	box.add_theme_constant_override("separation", 4)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var coin_row := HBoxContainer.new()
	coin_row.add_theme_constant_override("separation", 6)
	box.add_child(coin_row)

	var gem := Label.new()
	gem.text = "◆"
	gem.add_theme_color_override("font_color", C_GOLD)
	FONT.fs(gem, 12)
	gem.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	coin_row.add_child(gem)

	_coin_label = Label.new()
	_coin_label.text = "0"
	_coin_label.add_theme_color_override("font_color", Color(0.918, 0.969, 0.980))
	FONT.fs(_coin_label, 24)
	_coin_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	coin_row.add_child(_coin_label)

	var unit := Label.new()
	unit.text = T.t("SHOP_COIN_UNIT", "星币")
	unit.add_theme_color_override("font_color", C_TEXT_DIM)
	FONT.fs(unit, 10)
	unit.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	coin_row.add_child(unit)

	var ops := GridContainer.new()
	# ⚠️ 一列三行（原来是一列两行的 2 列网格）。
	#    改的原因是 B03 的文案口径：按钮必须叫「加速等级」而不是「升级」
	#    （交接文档 §4.2：与「加速列表」统一），而 124px 的窄簇里
	#    两列并排只给得下 60px，七个字必然溢出。一列之后三个按钮等宽。
	#
	# ⚠️ 2026-09-22：v_separation 4 → 3、按钮高 26 → 24。
	#    商店窗从 168 压到 158（给备战格带腾纵向空间）后，内容区只剩 118px，
	#    而经济区原需 120px（币行 30 + 间距 4 + 3×26 + 2×4）—— 刚刚好超 2px，
	#    表现是三个按钮被 VBox 挤扁且**不报错**。收 8px 后为 112px，留出余量。
	ops.columns = 1
	ops.add_theme_constant_override("h_separation", 4)
	ops.add_theme_constant_override("v_separation", 3)
	ops.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(ops)

	_refresh_btn = Button.new()
	_refresh_btn.text = T.t("SHOP_REFRESH", "↻ 刷新 %d") % refresh_cost
	_refresh_btn.custom_minimum_size = Vector2(0, 24)
	_refresh_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	EveButtonTheme.apply(_refresh_btn, "hud_warn")
	_refresh_btn.pressed.connect(func(): refresh_requested.emit())
	ops.add_child(_refresh_btn)

	_levelup_btn = Button.new()
	_levelup_btn.text = T.t("SHOP_LEVELUP", "▲ 加速等级 %d") % levelup_cost
	_levelup_btn.custom_minimum_size = Vector2(0, 24)
	_levelup_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	EveButtonTheme.apply(_levelup_btn, "hud")
	_levelup_btn.pressed.connect(func(): levelup_requested.emit())
	ops.add_child(_levelup_btn)

	_lock_btn = Button.new()
	_lock_btn.text = T.t("SHOP_LOCK", "✦ 锁定加速列表")
	_lock_btn.custom_minimum_size = Vector2(0, 24)
	_lock_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lock_btn.toggle_mode = true
	EveButtonTheme.apply(_lock_btn, "hud")
	_lock_btn.toggled.connect(_on_lock_toggled)
	ops.add_child(_lock_btn)

	return box


func _on_lock_toggled(on: bool) -> void:
	locked = on
	_lock_btn.text = (T.t("SHOP_LOCKED", "✦ 已锁定加速列表") if on
			else T.t("SHOP_LOCK", "✦ 锁定加速列表"))
	lock_toggled.emit(on)


## 外部同步锁定状态（真正的语义在 EveRunState：锁定 = 本节点结束后不重摇）
##
## ⚠️ 必须用 set_pressed_no_signal —— 直接 set_pressed 会再触发 toggled，
##    和 _on_lock_toggled 里的 lock_toggled.emit 构成回环。
func set_locked(on: bool) -> void:
	locked = on
	if _lock_btn != null:
		_lock_btn.set_pressed_no_signal(on)
		_lock_btn.text = (T.t("SHOP_LOCKED", "✦ 已锁定加速列表") if on
				else T.t("SHOP_LOCK", "✦ 锁定加速列表"))


## 买得起 / 买不起的视觉。
##
## 云顶口径是「降亮度」而不是「盖一层灰罩」—— 后者会让卡面立绘看起来像坏了。
## 买不起的卡压到 55% 亮度 + 立绘 dimmed（_CardArt 内部同样走降亮度那条路）。
##
## ⚠️ 2026-10-05：这一层只管**钱**。另有一层 `_buy_enabled`（阶段）——
##    见 `set_buy_enabled()`。两层都用同一套「压暗」表达，玩家看到的就是
##    「这张卡现在不能要」，而不是「点了没反应」。
func set_affordable(p_coin: int) -> void:
	coin = p_coin
	for i in _card_widgets.size():
		var w: Dictionary = _card_widgets[i]
		var root: PanelContainer = w["root"]
		var art: _CardArt = w["art"]
		var cost := 0
		var is_salvage := false
		if i < _offers.size():
			var raw = _offers[i]
			if raw is Dictionary:
				cost = int((raw as Dictionary).get("cost", 0))
				# ★ 打捞品取货免费 ⇒ 不能用 `cost` 判它买不起
				#   （否则玩家钱少时，免费的打捞品会被压暗成「买不起」，
				#    卡面却写着「已付」—— 自相矛盾，玩家不敢点）。
				is_salvage = (raw as Dictionary).has("from_node")
		# 钱不够 **或** 当前阶段不能买 ⇒ 都压暗；打捞品只看阶段闸门
		var able := _buy_enabled and (is_salvage or cost <= 0 or p_coin >= cost)
		art.dimmed = not able
		root.modulate = Color(1, 1, 1, 1.0 if able else 0.55)
		art.queue_redraw()
	if _refresh_btn != null:
		_refresh_btn.modulate = Color(1, 1, 1,
				1.0 if (_buy_enabled and p_coin >= refresh_cost) else 0.55)
	if _levelup_btn != null:
		_levelup_btn.modulate = Color(1, 1, 1,
				1.0 if (_buy_enabled and p_coin >= levelup_cost) else 0.55)


## ★ 2026-10-05：**阶段闸门** —— 只有准备阶段能买卖。
##
## ⚠️ 为什么必须补这一层：商店面板是**常驻**的（不随阶段显隐），
##    结算页/战斗阶段卡片照样亮着。玩家一点，`buy()` 以
##    「只有准备阶段能买船」拒绝，而**卡片本身毫无变化** ——
##    表现就是「点了没反应，东西也没到手」，玩家会当成 bug 报上来。
##    （红线 9：别摆看着能点、点了没反应的东西。）
##
## ⛔ 不改 `mouse_filter`（改 IGNORE 会让点击**穿透**到后面的控件，
##    变成「点卡片却触发了别的东西」）；只让 `_on_card_input` 早退 + 压暗。
func set_buy_enabled(on: bool) -> void:
	if _buy_enabled == on:
		return
	_buy_enabled = on
	if not on:
		# ★ 离开准备阶段 ⇒ 作废「已选中」（否则回来时那张卡还亮着金边，
		#   而金边语义是「再点一次就下单」—— 那会是个假承诺）。
		_armed = -1
		_paint_armed()
		_refresh_status_text()
	set_affordable(coin)


# ------------------------------------------------------------------ ② 卡槽

func _build_card() -> Dictionary:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.custom_minimum_size = Vector2(0, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.035, 0.047, 0.055, 0.72)
	sb.border_color = Color(0.42, 0.55, 0.60, 0.40)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	card.add_theme_stylebox_override("panel", sb)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	card.add_child(col)

	# 派系色顶条 3px
	var top := ColorRect.new()
	top.custom_minimum_size = Vector2(0, 3)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(top)

	# 立绘位（占位）
	#
	# ⚠️ 2026-09-22：56 → 50。商店窗压到 158px 后内容区只剩 118px，
	#    卡片内容合计（顶条 3 + 立绘 + 名称 11 + 攻甲 22 + 底距 4 + 间距 2）
	#    在 56 时为 98px，虽不超限但与经济区抢空间；收到 50 后为 92px。
	var art := _CardArt.new()
	art.size_flags_vertical = Control.SIZE_EXPAND_FILL
	art.custom_minimum_size = Vector2(0, 50)
	col.add_child(art)

	# ★ 2026-10-27（用户：「去掉 CTN 的标志，以后再定，毕竟现在也丑」）
	#   这里曾经在立绘右上角挂过一个「定位小标」：后勤 N / 攻击 C / 防御 T
	#   （2026-10-25 加）。⇒ 整体删除（Label + `role_badge()`）。
	#   ⛔ 别再"顺手加回来"：要恢复就连同 `role_badge()` 与 `_fill_card` 里
	#   那三行赋值一起复原，并同步 `tools/probe_hud_layout.gd` 的体检段。
	#   ⚠️ 船表里的 `role` 字段**仍然保留**（驱动站位/姿态）——
	#   删掉的只是这个角标，不是定位本身。

	# 名称 / 费用
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 1)
	col.add_child(info)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 0)
	info.add_child(name_row)

	var nm := Label.new()
	nm.text = "—"
	nm.add_theme_color_override("font_color", Color(0.875, 0.949, 0.965))
	FONT.fs(nm, 11)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# ⚠️ clip_text 必须开。
	#    Label 的最小宽度默认等于文本宽度，5 张卡里「布鲁提克斯级」比「裂谷级」
	#    宽一倍，HBox 按最小宽度分空间 → 卡片宽度参差不齐（实测截图里差 40px）。
	#    打开 clip_text 后最小宽度归零，5 张卡才真正等宽。
	nm.clip_text = true
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_child(nm)

	# ★ 2026-10-31（用户：「巨鸟等船的卡牌上没有电子战羁绊标签，这不行，加上」）：
	#   电子战船的卡面必须自带一个紫色「电子战」标签。
	#   位置选在**名称行、费用左边**——卡面 1142px 分 5 张、单卡约 220px，
	#   名称最长 7 字（66px）＋标签（24px）＋费用都塞得下；
	#   ⛔ 别贴到立绘上做角标：2026-10-27 用户刚要求「去掉 CTN 定位小标」，
	#     同一个位置再挂一个角标是往回走。
	#   ⚠️ 颜色读 `EveTraitTable.EW_COLOR`（唯一真源），别在这里写死紫色。
	var ew_tag := Label.new()
	# 显示名走取词（与羁绊窗、档案行同一口径），逻辑键仍是 `ew`。
	ew_tag.text = TERMS.trait_member(&"ew", "电子战")
	ew_tag.add_theme_color_override("font_color", EveTraitTable.EW_COLOR)
	FONT.fs(ew_tag, 8)
	ew_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ew_tag.visible = false
	name_row.add_child(ew_tag)

	# ★ 2026-10-31（用户：「后勤有没有落在商店的卡牌面上？确定一下」）：
	#   确认结果 —— **没有**，之前只贴了电子战。这里补上，版式与电子战标签完全对称。
	#   ⚠️ 一艘船可以同时是电子战 + 后勤（如鱼鹰级？不是；但表里允许），
	#      所以两个标签是**并列**不是互斥，各占独立 Label。
	var logi_tag := Label.new()
	logi_tag.text = TERMS.trait_member(&"logi", "后勤")
	logi_tag.add_theme_color_override("font_color", EveTraitTable.LOGI_COLOR)
	FONT.fs(logi_tag, 8)
	logi_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	logi_tag.visible = false
	name_row.add_child(logi_tag)

	# ★ 2026-10-31（超频精英货架）：★2 必须写在卡面上。
	#   超频满档后货架全是 ★2，但价格只有一星价 —— 不标星级玩家会以为
	#   「为什么这艘巡洋这么贵/这么便宜」，也看不出自己赚到了什么。
	#   ⚠️ 位置固定在名称右侧、费用左侧，金色（与费用同色系但更亮）。
	var star_tag := Label.new()
	star_tag.text = ""
	star_tag.add_theme_color_override("font_color", C_GOLD)
	FONT.fs(star_tag, 9)
	star_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	star_tag.visible = false
	name_row.add_child(star_tag)

	var cost := Label.new()
	cost.text = "0"
	cost.add_theme_color_override("font_color", C_GOLD)
	FONT.fs(cost, 11)
	cost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_child(cost)

	var stat := Label.new()
	stat.text = "—"
	stat.add_theme_color_override("font_color", C_TEXT_DIM)
	FONT.fs(stat, 9)
	stat.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	stat.clip_text = true
	stat.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.add_child(stat)

	# 底边留一点内边距
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 6)
	pad.add_theme_constant_override("margin_right", 6)
	pad.add_theme_constant_override("margin_bottom", 4)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.remove_child(info)
	pad.add_child(info)
	col.add_child(pad)

	return {"root": card, "top": top, "art": art,
			"name": nm, "cost": cost, "stat": stat,
			"ew": ew_tag, "logi": logi_tag, "star": star_tag}


## 设置 5 张卡的报价。offers 的元素是 EveShipDatabase 出来的 Dictionary
func set_offers(offers: Array) -> void:
	_offers = offers
	# ★ 换货 = 上一张的「选中」作废（买走后补空位 / 刷新 都会走到这里）。
	#   ⚠️ 必须在 `_fill_card` 之前清 —— 否则新卡片会继承旧卡片的金边。
	_armed = -1
	while _cards_row.get_child_count() < CARD_COUNT:
		var c := _build_card()
		var idx := _cards_row.get_child_count()
		var root: PanelContainer = c["root"]
		root.gui_input.connect(_on_card_input.bind(idx))
		_cards_row.add_child(root)
		_card_widgets.append(c)

	for i in CARD_COUNT:
		var w: Dictionary = _card_widgets[i]
		var offer = offers[i] if i < offers.size() else null
		_fill_card(w, offer, i)
	_paint_armed()
	set_affordable(coin)
	_refresh_status_text()


var _card_widgets: Array[Dictionary] = []


func _fill_card(w: Dictionary, offer, index: int) -> void:
	var root: PanelContainer = w["root"]
	var top: ColorRect = w["top"]
	var art: _CardArt = w["art"]
	var nm: Label = w["name"]
	var cost: Label = w["cost"]
	var stat: Label = w["stat"]
	var ew_tag: Label = w["ew"]
	var logi_tag: Label = w["logi"]
	var star_tag: Label = w["star"]

	# ★ 2026-10-01：买走的槽位是**空 Dictionary**（不补货）。
	#   显示一张压暗的空卡而不是直接隐藏 —— 隐藏会让商店看起来"少了一格"，
	#   玩家会以为刷新坏了；空卡则明确表达「这格我自己买走了」。
	if offer == null or (offer is Dictionary and (offer as Dictionary).is_empty()):
		root.visible = true
		root.modulate = Color(1, 1, 1, 0.34)
		top.color = Color(0.14, 0.18, 0.21)
		nm.text = T.t("SHOP_BOUGHT", "已买走")
		cost.text = "—"
		stat.text = ""
		ew_tag.visible = false
		logi_tag.visible = false
		star_tag.visible = false
		art.accent = Color(0.35, 0.42, 0.46)
		return
	root.visible = true
	root.modulate = Color(1, 1, 1, 1)

	var d: Dictionary = offer
	var fcol := _faction_color(int(d.get("faction", 0)))
	# 打捞到账的「修复品」必须能一眼认出来：它与普通货架同为一张卡，
	# 不标记的话玩家花过钱的单会混在 5 张卡里找不到（而且不报错）。
	var is_salvage := d.has("from_node")
	if is_salvage:
		top.color = C_ACCENT
		art.accent = C_ACCENT
		nm.text = T.t("SHOP_SALVAGE", "修复 %s") % String(d.get("name", "—"))
	else:
		top.color = fcol
		art.accent = fcol
		nm.text = String(d.get("name", "—"))
	art.dimmed = false
	art.set_ship_key(StringName(d.get("ship_key", "")))
	# ★ 2026-10-06（二改）：价格格**留空**（用户：「我不喜欢『已付』的标签，取消掉吧」）。
	#   ⚠️ 但**不能**恢复成显示 `cost` 数字 —— 取货本来就免费，写「1」会让
	#     玩家以为还要花钱（不敢点），那是这一栏最初的问题。
	#   ⇒ 打捞品靠「修复」前缀 + 青色顶带识别，价格格不需要内容。
	cost.text = "" if is_salvage else str(int(d.get("cost", 0)))

	# ★ 2026-10-10（审查 2#5）：判据走 id（⛔ 不拿中文当主键）。
	# ★ 2026-10-10（i18n）：**显示名走取词** —— 武器/防御的英文用 EVE 官方
	#   市场分组名（Energy Turret / Hybrid Turret / Projectile Turret /
	#   Missile Launcher）与 EVE 官方 Shield / Armor。默认 locale 下逐字不变。
	var wid := CIDS.weapon_id_of(String(d.get("weapon_type", "")))
	var did := CIDS.defense_id_of(String(d.get("defense_type", "")))
	var is_shield := did == CIDS.D_SHIELD
	# ★ 电子战标签：判据唯一真源 = `EveTraitTable.EW_SHIP_KEYS`（走公开入口）。
	#   `d` 是船表 Dictionary，`is_ew_ship()` 认它的 `ship_key`；
	#   打捞来的「修复品」同样带 ship_key ⇒ 一条分支就够，不用另写。
	ew_tag.visible = EveTraitTable.is_ew_ship(d)
	# 后勤标签同理（用户：「后勤有没有落在商店的卡牌面上？确定一下」——
	#   确认之前没有，本次补上，判据走公开入口 `is_logi_ship`）。
	logi_tag.visible = EveTraitTable.is_logi_ship(d)

	# ★ 2026-10-31（超频精英货架）：★2 及以上必须在卡面标出来，否则玩家
	#   完全看不出「超频买到了什么」。普通货架的报价没有 `star` 键 ⇒ 默认 1、
	#   标签隐藏，行为与改动前一致。
	var star := clampi(int(d.get("star", 1)), 1, EveRunState.MAX_STAR)
	star_tag.visible = star > 1
	star_tag.text = "★%d" % star
	# 星级对战力是 ×1.8^(star-1)（`EveRunState.STAR_MULT`）——
	# 卡面必须显示**实际战力**，否则 ★2 巡洋写着 35 攻、打出来 63，
	# 玩家会以为数值是假的。⚠️ 别在这里另写 1.8：读常量。
	var stat_mul := pow(EveRunState.STAR_MULT, float(star - 1))
	var atk_show := int(round(float(d.get("attack", 0)) * stat_mul))
	var def_raw := float(d.get("shield", 0)) if is_shield else float(d.get("armor_struct", 0))
	var def_show := int(round(def_raw * stat_mul))
	stat.text = T.t("SHOP_CARD_STAT", "%s · %s\n攻 %d　%s %d") % [
		TERMS.weapon(wid), TERMS.defense(did),
		atk_show,
		(T.t("SHOP_DEF_SHIELD", "盾") if is_shield else T.t("SHOP_DEF_ARMOR", "甲")),
		def_show,
	]


func _on_card_input(event: InputEvent, index: int) -> void:
	if _selling_blocked_by_overlay():
		return
	# ★ 非准备阶段：不派发买入请求。
	#   ⚠️ 卡片此时已被 `set_buy_enabled(false)` 压暗 ⇒ 玩家不会去点；
	#   这一句是**兜底**（压暗万一没生效，也不能让请求发出去被静默拒）。
	if not _buy_enabled:
		return
	if not (event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT):
		return
	# 空槽（已买走）点了什么都不该发生 —— 但也不能静默：
	# 卡片自己写着「已买走」，再弹提示反而是噪音，安静返回即可。
	var offer = _offers[index] if index < _offers.size() else null
	if offer == null or not (offer is Dictionary) or (offer as Dictionary).is_empty():
		return
	if _armed == index:
		# 第二下 = 下单。⚠️ 先清选中再发信号：`buy_requested` 会触发换货，
		# `set_offers()` 里也会清一次（两处都清是幂等的，但顺序反了会出现
		# 「新卡片继承了旧卡片的金边」）。
		_set_armed(-1)
		buy_requested.emit(index)
		return
	# 第一下 = 预览：展开档案 + 亮金边 + 状态栏写「再点一次购买」
	_set_armed(index)
	preview_requested.emit(index)


## 选中 / 取消选中某一张报价卡。
##
## ⚠️ 只改视觉与状态栏，**不碰任何数据** —— 真正的扣钱发生在第二次点击。
func _set_armed(index: int) -> void:
	if _armed == index:
		return
	_armed = index
	_paint_armed()
	_refresh_status_text()


## 把「选中」画出来：金边 + 略亮的底色（2px 边比 1px 更醒目，不改卡片尺寸）。
func _paint_armed() -> void:
	for i in _card_widgets.size():
		var w: Dictionary = _card_widgets[i]
		var root: PanelContainer = w["root"]
		var on := i == _armed
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.106, 0.086, 0.043, 0.90) if on \
				else Color(0.035, 0.047, 0.055, 0.72)
		sb.border_color = C_GOLD if on else Color(0.42, 0.55, 0.60, 0.40)
		sb.set_border_width_all(2 if on else 1)
		sb.set_corner_radius_all(0)
		root.add_theme_stylebox_override("panel", sb)


## 状态栏（标题栏右侧那格小字）：没选中时显示备战席计数，选中时改成下单提示。
##
## [WHY] 只有金边还不够 —— 玩家不知道"金边之后该做什么"。这一行是唯一
##       能写全「再点一次购买 ◆N」的位置（卡片上塞不下，且会盖掉数值）。
func _refresh_status_text() -> void:
	if _armed < 0 or _armed >= _offers.size():
		set_status(T.t("SHOP_BENCH", "备战席 %d / %d") % [bench_used, bench_cap])
		return
	var d = _offers[_armed]
	if not (d is Dictionary):
		set_status(T.t("SHOP_BENCH", "备战席 %d / %d") % [bench_used, bench_cap])
		return
	var nm := String((d as Dictionary).get("name", ""))
	if (d as Dictionary).has("from_node"):
		set_status("已选 %s · 再点一次领取" % nm)
		return
	set_status("已选 %s · 再点一次购买 ◆%d"
			% [nm, int((d as Dictionary).get("cost", 0))])


static func _faction_color(faction: int) -> Color:
	match faction:
		0: return C_FACTION_AMARR
		1: return C_FACTION_CALDARI
		2: return C_FACTION_GALLENTE
		3: return C_FACTION_MINMATAR
	return C_TEXT_DIM


# ------------------------------------------------------------------ ③ 打捞 / 出售区

func _build_salvage() -> Control:
	_slv_box = Control.new()
	_slv_box.custom_minimum_size = Vector2(84, 0)
	# ⚠️ 必须是 STOP 而不是 IGNORE。
	#    打捞框是**要点的**（下单打捞），IGNORE 会让点击直接穿过去、什么都不发生，
	#    而且不报错 —— 表现是「这个框看着能点，点了没反应」。
	#    子控件保持 IGNORE，事件就会落到这个框自己身上。
	_slv_box.mouse_filter = Control.MOUSE_FILTER_STOP
	_slv_box.gui_input.connect(_on_salvage_input)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", 3)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_slv_box.add_child(col)

	_slv_head = Label.new()
	_slv_head.text = T.t("SHOP_SALVAGE_HEAD", "待打捞")
	_slv_head.add_theme_color_override("font_color", C_TEXT_FAINT)
	FONT.fs(_slv_head, 9)
	_slv_head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_slv_head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_slv_head)

	_slv_body = VBoxContainer.new()
	_slv_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_slv_body.alignment = BoxContainer.ALIGNMENT_CENTER
	_slv_body.add_theme_constant_override("separation", 3)
	_slv_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_slv_body)

	_slv_box.draw.connect(_draw_salvage_frame)
	return _slv_box


func _draw_salvage_frame() -> void:
	var r := Rect2(Vector2(0.5, 0.5 + 16.0), Vector2(_slv_box.size.x - 1.0, _slv_box.size.y - 17.0))
	match _slv_state:
		"wreck":
			# 有残骸、可下单：实线橙框 + 亮底（V3 稿的 .slv.hot）
			_slv_box.draw_rect(r, Color(0.408, 0.235, 0.102, 0.50), true)
			_slv_box.draw_rect(r, Color(1.0, 0.627, 0.353, 0.95), false, 1.0)
		"repairing":
			# 已下单、等到账：改【青色】实线。
			# 与橙的区别是必需的 —— 两者都是「实线亮框」，只靠文字区分的话
			# 玩家会以为还能再点一次，点下去没反应就成了 bug 观感。
			_slv_box.draw_rect(r, Color(0.141, 0.220, 0.235, 0.50), true)
			_slv_box.draw_rect(r, Color(0.55, 0.78, 0.82, 0.75), false, 1.0)
		_:
			_slv_box.draw_rect(r, Color(0.071, 0.094, 0.110, 0.55), true)
			_dash_rect(_slv_box, r, Color(0.42, 0.55, 0.60, 0.45), 4.0, 4.0)


static func _dash_rect(ci: CanvasItem, r: Rect2, col: Color, dash: float, gap: float) -> void:
	var seg := dash + gap
	var x := r.position.x
	while x < r.end.x:
		var x2 := minf(x + dash, r.end.x)
		ci.draw_line(Vector2(x, r.position.y), Vector2(x2, r.position.y), col, 1.0)
		ci.draw_line(Vector2(x, r.end.y), Vector2(x2, r.end.y), col, 1.0)
		x += seg
	var y := r.position.y
	while y < r.end.y:
		var y2 := minf(y + dash, r.end.y)
		ci.draw_line(Vector2(r.position.x, y), Vector2(r.position.x, y2), col, 1.0)
		ci.draw_line(Vector2(r.end.x, y), Vector2(r.end.x, y2), col, 1.0)
		y += seg


## 设置打捞框。传 {} 表示空。
##
## info 由 `EveRunState.salvage_info()` 产出 —— **唯一输入源**，本函数不自己判
## 「有没有残骸」（判据写两份必然分叉）。★ C-P1-1 契约收口（2026-10-11），
## 值域以数据源为准：
##   {"state": "list", …}      残骸挂在**结算页** ⇒ 本框按空态渲染（见下）
##   {"state": "repairing", …} 已下单等到账 ⇒ 「修复中」
##   {}                        空
##
## ⚠️ 本框 2026-10-04 起退役为**只读看板**（打捞入口在结算页）：
##   "list" 在这里按空态渲染是有意设计——空态的引导文案把玩家指去结算页，
##   不是 bug。下面保留的 "wreck" 渲染分支只是**兜底**（万一未来恢复商店下单），
##   当前数据流永远不会喂进来。
##   ⛔ 因此别「顺手」把 wreck 分支删掉或把 "list" 映射成 wreck 展示。
##
## ⚠️⚠️ 2026-10-01 修「**打捞框里的数字有残留**」（用户实机报告）：
##
##   病根有两条，缺一条都还会残留：
##     ① **UI 侧只清 `_slv_body` 的子节点、不清文本**：`_slv_head` 是常驻控件
##        （它在 `_slv_body` 外面），三态里各写各的字 ⇒ 走到 `empty` 之前，
##        上一次的「待打捞 1」会一直挂在框顶。现在每一态都显式写 `_slv_head`。
##     ② **数据侧 UI 自己判「有没有变」**：本函数原来一进来就 `return`，
##        因为「`state` 没变就当作没变」。但**换了一具残骸、state 仍是 wreck**，
##        那一帧就整块跳过 ⇒ 框上画的还是上一具的数值。
##        ⇒ 现在改判 `evt`（世代号）。`evt` 变了就一定重画，与 state 无关。
##
##   ⛔ 别再往这里加「优化：state 没变就 return」——那正是这个 bug 的原始形态。
##   ⛔ 也别在 UI 侧另记一个计数器：世代号的唯一真源是 `EveRunState.wreck_evt`。
func set_salvage(info: Dictionary) -> void:
	var st := String(info.get("state", "")) if not info.is_empty() else ""
	var evt := int(info.get("evt", 0))
	var same := (_slv_state == st and st != "empty" and evt == _slv_evt)
	_slv_evt = evt
	_slv_state = st if st in ["wreck", "repairing"] else "empty"
	if same:
		return
	# 只有「可下单」才给手型光标：「修复中」点不出任何东西，
	# 给手型等于骗玩家点（点完没反应就变成 bug 观感）。
	_slv_box.mouse_default_cursor_shape = (Control.CURSOR_POINTING_HAND
			if _slv_state == "wreck" else Control.CURSOR_ARROW)
	for c in _slv_body.get_children():
		c.queue_free()

	if _slv_state == "empty":
		_slv_head.text = T.t("SHOP_SALVAGE_HEAD", "待打捞")
		_slv_head.add_theme_color_override("font_color", C_TEXT_FAINT)

		var big := Label.new()
		big.text = "—"
		big.add_theme_color_override("font_color", Color(0.494, 0.576, 0.612))
		FONT.fs(big, 19)
		big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_slv_body.add_child(big)

		var hint := Label.new()
		# ★ 2026-10-04：打捞改在**结算页**选，这个框只显示已到账的修复品。
		#    文案必须指向新入口，否则玩家在商店里找不到「打捞」按钮。
		hint.text = T.t("SHOP_SALVAGE_HINT", "打捞请在\n战斗结算页选")
		hint.add_theme_color_override("font_color", Color(0.561, 0.651, 0.686))
		FONT.fs(hint, 9)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_slv_body.add_child(hint)
	elif _slv_state == "wreck":
		_slv_head.text = T.t("SHOP_SALVAGE_HEAD_N", "待打捞 %d") % 1
		_slv_head.add_theme_color_override("font_color", C_WARN)

		var ic := EveIcon.make(&"hangar", 34, Color(1.0, 0.72, 0.45))
		ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_slv_body.add_child(ic)

		var nm := Label.new()
		nm.text = "%s ★%d" % [String(info.get("name", "—")), int(info.get("star", 1))]
		nm.add_theme_color_override("font_color", Color(1.0, 0.851, 0.706))
		FONT.fs(nm, 10)
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_slv_body.add_child(nm)

		# 船的关键数：打击 / 防御。玩家要能一眼判断「值不值得捞」。
		# ⚠️ `base_exact == false` 时这两个数只是**参考**（残骸来自被放大过的
		#    敌掠袭舰队），所以后缀换措辞，不假装它是原版裸值 —— 详见
		#    `EveRunState.derive_wreck_tier()` 的 §2。
		var exact := bool(info.get("base_exact", true))
		var st2 := Label.new()
		st2.text = T.t("SHOP_WRECK_STAT", "打击 %d · %s %d") % [
			int(info.get("atk", 0)),
			(T.t("SHOP_WRECK_BOOSTED", "强化") if not exact
				else T.t("SHOP_WRECK_DEFENSE", "防御")),
			int(info.get("def", 0)),
		]
		st2.add_theme_color_override("font_color", Color(0.78, 0.85, 0.88))
		FONT.fs(st2, 9)
		st2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_slv_body.add_child(st2)

		# 价格必须写出来：打捞是**花钱**的决定，框上不写价格等于让玩家盲点。
		var pr := Label.new()
		pr.text = T.t("SHOP_WRECK_ORDER", "下单 −%d ◆") % int(info.get("price", 0))
		pr.add_theme_color_override("font_color", C_GOLD)
		FONT.fs(pr, 10)
		pr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_slv_body.add_child(pr)

		var sm := Label.new()
		sm.text = T.t("SHOP_NEXT_NODE", "下节点到账")
		sm.add_theme_color_override("font_color", Color(0.561, 0.651, 0.686))
		FONT.fs(sm, 9)
		sm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_slv_body.add_child(sm)
	else:
		_slv_head.text = T.t("SHOP_REPAIRING", "修复中")
		_slv_head.add_theme_color_override("font_color", C_ACCENT)

		var ic := EveIcon.make(&"clock", 34, Color(0.62, 0.83, 0.87))
		ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_slv_body.add_child(ic)

		var nm := Label.new()
		nm.text = "%s ★%d" % [String(info.get("name", "—")), int(info.get("star", 1))]
		nm.add_theme_color_override("font_color", C_ACCENT)
		FONT.fs(nm, 10)
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_slv_body.add_child(nm)

		var sm := Label.new()
		sm.text = T.t("SHOP_NEXT_NODE_SLOT", "下节点到账\n顶掉 1 个货位")
		sm.add_theme_color_override("font_color", Color(0.561, 0.651, 0.686))
		FONT.fs(sm, 9)
		sm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_slv_body.add_child(sm)

	_slv_box.queue_redraw()


## 打捞框的点击通道。
##
## ★★ 2026-10-04 **本框已退役为「只读看板」**。
## 打捞搬到结算页（时序：结算页下单 ⇒ 下一节点到手），这里只剩一个用途：
## 让玩家在准备阶段**看见**上一批打捞品占住了哪几个货位。
##
## ⛔ 因此 `_slv_state` 只可能是 "empty" / "repairing" ——
##    "wreck" 态在这个框里**永远不会出现**（残骸只在结算页挂着）。
##    下面 `!= "wreck"` 的早退分支保留着：它同时兜住了「万一状态被改错」
##    和「点框没反应」两种情况，且不花任何代价。
func _on_salvage_input(event: InputEvent) -> void:
	if _selling_blocked_by_overlay():
		return
	if _slv_state != "wreck":
		# 「修复中」与「空」都点不出东西。明确 return（而不是靠上层判），
		# 免得日后 _slv_state 多一个值就漏过去。
		return
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		salvage_requested.emit()


# ------------------------------------------------------------------ 整窗出售区

func _build_overlay() -> void:
	_overlay = _SellOverlay.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false
	add_child(_overlay)


## 玩家拿起备战席的舰船时打开 —— 整个商店窗变橙并提示「拖到此处出售」
##
## ⚠️ 覆盖层要盖住标题栏，所以挂在 EveWindow 自己身上而不是 content 上：
##    玩家的拖拽落点判定用的是「窗口矩形」，不包括标题栏的话热区会少 26px。
func set_selling(on: bool) -> void:
	selling = on
	_overlay.visible = on
	if on:
		# 窗口底色染橙（对齐 V3 稿的 .win.selling）
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.227, 0.125, 0.047, 0.88)
		sb.border_color = Color(1.0, 0.627, 0.353, 0.95)
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(0)
		add_theme_stylebox_override("panel", sb)
		move_to_front()
	else:
		var sb2 := StyleBoxFlat.new()
		sb2.bg_color = C_PANEL
		sb2.border_color = C_BORDER
		sb2.set_border_width_all(1)
		sb2.set_corner_radius_all(0)
		add_theme_stylebox_override("panel", sb2)


func _selling_blocked_by_overlay() -> bool:
	return selling


# ------------------------------------------------------------------ 刷新

func set_economy(p_coin: int, p_level: int, p_xp: int, p_xp_need: int,
		p_refresh_cost: int, p_levelup_cost: int) -> void:
	coin = p_coin
	level = p_level
	xp = p_xp
	xp_need = p_xp_need
	refresh_cost = p_refresh_cost
	levelup_cost = p_levelup_cost
	_refresh_btn.text = T.t("SHOP_REFRESH", "↻ 刷新 %d") % refresh_cost
	_levelup_btn.text = T.t("SHOP_LEVELUP", "▲ 加速等级 %d") % levelup_cost
	_coin_label.text = str(coin)
	_level_label.text = "Lv.%d · %d / %d" % [level, xp, xp_need]
	set_affordable(coin)


func set_bench(used: int, cap: int) -> void:
	bench_used = used
	bench_cap = cap
	# ★ 2026-11-07：选中报价时，这格小字归「再点一次购买」用。
	#   `set_bench()` 每次 `run.changed` 都会来一遍（经济刷新），
	#   无条件覆盖的话下单一瞬间提示就消失 —— 玩家会以为"没选中"。
	_refresh_status_text()


# ------------------------------------------------------------------ 自绘件

## 卡面立绘位
##
## 有官方渲染图就贴图（等比 contain），没有才退回淡色机库剪影。
## 立绘资源与取用方式见 EveShipArt —— 文件名 = 舰船 id。
##
## ★ 2026-10-28：实现搬到 `scripts/ui/eve_ship_art_view.gd`（图鉴要复用同一份，
##   否则"商店一个样、图鉴另一个样"）。这里留空壳 + 原类名，是为了
##   `_card_widgets` 的 `_CardArt` 类型标注、以及 `art.dimmed = ...` /
##   `art.accent = ...` / `art.set_ship_key(...)` 这些调用一行都不用改。
class _CardArt extends EveShipArtView:
	pass


## 出售区覆盖层
class _SellOverlay extends Control:
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if size.x <= 4.0 or size.y <= 4.0:
			return
		var r := Rect2(Vector2(3, 3), size - Vector2(6, 6))
		draw_rect(r, Color(0.329, 0.173, 0.055, 0.62), true)

		# 2px 虚线边
		var seg := 12.0
		var gap := 8.0
		var col := Color(1.0, 0.690, 0.431, 0.90)
		var x := r.position.x
		while x < r.end.x:
			var x2 := minf(x + seg, r.end.x)
			draw_line(Vector2(x, r.position.y), Vector2(x2, r.position.y), col, 2.0)
			draw_line(Vector2(x, r.end.y), Vector2(x2, r.end.y), col, 2.0)
			x += seg + gap
		var y := r.position.y
		while y < r.end.y:
			var y2 := minf(y + seg, r.end.y)
			draw_line(Vector2(r.position.x, y), Vector2(r.position.x, y2), col, 2.0)
			draw_line(Vector2(r.end.x, y), Vector2(r.end.x, y2), col, 2.0)
			y += seg + gap

		var font := ThemeDB.fallback_font
		var text := T.t("SHOP_SELL_HINT", "拖到此处出售 · 返还 ◆")
		var fs := FONT.s(19)
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, Vector2((size.x - w) * 0.5, size.y * 0.5 + 7.0),
				text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1.0, 0.863, 0.733))
