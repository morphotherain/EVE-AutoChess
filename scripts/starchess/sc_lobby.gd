extends Control

## 星舰万象棋 —— 大厅（选指挥官）
##
## 流程对齐真实游戏：6 人环形分布 -> 选指挥官（60 秒）-> 选棋盘（占位）-> 进对局。
## 视觉全部复用 EVE 工程：字体 FONT / 按钮 EveButtonTheme / 舰船立绘 EveShipArtView。
##
## 注意：指挥官**可以重复选**（用户明确要求），多人同选一个是合法的。
## 注意：棋盘样式不实现，只留明确写着未实现的占位槽。

const FONT := preload("res://scripts/ui/eve_font.gd")
const THEME := preload("res://scripts/ui/eve_button_theme.gd")
const ADAPTER := preload("res://scripts/starchess/sc_ship_adapter.gd")
const CONTEXT := preload("res://scripts/starchess/sc_context.gd")
const COMMANDERS := preload("res://scripts/starchess/sc_commanders.gd")

const C_TEXT := Color(0.70, 0.82, 0.85)
const C_TEXT_HI := Color(0.91, 0.96, 0.97)
const C_DIM := Color(0.44, 0.55, 0.59)
const C_ACCENT := Color(0.55, 0.78, 0.82)
const C_GOLD := Color(0.91, 0.76, 0.35)
const C_BORDER := Color(0.42, 0.55, 0.60, 0.34)
const C_BG_DEEP := Color(0.012, 0.02, 0.028, 1.0)

## 6 个玩家的环形站位（相对 1920x1080 的比例坐标）
const RING := [
	Vector2(0.50, 0.20), Vector2(0.74, 0.32), Vector2(0.74, 0.62),
	Vector2(0.50, 0.76), Vector2(0.26, 0.62), Vector2(0.26, 0.32),
]

const PICK_SECONDS := 60.0

var _picked: Array = [-1, -1, -1, -1, -1, -1]
var _my_index: int = 0
var _time_left: float = PICK_SECONDS
var _commander_ids: Array = []
var _center_name: Label = null
var _timer_lb: Label = null
var _ready_lb: Label = null
var _rows: Array = []


func _ready() -> void:
	_load_commanders()
	_build()
	_schedule_ai_picks()

## 指挥官表来自 scripts/starchess/sc_commanders.gd。
##
## [注意 不要改回读 data/*.json] data/ 有 .gdignore，整个目录不进 pck。
##   曾经读 data/starchess/sc_commanders.json —— 热更后包内根本没这个文件，
##   运行时静默拿到空表，指挥官全空且不会报错。见 sc_commanders.gd 文件头。
func _load_commanders() -> void:
	_commander_ids = COMMANDERS.all()
	if _commander_ids.is_empty():
		push_warning("[sc_lobby] 指挥官表为空 —— 检查 scripts/starchess/sc_commanders.gd")
		return
	var problems: Array = COMMANDERS.validate()
	if not problems.is_empty():
		push_warning("[sc_lobby] 指挥官表有问题: %s" % str(problems))
