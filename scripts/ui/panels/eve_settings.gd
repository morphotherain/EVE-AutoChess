extends "res://scripts/ui/eve_window.gd"

## EVE 自走棋 —— 设置窗（阶段 D / 2026-09-28 重构）
##
## ══════════════════════════════════════════════════════════════════
##  它存在的原因：把「散落开关」收进来
## ══════════════════════════════════════════════════════════════════
##  在它出现之前，这个工程有一堆只能靠键盘快捷键碰到的开关：
##    B = 棋盘显隐 · C = 相机复位 · SPACE = 暂停 · R = 重开一局
##  它们分散在 `eve_battle_scene._unhandled_input` 里，玩家不看代码就发现不了。
##  顶条右端那个 `≡` 按钮从 V3 稿起就一直空着 —— 它就是给这个窗留的位置。
##
##  ⚠️ 快捷键【保留不动】。设置窗是「让不知道快捷键的玩家也能用」，
##     不是「取代快捷键」。两者并存，谁也不抢谁。
##
## ── 2026-09-28 重构：从「开关集散地」升级成「真设置」────────────
##  三件事：
##   ① **暂停按钮上位**（最顶、最大）—— PVE 也要能停。暂停 = 停推进 + 禁操作，
##      由 `EveHudRoot` 的全屏遮罩吃掉鼠标、主控停掉 `_process`，
##      只有空格与设置窗自己的「继续」能解开（见 eve_battle_scene.set_paused）。
##   ② **音量四条滑杆**（总 / 音效 / 环境 / 音乐）+ 静音 —— 后端是
##      `EveAudio.set_volume()`，真实存在，不是假旋钮。
##   ③ **持久化**（`EveSettingsStore` → `user://settings.cfg`）——
##      只存「玩家偏好」，不存「场上状态」（雾 / 射程环 / 棋盘会随阶段自动变，
##      存下来只会造成「上局收尾是关的 ⇒ 下局开局也是关的」这种鬼打墙）。
##
## ── 分区 ──────────────────────────────────────────────────────────
##    [暂停]  ·  音频  ·  画面  ·  战斗界面  ·  操作  ·  系统（DEBUG 折叠）
##  顺序是「按玩家会来找什么」排的：最急的是暂停，其次听感，其次画面，
##  其次场上辅助线，其次是动作，最后是调试残留。
##
## ── 交互形态：为什么用「分段按钮」而不是 CheckButton ──────────────
##  这个工程的整套视觉语言是**直角、1px 边框、不发光**（见 EveWindow 顶注）。
##  Godot 默认 CheckButton 是圆角胶囊 + 蓝色高亮，丢进来自带一整套
##  不属于这里的语言。所以开关用 EveButtonTheme 的按钮做（青底 = 开），
##  连续量（音量）用 HSlider **套同样的直角 StyleBoxFlat**。
##
## ⚠️ 每一组都是【即时生效】的：点下去立刻改后端，没有「应用」按钮。
##    设置项少到一个屏能看完时，「应用」只是多一次误操作的机会。
## ⚠️ 窗高是**按内容反推**的（`_fit_height`）—— 别手写高度：
##    写死的后果是本工程已经踩过两次的「窗底一条填不满的死白」。

signal background_changed(id: String)
signal mood_changed(mode: int)
signal fog_toggled(on: bool)
signal range_rings_toggled(on: bool)
signal board_toggled(on: bool)
signal camera_reset_requested()
signal run_restart_requested()
## 「放弃本局 · 回主界面」——离开这一局、回主菜单。由主控切场景。
## ⚠️ 目前**没有存档**，所以按钮文案必须把"放弃本局"写出来，
##    不能只写"返回主界面" —— 那会让人以为进度还在。
signal back_to_menu_requested()

## 暂停 / 继续。`on = true` 请求暂停。
##
## ⚠️ 这是**请求**不是命令：主控（`EveBattleScene.set_paused`）才是真相源，
##    它会把结果用 `set_paused()` 回写到这里（键盘空格走的是另一条路，
##    按钮必须跟着变，否则出现「场上停着、按钮写着暂停」）。
signal pause_toggled(on: bool)
## 音量改动。`kind` = &"master" / &"sfx" / &"amb" / &"music"，`v` ∈ [0,1]
signal volume_changed(kind: StringName, v: float)
## 静音开关
signal mute_toggled(on: bool)
## ★ 界面缩放档（2026-10-07）。值 = **存档原值**（0 = 自动）。
## ⚠️ 只发「玩家点了哪一个」，解析成倍数由 `EveUiScale.resolve()` 负责 ——
##    档位表只有一份，窗里不再抄第二份。
signal ui_scale_changed(saved: float)
## ★ 字号缩放变了（`1.0` = 设计字号）。值已经**由本窗应用到全树**（`FONT.reapply`），
## 这个信号是给 HUD 的：「底部两条要按新字高重新上抬」（见 `EveHudRoot.SHOP_FONT_GROW`）。
signal font_scale_changed(v: float)
## ★ 分辨率档变了（2026-10-07）。值 = **档位下标**（`EveResolution.CHOICES`）。
## ⚠️ 窗口尺寸**本窗自己就改了**（`EveResolution.apply_index`）—— 这个信号是给
##    「拿不到窗口的持有者」的：HUD 要重铺（居中偏移变了）、牌桌要重绘。
##    ⛔ 别在接收方再改一次窗口尺寸（两次改动之间会闪一帧）。
signal resolution_changed(idx: int)

## ══════════════════════════════════════════════════════════════════
##  场景档案：**同一扇设置窗，两套内容**
## ══════════════════════════════════════════════════════════════════
##
## 2026-10-07 用户：「我发现斗地主页面没有基本的设置，看看能不能把守卫边境的设置搬过去」。
##
## ⚠️ 「搬过去」不能是**整扇照搬** —— 战场的「暂停 / 空间雾 / 射程环 / 棋盘 /
##    相机复位 / 重开一局」在牌桌上**没有对应物**，照搬过去就是一排
##    「看着能点、点了没反应」的死按钮（工程红线 9，本文件顶注也写过同一条）。
## ⇒ 按场景**条件构建**：
##    · `battle`（守卫边境 / 战场）：完整设置，一字不改
##    · `lounge`（娱乐总汇 / 牌桌）：音频 · 显示 · 界面 · 返回主界面
##
## ⚠️ 是「**不构建**」而不是「灰掉/禁用」：禁用态会在正式版里留下一排
##    永远点不动的按钮，比没有更糟（同一个理由见「系统 DEBUG」那一段）。
const PROFILE_BATTLE := "battle"
const PROFILE_LOUNGE := "lounge"
## ★ 2026-10-10 主界面（大厅主菜单）档案。
##
## ⚠️ 它 = 「音频 + 显示」，**没有**「界面·字号」与「操作」两块：
##    · 字号：主菜单按 1920×1080 **死坐标**排、恒定 100%（`FONT.reset_scale`）——
##      给滑块就地 `reapply` 会把 62px 的模式按钮撑破（见 EveFont 顶注）。
##      字号偏好仍在设置里，进战场 / 牌桌时 `load_from_settings()` 读回生效。
##    · 操作：那一块是「相机复位/重开/离开这一局·回主界面」——我们**就在**主界面
##      ⇒ 一个对应物都没有，建出来就是一排死按钮（红线 9）。
const PROFILE_MENU := "menu"

## 本窗的档案。**建 UI 之前**设好（`_build_contents` 读它决定建哪些分区）。
var profile := PROFILE_BATTLE


func _is_battle() -> bool:
	return profile == PROFILE_BATTLE


## 主界面档案：没有「界面·字号」（菜单恒定 100%），也没有「操作 / 返回主界面」
## （我们就在主界面）。见 `PROFILE_MENU` 的说明。
func _is_menu() -> bool:
	return profile == PROFILE_MENU

## ⚠️ DEBUG-ONLY: 调试期加币按钮。
##
## ★ 2026-10-30（用户定案）：「以后导出的都带 debug，把那个加星币的选项加回来，
##   直到我要你取消」。
##   ⇒ 开关不再是 `OS.has_feature("release")`（那个由导出配置决定，改起来要动预设），
##     而是**这一个常量**：`true` = 正式包也建这块；用户说取消时把它翻成 `false` 即可。
##   ⛔ 别再把它绑回 release 特征 —— 两边会打架，而且线上包里到底有没有、谁都说不准。
const SHOW_DEBUG_COINS := true

## 加币按钮的档位（点一下直接 +N 星币）。
const DEBUG_COIN_STEPS: Array[int] = [100, 300, 999]

## 加 300 星币让玩家在不动现有结构的前提下快速测试经济路径
##   （买经验、超频、刷新、打捞都更顺）。
##   彻底删的时候一并删：① 本 signal ② 本组按钮构建块 ③ eve_hud_root 里的 connect
##   ④ eve_battle_scene 里的 handler（如果加了）⑤ `add_coins_requested` 的所有 grep 引用。
signal add_coins_requested(amount: int)
signal closed()
## ★ 2026-10-10 i18n：玩家切换了界面语言（`code` = 新 locale）。
## ⚠️ 发出后本窗会**重载当前场景** —— 文案是建 UI 时取词的，
##    只有重建才能全部换语言（见 `_pick_language`）。
signal language_changed(code: String)

## 当前天空盒候选（与 EveBattleArena 的 background_id 导出枚举同源）。
##
## ⚠️ 这里只列 4 个有代表性的，不是全部 —— 设置窗是「换一张看看」，
##    不是素材浏览器。真正的全表在 eve_background_library.gd。
##    加新背景时**优先改这里**（而不是在别处再抄一份列表）。
const BACKGROUNDS: Array = [
	{"id": "caldari_c07", "name": "加达里 C07"},
	{"id": "caldari_c02", "name": "加达里 C02"},
	{"id": "gallente_g03", "name": "盖伦特 G03"},
	{"id": "amarr_a03", "name": "艾玛 A03"},
]

const MOODS: Array = [
	{"v": 0, "name": "通透"},
	{"v": 1, "name": "氛围"},
]

