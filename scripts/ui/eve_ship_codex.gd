extends Control

## EVE 自走棋 —— **舰船图鉴**（全屏浮层，只读资料库）
##
## ══════════════════════════════════════════════════════════════════
##  设计口径（2026-10-28 用户定案）
## ══════════════════════════════════════════════════════════════════
##  · 入口：主菜单「任务关卡」难度卡片**下面**的「舰船图鉴」按钮；
##  · **全收录、全可见**：52 艘一律可查，不做「未解锁剪影」
##    （自走棋商店本来就随机出船，藏卡池只会增加新人理解成本）；
##  · 参考：EVE 的 ISIS / Ship Tree（按派系 × 吨位分层）+ 云顶之弈的英雄一览
##    （卡片网格 + 筛选 + 点开详情）。
##
## ── 立绘（2026-10-28 重做）────────────────────────────────────
##  第一版用 `scripts/visual/ship_portrait_art.gd` 的**程序化几何侧影**，
##  52 艘画出来几乎同一个梯形 —— 用户：「用莫名其妙的图标是咋回事」。
##  ⇒ 现在与商店卡共用 `EveShipArtView`（真立绘 = `assets/ships/<id>.png`），
##    见该文件顶部的 [WHY]。⛔ 不要在这里另写一套画法。
##
## ── 数据来源（唯一真源，⛔ 别在这里写第二份）──────────────────
##  `EveShipDatabase.all_ships()`（= `EveShipTable.ROWS` 派生后）。
##  编号、名称、派系、吨位、攻击、射程、速度、后勤……全部来自那里；
##  以后加船，图鉴自动多一张卡，一行都不用改。
##
## ── 为什么用「屏幕空间」而不是设计空间 ────────────────────────
##  主菜单内容层是 1920×1080 死坐标；手机档画布缩放 1.35 后可见区只剩
##  ≈1422×800，挂在内容层里的浮层会被切掉边。这里挂到**根节点**、
##  按真实视口尺寸算 92%×90% 的居中面板 ⇒ PC / 手机同一套代码。

const SHIP_DB := preload("res://scripts/core/eve_ship_database.gd")
## 立绘控件：与商店卡同源（真立绘 + 无图兜底剪影），见文件头 [WHY]
const ART := preload("res://scripts/ui/eve_ship_art_view.gd")
const FONT := preload("res://scripts/ui/eve_font.gd")
const T := preload("res://scripts/core/eve_text.gd")

const C_TEXT := Color(0.70, 0.82, 0.85)
const C_TEXT_HI := Color(0.91, 0.96, 0.97)
const C_DIM := Color(0.44, 0.55, 0.59)
const C_ACCENT := Color(0.55, 0.78, 0.82)
const C_GOLD := Color(0.91, 0.76, 0.35)
const C_CARD := Color(0.045, 0.062, 0.078, 0.94)
const C_STRIP := Color(0.035, 0.048, 0.058, 0.86)
const C_BORDER := Color(0.42, 0.55, 0.60, 0.34)
const C_SEP := Color(0.42, 0.55, 0.60, 0.24)

## 吨位 → 中文（唯一真源是 `EveShipTable.CLASS_NAMES_BY_COST`，这里只是键序）
const COSTS: Array[int] = [1, 2, 3, 4, 5]

## 派系筛选的显示顺序 + 中文名。
##
## ⛔⛔ 顺序**必须**与 `EveShip.Faction` 枚举一致（AMARR / CALDARI / GALLENTE / MINMATAR），
##    因为 `_fac` 存的是**枚举值**，不是 chip 下标。
##    2026-10-28 之前这里按「加达里 / 盖伦特 / 米玛塔尔 / 艾玛」排、
##    回调里又拿 `i - 1` 当 faction ⇒ 每一档都错开一位
##    （点艾玛筛出米玛塔尔）。用户实测才发现 —— 因为每族都是 13 艘，
##    「数量 = 13」这条旧断言永远是绿的，等于没有断言。
const FACTION_NAMES: Array[String] = ["艾玛", "加达里", "盖伦特", "米玛塔尔"]

