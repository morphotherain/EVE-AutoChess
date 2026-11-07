extends "res://scripts/ui/eve_window.gd"

## EVE 自走棋 —— 舰队指挥顶条（裸条，无标题栏）
##
## V3 稿尺寸 680 × 40，位于顶部中央。按云顶之弈的阶段条做法：
## 无边框浮条，不是「窗口」—— 但它仍然可以拖走（拖动挂在整个内容区上）。
##
## 内容分五段（从左到右，各段之间 1px 竖分隔线）：
##   ① 阶段    节点 6 + 阶段标签（普通战 / 精英战 / 首领战）
##   ② 信标    ⛨ 100 —— **一局的生命线**，P0 常驻（交接文档 §11 P0）
##   ③ 计时    阶段名 + 环形进度 + 剩余时间
##   ④ 进度    15 枚方块 = 本局节点进度；Boss 节点描边为橙
##   ⑤ 操作    若全漏代价 / ✦ 开战 / ≡ 设置
##
## ⚠️ 2026-09-20（阶段 A）新增：
##   - 信标段 —— 在此之前 HUD 只有「若全漏代价」没有「信标本身」，
##     而信标是「失败」的唯一载体：不补这一条，玩家永远不知道自己离输还有多远。
##   - 计时段加了阶段名 —— 同一个环在准备阶段是布阵倒计时、
##     在战斗阶段是战斗时限，两者含义不同，必须写出来。
##   - `timer_expired` 信号 —— 倒计时到 0 不再自己绕回来，
##     由主控决定「开打」还是「结束」。
##
## ⚠️ 图标一律用几何字符（✦ ≡），不用 ⚔ 🔒 这类 —— 后者在 Windows 会
##    落到 Segoe UI Emoji 渲染成彩色 emoji，与工程规范冲突（已踩过）。
##
## 变更清单（实装版）：
##   - 五段式布局 + 15 节点进度方块 + 信标
##   - 环形倒计时（自绘，无贴图）
##   - start_battle_requested / settings_requested / timer_expired 三个信号

signal start_battle_requested()
signal settings_requested()
## 倒计时归零（准备阶段到点 / 战斗时限到点）
signal timer_expired()

const NODE_TOTAL := 15
## 首领节点（1-based 的第 9 / 12 / 15 个 = 下标 8 / 11 / 14）
## ⚠️ 与 EveNodeTable.BOSS_INDEXES 同一个口径，改一处必须改两处
##    （自检 tools/verify_run.tscn 会断言两者一致）
## ★ 2026-10-11（i18n）：文案取词（见 `eve_text.gd` 顶注）。
const T := preload("res://scripts/core/eve_text.gd")

const BOSS_NODES: Array[int] = [8, 11, 14]

## ★ 2026-10-28：联机信标排独立成条，与上方菜单拉开距离（用户：「和原来的顶端菜单做个隔断」）。
##   实测「贴在一起」的根因：`content` 的 separation 是 0，且信标排直接挂在 content 上
##   ⇒ 视觉上和顶条同一块底。改成 **8px 空档 + 独立实底面板**。
const VERSUS_STRIP_GAP := 8.0
const VERSUS_STRIP_H_DESKTOP := 44.0
const VERSUS_STRIP_H_MOBILE := 52.0
## 信标排每一格的血条段数（电容式分段条）。
##
## ★ 2026-10-28：连续填充条在「四人并排」时只能看个大概，
##   分段条的读数是**突变**的 —— 掉一格就少一段，一眼数得出来。
const VERSUS_SEGMENTS := 10
## 灭掉的段（比底再暗一点，仍能看出「这里有几格」）
const C_SEG_OFF := Color(0.13, 0.19, 0.22, 0.9)
## 裸条的设计稿高度（= HUD `RECT_TOP` 的 40；撑高时以它为基准，⛔ 别累加）
const BAR_BASE_H := 40.0
## 平台判据走工程唯一真源（⛔ 别在这里写 `OS.has_feature`）
const UI_SCALE := preload("res://scripts/ui/eve_ui_scale.gd")

var node_index: int = 1
var stage_label: String = T.t("BAR_STAGE_DEFAULT", "遭遇战")
var time_left: float = 24.0
var time_total: float = 60.0
## 战败会掉多少信标（预览）。⛔ 原字段名 `leak_damage` 随漏网机制一起删了。
var loss_cost: int = 0
var beacon: int = 100
var beacon_max: int = 100
## 0 = 准备 / 1 = 战斗 / 2 = 结算
var phase: int = 0

