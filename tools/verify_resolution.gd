extends Node
## 分辨率档 + 内容居中偏移 + 设置窗两套档案 + 牌桌设置入口 自检（★ 2026-10-07）
##
## ⚠️ 为什么单独一套：这一批功能有三个**极容易静默错**的地方 ——
##    ① 无头/移动端误应用分辨率 ⇒ 把自检的视口改掉（581 条几何断言一起歪）；
##    ② 居中偏移只加在"画"上、忘了"点" ⇒ 「看着能点、点了没反应」（红线 9）；
##    ③ 牌桌档案漏建/多建分区 ⇒ 多出点不动的死按钮，或者少掉该有的设置。
##    这三条都不会报错，只能靠断言钉。

const RES := preload("res://scripts/ui/eve_resolution.gd")
const LAYOUT := preload("res://scripts/ui/eve_layout.gd")
const SETTINGS := preload("res://scripts/ui/panels/eve_settings.gd")
const STORE := preload("res://scripts/core/eve_settings_store.gd")
const LAYOUT_STORE := preload("res://scripts/ui/eve_window_store.gd")
const DDZ := preload("res://scenes/doudizhu.tscn")
const MENU := preload("res://scenes/main_menu.tscn")
## user:// 迁移（2026-10-07 项目名去掉「918」的收尾）
const USER_DIR := preload("res://scripts/core/eve_user_dir.gd")

var _pass := 0
var _fail := 0
var _cfg_snapshot := PackedByteArray()
var _cfg_existed := false


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  ✓ " + msg)
	else:
		_fail += 1
		print("  ✗ " + msg)


func _ready() -> void:
	LAYOUT_STORE.persist = false          # ⛔ 别写盘污染玩家的窗口布局
	# ⛔⛔ 必须在这里就关掉：下面 `_t_menu_layer()` 会实例化主菜单，
	#     而主菜单的 `_ready` **第一件事就是调 user:// 迁移** ——
	#     不关的话验收会真的去搬玩家的存档目录（本文件是唯一会碰到它的地方）。
	USER_DIR.persist = false
	_snapshot_settings()
	print("═══ 分辨率 / 居中偏移 / 设置窗档案 自检 ═══")
	_t_table()
	_t_resolve()
	_t_origin()
	_t_platform_guard()
	_t_screen_filled()
	await _t_settings_profile()
	await _t_lounge_table()
	await _t_menu_layer()
	_t_user_dir()
	_restore_settings()
	print("═══ RESULT passed=%d failed=%d ═══" % [_pass, _fail])
	# ★ 2026-10-10（审查 R07）：失败 ⇒ 非零退出码
	get_tree().quit(1 if _fail > 0 else 0)


func _snapshot_settings() -> void:
	var f := FileAccess.open(STORE.PATH, FileAccess.READ)
	if f != null:
		_cfg_existed = true
		_cfg_snapshot = f.get_buffer(f.get_length())
		f = null


func _restore_settings() -> void:
	if _cfg_existed:
		var f := FileAccess.open(STORE.PATH, FileAccess.WRITE)
		if f != null:
			f.store_buffer(_cfg_snapshot)
			f = null
		print("  （设置文件已原样还原）")
	else:
		DirAccess.remove_absolute(STORE.PATH)
		print("  （本机原本没有设置文件，测试后已删除）")


# ---------------------------------------------------------------- [1] 档位表

