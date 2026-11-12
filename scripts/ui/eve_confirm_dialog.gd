extends Control
class_name EveConfirmDialog

## EVE 自走棋 —— 模态确认框（与 `EveWindow` 同一套窗口语言）
##
## ══════════════════════════════════════════════════════════════════
##  它取代了什么 / 为什么必须自己造
## ══════════════════════════════════════════════════════════════════
##  在它出现之前，「放弃打捞」的二次确认用的是 Godot 内置
##  `ConfirmationDialog.popup_centered()` —— 用户原话：「给我丑哭了，
##  至少和其他窗口对齐一下 ui 设计啊」。
##
##  根因不是配色没调，而是**它是原生 OS 窗口**：系统标题栏、系统字体度量、
##  系统按钮配色，在 `gui_embed_subwindows = false`（默认）下就是一个真正的
##  桌面窗口。这些部分换皮换不掉 ⇒ 只能自己造。
##
##  ── 形态：与 EveWindow 逐项对齐（改 EveWindow 时要同步这里）────────
##    面板底    沿用 `EveWindow.C_PANEL_SOLID`（实底，弹窗不该透出战场）
##    边框       1px `EveWindow.C_BORDER`
##    标题栏     高 `EveWindow.HEADER_H`（26），底 `C_TITLE_BG` + 底边 1px 分隔线，
##               左角 2×12 竖线，右端一枚自绘「✕」（hover 转暖红，与
##               `EveWindow._draw_close_btn` 同一只手感）
##    按钮       `EveButtonTheme`：取消 "hud" / 确定 "hud_warn"（橙 = 破坏性操作）
##    压暗       全屏 scrim `rgba(2,3,4,.45)`，与暂停遮罩同色同手法
##
##  ── 三个实现要点（每条都是踩过的坑）──────────────────────────────
##  ① **Control 而不是 Window**：Window 会变成真正的 OS 窗口（上面说的根因），
##     而且会被父容器（PanelContainer）拉成整块矩形 —— `EveWindow` 的缩放把手
##     踩过同一个坑（见那里 300 字注释）。
##  ② **`process_mode = ALWAYS`**：结算页弹出时树可能处于暂停态
##     （`set_paused()` 是全局暂停）⇒ 继承态节点收不到输入，
##     症状是「按钮看着能点、点了没反应」。
##  ③ **⛔ 不开 autowrap**：本工程踩过「autowrap Label 进容器 ⇒ 容器给它的
##     最小宽度塌成一个字宽 ⇒ 折成一列竖排 ⇒ 高度炸弹」（`eve_result.gd`
##     打捞区有同款红字，实测同一 Label 布局前后 14 → 958）。
##     本框文案自带 `\n` 断行且每行都短，单行显示即可。
##
##  ⚠️ 它必须挂在 **EveResult 的父节点**（HUD 根，一个 Control）上，
##     ⛔ 不能 `add_child` 到 EveWindow 自己身上 —— 见 ①。

const FONT := preload("res://scripts/ui/eve_font.gd")
const T := preload("res://scripts/core/eve_text.gd")

## 卡片尺寸。宽度 400 沿用旧原生弹窗的 `popup_centered(400×176)`；
## 高度 120 是下限（标题栏 26 + 上距 10 + 两行文案 ~34 + 间距 12 + 按钮 28 + 下距 10）。
const CARD_MIN := Vector2(400, 120)

signal confirmed()   ## 点了「确定」—— 破坏性动作真的执行
signal cancelled()   ## 点了「取消 / ✕ / 遮罩」—— 什么都不做，只收起

var dialog_title: String = "":
	set(v):
		dialog_title = v
		if _title_lb != null:
			_title_lb.text = v

var message: String = "":
	set(v):
		message = v
		if _msg_lb != null:
			_msg_lb.text = v

var ok_text: String = "确定":
	set(v):
		ok_text = v
		if _ok_btn != null:
			_ok_btn.text = v

var cancel_text: String = "取消":
	set(v):
		cancel_text = v
		if _cancel_btn != null:
			_cancel_btn.text = v

var _title_lb: Label
var _msg_lb: Label
var _ok_btn: Button
var _cancel_btn: Button
var _close_btn: Control
var _close_hot := false


