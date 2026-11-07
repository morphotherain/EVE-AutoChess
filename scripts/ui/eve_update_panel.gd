extends Control

## EVE 自走棋 —— 开屏更新页（四态：询问 / 下载中 / 已就绪 / 失败）
##
## ══════════════════════════════════════════════════════════════════
##  为什么是**全屏开屏页**，不是一张居中卡片
## ══════════════════════════════════════════════════════════════════
##  2026-11-07 第一版做的是 460 宽居中卡片 + 半透明压暗（沿用 `EveConfirmDialog`
##  的皮肤）。用户看过之后否掉了：
##      「加一个检测更新的大弹窗……而不是现在在右下角一点小字，
##        做成完全开屏显示都行」
##
##  [WHY] 判断没错，而且是有道理的：卡片式弹窗在视觉上等于「主菜单上的一个浮层」，
##        玩家会当成可以无视的提示；而「要不要更新」是一次**需要玩家负责的选择**
##        —— 它应该占据整屏、把主菜单完全挡在身后。
##  ⇒ 本文件改成：**不透明全屏底 + 居中内容区 + 大字号 + 大按钮**。
##        玩家关掉它之前，主菜单既看不见也点不到（`MOUSE_FILTER_STOP` 铺满视口）。
##
##  ── 与卡片版的三处行为差异（都是有意的）────────────────────────
##  ① **没有右上角 ✕，也不能点空白关闭**。全屏页上每一点都是「空白」，
##     点一下就关等于玩家还没看清就把选择取消了。要离开只能点按钮。
##  ② **下载中不给任何关闭入口**。以前给了「后台继续」，收起后进度只剩右下角
##     一行小字 —— 那正是用户抱怨的东西。现在下载就停在页面上，几秒的事。
##  ③ **`稍后` 仍然是安全默认**（获得焦点）：回车 / 手柄确认不会误触发下载。
##
##  ── 三个实现要点 ─────────────────────────────────────────────────
##  ⚠️ `Control` 而非 `Window`：系统窗口换不掉皮（见 `eve_confirm_dialog.gd` 顶注 ①）。
##     必须挂在**主菜单根节点**（铺满视口），⛔ 不是 `_content`。
##  ⚠️ `process_mode = ALWAYS`：主菜单可能处于暂停态（Esc 菜单），
##     继承态收不到输入，症状是「按钮看着能点、点了没反应」。
##  ⚠️ 文案行 ⛔ 不开 autowrap：本工程踩过「autowrap Label 进容器 ⇒
##     最小宽度塌成一个字宽 ⇒ 折成竖排 ⇒ 高度炸弹」（14 → 958 px）。

const FONT := preload("res://scripts/ui/eve_font.gd")

enum Mode { ASK, PROGRESS, READY, ERROR }

## 内容区宽度。
## [WHY] 620 是「长版本号两侧还能留白」的下限，但在 1920 宽的视口里只占 32%，
##       读起来仍像一块卡片 —— 用户要的是「大弹窗 / 开屏」，所以放到 760。
##       ⚠️ 不能再大：手机竖屏的逻辑视口窄，760 以上会顶满到边。
const CONTENT_W := 760
## 进度条高度。开屏页上可以比 HUD 粗一点 —— 这里它就是视觉重心。
const BAR_H := 14
## 主按钮高度。手机竖屏下 44 是拇指可靠命中的下限，开屏页给到 64。
const BTN_H := 64

signal accepted()
signal dismissed()
signal restart_now()
signal retry_requested()

var _mode: int = Mode.ASK

var _eyebrow_lb: Label
var _title_lb: Label
var _sub_lb: Label
var _cur_lb: Label
var _new_lb: Label
## 「当前版本」整行（含它上面的分隔线）。READY 态要藏起来，见 `set_mode`。
var _cur_row: Control
var _cur_hr: Control
var _bar: ProgressBar
var _pct_lb: Label
var _detail_lb: Label
var _btn_primary: Button
var _btn_secondary: Button


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build()


# ══════════════════════════════════════════════════════════════════
#  构建
# ══════════════════════════════════════════════════════════════════

