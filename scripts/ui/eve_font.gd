extends RefCounted

## EVE 自走棋 —— **字号缩放**（独立于「界面缩放」）
##
## ══════════════════════════════════════════════════════════════════
##  和 `EveUiScale`（界面缩放）的分工，别混
## ══════════════════════════════════════════════════════════════════
##  · **界面缩放**：整幅 2D 画布一起放大 ⇒ 字号与版面**同步**变大。
##    代价是设计空间被压缩（设计高 = 1080 ÷ 倍数），所以底部两条要改贴底。
##  · **字号缩放**（本文件）：**只动字，版面一点不动**。
##    适合「整体比例看着正好、就是字小」，或者两种一起用做细调。
##
## ── 为什么上限定在 1.30 ─────────────────────────────────────────
##  只放大字会撑破**写死高度**的地方：顶条 40px、商店 158px、备战席格带 140px
##  都是设计稿定的数字。1.30 之内它们都还塞得下（实测：见 `verify_ui_scale`
##  的字号段与 `_shots/font_130.png`）；再大就该用「界面缩放」而不是这个。
##
## ── 为什么不改 Theme 的默认字号 ─────────────────────────────────
##  工程里有 **88 处** `add_theme_font_size_override("font_size", N)` ——
##  全是**节点级覆盖**，它**压过** Theme 默认值 ⇒ 改 Theme 一点用都没有。
##  ⇒ 所以把调用点统一收口到 `fs()`（记录设计字号 + 应用实际字号）。
##
## ── 两个入口各管一段 ────────────────────────────────────────────
##  · `fs(node, base)`：**建立时**用（把设计字号乘上当前倍数）。
##  · `s(base)`：**自绘文字**用（`draw_string` 每次画都现算 ⇒ 天然即时生效）。
##  · `reapply(root)`：改滑块时把**已经建好的**控件就地重算。
##    它靠节点上记的**设计字号**（meta）反推，⛔ 不是"再乘一次" ——
##    那样每次拖动都会复利叠上去。

## 设置存档（读一次玩家偏好）
const STORE := preload("res://scripts/core/eve_settings_store.gd")

## 当前倍数。**静态**是为了自绘文字能在任何地方现读（不必拿到实例）。
static var scale := 1.0

## ★★ 2026-10-07 平台**出厂默认**（用户实测定）：
##   · 桌面（Windows）**110%** —— 用户原话「我实测了一下 PC 端是 110% 比较好」。
##   · 移动（安卓）  **120%** —— 实机反馈「字体有点小」；这边只动字，
##     与 `EveUiScale` 的整幅画布放大（移动端默认 1.35）**相乘**，
##     所以这边定 120% 而不是更大（再大商店/备战席的写死高度就塞不下）。
## ⚠️ 只在「玩家没设过」时生效（存档 `font_scale <= 0` ⇒ 见 `load_from_settings`）。
## ⚠️ 它们**不是取值域**：取值域仍是 MIN~MAX，玩家可以调到任何一档。
const DESKTOP_DEFAULT := 1.10
const MOBILE_DEFAULT := 1.20

const MIN_SCALE := 0.80
const MAX_SCALE := 1.30
const STEP := 0.05
## 节点上记「设计字号」的键名。`reapply()` 靠它反推，见顶注。
const META := "_eve_font_base"



## ★ 2026-10-19 安卓线：手机上试「黑体 / 加粗」。
##
## 为什么不往仓库塞字体文件：中文字体动辄十几 MB，且微软雅黑/思源黑体的分发授权要另说。
## SystemFont 走**系统已装字体**（Windows 微软雅黑 / 安卓 Noto Sans CJK），权重 700 = 粗体，
## 不增加包体、也不用管授权；代价是各机型字形略有差异（可接受，正文没变，只是更实）。
static var _heavy: Font = null


