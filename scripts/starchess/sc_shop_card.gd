extends PanelContainer

## [⚠️ 刻意不写 class_name] 全局类表在**引擎启动时**读，
## 和 autoload 一样会让老客户端解析失败（见 sc_context.gd 的说明）。
## 使用方一律 `const CARD := preload("res://scripts/starchess/sc_shop_card.gd")`。

## 星舰万象棋 —— 商店卡（顶部 4 张大卡）
##
## [WHY] 版式直接对齐 EVE 自己的商店卡（scripts/ui/panels/eve_shop.gd 的 _build_card）：
##   派系顶条 -> 真立绘 -> 名称/费用 -> 属性。不要自己发明一套卡面。
##   唯一增量是【技能说明】与【流派条】—— 那是自走棋需要、EVE 商店不需要的。
##
## [SRC] 立绘走 EveShipArtView（全工程唯一画立绘控件，自带裁留白 + dimmed）
## [SRC] 字体走 FONT.fs()

signal card_pressed(index: int)

const FONT := preload("res://scripts/ui/eve_font.gd")
const ADAPTER := preload("res://scripts/starchess/sc_ship_adapter.gd")

const C_TEXT_HI := Color(0.91, 0.96, 0.97)
const C_DIM := Color(0.44, 0.55, 0.59)
const C_GOLD := Color(0.91, 0.76, 0.35)
const C_BORDER := Color(0.42, 0.55, 0.60, 0.40)

var index: int = 0
var ship: Dictionary = {}
var affordable: bool = true

var _art: EveShipArtView = null
var _name_lb: Label = null
var _cost_lb: Label = null
var _ability_lb: Label = null
var _stat_lb: Label = null
var _flow_lb: Label = null
var _top_bar: ColorRect = null
var _panel_sb: StyleBoxFlat = null


func _ready() -> void:
	mouse_entered.connect(func(): EveUiAudio.play("ui.hover"))
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_build()


func _build() -> void:
	_panel_sb = StyleBoxFlat.new()
	_panel_sb.bg_color = Color(0.035, 0.047, 0.055, 0.82)
	_panel_sb.border_color = C_BORDER
	_panel_sb.set_border_width_all(1)
	_panel_sb.set_corner_radius_all(0)
	add_theme_stylebox_override("panel", _panel_sb)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	add_child(col)

	_top_bar = ColorRect.new()
	_top_bar.custom_minimum_size = Vector2(0, 3)
	_top_bar.color = Color(0.55, 0.78, 0.82)
	_top_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_top_bar)

	_art = EveShipArtView.new()
	_art.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_art.custom_minimum_size = Vector2(0, 118)
	col.add_child(_art)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 4)
	name_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(name_row)

	_name_lb = Label.new()
	_name_lb.text = "-"
	_name_lb.add_theme_color_override("font_color", C_TEXT_HI)
	FONT.fs(_name_lb, 13)
	_name_lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_lb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name_lb.clip_text = true
	_name_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_child(_name_lb)

	# ⚠️ 价格**不放在名称行** —— 名称行窄，价格会挤到属性行上（踩过）。
	#    改挂到下方流派条的右侧，与 EVE 商店卡的"费用在名称行"不同的地方就在这里。
	_cost_lb = Label.new()
	_cost_lb.text = "0"
	_cost_lb.add_theme_color_override("font_color", C_GOLD)
	FONT.fs(_cost_lb, 14)
	_cost_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_stat_lb = Label.new()
	_stat_lb.text = "-"
	_stat_lb.add_theme_color_override("font_color", C_DIM)
	FONT.fs(_stat_lb, 10)
	_stat_lb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_stat_lb.clip_text = true
	_stat_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_stat_lb)

	_ability_lb = Label.new()
	_ability_lb.text = ""
	_ability_lb.add_theme_color_override("font_color", Color(0.66, 0.78, 0.82))
	FONT.fs(_ability_lb, 10)
	_ability_lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ability_lb.custom_minimum_size = Vector2(0, 30)
	_ability_lb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_ability_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_ability_lb)

	var flow_bar := ColorRect.new()
	flow_bar.custom_minimum_size = Vector2(0, 24)
	flow_bar.color = Color(0.08, 0.11, 0.13, 0.9)
	flow_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(flow_bar)

	var flow_row := HBoxContainer.new()
	flow_row.set_anchors_preset(Control.PRESET_FULL_RECT)
	flow_row.offset_left = 8.0
	flow_row.offset_right = -8.0
	flow_row.add_theme_constant_override("separation", 4)
	flow_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flow_bar.add_child(flow_row)

	_flow_lb = Label.new()
	_flow_lb.text = ""
	_flow_lb.add_theme_color_override("font_color", C_DIM)
	FONT.fs(_flow_lb, 10)
	_flow_lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flow_lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_flow_lb.clip_text = true
	_flow_lb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_flow_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flow_row.add_child(_flow_lb)

	_cost_lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	flow_row.add_child(_cost_lb)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		card_pressed.emit(index)


## 填入一艘船。ability 由调用方给（EVE 表里没有技能概念，是自走棋的增量）。
func set_ship(data: Dictionary, cost: int, ability: String, flow_name: String) -> void:
	ship = data
	var sid := StringName(str(data.get("id", "")))
	if _art != null:
		_art.ship_key = sid
		_art.accent = ADAPTER.faction_color(str(data.get("faction_cn", "")))
	if _top_bar != null:
		_top_bar.color = ADAPTER.faction_color(str(data.get("faction_cn", "")))
	if _name_lb != null:
		_name_lb.text = str(data.get("name", "-"))
	if _cost_lb != null:
		_cost_lb.text = str(cost)
	if _stat_lb != null:
		_stat_lb.text = "攻 %d   血 %d" % [
			int(data.get("atk", 0)), int(data.get("hp", 0))]
	if _ability_lb != null:
		_ability_lb.text = ability
	if _flow_lb != null:
		_flow_lb.text = "%s · %s" % [flow_name, str(data.get("faction_cn", ""))]


func set_affordable(v: bool) -> void:
	affordable = v
	if _art != null:
		_art.dimmed = not v
	modulate = Color(1, 1, 1, 1.0 if v else 0.62)