var _stage_phase: Label
var _stage_tag: Label
var _beacon_value: Label
var _beacon_icon: EveIcon
## 联机对战信息区（单机时 invisible，不占地方）
var _versus_box: HBoxContainer
var _versus_round: Label
var _versus_kind: Label
var _versus_hp: Label
## 参战人员信标血量排（联机时显示在顶条下方单独一排）
var _versus_row: HBoxContainer
## 信标排的外壳（独立底 + 边框）与它和菜单之间的空档
var _versus_strip: PanelContainer
var _versus_gap: Control
var _versus_clock: Label
var _ring: Control
var _phase_label: Label
var _time_label: Label
var _dots: Array[Control] = []
var _loss_label: Label
var _start_btn: Button
var _settings_btn: Button
var _expired_emitted := false


func _ready() -> void:
	window_title = T.t("BAR_TITLE", "舰队指挥")
	density = Density.BARE
	show_header = false          # 裸条：没有标题栏
	show_status_text = false
	resizable = false            # 顶条不给缩放（它的宽度就是屏宽的一部分）
	draggable = true
	super._ready()
	_build_contents()
	refresh()


func _build_contents() -> void:
	content.add_theme_constant_override("separation", 0)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 0)
	bar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(bar)
	# ── 参战人员信标血量（联机专属，单独一排）──
	# ⚠️ 为什么单独一排而不是塞进上面那行：顶条第一排已经装了
	#    阶段/信标/计时/进度点/操作五组，再挤一排人名血量会让每一项
	#    都窄到读不出来。联机是「多人信息刚需」，值得占独立一行。
	#
	# ★ 2026-10-28：再包一层独立面板 + 8px 空档 —— 之前它直接挂在 content 上，
	#   而 content 的 separation 是 0 ⇒ 和菜单同底同边，像一行没排完的字。
	_versus_gap = Control.new()
	_versus_gap.custom_minimum_size = Vector2(0.0, VERSUS_STRIP_GAP)
	_versus_gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_versus_gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_versus_gap.visible = false
	content.add_child(_versus_gap)

	_versus_strip = PanelContainer.new()
	_versus_strip.custom_minimum_size = Vector2(0.0,
			VERSUS_STRIP_H_MOBILE if UI_SCALE.is_mobile() else VERSUS_STRIP_H_DESKTOP)
	_versus_strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_versus_strip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_versus_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_versus_strip.add_theme_stylebox_override("panel", _versus_strip_box())
	_versus_strip.visible = false
	content.add_child(_versus_strip)

	_versus_row = HBoxContainer.new()
	# 8 + 1px 竖线 + 8 = 格间 17px（竖线本身算隔断，别把 separation 又调回 14）
	_versus_row.add_theme_constant_override("separation", 8)
	_versus_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_versus_row.visible = false
	_versus_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_versus_strip.add_child(_versus_row)

	# ── ① 阶段 ──
	var stage := HBoxContainer.new()
	stage.add_theme_constant_override("separation", 6)
	stage.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(stage)

	_stage_phase = Label.new()
	_stage_phase.text = T.t("BAR_NODE", "节点 %d") % node_index
	_stage_phase.add_theme_color_override("font_color", Color(0.918, 0.969, 0.980))
	FONT.fs(_stage_phase, 14)
	_stage_phase.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	stage.add_child(_stage_phase)

	_stage_tag = Label.new()
	_stage_tag.text = stage_label
	_stage_tag.add_theme_color_override("font_color", C_TEXT_DIM)
	FONT.fs(_stage_tag, 9)
	_stage_tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_stage_tag.add_theme_stylebox_override("normal", _tag_box())
	stage.add_child(_stage_tag)

	bar.add_child(_vline())

	# ── ② 信标（一局的生命线，P0 常驻）──
	var beacon_box := HBoxContainer.new()
	beacon_box.add_theme_constant_override("separation", 5)
	beacon_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(beacon_box)

	_beacon_icon = EveIcon.make(&"beacon", 15, C_HULL, 1.4)
	beacon_box.add_child(_beacon_icon)

	_beacon_value = Label.new()
	_beacon_value.text = "100"
	_beacon_value.add_theme_color_override("font_color", C_HULL)
	FONT.fs(_beacon_value, 15)
	_beacon_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	beacon_box.add_child(_beacon_value)

	var beacon_unit := Label.new()
	beacon_unit.text = T.t("BAR_BEACON", "信标")
	beacon_unit.add_theme_color_override("font_color", C_TEXT_DIM)
	FONT.fs(beacon_unit, 9)
	beacon_unit.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	beacon_box.add_child(beacon_unit)

	bar.add_child(_vline())

	# ── ②b 联机对战信息（单机时不建，占屏比为 0）──
	_versus_box = HBoxContainer.new()
	_versus_box.add_theme_constant_override("separation", 5)
	_versus_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_versus_box.visible = false
	bar.add_child(_versus_box)

	_versus_round = Label.new()
	_versus_round.text = "1-1"
	_versus_round.add_theme_color_override("font_color", C_ACCENT)
	FONT.fs(_versus_round, 12)
	_versus_round.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_versus_box.add_child(_versus_round)

	_versus_kind = Label.new()
	_versus_kind.text = "打怪"
	_versus_kind.add_theme_color_override("font_color", C_TEXT_DIM)
	FONT.fs(_versus_kind, 9)
	_versus_kind.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_versus_kind.add_theme_stylebox_override("normal", _tag_box())
	_versus_box.add_child(_versus_kind)

	_versus_hp = Label.new()
	_versus_hp.text = "你100"
	# ⛔ 这里曾经是 C_HULL（结构红）—— 「4 人」是参战人数、不是损伤，
	#    红色会读成警报。降一档到 C_TEXT_DIM，让红色只留给真正的危险。
	_versus_hp.add_theme_color_override("font_color", C_TEXT_DIM)
	FONT.fs(_versus_hp, 11)
	_versus_hp.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_versus_box.add_child(_versus_hp)

	bar.add_child(_vline())

	# ── ③ 计时 ──
	var timer := HBoxContainer.new()
	timer.add_theme_constant_override("separation", 6)
	timer.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(timer)

	# ⚠️ 同一个环在准备阶段是「布阵倒计时」、在战斗阶段是「战斗时限」，
	#    含义不同 —— 所以必须把阶段名写出来，不能只留一个转圈的表。
	_phase_label = Label.new()
	_phase_label.text = T.t("BAR_PHASE_PREP", "准备")
	_phase_label.add_theme_color_override("font_color", C_ACCENT)
	FONT.fs(_phase_label, 10)
	_phase_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	timer.add_child(_phase_label)

	_ring = _RingGauge.new()
	_ring.custom_minimum_size = Vector2(24, 24)
	timer.add_child(_ring)

	_time_label = Label.new()
	_time_label.text = "00:24"
	_time_label.add_theme_color_override("font_color", Color(0.918, 0.969, 0.980))
	FONT.fs(_time_label, 14)
	_time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	timer.add_child(_time_label)

	bar.add_child(_vline())

	# ── ④ 节点进度 ──
	var dots := HBoxContainer.new()
	dots.add_theme_constant_override("separation", 3)
	dots.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(dots)

	for i in NODE_TOTAL:
		var d := PanelContainer.new()
		d.custom_minimum_size = Vector2(8, 8)
		d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		d.mouse_filter = Control.MOUSE_FILTER_IGNORE
		d.add_theme_stylebox_override("panel", _dot_box(false, false))
		dots.add_child(d)
		_dots.append(d)

	bar.add_child(_vline())

	# ── ⑤ 操作 ──
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(spacer)

	_loss_label = Label.new()
	# ⚠️ 这是**预览**（"这一场输了会掉多少"），不是已经发生的事。
	#    ⛔ 原来写「若全漏 −N」——「漏」字是漏网机制的残留，玩家看不懂，
	#       2026-10-01 改成「战败 −N」。
	_loss_label.text = T.t("BAR_LOSS", "战败 −%d") % 0
	_loss_label.add_theme_color_override("font_color", C_WARN)
	FONT.fs(_loss_label, 10)
	_loss_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_loss_label.add_theme_stylebox_override("normal", _leak_box())
	_loss_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(_loss_label)

	var pad1 := Control.new()
	pad1.custom_minimum_size = Vector2(10, 0)
	pad1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(pad1)

	# 手机端的操作组必须有明确的触控面积。桌面沿用原尺寸，避免改变既有 HUD 密度。
	var action_group := HBoxContainer.new()
	action_group.name = "ActionGroup"
	action_group.add_theme_constant_override("separation", 8)
	action_group.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(action_group)

	var start_btn := Button.new()
	start_btn.text = T.t("BAR_START", "✦ 开战")
	start_btn.custom_minimum_size = Vector2(0, 48 if EveUiScale.is_mobile() else 26)
	start_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	EveButtonTheme.apply(start_btn, "hud_main")
	start_btn.pressed.connect(func(): start_battle_requested.emit())
	action_group.add_child(start_btn)
	_start_btn = start_btn

	var set_btn := Button.new()
	set_btn.name = "SettingsButton"
	set_btn.text = T.t("BAR_SETTINGS", "设置") if EveUiScale.is_mobile() else "≡"
	set_btn.tooltip_text = T.t("BAR_SETTINGS_TIP",
			"打开设置")
	set_btn.custom_minimum_size = Vector2(88 if EveUiScale.is_mobile() else 26,
			48 if EveUiScale.is_mobile() else 26)
	set_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	EveButtonTheme.apply(set_btn, "hud")
	set_btn.pressed.connect(func(): settings_requested.emit())
	action_group.add_child(set_btn)
	_settings_btn = set_btn