var _built := false
var _frame: PanelContainer = null
var _grid: GridContainer = null
var _grid_scroll: ScrollContainer = null
var _detail: VBoxContainer = null
var _count_lbl: Label = null

## 当前筛选：-1 = 全部
var _fac := -1
var _cost := -1
## 当前定位筛选：&"" = 全部（档位定义见 `EveShipDatabase.ROLE_TAGS`）
var _role: StringName = &""
## 当前选中
var _sel := ""
var _cards: Dictionary = {}          ## ship_key -> PanelContainer
var _fac_chips: Array[Button] = []
var _cost_chips: Array[Button] = []
var _role_chips: Array[Button] = []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	resized.connect(_layout)


## 打开图鉴（懒建）。
func open() -> void:
	if not visible:
		EveUiAudio.play("window.detail")
	_sync_size()
	if not _built:
		_build()
	_sync_size()
	visible = true
	move_to_front()
	_rebuild_grid()
	if _sel == "" or not _cards.has(_sel):
		var all := SHIP_DB.all_ships()
		if not all.is_empty():
			_select(String(all[0]["ship_key"]))
	else:
		_select(_sel)


## 铺满视口。
##
## ⚠️⚠️ 必须显式设 `size`：浮层是**运行时挂到根节点**的，`_ready` 那一刻父级
##   还没给它尺寸（实测 size = 0）⇒ 面板按「子节点最小尺寸」缩成一条，
##    整块图鉴被裁掉。锚点铺满在运行时挂载的场景里**不可靠**。
func _sync_size() -> void:
	var vp := get_viewport_rect().size
	if vp.x <= 1.0 or vp.y <= 1.0:
		return
	if size != vp:
		size = vp
		position = Vector2.ZERO
		_layout()


func _process(_dt: float) -> void:
	if visible:
		_sync_size()


func close() -> void:
	if visible:
		EveUiAudio.play("window.close")
	visible = false


func is_open() -> bool:
	return visible


## 当前网格里的卡片数（验收用）
func card_count() -> int:
	return _grid.get_child_count() if _grid != null else 0


## 当前选中舰船 id（验收用）
func selected_id() -> String:
	return _sel


## 设置筛选（验收直接调）：`fac`/`cost` 传 -1 = 全部；`role` 传 &"" = 全部。
func set_filter(fac: int, cost: int, role: StringName = &"") -> void:
	_fac = fac
	_cost = cost
	_role = role
	if _built:
		_sync_chips()
		_rebuild_grid()


## Esc 关闭；不拦其它键（菜单的键盘导航照常）。
func _unhandled_key_input(e: InputEvent) -> void:
	if not visible:
		return
	var k := e as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_ESCAPE:
		close()
		accept_event()


# ────────────────────────────────────────────── 构建