func _t_table() -> void:
	print("[1] 档位表（照用户 2026-10-07 给的图 + 顶部补 4K）")
	_ok(RES.CHOICES.size() == 14, "表长 14（图里 13 档 + 补的 3840×2160）实际 %d"
			% RES.CHOICES.size())
	_ok(String(RES.CHOICES[0]["key"]) == "3840x2160",
			"最高档 = 3840×2160（用户要求「最高 4K」）实际 %s"
			% String(RES.CHOICES[0]["key"]))
	_ok(String(RES.CHOICES[1]["key"]) == "2560x1440" and bool(RES.CHOICES[1].get("recommend", false)),
			"第二档 = 2560×1440 且标「推荐」（与图一致）")
	_ok(String(RES.CHOICES[RES.CHOICES.size() - 1]["key"]) == "1366x768",
			"最低档 = 1366×768（图的最后一项）")
	# key 唯一 + 数值合法 + 只有一个推荐
	var keys := {}
	var dup := ""
	var bad := ""
	var rec := 0
	for it in RES.CHOICES:
		var k := String(it["key"])
		if keys.has(k):
			dup = k
		keys[k] = true
		if int(it["w"]) < 640 or int(it["h"]) < 480:
			bad = k
		if bool(it.get("recommend", false)):
			rec += 1
		if k != "%dx%d" % [int(it["w"]), int(it["h"])]:
			bad = k + "（key 与 w/h 不符）"
	_ok(dup == "", "key 唯一（重复：%s）" % ("无" if dup == "" else dup))
	_ok(bad == "", "每档 w/h 合法且 key == \"WxH\"（异常：%s）" % ("无" if bad == "" else bad))
	_ok(rec == 1, "「推荐」只标了一档（实际 %d）" % rec)
	_ok(RES.BASE == Vector2i(1920, 1080), "基准 = 1920×1080（与 project.godot 同源）")


# ---------------------------------------------------------------- [2] 解析

func _t_resolve() -> void:
	print("[2] 存档 → 档位（key 字符串，⛔ 不用下标）")
	_ok(RES.resolve_index("2560x1440") == 1, "key 2560x1440 ⇒ 下标 1（实际 %d）"
			% RES.resolve_index("2560x1440"))
	_ok(RES.resolve_index("3840x2160") == 0, "key 3840x2160 ⇒ 下标 0")
	# ⚠️ 认不出的 key 必须回落"自动"，⛔ 不是下标 0（那会把玩家扔进 4K）
	var junk := RES.resolve_index("9999x9999")
	_ok(junk == RES.default_index(),
			"认不出的 key ⇒ 回落 default_index()（实际 %d）" % junk)
	# ★ 默认档必须**能放进屏幕**，且优先 16:9
	var di := RES.default_index()
	var dw := int(RES.CHOICES[di]["w"])
	var dh := int(RES.CHOICES[di]["h"])
	var avail := RES.usable_size()
	_ok(dw <= avail.x and dh <= avail.y,
			"★ 默认档 %dx%d 放得进屏幕可用区 %s" % [dw, dh, str(avail)])
	_ok(absf(float(dw) / float(dh) - 16.0 / 9.0) < 0.01 or _no_169_fits(),
			"★ 默认档是 16:9（%dx%d）—— 4:3 的 1856×1392 面积更大但不该当选"
			% [dw, dh])
	# 存档往返
	STORE.save_one("resolution", "2560x1440")
	_ok(String(STORE.load_all().get("resolution", "-")) == "2560x1440",
			"resolution 存档往返（字符串）")
	_ok(STORE.DEFAULTS.has("resolution") and String(STORE.DEFAULTS["resolution"]) == "",
			"默认值表里有 resolution 且默认是空串（= 自动）")
	STORE.save_one("resolution", "")


## 屏幕小到没有任何 16:9 档放得下（用来给上面那条断言兜底）。
func _no_169_fits() -> bool:
	var avail := RES.usable_size()
	for it in RES.CHOICES:
		var w := int(it["w"])
		var h := int(it["h"])
		if absf(float(w) / float(h) - 16.0 / 9.0) < 0.01 and w <= avail.x and h <= avail.y:
			return false
	return true


# ---------------------------------------------------------------- [3] 居中偏移