## ★ 2026-10-10 「重置」区那行说明的默认文案。
## ⚠️ 必须**短**：它和按钮同一行，窗宽只有 320（见 `_build_contents` 里的说明）。
##    点了重置会临时换成「✓ 已恢复默认」，开窗时换回。
const RESET_NOTE_HINT := "Ctrl + F11"

## 设置持久化。
##
## ⚠️ 用 `preload` 而不是直接写类名：全局 class_name 要等 `.godot` 重新扫描
##    才注册得上，而 preload 是**显式依赖**，任何时候都能解析 ——
##    少一层「必须记得跑 --import」的隐性前提。
const STORE := preload("res://scripts/core/eve_settings_store.gd")
## UI 缩放档的取值域与解析（唯一真相源）
const UI_SCALE_SCRIPT := preload("res://scripts/ui/eve_ui_scale.gd")
## ★ 窗口分辨率档（唯一真相源）。⚠️ 只在**桌面端**生效。
const RESOLUTION_SCRIPT := preload("res://scripts/ui/eve_resolution.gd")
## ★ 2026-10-10 i18n：玩家可见文案一律从这里取（见 eve_text.gd 顶注）。
const T := preload("res://scripts/core/eve_text.gd")
## 切语言要重载场景；战场上重载前得先置「继续上一局」。
const RUN_STORE := preload("res://scripts/core/eve_run_store.gd")

## 音量的四档 —— 顺序 = 窗里的顺序，键 = `EveAudio.set_volume` 的 kind。
##
## ⚠️ 「总音量」走 Master 总线（三条分总线都是它的下游），
##    所以它不是「三条的平均值」而是一个真正的上游总闸。
const VOLUME_KINDS: Array = [
	{"k": &"master", "name": "总音量"},
	{"k": &"sfx", "name": "音效"},
	{"k": &"amb", "name": "环境"},
	{"k": &"music", "name": "音乐"},
]

## 单选组的按钮引用 —— 每项 = {"btns": Array[Button], "apply": Callable(index)}
var _groups: Array[Dictionary] = []
var _bg_btns: Array[Button] = []
var _mood_btns: Array[Button] = []
## 缩放档按钮（**只有移动端才建** ⇒ 桌面端这里是空的，别当成 bug）
var _scale_btns: Array[Button] = []
## 分辨率档按钮（**只有桌面端才建** ⇒ 移动端这里是空的，别当成 bug）
## ⚠️ 顺序 = [自适应] + `CHOICES` ⇒ **下标比 CHOICES 大 1**（见 `set_resolution`）。
var _res_btns: Array[Button] = []
## ★ 2026-11-08 分辨率块下面那行小字。
##
## ⚠️ 必须留引用：全屏 / 最大化下分辨率档的**语义变了**（只调 3D 清晰度、
##    不动窗口，见 `EveResolution.MIN_RENDER_SCALE` 顶注）。玩家不看这一行
##    会发现"点了没变化"，只会当成**按钮坏了**（红线 9）。
var _res_note: Label = null
## ★ 2026-10-10 「重置」区那行说明（默认显示快捷键提示，点过重置后变成「已恢复」）。
var _reset_note: Label = null
## 本窗认为的缩放档（存档原值，0 = 自动）
var _cur_ui_scale := 0.0
## 二态开关（雾 / 射程环 / 棋盘 / 静音）—— 值存在这里，刷新时按值上皮肤
var _toggles: Dictionary = {}
## 音量滑杆 —— key = kind，值 = {"slider": HSlider, "num": Label}
var _sliders: Dictionary = {}

var _cur_bg: String = "caldari_c07"
var _cur_mood: int = 0
## 「字号」滑杆行（{"row","slider","num"}）—— 桌面端也有，所以不是空字典
var _font_slider: Dictionary = {}
## 本窗认为的暂停态。只在 `set_paused()` 里被改（主控回写）。
var _paused := false

var _pause_btn: Button = null
## 「语言」行的按钮（**单行**：标签与按钮同排，见 `_build_display_rows` 的说明）
var _lang_btns: Array[Button] = []
## 防重入：切语言会重载场景，重载前后可能各触发一次 pressed
var _lang_pick_guard := false
## DEBUG 区（默认收起）—— 常驻显示的话，一个正式设置窗里挂着加币按钮很出戏
var _dbg_box: VBoxContainer = null
var _dbg_btn: Button = null
## ★ 2026-10-13 横向栏目态（手机专用布局）开关。
##   ⚠️ 两个写入方：`_ready` 自判据（`EveUiScale.is_mobile_tier`，唯一真源）
##     与 HUD 每次重铺时的 `set_tabbed()`（兜底：切档位 / 自检开闸）。
var _tabbed := false
## 栏目顺序与文案（键 = 组盒在 `_tab_boxes` 里的键）
const TAB_ORDER: Array[String] = ["video", "audio", "ui", "game"]
var _tab_btns: Array[Dictionary] = []     ## [{"key": String, "btn": Button}]
var _tab_boxes: Dictionary = {}           ## key → VBoxContainer
var _cur_tab := "video"
## 最近一次 `set_state()` 的入参 —— 重建内容后按它回写，免得开关/滑杆跳回默认值
var _last_state: Dictionary = {}


func _ready() -> void:
	# ⚠️ 标题也会被 i18n 化 ⇒ 它**不能**当布局存档键（见 hud_root 里的 layout_key）。
	window_title = T.t(&"SETTINGS_TITLE", "设置")
	density = Density.COMPACT
	# ★ 2026-10-10：标题栏右上角给一枚 ✕（在折叠按钮**右边**）。
	#   设置窗是「点开就为一个目的」的窗 —— 此前只能靠再点一次顶条 ≡ 或 ESC
	#   关掉，玩家第一眼是找不到出口的。⚠️ 必须在 `super._ready()` **之前**设，
	#   因为基类的 `_build()` 读 `closable` 决定建不建那枚按钮。
	closable = true
	# ⚠️★ 2026-10-10 i18n：**布局存档键必须与文案脱钩**。
	#   `EveWindow._layout_key()` 在 `layout_key` 为空时回落到 `window_title`，
	#   而标题现在会被 i18n 化 ⇒ 空着的话「切一次语言 = 这扇窗的布局键跟着变
	#   = 玩家摆好的窗口位置丢失」。按档案推导一个稳定的键（三个档案各自一个位，
	#   与牌桌 / 主菜单以前手写的那两个键**同名** ⇒ 不需要迁移）。
	if layout_key == "":
		layout_key = "%s_settings" % profile
	# 按钮按下 ⇒ 复用本窗**已有**的 `closed` 信号（HUD 早就把它接到 hide_settings 了）。
	close_requested.connect(func() -> void: closed.emit())
	# ★ 高度由内容反推（见 `_fit_height`）⇒ 允许它高过设计稿的 480，
	#   摆位时由基类把它上移进屏（否则底部会被切掉）。
	fit_in_viewport = true
	super._ready()
	# ★ 2026-10-10 Ctrl+F11 = 恢复默认设置：**显式**开启 unhandled_input，
	#   不依赖"脚本定义了 `_unhandled_input` 引擎就自动开"这条隐式规则。
	#   ⚠️ `_unhandled_input` 不受 `visible` 影响 ⇒ 窗关着也按得到（救命键的关键）。
	set_process_unhandled_input(true)
	# ★ 2026-10-13：手机专用布局 ⇒ 设置窗改横向栏目（视频/音频/界面/游戏）。
	#   ★ 同日用户定：「把设置更新也同步改到PC端」⇒ **全平台栏目态** ——
	#     PC 与手机同一骨架（栏目 → 滚动内容 → 常驻底栏），矩形由各持有方给
	#     （战场 HUD `settings_rect()` / 牌桌与主菜单 `_place_settings()`）。
	#     ⛔ 竖向 `_build_contents()` 保留但不再走（`set_tabbed(false)` 仍可手动回退）。
	_tabbed = true
	_build_contents()
	set_paused(false)
	#
	# ⚠️ 窗高按内容反推，但**必须等布局稳定**才量得准 ——
	#    `_build_contents()` 刚跑完时窗口宽度还是 0（hud 的 `set_window_rect`
	#    在 `add_child` 之后才执行），而带 autowrap / 自动换行的控件的最小高度
	#    **取决于当时拿到的宽度**：0 宽 ⇒ 折成几十行 ⇒ 量出 800+px ⇒
	#    窗被撑到 919px、底部留 390px 空白（用户 2026-09-29 实测报的就是这个）。
	#    等两帧：第一帧宽度就位、第二帧各控件的 minimum size 缓存刷新完。
	await get_tree().process_frame
	await get_tree().process_frame
	_fit_height()


## 把 `[{"id"/"k"/"v": ..., "name": 中文}]` 这类表的**显示名**过一遍 i18n。
##
## ★ 数据表（BACKGROUNDS / MOODS / VOLUME_KINDS）里**保持中文源文**：
##   中文既是兜底也是活文档，**渲染时**才过一遍 `T.t()`
##   ⇒ 加语言不用改数据表，改数据表也不用碰 i18n。
## ⚠️ `id_field` 一律取 ASCII 稳定标识（⛔ 别用中文当 key 的一部分）。
## ⚠️⚠️ **用 `str()` 不是 `String()`**：`MOODS` 的 `v` 是 `int`，而 GDScript 的
##    `String()` 构造函数**不接 int**（实测 `String(0)` ⇒
##    `Invalid call 'String' constructor`）—— 开窗时才炸，中文版也一样。
static func _names(items: Array, key_prefix: String, id_field := "id") -> Array:
	var out: Array = []
	for it in items:
		var d: Dictionary = (it as Dictionary).duplicate()
		d["name"] = T.t("%s_%s" % [key_prefix, str(d[id_field]).to_upper()],
				String(d["name"]))
		out.append(d)
	return out


## 界面缩放档：只有「自动」需要翻译（`100%` / `115%` 中英文一样）。
static func _ui_scale_items() -> Array:
	var out: Array = []
	for c in UI_SCALE_SCRIPT.CHOICES:
		var d: Dictionary = (c as Dictionary).duplicate()
		if float(d["v"]) == 0.0:
			d["name"] = T.t("SET_UISCALE_AUTO", String(d["name"]))
		out.append(d)
	return out


