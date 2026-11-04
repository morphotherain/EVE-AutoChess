extends Node
## 启动引导（autoload）。在任何场景加载之前执行一次。
##
## 目前只负责语言：`TranslationServer` 的初始 locale 是操作系统语言，
## 必须在第一次取词之前改成游戏设定的语言，否则英文系统上会取到 CSV 的 en 列
## （例如舰船中文名显示成英文、羁绊数值不生效）。
##
## autoload 早于主场景实例化，所以无论从哪个场景启动（主菜单、验收场景）都会先执行这里。
## 只依赖 `EveText`，不要在这里引用其他游戏脚本，以免提前触发它们的静态初始化。

const T := preload("res://scripts/core/eve_text.gd")
## 安卓线 · 设备指标采集（只读，不改布局）。桌面端不会写。
const DI := preload("res://scripts/mobile/eve_device_info.gd")


func _init() -> void:
	T.apply_saved()


## ★ 2026-11-04 网页版字体。
## [WHY] 浏览器里没有"系统已装字体"这回事，`SystemFont` 会退化到引擎自带
##       默认字体（无中文字形）⇒ 整站中文变乱码。这里把随包分发的
##       Noto Sans SC 子集（OFL 授权，按工程实际用字裁剪过）设为全局兜底。
## [NOTE] 只在 web 生效，桌面/安卓仍走系统字体，出图基线不受影响。
## [PITFALL] 不能放在 `_init()`：那时节点还没进树，`get_tree()` 直接报
##       `Parameter "data.tree" is null`，主题挂不上去（实测白干一轮）。
const WEB_FONT := "res://assets/fonts/NotoSansSC-Regular.ttf"


func _apply_web_font() -> void:
	if not ResourceLoader.exists(WEB_FONT):
		push_warning("[EveBoot] 网页版字体缺失：" + WEB_FONT)
		return
	var f := load(WEB_FONT)
	if not (f is Font):
		push_warning("[EveBoot] 网页版字体加载失败：" + WEB_FONT)
		return

	# ★★ 2026-11-04 修正：只挂 `Theme.default_font` **不够**，会漏掉绝大多数控件。
	#
	# [WHY] 实测证据（网页版战斗场景，打了 [web-diag] 打印每个 Label 的解析结果）：
	#         自己 new 的 Label      → font = Noto Sans SC      ← 走 root.theme.default_font
	#         HUD 里真实存在的 Label → font = Open Sans SemiBold ← 内置默认主题！
	#       两者在同一棵树下，差别只在**内置默认主题里定义了 `Label/fonts/font`**。
	#       Godot 的查找顺序是「override → 自身上级 theme 链 → 内置默认主题 → fallback」，
	#       而 `Theme.default_font` 只在**该类型整条链都没定义 font 时**才顶上。
	#       ⇒ 内置主题里那套 Open Sans 永远先命中，中文自然是 notdef 方块。
	# [PITFALL] 主菜单看着没问题，是因为它那批控件确实没被内置主题命中 ——
	#       别拿"主菜单正常"当字体没问题的证据，这次就是这么被骗过去的。
	#
	# 修法：**逐个类型**把内置默认主题的 font 项换成中文子集。
	#       这是唯一能一次覆盖 Label/Button/RichTextLabel/… 全部控件，
	#       且不需要在 88 处调用点逐个塞字体的办法。
	ThemeDB.fallback_font = f
	var dt := ThemeDB.get_default_theme()
	if dt != null:
		dt.default_font = f
		for ty in dt.get_type_list():
			if dt.has_font("font", ty):
				dt.set_font("font", ty, f)

	# 保险：再给根窗口挂一份（覆盖那些绕过默认主题、直接读 root.theme 的路径）
	var t := Theme.new()
	t.default_font = f
	for ty2 in ["Label", "Button", "RichTextLabel", "LineEdit", "TextEdit",
			"PopupMenu", "TooltipLabel", "ItemList", "Tree", "OptionButton",
			"CheckBox", "CheckButton", "LinkButton", "ProgressBar", "SpinBox",
			"TabBar", "TabContainer", "MenuBar", "CodeEdit"]:
		t.set_font("font", ty2, f)
	var tree := get_tree()
	if tree != null and tree.root != null:
		tree.root.theme = t
	print("[EveBoot] 网页版字体已接管：", f.get_font_name())


## ★ 2026-10-18：真机指标回传。
##   等两帧再采集 —— `_init()` 时根窗口还没完成尺寸/缩放初始化，那时读到的
##   `viewport_logical` 是默认值，不是真机实际值（会误导后续布局）。
func _ready() -> void:
	if OS.has_feature("web"):
		_apply_web_font()
	if not OS.has_feature("mobile"):
		return
	await get_tree().process_frame
	await get_tree().process_frame
	DI.write_report(get_tree())
