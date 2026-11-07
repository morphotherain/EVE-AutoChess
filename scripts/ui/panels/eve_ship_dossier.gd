extends "res://scripts/ui/eve_window.gd"

## EVE 自走棋 —— 舰船档案窗（右列上）
##
## 内容口径 = 云顶之弈的棋子信息面板（用户原话「参考云顶之弈的棋子信息」）：
##   立绘 → 名称 + 星级 → 羁绊（n/m + 是否生效）→ 三层血量 →
##   六格属性 → 特性 → 装备 2 格
##
## ── 两态（V3 稿定稿）────────────────────────────────────────────
##   收起 172 × 128：默认。只有一枚淡淡的机库剪影 + 「点击舰船查看」
##   展开 172 × 320：点到舰船（战场 / 备战席 / 商店卡任一处）才展开
##   展开后底边落在 y=376，右下战斗日志从 y=384 起 —— 刚好不打架。
##
## ── 立绘 ────────────────────────────────────────────────────────
##   官方 1024px 渲染图 → 语义分割抠像 → 512×512 透明底画布，
##   落在 res://assets/ships/<id>.png，由 EveShipArt 取用并缓存。
##   缺图自动退回程序化侧影（见 _Portrait）。
##
## 变更清单（实装版）：
##   - 收起 / 展开两态 + 动画无关的瞬时切换
##   - 三组羁绊行（势力 / 武器 / 防御），带 n/m 与生效高亮
##   - 属性按【权威表原值】显示（攻击 / 攻击间隔 / 射程格 / 移速格），
##     只有「信号半径 / 吨位」是工程派生值（权威表没有这两列）

## ★ 2026-10-10（审查 2#5）：`_extra` 键名常量（拼错键不报错 ⇒ 用常量）。
const CIDS := preload("res://scripts/core/eve_combat_ids.gd")
## ★ 2026-10-10（i18n）：术语取词（见 `eve_terms.gd` 顶注）。
const TERMS := preload("res://scripts/core/eve_terms.gd")
## ★ 2026-10-10（i18n）：文案取词（见 `eve_text.gd` 顶注）。
const T := preload("res://scripts/core/eve_text.gd")

const W_COLLAPSED := 128.0
const H_COLLAPSED := 128.0
## ⚠️ 2026-10-26：320 → **376**。羁绊行从 3 条（势力/武器/防御）加到 5 条（+后勤 +电子战），
##    内容最小高实测 332，加上外框（标题栏 33 + 下内距 8）需要 373 —— 320 会裁掉最后一行。
##    ⛔ 与其压行高，不如把窗加高：这是「一屏看全舰船档案」的窗，缺一行比多 56px 更难接受。
const H_EXPANDED := 376.0

## ★★ 2026-10-28（用户：「左上角舰船档案需要添加一个缩放按钮，让它能够缩放。
##   然后如果我拖放它放大了，点击下一艘船的档案时，这个窗口应该维持拉大后的样式」）
##
##   为什么还要按钮：右下角那道三角把手只有 14 px，手机上手指压不准；
##   而且它在窗口右下角，被战斗日志挡着 —— 等于「找不到 = 缩不了」。
##   ⇒ 标题栏加一枚自绘的「放大 / 还原」按钮（两态切换，⛔ 不是连续缩放）。
##
##   ⚠️ 尺寸必须记进 `_user_rect`（`_note_user_rect()` 干这件事）——
##      `set_ship()` 每换一艘都会走 `_set_expanded(true)`，它按 `_user_rect.size`
##      恢复尺寸；不记就等于「关掉档案再打开、放大白做」。
const ZOOM_SCALE := 1.5
## 放大后的最大高/宽（设计空间像素）—— 别让档案盖住商店与棋盘。
## ⚠️ 视口只有 1080 高，376×1.5=564 已经占了小半屏；再大就挡战场了。
const ZOOM_MAX_H := 660.0
const ZOOM_MAX_W := 520.0

var ship: EveShip = null

## ★ 缩放按钮（标题栏自绘图标，插在关闭按钮左边）
var _zoom_btn: Button
var _zoom_hot := false
## 当前是否处于「放大」态。⛔ 不要在 `_set_expanded()` 里重置它 ——
## 收起再展开应当回到放大尺寸，而不是被"重新展开"悄悄缩回去。
var _zoomed := false
## 放大前的尺寸（点「还原」时回到这里）
var _zoom_base_size := Vector2.ZERO