func _build_contents() -> void:
	content.add_theme_constant_override("separation", 7)
	# ★ 2026-10-13：手机专用布局 ⇒ 横向栏目（视频/音频/界面/游戏）；
	#   桌面档 / 牌桌 / 主菜单 ⇒ 老长条（⛔ PC 路径一个像素都不动）。
	if _tabbed:
		_build_tabbed()
		return
	_build_vertical()


## ⛔ **PC 路径**（桌面档 / 牌桌 / 主菜单）：分区顺序与 2026-09-28 重构版
##    逐行一致 —— 改这里 = 改 Windows 端像素。
## ⛔ **PC 路径**（桌面档 / 牌桌 / 主菜单）：分区顺序与 2026-09-28 重构版
##    逐行一致 —— 改这里 = 改 Windows 端像素。
##
## ⚠️ 每个分区都是 `_sec_*` 构建器（与横向栏目版共用同一批代码），
##    分区之间的分隔线在这里**显式**加 —— 栏目版每组自己一页，不需要。
func _build_vertical() -> void:
	_sec_pause(content)              # ⓪（内部含尾部分隔线）
	_sec_audio(content)              # ①
	content.add_child(make_divider())
	_sec_display(content)            # ②（`_build_display_rows` 自带尾部分隔线）
	if not _is_menu():
		_sec_interface(content)      # ③
		content.add_child(make_divider())
	if _is_battle():
		_sec_render(content)         # ④
		content.add_child(make_divider())
		_sec_battle_ui(content)      # ⑤
		content.add_child(make_divider())
	if not _is_menu():
		_sec_action(content)         # ⑥
	_sec_debug(content)              # ⑦（内部含首部分隔线；发布版整块跳过）
	_sec_reset(content)              # ⑧（内部含首部分隔线）
	_sec_hint(content)


## ★★ 2026-10-13 横向栏目态（手机专用布局）—— 视频 / 音频 / 界面 / 游戏。
##
## 为什么必须有它：竖向长条在手机档实测约 **900** 高，而设计高只有 800
## （1.35 放大档）⇒ 必然出屏（用户原话：「设置栏太长了，已经超出屏幕了」）。
## 评审稿（`outputs/android_ui_review/index_v2.html` 状态 2）定的形态：
##   · 窗高**定死**（HUD 矩形给 560）⇒「栏目只切换内容，不改变设置窗高度」；
##   · 内容区自己滚（ScrollContainer）⇒ 单页再长也撑不破窗；
##   · 没有内容的组**整个不建** ⇒ 栏目按钮也不建（⛔ 不留点不动的空栏目）；
##   · 暂停按钮留在栏目**之上** —— 它是唯一会被急用的东西，埋进栏目等于没有；
##   · 底栏常驻「恢复默认 + 完成」。
func _build_tabbed() -> void:
	# ★ 安卓线：移动端用**左侧竖排标签 + 右侧滚动 + 底部固定栏**，
	#   而不是把桌面那排小 tab 拉横。桌面路径继续走下面原逻辑（像素不变）。
	if UI_SCALE_SCRIPT.is_mobile():
		_build_tabbed_mobile()
		return
	if _is_battle():
		_sec_pause(content)
	# ── 栏目行（先占位；盒子灌完内容再建按钮，空组不建钮）──
	var tabs := HBoxContainer.new()
	tabs.name = "Tabs"
	tabs.add_theme_constant_override("separation", 4)
	tabs.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(tabs)
	# ── 内容滚动区 ──
	var scroll := ScrollContainer.new()
	scroll.name = "TabScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)
	widen_scrollbar(scroll)
	for key in TAB_ORDER:
		var box := VBoxContainer.new()
		box.name = "Tab_%s" % key
		box.add_theme_constant_override("separation", 7)
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.visible = false
		scroll.add_child(box)
		_tab_boxes[key] = box
	# ── 灌内容（按档案条件构建，与竖向版同一批 `_sec_*`）──
	# ★ 2026-10-13 三方统一后的栏目表（空组不建栏目钮）：
	#   战场   视频 / 音频 / 界面 / 游戏（操作·DEBUG·快捷键；**返回→底栏**）
	#   牌桌   音频 / 界面（显示+字号+说明；操作区只剩返回 ⇒ 整页不建，返回→底栏）
	#   主菜单 音频 / 界面（显示+说明；无字号、无操作、无返回）
	if _is_battle():
		_sec_render(_tab_boxes["video"])          # 天空盒 / 氛围
		_sec_battle_ui(_tab_boxes["video"])       # 空间雾 / 射程环 / 棋盘
	_sec_audio(_tab_boxes["audio"])
	_sec_display(_tab_boxes["ui"])                # 分辨率(桌面) / 界面缩放(手机) / 语言
	if not _is_menu():
		_sec_interface(_tab_boxes["ui"])          # 字号
	if _is_battle():
		# ── 游戏页：操作（不含返回——回底栏）+ DEBUG + 快捷键 ──
		_sec_action(_tab_boxes["game"], false)
		if not OS.has_feature("release"):
			_sec_debug(_tab_boxes["game"])
		_sec_hint(_tab_boxes["game"])             # 快捷键备忘
	else:
		# 牌桌 / 主菜单：说明行跟着界面页（牌桌操作区只剩返回 ⇒ 无游戏页）
		_sec_hint(_tab_boxes["ui"])
	# ── 栏目按钮（只给有内容的组建）──
	_tab_btns.clear()
	for key in TAB_ORDER:
		var box: VBoxContainer = _tab_boxes[key]
		if box.get_child_count() == 0:
			continue
		var b := _mk_btn(_tab_label(key))
		b.custom_minimum_size = Vector2(0, 26)
		b.set_meta(&"tab", key)
		b.pressed.connect(_on_tab_pressed.bind(key))
		tabs.add_child(b)
		_tab_btns.append({"key": key, "btn": b})
	# ── 底栏（常驻，不随栏目藏）：[放弃本局·回主界面] + 恢复默认 + 说明 + 完成 ──
	# ★ 2026-10-13 返回主菜单常驻底栏（用户：「返回主菜单按钮…常驻首页，
	#   要能很方便的点到才行」）：从「游戏」栏目提到底栏 —— 开窗即见、一步点到，
	#   与斗地主/战场同一位置同一手感。
	#   ⚠️ 它是破坏性动作（放弃本局/退出牌桌）⇒ **warn 橙皮肤** + 文案写全防误触。
	#   ⚠️ 主菜单档案不建（我们就在主界面，没有"回去"可言）。
	var foot := HBoxContainer.new()
	foot.name = "Foot"
	foot.add_theme_constant_override("separation", 8)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(foot)
	if not _is_menu():
		var back_btn := _mk_btn(T.t("SET_ACT_BACK_BATTLE", "放弃本局 · 回主界面")
				if _is_battle() else T.t("SET_ACT_BACK_LOUNGE", "返回主界面"))
		EveButtonTheme.apply(back_btn, "hud_warn")
		back_btn.custom_minimum_size = Vector2(0, 30)
		back_btn.pressed.connect(func(): back_to_menu_requested.emit())
		foot.add_child(back_btn)
	var reset_btn := _mk_btn(T.t(&"SETTINGS_RESET", "恢复默认设置"))
	reset_btn.custom_minimum_size = Vector2(0, 30)
	reset_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # 给说明留位
	reset_btn.pressed.connect(reset_to_defaults)
	foot.add_child(reset_btn)
	# ⚠️ 说明**复用 `_reset_note` 字段**：`reset_to_defaults()` 回写的就是它
	_reset_note = Label.new()
	_reset_note.text = RESET_NOTE_HINT
	_reset_note.add_theme_color_override("font_color", C_TEXT_FAINT)
	FONT.fs(_reset_note, 9)
	_reset_note.autowrap_mode = TextServer.AUTOWRAP_OFF
	_reset_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reset_note.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	foot.add_child(_reset_note)
	var done_btn := _mk_btn(T.t("SET_DONE", "完成"))
	done_btn.custom_minimum_size = Vector2(0, 30)
	EveButtonTheme.apply(done_btn, "hud_main")
	done_btn.pressed.connect(func(): closed.emit())
	foot.add_child(done_btn)
	# 默认落在线第一个有内容的组
	_show_tab(String(_tab_btns[0]["key"]) if not _tab_btns.is_empty() else "video")