func _t_origin() -> void:
	print("[3] 居中偏移（纯函数 origin_of）")
	var zero := Vector2.ZERO
	_ok(LAYOUT.origin_of(Vector2(1920, 1080)).is_equal_approx(zero),
			"设计空间 = 基准（1920×1080）⇒ 零偏移")
	# ⚠️ 16:9 的窗口**设计空间恒 = 1920×1080**（等比缩放的必然结果）
	#    ⇒ 不需要单独断言"2560×1440 窗口偏移为零"，那等价于上面这一条。
	#    真正要钉的是"设计空间比基准大时偏移多少"，见下面三条。
	_ok(LAYOUT.origin_of(Vector2(1920, 1200)).is_equal_approx(Vector2(0, 60)),
			"1920×1200（16:10）⇒ (0,60) 实际 %s"
			% str(LAYOUT.origin_of(Vector2(1920, 1200))))
	_ok(LAYOUT.origin_of(Vector2(1920, 1440)).is_equal_approx(Vector2(0, 180)),
			"1920×1440（4:3）⇒ (0,180) 实际 %s"
			% str(LAYOUT.origin_of(Vector2(1920, 1440))))
	_ok(LAYOUT.origin_of(Vector2(1920, 1200)).x == 0.0
			and LAYOUT.origin_of(Vector2(2380, 1080)).is_equal_approx(Vector2(230, 0)),
			"只有一边大时只偏那一边（2380×1080 ⇒ (230,0) 实际 %s）"
			% str(LAYOUT.origin_of(Vector2(2380, 1080))))
	# ⚠️ 设计空间**小于**基准时不许出现负偏移（会把内容推出屏幕左上）
	var small := LAYOUT.origin_of(Vector2(1280, 720))
	_ok(small.x >= 0.0 and small.y >= 0.0, "比基准小 ⇒ 夹到零（⛔ 不出现负偏移）实际 %s"
			% str(small))
	_ok(LAYOUT.design_space(null).is_equal_approx(LAYOUT.BASE),
			"窗口为 null ⇒ 回落基准（防御）")


# ---------------------------------------------------------------- [4] 平台守卫

func _t_platform_guard() -> void:
	print("[4] ★★ 平台守卫：无头 / 移动端一律不碰窗口")
	if DisplayServer.get_name() == "headless":
		_ok(not RES.is_enabled(),
				"★★ 无头下 is_enabled() = false ⇒ 分辨率不会去改自检的视口")
		_ok(LAYOUT.origin(null).is_equal_approx(Vector2.ZERO),
				"★★ 无头下 origin() = 零偏移（否则 581 条断言会整体下移 420px）")
	else:
		_ok(RES.is_enabled(), "非无头 ⇒ 桌面端启用分辨率档")
		print("    （本次不是无头运行，「无头守卫」那两条跳过）")
	var saved_pos := get_window().position
	var saved_size := get_window().size
	# 即便硬调 apply_index，无头下也必须一个字节都不动
	RES.apply_index(get_window(), 0)
	if DisplayServer.get_name() == "headless":
		_ok(get_window().size == saved_size and get_window().position == saved_pos,
				"无头下强行 apply_index(4K) ⇒ 窗口尺寸/位置一点没变（%s）"
				% str(get_window().size))


# ---------------------------------------------------------------- [4.5] 全屏只改清晰度