## 竖分隔线（自带左右 12px / 上下 11px 留白，免得线顶满 40px 显硬）
func _vline() -> Control:
	var v := ColorRect.new()
	v.color = Color(0.42, 0.55, 0.60, 0.28)
	v.custom_minimum_size = Vector2(1, 0)
	v.size_flags_vertical = Control.SIZE_FILL
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 用 MarginContainer 包一层给上下留白，免得竖线顶满 40px 显得很硬
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_left", 12)
	wrap.add_theme_constant_override("margin_right", 12)
	wrap.add_theme_constant_override("margin_top", 11)
	wrap.add_theme_constant_override("margin_bottom", 11)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(v)
	return wrap


func _tag_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.42, 0.55, 0.60, 0.18)
	sb.border_color = Color(0.42, 0.55, 0.60, 0.40)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 5
	sb.content_margin_right = 5
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb


func _leak_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.282, 0.188, 0.102, 0.45)
	sb.border_color = Color(0.878, 0.522, 0.302, 0.50)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb


func _dot_box(done: bool, boss: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(0)
	sb.set_border_width_all(1)
	if done:
		sb.bg_color = Color(0.52, 0.76, 0.55, 0.55)
		sb.border_color = Color(0.52, 0.76, 0.55, 0.75)
	elif boss:
		sb.bg_color = Color(0.55, 0.78, 0.82, 0.12)
		sb.border_color = Color(0.878, 0.522, 0.302, 0.80)
	else:
		sb.bg_color = Color(0.55, 0.78, 0.82, 0.12)
		sb.border_color = Color(0.55, 0.78, 0.82, 0.42)
	return sb


# ------------------------------------------------------------------ 刷新

const PHASE_NAMES: Array[String] = ["准备", "交战", "结算"]
## 与 `PHASE_NAMES` **一一对应**的 key（⛔ 顺序不许错）。
const PHASE_KEYS: Array[String] = [
	"BAR_PHASE_PREP", "BAR_PHASE_BATTLE", "BAR_PHASE_RESOLVE",
]


## 把当前状态刷进 UI。战斗主控每帧或状态变化时调一次。
func refresh() -> void:
	_stage_phase.text = T.t("BAR_NODE", "节点 %d") % node_index
	_stage_tag.text = stage_label
	_loss_label.text = T.t("BAR_LOSS", "战败 −%d") % loss_cost
	_refresh_beacon()

	var ph := clampi(phase, 0, PHASE_NAMES.size() - 1)
	_phase_label.text = T.t(PHASE_KEYS[ph], PHASE_NAMES[ph])
	_phase_label.add_theme_color_override("font_color",
			[C_ACCENT, C_WARN, C_OK][ph])

	# ★ 2026-11-07（新手模式 / 事件节点）：`time_total <= 0` = **本阶段没有倒计时**。
	#
	#   [WHY] 以前一律按 `00:00` + 走满的环画 —— 新手模式的准备/交战阶段传的
	#         正是 0，画出来读作「已经超时」，玩家会以为系统卡住了。
	#         事件节点（本来就没有时限）也是同一副样子，顺手一起修。
	#   ⚠️ 环收起后不留空：它和 `_time_label` 都在顶条的 `timer` 横向容器里。
	var untimed := time_total <= 0.0
	if _ring != null:
		_ring.visible = not untimed
	if untimed:
		_time_label.text = "不限时"
	else:
		_time_label.text = "%02d:%02d" % [int(time_left) / 60, int(time_left) % 60]
	if _ring != null:
		_ring.set("progress", 0.0 if untimed
				else clampf(1.0 - time_left / maxf(0.001, time_total), 0.0, 1.0))
		_ring.queue_redraw()

	for i in _dots.size():
		var done := i < node_index - 1
		var cur := i == node_index - 1
		var boss := BOSS_NODES.has(i)
		var box := _dot_box(done or cur, boss)
		if cur:
			box.bg_color = C_ACCENT
			box.border_color = Color(0.875, 0.949, 0.965)
		_dots[i].add_theme_stylebox_override("panel", box)


## 信标读数与配色。
## 三段色带对齐工程语义色：>60% 正常绿 / >30% 警告橙 / 其余结构红。
func _refresh_beacon() -> void:
	if _beacon_value == null:
		return
	_beacon_value.text = str(beacon)
	var ratio := float(beacon) / maxf(1.0, float(beacon_max))
	var col := C_OK
	if ratio <= 0.30:
		col = C_HULL
	elif ratio <= 0.60:
		col = C_WARN
	_beacon_value.add_theme_color_override("font_color", col)
	if _beacon_icon != null:
		_beacon_icon.set_color(col)


## 刷新联机对战信息条。
##
## `rows` = [{name, hp, is_ai, alive}]，`round` = "2-3"，`kind` = "打怪"/"PvP"/"事件"
##
## ⚠️ 单机模式下根本不调它，_versus_box 保持 invisible ⇒ 占屏比一个像素不变。
## 刷新联机信息：第一排放回合与类型，第二排放全员信标血量。
##
## rows = [{name, hp, is_ai, alive}]，已按名次排好。
## Round clock. expired = time is up (the round is a loss).
func set_versus_clock(text: String, expired: bool) -> void:
	if _versus_clock == null:
		return
	_versus_clock.text = text
	_versus_clock.add_theme_color_override("font_color", C_HULL if expired else C_TEXT)
	_versus_clock.tooltip_text = "回合时限：到点没分出胜负就判负" if not expired else "已超时"


## 信标排的外壳。
##
## ★ 2026-10-28 第二轮（用户：「不够美观」）：⛔ 去掉四周 1px 边框 ——
##   上一版把 2px 顶边 + 四周 1px 一起画，44px 高的窄条被框成了一块
##   「第二排菜单」。现在只留顶部 **1px 弱青线**：它就是「隔断」的视觉落点，
##   其余三边交给更暗的底色自己收口。读起来是「嵌在主菜单下方的一条仪表带」。
func _versus_strip_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.035, 0.048, 0.056, 0.93)
	sb.border_width_top = 1
	sb.border_color = Color(0.55, 0.78, 0.82, 0.22)
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 5.0
	sb.content_margin_bottom = 5.0
	return sb


