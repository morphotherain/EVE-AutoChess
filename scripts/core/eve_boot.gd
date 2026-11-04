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
	# [NOTE] 光设 ThemeDB.fallback_font 覆盖不全（大量控件走主题查找），
	#        必须再给根窗口挂一个带 default_font 的 Theme，Control 才继承得到。
	ThemeDB.fallback_font = f
	var t := Theme.new()
	t.default_font = f
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