## ★★ 2026-11-08：全屏 / 最大化下改分辨率档**不许动窗口**。
##
## 玩家报的现象：把窗口最大化（看着就是全屏）后点分辨率档 ⇒ 窗口被缩回档位
## 大小、退出最大化 ⇒ 右边下边露出大片桌面（截图坐实）。
## 修法：全屏 / 最大化分支**只写 `scaling_3d_scale`**（3D 渲染精度），窗口一个
## 字节都不碰。这一段钉三件事：
##   ① 三种「尺寸不归我们管」的窗口模式都认（漏一个就漏一条黑边路径）；
##   ② 倍率换算对（含 4:3 档落在 16:9 屏上那种非等比情况）；
##   ③ 全屏分支**真的不动 size**（这条是本次 bug 的正题）。
##
## ⚠️ 用**未入树的 `Window.new()`** 造样本：入树会真去开一个 OS 窗口，无头下没有
##    显示服务（实测 `--script` 直接挂死）。未入树的 Window 上 `mode` / `size` /
##    `scaling_3d_scale` 都是纯属性读写，正好够验判定与换算。
func _t_screen_filled() -> void:
	print("[4.5] ★★ 全屏 / 最大化 ⇒ 只改 3D 渲染精度，不动窗口")
	_ok(not RES.is_screen_filled(null), "null ⇒ 不当作全屏（防御）")
	var w := Window.new()
	w.size = Vector2i(1920, 1080)
	_ok(not RES.is_screen_filled(w),
			"默认 WINDOWED ⇒ 不是全屏（mode=%d）" % w.mode)
	w.mode = Window.MODE_MAXIMIZED
	_ok(RES.is_screen_filled(w), "★★ MODE_MAXIMIZED ⇒ 认（玩家最常遇到的那个）")
	var before := w.size
	RES.apply_render_scale(w, 5)
	_ok(w.size == before,
			"★★ 全屏分支**不动窗口尺寸**（%s ⇒ %s）—— 这就是黑边 bug 的正题"
			% [str(before), str(w.size)])
	# 1366×768 档落在 1920×1080 的画面上：高度方向更紧 ⇒ 取 768/1080
	_ok(absf(w.scaling_3d_scale - 768.0 / 1080.0) < 0.002,
			"换算取两边更小的比例（1366×768 / 1920×1080 ⇒ %.4f，期望 %.4f）"
			% [w.scaling_3d_scale, 768.0 / 1080.0])
	RES.apply_render_scale(w, 0)
	_ok(is_equal_approx(w.scaling_3d_scale, RES.MAX_RENDER_SCALE),
			"4K 档跑在 1080p 全屏 ⇒ 夹到引擎上限 %.2f（超采样）"
			% RES.MAX_RENDER_SCALE)
	RES.reset_render_scale(w)
	_ok(is_equal_approx(w.scaling_3d_scale, 1.0), "归位 ⇒ 1.0（原生分辨率）")
	w.mode = Window.MODE_FULLSCREEN
	_ok(RES.is_screen_filled(w), "MODE_FULLSCREEN ⇒ 认")
	w.mode = Window.MODE_EXCLUSIVE_FULLSCREEN
	_ok(RES.is_screen_filled(w), "MODE_EXCLUSIVE_FULLSCREEN ⇒ 认")
	w.mode = Window.MODE_WINDOWED
	_ok(not RES.is_screen_filled(w),
			"★ 回到 WINDOWED ⇒ 不再算全屏（否则窗口模式下也改不了窗口尺寸）")
	w.free()


# ---------------------------------------------------------------- [5] 设置窗两套档案