## 信标排显形后把裸条**撑高**。
##
## ⛔ 必须撑：`EveWindow` 的内容宿主是 `clip_contents = true`，而顶条高度由 HUD 的
##    `RECT_TOP` 定死 40 ⇒ 第二排会被直接裁掉（实测：strip.visible=true，画面上没有）。
## ⚠️ 用 `set_window_height()`（把 `_height_owned` 置真）而不是自己改 `size`：
##    否则 HUD 下一次 `set_window_rect()` 会把高度按设计稿 40 改回去。
func _fit_versus_height() -> void:
	var add := VERSUS_STRIP_GAP
	add += VERSUS_STRIP_H_MOBILE if UI_SCALE.is_mobile() else VERSUS_STRIP_H_DESKTOP
	var target := BAR_BASE_H + add
	if absf(target - _base_rect.size.y) > 0.5:
		set_window_height(target)


## 格间 1px 竖线（上下各缩 9px，不顶满条高）。
##
## ⚠️ 顶满的竖线会把窄条切成一张「表格」；缩进之后才像仪表的分栏。
func _strip_div() -> Control:
	var v := ColorRect.new()
	v.color = Color(0.42, 0.55, 0.60, 0.24)
	v.custom_minimum_size = Vector2(1, 0)
	v.size_flags_vertical = Control.SIZE_FILL
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_top", 9)
	wrap.add_theme_constant_override("margin_bottom", 9)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(v)
	return wrap