static func heavy() -> Font:
	if _heavy == null:
		# [WHY] 网页版没有系统字体，必须用随包分发的子集字体（见 eve_boot.gd）
		if OS.has_feature("web"):
			var wf := load("res://assets/fonts/NotoSansSC-Bold.ttf")
			if wf is Font:
				_heavy = wf
				return _heavy
		var f := SystemFont.new()
		f.font_names = PackedStringArray([
			"Microsoft YaHei UI", "Microsoft YaHei", "SimHei",
			"Noto Sans CJK SC", "Noto Sans SC", "sans-serif",
		])
		f.font_weight = 700
		f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		_heavy = f
	return _heavy


## 把节点字体换成「加粗黑体」（只在移动端调用；桌面保持原字体，避免动到既有出图基线）。
static func heavy_on(node: CanvasItem) -> void:
	if node != null:
		node.add_theme_font_override("font", heavy())

## 设计字号 → 实际字号（自绘文字用；每次调用都按当前倍数算）。
static func s(base: int) -> int:
	return maxi(6, int(round(float(base) * scale)))


## 给控件设字号（**唯一入口**，⛔ 别直接调 `add_theme_font_size_override`）。
##
## ⚠️ 必须记 meta：不记的话 `reapply()` 只能读到"上一次算过的值"，
##    再乘一次就是**复利**（拖几次滑块字就爆了）。
static func fs(node: CanvasItem, base: int) -> void:
	if node == null:
		return
	node.set_meta(META, base)
	node.add_theme_font_size_override("font_size", s(base))


## 改倍数（夹在取值域里）。
static func set_scale(v: float) -> void:
	scale = clampf(v, MIN_SCALE, MAX_SCALE)


## 本平台的出厂默认倍数（桌面 110% / 移动 120%）。
static func default_scale() -> float:
	return MOBILE_DEFAULT if OS.has_feature("mobile") else DESKTOP_DEFAULT


## 开局读盘：把玩家存下来的倍数装进来。
##
## ⚠️ 必须在**建 UI 之前**调（每个场景 `_ready` 的开头）——
##    晚了的话先建出来的那批控件还是旧倍数，`reapply()` 也救不回
##    （它们建的时候就把 `s()` 的结果写进覆盖值了，而 meta 是那时记的，
##     其实能救回来 —— 但没必要让第一帧闪一下）。
static func load_from_settings() -> void:
	var v := float(STORE.load_all().get("font_scale", 0.0))
	# ⚠️ 存 0.0 = 「没设过」的旧文件 / 手改坏了 ⇒ 用**本平台出厂默认**
	#    （桌面 1.10 / 移动 1.20）；⛔ 不是 1.0、也不是夹到 MIN。
	scale = default_scale() if v <= 0.0 else clampf(v, MIN_SCALE, MAX_SCALE)


## ★ 非战斗场景（**主菜单**）不参与字号缩放。
##
## 为什么：主菜单那一版是按 1920×1080 **死坐标**排的（模式按钮只有 62px 高），
## 字一放大就顶破方框 —— 用户 2026-10-07 实测「130% 全超出方框范围了」。
## ⇒ 主菜单 `_ready()` 调本函数把倍数归 1.0（和 `EveUiScale.apply_scene_default`
##   是同一个理由、同一种做法）。
##
## ⚠️ 只改**当前倍数**，不动存档：进战场时 `load_from_settings()` 照样读回来。
static func reset_scale() -> void:
	scale = 1.0


## 把**已经建好的**控件就地重算（滑块要即时生效）。
##
## ⚠️ 只处理带 meta 的控件：没经过 `fs()` 的一律不碰
##    （⛔ 别「凡是有 font_size 覆盖的都乘一遍」—— 那些是别人设的，来源不明）。
static func reapply(root: Node) -> void:
	if root == null:
		return
	_apply_one(root)
	for c in root.get_children():
		reapply(c)


static func _apply_one(n: Node) -> void:
	var c := n as Control
	if c == null or not c.has_meta(META):
		return
	c.add_theme_font_size_override("font_size", s(int(c.get_meta(META))))