## 移动端栏目结构：左侧大标签栏 + 右侧滚动内容 + 底部固定操作栏。
##
## ★ 为什么不是「把桌面 tab 行拉宽」：手机上顶部横排 tab 离拇指远、字号小；
##   竖排标签在左手拇指弧内，且能做得很大。内容区独立滚动，底部「完成」常驻。
func _build_tabbed_mobile() -> void:
	content.add_theme_constant_override("separation", 16)
	if _is_battle():
		_sec_pause(content)

	var body := HBoxContainer.new()
	body.name = "MobileBody"
	body.add_theme_constant_override("separation", 24)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(body)

	var rail := VBoxContainer.new()
	rail.name = "TabRail"
	rail.custom_minimum_size = Vector2(300, 0)
	rail.add_theme_constant_override("separation", 12)
	rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(rail)

	var scroll := ScrollContainer.new()
	scroll.name = "TabScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(scroll)
	widen_scrollbar(scroll)

	for key in TAB_ORDER:
		var box := VBoxContainer.new()
		box.name = "Tab_%s" % key
		box.add_theme_constant_override("separation", 18)
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.visible = false
		scroll.add_child(box)
		_tab_boxes[key] = box

	# 与桌面栏目版同一批 `_sec_*`，只是排布不同。
	if _is_battle():
		_sec_render(_tab_boxes["video"])
		_sec_battle_ui(_tab_boxes["video"])
	_sec_audio(_tab_boxes["audio"])
	_sec_display(_tab_boxes["ui"])
	if not _is_menu():
		_sec_interface(_tab_boxes["ui"])
	if _is_battle():
		_sec_action(_tab_boxes["game"], false)
		if not OS.has_feature("release"):
			_sec_debug(_tab_boxes["game"])
		_sec_hint(_tab_boxes["game"])
	else:
		_sec_hint(_tab_boxes["ui"])

	# 左侧标签：大按钮，选中态 hud_main。
	_tab_btns.clear()
	for key in TAB_ORDER:
		var bx: VBoxContainer = _tab_boxes[key]
		if bx.get_child_count() == 0:
			continue
		var b := _mk_btn(_tab_label(key))
		b.custom_minimum_size = Vector2(300, 98)
		b.size_flags_horizontal = Control.SIZE_FILL
		FONT.fs(b, 27)
		b.set_meta(&"tab", key)
		b.pressed.connect(_on_tab_pressed.bind(key))
		rail.add_child(b)
		_tab_btns.append({"key": key, "btn": b})

	# 底部固定操作栏：返回（非主菜单）/ 恢复默认 / 完成。
	var foot := HBoxContainer.new()
	foot.name = "Foot"
	foot.add_theme_constant_override("separation", 16)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(foot)
	if not _is_menu():
		var back_btn := _mk_btn(T.t("SET_ACT_BACK_BATTLE", "放弃本局 · 回主界面")
				if _is_battle() else T.t("SET_ACT_BACK_LOUNGE", "返回主界面"))
		EveButtonTheme.apply(back_btn, "hud_warn")
		back_btn.custom_minimum_size = Vector2(300, 88)
		back_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		back_btn.pressed.connect(func(): back_to_menu_requested.emit())
		foot.add_child(back_btn)
	var reset_btn := _mk_btn(T.t(&"SETTINGS_RESET", "恢复默认设置"))
	reset_btn.custom_minimum_size = Vector2(300, 88)
	FONT.fs(reset_btn, 24)
	reset_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	reset_btn.pressed.connect(reset_to_defaults)
	foot.add_child(reset_btn)
	# ⚠️ `reset_to_defaults()` 会回写 `_reset_note`；移动端不显示 Ctrl+F11 提示，
	#   但字段必须存在（否则空指针）。建一个隐藏 Label 兜住。
	_reset_note = Label.new()
	_reset_note.visible = false
	var done_btn := _mk_btn(T.t("SET_DONE", "完成"))
	done_btn.custom_minimum_size = Vector2(0, 88)
	FONT.fs(done_btn, 24)
	done_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	EveButtonTheme.apply(done_btn, "hud_main")
	done_btn.pressed.connect(func(): closed.emit())
	foot.add_child(done_btn)

	_show_tab(String(_tab_btns[0]["key"]) if not _tab_btns.is_empty() else "video")


## 栏目文案。⛔ i18n 冻结期**不进 CSV**：`T.t` 对未登记 key 返回调用点给的
##    中文源文（全工程同款写法，`verify_i18n` 有兜底用例）。解冻时补 4 条
##    `SET_TAB_*` 即可 —— 现在不加行（冻结令）。
const TAB_LABELS := {"video": "视频", "audio": "音频", "ui": "界面", "game": "游戏"}

func _tab_label(key: String) -> String:
	return T.t("SET_TAB_%s" % key.to_upper(), String(TAB_LABELS.get(key, key)))


func _on_tab_pressed(key: String) -> void:
	if key != _cur_tab:
		EveUiAudio.play("ui.tab")
	_show_tab(key)


## 切栏目：只切盒子可见性 + 按钮皮肤（⛔ 不重建控件 —— 那会丢滑块/开关的当前值）。
func _show_tab(key: String) -> void:
	if _tab_boxes.is_empty():
		return
	_cur_tab = key
	for k in _tab_boxes.keys():
		var box: VBoxContainer = _tab_boxes[k]
		box.visible = String(k) == key
	for it in _tab_btns:
		var b: Button = it["btn"]
		var on := String(it["key"]) == key
		EveButtonTheme.apply(b, "hud_main" if on else "hud")


# ══════════════════════════════════════════════════════════════════
#  分区构建器（竖向版与栏目版共用）
# ══════════════════════════════════════════════════════════════════
#
## ⚠️ 它们**不**加「分区之间」的分隔线 —— 分隔线由调用方按形态决定：
##    竖向长条要（历史像素），栏目页不要（每组自己就是一页）。
## ⚠️ 每个函数都自带「这个档案没有这块内容」的早退 ⇒ 调用方不用再包一层 if。

## ⓪ 暂停（最顶、最大）—— **只有战场有**。
func _sec_pause(t: VBoxContainer) -> void:
	if not _is_battle():
		return
	_pause_btn = Button.new()
	var mobile := UI_SCALE_SCRIPT.is_mobile()
	_pause_btn.custom_minimum_size = Vector2(0, 72 if mobile else 40)
	_pause_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if mobile:
		FONT.fs(_pause_btn, 20)
	_pause_btn.pressed.connect(func(): pause_toggled.emit(not _paused))
	t.add_child(_pause_btn)
	t.add_child(make_divider())


## ① 音频（**所有档案都有**）。
func _sec_audio(t: VBoxContainer) -> void:
	t.add_child(make_group_header(T.t("SET_GROUP_AUDIO", "音频  AUDIO")))
	for item in _names(VOLUME_KINDS, "SET_VOL", "k"):
		var kind: StringName = item["k"]
		var made := _build_slider_row(String(item["name"]), 1.0,
				func(v: float): _pick_volume(kind, v))
		_sliders[kind] = made
		t.add_child(made["row"])
	var mute_row := HBoxContainer.new()
	mute_row.add_theme_constant_override("separation", 5)
	mute_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mute_row.add_child(_make_toggle("mute", T.t("SET_MUTE", "静音"), func(on: bool):
		STORE.save_one("muted", on)
		mute_toggled.emit(on)))
	t.add_child(mute_row)



## ② 显示（分辨率 / 界面缩放 / 语言）—— 内容随平台变，见 `_build_display_rows`。
func _sec_display(t: VBoxContainer) -> void:
	for r in _build_display_rows():
		t.add_child(r)


## ③ 界面（字号）—— **战斗与牌桌有；主菜单没有**。
func _sec_interface(t: VBoxContainer) -> void:
	if _is_menu():
		return
	t.add_child(make_group_header(T.t("SET_GROUP_INTERFACE", "界面  INTERFACE")))
	_font_slider = _build_slider_row(T.t("SET_FONT_SCALE", "字号"), FONT.scale,
			func(v: float): _pick_font_scale(v),
			FONT.MIN_SCALE, FONT.MAX_SCALE, FONT.STEP)
	t.add_child(_font_slider["row"])


## ④ 画面（天空盒 / 氛围）—— **只有战场有**。
func _sec_render(t: VBoxContainer) -> void:
	if not _is_battle():
		return
	t.add_child(make_group_header(T.t("SET_GROUP_RENDER", "画面  RENDER")))
	var bg := _build_choice_block(_names(BACKGROUNDS, "SET_BG"), "name", 2,
			func(i: int): _pick_background(i))
	var bg_btns: Array = bg["btns"]
	for b in bg_btns:
		_bg_btns.append(b as Button)
	var bg_rows: Array = bg["rows"]
	for r in bg_rows:
		t.add_child(r)
	var mood := _build_choice_block(_names(MOODS, "SET_MOOD", "v"), "name", 2,
			func(i: int): _pick_mood(i))
	var mood_btns: Array = mood["btns"]
	for b in mood_btns:
		_mood_btns.append(b as Button)
	var mood_rows: Array = mood["rows"]
	for r in mood_rows:
		t.add_child(r)


## ⑤ 战斗界面（空间雾 / 射程环 / 棋盘）—— **只有战场有**。
func _sec_battle_ui(t: VBoxContainer) -> void:
	if not _is_battle():
		return
	t.add_child(make_group_header(T.t("SET_GROUP_BATTLE_UI", "战斗界面  BATTLE UI")))
	var toggles := HBoxContainer.new()
	toggles.add_theme_constant_override("separation", 5)
	toggles.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toggles.add_child(_make_toggle("fog", T.t("SET_TOGGLE_FOG", "空间雾"), func(on: bool):
		fog_toggled.emit(on)))
	toggles.add_child(_make_toggle("rings", T.t("SET_TOGGLE_RINGS", "射程环"), func(on: bool):
		range_rings_toggled.emit(on)))
	toggles.add_child(_make_toggle("board", T.t("SET_TOGGLE_BOARD", "棋盘"), func(on: bool):
		board_toggled.emit(on)))
	t.add_child(toggles)


## ⑥ 操作（不是开关，是「做一件事」）—— **战斗与牌桌有；主菜单没有**。
##
## ⚠️ `with_back`：栏目态传 **false** —— 返回主菜单已常驻**底栏**（2026-10-13 用户定），
##    栏目页里再放一个是重复入口。竖向（PC）路径保持默认 true，逐像素不动。
func _sec_action(t: VBoxContainer, with_back := true) -> void:
	if _is_menu():
		return
	# 牌桌去掉返回后这一区就空了 ⇒ 整块不建（红线：不留看着能点的死区）
	if not _is_battle() and not with_back:
		return
	t.add_child(make_group_header(T.t("SET_GROUP_ACTION", "操作  ACTION")))
	if _is_battle():
		var acts := HBoxContainer.new()
		acts.add_theme_constant_override("separation", 5)
		acts.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var cam_btn := _mk_btn(T.t("SET_ACT_CAMERA", "相机复位"))
		cam_btn.pressed.connect(func(): camera_reset_requested.emit())
		acts.add_child(cam_btn)
		var restart_btn := _mk_btn(T.t("SET_ACT_RESTART", "重开一局"))
		EveButtonTheme.apply(restart_btn, "hud_warn")
		restart_btn.pressed.connect(func(): run_restart_requested.emit())
		acts.add_child(restart_btn)
		t.add_child(acts)
	if with_back:
		var back_row := HBoxContainer.new()
		back_row.add_theme_constant_override("separation", 5)
		back_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var menu_btn := _mk_btn(T.t("SET_ACT_BACK_BATTLE", "放弃本局 · 回主界面")
				if _is_battle() else T.t("SET_ACT_BACK_LOUNGE", "返回主界面"))
		menu_btn.pressed.connect(func(): back_to_menu_requested.emit())
		back_row.add_child(menu_btn)
		t.add_child(back_row)