func _build() -> void:
	# ── 不透明全屏底：主菜单在它后面彻底不可见 ──
	# [WHY] 不用半透明：半透明会让人读成「浮层」，而不透明读成「换了个界面」。
	#       用户要的是后者。
	var bg := ColorRect.new()
	bg.name = "Backdrop"
	bg.color = Color(0.028, 0.038, 0.046, 1.0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# ── 居中容器 ──
	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var col := VBoxContainer.new()
	col.name = "Column"
	col.custom_minimum_size = Vector2(CONTENT_W, 0)
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(col)

	col.add_child(_build_header())
	col.add_child(_spacer(34))
	col.add_child(_build_info())
	col.add_child(_spacer(26))
	col.add_child(_build_progress())
	col.add_child(_build_actions())


## 「品牌小字 + 大标题 + 一句说明」。三行共同承担「这是一件需要你决定的事」。
func _build_header() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var mark := HBoxContainer.new()
	mark.add_theme_constant_override("separation", 8)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 2×16 竖线角标（与 `EveWindow` 标题栏同色同手法）
	var tick := ColorRect.new()
	tick.color = Color(0.45, 0.62, 0.68, 0.75)
	tick.custom_minimum_size = Vector2(2, 16)
	tick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.add_child(tick)

	_eyebrow_lb = Label.new()
	_eyebrow_lb.text = "EVE 自走棋 · 启动检查"
	FONT.fs(_eyebrow_lb, 14)
	_eyebrow_lb.add_theme_color_override("font_color", Color(0.48, 0.60, 0.66, 0.95))
	_eyebrow_lb.autowrap_mode = TextServer.AUTOWRAP_OFF
	_eyebrow_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.add_child(_eyebrow_lb)
	box.add_child(mark)

	_title_lb = Label.new()
	_title_lb.text = "发现新版本"
	FONT.fs(_title_lb, 40)
	_title_lb.add_theme_color_override("font_color", Color(0.80, 0.91, 0.94, 1.0))
	_title_lb.autowrap_mode = TextServer.AUTOWRAP_OFF
	_title_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_title_lb)

	_sub_lb = Label.new()
	_sub_lb.text = ""
	FONT.fs(_sub_lb, 15)
	_sub_lb.add_theme_color_override("font_color", Color(0.52, 0.64, 0.69, 0.95))
	_sub_lb.autowrap_mode = TextServer.AUTOWRAP_OFF
	_sub_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_sub_lb)
	return box


## 三行「标签 …… 值」。用细横线隔开，读起来像一张规格表而不是对话框文案。
func _build_info() -> Control:
	var box := VBoxContainer.new()
	box.name = "Info"
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# ⚠️ 「当前版本」整行要留引用：READY 态下玩家只关心「新版本已就绪」，
	#    显示一个破折号或者旧版本号都是噪音（旧版这里就显示成了 "—"）。
	_cur_hr = _hr()
	box.add_child(_cur_hr)
	_cur_row = _build_kv_row("当前版本", func(lb: Label) -> void: _cur_lb = lb)
	box.add_child(_cur_row)
	box.add_child(_hr())
	box.add_child(_build_kv_row("最新版本", func(lb: Label) -> void: _new_lb = lb))
	box.add_child(_hr())
	return box


func _hr() -> Control:
	var line := ColorRect.new()
	line.color = Color(0.22, 0.33, 0.37, 0.55)
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


## 一行「标签 …… 值」。标签定宽 96（4 个汉字 + 余量），值右对齐。
## [WHY] 用 HBox + 两个 Label 而不是 `Label` 拼空格：中英混排下空格宽度不可控，
##       长版本号会顶到标签上。
func _build_kv_row(tag: String, bind: Callable) -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 52)
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var k := Label.new()
	k.text = tag
	k.custom_minimum_size = Vector2(110, 0)
	FONT.fs(k, 16)
	k.add_theme_color_override("font_color", Color(0.50, 0.61, 0.66, 0.95))
	k.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	k.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(k)

	var v := Label.new()
	v.text = "—"
	FONT.fs(v, 20)
	v.add_theme_color_override("font_color", EveWindow.C_TEXT)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	v.autowrap_mode = TextServer.AUTOWRAP_OFF
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(v)
	bind.call(v)
	return row


func _build_progress() -> Control:
	var box := VBoxContainer.new()
	box.name = "Progress"
	box.add_theme_constant_override("separation", 8)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

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
	bbg.bg_color = Color(0.08, 0.11, 0.13, 1.0)
	bbg.border_color = Color(0.22, 0.32, 0.36, 0.95)
	bbg.set_border_width_all(1)
	bbg.set_corner_radius_all(0)
	_bar.add_theme_stylebox_override("background", bbg)
	var bfg := StyleBoxFlat.new()
	bfg.bg_color = Color(0.40, 0.72, 0.78, 1.0)
	bfg.set_corner_radius_all(0)
	_bar.add_theme_stylebox_override("fill", bfg)
	box.add_child(_bar)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_pct_lb = Label.new()
	_pct_lb.text = "0%"
	FONT.fs(_pct_lb, 28)
	_pct_lb.add_theme_color_override("font_color", Color(0.62, 0.84, 0.88, 1.0))
	_pct_lb.autowrap_mode = TextServer.AUTOWRAP_OFF
	_pct_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_pct_lb)

	_detail_lb = Label.new()
	_detail_lb.text = ""
	_detail_lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	FONT.fs(_detail_lb, 14)
	_detail_lb.add_theme_color_override("font_color", Color(0.52, 0.63, 0.68, 0.95))
	_detail_lb.autowrap_mode = TextServer.AUTOWRAP_OFF
	_detail_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_detail_lb)
	box.add_child(row)
	return box