func _build() -> void:
	_built = true
	var veil := ColorRect.new()
	veil.color = Color(0.015, 0.025, 0.035, 0.80)
	veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(veil)

	_frame = PanelContainer.new()
	_frame.name = "Frame"
	_frame.add_theme_stylebox_override("panel", _frame_box())
	add_child(_frame)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	_frame.add_child(col)

	# ── 标题行 ──
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	col.add_child(head)
	var title := _label(T.t("CODEX_TITLE", "舰船图鉴"), 24, C_TEXT_HI)
	head.add_child(title)
	_count_lbl = _label("", 13, C_GOLD)
	head.add_child(_count_lbl)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(sp)
	var close_btn := _btn(T.t("CODEX_CLOSE", "关闭"), close, 92)
	head.add_child(close_btn)

	col.add_child(_hair())

	# ── 筛选：派系 ──
	#
	# ⛔⛔ 2026-10-28 修 bug（用户实测：「点艾玛出来的全是米玛塔尔的船」）：
	#    chip 顺序原来是「加达里 / 盖伦特 / 米玛塔尔 / 艾玛」，而回调算的是
	#    `_fac = i - 1` —— 但 `EveShip.Faction` 枚举是
	#    **AMARR=0 / CALDARI=1 / GALLENTE=2 / MINMATAR=3**（艾玛在前）。
	#    两套顺序错位一位 ⇒ 点「艾玛」拿到 3 = 米玛塔尔，点「加达里」拿到 0 = 艾玛，
	#    每一档都错，而且**每族都是 13 艘**，所以旧的「数量 = 13」断言全绿，
	#    错得毫无征兆。
	#    ⇒ 现在：列表顺序**就是枚举顺序**，并且用中文名去 `FACTION_INDEX` 查值，
	#      不再拿 chip 下标当 faction。
	var fac_row := _row("派系")
	var fac_names: Array = ["全部"]
	fac_names.append_array(Array(FACTION_NAMES))
	_fac_chips = _chip_row(fac_row, fac_names,
			func(i: int) -> void:
				_fac = -1 if i == 0 else _faction_of_chip(i)
				_sync_chips()
				_rebuild_grid())
	col.add_child(fac_row)

	# ── 筛选：吨位 ──
	var cost_row := _row("吨位")
	_cost_chips = _chip_row(cost_row, ["全部", "护卫", "驱逐", "巡洋", "战巡", "战列"],
			func(i: int) -> void:
				_cost = -1 if i == 0 else COSTS[i - 1]
				_sync_chips()
				_rebuild_grid())
	col.add_child(cost_row)

	# ── 筛选：定位（攻击 / 防御 / 后勤 / 电子战 / 加强型）──
	#
	# ★ 2026-10-28 用户：「最顶上的分类要加个定位」。
	# ⚠️ 五档是**互斥**的（口径见 EveShipDatabase.ROLE_TAGS 的注释）：
	#    电子战船不再重复算进「攻击型 / 防御型」⇒ 每档后面直接标艘数，
	#    玩家一眼能看出「攻击型 17」比表里的 20 少，少掉的是电子战那批。
	var role_row := _row("定位")
	var role_names: Array = ["全部 %d" % SHIP_DB.count()]
	var role_tags: Array[StringName] = [&""]
	for tg in SHIP_DB.ROLE_TAGS:
		role_tags.append(tg)
		role_names.append("%s %d" % [SHIP_DB.role_label(tg), SHIP_DB.count_by_role(tg)])
	_role_chips = _chip_row(role_row, role_names, func(i: int) -> void:
		_role = role_tags[i]
		_sync_chips()
		_rebuild_grid(), 96)
	col.add_child(role_row)

	col.add_child(_hair())

	# ── 主体：左网格 + 右详情 ──
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(body)

	_grid_scroll = ScrollContainer.new()
	_grid_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(_grid_scroll)
	EveWindow.widen_scrollbar(_grid_scroll)

	_grid = GridContainer.new()
	_grid.columns = 6
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_scroll.add_child(_grid)

	var detail_wrap := PanelContainer.new()
	detail_wrap.custom_minimum_size = Vector2(392, 0)
	detail_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_wrap.add_theme_stylebox_override("panel", _strip_box())
	body.add_child(detail_wrap)

	var dscroll := ScrollContainer.new()
	dscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	detail_wrap.add_child(dscroll)
	# ★ 2026-10-31（用户：「文本框也拉不动」）：右栏舰船详情是全工程唯一的长文本区，
	#   8px 滚动条压不住 ⇒ 加宽（见 `EveWindow.widen_scrollbar`）。
	EveWindow.widen_scrollbar(dscroll)
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override("separation", 6)
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dscroll.add_child(_detail)

	_layout()


func _layout() -> void:
	if _frame == null:
		return
	var w := minf(size.x * 0.92, 1600.0)
	var h := minf(size.y * 0.90, 940.0)
	_frame.position = ((size - Vector2(w, h)) * 0.5).floor()
	_frame.size = Vector2(w, h)
	if _grid != null:
		# ★ 2026-10-28 用户：「可以稀疏点」。
		#   6 列 → 5 列（单卡 172 → 208 宽）。列数不是随手调的：
		#   窄窗口下必须同步降档（5→3），否则卡片会被挤到比立绘还窄。
		_grid.columns = 5 if w >= 1180.0 else 3


# ────────────────────────────────────────────── 网格 / 详情