## ⑦ 系统（DEBUG 默认折叠）—— **只有战场有**。
##   ★ 2026-10-30：门禁从 `not OS.has_feature("release")` 改成常量 `SHOW_DEBUG_COINS`
##     ⇒ 导出包（含 release）也有这块，直到用户说取消。
func _sec_debug(t: VBoxContainer) -> void:
	if not (_is_battle() and SHOW_DEBUG_COINS):
		return
	t.add_child(make_divider())
	t.add_child(make_group_header(T.t("SET_GROUP_SYSTEM", "系统  SYSTEM")))
	_dbg_btn = Button.new()
	_dbg_btn.custom_minimum_size = Vector2(0, 64 if UI_SCALE_SCRIPT.is_mobile() else 20)
	_dbg_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if UI_SCALE_SCRIPT.is_mobile():
		FONT.fs(_dbg_btn, 18)
	_dbg_btn.pressed.connect(func():
		_set_debug_open(_dbg_box == null or not _dbg_box.visible))
	t.add_child(_dbg_btn)
	_dbg_box = VBoxContainer.new()
	_dbg_box.add_theme_constant_override("separation", 5)
	_dbg_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dbg := HBoxContainer.new()
	dbg.add_theme_constant_override("separation", 5)
	dbg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for amt in DEBUG_COIN_STEPS:
		var b := _mk_btn(T.t("SET_DEBUG_COINS", "+%d 星币") % amt)
		b.pressed.connect(func(a = amt): add_coins_requested.emit(a))
		dbg.add_child(b)
	_dbg_box.add_child(dbg)
	t.add_child(_dbg_box)
	# ⚠️ 传 false：此刻窗口宽度可能还没定，反推高度会拿到垃圾值
	_set_debug_open(false, false)


## ⑧ 重置（**所有档案都有**）—— 竖向长条形态；栏目态的重置在底栏。
func _sec_reset(t: VBoxContainer) -> void:
	t.add_child(make_divider())
	t.add_child(make_group_header(T.t("SET_GROUP_RESET", "重置  RESET")))
	var reset_row := HBoxContainer.new()
	reset_row.add_theme_constant_override("separation", 8)
	reset_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var reset_btn := _mk_btn(T.t(&"SETTINGS_RESET", "恢复默认设置"))
	reset_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # 别撑满，给说明留位
	reset_btn.pressed.connect(reset_to_defaults)
	reset_row.add_child(reset_btn)
	_reset_note = Label.new()
	_reset_note.text = RESET_NOTE_HINT
	_reset_note.add_theme_color_override("font_color", C_TEXT_FAINT)
	FONT.fs(_reset_note, 9)
	_reset_note.autowrap_mode = TextServer.AUTOWRAP_OFF
	_reset_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	reset_row.add_child(_reset_note)
	t.add_child(reset_row)


## 快捷键备忘 —— 设置窗的一大价值就是「让隐藏操作变得可发现」。
func _sec_hint(t: VBoxContainer) -> void:
	var hint := Label.new()
	var hint_text := T.t("SET_HINT_BATTLE",
				"快捷键  空格 暂停/继续 · C 相机复位 · B 棋盘 · R 重开")
	if _is_menu():
		hint_text = (T.t("SET_HINT_MENU_DESKTOP",
						"音量与分辨率即时生效；主界面为固定版面，字号沿用战斗设置")
					if RESOLUTION_SCRIPT.is_enabled()
					else T.t("SET_HINT_MENU_MOBILE",
						"音量即时生效；界面缩放与字号在战斗中生效（主界面为固定版面）"))
	elif not _is_battle():
		hint_text = T.t("SET_HINT_LOUNGE", "分辨率与字号即时生效；牌桌不参与「界面缩放」")
	hint.text = hint_text
	hint.add_theme_color_override("font_color", C_TEXT_FAINT)
	FONT.fs(hint, 16 if UI_SCALE_SCRIPT.is_mobile() else 9)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if UI_SCALE_SCRIPT.is_mobile() \
			else TextServer.AUTOWRAP_OFF
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.add_child(hint)


## 「显示 DISPLAY」分区的行（窗口分辨率 / 界面缩放）。
##
## ⚠️ 两块各自**只在对应平台**出现，而且正好互补：
##    · 窗口分辨率：**只桌面端**（手机上全屏，没有可调的余地）
##    · 界面缩放  ：**只移动端**（桌面有窗口尺寸可调，不需要整幅放大）
##   ⇒ 两个平台各看到一块，不会出现"空分区"。
##
## ⚠️ 返回 `Array[Control]`（标题 + 各行的**扁平**列表），调用方直接 add_child。
##    做成"返回行"而不是"自己 add_child"，是为了让 `_build_contents` 里的
##    分区顺序一眼可读 —— 本文件的分区顺序一直在被调整（见顶注）。
func _build_display_rows() -> Array:
	var rows: Array = []
	rows.append(make_group_header(T.t("SET_GROUP_DISPLAY", "显示  DISPLAY")))

	# ★ 2026-10-10 i18n：「语言」。
	# ⏸⏸ **2026-10-11 冻结：英文版现在时机不成熟 ⇒ 这一行整个不建。**
	#    · 开关是 `EveText.LANGUAGE_ENABLED`（唯一真源，当前 false）。
	#      改成 true 这一行就回来 —— 代码一直在，不是删掉的。
	#    · 为什么藏：CSV 的 en 列大量是占位/直译没过审，UI 面也只迁了一半，
	#      玩家切过去只会得到中英混杂的半成品。
	#    · ⛔ 解冻前不要对外宣称支持英文。解冻顺序见 `i18n/README.md` 顶部。
	#    · ⚠️ 藏掉这一行会让窗矮约 28px（内容 ~940 ⇒ ~912），对 `_fit_height`
	#      的上界守卫（视口 92%）是**更安全**的方向，不会切掉底部「重置」。
	if T.LANGUAGE_ENABLED:
		# ⚠️ **刻意压成一行**（标签与按钮同排）：设置窗内容已约 900 高，
		#   而 `_fit_height` 的上界是视口 92%（1080 屏 = 993）——
		#    再多一个「标签行 + 按钮行」就可能被上界守卫拒掉，
		#    表现是窗停在初值、**底部的「重置」被切**（这个坑踩过一次）。
		var lang_row := _new_row(6)
		var lang_lab := Label.new()
		# ⚠️ 标签里带上**当前语言**：这一行的两个按钮不做高亮（窗里没有通用
		#    「选中态」机制），靠文案表示当前值最省事也最不容易看错。
		lang_lab.text = T.t("SET_LANG", "语言 LANGUAGE · %s") % T.locale_label()
		lang_lab.add_theme_color_override("font_color", C_TEXT_DIM)
		FONT.fs(lang_lab, 10)
		lang_lab.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		lang_lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lang_row.add_child(lang_lab)
		_lang_btns.clear()
		for i in T.LOCALES.size():
			var lb := _mk_btn(String(T.LOCALES[i]["name"]))
			lb.pressed.connect(_pick_language.bind(i))
			_lang_btns.append(lb)
			lang_row.add_child(lb)
		rows.append(lang_row)

	if RESOLUTION_SCRIPT.is_enabled():
		# ★ 2026-10-10 「自适应」排在最前（= 视频设置里 "自动/推荐" 的常规位置）。
		#   它的存档哨兵是 `EveResolution.AUTO`（空串），解析成「按屏幕可用区
		#   挑能放下的最大 16:9 档」。
		# ⚠️ ⇒ `_res_btns` 的**下标比 `CHOICES` 大 1**：0 = 自适应，
		#    1..N = `CHOICES[0..N-1]`。见 `set_resolution` / `_pick_resolution`。
		var items: Array = [{"name": T.t("RES_AUTO", RESOLUTION_SCRIPT.AUTO_LABEL)}]
		for i in RESOLUTION_SCRIPT.CHOICES.size():
			items.append({"name": RESOLUTION_SCRIPT.label_of(i)})
		var blk := _build_choice_block(items, "name", 2,
				func(i: int): _pick_resolution(i))
		var btns: Array = blk["btns"]
		for i in btns.size():
			var rb := btns[i] as Button
			# 当前屏幕放不下的档位置灰（选了也会被退回自动档）
			if not RESOLUTION_SCRIPT.fits_screen(i):
				rb.disabled = true
				rb.tooltip_text = "超出当前屏幕"
			_res_btns.append(rb)
		var blk_rows: Array = blk["rows"]
		for r in blk_rows:
			rows.append(r)
		# ⚠️ 说明行必须补：`★` 是**前缀**（理由见 `EveResolution.label_of`），
		#    不解释一下玩家会以为是某种星级。
		# ⚠️ 这一行**必须短**：窗宽只有 320，「太长 + ⛔禁止 autowrap」会直接被裁掉。
		var note := Label.new()
		note.add_theme_color_override("font_color", C_TEXT_FAINT)
		FONT.fs(note, 9)
		note.autowrap_mode = TextServer.AUTOWRAP_OFF
		note.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_res_note = note
		_refresh_res_note()
		rows.append(note)

	if UI_SCALE_SCRIPT.is_enabled():
		var sc := _build_choice_block(_ui_scale_items(), "name", 2,
				func(i: int): _pick_ui_scale(i))
		var sc_btns: Array = sc["btns"]
		for b in sc_btns:
			_scale_btns.append(b as Button)
		var sc_rows: Array = sc["rows"]
		for r in sc_rows:
			rows.append(r)

	rows.append(make_divider())
	return rows


