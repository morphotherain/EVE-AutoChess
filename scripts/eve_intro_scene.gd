extends Control
class_name EveIntroScene
## ★ 字号缩放（2026-10-07）：只动字、不动版面（见 eve_font.gd）
const FONT := preload("res://scripts/ui/eve_font.gd")

## 「守卫边境」开场 —— 两段视频 + 对话层，最后进对局。
##
## ★ 三层彻底分开（这是「上一步 / 暂停 / 跳过」能真正工作的前提）：
##   ① 背景  `VideoStreamPlayer`（BgVideo）   —— `mouse_filter = IGNORE`，只播画面
##   ② 末段  `VideoStreamPlayer`（BeaconVideo）—— 信标展开视频，叠在①上面
##   ③ 对话  `EveIntroOverlay`                —— 实时绘制的 Control，按钮是真 Button
##   ⛔ 绝不把 UI 烘进视频 —— 那样三个按钮只是画面上的方块，点不动。
##
## ★ 时间真源是**本脚本的 `_t`**，不是视频的播放位置。
##   理由：末句超出了第一段视频长度（视频 23.104s / 台词到 24.27s），拿视频当钟
##   会在末段冻结；而且无头环境下视频根本不推进，以它为准的话验收就全废了。
##   视频只负责「按指令播 / 停 / 跳」。

const SCRIPT := preload("res://scripts/data/eve_intro_script.gd")
const PROGRESS := preload("res://scripts/core/eve_progress_store.gd")
const OVERLAY := preload("res://scripts/ui/eve_intro_overlay.gd")

const BATTLE_SCENE := "res://scenes/battle_scene.tscn"

## 开场结束（看完 / 跳过）之后去哪。
## 留成变量：验收要测「跳过 ⇒ 写进度存档」，但不希望自检节点被切场景销毁
## ⇒ 自检里把它置空，就只验写盘不真跳。
var next_scene := BATTLE_SCENE

## 片头段结束 → 对话层淡入的时长（秒）。硬切会"啪"一下跳出来。
const RAMP := 0.35
const FADE_3D := 0.45               ## 第一段 → 第二段视频的交叉淡入

## 末段的任务提示（⚠️ 最小版：完整的「任务方框 + 星币教学」还没做）
const TASK_TEXT := "守卫移动式诱导信标 · 共计 15 回合（含事件回合）"

var _lines: Array = []

var _video: VideoStreamPlayer
var _video2: VideoStreamPlayer      ## 信标展开视频（末段）
var _overlay: EveIntroOverlay

var _t := 0.0
var _paused := false
var _line_idx := -2                  ## −2 = 还没评估过；−1 = 无当前句（片头）
var _video2_started := false
var _cinematic := false              ## 末段视频期间：整层让位，只留「跳过对话」
var _prompted := false
var _done := false


func _ready() -> void:
	name = "IntroScene"
	# ★ 字号缩放：对话层与信标标注的字都在建立时定
	FONT.load_from_settings()
	# ⛔ 见 overlay 里的同一条注释：0×0 控件上必须用 and_offsets 版本才会真铺开
	if size == Vector2.ZERO:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_video()
	_build_video2()
	_build_overlay()

	_lines = SCRIPT.build()
	_overlay.bind_lines(_lines)
	_t = 0.0
	_sync_line(true)
	print("[开场] 共 %d 句 · 总长 %.2fs（末段信标视频 %.2f–%.2f，提示 %.2f）"
			% [_lines.size(), SCRIPT.total(), SCRIPT.VIDEO2_IN, SCRIPT.PROMPT_AT, SCRIPT.PROMPT_AT])


# ── ① 背景视频 ───────────────────────────────────────────
func _build_video() -> void:
	_video = VideoStreamPlayer.new()
	_video.name = "BgVideo"
	_video.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_video.expand = true
	_video.mouse_filter = Control.MOUSE_FILTER_IGNORE      # ★ 不吃事件，点击才轮得到 UI
	# ⛔ `autoplay` 默认是 **false** —— 不打开它，视频永远停在第一帧（等于全黑）。
	#    这个坑很隐蔽：Node 建出来了、stream 也载到了、就是不出画面。
	_video.autoplay = true
	_video.stream = load(SCRIPT.VIDEO)
	if _video.stream == null:
		push_warning("[开场] 载不到背景视频 %s —— 只有空格子（Ogg Theora 才认）" % SCRIPT.VIDEO)
	add_child(_video)
	if _video.stream != null:
		_video.play()          # `autoplay` 之外再显式叫一次，两种触发都不落空