## 十段电容式血条：`lit` 段亮、其余段暗。
##
## 为什么不用连续填充条：四人并排时连续条只能看个大概，
## 「掉了 1 格」在分段条上是**突变**、一眼数得出来；
## 也避免和顶条的信标连续条撞形（同一屏两种血条长得一样会读错对象）。
func _seg_bar(ratio: float, color: Color, h: float) -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 2)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lit := int(round(clampf(ratio, 0.0, 1.0) * float(VERSUS_SEGMENTS)))
	for i in VERSUS_SEGMENTS:
		var seg := ColorRect.new()
		seg.custom_minimum_size = Vector2(2.0, h)
		seg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		seg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		seg.color = color if i < lit else C_SEG_OFF
		bar.add_child(seg)
	return bar


## 一格席位：`▍01 名字 AI ▮▮▮▮▮▮▮▮▯▯ 100`
##
## ★ 2026-10-28 第二轮改版要点（用户：「不够美观，弄个符合我们 UI 特性又美观点的」）：
##   ① 名字不再带 `[AI] ` 前缀 —— 前缀把名字挤成两截；AI 改成右侧**固定 16px 角标**，
##      人类那一格留空（都留同宽，四格才等宽）；
##   ② 名次 `%02d` 定宽 + 微字号：是「榜单」的读法，不是「序号」；
##   ③ 自己那格左侧 2px 青色竖条：四人同色时唯一能一眼定位「我在哪」的标记；
##   ④ 淘汰格显示 `—` 而不是 `X`（`X` 像未加载的占位符）。
func _seat_cell(idx: int, r: Variant, pip_h: float) -> HBoxContainer:
	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 5)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var alive := bool(r.get("alive", true))
	var mine := not bool(r.get("is_ai", false))
	var hp := int(r.get("hp", 0))
	var ratio := clampf(float(hp) / 100.0, 0.0, 1.0)
	# 三段色带与顶条信标读数同一口径：>60 正常绿 / >30 警告橙 / 其余结构红
	var band := C_HULL
	if ratio > 0.6:
		band = C_OK
	elif ratio > 0.3:
		band = C_WARN
	# 淘汰：整格压暗，但仍可读（玩家要能看见「谁出局了」）
	cell.modulate.a = 1.0 if alive else 0.45

	if mine:
		var mark := ColorRect.new()
		mark.color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.85)
		mark.custom_minimum_size = Vector2(2.0, pip_h + 4.0)
		mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(mark)

	var rk := Label.new()
	rk.text = "%02d" % (idx + 1)
	rk.custom_minimum_size = Vector2(16, 0)
	rk.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rk.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	FONT.fs(rk, 10)
	rk.add_theme_color_override("font_color", C_ACCENT if mine else C_TEXT_FAINT)
	cell.add_child(rk)

	var nm := Label.new()
	nm.text = String(r.get("name", "?"))
	nm.custom_minimum_size = Vector2(40, 0)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	FONT.fs(nm, 13)
	var nc := C_TEXT if alive else C_TEXT_FAINT
	if mine and alive:
		nc = C_ACCENT
	nm.add_theme_color_override("font_color", nc)
	cell.add_child(nm)

	var tag := Label.new()
	tag.text = "AI" if bool(r.get("is_ai", false)) else ""
	tag.custom_minimum_size = Vector2(16, 0)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	FONT.fs(tag, 9)
	tag.add_theme_color_override("font_color", C_TEXT_FAINT)
	cell.add_child(tag)

	cell.add_child(_seg_bar(ratio if alive else 0.0, band, pip_h))

	var hv := Label.new()
	hv.text = str(hp) if alive else "—"
	hv.custom_minimum_size = Vector2(30, 0)
	hv.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hv.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	FONT.fs(hv, 14)
	hv.add_theme_color_override("font_color", band if alive else C_TEXT_FAINT)
	cell.add_child(hv)
	return cell


