extends Control

## EVE 自走棋 —— 热更新面板（四态：询问 / 下载中 / 已就绪 / 失败）
##
## ══════════════════════════════════════════════════════════════════
##  为什么需要它（而不是复用 EveConfirmDialog）
## ══════════════════════════════════════════════════════════════════
##  `EveConfirmDialog` 只有「文案 + 两按钮」，**没有进度条**。
##  而「下载 1.1 MB」这件事如果不给条，玩家看到的就是一个卡住的窗口
##  —— 用户 2026-11-07 原话：「整一个下载进度条」。
##
##  所以这里沿用它的**视觉语言**（同一套 StyleBox / 标题栏 / 按钮皮肤），
##  但把主体换成「版本对比行 + 进度条 + 明细行 + 按钮行」。
##
##  ── 四态（用 `set_mode()` 切，不要 new 第二个面板）────────────────
##    ASK      当前 V35 → V41 · 1.12 MB    [稍后] [现在更新]
##    PROGRESS  ▓▓▓▓▓▓░░░░ 43%             [后台继续]
##              1.1 / 1.12 MB · 约 3 秒
##    READY    已就绪，重启后生效           [稍后重启] [立即重启]
##    ERROR    下载失败（网络）             [关闭] [重试]
##
##  ── 三个实现要点 ─────────────────────────────────────────────────
##  ① **Control 而非 Window**：系统窗口换不掉皮（见 `eve_confirm_dialog.gd`
##     文件顶注 ①）。它必须挂在**主菜单根节点**（铺满视口），不是 `_content`。
##  ② **`process_mode = ALWAYS`**：主菜单可能处于暂停态（Esc 菜单），
##     继承态收不到输入，症状是「按钮看着能点、点了没反应」。
##  ③ **文案行 ⛔ 不开 autowrap**：本工程踩过「autowrap Label 进容器 ⇒
##     最小宽度塌成一个字宽 ⇒ 折成竖排 ⇒ 高度炸弹」（14 → 958 px）。
##     本面板每行文案都短、且自带 `\n`，单行显示即可。

const FONT := preload("res://scripts/ui/eve_font.gd")

enum Mode { ASK, PROGRESS, READY, ERROR }

## 卡片宽度。比 `EveConfirmDialog` 的 400 宽一点：要放「V0.14.10.5.35 → V0.14.10.5.41」
## 这种长版本号（20 个字符），400 会挤。
const CARD_W := 460
## 进度条高度。不做圆角、不做渐变 —— 与 HUD 的「细线 + 平直」语言一致。
const BAR_H := 8

## 询问态点了「现在更新」
signal accepted()
## 询问态点了「稍后」（或 ✕）
signal dismissed()
## 就绪态点了「立即重启」
signal restart_now()
## 失败态点了「重试」
signal retry_requested()

var _mode: int = Mode.ASK

var _title_lb: Label
var _cur_lb: Label
var _new_lb: Label
var _bar: ProgressBar
var _pct_lb: Label
var _detail_lb: Label
var _btn_primary: Button
var _btn_secondary: Button
var _close_btn: Control
var _close_hot := false


func _ready() -> void:
	# ② 暂停态也要能点
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	gui_input.connect(_on_root_input)
	_build()


# ══════════════════════════════════════════════════════════════════
#  构建（视觉与 `EveConfirmDialog` 逐项对齐，改那边要同步这边）
# ══════════════════════════════════════════════════════════════════

func _build() -> void:
	# ── 全屏压暗（与 `EveHudRoot._build_pause_veil()` 同色同手法）──
	var dim := ColorRect.new()
	dim.name = "Scrim"
	dim.color = Color(0.02, 0.03, 0.04, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var card := PanelContainer.new()
	card.name = "Card"
	card.custom_minimum_size = Vector2(CARD_W, 0)
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

	# 左角 2×12 竖线（EVE 式角标，与 EveWindow 同色同尺寸）
	var tick := ColorRect.new()
	tick.color = Color(0.45, 0.62, 0.68, 0.55)
	tick.custom_minimum_size = Vector2(2, 12)
	tick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(tick)

	_title_lb = Label.new()
	_title_lb.text = "游戏更新"
	_title_lb.add_theme_color_override("font_color", EveWindow.C_TEXT)
	FONT.fs(_title_lb, 12)
	_title_lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_title_lb)

	_close_btn = Control.new()
	_close_btn.name = "CloseBtn"
	_close_btn.custom_minimum_size = Vector2(20, 18)
	_close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_close_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_close_btn.mouse_filter = Control.MOUSE_FILTER_STOP
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