# ── ② 末段视频（信标展开）—— 先隐藏，到点才淡入并播放 ─────────
func _build_video2() -> void:
	_video2 = VideoStreamPlayer.new()
	_video2.name = "BeaconVideo"
	_video2.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_video2.expand = true
	_video2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_video2.autoplay = false                     # 由时间轴 `VIDEO2_IN` 触发
	_video2.visible = false
	_video2.modulate = Color(1, 1, 1, 0)         # 初始全透明
	_video2.stream = load(SCRIPT.VIDEO2)
	if _video2.stream == null:
		push_warning("[开场] 载不到信标视频 %s —— 末段会只剩背景最后一帧" % SCRIPT.VIDEO2)
	add_child(_video2)


# ── ③ 对话层 ─────────────────────────────────────────────
func _build_overlay() -> void:
	_overlay = OVERLAY.new()
	add_child(_overlay)
	_overlay.prev_pressed.connect(_on_prev)
	_overlay.next_pressed.connect(_on_next)
	_overlay.pause_toggled.connect(_on_pause)
	_overlay.skip_pressed.connect(_on_skip_talk)
	_overlay.line_skipped.connect(_on_line_skipped)


# ── 主循环 ───────────────────────────────────────────────
func _process(delta: float) -> void:
	if _done:
		return
	if not _paused:
		_t += delta
	_update_video()
	_sync_line(false)
	_update_beacon_video()
	_update_ramp()


## 两段视频：第一段播完停在最后一帧；到点淡入第二段并开始播放。
func _update_video() -> void:
	if _video.stream != null and _t >= SCRIPT.VIDEO_LEN and not _video.paused:
		_video.paused = true             # 停在最后一帧，作为第二段淡入时的底

	if _video2 == null or _video2.stream == null:
		return
	if _t < SCRIPT.VIDEO2_IN:
		_video2.visible = false
		_video2.modulate.a = 0.0
		return
	if not _video2_started:
		_video2_started = true
		_video2.visible = true
		_video2.play()
		print("[开场] 信标视频开始（t=%.2f，时长 %.2fs）" % [_t, SCRIPT.VIDEO2_LEN])
	_video2.modulate.a = clampf((_t - SCRIPT.VIDEO2_IN) / FADE_3D, 0.0, 1.0)


## 按 `_t` 找当前句；变了就换。片头段（没有台词）⇒ 整层不显示。
## ⛔ 末段的任务提示**不归这里管** —— 一旦 `_prompted` 就必须早退，
##    否则 `show_line(-1)` 会把刚写好的任务文字和对话框一起藏掉
##    （踩过：信标展开完成、按钮出来了，任务文字却是空的）。
func _sync_line(force: bool) -> void:
	if _prompted:
		return
	var idx := -1
	for i in range(_lines.size()):
		var L: Dictionary = _lines[i]
		if _t >= float(L["t0"]) and _t < float(L["t1"]):
			idx = i
			break
	# 末句：超出它的 t1 但第二段视频还没开始 ⇒ 继续挂在屏幕上（别提前收掉）
	if idx < 0 and _t >= float(_lines[-1]["t1"]) and _t < SCRIPT.VIDEO2_IN:
		idx = _lines.size() - 1
	if idx != _line_idx or force:
		_line_idx = idx
		_overlay.show_line(idx)
	if idx >= 0:
		var L2: Dictionary = _lines[idx]
		_overlay.set_reveal(int(maxf(0.0, _t - float(L2["t0"])) * float(L2["cps"])))


## 片头段整屏干净；片头结束 → 按 RAMP 淡入
func _update_ramp() -> void:
	var intro_end := 0.0
	for L in _lines:
		if not bool(L["box"]):
			intro_end = float(L["t1"])
			break
	var a := 1.0
	if _t < intro_end:
		a = 0.0
	elif _t < intro_end + RAMP:
		a = (_t - intro_end) / RAMP
	_overlay.set_ui_on(a > 0.001)
	_overlay.modulate = Color(1, 1, 1, a)


## 末段：第二段视频播完 → 出「▶ 进入边境」。
## ★ 视频期间整层让位（`set_cinematic`）：只留一个「跳过对话」按钮，
##   这样 16 秒的镜头也能一键跳过 —— 不至于「点不动」。
func _update_beacon_video() -> void:
	if _t >= SCRIPT.VIDEO2_IN and not _cinematic and not _prompted:
		_cinematic = true
		_overlay.set_cinematic(true)
	if not _prompted and _t >= SCRIPT.PROMPT_AT:
		_prompted = true
		_cinematic = false
		if _video2 != null:
			_video2.paused = true            # 停在传送门完全展开的最后一帧
		_overlay.set_cinematic(false)
		_overlay.show_task(TASK_TEXT)
		_overlay.set_prompt(true)
		print("[开场] 信标视频结束 → 等待「进入边境」")