func _ready() -> void:
	# ② 暂停态也要能点（结算页可能在全局暂停中弹出）
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	# 点遮罩（卡片外）= 取消。卡片自己是 PanelContainer（STOP），
	# 点它内部的事件到不了这里，⛔ 不会误触「点哪都取消」。
	gui_input.connect(_on_root_input)
	_build()


# ══════════════════════════════════════════════════════════════════
#  构建
# ══════════════════════════════════════════════════════════════════

func _build() -> void:
	# ── ① 全屏压暗（与 `EveHudRoot._build_pause_veil()` 同一手法）──
	var dim := ColorRect.new()
	dim.name = "Scrim"
	dim.color = Color(0.02, 0.03, 0.04, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	# ── ② 居中容器（⛔ 不做锚点算术：CenterContainer 是工程里验证过的做法）──
	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	# ── ③ 卡片：EveWindow 同款面板 ──
	var card := PanelContainer.new()
	card.name = "Card"
	card.custom_minimum_size = CARD_MIN
	var sb := StyleBoxFlat.new()
	sb.bg_color = EveWindow.C_PANEL_SOLID
	sb.border_color = EveWindow.C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 0
	sb.content_margin_right = 0
	sb.content_margin_top = 0
	sb.content_margin_bottom = 0
	card.add_theme_stylebox_override("panel", sb)
	center.add_child(card)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	card.add_child(root)
	root.add_child(_build_title_bar())
	root.add_child(_build_body())


## 标题栏：`EveWindow._build_header()` 的模态版（无状态小字 / 无收起钮）。
func _build_title_bar() -> Control:
	var bar := PanelContainer.new()
	bar.name = "TitleBar"
	bar.custom_minimum_size = Vector2(0, EveWindow.HEADER_H)
	var hsb := StyleBoxFlat.new()
	hsb.bg_color = EveWindow.C_TITLE_BG
	hsb.border_color = EveWindow.C_BORDER
	hsb.border_width_bottom = 1
	hsb.content_margin_left = 7
	hsb.content_margin_right = 7
	bar.add_theme_stylebox_override("panel", hsb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	bar.add_child(row)

	# 左角 2×12 竖线 —— EVE 式角标（与 EveWindow 同色同尺寸）
	var tick := ColorRect.new()
	tick.color = Color(0.45, 0.62, 0.68, 0.55)
	tick.custom_minimum_size = Vector2(2, 12)
	tick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(tick)

	_title_lb = Label.new()
	_title_lb.text = dialog_title
	_title_lb.add_theme_color_override("font_color", EveWindow.C_TEXT)
	FONT.fs(_title_lb, 12)
	_title_lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_title_lb)

	# ✕ = 取消。⛔ 不用文字 Button：那个皮肤带边框，塞标题栏里是个难看的方框
	#    （EveWindow 收起/关闭钮一律自绘，红线：HUD 图标只许几何/自绘线条）。
	_close_btn = Control.new()
	_close_btn.name = "CloseBtn"
	_close_btn.custom_minimum_size = Vector2(20, 18)
	_close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_close_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_close_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	_close_btn.tooltip_text = T.t(&"WINDOW_CLOSE", "关闭")
	_close_btn.draw.connect(_draw_close_btn)
	_close_btn.gui_input.connect(_on_close_input)
	_close_btn.mouse_entered.connect(func() -> void:
		_close_hot = true
		if _close_btn != null:
			_close_btn.queue_redraw())
	_close_btn.mouse_exited.connect(func() -> void:
		_close_hot = false
		if _close_btn != null:
			_close_btn.queue_redraw())
	row.add_child(_close_btn)
	return bar


## 主体：文案 + 两个按钮（取消左 / 确定右，与结算页按钮同一高度 28）。
func _build_body() -> Control:
	var pad := MarginContainer.new()
	pad.name = "Body"
	pad.add_theme_constant_override("margin_left", 12)
	pad.add_theme_constant_override("margin_right", 12)
	pad.add_theme_constant_override("margin_top", 10)
	pad.add_theme_constant_override("margin_bottom", 10)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	pad.add_child(box)

	_msg_lb = Label.new()
	_msg_lb.name = "Message"
	_msg_lb.text = message
	FONT.fs(_msg_lb, 12)
	_msg_lb.add_theme_color_override("font_color", EveWindow.C_TEXT)
	_msg_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_msg_lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_msg_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_msg_lb.autowrap_mode = TextServer.AUTOWRAP_OFF     # ③ 见文件顶注
	box.add_child(_msg_lb)

	var acts := HBoxContainer.new()
	acts.name = "Actions"
	acts.add_theme_constant_override("separation", 8)
	acts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(acts)

	_cancel_btn = Button.new()
	_cancel_btn.name = "Cancel"
	_cancel_btn.text = cancel_text
	_cancel_btn.custom_minimum_size = Vector2(0, 28)
	_cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cancel_btn.focus_mode = Control.FOCUS_ALL
	EveButtonTheme.apply(_cancel_btn, "hud")
	_cancel_btn.pressed.connect(_on_cancel_pressed)
	acts.add_child(_cancel_btn)

	_ok_btn = Button.new()
	_ok_btn.name = "Ok"
	_ok_btn.text = ok_text
	_ok_btn.custom_minimum_size = Vector2(0, 28)
	_ok_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ok_btn.focus_mode = Control.FOCUS_ALL
	EveButtonTheme.apply(_ok_btn, "hud_warn")
	_ok_btn.pressed.connect(_on_ok_pressed)
	acts.add_child(_ok_btn)
	return pad


## 「✕」自绘：常态冷灰融进标题栏，hover 转暖红（关闭 = 破坏性动作，颜色给预兆）。
## 与 `EveWindow._draw_close_btn()` 同一组参数 —— 两处必须看起来一模一样。
func _draw_close_btn() -> void:
	if _close_btn == null:
		return
	var c := _close_btn.size * 0.5
	var col := Color(1.00, 0.70, 0.66, 0.98) if _close_hot \
			else Color(0.62, 0.71, 0.75, 0.82)
	var r := 3.6
	_close_btn.draw_line(c + Vector2(-r, -r), c + Vector2(r, r), col, 1.6)
	_close_btn.draw_line(c + Vector2(r, -r), c + Vector2(-r, r), col, 1.6)


# ══════════════════════════════════════════════════════════════════
#  对外 API
# ══════════════════════════════════════════════════════════════════

## 一次性把四个文案位设好（打开前调）。
func setup(p_title: String, p_message: String, p_ok: String, p_cancel: String) -> void:
	dialog_title = p_title
	message = p_message
	ok_text = p_ok
	cancel_text = p_cancel


## 是否开着（AI 操作面 / 自检用）。
func is_open() -> bool:
	return visible


## 点「确定」。⛔ 别直接 emit confirmed() —— close_dialog 也得走，
## 否则 scrim 会留在屏幕上继续吃点击（eve_result 的 _notification 只兜 visible 变化）。
func confirm() -> void:
	if visible:
		_on_ok_pressed()


## 点「取消 / ✕」。
func cancel() -> void:
	if visible:
		_on_cancel_pressed()


func open_dialog() -> void:
	visible = true
	EveUiAudio.play("window.open")
	# HUD 根上它加得比暂停遮罩/拖动幽灵早 ⇒ 不提最前会被遮罩压住
	move_to_front()
	# ⚠️ 焦点给「取消」而不是「确定」：scrim 挡鼠标但不挡键盘，
	#    焦点留在结算页的「继续」上时，按空格会再次触发开弹窗的同一个按钮。
	#    破坏性确认的默认答案必须是「不」。
	if _cancel_btn != null:
		_cancel_btn.grab_focus()


func close_dialog() -> void:
	visible = false


# ══════════════════════════════════════════════════════════════════
#  交互
# ══════════════════════════════════════════════════════════════════

func _on_ok_pressed() -> void:
	EveUiAudio.play("ui.confirm")
	close_dialog()
	confirmed.emit()


func _on_cancel_pressed() -> void:
	EveUiAudio.play("ui.cancel")
	close_dialog()
	cancelled.emit()


func _on_close_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_on_cancel_pressed()
		accept_event()          # ⛔ 别让点击继续往下传（同 EveWindow 的关闭钮）


func _on_root_input(event: InputEvent) -> void:
	# 点到卡片外（scrim 区域）= 取消。卡片与其子控件自己会 STOP 事件，
	# 所以能走到这里的一定是弹窗之外的点击。
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_on_cancel_pressed()