var _portrait: Control
var _name_label: Label
var _meta_label: Label
var _star_label: Label
var _trait_rows: Array[Dictionary] = []
var _bars: Dictionary = {}
var _hp_labels: Dictionary = {}
var _stat_labels: Dictionary = {}
var _trait_box: VBoxContainer
var _eq_row: HBoxContainer

var _built := false


func _ready() -> void:
	# ★ 本窗**自己**实现收起/展开（128 ↔ 320）⇒ ⛔ 关掉 EveWindow 的通用的收起，
	#   否则两套收起会互相打架（一个收一个展，看起来像抽风）。
	collapsible = false
	persist_layout = false   # 它自己管高度，别让玩家的拖动记录压过 128/320
	window_title = T.t("DOSSIER_TITLE", "舰船档案")
	density = Density.COMPACT
	show_status_text = false
	super._ready()
	_build_contents()
	_build_zoom_btn()
	_built = true
	collapse()


## 收起 = 只有提示；展开 = 完整内容
##
## ⚠️ 切的是两个内容盒的 visible，不是 content 的 ——
##    content 是 EveWindow 的内容容器，把它隐藏了收起态也是一片空白。
func _set_expanded(on: bool) -> void:
	if _empty_box:
		_empty_box.visible = not on
	if _full_box:
		_full_box.visible = on
	# ★ 2026-10-25（用户：「拖动放大之后再点另一艘船，会变回去」）：
	#   `set_ship()` 每换一艘都会走到这里 ⇒ 从前无条件 `set_window_height(320)`，
	#   把玩家自己拉大的尺寸**每次都抹掉**（宽也不保：`set_window_height` 曾只从
	#   `_base_rect` 取宽，而 `_base_rect` 是设计稿值）。
	#   现在：展开态一旦玩家缩放过，就用**玩家自己的高度**；宽度由 EveWindow 侧
	#   （`set_window_height` / `set_window_rect`）统一尊重 `_user_rect.size.x`。
	#   ⛔ 折叠态仍强制 128 —— 那是「收起」的语义，不是玩家尺寸。
	var h := H_EXPANDED if on else H_COLLAPSED
	# ⚠️ 判定门槛用 H_COLLAPSED：`EveWindow._note_user_rect()` 在收起态会
	#    存下**展开态**的高度（> 128），所以这个值直接可用；128 本身被排除。
	if on and _user_rect.size.y > H_COLLAPSED + 1.0:
		h = _user_rect.size.y
	set_window_height(h)
	# ★ 2026-10-28：收起态没有内容可放大 ⇒ 缩放按钮跟着隐掉。
	#   ⚠️ 不动 `_zoomed` —— 收起再展开要回到放大后的尺寸（见字段注释）。
	if _zoom_btn != null:
		_zoom_btn.visible = on


func collapse() -> void:
	ship = null
	_set_expanded(false)


# ------------------------------------------------------------------ 缩放按钮

## 标题栏里那枚「放大 / 还原」按钮。
##
## ⚠️ 自绘而不是 `Button`：本工程的按钮皮肤（`EveButtonTheme`）带边框与文字，
##    塞进 26 px 高的标题栏会得到一个难看的方框 —— 与收起/关闭按钮同一口径。
## ⚠️ 插入位置：**关闭按钮左边**（`move_child`）。
##    HBoxContainer 按子节点顺序从左到右排，直接 `add_child` 会排到最右。
##    本窗 `closable = false`（没有 ✕，见 `EveWindow.closable` 默认值），
##    所以实际它就是标题栏最右那一枚；这句 `move_child` 是为「将来开 closable」留的顺序。
func _build_zoom_btn() -> void:
	if header == null:
		return
	# ⛔⛔ 2026-10-28 实测：这里原来是**裸 Control + gui_input**，按钮画得出来、
	#    尺寸位置全对、`visible=true`、`mouse_filter=STOP`，但**真实鼠标点在
	#    按钮上时命中的是标题栏 HBox**（`gui_get_hovered_control()` 返回
	#    `@HBoxContainer@199`）⇒ `toggle_zoom()` 一次都没被调用过
	#    ⇒ 玩家看到的正是「有一颗图标，点了没反应」。
	#    换成 Button（flat + 清空 stylebox）后点击正常。⛔ 别再改回裸 Control。
	_zoom_btn = Button.new()
	_zoom_btn.name = "ZoomBtn"
	_zoom_btn.flat = true
	_zoom_btn.focus_mode = Control.FOCUS_NONE
	_zoom_btn.custom_minimum_size = Vector2(22, 18)
	_zoom_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_zoom_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_zoom_btn.tooltip_text = T.t("DOSSIER_ZOOM_TIP", "放大 / 还原")
	# 图标全自绘 ⇒ Button 自己的各态底色必须清干净，否则 hover 时冒出一块方底。
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		_zoom_btn.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	_zoom_btn.draw.connect(_draw_zoom_btn)
	_zoom_btn.pressed.connect(toggle_zoom)
	_zoom_btn.mouse_entered.connect(func() -> void:
		_zoom_hot = true
		if _zoom_btn != null:
			_zoom_btn.queue_redraw())
	_zoom_btn.mouse_exited.connect(func() -> void:
		_zoom_hot = false
		if _zoom_btn != null:
			_zoom_btn.queue_redraw())
	header.add_child(_zoom_btn)
	if _close_btn != null:
		header.move_child(_zoom_btn, _close_btn.get_index())
	_zoom_btn.visible = false


