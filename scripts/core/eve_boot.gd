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

## ★ 2026-11-07 移动端性能档 + 崩溃取证（玩家端：荣耀平板 GT · 8+256）。
##
## [WHY] 玩家报告卡顿 + 频繁闪退。查下来的事实是：这台是
##       天玑8350 · **Mali-G615 MC6** · **2800×1840（5.15 MP，1080p 的 2.49 倍）** · 最高 144Hz，
##       而我们跑的是 Compatibility 渲染器 + 2×MSAA + FXAA + glow，并且
##       **全工程没有一处 `Engine.max_fps`** ⇒ 系统给 120/144Hz 就照着画 5.15MP。
##       Mali 这档 GPU 的 fill rate 吃不下「5.15MP × 120Hz × 2×MSAA」，结果是
##       满载 → 发热 → 系统降频 → 更卡。60 帧足够，且给 glow / 粒子留出余量。
## [SRC] docs/玩家反馈-荣耀平板GT卡顿闪退-2026-11-07.md
const MOBILE_MAX_FPS := 60
## 上次会话标记：**正常退出才删**。启动时它还在 = 上次没走完退出流程。
const RUN_MARK := "user://run.flag"
## 引擎文件日志，由 project.godot 的 `debug/file_logging/enable_file_logging` 打开。
const LOG_PATH := "user://logs/godot.log"
## 切后台那一刻的日志快照。
## [PITFALL] 引擎在**任何 GDScript 执行之前**就按 WRITE 打开 godot.log（截断），
##           所以崩溃当次的日志活不过重启 —— 只有这一刻抢下来的快照才是现场。
const LOG_SNAPSHOT := "user://logs/last_session.log"

## 上次启动是不是没走完退出流程（`EveReport` 读它决定要不要弹「发诊断信息」）。
var had_unclean_exit := false
## 上次会话的启动时间戳 —— 作为「这次的现场报过没」的标识，避免同一次崩溃反复追问。
var unclean_ts := 0
## 日志路径暴露成属性（而不是让 `EveReport` 去读本文件的常量）：
## 跨脚本读常量在 GDScript 里不是常规写法，属性访问没有这个疑问。
var log_path := LOG_PATH
var log_snapshot_path := LOG_SNAPSHOT


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
	# 性能档要在第一帧之前定下来，否则玩家先看到的就是掉帧的开头。
	_apply_mobile_perf()
	_check_last_session()
	await get_tree().process_frame
	await get_tree().process_frame
	DI.write_report(get_tree())


## 移动端性能档：封顶帧率 + 关掉两项最贵的全屏开销。
##
## [NOTE] 只对 `mobile` 生效。桌面 / 网页的 1920×1080 出图基线一个字节都不碰 ——
##        那样会让历史验收图全部对不上。
func _apply_mobile_perf() -> void:
	Engine.max_fps = MOBILE_MAX_FPS
	var vp := get_viewport()
	if vp == null:
		return
	# [WHY] 2×MSAA 在 tiler GPU 上是一项纯带宽税，5.15MP 下是整套配置里最贵的一项。
	#       这块屏 291 PPI、2800 像素宽，关掉之后锯齿肉眼几乎看不出。
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	print("[EveBoot] 移动端性能档 max_fps=%d msaa=off fxaa=off 窗口=%s"
			% [MOBILE_MAX_FPS, str(DisplayServer.window_get_size())])


## 上次是不是正常退出？不是就把快照尾部打到 logcat（没有上报通道前，这是唯一能人工读到的现场）。
func _check_last_session() -> void:
	if FileAccess.file_exists(RUN_MARK):
		had_unclean_exit = true
		unclean_ts = _read_mark()
		print("[EveBoot] 上次未正常退出（切后台被系统回收 或 闪退）。快照尾部如下：")
		_dump_snapshot_tail()
	_write_mark()


## 标记文件里存的是**本次启动的时间戳**（不是 0/1），这样上报端能分清
## 「这是同一个现场已经问过了」还是「又崩了一次，该再问一次」。
func _read_mark() -> int:
	var f := FileAccess.open(RUN_MARK, FileAccess.READ)
	if f == null:
		return 0
	var s := f.get_as_text().strip_edges()
	f.close()
	return int(s) if s.is_valid_int() else 0


func _write_mark() -> void:
	var f := FileAccess.open(RUN_MARK, FileAccess.WRITE)
	if f == null:
		return
	f.store_line(str(Time.get_unix_time_from_system()))
	f.close()


func _clear_mark() -> void:
	if FileAccess.file_exists(RUN_MARK):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RUN_MARK))


## 把快照尾部 N 行打到 logcat。
func _dump_snapshot_tail(lines: int = 40) -> void:
	if not FileAccess.file_exists(LOG_SNAPSHOT):
		print("[EveBoot] （没有快照：上次退出前没经过 PAUSED，或文件日志没开）")
		return
	var f := FileAccess.open(LOG_SNAPSHOT, FileAccess.READ)
	if f == null:
		return
	var rows := f.get_as_text().split("\n")
	f.close()
	for i in range(maxi(0, rows.size() - lines), rows.size()):
		print("[prev] ", rows[i])


## 切后台瞬间抓一份日志快照（玩家"切出去再回来就闪退"这类问题，只有这里留得下证据）。
func _snapshot_log() -> void:
	if not FileAccess.file_exists(LOG_PATH):
		return
	var src := FileAccess.open(LOG_PATH, FileAccess.READ)
	if src == null:
		return
	var data := src.get_buffer(src.get_length())
	src.close()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://logs"))
	var dst := FileAccess.open(LOG_SNAPSHOT, FileAccess.WRITE)
	if dst == null:
		return
	dst.store_buffer(data)
	dst.close()


func _notification(what: int) -> void:
	if not OS.has_feature("mobile"):
		return
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT:
			_snapshot_log()
		NOTIFICATION_WM_CLOSE_REQUEST:
			# 走完退出流程 = 正常退出，下次启动不该报"异常"。
			_clear_mark()