func set_versus(round: String, kind: String, rows: Array) -> void:
	if _versus_box == null or _versus_row == null:
		return
	_versus_box.visible = true
	_versus_row.visible = true
	# ★ 2026-10-28：外壳与空档一起显形（单机两者恒隐 ⇒ 占屏不变）
	if _versus_gap != null:
		_versus_gap.visible = true
	if _versus_strip != null:
		_versus_strip.visible = true
	_fit_versus_height()
	_versus_round.text = round
	_versus_kind.text = kind
	_versus_hp.text = "%d 人" % rows.size()
	if _versus_clock == null:
		_versus_clock = Label.new()
		_versus_clock.custom_minimum_size = Vector2(44, 0)
		_versus_clock.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		FONT.fs(_versus_clock, 12)
		_versus_box.add_child(_versus_clock)
	# 第二排：每人一格（格与格之间由 `_strip_div()` 的 1px 竖线分开）。
	# ★ 2026-10-28 第二轮：渲染细节全部搬进 `_seat_cell()`，
	#   这里只负责「清空 → 按名次铺格 → 插竖线」。
	for ch in _versus_row.get_children():
		_versus_row.remove_child(ch)
		ch.queue_free()
	var pip_h := 12.0 if not UI_SCALE.is_mobile() else 13.0
	for idx in rows.size():
		if idx > 0:
			_versus_row.add_child(_strip_div())
		_versus_row.add_child(_seat_cell(idx, rows[idx], pip_h))