## 两态图标：放大态画**向内**的双箭头（提示「再点会缩回去」），
## 常态画**向外**的双箭头。与收起按钮的 chevron 同一套线条语言。
func _draw_zoom_btn() -> void:
	if _zoom_btn == null:
		return
	var c := _zoom_btn.size * 0.5
	var col := Color(0.82, 0.93, 0.96, 0.95) if _zoom_hot \
			else Color(0.58, 0.72, 0.76, 0.80)
	# near / far 反过来画就是两态：
	#   常态 杆从内侧走到外侧、箭头尖在外（放大）
	#   放大 杆从外侧走到内侧、箭头尖在内（还原）
	var near := 1.6
	var far := 5.2
	var from_d := far if _zoomed else near
	var to_d := near if _zoomed else far
	_draw_zoom_arrow(c + Vector2(-from_d, from_d), c + Vector2(-to_d, to_d), col)
	_draw_zoom_arrow(c + Vector2(from_d, -from_d), c + Vector2(to_d, -to_d), col)


## 一支 45° 箭头：`from` 是杆的起点，`to` 是箭头尖。
func _draw_zoom_arrow(from: Vector2, to: Vector2, col: Color) -> void:
	if _zoom_btn == null:
		return
	_zoom_btn.draw_line(from, to, col, 1.4)
	var dir := (to - from).normalized()
	var side := Vector2(-dir.y, dir.x)
	var head := 2.4
	_zoom_btn.draw_line(to, to - dir * head + side * head * 0.85, col, 1.4)
	_zoom_btn.draw_line(to, to - dir * head - side * head * 0.85, col, 1.4)


## 放大 ↔ 还原（幂等口径：只看当前是不是放大态）。
func toggle_zoom() -> void:
	if _zoom_btn == null or not _zoom_btn.visible:
		return
	if _zoomed:
		_apply_zoom(_zoom_base_size)
		_zoomed = false
	else:
		_zoom_base_size = size
		_apply_zoom(size * ZOOM_SCALE)
		_zoomed = true
	if _zoom_btn != null:
		_zoom_btn.queue_redraw()


func is_zoomed() -> bool:
	return _zoomed


## 把窗设成指定尺寸，并把结果记成「玩家尺寸」。
##
## ⚠️ 顺序不能换：先把目标尺寸写进 `_user_rect`，再调基类的 `set_window_height()`。
##    基类那条路**宽度一律从 `_user_rect.size.x` 取**（玩家缩放过就听玩家的），
##    不先写它，就只有高度变了、宽度纹丝不动 —— 看起来像"按钮没反应"。
## ⚠️ `set_window_height()` 取位置时也看 `_user_rect.size`，所以位置必须显式给
##    当前真实位置（`position`）；漏给会把窗拽到 (0,0)。
func _apply_zoom(want: Vector2) -> void:
	var w := clampf(want.x, W_COLLAPSED, ZOOM_MAX_W)
	# ⚠️ 下限用 `HEADER_H + 1` 而不是 H_EXPANDED：玩家可能先用右下角把手把窗
	#    拖得比 376 还矮，再点放大 —— 还原时要回到**他拖的那个尺寸**，
	#    不是被悄悄抬回 376。
	var h := clampf(want.y, HEADER_H + 1.0, ZOOM_MAX_H)
	_user_rect = Rect2(position, Vector2(w, h))
	set_window_height(h)
	_fit_zoom_into_view()
	# 记成玩家尺寸 ⇒ `set_ship()` 换下一艘船时才会**原样恢复**（用户明确要求）。
	_note_user_rect()
	# ★ 2026-10-28：立刻落盘。不存的话"放大"只在本次会话有效，
	#   而 `_save_layout()` 又会在别处（拖拽/隐藏时）把放大尺寸存下去 ——
	#   最终存下来的是「大尺寸 + 没有放大标记」，正是用户遇到的那一版坏档。
	_save_layout()