func _t_settings_profile() -> void:
	print("[5] 设置窗：战场 / 牌桌两套档案")
	var battle: Variant = SETTINGS.new()
	add_child(battle)
	var lounge: Variant = SETTINGS.new()
	lounge.profile = SETTINGS.PROFILE_LOUNGE
	add_child(lounge)
	await _frames(4)

	_ok(battle.profile == SETTINGS.PROFILE_BATTLE, "战场档案是 default（%s）" % battle.profile)
	_ok(battle.get("_pause_btn") != null, "★ 战场有「暂停」大按钮")
	# ★ 2026-10-10 分辨率块多了「自适应」一颗（按钮 0）⇒ 桌面端 15 个
	_ok(battle.get("_res_btns").size() == (15 if RES.is_enabled() else 0),
			"战场分辨率按钮 %d 个（桌面 15 = 自适应 + 14 档 / 非桌面 0）实际 %d"
			% [(15 if RES.is_enabled() else 0), battle.get("_res_btns").size()])
	_ok(RES.AUTO_LABEL != "", "★ 有「自适应」档的显示名（%s）" % RES.AUTO_LABEL)
	_ok(RES.resolve_index(RES.AUTO) == RES.default_index(),
			"★ 自适应（哨兵 \"\"）解析成 default_index()（%d）" % RES.default_index())
	_ok(battle.get("_font_slider").size() > 0, "战场有「字号」滑杆")

	_ok(lounge.profile == SETTINGS.PROFILE_LOUNGE, "牌桌档案设得上（%s）" % lounge.profile)
	_ok(lounge.get("_pause_btn") == null,
			"★★ 牌桌**不建**暂停按钮（牌桌没有战斗在跑 ⇒ 建了就是死按钮，红线 9）")
	_ok(lounge.get("_dbg_box") == null and lounge.get("_dbg_btn") == null,
			"★★ 牌桌不建 DEBUG 加币区（加币是战场经济的事）")
	_ok(lounge.get("_bg_btns").is_empty() and lounge.get("_mood_btns").is_empty(),
			"★★ 牌桌不建天空盒 / 氛围（牌桌没有 3D 场景）")
	_ok(lounge.get("_toggles").size() == 1,
			"★★ 战斗界面开关只剩「静音」一个（实际 %d 个：%s）"
			% [lounge.get("_toggles").size(), str(lounge.get("_toggles").keys())])
	_ok(lounge.get("_font_slider").size() > 0, "★ 牌桌**有**「字号」滑杆（通用项）")
	_ok(lounge.get("_sliders").is_empty() == false,
			"★ 牌桌**有**音频四路（%d 路）—— 否则滑杆是死旋钮" % lounge.get("_sliders").size())
	# ★ 分辨率高亮**唯一**（只有"当前生效档"是亮的）。
	# ⚠️ 这条只在**桌面端**跑得到：无头下分辨率块根本不存在（`is_enabled()` = false）。
	var rbtns: Array = lounge.get("_res_btns")
	if rbtns.is_empty():
		print("    （无头下没有分辨率按钮，「高亮唯一」那条跳过）")
	else:
		# ★ 2026-10-10：按钮 0 = 自适应，1..N = CHOICES[0..N-1] ⇒ 固定档下标要 +1
		lounge.call("set_resolution", 3)
		var ref: Color = (rbtns[4] as Button).get_theme_stylebox("normal").bg_color
		var same := 0
		for b in rbtns:
			if ((b as Button).get_theme_stylebox("normal").bg_color as Color).is_equal_approx(ref):
				same += 1
		_ok(same == 1, "★ 分辨率高亮唯一（CHOICES 档 3 → 按钮 4，同色按钮 %d 个）" % same)
		lounge.call("set_resolution", -1)
		var ref2: Color = (rbtns[1 + RES.default_index()] as Button) \
				.get_theme_stylebox("normal").bg_color
		var same2 := 0
		for b in rbtns:
			if ((b as Button).get_theme_stylebox("normal").bg_color as Color).is_equal_approx(ref2):
				same2 += 1
		_ok(same2 == 1, "★ 传 -1 ⇒ 回落「实际生效档」（下标 %d）且唯一高亮"
				% RES.default_index())
		# ★ 2026-10-10 新增：「自适应」高亮（按钮 0）且唯一
		lounge.call("set_resolution_auto")
		var ref3: Color = (rbtns[0] as Button).get_theme_stylebox("normal").bg_color
		var same3 := 0
		for b in rbtns:
			if ((b as Button).get_theme_stylebox("normal").bg_color as Color).is_equal_approx(ref3):
				same3 += 1
		_ok(same3 == 1, "★ 「自适应」档高亮唯一（同色按钮 %d 个）" % same3)
	# ★ 2026-10-10 「自适应」按钮 → 存档写**哨兵空串**（⛔ 不是默认那一档的 key）。
	#    ⚠️ 放在 `if rbtns.is_empty()` **之外**：`_pick_resolution` 不依赖按钮，
	#    无头下同样跑得到（无头下按钮不建，但这条语义照验）。
	lounge.call("_pick_resolution", 0)
	_ok(String(RES.STORE.load_all().get("resolution", "?")) == RES.AUTO,
			"★ 点「自适应」⇒ 存档写哨兵 \"\"（实际 \"%s\"）"
			% String(RES.STORE.load_all().get("resolution", "?")))
	lounge.call("_pick_resolution", 1)
	_ok(String(RES.STORE.load_all().get("resolution", "?")) == String(RES.CHOICES[0]["key"]),
			"★ 点第 1 档 ⇒ 存档写 key（%s，实际 \"%s\"）"
			% [String(RES.CHOICES[0]["key"]),
			   String(RES.STORE.load_all().get("resolution", "?"))])
	# ★ 2026-10-13 全平台栏目态：三处设置窗同一骨架（半屏宽 + 定高 560），
	#   档案间的差别落在**栏目数**上 —— 战场 4（视频/音频/界面/游戏）、牌桌 2（音频/界面）。
	#   ⚠️ 不比窗高：本测试的窗没走过 `_place_settings()`，高度来自布局存档，不可靠。
	var lb: int = (lounge.get("_tab_btns") as Array).size()
	var bb: int = (battle.get("_tab_btns") as Array).size()
	_ok(bool(lounge.get("_tabbed")) and bool(battle.get("_tabbed")),
			"牌桌与战场设置窗同为**栏目态**（全平台统一）")
	_ok(lb < bb,
			"牌桌栏目更少（%d < %d）—— 少掉战场的分区" % [lb, bb])
	# ★ 整扇窗必须在屏内（加完分辨率块之后战场窗实测 866 高）
	# ⚠️ 本节点是 `Node` 不是 `Control` ⇒ `get_viewport_rect()` 不存在，走 get_viewport()
	var vh := get_viewport().get_visible_rect().size.y
	_ok(battle.position.y >= 0.0 and battle.position.y + battle.size.y <= vh + 0.5,
			"★ 战场设置窗整扇在屏内（y %.0f..%.0f / 屏高 %.0f）"
			% [battle.position.y, battle.position.y + battle.size.y, vh])
	_ok(lounge.position.y + lounge.size.y <= vh + 0.5,
			"★ 牌桌设置窗整扇在屏内（y %.0f..%.0f）"
			% [lounge.position.y, lounge.position.y + lounge.size.y])
	battle.queue_free()
	lounge.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- [6] 牌桌接入