func _build_body() -> Control:
	var pad := MarginContainer.new()
	pad.name = "Body"
	pad.add_theme_constant_override("margin_left", 14)
	pad.add_theme_constant_override("margin_right", 14)
	pad.add_theme_constant_override("margin_top", 12)
	pad.add_theme_constant_override("margin_bottom", 12)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	pad.add_child(box)

	# ── 版本对比（两行左对齐：标签列固定宽度，值列自适应）──
	box.add_child(_build_kv_row("当前版本", func(lb: Label) -> void: _cur_lb = lb))
	box.add_child(_build_kv_row("最新版本", func(lb: Label) -> void: _new_lb = lb))

	# ── 进度条（PROGRESS 态才显示）──
	_bar = ProgressBar.new()
	_bar.name = "Bar"
	_bar.custom_minimum_size = Vector2(0, BAR_H)
	_bar.min_value = 0.0
	_bar.max_value = 100.0
	_bar.value = 0.0
	_bar.show_percentage = false
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ⚠️ `ProgressBar` 的两个样式槽名就叫 "background" / "fill"（不是 StyleBox 前缀），
	#    写错名字不报错、只是不生效 —— 这条踩过。
	var bbg := StyleBoxFlat.new()
	bbg.bg_color = Color(0.09, 0.12, 0.14, 1.0)
	bbg.border_color = Color(0.20, 0.28, 0.32, 0.9)
	bbg.set_border_width_all(1)
	bbg.set_corner_radius_all(0)
	_bar.add_theme_stylebox_override("background", bbg)
	var bfg := StyleBoxFlat.new()
	bfg.bg_color = Color(0.36, 0.68, 0.74, 1.0)
	bfg.set_corner_radius_all(0)
	_bar.add_theme_stylebox_override("fill", bfg)
	box.add_child(_bar)

	_pct_lb = Label.new()
	_pct_lb.text = "0%"
	FONT.fs(_pct_lb, 12)
	_pct_lb.add_theme_color_override("font_color", Color(0.62, 0.82, 0.86, 0.95))
	_pct_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pct_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pct_lb.autowrap_mode = TextServer.AUTOWRAP_OFF     # ③ 见文件顶注
	box.add_child(_pct_lb)

	_detail_lb = Label.new()
	_detail_lb.text = ""
	FONT.fs(_detail_lb, 11)
	_detail_lb.add_theme_color_override("font_color", Color(0.55, 0.65, 0.70, 0.90))
	_detail_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_lb.autowrap_mode = TextServer.AUTOWRAP_OFF
	box.add_child(_detail_lb)

	# ── 按钮行（右对齐：次要左、主要右，与 EveConfirmDialog 一致）──
	var acts := HBoxContainer.new()
	acts.name = "Actions"
	acts.add_theme_constant_override("separation", 8)
	acts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(acts)

	_btn_secondary = Button.new()
	_btn_secondary.name = "Secondary"
	_btn_secondary.text = "稍后"
	_btn_secondary.custom_minimum_size = Vector2(0, 28)
	_btn_secondary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	EveButtonTheme.apply(_btn_secondary, "hud")
	_btn_secondary.pressed.connect(_on_secondary_pressed)
	acts.add_child(_btn_secondary)

	_btn_primary = Button.new()
	_btn_primary.name = "Primary"
	_btn_primary.text = "现在更新"
	_btn_primary.custom_minimum_size = Vector2(0, 28)
	_btn_primary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	EveButtonTheme.apply(_btn_primary, "hud_warn")
	_btn_primary.pressed.connect(_on_primary_pressed)
	acts.add_child(_btn_primary)

	return pad