## ── 布局存档：把「放大态」一起存 ────────────────────────────────
##
## ⛔⛔ 2026-10-28 用户复测：「我放大之后，再到下一局，没法缩小了」。
##
##   根因：`_apply_zoom()` 把放大尺寸记进 `_user_rect`，随后别处调的
##   `_save_layout()` 把 258×564 写进 `window_layout.cfg`，**但"处于放大态"没写**。
##   下一局读出 258×564、`_zoomed` 却是 false ⇒ 点按钮等于「拿放大尺寸当基准
##   再放大 1.5 倍」，点第二次只回到 258×564 —— **永远回不到 172×376**。
##
##   ⇒ 尺寸和态必须一起存（基类 `EveWindow._layout_extra` 就是为这个加的钩子）。
func _layout_extra() -> Dictionary:
	if not _zoomed:
		return {}
	return {
		"zoom": true,
		"zoom_w": _zoom_base_size.x,
		"zoom_h": _zoom_base_size.y,
	}


func _apply_layout_extra(d: Dictionary) -> void:
	if not bool(d.get("zoom", false)):
		# ★ 旧档兼容：2026-10-28 之前存下的档只有「放大尺寸」、没有放大标记。
		# 判据：高 ≈ 设计高 × ZOOM_SCALE（容差 2px）。命中就当"当时是放大态"，
		# 反推基准尺寸 ⇒ 玩家点一下就能缩回去（否则那批档一次都点不回来）。
		if _user_rect.size.y > H_EXPANDED * ZOOM_SCALE - 2.0:
			_zoomed = true
			_zoom_base_size = Vector2(_user_rect.size.x / ZOOM_SCALE,
					_user_rect.size.y / ZOOM_SCALE)
			if _zoom_btn != null:
				_zoom_btn.queue_redraw()
		return
	_zoomed = true
	var bw := float(d.get("zoom_w", 0.0))
	var bh := float(d.get("zoom_h", 0.0))
	# 存档里没带基准尺寸（将来若有人只写 zoom 标记）⇒ 用当前尺寸反推。
	_zoom_base_size = Vector2(bw, bh) if bw > 1.0 and bh > 1.0 \
			else Vector2(_user_rect.size.x / ZOOM_SCALE, H_EXPANDED)
	if _zoom_btn != null:
		_zoom_btn.queue_redraw()


## 放大后把窗推回屏幕内。
##
## ⚠️ 档案窗贴在右列 ⇒ 变宽会把右边缘顶出屏幕（右下角那道 grip 跟着出屏，
##    玩家再也缩不回来）。基础的 `_clamp_into_viewport()` 只保证「至少露出
##    60 px」，对"放大"这个动作不够 —— 这里要求**整扇窗可见**。
func _fit_zoom_into_view() -> void:
	var parent := get_parent_control()
	if parent == null:
		return
	var limit := parent.size
	if limit.x <= 1.0 or limit.y <= 1.0:
		return
	var x := position.x
	var y := position.y
	if x + size.x > limit.x - FIT_MARGIN:
		x = maxf(FIT_MARGIN, limit.x - FIT_MARGIN - size.x)
	if y + size.y > limit.y - FIT_MARGIN:
		y = maxf(FIT_MARGIN, limit.y - FIT_MARGIN - size.y)
	position = Vector2(x, y)
	# ⚠️ 三处都要同步：否则下次 HUD 刷新（`set_window_rect`）或 `set_ship()`
	#    （`set_window_height`）会把刚推回来的位置又按旧位置摆回去。
	_base_rect.position = position
	_user_rect.position = position


