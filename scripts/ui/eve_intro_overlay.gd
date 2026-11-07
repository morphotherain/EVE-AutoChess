extends Control
class_name EveIntroOverlay

## ★ 字号缩放（2026-10-07）：⛔ 别直接调 `add_theme_font_size_override`，
## 一律走 `FONT.fs(node, 设计字号)` —— 它同时记住设计字号（供改滑块时就地重算）。
## ⚠️ 子类（`extends eve_window.gd` 的那 9 个）靠**继承**拿到这个常量，
##    它们自己再写一个会撞名（基类已有同名成员 ⇒ 子类编译失败，本工程踩过）。
const FONT := preload("res://scripts/ui/eve_font.gd")

## 开场通讯的**对话层**（纯 UI，不含视频、不含 3D）。
##
## ★ 为什么要单独一层、而不是把 UI 烘进视频：
##   烘进视频的话「上一步 / 暂停 / 跳过」就只是画面上的三个方块，点不动。
##   分成两层之后，背景是 `VideoStreamPlayer`（`mouse_filter = IGNORE`，不吃事件），
##   本层是**实时绘制的 Control**，三个按钮是真 `Button`，能收鼠标、能发信号。
##
## 版面（1080 基准，全部按**屏幕底边**定位 ⇒ 窗口高度变了也不会跑）：
##   ┌──────────────────────────────────────────────┐
##   │              背景视频（另一个节点）           │
##   │░░░░░░░░░ 顶边 90px 渐隐 ░░░░░░░░░░░░░░░░░░░░░│ ← 屏底往上 288
##   │ ┌────────┐ ┌────────────────────────────────┐│
##   │ │ 头像框 │ │ ▎队长                          ││
##   │ │236×224 │ │  我还在守着空间站……            ││
##   │ └────────┘ └────────────────────────────────┘│
##   │                        上一步 暂停 跳过 ▸    │
##   └──────────────────────────────────────────────┘
##
## 占地 ≈ 屏高 1/4（与离线定稿的透明层一致）。
##
## ★ 四个按钮的语义（由主控 `eve_intro_scene.gd` 落实）：
##   · 上一步   —— 回到上一句开头；**视频一起回退**（时间轴是按视频排的，不能只退文字）
##   · 下一步 ▸ —— 当前句没显示完 ⇒ 先补全；已显示完 ⇒ 跳到下一句
##   · 暂停     —— 冻结时间真源 + 暂停视频；再按继续
##   · 跳过对话 —— **跳过整段对话**，直接进末段（信标展开 + 任务提示）。
##                 ⚠️ 2026-10-01 用户反馈：原来叫「跳过」，他以为是"跳过当前这句"。
##                 改名 + 改语义：它跳的是**对话**，不是退对局。要退出开场，
##                 用末段的「▶ 进入边境」。
## 另外：**点画面 = 补全当前句**（与「下一步」等价的第一段行为）。

signal prev_pressed()
signal next_pressed()                 ## 下一步：补全当前句 or 进下一句
signal pause_toggled(on: bool)
signal skip_pressed()                 ## 「跳过对话」：跳过整段对话 → 进末段
signal line_skipped()                 ## 点画面，要求把当前句一次显示完

const SCRIPT := preload("res://scripts/data/eve_intro_script.gd")
const BTN_THEME := preload("res://scripts/ui/eve_button_theme.gd")

# ── 版面常量（按屏底定位）────────────────────────────────
const BAND_H := 288.0                 ## 底部半透明带高度（1080 − 792）
const BAND_FADE := 90.0               ## 顶边渐隐
const BAND_A := 0.55
const BAND_RGB := Color(0.016, 0.027, 0.039)

const PORT_W := 236.0
const PORT_H := 224.0
const PORT_X := 60.0
const DLG_X := 320.0
const DLG_W := 1508.0
const RIGHT_MARGIN := 92.0
const BOX_TOP_FROM_BOTTOM := 274.0    ## 1080 − 806
const BOX_H := 224.0