func set_stage(index: int, label: String, total_time: float) -> void:
	node_index = clampi(index, 1, NODE_TOTAL)
	stage_label = label
	time_total = total_time
	time_left = total_time
	_expired_emitted = false
	refresh()


## 切换阶段（0 准备 / 1 战斗 / 2 结算）
func set_phase(p: int) -> void:
	phase = clampi(p, 0, PHASE_NAMES.size() - 1)
	refresh()


## 信标结构值 + 上限（上限只在紧急维修 / 事件回复时才有意义，默认 100）
func set_beacon(value: int, max_value: int = -1) -> void:
	beacon = maxi(0, value)
	if max_value > 0:
		beacon_max = max_value
	refresh()


## 开战按钮的文案随阶段变 —— 同一个按钮在准备阶段是「开战」、
## 结算阶段是「下一节点」、结局是「再来一局」。
## 不写清楚的话，玩家在结算阶段会以为点了没用（其实那是推进节点）。
func set_start_button(text: String, enabled: bool = true) -> void:
	if _start_btn == null:
		return
	_start_btn.text = text
	_start_btn.disabled = not enabled
	_start_btn.modulate = Color(1, 1, 1, 1.0 if enabled else 0.45)


## 联机对战：**把开战按钮整个撤掉**。
##
## 2026-10-27 用户定案：「一切都以倒计时为最终判断」。
## 理由：手动开战等于给「想得快的人」一个快进开关 —— 他提前点开打，
## 别人还在凑羁绊，节奏就被拖走了。统一时钟才是公平的裁判。
## ⚠️ 只改 visible，不改 disabled：`set_start_button` 每回合都会重写
##    text/disabled/modulate，但**不碰 visible** ⇒ 藏一次就一直是藏的。
func set_start_visible(on: bool) -> void:
	if _start_btn == null:
		return
	_start_btn.visible = on


## 推进倒计时。归零后**停在 0 并广播一次** `timer_expired`，
## 由主控决定下一步（准备阶段到点 = 开打；战斗时限到点 = 由模拟器收尾）。
##
## ⚠️ 旧实现到 0 就自己绕回起点（"让环一直转着"）—— 那是回合制没接上时的占位。
##    现在真接上了，再自己绕回去就等于「倒计时可以无限循环」，玩家没有压力。
func tick(delta: float) -> void:
	if time_left <= 0.0:
		return
	time_left = maxf(0.0, time_left - delta)
	refresh()
	if time_left <= 0.0 and not _expired_emitted:
		_expired_emitted = true
		timer_expired.emit()


# ------------------------------------------------------------------ 自绘环形倒计时

class _RingGauge extends Control:
	var progress: float = 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 2.2
		if r <= 1.0:
			return
		draw_arc(c, r, 0.0, TAU, 40, Color(0.42, 0.55, 0.60, 0.32), 2.4, true)
		if progress <= 0.001:
			return
		var start := -PI * 0.5
		draw_arc(c, r, start, start + TAU * progress, 40,
				Color(0.549, 0.780, 0.820), 2.4, true)