## 分段单选块：一组按钮排成若干行，点谁谁亮。
##
## 返回 {"rows": Array[HBoxContainer], "btns": Array[Button]} ——
## 调用方把 rows 塞进 content（`_bg_btns` 这类引用则单独留着刷皮肤）。
##
## ⚠️ `btns` 的顺序恒等于 `items` 的顺序（与行无关）——
##    verify_run 靠「下标 i ↔ BACKGROUNDS[i]」挑一个不同条目来验证后端，
##    一旦顺序和 items 不一致，验的就是另一张背景（静默的假通过）。
func _build_choice_block(items: Array, label_key: String, cols: int,
		on_pick: Callable) -> Dictionary:
	var rows: Array[HBoxContainer] = []
	var btns: Array[Button] = []
	for i in items.size():
		var b := _mk_btn(String(items[i][label_key]))
		b.pressed.connect(on_pick.bind(i))
		btns.append(b)
		var row_idx := i / maxi(1, cols)
		while rows.size() <= row_idx:
			rows.append(_new_row(4))
		rows[row_idx].add_child(b)
	return {"rows": rows, "btns": btns}


## 滑杆行：标签 + 直角滑杆 + 百分比。
##
## ⚠️ `min_v/max_v/step_v` 默认是**音量口径**（0~1，步进 0.01）；
##    字号那一行传 0.80~1.30 / 0.05（见 `_build_contents` 的字号行）。
##
## 返回 {"row": HBoxContainer, "slider": HSlider, "num": Label}
func _build_slider_row(label: String, value: float, on_change: Callable,
		min_v: float = 0.0, max_v: float = 1.0, step_v: float = 0.01) -> Dictionary:
	var mobile := UI_SCALE_SCRIPT.is_mobile()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14 if mobile else 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.custom_minimum_size = Vector2(0, 98 if mobile else 16)

	var k := Label.new()
	k.text = label
	k.add_theme_color_override("font_color", C_TEXT_DIM)
	FONT.fs(k, 27 if mobile else 11)
	k.custom_minimum_size = Vector2(230 if mobile else 42, 0)
	k.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(k)

	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step_v
	s.value = clampf(value, min_v, max_v)
	s.custom_minimum_size = Vector2(200 if mobile else 90, 62 if mobile else 14)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_style_slider(s)
	row.add_child(s)

	var num := Label.new()
	num.custom_minimum_size = Vector2(140 if mobile else 36, 0)
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	num.add_theme_color_override("font_color", C_TEXT)
	FONT.fs(num, 27 if mobile else 11)
	num.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(num)

	s.value_changed.connect(func(v: float):
		num.text = "%d%%" % int(round(v * 100.0))
		on_change.call(v))
	num.text = "%d%%" % int(round(s.value * 100.0))
	return {"row": row, "slider": s, "num": num}


## 给滑杆套上本工程的皮肤（直角 / 1px 边框 / 青色已填充段）。
##
## ⚠️ 默认 HSlider 是圆角 + 蓝色高亮，和 CheckButton 一样不属于这里的语言。
## ⚠️ Godot 的滑块把手（grabber）是 **icon 不是 stylebox**，
##    所以只能用一张 5×14 的纯色小图，不能给它一个 StyleBoxFlat。
static var _grabber_tex: Texture2D = null


static func _style_slider(s: HSlider) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.10, 0.13, 0.15, 0.92)
	track.border_color = Color(0.42, 0.55, 0.60, 0.40)
	track.set_border_width_all(1)
	track.set_corner_radius_all(0)
	var th := 11 if UI_SCALE_SCRIPT.is_mobile() else 4
	track.content_margin_top = th
	track.content_margin_bottom = th
	s.add_theme_stylebox_override("slider", track)

	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.55, 0.78, 0.82, 0.55)
	fill.set_corner_radius_all(0)
	fill.content_margin_top = 4
	fill.content_margin_bottom = 4
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)

	if _grabber_tex == null:
		var gw := 20 if UI_SCALE_SCRIPT.is_mobile() else 5
		var gh := 48 if UI_SCALE_SCRIPT.is_mobile() else 14
		var img := Image.create(gw, gh, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.55, 0.78, 0.82, 0.95))
		_grabber_tex = ImageTexture.create_from_image(img)
	s.add_theme_icon_override("grabber", _grabber_tex)
	s.add_theme_icon_override("grabber_highlight", _grabber_tex)
	s.add_theme_icon_override("grabber_disabled", _grabber_tex)


func _new_row(sep: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", sep)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return row


func _mk_btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 64 if UI_SCALE_SCRIPT.is_mobile() else 22)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	EveButtonTheme.apply(b, "hud")
	if UI_SCALE_SCRIPT.is_mobile():
		FONT.fs(b, 18)
	return b


## 二态开关按钮。
##
## ⚠️ 用 [开] / [关] 前缀在**文字**里也写出来，不只靠皮肤颜色区分 ——
##    只靠颜色的话，色觉障碍玩家读不出当前状态（而且青/暗这两档对比本来就不大）。
func _make_toggle(key: String, label: String, on_press: Callable) -> Button:
	var b := _mk_btn(label)
	_toggles[key] = {"btn": b, "label": label, "on": false}
	b.pressed.connect(func():
		var st: Dictionary = _toggles[key]
		st["on"] = not bool(st["on"])
		_refresh_toggle(key)
		on_press.call(bool(st["on"])))
	_refresh_toggle(key)
	return b


func _refresh_toggle(key: String) -> void:
	var st: Dictionary = _toggles.get(key, {})
	if st.is_empty():
		return
	var on := bool(st["on"])
	var b: Button = st["btn"]
	b.text = "%s %s" % [T.t("TOGGLE_ON", "[开]") if on else T.t("TOGGLE_OFF", "[关]"),
			String(st["label"])]
	EveButtonTheme.apply(b, "hud_main" if on else "hud")


## DEBUG 折叠。收起时那三个加币按钮连最小高度都不占（VBox 不计隐藏子节点）。
##
## ⚠️ `refit` 参数不是多余的：构建阶段（`_build_contents` 里）窗口**宽度还是 0**，
##    此时反推高度拿到的是垃圾值（而且它会被写进 custom_minimum_size，
##    把后续所有布局都带歪）。构建时传 false，等 `_ready` 里布局稳定后再统一算一次。
func _set_debug_open(open: bool, refit: bool = true) -> void:
	if _dbg_box != null:
		_dbg_box.visible = open
	if _dbg_btn != null:
		_dbg_btn.text = "%s DEBUG（发布时删除）" % ["▾" if open else "▸"]
		EveButtonTheme.apply(_dbg_btn, "hud")
	if refit:
		_fit_height()


## 按内容反推窗高。
##
## ⚠️ 手写高度的后果本工程踩过两次：窗底多出一条填不满的死白
##    （`_content_margin` 拿到 EXPAND 后，富余高度全部堆在 VBox 末尾）。
func _fit_height() -> void:
	if content == null:
		return
	# ★ 横向栏目态：窗高由 HUD 的矩形定（栏目内容区自己滚）。
	#   ⛔ 别按内容反推 —— 那正是这次改版要消灭的「竖向长条一屏装不下」。
	if _tabbed:
		return
	var need: Vector2 = content.get_combined_minimum_size()
	# ⚠️ 宽度还没定（刚建完、还没排过序）时量出来的是垃圾值，直接放弃这一轮
	if need.x <= 0.0:
		return
	# ⚠️ 上界守卫：一个「设置窗」不可能比视口的 **85%** 还高。
	#    量出更大的值只可能是拿错了数（典型：autowrap 控件在 0 宽下折出几十行），
	#    而把它写进 custom_minimum_size 会**永久**把窗撑大 —— 宁可不改、下帧再算。
	#    ⛔ 关键不变量不许用 assert（release 会被剥离），走 push_warning。
	# ★ 2026-10-07 由 60% 放宽到 85%：加了「显示 · 分辨率」14 档（2 列 7 行）之后
	#   设置窗真的变高了（实测内容 **824px**），60% 的 648 会把**正当**的高度也拒掉 ——
	#   表现是窗停在初值、下半截被切掉，而且只报一条 warning。
	#   ⚠️ 放宽不等于失去保护：原来要防的「未布局就量」现在被两道拦住 ——
	#     ① `_ready` 里 `await process_frame` 两次才量；② 下面 `need.x <= 0` 的早退。
	# ★ 2026-10-10 又由 85% 放宽到 92%：再加「重置」区之后，地面档案的内容需求
	#   实测约 **900**，而 85% 在 1080 屏上只有 918 —— 已经贴在正当高度上了
	#   （表现：窗停在初值、底部的「重置」按钮被切掉）。92%（= 993）留出余量；
	#   真正的垃圾值（0 宽折行量出的 800+）本来就被上面那两道先拦掉了。
	var limit := get_viewport_rect().size.y * 0.92
	if need.y > limit:
		push_warning("[设置窗] 内容最小高度 %.0f 超过视口 85%%（%.0f）—— 疑似未布局就量了，本次不改窗高"
				% [need.y, limit])
		return
	set_window_height(HEADER_H + need.y + 6.0 + 8.0 + 2.0)
	# ★ 窗高由内容反推 ⇒ 可能高过设计稿的 480（加了「显示 · 分辨率」实测 **866**）。
	#    `RECT_SETTINGS` 的 y=250 是配 480 高算的 ⇒ 250+866 = 1116 顶出屏外。
	#    ⇒ 上移进屏。⚠️ 同一件事在 `EveWindow.set_window_rect()` 里也做了一遍
	#      （HUD 每次刷新都会把窗摆回设计稿坐标）—— 两边都必须有，缺一边就会
	#      "开窗时是对的、刷新一次就掉下去"。
	var ny := _fit_y_in_viewport(position.y, size.y)
	if not is_equal_approx(ny, position.y):
		position.y = ny
		_base_rect = Rect2(_base_rect.position.x, ny, _base_rect.size.x, _base_rect.size.y)