func _build() -> void:
	var bg := ColorRect.new()
	bg.color = C_BG_DEEP
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var title := Label.new()
	title.text = "选择指挥官"
	title.add_theme_color_override("font_color", C_TEXT_HI)
	FONT.fs(title, 18)
	title.position = Vector2(40, 26)
	add_child(title)

	_timer_lb = Label.new()
	_timer_lb.text = "60"
	_timer_lb.add_theme_color_override("font_color", C_GOLD)
	FONT.fs(_timer_lb, 26)
	_timer_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_timer_lb.position = Vector2(910, 18)
	_timer_lb.size = Vector2(100, 40)
	add_child(_timer_lb)

	var hint := Label.new()
	hint.text = "指挥官可以重复选 · 60 秒后自动进入"
	hint.add_theme_color_override("font_color", C_DIM)
	FONT.fs(hint, 11)
	hint.position = Vector2(40, 52)
	add_child(hint)

	_center_name = Label.new()
	_center_name.text = "等待选择"
	_center_name.add_theme_color_override("font_color", C_ACCENT)
	FONT.fs(_center_name, 22)
	_center_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center_name.position = Vector2(760, 470)
	_center_name.size = Vector2(400, 40)
	add_child(_center_name)

	# 棋盘占位：明确标注未实现，避免"看着能点、点了没反应"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.07, 0.6)
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	var slot_panel := PanelContainer.new()
	slot_panel.add_theme_stylebox_override("panel", sb)
	slot_panel.position = Vector2(810, 530)
	slot_panel.size = Vector2(300, 54)
	add_child(slot_panel)
	var slot_lb := Label.new()
	slot_lb.text = "棋盘样式 · 未实现"
	slot_lb.add_theme_color_override("font_color", C_DIM)
	FONT.fs(slot_lb, 12)
	slot_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slot_lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	slot_panel.add_child(slot_lb)

	for i in range(6):
		var pos: Vector2 = RING[i]
		var holder := Control.new()
		holder.position = Vector2(1920.0 * pos.x - 70.0, 1080.0 * pos.y - 40.0)
		holder.size = Vector2(140, 88)
		add_child(holder)
		var circle := ColorRect.new()
		circle.color = Color(0.05, 0.08, 0.10, 0.9)
		circle.position = Vector2(38, 0)
		circle.size = Vector2(64, 64)
		holder.add_child(circle)
		var initial := Label.new()
		initial.text = "?"
		initial.add_theme_color_override("font_color", C_DIM)
		FONT.fs(initial, 24)
		initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		initial.position = Vector2(38, 0)
		initial.size = Vector2(64, 64)
		holder.add_child(initial)
		var nm := Label.new()
		nm.text = "玩家 %d" % (i + 1)
		nm.add_theme_color_override("font_color", C_DIM)
		FONT.fs(nm, 11)
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nm.position = Vector2(0, 66)
		nm.size = Vector2(140, 18)
		holder.add_child(nm)
		_rows.append({"initial": initial, "name": nm})

	# 底部指挥官条
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	bar.position = Vector2(0, 890)
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.size = Vector2(1920, 100)
	add_child(bar)
	for i in range(_commander_ids.size()):
		var c: Dictionary = _commander_ids[i]
		var b := Button.new()
		b.custom_minimum_size = Vector2(150, 92)
		b.text = "%s\n%s" % [str(c.get("name", "")), str(c.get("empire_cn", ""))]
		THEME.apply(b, "default")
		FONT.fs(b, 13)
		b.pressed.connect(_on_pick.bind(i))
		bar.add_child(b)

	var go := Button.new()
	go.text = "▶ 进入对局"
	go.position = Vector2(1660, 960)
	go.size = Vector2(200, 44)
	THEME.apply(go, "accent")
	go.pressed.connect(_enter_battle)
	add_child(go)

	_ready_lb = Label.new()
	_ready_lb.text = ""
	_ready_lb.add_theme_color_override("font_color", C_DIM)
	FONT.fs(_ready_lb, 12)
	_ready_lb.position = Vector2(40, 960)
	add_child(_ready_lb)


func _process(delta: float) -> void:
	if _time_left <= 0.0:
		return
	_time_left = maxf(0.0, _time_left - delta)
	if _timer_lb != null:
		_timer_lb.text = str(int(ceil(_time_left)))
	if _time_left <= 0.0:
		_enter_battle()


## 玩家点选指挥官：允许重复，不排除别人已选的。
func _on_pick(idx: int) -> void:
	if idx < 0 or idx >= _commander_ids.size():
		return
	_picked[_my_index] = idx
	EveUiAudio.play("commander.select")
	var c: Dictionary = _commander_ids[idx]
	if _center_name != null:
		_center_name.text = str(c.get("name", ""))
	_refresh_rows()


func _refresh_rows() -> void:
	for i in range(_rows.size()):
		var r: Dictionary = _rows[i]
		var nm: Label = r["name"]
		var ini: Label = r["initial"]
		var idx := int(_picked[i])
		if idx >= 0 and idx < _commander_ids.size():
			var c: Dictionary = _commander_ids[idx]
			nm.text = str(c.get("name", ""))
			nm.add_theme_color_override("font_color", C_TEXT_HI if i == _my_index else C_TEXT)
			var cname := str(c.get("name", "?"))
			ini.text = cname.substr(0, 1)
			ini.add_theme_color_override("font_color", ADAPTER.faction_color(str(c.get("empire_cn", ""))))
		else:
			nm.text = "玩家 %d" % (i + 1)
			nm.add_theme_color_override("font_color", C_DIM)
			ini.text = "?"
			ini.add_theme_color_override("font_color", C_DIM)
	if _ready_lb != null:
		var mine := int(_picked[_my_index])
		if mine < 0:
			_ready_lb.text = "你还没选指挥官"
		else:
			_ready_lb.text = "已选：%s" % str((_commander_ids[mine] as Dictionary).get("name", ""))


## 其余 5 个位置由 AI 陆续选完（模拟别人也在选）。
func _schedule_ai_picks() -> void:
	for i in range(1, 6):
		var t := get_tree().create_timer(0.8 * float(i))
		t.timeout.connect(_ai_pick.bind(i))


func _ai_pick(idx: int) -> void:
	if idx <= 0 or idx >= _picked.size():
		return
	_picked[idx] = (idx * 2) % maxi(1, _commander_ids.size())
	_refresh_rows()


func _enter_battle() -> void:
	if int(_picked[_my_index]) < 0:
		_picked[_my_index] = 0
	CONTEXT.commander_index = int(_picked[_my_index])
	CONTEXT.player_picks = _picked.duplicate()
	EveUiAudio.play("menu.start")
	get_tree().change_scene_to_file("res://scenes/starchess/sc_battle.tscn")