const NAME_X := 24.0
const NAME_Y := 18.0
const BAR_W := 3.0
const BAR_H := 20.0
const TEXT_X := 24.0
const TEXT_Y := 68.0
const TEXT_SIZE := 26
const BTN_H := 34.0
## 按钮行**顶边**距屏幕底边多少（= 1080 − 1044，与离线透明层定稿一致）。
## ⚠️ 是"顶边偏移"不是"底边偏移" —— 写成底边偏移会让按钮整体抬高 34px，
##    正好压住对话框的下沿（对话框底 = 1080 − 50）。
const BTN_TOP_OFFSET := 36.0
const BTN_GAP := 12.0
## 上一步 / 下一步 / 暂停 / 跳过对话
## ⚠️ 与离线透明视频那一版（3 个按钮）**已经不一致** —— 那份是给剪辑用的，
##    这一版是游戏内实机，以这里为准。
const BTN_W := [100.0, 108.0, 84.0, 132.0]

const C_TEXT := Color(0.886, 0.925, 0.941)
const C_OUTLINE := Color(0.012, 0.020, 0.031)
const C_BOX := Color(0.031, 0.047, 0.063)
const C_EDGE := Color(0.282, 0.384, 0.416, 0.882)
const C_GOLD := Color(0.91, 0.76, 0.35)

var _catcher: Control                 ## 全屏透明点击层（在按钮**下面**）
var _band: Control
var _port_box: Panel
var _portrait: TextureRect
var _dlg_box: Panel
var _name_bar: ColorRect
var _name: Label
var _body: Label
var _btn_row: HBoxContainer
var _btn_prev: Button
var _btn_next: Button
var _btn_pause: Button
var _btn_skip: Button

var _lines: Array = []
var _line_idx := -1
var _paused := false
var _prompt := false
var _cinematic := false               ## 末段信标视频期间：整层让位，只留「跳过对话」
var _portraits: Dictionary = {}


func _ready() -> void:
	name = "IntroOverlay"
	# ⛔ 用 `set_anchors_and_offsets_preset` 而不是 `set_anchors_preset`：
	#    `set_anchors_preset` 会**保持控件当前矩形**（只改锚点、重算偏移去补偿），
	#    在 `.new()` 出来的 0×0 控件上调用 ⇒ 仍然是 0×0，整层画不出来。
	#    （踩过：overlay 的 size 恒为 0，对话框被算成负宽度、整屏空白。）
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE     # 本层自身不吃事件，交给子节点
	_build()
	resized.connect(_layout)
	_layout()
	set_ui_on(false)                                # 片头段整屏干净，由主控打开


func _build() -> void:
	# ① 全屏点击层 —— **必须最先加**（Godot 按子节点逆序做命中测试，
	#    后加的按钮才在它上面、才抢得到点击）
	_catcher = Control.new()
	_catcher.name = "ClickCatcher"
	_catcher.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	_catcher.gui_input.connect(_on_catcher_input)
	add_child(_catcher)

	# ② 半透明带（自绘，随高度变化）
	_band = Control.new()
	_band.name = "Band"
	_band.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_band.draw.connect(_draw_band)
	add_child(_band)

	# ③ 头像框
	_port_box = Panel.new()
	_port_box.name = "PortraitBox"
	_port_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_port_box.add_theme_stylebox_override("panel", _box_style(0.86))
	add_child(_port_box)

	_portrait = TextureRect.new()
	_portrait.name = "Portrait"
	_portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_port_box.add_child(_portrait)

	# ④ 对话框
	_dlg_box = Panel.new()
	_dlg_box.name = "DialogueBox"
	_dlg_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dlg_box.add_theme_stylebox_override("panel", _box_style(0.745))
	add_child(_dlg_box)

	_name_bar = ColorRect.new()
	_name_bar.name = "NameBar"
	_name_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dlg_box.add_child(_name_bar)

	_name = Label.new()
	_name.name = "Speaker"
	FONT.fs(_name, 15)
	_name.add_theme_constant_override("outline_size", 5)
	_name.add_theme_color_override("font_outline_color", C_OUTLINE)
	_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dlg_box.add_child(_name)

	_body = Label.new()
	_body.name = "Body"
	FONT.fs(_body, TEXT_SIZE)
	_body.add_theme_color_override("font_color", C_TEXT)
	# 描边必须留：背景视频是亮的，没描边的浅色字会整行消失
	_body.add_theme_constant_override("outline_size", 6)
	_body.add_theme_color_override("font_outline_color", C_OUTLINE)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.clip_text = true
	_dlg_box.add_child(_body)

	# ⑤ 三个按钮（最后加 ⇒ 在最上层）
	_btn_row = HBoxContainer.new()
	_btn_row.name = "Buttons"
	_btn_row.add_theme_constant_override("separation", int(BTN_GAP))
	_btn_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_btn_row)

	_btn_prev = _mk_btn("上一步", "Prev")
	_btn_prev.pressed.connect(func(): prev_pressed.emit())
	_btn_next = _mk_btn("下一步 ▸", "Next")
	_btn_next.pressed.connect(func(): next_pressed.emit())
	_btn_pause = _mk_btn("暂停", "Pause")
	_btn_pause.pressed.connect(_on_pause)
	_btn_skip = _mk_btn("跳过对话", "Skip")
	_btn_skip.pressed.connect(func(): skip_pressed.emit())


func _mk_btn(text: String, node_name: String) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.custom_minimum_size = Vector2(0, BTN_H)
	FONT.fs(b, 13)
	BTN_THEME.apply(b, "hud")
	_btn_row.add_child(b)
	return b


func _box_style(alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_BOX.r, C_BOX.g, C_BOX.b, alpha)
	sb.border_color = C_EDGE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)        # 工程铁律：直角、不发光
	return sb


## 半透明带。**每次 queue_redraw 都会被调**（挂在 CanvasItem 的 draw 信号上）。
func _draw_band() -> void:
	var w := size.x
	var h := size.y
	var top := h - BAND_H
	_band.draw_rect(Rect2(0, top, w, BAND_H + 1.0),
			Color(BAND_RGB.r, BAND_RGB.g, BAND_RGB.b, BAND_A))
	for i in range(int(BAND_FADE)):
		var y := top - BAND_FADE + i
		if y < 0.0:
			continue
		var a := BAND_A * pow(float(i) / BAND_FADE, 1.6)
		_band.draw_rect(Rect2(0, y, w, 1.0),
				Color(BAND_RGB.r, BAND_RGB.g, BAND_RGB.b, a))


func _layout() -> void:
	var w := size.x
	var h := size.y
	var box_top := h - BOX_TOP_FROM_BOTTOM
	var dlg_w := minf(DLG_W, w - DLG_X - RIGHT_MARGIN)

	_port_box.position = Vector2(PORT_X, box_top)
	_port_box.size = Vector2(PORT_W, BOX_H)
	_dlg_box.position = Vector2(DLG_X, box_top)
	_dlg_box.size = Vector2(dlg_w, BOX_H)

	_name_bar.position = Vector2(NAME_X, NAME_Y)
	_name_bar.size = Vector2(BAR_W, BAR_H)
	_name.position = Vector2(NAME_X + BAR_W + 10.0, NAME_Y - 3.0)

	_body.position = Vector2(TEXT_X, TEXT_Y)
	_body.size = Vector2(dlg_w - TEXT_X * 2.0, BOX_H - TEXT_Y - 12.0)

	var total := 0.0
	for bw in BTN_W:
		total += bw
	total += BTN_GAP * float(BTN_W.size() - 1)
	_btn_row.position = Vector2(DLG_X + dlg_w - total, h - BTN_TOP_OFFSET)
	var i := 0
	for child in _btn_row.get_children():
		var b: Button = child
		b.custom_minimum_size = Vector2(BTN_W[i], BTN_H)
		i += 1

	_band.queue_redraw()


# ── 对外接口 ─────────────────────────────────────────────

func set_ui_on(on: bool) -> void:
	visible = on


func bind_lines(lines: Array) -> void:
	_lines = lines