## ★ 2026-10-28：HUD **每次刷新**都会重铺窗口（`set_window_rect`），
##   而它算 x 用的是**设计宽 172** —— 放大到 258 后右边缘会顶出屏幕，
##   右下角那道 grip 跟着出屏（= 玩家再也缩不回来）。
##   ⇒ 重铺完再夹一次；只在放大态做，常规尺寸不额外挪动位置。
##
## ⚠️ 必须 `super.set_window_rect()` 先跑：宽度就是它按 `_user_rect.size.x` 还原的，
##    漏掉它连"放大后的宽"都保不住。
func set_window_rect(x: float, y: float, w: float, h: float) -> void:
	super.set_window_rect(x, y, w, h)
	if _zoomed:
		_fit_zoom_into_view()
		_note_user_rect()


# ------------------------------------------------------------------ 构建

func _build_contents() -> void:
	# 收起态的提示（与展开态互斥显示）
	_empty_box = VBoxContainer.new()
	_empty_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_empty_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty_box.add_theme_constant_override("separation", 5)
	content.add_child(_empty_box)

	var ic := EveIcon.make(&"hangar", 30, Color(0.55, 0.78, 0.82, 0.30), 1.4)
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_empty_box.add_child(ic)

	var h := Label.new()
	h.text = T.t("DOSSIER_EMPTY_H", "点击舰船查看")
	h.add_theme_color_override("font_color", Color(0.561, 0.651, 0.686))
	FONT.fs(h, 11)
	h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_box.add_child(h)

	var p := Label.new()
	# ★ 2026-11-07：商店卡重新变成**合法的点选入口** —— 它现在第一下只是
	#   展开档案（`EveShop.preview_requested`），不再直接扣钱。
	#   （2026-10-30 删掉「商店卡」是因为那一下的语义是购买，见当时的说明。）
	p.text = T.t("DOSSIER_EMPTY_P", "战场 / 备战席 / 商店卡\n任一处点选即可")
	p.add_theme_color_override("font_color", C_TEXT_FAINT)
	FONT.fs(p, 9)
	p.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_box.add_child(p)

	# ── 以下是展开态内容（先建好，整体切 visible）──
	#
	# ⚠️ separation 必须压到 3：320 高的窗（扣掉 26 标题栏 + 14 内边距 = 280）
	#    要装下「立绘 / 名称 / 元信息 / 3 羁绊行 / 3 血条 / 6 属性 / 定位 / 2 装备格」，
	#    按 4 算会超出约 20px —— 表现为最底下两个装备格被窗底裁掉（实测过一次）。
	_full_box = VBoxContainer.new()
	_full_box.add_theme_constant_override("separation", 3)
	_full_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_full_box)

	# 立绘位
	_portrait = _Portrait.new()
	_portrait.custom_minimum_size = Vector2(0, 38)
	_full_box.add_child(_portrait)

	# 名称 + 星级
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	_full_box.add_child(head)

	_name_label = Label.new()
	_name_label.text = T.t("DOSSIER_NONE", "未选中")
	_name_label.add_theme_color_override("font_color", Color(0.918, 0.969, 0.980))
	FONT.fs(_name_label, 12)
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(_name_label)

	_star_label = Label.new()
	_star_label.text = ""
	_star_label.add_theme_color_override("font_color", C_GOLD)
	FONT.fs(_star_label, 10)
	_star_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(_star_label)

	_meta_label = Label.new()
	_meta_label.text = ""
	_meta_label.add_theme_color_override("font_color", C_TEXT_DIM)
	FONT.fs(_meta_label, 9)
	_meta_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full_box.add_child(_meta_label)

	# 羁绊 3 行（势力 / 武器 / 防御）
	_trait_box = VBoxContainer.new()
	_trait_box.add_theme_constant_override("separation", 1)
	_full_box.add_child(_trait_box)
	for g in EveTraitTable.GROUPS:
		_trait_rows.append(_build_trait_row(g["key"]))

	_full_box.add_child(make_divider())

	# 三层血量
	for item in [
		[T.t("DOSSIER_HP_SHIELD", "护盾"), "shield", C_SHIELD],
		[T.t("DOSSIER_HP_ARMOR", "装甲"), "armor", C_ARMOR],
		[T.t("DOSSIER_HP_HULL", "结构"), "hull", C_HULL],
	]:
		var bar_row := make_bar_row(String(item[0]), item[2], 1.0, 26.0, 44.0)
		_full_box.add_child(bar_row["row"])
		_bars[item[1]] = bar_row["bar"]
		_hp_labels[item[1]] = bar_row["num"]

	_full_box.add_child(make_divider())

	# 六格属性（2 列 × 3 行）
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 0)
	_full_box.add_child(grid)
	for item in [
		[T.t("DOSSIER_ATTR_HIT", "每发"), "attack"],
		[T.t("DOSSIER_ATTR_INTERVAL", "攻击间隔"), "interval"],
		[T.t("DOSSIER_ATTR_RANGE", "射程"), "range"],
		[T.t("DOSSIER_ATTR_SPEED", "移速"), "speed"],
		[T.t("DOSSIER_ATTR_SIG", "信号半径"), "sig"],
		[T.t("DOSSIER_ATTR_CLASS", "吨位"), "class"],
	]:
		var row := _build_attr(String(item[0]), String(item[1]))
		grid.add_child(row["root"])
		_stat_labels[item[1]] = row["value"]

	_full_box.add_child(make_divider())

	# 特性 / 定位
	_role_label = Label.new()
	_role_label.text = T.t("DOSSIER_ROLE_NONE", "定位　—")
	_role_label.add_theme_color_override("font_color", C_TEXT_DIM)
	FONT.fs(_role_label, 10)
	_role_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_role_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full_box.add_child(_role_label)

	# 装备 2 格
	_eq_row = HBoxContainer.new()
	_eq_row.add_theme_constant_override("separation", 5)
	_full_box.add_child(_eq_row)
	for i in 2:
		var slot := EveSlot.new()
		slot.custom_minimum_size = Vector2(30, 30)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_eq_row.add_child(slot)