func _rebuild_grid() -> void:
	if _grid == null:
		return
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	_cards.clear()
	var shown := 0
	for s in SHIP_DB.all_ships():
		if _fac >= 0 and int(s["faction"]) != _fac:
			continue
		if _cost >= 0 and int(s["cost"]) != _cost:
			continue
		if _role != &"" and SHIP_DB.role_tag(String(s["ship_key"])) != _role:
			continue
		var key := String(s["ship_key"])
		var card := _make_card(s)
		_grid.add_child(card)
		_cards[key] = card
		shown += 1
	if _count_lbl != null:
		_count_lbl.text = T.t("CODEX_COUNT", "收录 %d / %d 艘") % [shown, SHIP_DB.count()]
	# ★ 2026-10-28：当前选中项被筛选筛掉时，自动改选结果里的第一艘。
	#   ⛔ 不修的话右边详情还挂着上一族的船（"点艾玛，详情写小鹰级"），
	#     看起来像筛选没生效。
	if not _cards.is_empty() and not _cards.has(_sel):
		var keys := _cards.keys()
		_select(String(keys[0]))
	elif _sel != "" and _cards.has(_sel):
		_apply_card_style(_sel, true)


func _make_card(s: Dictionary) -> PanelContainer:
	var key := String(s["ship_key"])
	var p := PanelContainer.new()
	p.name = "Card_%s" % key
	p.custom_minimum_size = Vector2(208, 130)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	p.add_theme_stylebox_override("panel", _card_box(false))
	p.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed \
				and ev.button_index == MOUSE_BUTTON_LEFT:
			_select(key))
	p.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			EveUiAudio.play("fleet.select"))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(box)

	# 真立绘（与商店卡同一控件 EveShipArtView）。
	# 高度给到 66：立绘是 512×512 方图，扁船要经过 used_rect 裁留白才撑得开，
	# 槽位太矮会变成"远处的蚊子"（见 EveShipArt.used_rect 的注释）。
	var art = ART.new()
	art.custom_minimum_size = Vector2(0, 74)
	art.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	art.size_flags_vertical = Control.SIZE_EXPAND_FILL
	art.inset = 4.0
	art.set_ship_key(StringName(key))
	box.add_child(art)

	var nm := _label(String(s["name"]), 13, C_TEXT_HI, HORIZONTAL_ALIGNMENT_CENTER)
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(nm)

	var cls := String(EveShipTable.CLASS_NAMES_BY_COST.get(int(s["cost"]), "?"))
	# 定位用 `role_tag` 的中文，而不是表里的 `role` —— 否则「电子战」「加强型」
	# 两档在卡面上会显示成「攻击型 / 防御型」，和上面的筛选对不上。
	var meta := "%s · %s · %s" % [cls, String(s["weapon_type"]),
			SHIP_DB.role_label(SHIP_DB.role_tag(key))]
	var mt := _label(meta, 9, C_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	mt.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(mt)
	return p


func _select(key: String) -> void:
	var prev := _sel
	_sel = key
	if prev != "" and _cards.has(prev):
		_apply_card_style(prev, false)
	if _cards.has(key):
		_apply_card_style(key, true)
	_render_detail(SHIP_DB.by_id(key))


func _apply_card_style(key: String, on: bool) -> void:
	var p: PanelContainer = _cards.get(key, null)
	if p == null:
		return
	p.add_theme_stylebox_override("panel", _card_box(on))


func _render_detail(s: Dictionary) -> void:
	if _detail == null:
		return
	for c in _detail.get_children():
		_detail.remove_child(c)
		c.queue_free()
	if s.is_empty():
		return
	var key := String(s["ship_key"])

	# 详情大图：同一控件，给足高度让舰体轮廓可读
	var art = ART.new()
	art.custom_minimum_size = Vector2(0, 168)
	art.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	art.inset = 6.0
	art.set_ship_key(StringName(key))
	_detail.add_child(art)

	_detail.add_child(_label(String(s["name"]), 20, C_TEXT_HI))
	_detail.add_child(_label(String(s["en"]), 11, C_DIM))
	var cls := String(EveShipTable.CLASS_NAMES_BY_COST.get(int(s["cost"]), "?"))
	_detail.add_child(_label("%s · 费用 %d · %s · %s · %s" % [
			String(s["faction_cn"]), int(s["cost"]), cls,
			String(s["weapon_type"]),
			SHIP_DB.role_label(SHIP_DB.role_tag(key))], 12, C_ACCENT))
	_detail.add_child(_hair())

	_detail.add_child(_kv("护盾", "%.0f" % float(s["shield"])))
	_detail.add_child(_kv("装甲", "%.0f" % float(s["armor"])))
	_detail.add_child(_kv("结构", "%.0f" % float(s["hull"])))
	# ★ 2026-10-29：图鉴原来只写「攻击（表值）」+ 射击间隔 —— 表里的 attack
	#   等于 **DPS**（`weapon_damage = attack × cycle`），玩家拿 80 ÷ 1.5 会算成
	#   53，和战斗里冒出来的 120 对不上。⇒ 直接写成「每发」与「DPS」两行。
	var wdmg := float(s["weapon_damage"])
	var wcycle := maxf(0.01, float(s["weapon_cycle"]))
	_detail.add_child(_kv("每发伤害", "%.0f" % wdmg))
	_detail.add_child(_kv("DPS", "%.0f" % (wdmg / wcycle)))
	_detail.add_child(_kv("射程", "%d 格 · %.1f km" % [int(s["range_cells"]),
			float(s["optimal_range"]) / 1000.0]))
	_detail.add_child(_kv("速度", "%.2f 格 · %.0f m/s" % [float(s["speed_cells"]),
			float(s["max_speed"])]))
	_detail.add_child(_kv("射击间隔", "%.2f s（%.2f 发/秒）" % [wcycle,
			float(s["shots_per_second"])]))
	# 穿盾：只有战列舰带（0 = 普通「先破盾再打到甲」的顺序）。
	if float(s.get("shield_pierce", 0.0)) > 0.0:
		_detail.add_child(_kv("穿盾概率", "%.0f%% 直接落到装甲" % (
				float(s["shield_pierce"]) * 100.0)))
	# ★ 2026-10-29（用户：「加强型单独加一个出现概率减少」）：
	#   权重 < 1.0 的船写明「稀有」——同费里它不是等概率出现的，
	#   图鉴不写就等于让玩家以为自己和普通战列一样好刷。
	var weight := SHIP_DB.shop_weight(StringName(key))
	if weight < 1.0:
		_detail.add_child(_kv("刷新概率", "稀有 · 约为普通战列的 %.0f%%"
				% (weight * 100.0)))
	# 抗性：2026-10-29 起全表归 0 ⇒ 显示「无」而不是藏起来，
	# 否则玩家会以为图鉴漏了一行。以后若给某几艘填回抗性，这行会自动变百分数。
	var rmax := 0.0
	for arr in [s["shield_resists"], s["armor_resists"], s["hull_resists"]]:
		for v in arr:
			rmax = maxf(rmax, float(v))
	_detail.add_child(_kv("抗性",
			"无（四类伤害都不减免）" if rmax <= 0.0 else "最高 %.0f%%" % (rmax * 100.0)))
	if bool(s["is_logistics"]):
		# ★ 2026-10-28 后勤改成**同时修两层**（另一层 = 主修 × 3/7）。
		#   两笔都写出来 —— 只写主修会让玩家以为派生那条不存在。
		var lay := "护盾" if String(s["logistics_layer"]) == "shield" else "装甲"
		var lay2 := "装甲" if String(s["logistics_layer"]) == "shield" else "护盾"
		_detail.add_child(_kv("后勤", "每 %.1f s 修 %s %.0f 点 · %s %.0f 点" % [
				float(s["logistics_cycle"]), lay, float(s["logistics_repair"]),
				lay2, float(s["logistics_repair_secondary"])]))

	_detail.add_child(_hair())
	_detail.add_child(_label(T.t("CODEX_TRAITS", "羁绊归属"), 12, C_DIM))
	var tr: PackedStringArray = s["traits"]
	_detail.add_child(_label(" · ".join(tr), 14, C_GOLD))


# ────────────────────────────────────────────── 小控件

func _row(title: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 6)
	var lb := _label(title, 13, C_DIM)
	lb.custom_minimum_size = Vector2(44, 0)
	r.add_child(lb)
	return r


func _chip_row(row: HBoxContainer, names: Array, cb: Callable, w: int = 78) -> Array[Button]:
	var out: Array[Button] = []
	for i in names.size():
		var b := Button.new()
		b.text = String(names[i])
		b.set_meta("ui_audio_slot", "ui.tab")
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(w, 28)
		b.add_theme_font_size_override("font_size", FONT.s(12))
		b.add_theme_color_override("font_color", C_TEXT)
		b.add_theme_color_override("font_hover_color", C_TEXT_HI)
		b.add_theme_color_override("font_pressed_color", C_TEXT_HI)
		for st in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(st, _chip_box(st == "pressed" or st == "focus"))
		b.pressed.connect(func(): cb.call(i))
		row.add_child(b)
		out.append(b)
	return out


## chip 下标 → 派系枚举值。0「全部」或越界 ⇒ -1。
##
## ⚠️ 走 `FACTION_INDEX` 查表，不写死 0/1/2/3 —— 以后加派系只改 `FACTION_NAMES`
##    和枚举，这里不用动。
func _faction_of_chip(i: int) -> int:
	if i <= 0 or i > FACTION_NAMES.size():
		return -1
	return int(EveShipTable.FACTION_INDEX.get(FACTION_NAMES[i - 1], -1))


## 当前网格里显示的舰船 id（**验收用**）。
##
## ⛔ 存在的理由：每族都是 13 艘、每档吨位也固定，「只数数量」的断言永远绿 ——
##    正是这个漏洞让「点艾玛出米玛塔尔」活了很久。要比对具体 id 才有意义。
func visible_ids() -> Array[String]:
	var out: Array[String] = []
	for k in _cards.keys():
		out.append(String(k))
	out.sort()
	return out


func _sync_chips() -> void:
	for i in _fac_chips.size():
		_fac_chips[i].button_pressed = \
				(_fac == -1 and i == 0) or (_fac == _faction_of_chip(i))
	for i in _cost_chips.size():
		_cost_chips[i].button_pressed = \
				(_cost == -1 and i == 0) or (_cost == COSTS[i - 1])
	for i in _role_chips.size():
		var on := false
		if i == 0:
			on = _role == &""
		elif i - 1 < SHIP_DB.ROLE_TAGS.size():
			on = _role == SHIP_DB.ROLE_TAGS[i - 1]
		_role_chips[i].button_pressed = on


func _label(text: String, size: int, col: Color, align: int = 0) -> Label:
	var l := Label.new()
	l.text = text
	FONT.fs(l, size)
	l.add_theme_color_override("font_color", col)
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _kv(k: String, v: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 6)
	var kl := _label(k, 12, C_DIM)
	kl.custom_minimum_size = Vector2(120, 0)
	r.add_child(kl)
	var vl := _label(v, 13, C_TEXT_HI)
	vl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(vl)
	return r


func _hair() -> ColorRect:
	var r := ColorRect.new()
	r.color = C_SEP
	r.custom_minimum_size = Vector2(0, 1)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _btn(text: String, cb: Callable, w: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(w, 34)
	b.add_theme_font_size_override("font_size", FONT.s(14))
	b.add_theme_color_override("font_color", C_TEXT_HI)
	b.add_theme_color_override("font_hover_color", C_ACCENT)
	for st in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(st, _chip_box(st != "normal"))
	b.pressed.connect(cb)
	return b


func _frame_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_CARD
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 16
	sb.content_margin_bottom = 16
	return sb


func _card_box(on: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.055, 0.075, 0.092, 0.92) if on else C_STRIP
	sb.border_color = C_ACCENT if on else C_BORDER
	sb.set_border_width_all(1)
	sb.border_width_left = 3 if on else 1
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


func _strip_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_STRIP
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


func _chip_box(on: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.11, 0.13, 0.95) if on else Color(0.039, 0.055, 0.067, 0.7)
	sb.border_color = C_ACCENT if on else C_BORDER
	sb.set_border_width_all(1)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb
