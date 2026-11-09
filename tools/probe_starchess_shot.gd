extends Node

## 星舰万象棋截图探针。

## 注意：本节点挂在 **/root 下（autoload）**，而不是作为 current_scene，
## 因为 change_scene_to_file() 会销毁 current_scene，探针会跟着死掉。

const DIR := "res://.screenshots/starchess/"

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	_run()

func _run() -> void:
	await _wait(1.2)
	_snap("00_main_menu")

	get_tree().change_scene_to_file("res://scenes/starchess/sc_lobby.tscn")
	await _wait(1.0)
	_snap("01_lobby")

	get_tree().change_scene_to_file("res://scenes/starchess/sc_battle.tscn")
	await _wait(1.2)
	_snap("02_battle")

	print("SHOTS DONE")
	get_tree().quit(0)

func _wait(t: float) -> void:
	await get_tree().create_timer(t).timeout

func _snap(tag: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		print("SHOT FAIL ", tag)
		return
	var path := ProjectSettings.globalize_path(DIR + tag + ".png")
	var e := img.save_png(path)
	print("SHOT ", tag, " ", img.get_width(), "x", img.get_height(), " err=", e)