var _empty_box: VBoxContainer
var _full_box: VBoxContainer
var _role_label: Label


func _build_trait_row(group: StringName) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	# ★ 2026-10-25（A 方案）：行要能出 tooltip 说明「谁在贡献」⇒ 不能 IGNORE
	row.mouse_filter = Control.MOUSE_FILTER_PASS

	var chip := ColorRect.new()
	chip.custom_minimum_size = Vector2(10, 10)
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(chip)

	var nm := Label.new()
	nm.text = "—"
	nm.add_theme_color_override("font_color", C_TEXT)
	FONT.fs(nm, 10)
	nm.custom_minimum_size = Vector2(50, 0)
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(nm)

	var ratio := Label.new()
	ratio.text = "0/0"
	ratio.add_theme_color_override("font_color", Color(0.918, 0.969, 0.980))
	FONT.fs(ratio, 9)
	ratio.custom_minimum_size = Vector2(24, 0)
	ratio.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(ratio)

	var state := Label.new()
	state.text = ""
	state.add_theme_color_override("font_color", C_TEXT_FAINT)
	FONT.fs(state, 9)
	state.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	state.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	state.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(state)

	_trait_box.add_child(row)
	return {"group": group, "chip": chip, "name": nm, "ratio": ratio,
			"state": state, "row": row}