func _t_lounge_table() -> void:
	print("[6] 牌桌接入（设置按钮 / 居中偏移 / 音频后端）")
	var host := SubViewport.new()
	host.size = Vector2i(1920, 1080)
	add_child(host)
	var t: Variant = DDZ.instantiate()
	host.add_child(t)
	await _frames(4)

	_ok(t.get("_settings") != null, "★ 牌桌建了设置窗")
	if t.get("_settings") != null:
		_ok(String(t.get("_settings").profile) == SETTINGS.PROFILE_LOUNGE,
				"★ 牌桌设置窗走 lounge 档案（%s）" % String(t.get("_settings").profile))
		_ok(String(t.get("_settings").layout_key) == "lounge_settings",
				"★ 布局键与战场分开（%s）—— 共用会让两扇窗抢同一份坐标"
				% String(t.get("_settings").layout_key))
		_ok(not bool(t.get("_settings").visible), "设置窗默认收起")
	_ok(t.get("_audio") != null, "★ 牌桌起了音频后端（音量滑杆才不是死旋钮）")

	var ids := _ids(t.call("_buttons"))
	_ok(ids.has("settings"), "★ 顶栏有「设置」按钮（实际 %s）" % str(ids))
	_ok(ids.has("back") and ids.has("auto"), "原来两个按钮还在（不抢位置）")

	# ★★ 居中偏移：把牌桌改成 1920×1200（模拟 16:10 分辨率档）
	t.size = Vector2(1920, 1200)
	await _frames(2)
	var o: Vector2 = t.call("_ui_origin")
	_ok(o.is_equal_approx(Vector2(0, 60)),
			"★★ size=1920×1200 ⇒ 偏移 (0,60) 实际 %s" % str(o))
	# 几何仍在**基准区**里（⛔ 不许跟着 size 一起变长）
	var p0: Vector2 = t.call("_seat_pt", 0)
	var want_y := float(t.BASE.y) * float(t.TABLE_CY) \
			+ float(t.BASE.y) * float(t.TABLE_RY) * float(t.PLAY_OUT)
	_ok(absf(p0.x - 960.0) < 2.0 and absf(p0.y - want_y) < 0.5,
			"★★ 牌桌座位点完全由 1080 基准算出（%s，期望 y=%.1f）—— ⛔ 与 size=%s 无关"
			% [str(p0), want_y, str(t.size)])
	# 按钮矩形也在基准区内（底部按钮不许跑到 1200 那一带）
	var all_in := true
	for b in t.call("_buttons"):
		var r: Rect2 = b["rect"]
		if r.end.y > 1080.5 or r.end.x > 1920.5:
			all_in = false
	_ok(all_in, "★★ 所有按钮矩形都在 1920×1080 基准区内（画与点同源的那套坐标）")
	t.size = Vector2(1920, 1080)
	await _frames(2)
	_ok((t.call("_ui_origin") as Vector2).is_equal_approx(Vector2.ZERO),
			"切回 1920×1080 ⇒ 偏移归零")
	host.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- [7] 主菜单分层