## 切界面语言：**立即生效 + 立即写盘 + 重载当前场景**。
##
## ⚠️ 为什么必须重载：本工程的文案是**建 UI 的那一刻**取词的（面板一大半是
##    自绘 + 常量），没有「统一 retranslate」这条路径。重载是唯一能把整屏
##    文字都换掉的做法，且不会留下中英混杂的中间态。
##
## ⏸⏸ **2026-10-11 冻结**：英文版先不做 ⇒ 这个入口**实际不该被玩家用到**。
##    （保留代码是为了自检与将来解冻，不是"已经支持英文"。）
## ⚠️ 战场上重载 = 重新进这一局 ⇒ 先置「继续上一局」（`resume_requested`），
##    否则 `_ready` 会走 `start_run()` **从第 1 节点重开**。
##    代价：本节点准备阶段的买/刷新会丢（存档点是 `begin_prep` 末尾）。
func _pick_language(i: int) -> void:
	# ⏸ 冻结期双保险：行不建 ⇒ 按钮不存在，但函数还在（自检 / 将来解冻要用）。
	if not T.LANGUAGE_ENABLED:
		return
	if _lang_pick_guard or i < 0 or i >= T.LOCALES.size():
		return
	var code := String(T.LOCALES[i]["code"])
	if code == T.current():
		return
	_lang_pick_guard = true
	T.set_locale(code)
	T.save_locale(code)
	language_changed.emit(code)
	var cs := get_tree().current_scene
	if cs != null and cs.has_method("start_battle") and RUN_STORE.session_active:
		RUN_STORE.resume_requested = true
	get_tree().reload_current_scene()


# ------------------------------------------------------------------ 对外

func _pick_background(i: int) -> void:
	if i < 0 or i >= BACKGROUNDS.size():
		return
	var id := String(BACKGROUNDS[i]["id"])
	set_background_id(id)
	STORE.save_one("background", id)
	background_changed.emit(id)


func _pick_mood(i: int) -> void:
	if i < 0 or i >= MOODS.size():
		return
	var v := int(MOODS[i]["v"])
	set_mood(v)
	STORE.save_one("mood", v)
	mood_changed.emit(v)


## 界面缩放档。与背景 / 氛围同款：**立即生效 + 立即写盘**。
##
## ⚠️ 写盘写的是**原值**（0 = 自动），⛔ 不是解析后的倍数 ——
##    否则玩家选了「自动」之后再打开窗，高亮会跳到某个具体倍数上，
##    看起来像自己变了。
func _pick_ui_scale(i: int) -> void:
	if i < 0 or i >= UI_SCALE_SCRIPT.CHOICES.size():
		return
	var v := float(UI_SCALE_SCRIPT.CHOICES[i]["v"])
	set_ui_scale(v)
	STORE.save_one("ui_scale", v)
	ui_scale_changed.emit(v)


## 字号缩放。**改完立即生效**（不用关窗）：
##   ① 改倍数 → ② 把**已经建好的**控件就地重算 → ③ 自己按新内容重推窗高。
##
## ⚠️ 重算读的是节点上记的**设计字号**（meta），⛔ 不是「再乘一次」——
##    那样每拖一格都复利叠上去，几下就把字撑爆（见 `EveFont.reapply`）。
## ⚠️ 必须 `_fit_height()`：字变了 ⇒ 本窗内容的最小高度也变了，
##    不重推的话底部会留一条死白（本工程踩过两次的老病）。
func _pick_font_scale(v: float) -> void:
	FONT.set_scale(v)
	STORE.save_one("font_scale", FONT.scale)
	FONT.reapply(get_tree().root)
	# 字变高 ⇒ 商店会长高 ⇒ 告诉 HUD 重新上抬底部两条（⛔ 不转发给主控：
	# 3D 战场跑在原生分辨率上，跟 2D 字号无关）
	font_scale_changed.emit(FONT.scale)
	_fit_height()
	if not _font_slider.is_empty():
		(_font_slider["num"] as Label).text = "%d%%" % int(round(FONT.scale * 100.0))


## 主控打开窗时回写（**只改外观，不发信号** —— 叫 reapply 会把整棵树重刷一遍，
## 开窗那一下没必要）。
func set_font_scale(v: float) -> void:
	if _font_slider.is_empty():
		return
	# ⚠️ 存 0.0 = 没设过 / 旧文件 / 手改坏了 ⇒ 回落到**本平台出厂默认**
	#    （桌面 1.10 / 移动 1.20），⛔ 不是硬写 1.00。
	var s := FONT.default_scale() if v <= 0.0 else clampf(v, FONT.MIN_SCALE, FONT.MAX_SCALE)
	(_font_slider["slider"] as HSlider).set_value_no_signal(s)
	(_font_slider["num"] as Label).text = "%d%%" % int(round(s * 100.0))


## 刷新分辨率块下面那行小字 —— **按窗口当前状态说人话**。
##
## ★ 2026-11-08 为什么需要它：全屏 / 最大化时点分辨率档**不改窗口**，
##   只改 3D 渲染精度（见 `EveResolution.apply_index`）。如果还写着
##   「自适应 = 跟随屏幕」，玩家会以为窗口该变小却没变 ⇒ 判定成按钮坏了（红线 9）。
##
## ⚠️ 两种文案都**必须短**：窗宽 320、9px 字、禁止 autowrap ⇒ 超了就是被裁。
## ⛔ 别在这里顺带去改窗口/档位 —— 本函数只负责文案。
func _refresh_res_note() -> void:
	if _res_note == null:
		return
	var filled := RESOLUTION_SCRIPT.is_screen_filled(get_window())
	_res_note.text = "全屏中：只调 3D 清晰度" if filled \
			else T.t("SET_RES_NOTE", "★ = 推荐档 · 自适应 = 跟随屏幕")


## 窗口分辨率档。**本窗自己就把窗口改了**（`EveResolution.apply_index`），
## 不再让上层各写一遍尺寸逻辑（战斗场景与牌桌都要它 ⇒ 抄两份必然漂移）。
##
## `i` = **按钮下标**：`0` = 自适应，`i ≥ 1` = `CHOICES[i-1]`（见 `_res_btns` 的说明）。
##
## ⚠️ 写盘写的是 **key 字符串**（自适应 = 空串哨兵 `EveResolution.AUTO`），
##    ⛔ 不是下标 —— 档位表将来增删时下标会漂移
##    （本工程惯例：写进代码/存档的"位置"先问"这列表会增删吗"）。
## ⚠️ 牌桌 / 战场收到 `resolution_changed` 后**只做重铺/重绘**，
##    ⛔ 别再改一次窗口尺寸（两次改动之间会闪一帧）。
func _pick_resolution(i: int) -> void:
	var key := RESOLUTION_SCRIPT.AUTO
	if i > 0:
		var ci := i - 1
		if ci >= RESOLUTION_SCRIPT.CHOICES.size():
			return
		key = String(RESOLUTION_SCRIPT.CHOICES[ci]["key"])
	STORE.save_one("resolution", key)
	var idx := RESOLUTION_SCRIPT.resolve_index(key)
	RESOLUTION_SCRIPT.apply_index(get_window(), idx)
	resolution_changed.emit(idx)


## 主控打开窗时回写高亮（**只改外观，不发信号**）。
##
## ⚠️ 桌面端 `_res_btns` 是空的（那一行根本不建）⇒ 本函数直接返回，不是漏写。
func set_resolution(idx: int) -> void:
	if _res_btns.is_empty():
		return
	if idx < 0:
		idx = RESOLUTION_SCRIPT.current_index()
	# 按钮 0 = 自适应，1..N = CHOICES[0..N-1] ⇒ 固定档的高亮下标要 +1
	var pick := 1 + clampi(idx, 0, RESOLUTION_SCRIPT.CHOICES.size() - 1)
	for i in _res_btns.size():
		EveButtonTheme.apply(_res_btns[i], "hud_main" if i == pick else "hud")
	_refresh_res_note()


## 高亮「自适应」档（**只改外观，不发信号**）。
##
## ⚠️ 单独一个函数、而不是给 `set_resolution` 传个哨兵下标：
##    `set_resolution()` 的语义是「`CHOICES` 下标 → 高亮那一档」，而自适应
##    **没有固定下标**（它的下标随屏幕变）—— 两件事分开，读起来才不会有歧义。
func set_resolution_auto() -> void:
	if _res_btns.is_empty():
		return
	for i in _res_btns.size():
		EveButtonTheme.apply(_res_btns[i], "hud_main" if i == 0 else "hud")
	_refresh_res_note()


# ------------------------------------------------------------------ 重置

## 「恢复默认设置」—— **全站唯一入口**（按钮与 Ctrl+F11 都走这里）。
##
## 三件事，顺序有讲究：
##   ① **先把默认值写盘**（`EveSettingsStore.DEFAULTS` 是唯一真相源）；
##   ② 再逐项**立即生效** —— 复用本窗已有的静默回写（`set_volume` / `set_font_scale`
##      / `set_ui_scale` / …）把外观拨回默认，再发**已有的信号**让各场景跟上
##      （音量 → 音频层 · 分辨率 → 重铺 · 字号 → HUD）；
##      ⛔ 不在这里重抄一遍"怎么应用"的逻辑 —— 抄一份必然和原路径漂移；
##   ③ 给一行确认反馈（说明行换成「✓ 已恢复默认设置」）。
##
## ⚠️ 只重置**持久化的偏好**（= `DEFAULTS` 里的项）。雾 / 射程环 / 棋盘是**场上
##    临时状态**、不进存档（见 `EveSettingsStore` 顶注）⇒ 不在这里动它们。
## ⚠️ 字号 / 界面缩放的哨兵是 `0`（= 跟随平台出厂默认），分辨率是 `""`
##    （= 自适应）—— 所以「恢复默认」写回去的是**哨兵值**，不是解析后的具体值。
func reset_to_defaults() -> void:
	var d := STORE.DEFAULTS
	STORE.save_all(d)
	# ① 音量四条：先把滑杆拨回默认（静默），再发信号让各场景的音频层真的改
	for item in VOLUME_KINDS:
		var k: StringName = item["k"]
		var v := float(d[String(k)])
		set_volume(k, v)
		volume_changed.emit(k, v)
	# ② 静音
	_set_toggle("mute", bool(d["muted"]))
	mute_toggled.emit(bool(d["muted"]))
	# ③ 天空盒 / 氛围（只有战场有控件；发信号让 arena 跟着换）
	if _is_battle():
		set_background_id(String(d["background"]))
		background_changed.emit(String(d["background"]))
		set_mood(int(d["mood"]))
		mood_changed.emit(int(d["mood"]))
	# ④ 字号（哨兵 0 ⇒ 平台出厂默认：桌面 1.10 / 移动 1.20）
	FONT.set_scale(FONT.default_scale())
	FONT.reapply(get_tree().root)
	set_font_scale(0.0)                 # 回写滑杆显示（0.0 ⇒ 按平台默认算）
	font_scale_changed.emit(FONT.scale)
	# ⑤ 界面缩放（只有移动端有控件）
	set_ui_scale(float(d["ui_scale"]))
	ui_scale_changed.emit(float(d["ui_scale"]))
	# ⑥ 分辨率（只有桌面端有控件）：哨兵 "" ⇒ 自适应
	var ri := RESOLUTION_SCRIPT.resolve_index(String(d["resolution"]))
	RESOLUTION_SCRIPT.apply_index(get_window(), ri)
	set_resolution_auto()
	resolution_changed.emit(ri)
	# ⑦ 反馈 + 窗高可能因文字变化而变 ⇒ 重推一次
	if _reset_note != null:
		_reset_note.text = T.t("SET_RESET_DONE", "✓ 已恢复默认")
		_reset_note.add_theme_color_override("font_color", C_OK)
	_fit_height()