func _build_actions() -> Control:
	var acts := HBoxContainer.new()
	acts.name = "Actions"
	acts.add_theme_constant_override("separation", 12)
	acts.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_btn_secondary = Button.new()
	_btn_secondary.name = "Secondary"
	_btn_secondary.text = "稍后"
	_btn_secondary.custom_minimum_size = Vector2(0, BTN_H)
	_btn_secondary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	EveButtonTheme.apply(_btn_secondary, "hud")
	# ⚠️ `apply()` 内部会按皮肤设字号（hud = 11）⇒ 必须**在它之后**覆盖。
	FONT.fs(_btn_secondary, 17)
	_btn_secondary.pressed.connect(_on_secondary_pressed)
	acts.add_child(_btn_secondary)

	_btn_primary = Button.new()
	_btn_primary.name = "Primary"
	_btn_primary.text = "立即更新"
	_btn_primary.custom_minimum_size = Vector2(0, BTN_H)
	_btn_primary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	EveButtonTheme.apply(_btn_primary, "hud_warn")
	FONT.fs(_btn_primary, 17)
	_btn_primary.pressed.connect(_on_primary_pressed)
	acts.add_child(_btn_primary)
	return acts


static func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# ══════════════════════════════════════════════════════════════════
#  对外 API
# ══════════════════════════════════════════════════════════════════

## 询问态：有新版，问要不要下。
func show_ask(cur: String, new_ver: String, size_mb: float) -> void:
	_cur_lb.text = "V" + cur
	_new_lb.text = "V%s  ·  %s" % [new_ver, _size_text(size_mb)]
	_title_lb.text = "发现新版本"
	_sub_lb.text = "更新包只包含脚本与数值，不重新下载美术资源。"
	set_mode(Mode.ASK)
	open()


## 进度态。`allow_dismiss` 仅保留接口兼容 —— 开屏页上**永远不给收起**（见文件顶注 ②）。
func show_progress(cur: String, new_ver: String, _allow_dismiss: bool) -> void:
	_cur_lb.text = "V" + cur
	_new_lb.text = "V" + new_ver
	_title_lb.text = "正在更新"
	_sub_lb.text = "请不要关闭游戏，完成后会提示你重启。"
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
	_new_lb.text = "V" + ver
	_title_lb.text = "更新已就绪"
	_sub_lb.text = "新版本已经下载完成，重启游戏后生效。"
	set_mode(Mode.READY)
	open()


func show_error(msg: String, cur: String, new_ver: String) -> void:
	_cur_lb.text = "V" + cur
	_new_lb.text = "V" + new_ver
	_title_lb.text = "更新失败"
	_sub_lb.text = msg
	_detail_lb.text = ""
	set_mode(Mode.ERROR)
	open()


func set_mode(m: int) -> void:
	_mode = m
	var show_bar := m == Mode.PROGRESS
	_bar.visible = show_bar
	_pct_lb.visible = show_bar
	# `_detail_lb` 只在进度态有意义（"499 KB / 1.13 MB"）。
	# [WHY] READY / ERROR 态曾经也让它显示，结果和副标题撞在一起 ——
	#       截图里「重启后生效」吊在按钮上方右侧，看着像另一行的残片。
	_detail_lb.visible = show_bar
	# READY 态隐藏「当前版本」整行：此刻玩家只关心新版本已就绪，
	# 摆一个旧版本号（或破折号）纯属噪音。
	var show_cur := m != Mode.READY
	_cur_row.visible = show_cur
	_cur_hr.visible = show_cur
	match m:
		Mode.ASK:
			_btn_secondary.text = "稍后"
			_btn_secondary.visible = true
			_btn_primary.text = "立即更新"
			_btn_primary.visible = true
		Mode.PROGRESS:
			# 下载中两个按钮都不给：没有「取消」是因为半截包没有意义，
			# 没有「关闭」是因为那正是用户抱怨的「只剩右下角小字」。
			_btn_secondary.visible = false
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
		Mode.READY:
			close()
		Mode.ERROR:
			close()
		Mode.PROGRESS:
			pass    # 下载中不该走到这里（按钮已隐藏）


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