## ★★ 底图必须在内容层**之下**。
##
## 为什么值得单列一条：Godot 里**后加的子节点画在上面**，而"底图铺满 + 内容居中"
## 这件事天然要求两层。顺序写反的后果是**整屏只剩背景**（4:3 下出图实测踩到），
## 而所有"逻辑型"断言照样全绿 —— 它们不看像素。
func _t_menu_layer() -> void:
	print("[7] 主菜单分层（底图在内容层之下）")
	var host := SubViewport.new()
	host.size = Vector2i(1920, 1200)
	add_child(host)
	var m: Variant = MENU.instantiate()
	host.add_child(m)
	await _frames(4)
	var bg: Node = m.get_node_or_null("MenuBg")
	var ct: Variant = m.get("_content")
	_ok(bg != null, "★ 主菜单有底图节点 MenuBg")
	_ok(ct != null, "★ 主菜单有内容居中层")
	if bg != null and ct != null:
		_ok(bg.get_index() < ct.get_index(),
				"★★ 底图下标 %d < 内容层下标 %d（后加的画在上面 ⇒ 底图必须先加）"
				% [bg.get_index(), ct.get_index()])
		_ok(ct.get_child_count() > 4,
				"★ 内容层里挂了 %d 个节点（品牌 / 系统 / 模式 / 卡片…）"
				% ct.get_child_count())
	# 4:3 下内容层居中、尺寸仍是基准
	_ok((ct.size as Vector2).is_equal_approx(LAYOUT.BASE),
			"★ 内容层尺寸 = 基准 1920×1080（实际 %s）" % str(ct.size))
	_ok((ct.position as Vector2).is_equal_approx(Vector2(0, 60)),
			"★★ 4:3（1920×1200）⇒ 内容层 pos (0,60) 实际 %s" % str(ct.position))
	host.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- [8] user:// 迁移