## 一行「标签 : 值」。标签固定 72 宽（4 个汉字），值 `EXPAND_FILL`。
## [WHY] 用 HBox + 两个 Label 而不是 `Label` 拼空格：中英混排下空格宽度不可控，
##       长版本号会顶到标签上。
func _build_kv_row(tag: String, bind: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var k := Label.new()
	k.text = tag
	k.custom_minimum_size = Vector2(72, 0)
	FONT.fs(k, 11)
	k.add_theme_color_override("font_color", Color(0.52, 0.62, 0.67, 0.90))
	k.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(k)

	var v := Label.new()
	v.text = "—"
	FONT.fs(v, 12)
	v.add_theme_color_override("font_color", EveWindow.C_TEXT)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.autowrap_mode = TextServer.AUTOWRAP_OFF
	row.add_child(v)
	bind.call(v)
	return row


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

## 询问态：有新版，问要不要下。
func show_ask(cur: String, new_ver: String, size_mb: float) -> void:
	_cur_lb.text = "V" + cur
	_new_lb.text = "V%s · %s" % [new_ver, _size_text(size_mb)]
	_title_lb.text = "发现新版本"
	set_mode(Mode.ASK)
	open()


## 进度态。`allow_dismiss` = 是否给「后台继续」（老客户端由 EveUpdater 自己在下，
## 面板只是观察者，答不 answering 都不影响下载 ⇒ 才允许收起）。
func show_progress(cur: String, new_ver: String, allow_dismiss: bool) -> void:
	_cur_lb.text = "V" + cur
	_new_lb.text = "V" + new_ver
	_title_lb.text = "正在下载更新"
	_btn_secondary.visible = allow_dismiss
	set_mode(Mode.PROGRESS)
	open()


func set_progress(pct: float, done: int, total: int) -> void:
	var p := clampf(pct, 0.0, 1.0)
	_bar.value = p * 100.0
	_pct_lb.text = "%d%%" % int(round(p * 100.0))
	if total > 0:
		_detail_lb.text = "%s / %s" % [_bytes_text(done), _bytes_text(total)]
	else:
		_detail_lb.text = _bytes_text(done)


func show_ready(ver: String) -> void:
	_title_lb.text = "更新已就绪"
	_new_lb.text = "V" + ver
	_detail_lb.text = "重启游戏后生效"
	set_mode(Mode.READY)
	open()


func show_error(msg: String, cur: String, new_ver: String) -> void:
	_cur_lb.text = "V" + cur
	_new_lb.text = "V" + new_ver
	_title_lb.text = "更新失败"
	_detail_lb.text = msg
	set_mode(Mode.ERROR)
	open()


func set_mode(m: int) -> void:
	_mode = m
	_bar.visible = m == Mode.PROGRESS
	_pct_lb.visible = m == Mode.PROGRESS
	_detail_lb.visible = m == Mode.PROGRESS or m == Mode.READY or m == Mode.ERROR
	match m:
		Mode.ASK:
			_btn_secondary.text = "稍后"
			_btn_secondary.visible = true
			_btn_primary.text = "现在更新"
		Mode.PROGRESS:
			_btn_secondary.text = "后台继续"
			_btn_primary.text = "完成"
			# 进度态的主按钮没意义（还没下完），先按「收起面板」
			_btn_primary.visible = false
		Mode.READY:
			_btn_secondary.text = "稍后重启"
			_btn_secondary.visible = true
			_btn_primary.text = "立即重启"
			_btn_primary.visible = true
		Mode.ERROR:
			_btn_secondary.text = "关闭"
			_btn_secondary.visible = true
			_btn_primary.text = "重试"
			_btn_primary.visible = true


func is_open() -> bool:
	return visible


func open() -> void:
	visible = true
	move_to_front()
	# ⚠️ 焦点给「次要」：默认答案必须是「先别动」（同 EveConfirmDialog 的理由）。
	if _btn_secondary.visible:
		_btn_secondary.grab_focus()
	elif _btn_primary.visible:
		_btn_primary.grab_focus()


func close() -> void:
	visible = false


# ══════════════════════════════════════════════════════════════════
#  交互
# ══════════════════════════════════════════════════════════════════

func _on_primary_pressed() -> void:
	match _mode:
		Mode.ASK:
			accepted.emit()
		Mode.READY:
			restart_now.emit()
		Mode.ERROR:
			retry_requested.emit()


func _on_secondary_pressed() -> void:
	match _mode:
		Mode.ASK:
			close()
			dismissed.emit()
		Mode.PROGRESS:
			# 只是收起面板，下载继续（进度看右下角那行小字，见 EveUpdater.status_text）
			close()
		Mode.READY:
			close()
		Mode.ERROR:
			close()


func _on_close_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_on_secondary_pressed()
		accept_event()


func _on_root_input(event: InputEvent) -> void:
	# 点卡片外。⚠️ 下载中**不响应**：玩家手滑点空白就把进度条点没了，
	# 会以为「更新被取消了」。只有 ASK / READY / ERROR 允许点外关闭。
	if _mode == Mode.PROGRESS:
		return
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_on_secondary_pressed()


static func _size_text(mb: float) -> String:
	if mb <= 0.0:
		return "体积未知"
	return "%.2f MB" % mb


static func _bytes_text(b: int) -> String:
	if b >= 1048576:
		return "%.2f MB" % (float(b) / 1048576.0)
	if b >= 1024:
		return "%d KB" % int(b / 1024)
	return "%d B" % b
