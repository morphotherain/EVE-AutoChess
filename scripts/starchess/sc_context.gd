extends RefCounted

## 星舰万象棋 —— 场景间传参单例。
##
## [WHY] Godot 的 change_scene_to_file() 带不了参数，
##   而大厅选的指挥官 / 玩家人数必须传给对局场景。
##
## [WHY 用 static var 而不是 autoload] ⚠️ 这是踩过的坑，别改回去：
##   autoload 的名字在**引擎启动那一刻**就定死了，
##   `load_resource_pack()` 只挂文件系统，**不重新注册 autoload**。
##   ⇒ 老客户端（完整包里没有这个 autoload）加载到引用它的脚本时，
##     GDScript 编译期直接报 `Identifier "ScContext" not declared`
##     ⇒ 整个脚本加载失败 ⇒ **黑屏**。
##
##   这就是 2026-11-07 的 b39 事故（见 docs/事故-b39黑屏-2026-11-07.md），
##   也是 tools/check_hotfix_safe.py 那道闸门存在的原因。
##
##   `static var` 是类内状态，**不依赖引擎注册表**，
##   纯脚本随 pck 热更即可生效 —— 老客户端也能安全拿到。
##
## [⚠️ 刻意不写 class_name] 全局类表（`.godot/global_script_class_cache.cfg`）
##   同样是**引擎启动时**读的，和 autoload 一个毛病。
##   所以这里不注册全局名，使用方一律走路径 preload：
##
##       const Context := preload("res://scripts/starchess/sc_context.gd")
##       Context.commander_index = 3
##
##   preload 是**路径解析**，编译期就绑定到文件，不查任何全局表 —— 最安全。

static var commander_index: int = 0
static var player_picks: Array = []
static var seed_value: int = 20261101
static var selected_board: String = ""


static func reset() -> void:
	commander_index = 0
	player_picks = []
	seed_value = 20261101
	selected_board = ""