## ★★ 改项目名的**唯一**副作用 = `user://` 目录换名字 ⇒ 老玩家存档"消失"。
##
## 这一段用**两个临时目录**跑迁移逻辑（⛔ 绝不碰玩家真实的 `appdata`）——
## `migrate_between()` 之所以做成"只认路径"的形态，就是为了这里能单测。
## ⚠️ 真实的 `appdata` 目录：`EveUserDir.persist = false` 保证验收一条都不写。
func _t_user_dir() -> void:
	print("[8] user:// 迁移（项目名去掉「918」的收尾）")
	USER_DIR.persist = false
	_ok(USER_DIR.LEGACY_NAME == "EVE自走棋918",
			"★ 旧项目名字面量 = %s（改完名之后再也读不到旧名，⛔ 不能靠推导）"
			% USER_DIR.LEGACY_NAME)
	_ok(not USER_DIR.FILES.is_empty(), "白名单非空（%d 个）" % USER_DIR.FILES.size())
	var all_cfg := true
	for f in USER_DIR.FILES:
		if not String(f).ends_with(".cfg"):
			all_cfg = false
	_ok(all_cfg, "白名单里全是 .cfg（%s）" % str(USER_DIR.FILES))
	_ok(String(USER_DIR._legacy_dir()).get_file() == USER_DIR.LEGACY_NAME,
			"★ 旧目录 = 当前目录的**同级兄弟**（%s）" % String(USER_DIR._legacy_dir()))
	_ok(String(USER_DIR._legacy_dir()) != String(USER_DIR._current_dir()),
			"★ 旧目录 ≠ 当前目录（当前 %s）—— 否则就成了自己复制自己"
			% String(USER_DIR._current_dir()).get_file())

	# ── 用临时目录跑真逻辑 ──
	var base := OS.get_temp_dir().replace("\\", "/").trim_suffix("/") \
			.path_join("evezzq_mig_test")
	var src := base.path_join("legacy")
	var dst := base.path_join("fresh")
	_rm_tree(base)
	DirAccess.make_dir_recursive_absolute(src)
	_write(src.path_join("settings.cfg"), "vol=0.5\n")
	_write(src.path_join("progress.cfg"), "intro_seen=true\n")
	_write(src.path_join("mcp_settings.cfg"), "插件自己的，不该搬\n")
	DirAccess.make_dir_recursive_absolute(src.path_join("logs"))
	_write(src.path_join("logs/x.txt"), "旧日志，不该搬\n")

	var n := USER_DIR.migrate_between(src, dst, true)
	_ok(n == 2, "★ 搬了 2 个（settings/progress），实际 %d" % n)
	_ok(FileAccess.file_exists(dst.path_join("settings.cfg"))
			and FileAccess.file_exists(dst.path_join("progress.cfg")),
			"★ 两个白名单文件到位")
	_ok(not FileAccess.file_exists(dst.path_join("mcp_settings.cfg")),
			"★★ 插件自己的 mcp_*.cfg **没**被搬（白名单之外）")
	_ok(not DirAccess.dir_exists_absolute(dst.path_join("logs")),
			"★★ 子目录（旧日志/截图）**没**被搬 —— ⛔ 不整目录复制")
	_ok(_read(dst.path_join("settings.cfg")) == "vol=0.5\n", "内容逐字节一致")

	# ⚠️ 幂等 + 不覆盖
	var n2 := USER_DIR.migrate_between(src, dst, true)
	_ok(n2 == 0, "★ 再跑一次 ⇒ 0（目标已存在的不动）实际 %d" % n2)
	_write(dst.path_join("progress.cfg"), "改过的\n")
	USER_DIR.migrate_between(src, dst, true)
	_ok(_read(dst.path_join("progress.cfg")) == "改过的\n",
			"★★ 目标已存在 ⇒ **不覆盖**（玩家新存档不会被旧存档顶掉）")

	# ⚠️ 只读 pass / 边界
	var dst2 := base.path_join("fresh2")
	_ok(USER_DIR.migrate_between(src, dst2, false) == 2
			and not DirAccess.dir_exists_absolute(dst2),
			"★ do_write=false ⇒ 只统计不写（数 2、目录没建）")
	_ok(USER_DIR.migrate_between(src, src, true) == 0, "源 = 目标 ⇒ 0（不自复制）")
	_ok(USER_DIR.migrate_between("", dst, true) == 0, "空路径 ⇒ 0（防御）")
	_ok(USER_DIR.migrate_between(base.path_join("nope"), dst, true) == 0,
			"旧目录不存在 ⇒ 0（首次安装的正常路径）")
	_rm_tree(base)
	_ok(not DirAccess.dir_exists_absolute(base), "临时目录已清理")


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f = null


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f = null
	return s


## 递归删临时目录（只在 `OS.get_temp_dir()/evezzq_mig_test` 上用）。
func _rm_tree(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	for sub in d.get_directories():
		_rm_tree(dir.path_join(sub))
	d = null
	DirAccess.remove_absolute(dir)


func _ids(arr: Array) -> Array:
	var out: Array = []
	for b in arr:
		out.append(String(b["id"]))
	return out


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