## ★ 2026-10-10  Ctrl + F11 = 恢复默认设置。
##
## ⚠️ 挂在**本窗**上（而不是只做按钮）：设置窗在主菜单 / 战场 / 牌桌**三处都建**，
##    而 `_unhandled_input` **不受 `visible` 影响** ⇒ 窗关着也按得到 ——
##    这正是「把界面调歪了、窗都点不开」时需要的救命路径。
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_F11 and event.ctrl_pressed:
		reset_to_defaults()
		get_viewport().set_input_as_handled()


## 音量滑杆。改完立即写盘 —— 音量是「调一次就定型」的典型，
## 不写盘等于每次开游戏都要重调。
func _pick_volume(kind: StringName, v: float) -> void:
	STORE.save_one(String(kind), v)
	volume_changed.emit(kind, v)


## 同步当前状态（主控打开窗时调一次，保证窗里显示的就是场上的实际值）。
##
## ⚠️ 四件事各自独立，不能合并成「一个 refresh」就完事：
##    单选组刷**皮肤** · 二态开关刷皮肤 + **文字** ·
##    滑杆刷**值 + 百分比**（且不发信号，见 `set_volume`）· 暂停刷按钮文字。
func set_state(state: Dictionary) -> void:
	# 记住一份：`set_tabbed()` 重建内容后要按它回写（否则开关/滑杆显示跳回默认值）
	_last_state = state.duplicate()
	set_background_id(String(state.get("background", "caldari_c07")))
	set_mood(int(state.get("mood", 0)))
	_set_toggle("fog", bool(state.get("fog", false)))
	_set_toggle("rings", bool(state.get("rings", false)))
	_set_toggle("board", bool(state.get("board", false)))
	_set_toggle("mute", bool(state.get("muted", false)))
	var vols: Dictionary = state.get("volumes", {})
	for kind in _sliders.keys():
		set_volume(kind, float(vols.get(String(kind), 1.0)))
	set_paused(bool(state.get("paused", false)))
	set_ui_scale(float(state.get("ui_scale", 0.0)))
	set_font_scale(float(state.get("font_scale", 1.0)))
	# ⚠️ 缺省值给 `-1`（= 「上层没说」）⇒ `set_resolution` 自己读盘算当前档，
	#    而不是把 -1 当成"第一档"高亮（那会让玩家以为默认是 4K）。
	# ★ 2026-10-10：自适应与固定档都可能出现在存档里 ⇒ **以存档的原始 key 分派**；
	#   ⛔ 别只看解析出的下标 —— 自适应解析出的下标会与某个固定档重合，分不出来。
	var saved_res := String(state.get("resolution_saved",
			STORE.load_all().get("resolution", RESOLUTION_SCRIPT.AUTO)))
	if saved_res == RESOLUTION_SCRIPT.AUTO:
		set_resolution_auto()
	else:
		set_resolution(int(state.get("resolution_index", -1)))
	# 打开窗时把「重置」那行的说明恢复成快捷键提示（上一次点过会留下"已恢复"）
	if _reset_note != null:
		_reset_note.text = RESET_NOTE_HINT
		_reset_note.add_theme_color_override("font_color", C_TEXT_FAINT)


func set_background_id(id: String) -> void:
	_cur_bg = id
	for i in _bg_btns.size():
		var on := String(BACKGROUNDS[i]["id"]) == id
		EveButtonTheme.apply(_bg_btns[i], "hud_main" if on else "hud")
	# ★ 2026-10-10 主界面档案**没有天空盒可换** ⇒ 标题栏右侧别挂「加达里 C07」
	#    这种背景名（会让人以为这里能换背景，其实是块死信息）。
	if not _is_menu():
		set_status(_bg_name(id))


## 回写缩放档高亮。传**存档原值**（0 = 自动）。
##
## ⚠️ 桌面端 `_scale_btns` 是空的（那一行根本不建）⇒ 本函数直接返回，
##    不是漏写。
func set_ui_scale(saved: float) -> void:
	_cur_ui_scale = saved
	if _scale_btns.is_empty():
		return
	var idx := UI_SCALE_SCRIPT.choice_index(saved)
	for i in _scale_btns.size():
		EveButtonTheme.apply(_scale_btns[i], "hud_main" if i == idx else "hud")


func set_mood(mode: int) -> void:
	_cur_mood = mode
	for i in _mood_btns.size():
		var on := int(MOODS[i]["v"]) == mode
		EveButtonTheme.apply(_mood_btns[i], "hud_main" if on else "hud")


## 只改滑杆外观，**不发信号** —— 供主控回写实际状态（避免回环）
func set_volume(kind: StringName, v: float) -> void:
	var item: Dictionary = _sliders.get(kind, {})
	if item.is_empty():
		return
	var s: HSlider = item["slider"]
	s.set_value_no_signal(clampf(v, 0.0, 1.0))
	var num: Label = item["num"]
	num.text = "%d%%" % int(round(s.value * 100.0))


## 只改按钮外观，**不发信号** —— 供主控回写实际状态（避免回环）
func _set_toggle(key: String, on: bool) -> void:
	var st: Dictionary = _toggles.get(key, {})
	if st.is_empty():
		return
	st["on"] = on
	_refresh_toggle(key)


## 主控回写暂停态（键盘空格改的，窗不知道）。
##
## ⚠️ 不回写就会出现「场上已经停了、按钮还写着『暂停对局』」——
##    玩家再点一下以为在暂停，实际是继续，而且没有任何提示。
func set_paused(on: bool) -> void:
	_paused = on
	if _pause_btn == null:
		return
	_pause_btn.text = (T.t("SET_PAUSE_RESUME", "▶ 继续对局") if on
				else T.t("SET_PAUSE_PAUSE", "‖ 暂停对局"))
	# 暂停态用警示色（橙）：它表示「当前处于非正常状态」，
	# 而不是「这是一个危险操作」 —— 恢复态才是常规主操作（青）。
	EveButtonTheme.apply(_pause_btn, "hud_warn" if on else "hud_main")
	FONT.fs(_pause_btn, 14)


func is_paused() -> bool:
	return _paused


## 切「横向栏目」态（HUD 每次重铺都调；值没变就直接返回）。
##
## ⚠️ 为什么需要重建而不是「建两套、切可见性」：栏目版的盒子里装的控件
##    引用（`_sliders` / `_toggles` / `_bg_btns` …）与竖向版**同名同型**，
##    两套并存会让「回写状态」不知道该写哪一套 —— 重建是唯一不会漂的做法。
## ⚠️ 桌面档**永远**收不到 true（HUD 只在手机档调它）⇒ PC 路径不受影响。
func set_tabbed(on: bool) -> void:
	if on == _tabbed or not is_node_ready():
		return
	_tabbed = on
	_rebuild_contents()


## 清空 content 并按当前 `_tabbed` 重建，然后把上一次的真实状态回写回去。
func _rebuild_contents() -> void:
	for c in content.get_children():
		content.remove_child(c)
		c.queue_free()
	# ⚠️ 控件引用**必须**清干净：旧控件已 `queue_free`，留着就是悬垂引用
	_sliders.clear()
	_toggles.clear()
	_groups.clear()
	_bg_btns.clear()
	_mood_btns.clear()
	_scale_btns.clear()
	_res_btns.clear()
	_lang_btns.clear()
	_tab_btns.clear()
	_tab_boxes.clear()
	_pause_btn = null
	_dbg_box = null
	_dbg_btn = null
	_reset_note = null
	_res_note = null
	_font_slider = {}
	_cur_tab = "video"
	_build_contents()
	# ★ 栏目态：窗高归调用方的矩形管（定高 560）——竖向时代 `_fit_height` →
	#   `set_window_height` 置位的 `_height_owned` 必须交还，
	#   否则 `set_window_rect(..., 560)` 的**高度被忽略**（实测牌桌窗 652 高，
	#   底栏悬在半空）。桌面竖向态照旧由内容反推。
	_height_owned = not _tabbed
	# 重建后回写真实状态（暂停态 / 音量 / 开关 / 高亮）—— 否则开着的窗会跳回默认值
	if not _last_state.is_empty():
		set_state(_last_state)
	if not _tabbed:
		# 等两帧让布局稳定再量高（与 `_ready` 同款理由：宽度没定时量出垃圾值）
		await get_tree().process_frame
		await get_tree().process_frame
		_fit_height()


func get_toggle(key: String) -> bool:
	var st: Dictionary = _toggles.get(key, {})
	return bool(st.get("on", false))


func _bg_name(id: String) -> String:
	for b in BACKGROUNDS:
		if String(b["id"]) == id:
			return String(b["name"])
	return id