## 切到第 n 句。`n < 0` = 没有当前句（片头段）⇒ 不出框。
func show_line(n: int) -> void:
	_line_idx = n
	if n < 0 or n >= _lines.size():
		_port_box.visible = false
		_dlg_box.visible = false
		return
	var L: Dictionary = _lines[n]
	var who := String(L["who"])
	_port_box.visible = true
	_dlg_box.visible = true
	if SCRIPT.SPEAKERS.has(who):
		var cfg: Dictionary = SCRIPT.SPEAKERS[who]
		if not _portraits.has(who):
			_portraits[who] = load(String(cfg["portrait"]))
		_portrait.texture = _portraits[who]
		_name.text = who
		_name.add_theme_color_override("font_color", cfg["color"])
		_name_bar.color = cfg["color"]
	_body.text = String(L["text"])
	_body.visible_characters = 0


func set_reveal(chars: int) -> void:
	if _line_idx < 0 or _line_idx >= _lines.size():
		return
	_body.visible_characters = clampi(chars, 0, String(_lines[_line_idx]["text"]).length())


func reveal_all() -> void:
	if _line_idx >= 0 and _line_idx < _lines.size():
		_body.visible_characters = String(_lines[_line_idx]["text"]).length()


func revealed_all() -> bool:
	if _line_idx < 0 or _line_idx >= _lines.size():
		return true
	return _body.visible_characters >= String(_lines[_line_idx]["text"]).length()


func current_index() -> int:
	return _line_idx


## 末段的任务提示（替换掉台词）。
## ⚠️ 这是**最小版**的任务目标提示 —— 完整版「任务方框 + 星币教学」还没做，
##    这里只是把「守卫什么、打几回合」一句话说清，别当成最终形态。
func show_task(text: String) -> void:
	_line_idx = -1                      # 让 set_reveal / revealed_all 不再管这一屏
	_port_box.visible = false
	_dlg_box.visible = true
	_name.text = "本局任务"
	_name.add_theme_color_override("font_color", C_GOLD)
	_name_bar.color = C_GOLD
	_body.text = text
	_body.visible_characters = -1       # 全显


## 末段：收起「上一步 / 暂停」，把主按钮变成「▶ 进入边境」
func set_prompt(on: bool) -> void:
	_prompt = on
	_btn_prev.visible = not on and not _cinematic
	_btn_next.visible = not on and not _cinematic
	_btn_pause.visible = not on and not _cinematic
	_btn_skip.text = "▶　进入边境" if on else "跳过对话"


## 末段信标视频期间（`on = true`）：藏掉半透明带 / 头像 / 对话框 / 其余按钮，
## **只留一个「跳过对话」**，让整屏画面给电影镜头。
## ⚠️ 两个开关互相开会打架（`set_prompt` 也想管这三个按钮的可见性）
## ⇒ 两者都同时看 `_prompt` 和 `_cinematic`，谁后调用都不会把另一边覆盖掉。
func set_cinematic(on: bool) -> void:
	_cinematic = on
	_band.visible = not on
	_btn_prev.visible = not on and not _prompt
	_btn_next.visible = not on and not _prompt
	_btn_pause.visible = not on and not _prompt
	_btn_skip.visible = true
	if on:
		_port_box.visible = false
		_dlg_box.visible = false
		_btn_skip.text = "▶　进入边境" if _prompt else "跳过对话"
	else:
		_port_box.visible = _line_idx >= 0
		_dlg_box.visible = _line_idx >= 0


func set_paused(on: bool) -> void:
	_paused = on
	_btn_pause.text = "继续" if on else "暂停"
	_btn_prev.disabled = on
	_btn_next.disabled = on
	_btn_skip.disabled = on


func is_paused() -> bool:
	return _paused


func button(node_name: String) -> Button:
	return _btn_row.get_node_or_null(NodePath(node_name)) as Button


func _on_pause() -> void:
	pause_toggled.emit(not _paused)


## 点画面 = 把当前句**一次显示完**（不是跳过）
func _on_catcher_input(event: InputEvent) -> void:
	if _prompt or _paused or _line_idx < 0:
		return
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		if not revealed_all():
			line_skipped.emit()