# ── 按钮 ─────────────────────────────────────────────────

## 上一步：回到**上一句**开头。**视频一起回退** —— 时间轴是按视频排的，
## 只退文字会让音画错位。
## ⚠️ 语义只做一件事：**退到上一句**。曾经写成"刚切过来就再退一句、
##    否则重启本句"，那让同一个按钮有两种行为 —— 玩家没法预期（自检抓到）。
func _on_prev() -> void:
	if _done or _paused:
		return
	var idx := _line_idx
	if idx < 0:
		return
	var target_idx := maxi(idx - 1, 0)
	var t0 := float(_lines[target_idx]["t0"])
	print("[开场] 上一步 → 第 %d 句（t=%.2f）" % [target_idx + 1, t0])
	_t = t0
	_video2_started = false
	_cinematic = false
	_prompted = false
	_overlay.set_prompt(false)
	_overlay.set_cinematic(false)
	if _video2 != null:
		_video2.visible = false
		_video2.paused = true
		_video2.modulate.a = 0.0
		_video2.stream_position = 0.0
	if _video.stream != null:
		_video.modulate.a = 1.0
		_video.paused = false
		_video.stream_position = clampf(t0, 0.0, SCRIPT.VIDEO_LEN - 0.05)
	_sync_line(true)


func _on_pause(on: bool) -> void:
	if _done:
		return
	_paused = on
	_overlay.set_paused(on)
	if _video.stream != null and not (_t >= SCRIPT.VIDEO_LEN):
		_video.paused = on or _t >= SCRIPT.VIDEO_LEN
	if _video2 != null and _video2_started and not _prompted:
		_video2.paused = on
	print("[开场] %s（t=%.2f）" % ["暂停" if on else "继续", _t])


func _on_line_skipped() -> void:
	_overlay.reveal_all()


## 「跳过对话」：跳过整段对话 → 末段（信标视频收尾 + 任务提示）。
##
## ⚠️ 不要再让它直接退对局了 —— 名字改了语义就得跟着改。
##    用户原话：「我以为点跳过是跳过当前对话，原来不是哦」。
##    按钮写「跳过对话」却把人送出开场，那就是同一类谎话。
##    要离开开场，用末段的「▶ 进入边境」。
##
## ★ 2026-11-02 用户反馈：「点击跳过对话总是卡，没到最后根本跳过不了」。
##   原来这里只 `seek(BEACON_IN)`（落在末段**起点**），还得干等 2.3 s 才出提示、
##   再点一次才进边境 ⇒ 看起来就像"没反应"。现在落点是 `SKIP_TO`
##   （只差 RAMP 就到提示），并且**再点一次立刻到提示**，不再原地重播。
func _on_skip_talk() -> void:
	if _done:
		return
	if _prompted:
		_finish("进入边境")            # 末段时这个按钮已经写的是「▶ 进入边境」
		return
	if _t >= SCRIPT.SKIP_TO:
		print("[开场] 跳过对话（已在末段尾）→ 任务提示")
		seek(SCRIPT.PROMPT_AT)
		return
	print("[开场] 跳过对话 → 末段尾（t=%.2f）" % SCRIPT.SKIP_TO)
	seek(SCRIPT.SKIP_TO)


## 「下一步 ▸」：当前句没显示完 ⇒ 先补全；已显示完 ⇒ 跳下一句；最后一句 ⇒ 进末段。
func _on_next() -> void:
	if _done or _paused or _prompted:
		return
	if not _overlay.revealed_all():
		_overlay.reveal_all()
		return
	var idx := _overlay.current_index()
	if idx < 0 or idx >= _lines.size() - 1:
		_on_skip_talk()
		return
	print("[开场] 下一步 → 第 %d 句" % (idx + 2))
	seek(float(_lines[idx + 1]["t0"]))



func _finish(why: String) -> void:
	if _done:
		return
	_done = true
	print("[开场] %s → 进对局（已看过记得写盘）" % why)
	PROGRESS.mark_intro_seen()
	if next_scene != "":
		get_tree().change_scene_to_file(next_scene)


