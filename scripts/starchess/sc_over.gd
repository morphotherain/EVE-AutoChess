extends Control

## 星舰万象棋 —— 结算

const FONT := preload("res://scripts/ui/eve_font.gd")
const THEME := preload("res://scripts/ui/eve_button_theme.gd")

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.012, 0.02, 0.028, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var t := Label.new()
	t.text = "对 局 结 束"
	t.add_theme_color_override("font_color", Color(0.55, 0.78, 0.82))
	FONT.fs(t, 34)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.position = Vector2(660, 380)
	t.size = Vector2(600, 60)
	add_child(t)

	var sub := Label.new()
	sub.text = "星舰万象棋 · 无美术原型 · 框架验证"
	sub.add_theme_color_override("font_color", Color(0.44, 0.55, 0.59))
	FONT.fs(sub, 13)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.position = Vector2(660, 450)
	sub.size = Vector2(600, 24)
	add_child(sub)

	var back := Button.new()
	back.text = "返回主菜单"
	back.custom_minimum_size = Vector2(200, 48)
	back.position = Vector2(860, 540)
	THEME.apply(back, "accent")
	FONT.fs(back, 15)
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	add_child(back)