func _build_attr(key: String, id: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var k := Label.new()
	k.text = key
	k.add_theme_color_override("font_color", C_TEXT_DIM)
	FONT.fs(k, 9)
	k.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(k)

	var v := Label.new()
	v.text = "—"
	v.add_theme_color_override("font_color", Color(0.733, 0.851, 0.882))
	FONT.fs(v, 9)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(v)

	return {"root": row, "value": v}


# ------------------------------------------------------------------ 数据绑定

func set_ship(p_ship: EveShip) -> void:
	if p_ship == null:
		collapse()
		return
	ship = p_ship
	if not _built:
		return
	_set_expanded(true)

	_name_label.text = ship.ship_name
	# ★★ 2026-11-01（玩家报 bug：「合成三星战巡，进游戏之后发现自动下调到 2 星」）：
	#   这里原来是 `_stars_for_cost(ship.cost)` —— **按吨位猜星级**
	#   （cost ≥5 → ★3、cost ≥3 → ★2、其余 ★1），**根本没读 `ship.star`**。
	#   于是任何一艘合成船在档案窗里都会被显示成"该吨位的默认星级"：
	#   三星战巡（cost 4）→ 显示 ★2，三星护卫（cost 1）→ 显示 ★1，
	#   玩家只会以为系统把他的船降星了。实际数值一直是按真星级算的
	#   （`EveFleetFactory.apply_star` 用的是 entry 的 star），只是**显示在骗人**。
	#   ⛔ 别再用吨位推星级 —— 星级是编制里的独立字段（`{"ship_key","star"}`），
	#      与吨位正交，一艘 cost 3 的船既可能是 ★1 也可能是 ★3。
	_star_label.text = "★ %d" % maxi(1, ship.star)
	_meta_label.text = T.t("DOSSIER_META", "%s · %s · %d 费") % [
		ship.faction_name(), ship.class_name_cn(), ship.cost]

	var art: _Portrait = _portrait
	art.ship = ship
	art.queue_redraw()

	# 属性（权威表原值优先，缺了才退回派生值）
	# ★ 2026-10-29：原来显示 `attack`（= **DPS** 口径）与 `attack_interval` 取整
	#   ⇒ 「攻击 80 / 间隔 1」和战斗里冒出来的 120 对不上（80×1.5=120）。
	#   现在显示**每发伤害**与保留两位的间隔，两者相乘就是 DPS。
	_stat_labels["attack"].text = "%.0f" % ship.weapon_damage
	_stat_labels["interval"].text = "%.2fs" % ship.weapon_cycle
	_stat_labels["range"].text = T.t("DOSSIER_RANGE", "%d 格") % ship.range_cells
	_stat_labels["speed"].text = T.t("DOSSIER_SPEED", "%.2f 格/s") % ship.speed_cells
	_stat_labels["sig"].text = "%d m" % int(_extra_stat(CIDS.X_SIGNATURE, 0.0))
	_stat_labels["class"].text = ship.class_name_cn()

	_role_label.text = T.t("DOSSIER_ROLE", "定位　%s%s") % [
		ship.role_label(),
		(T.t("DOSSIER_LOGI", "（后勤）") if ship.is_logistics else "")]

	_refresh_traits()
	_refresh_live()


func _extra_stat(key: String, fallback: float) -> float:
	if ship._extra.has(key):
		return float(ship._extra[key])
	return fallback


## 羁绊三行：显示「这艘船的归属 + 该归属在舰队里的计数」
##
## 计数用的是【场上舰队】，不是只这艘船 —— 所以档位由 hud_root 喂进来。
var _fleet: Array = []


func set_fleet(ships: Array) -> void:
	_fleet = ships
	if ship != null:
		_refresh_traits()


func _refresh_traits() -> void:
	for row in _trait_rows:
		var group: StringName = row["group"]
		# ⚠️ 显式标注 String：三元表达式的两个分支类型不同（String / String 字面量）
		#    时 GDScript 会退回 Variant，用 := 推断会报错。
		var mine: String = EveTraitTable.group_of_ship(ship, group) if ship != null else ""
		var chip: ColorRect = row["chip"]
		var nm: Label = row["name"]
		var ratio: Label = row["ratio"]
		var state: Label = row["state"]

		if mine.is_empty():
			chip.color = Color(0.30, 0.36, 0.40)
			nm.text = "—"
			ratio.text = "0/%d" % EveTraitTable.max_tier(group)
			state.text = ""
			row["row"].tooltip_text = ""
			continue

		var counts := EveTraitTable.count(_fleet, group)
		var n := int(counts.get(mine, 0))
		var full := EveTraitTable.max_tier(group)
		var active := EveTraitTable.is_active(group, n)

		chip.color = _trait_color(group, mine)
		# ★ i18n：显示名走取词；`mine` 仍是**逻辑键**（`count()` / `_trait_color()` 都按它查）。
		nm.text = TERMS.trait_member(group, mine)
		ratio.text = "%d/%d" % [n, full]
		# ★ 2026-10-25（A 方案）：计数只算【场上】，玩家会问「我明明有这艘船为什么是 0」
		#   ⇒ tooltip 列出真正在贡献的舰船；本舰不在场上时再补一句，明说它没被算进去。
		# ⚠️ 文案**不走 `T.t`** —— i18n 处于冻结期（`EveText` 顶注：
		#    「⛔ 不要再往 strings.csv 加 key」），这里直接用中文源文。
		var names: Array[String] = []
		for s in _fleet:
			if EveTraitTable.group_of_ship(s, group) == mine:
				names.append(String(s.ship_name))
		var tip := "场上暂无同系舰船" if names.is_empty() \
				else "场上计入：%s" % "、".join(names)
		if not _fleet.has(ship):
			tip += "\n（本舰未上场，不计入）"
		var row_box: Control = row["row"]
		row_box.tooltip_text = tip
		if active:
			state.text = T.t("DOSSIER_TRAIT_ACTIVE", "已生效")
			state.add_theme_color_override("font_color", C_OK)
		else:
			state.text = T.t("DOSSIER_TRAIT_AWAY", "差 %d 档") % _tiers_away(group, n)
			state.add_theme_color_override("font_color", C_TEXT_FAINT)


static func _trait_color(group: StringName, member: String) -> Color:
	for m in EveTraitTable.members(group):
		if String(m["name"]) == member:
			return m["color"]
	return C_TEXT_DIM


static func _tiers_away(group: StringName, n: int) -> int:
	for g in EveTraitTable.GROUPS:
		if g["key"] == group:
			var t: Array = g["tiers"]
			for tier in t:
				if n < int(tier):
					return int(tier) - n
	return 0


## 每帧刷新会变的东西（血条）
func _process(_delta: float) -> void:
	if ship == null or not _built or not is_visible_in_tree():
		return
	_refresh_live()


func _refresh_live() -> void:
	if ship == null:
		return
	for key in ["shield", "armor", "hull"]:
		var bar: ProgressBar = _bars[key]
		var num: Label = _hp_labels[key]
		var mx: float = maxf(1.0, ship.max_hp[StringName(key)])
		bar.max_value = mx
		bar.value = ship.hp[StringName(key)]
		num.text = "%d" % int(ship.hp[StringName(key)])


# ------------------------------------------------------------------ 立绘

## 官方渲染立绘 + 全息格栅底。缺图时退回程序化侧影（不会留空框）。
##
## 底（深色 + 格栅 + 1px 内框）是【档案窗的视觉语言】，无论有没有贴图都画；
## 船体贴图叠在底之上，所以立体感来自「真实舰体 + 舱室格栅」的层叠。
## 资源与命名见 EveShipArt。
class _Portrait extends Control:
	var ship: EveShip = null
	var _tex: Texture2D = null

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0.028, 0.038, 0.046, 0.95))
		draw_rect(Rect2(Vector2(0.5, 0.5), size - Vector2(1, 1)),
				Color(0.42, 0.55, 0.60, 0.30), false, 1.0)

		# 底纹
		var col := Color(0.42, 0.55, 0.60, 0.10)
		var x := 0.0
		while x < size.x:
			draw_line(Vector2(x, 0), Vector2(x, size.y), col, 1.0)
			x += 12.0

		if ship == null:
			return
		if _tex == null:
			_tex = EveShipArt.portrait(ship.ship_key)
		if _tex != null:
			EveShipArt.draw_ship(self, r, ship.ship_key)
			return
		var cx := size.x * 0.5
		var cy := size.y * 0.5
		var fc := ship.faction_color()
		var c := Color(fc.r, fc.g, fc.b, 0.85)
		var dim := Color(fc.r, fc.g, fc.b, 0.35)
		# 侧视舰影：细长梭形，舰首在右
		var L := clampf(26.0 + float(ship.cost) * 7.0, 26.0, size.x * 0.80)
		var T := clampf(3.0 + float(ship.cost) * 1.4, 3.0, 11.0)
		var hull := PackedVector2Array([
			Vector2(cx - L * 0.50, cy),
			Vector2(cx - L * 0.22, cy - T * 0.60),
			Vector2(cx + L * 0.16, cy - T * 0.85),
			Vector2(cx + L * 0.50, cy),
			Vector2(cx + L * 0.16, cy + T * 0.85),
			Vector2(cx - L * 0.22, cy + T * 0.60),
			Vector2(cx - L * 0.50, cy),
		])
		draw_polyline(hull, c, 1.4, true)
		# 舰桥
		draw_line(Vector2(cx - L * 0.10, cy - T * 0.50),
				Vector2(cx - L * 0.10, cy - T * 0.50 - 5.0), c, 1.3)
		draw_line(Vector2(cx + L * 0.06, cy - T * 0.50),
				Vector2(cx + L * 0.06, cy - T * 0.50 - 3.5), c, 1.3)
		# 引擎尾焰
		draw_line(Vector2(cx - L * 0.50, cy),
				Vector2(cx - L * 0.50 - 6.0, cy), dim, 2.2)