func _unhandled_input(event: InputEvent) -> void:
	if _done or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	# ⛔ 键盘必须读 physical_keycode（工程铁律）
	match event.physical_keycode:
		KEY_SPACE:
			_on_pause(not _paused)
		KEY_ENTER, KEY_KP_ENTER:
			_on_skip_talk()
		KEY_RIGHT:
			_on_next()
		KEY_LEFT, KEY_BACKSPACE:
			_on_prev()
		_:
			return
	get_viewport().set_input_as_handled()


# ── 探针 / 验收用的只读接口 ──────────────────────────────

## 跳到时间 t（探针与自检用）。
## ★ 这是个**纯粹按 t 求值的函数**：调用后画面状态只由 t 决定，与"之前播过什么"无关。
##   两段视频、对话层、任务提示全部按 t 直接摆好（所以这里不用 Tween）。
func seek(t: float) -> void:
	_t = t

	# 第一段视频：跳到对应帧（不然出的是"时间轴在第 10 秒、画面还在第 1 帧"的错位图）
	if _video != null and _video.stream != null:
		_video.stream_position = clampf(t, 0.0, SCRIPT.VIDEO_LEN - 0.05)
		_video.modulate.a = 1.0
		_video.paused = t >= SCRIPT.VIDEO_LEN

	# 第二段视频（信标展开）
	var t2 := t - SCRIPT.VIDEO2_IN
	if _video2 != null and _video2.stream != null:
		if t2 < 0.0:
			_video2_started = false
			_video2.visible = false
			_video2.paused = true
			_video2.modulate.a = 0.0
			_video2.stream_position = 0.0
		else:
			_video2_started = true
			_video2.visible = true
			_video2.modulate.a = clampf(t2 / FADE_3D, 0.0, 1.0)
			# ⛔ 不能「先 paused 再 stream_position」—— 暂停态下解码器不刷新，
			#    画面会停在上一帧（实测：跳到片尾却还显示片头的船）。
			#    必须先 `play()` 再给 `stream_position`，否则 seek 不生效。
			_video2.paused = false
			_video2.play()
			_video2.stream_position = clampf(t2, 0.0, SCRIPT.VIDEO2_LEN - 0.05)

	# 末段形态：视频期间整层让位（只留「跳过对话」），出提示时恢复
	_prompted = t >= SCRIPT.PROMPT_AT
	_cinematic = not _prompted and t >= SCRIPT.VIDEO2_IN
	_overlay.set_cinematic(_cinematic)
	_overlay.set_prompt(_prompted)

	# 台词（`_prompted` 为真时它会早退，不会覆盖下面要写的任务提示）
	_sync_line(true)

	# 任务提示（必须放在 `_sync_line` **之后**）
	if _prompted:
		_overlay.show_task(TASK_TEXT)

	_update_ramp()


func elapsed() -> float:
	return _t


func overlay_ref() -> EveIntroOverlay:
	return _overlay


## 末段信标视频节点（自检用）
func video2_ref() -> VideoStreamPlayer:
	return _video2


# ══════════════════════════════════════════════════════════════════
#  AI 操作面（2026-10-26）—— 开场剧情
# ══════════════════════════════════════════════════════════════════
# 首次开局会先播片头。AI 要能「直接跳过」而不是干等 40 秒。


func ai_kind() -> String:
	return "intro"


func ai_snapshot() -> Dictionary:
	return {
		"scene": "intro",
		"elapsed": elapsed(),
		"done": _done,
		"paused": _paused,
		"line_index": _line_idx,
		"line_count": _lines.size(),
		"next_scene": String(next_scene),
	}


## 下一句 / 结束片头进下一场景。
func ai_next() -> Dictionary:
	if _done:
		return {"ok": false, "reason": "片头已结束"}
	_on_next()
	return {"ok": true}


## 跳过当前对白（不结束整段）。
func ai_skip_talk() -> Dictionary:
	if _done:
		return {"ok": false, "reason": "片头已结束"}
	_on_skip_talk()
	return {"ok": true}


## 直接整段结束 ⇒ 切到 next_scene（通常是战斗场景）。
func ai_finish() -> Dictionary:
	if _done:
		return {"ok": false, "reason": "片头已结束"}
	_finish("ai")
	return {"ok": true}


func ai_pause(on: bool) -> Dictionary:
	_on_pause(on)
	return {"ok": true}


## 拖到第 t 秒（调试 / 复现某一帧用）。
func ai_seek(t: float) -> Dictionary:
	seek(t)
	return {"ok": true}
