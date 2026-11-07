extends Node

## 开场剧情自检（无头）
##
## 跑法：
##   "$GODOT_BIN" --headless \
##     --path . --quit-after 900 \
##     res://tools/verify_intro.tscn
##
## ── 本文件里**刻意造错就必挂**的反向注入检查（没有这些等于没牙齿）──────
##   ① 片头段（0 ~ 2.6s）UI 层必须**整层不可见** —— 改回"只藏框不藏带子"就挂
##   ② 背景视频层必须 `MOUSE_FILTER_IGNORE` —— 让它 STOP（吃掉点击）就挂
##   ③ 三个按钮必须 `MOUSE_FILTER_STOP` 且能发出信号 —— 只是"画上去"就挂
##   ④ 暂停后时间真源 `_t` 必须**一动不动** —— 只是把按钮变灰就挂
##   ⑤ 「上一步」必须把 `_t` 拉回上一句的 t0（而不是只清一下画面）—— 糊弄就挂
##   ⑥ 末段信标**视频**：VIDEO2_IN 之前必须隐藏、之后必须淡入并播到 PROMPT_AT —— 提前露头/不播都挂
##   ⑦ 「首次 / 非首次」的判定必须**随进度存档翻转** —— 写死成两句话就挂
##   ⑧ 「下一步」两段行为必须都在：没显示完 ⇒ 只补全（时间不动）；显示完 ⇒ 真跳下一句
##   ⑨ 「跳过对话」必须**一步到末段尾**（SKIP_TO），且再点一次就能进边境 —— 只把人送到末段起点就挂
##
## ⚠️ 关键不变量禁用 assert（release 会剥离）⇒ 一律 push_warning + 计数。
## ⚠️ 本文件会**动玩家的进度存档** ⇒ 开头存快照、结尾原样写回（工程铁律）。

const INTRO_SCENE := preload("res://scenes/intro_scene.tscn")
const SCRIPT := preload("res://scripts/data/eve_intro_script.gd")
const PROGRESS := preload("res://scripts/core/eve_progress_store.gd")
## user:// 迁移（主菜单 `_ready` 会随启动调一次）—— 验收里必须关掉写盘
const EveUserDir := preload("res://scripts/core/eve_user_dir.gd")
const MENU_SCENE := preload("res://scenes/main_menu.tscn")

const MENU_PATH := "res://scenes/main_menu.tscn"
const BATTLE_SCENE := "res://scenes/battle_scene.tscn"

const MENU_INTRO := "res://scenes/intro_scene.tscn"
const MENU_BATTLE := "res://scenes/battle_scene.tscn"

var _pass: int = 0
var _fail: int = 0
var _intro: Variant = null
var _overlay: Variant = null
var _video2: Variant = null
var _saved: Dictionary = {}


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("PASS  %s" % what)
	else:
		_fail += 1
		push_warning("[verify_intro] FAIL  %s" % what)
		print("FAIL  %s" % what)


func _ready() -> void:

	# ⛔ 验收**不许**去搬玩家的真实存档目录（下面会实例化主菜单，它的 `_ready` 会调迁移）
	EveUserDir.persist = false

	print("=".repeat(62))
	print("开场剧情自检")
	print("=".repeat(62))

	# ── 存档快照（结尾原样写回，验收不许改玩家数据）──
	_saved = PROGRESS.load_all()

	_phase_scene_and_layers()
	await _phase_intro_clean()
	await _phase_dialogue()
	await _phase_buttons()
	await _phase_beacon_video()
	_phase_progress()
	await _check_menu_wiring()

	# ── 还原存档 ──
	PROGRESS.save_all(_saved)
	print("[存档] 已还原到自检前的状态：intro_seen = %s" % str(_saved["intro_seen"]))

	print("=".repeat(62))
	print("结果：%d 项通过 · %d 项失败" % [_pass, _fail])
	if _fail > 0:
		print("⚠️ 有失败项 —— 见上面的 FAIL 行")
	print("=".repeat(62))
	if _intro != null and is_instance_valid(_intro):
		_intro.queue_free()
	await get_tree().process_frame
	# ★ 2026-10-10（审查 R07）：失败 ⇒ 非零退出码
	get_tree().quit(1 if _fail > 0 else 0)


# ─────────────────────────────────────────────── ① 场景与分层
func _phase_scene_and_layers() -> void:
	print("\n[1] 场景与分层（视频 / 对话 / 3D 必须是三层）")
	_ok(ResourceLoader.exists(MENU_PATH), "主界面场景存在")
	_ok(ProjectSettings.get_setting("application/run/main_scene") == MENU_PATH,
			"主场景仍是主界面（没被开场场景顶掉）")
	_ok(ResourceLoader.exists(BATTLE_SCENE), "对局场景存在")

	_intro = INTRO_SCENE.instantiate()
	add_child(_intro)
	_intro.process_mode = Node.PROCESS_MODE_DISABLED     # 先冻住，用 seek 做确定性断言

	var vid: Node = _intro.get_node_or_null("BgVideo")
	_ok(vid != null, "背景视频层存在（BgVideo）")
	if vid != null:
		_ok(vid is VideoStreamPlayer, "背景层是 VideoStreamPlayer")
		# ★ 反向注入①：视频若吃掉点击，三个按钮永远收不到事件
		_ok((vid as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE,
				"★ 背景视频 mouse_filter = IGNORE（不吃点击）")
		var vs: Variant = (vid as VideoStreamPlayer).stream
		_ok(vs != null, "背景视频已加载")
		if vs != null:
			# 实测结论：Godot 4.7 的 VideoStream 只认 ogv（Ogg Theora），mp4 连 .import 都不生成
			_ok(vs.get_class() == "VideoStreamTheora",
					"★ 视频格式 = Ogg Theora（实际 %s；mp4 引擎不认）" % vs.get_class())

	var seg: Node = _intro.get_node_or_null("BeaconVideo")
	_ok(seg != null, "末段信标视频层存在（BeaconVideo）")
	if seg != null:
		_ok(seg is VideoStreamPlayer, "末段是 VideoStreamPlayer")
		_ok((seg as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE,
				"信标视频层不吃点击")
		var vs2: Variant = (seg as VideoStreamPlayer).stream
		_ok(vs2 != null, "信标视频已加载（%s）" % SCRIPT.VIDEO2)
		if vs2 != null:
			_ok(vs2.get_class() == "VideoStreamTheora",
					"★ 信标视频格式 = Ogg Theora（实际 %s）" % vs2.get_class())
		# 🚫 反向注入：末段视频提前露头 = 片头画面被盖住
		_ok(not (seg as CanvasItem).visible, "VIDEO2_IN 之前信标视频是隐藏的")

	_overlay = _intro.overlay_ref()
	_video2 = _intro.video2_ref()
	_ok(_overlay != null, "对话层存在")
	_ok(_video2 != null, "信标视频节点可访问")
	_ok(_overlay.get_parent() == _intro and _overlay != vid,
			"对话层与视频层是**两个独立节点**（不是同一棵子树）")
	if seg != null and vid != null:
		_ok(seg.get_index() > vid.get_index(),
				"信标视频叠在背景视频**之上**（子节点顺序 %d > %d）"
				% [seg.get_index(), vid.get_index()])

# ─────────────────────────────────────────────── ② 片头整屏干净
func _phase_intro_clean() -> void:
	print("\n[2] 片头段整屏干净（本次改动的核心）")
	_intro.seek(0.30)
	await get_tree().process_frame
	_ok(not _overlay.visible or _overlay.modulate.a <= 0.001,
			"★ 反向注入①：t=0.30 片头中段 UI 整层不可见（a=%.2f）" % _overlay.modulate.a)
	_intro.seek(2.50)
	await get_tree().process_frame
	_ok(not _overlay.visible or _overlay.modulate.a <= 0.001,
			"★ t=2.50 片头末段仍不可见")
	_intro.seek(2.80)
	await get_tree().process_frame
	_ok(_overlay.visible and _overlay.modulate.a > 0.05 and _overlay.modulate.a < 0.95,
			"t=2.80 淡入进行中（a=%.2f，不是硬切）" % _overlay.modulate.a)
	_intro.seek(4.00)
	await get_tree().process_frame
	_ok(_overlay.visible and _overlay.modulate.a >= 0.99,
			"t=4.00 片头结束后完全可见（a=%.2f）" % _overlay.modulate.a)


# ─────────────────────────────────────────────── ③ 对话内容
func _phase_dialogue() -> void:
	print("\n[3] 对话内容按时间码驱动")
	var lines := SCRIPT.build()
	_ok(lines.size() == 13, "台词表 13 句（实际 %d）" % lines.size())
	_ok(lines.size() > 1 and not bool(lines[0]["box"]), "第 1 行是片头（无台词 ⇒ 不出框）")

	_intro.seek(3.20)
	await get_tree().process_frame
	_ok(_overlay.current_index() == 1, "t=3.20 当前是第 2 句（实际 idx=%d）" % _overlay.current_index())
	var body: Label = _overlay.get_node("DialogueBox/Body")
	var spk: Label = _overlay.get_node("DialogueBox/Speaker")
	_ok(spk.text == "玩家", "说话人是「玩家」（实际 %s）" % spk.text)
	_ok(body.text == String(lines[1]["text"]), "台词文本与表一致")

	# 逐字：同一句更早的时刻，显示的字数必须更少
	_intro.seek(2.66)
	await get_tree().process_frame
	var early: int = body.visible_characters
	_intro.seek(4.10)
	await get_tree().process_frame
	var late: int = body.visible_characters
	_ok(early < late, "★ 逐字显示生效（t=2.66 显示 %d 字 < t=4.10 显示 %d 字）" % [early, late])
	_ok(late >= String(lines[1]["text"]).length(), "到时间后整句显示完")

	_intro.seek(SCRIPT.PROMPT_AT + 0.10)
	await get_tree().process_frame
	_ok(body.text.contains("15 回合"), "末段改成任务提示（含「15 回合」）：%s" % body.text)
	_ok(spk.text == "本局任务", "任务提示的抬头是「本局任务」（实际 %s）" % spk.text)


# ─────────────────────────────────────────────── ④ 按钮真的能点
func _phase_buttons() -> void:
	print("\n[4] 上一步 / 下一步 / 暂停 / 跳过对话 —— 必须真能点、真起作用")
	# 先回到对话中段 —— 上一阶段结尾停在末段（任务提示态），
	# 那时主按钮写的是「▶ 进入边境」，直接断文案会假失败
	_intro.seek(8.00)
	await get_tree().process_frame
	var row: Node = _overlay.get_node("Buttons")
	var prev: Button = _overlay.button("Prev")
	var nxt: Button = _overlay.button("Next")
	var pause: Button = _overlay.button("Pause")
	var skip: Button = _overlay.button("Skip")
	_ok(prev != null and nxt != null and pause != null and skip != null,
			"四个按钮都建出来了（Prev/Next/Pause/Skip）")
	_ok(skip != null and skip.text == "跳过对话",
			"「跳过」已改名「跳过对话」（实际 %s）" % ("" if skip == null else skip.text))
	for b in [prev, nxt, pause, skip]:
		if b == null:
			continue
		_ok(b.mouse_filter == Control.MOUSE_FILTER_STOP,
				"★ 反向注入③：按钮「%s」mouse_filter = STOP（能收鼠标）" % b.text)
		_ok(b.disabled == false, "按钮「%s」初始可点" % b.text)
		_ok(b.pressed.get_connections().size() > 0,
				"按钮「%s」pressed 已接线（不是画上去的死方块）" % b.text)
	_ok(row != null, "按钮行存在")

	# ── 暂停：点按钮 → 时间真源冻住 ──
	_intro.seek(9.00)
	await get_tree().process_frame
	_intro.process_mode = Node.PROCESS_MODE_INHERIT
	await get_tree().process_frame
	await get_tree().process_frame
	var t_run: float = _intro.elapsed()
	_ok(t_run > 9.0, "恢复处理后有推进（t=%.3f）" % t_run)
	pause.pressed.emit()
	await get_tree().process_frame
	_ok(_overlay.is_paused(), "点「暂停」后进入暂停态")
	_ok(pause.text == "继续", "暂停按钮文案变成「继续」（实际 %s）" % pause.text)
	var t_a: float = _intro.elapsed()
	await get_tree().process_frame
	await get_tree().process_frame
	var t_b: float = _intro.elapsed()
	_ok(absf(t_b - t_a) < 1e-6, "★ 反向注入④：暂停期间时间真源一动不动（%.5f → %.5f）" % [t_a, t_b])
	pause.pressed.emit()
	await get_tree().process_frame
	_ok(not _overlay.is_paused(), "再点一次恢复运行")
	_ok(pause.text == "暂停", "按钮文案变回「暂停」")

	# ── 上一步：必须把时间真源拉回上一句的 t0 ──
	var lines := SCRIPT.build()
	# ⚠️ 先把处理冻住再点「上一步」：否则 `_process` 会在这一帧里把 `_t`
	#    往前推一点（实测 0.035s = 一帧），断言会变成"差一帧"的假失败。
	_intro.process_mode = Node.PROCESS_MODE_DISABLED
	_intro.seek(float(lines[6]["t0"]) + 0.60)     # 停在第 7 句中间
	await get_tree().process_frame
	_ok(_overlay.current_index() == 6, "先站到第 7 句（实际 idx=%d）" % _overlay.current_index())
	var want := float(lines[5]["t0"])
	prev.pressed.emit()
	await get_tree().process_frame
	_ok(absf(_intro.elapsed() - want) < 1e-3,
			"★ 反向注入⑤：点「上一步」回到上一句 t0=%.3f（实际 %.3f）" % [want, _intro.elapsed()])
	_ok(_overlay.current_index() == 5, "上一步后当前句 = 第 6 句（实际 idx=%d）" % _overlay.current_index())

	# ── 下一步：两段行为都要在 ──
	var n_before := float(lines[3]["t0"]) + 0.10
	_intro.seek(n_before)
	await get_tree().process_frame
	_ok(not _overlay.revealed_all(), "先停在第 4 句刚开始（词还没打完）")
	var t_before: float = _intro.elapsed()        # ⚠️ `_intro` 是 Variant ⇒ 必须显式标类型
	nxt.pressed.emit()
	await get_tree().process_frame
	_ok(_overlay.revealed_all(), "★ 反向注入⑧-a：点「下一步」先把当前句补全")
	_ok(absf(_intro.elapsed() - t_before) < 1e-4,
			"补全那一下**不跳时间**（%.3f → %.3f）" % [t_before, _intro.elapsed()])
	nxt.pressed.emit()
	await get_tree().process_frame
	_ok(_overlay.current_index() == 4,
			"★ 反向注入⑧-b：再点「下一步」才真进下一句（实际 idx=%d）" % _overlay.current_index())

	# ── 跳过对话：必须一步到末段尾，不许直接退对局 ──
	_intro.next_scene = ""                       # 保险：万一它真想切场景也不会把自检干掉
	_intro.seek(5.00)
	await get_tree().process_frame
	_ok(_overlay.current_index() == 2, "先停在对话中段（实际 idx=%d）" % _overlay.current_index())
	skip.pressed.emit()
	await get_tree().process_frame
	_ok(absf(_intro.elapsed() - SCRIPT.SKIP_TO) < 1e-3,
			"★ 反向注入⑨：「跳过对话」一步到位 SKIP_TO=%.2f（实际 %.2f）"
			% [SCRIPT.SKIP_TO, _intro.elapsed()])
	_ok(_intro.elapsed() < SCRIPT.PROMPT_AT,
			"跳过对话**没跳过头**到任务提示（%.2f < %.2f）" % [_intro.elapsed(), SCRIPT.PROMPT_AT])
	_ok(_intro.elapsed() >= SCRIPT.SKIP_TO - 1e-3,
			"落点已经贴近提示（只差 %.2fs，不再干等整段）"
			% (SCRIPT.PROMPT_AT - SCRIPT.SKIP_TO))
	# ★ 用户反馈的核心：「跳过之后还要再等/再点一次」—— 现在就验第二次点能直达提示
	skip.pressed.emit()
	await get_tree().process_frame
	_ok(_intro.elapsed() >= SCRIPT.PROMPT_AT - 1e-3,
			"★ 在末段尾再点一次 ⇒ 立即出任务提示（t=%.2f）" % _intro.elapsed())
	_ok(skip.text.contains("进入边境"),
			"★ 再点一次后按钮已是「进入边境」（实际 %s）" % skip.text)

	# ── 末段：上一步/下一步/暂停收起，主按钮变「进入边境」 ──
	_intro.seek(SCRIPT.PROMPT_AT + 0.10)
	await get_tree().process_frame
	_ok(not prev.visible and not nxt.visible and not pause.visible,
			"末段收起「上一步 / 下一步 / 暂停」")
	_ok(skip.visible and skip.text.contains("进入边境"),
			"末段主按钮变成「进入边境」（实际 %s）" % skip.text)
	_ok(skip.pressed.get_connections().size() > 0, "「进入边境」已接线")


# ─────────────────────────────────────────────── ⑤ 末段信标视频
func _phase_beacon_video() -> void:
	print("\n[5] 末段信标视频（替代原 3D 展开动画）")
	# ① 第二段之前：隐藏，第一段还留在屏幕上（不能黑屏）
	_intro.seek(SCRIPT.VIDEO2_IN - 1.0)
	await get_tree().process_frame
	_ok(not _video2.visible, "★ VIDEO2_IN 之前信标视频隐藏（t=%.2f）" % _intro.elapsed())
	_ok(_overlay.current_index() >= 0, "此时最后一句台词还挂着（idx=%d）" % _overlay.current_index())

	# ② 进入末段：淡入 + 播；对话层让位（只留「跳过对话」）
	_intro.seek(SCRIPT.VIDEO2_IN + 0.30)
	await get_tree().process_frame
	_ok(_video2.visible, "★ 过了 VIDEO2_IN 信标视频出现")
	_ok(_video2.modulate.a > 0.05, "淡入进行中（a=%.2f）" % _video2.modulate.a)
	_ok(_overlay.current_index() == -1, "末段视频期间台词收起（idx=%d）" % _overlay.current_index())
	_ok(_overlay.button("Prev").visible == false and _overlay.button("Next").visible == false,
			"★ 末段视频期间「上一步 / 下一步」收起")
	_ok(_overlay.button("Skip").visible and _overlay.button("Skip").text == "跳过对话",
			"★ 但「跳过对话」必须还在（否则 16 秒镜头跳不过去）")
	_ok(not _video2.paused, "末段视频正在播放（paused=false）")

	# ③ 播完：定格在最后一帧，出任务提示
	_intro.seek(SCRIPT.PROMPT_AT + 0.10)
	await get_tree().process_frame
	_ok(_video2.stream_position >= SCRIPT.VIDEO2_LEN - 0.10,
			"★ 提示态的信标视频已走到片尾（position=%.2f / %.2f）"
			% [_video2.stream_position, SCRIPT.VIDEO2_LEN])
	_ok(_video2.modulate.a >= 0.99, "信标视频不透明（a=%.2f）" % _video2.modulate.a)
	_ok(_overlay.button("Skip").text.contains("进入边境"), "主按钮 = 进入边境")

	# ④ 时间轴自洽：提示必须落在视频播完之后
	_ok(SCRIPT.PROMPT_AT >= SCRIPT.VIDEO2_IN + SCRIPT.VIDEO2_LEN,
			"★ PROMPT_AT(%.2f) ≥ VIDEO2_IN+VIDEO2_LEN(%.2f) ⇒ 不会提前打断镜头"
			% [SCRIPT.PROMPT_AT, SCRIPT.VIDEO2_IN + SCRIPT.VIDEO2_LEN])
	_ok(SCRIPT.SKIP_TO < SCRIPT.PROMPT_AT, "SKIP_TO 在提示之前（%.2f < %.2f）"
			% [SCRIPT.SKIP_TO, SCRIPT.PROMPT_AT])
	_ok(SCRIPT.PROMPT_AT - SCRIPT.SKIP_TO <= 1.0,
			"★ 跳过落点离提示 ≤1s（实际 %.2fs）⇒ 点一下就不会觉得「卡」"
			% (SCRIPT.PROMPT_AT - SCRIPT.SKIP_TO))

	# ⑤ 回退（上一步）：信标视频必须重新藏起来，不能残留在画面上
	_intro.seek(10.00)
	await get_tree().process_frame
	_ok(not _video2.visible, "★ 退回对话段时信标视频收起（不残留）")


# ─────────────────────────────────────────────── ⑥ 进度存档
func _phase_progress() -> void:
	print("\n[6] 首次游玩判定（进度存档）")
	var d := PROGRESS.load_all()
	_ok(d.has("intro_seen"), "存档有 intro_seen 字段")
	_ok(typeof(d["intro_seen"]) == TYPE_BOOL, "intro_seen 是 bool")
	_ok(PROGRESS.DEFAULTS["intro_seen"] == false,
			"默认值 = false（第一次玩 ⇒ 播开场）")

	# ⛔ 反向注入：写一次必须真能读回来（否则"跳过之后下次还拦人"）
	PROGRESS.save_one("intro_seen", true)
	_ok(PROGRESS.intro_seen(), "★ mark 之后读回来是 true（写盘生效）")
	PROGRESS.save_one("intro_seen", false)
	_ok(not PROGRESS.intro_seen(), "写回 false 也生效（不是只写不读）")

	# 配置文件必须与设置存档**分开**（混在一起会出"上局跳过⇒下局开头直接没"）
	_ok(PROGRESS.PATH != "user://settings.cfg",
			"进度存档与设置存档是两个文件（%s）" % PROGRESS.PATH)


# ─────────────────────────────────────────────── ⑦ 主菜单接线 + 首次判定
func _check_menu_wiring() -> void:
	print("\n[7] 主菜单接线与「首次 / 非首次」判定")
	var menu: Variant = MENU_SCENE.instantiate()
	add_child(menu)
	# 「回看片头」按钮（跳过不可以是不可逆的 ⇒ 必须有显式回看入口）
	var found := false
	for n in menu.find_children("*", "Button", true, false):
		if String((n as Button).name) == "ReplayIntroBtn":
			found = true
	_ok(found, "主界面有「回看片头」按钮（ReplayIntroBtn）")

	_ok(String(menu.INTRO_SCENE) == "res://scenes/intro_scene.tscn", "主界面知道开场场景在哪")

	# ★ 反向注入⑦：同一份代码，只翻进度存档，去的目的地必须跟着翻
	# ★★ 2026-10-28：这一段原来有一条**假的红**和一条**过时的红**，一起修：
	#   ① 没先把模式切到「任务关卡」⇒ `_content_id()` 还停在父项「自走棋」
	#      ⇒ `first_time` 恒为 false，前两条断言根本不成立；
	#   ② `FIRST_TIER_ID` 写的是旧 id `"guard_border"`（四档化后不存在）
	#      ⇒ 就算切对了模式也永远返回 BATTLE_SCENE。**这是真 bug**：
	#      新玩家第一次点「开始」直接进战斗，开场片头一次都没播过。
	menu._on_mode_pressed(0)                       # 展开「自走棋」→ 选中「任务关卡」
	_ok(String(menu._content_id()) == String(menu.FIRST_MODE_ID),
			"已切到任务关卡（实际 %s）" % menu._content_id())
	var first_tier := String((EveCampaignTiers.difficulties()[0] as Dictionary)["id"])
	_ok(String(menu.FIRST_TIER_ID) == first_tier,
			"★ FIRST_TIER_ID 必须等于首档难度的真实 id（应为 %s，实际 %s）"
			% [first_tier, menu.FIRST_TIER_ID])

	menu._pick["campaign"] = 0
	PROGRESS.save_one("intro_seen", false)
	_ok(menu.target_scene_for_start() == MENU_INTRO,
			"★ 第一次玩（intro_seen=false）⇒ 去开场（实际 %s）"
			% menu.target_scene_for_start())
	PROGRESS.save_one("intro_seen", true)
	_ok(menu.target_scene_for_start() == MENU_BATTLE,
			"★ 第二次玩（intro_seen=true）⇒ 直接进对局（实际 %s）"
			% menu.target_scene_for_start())
	PROGRESS.save_one("intro_seen", false)

	# ★ 2026-10-28：原断言「第 2 难度待开发 ⇒ 哪都不去」的预设已失效 ——
	#   四档难度现在 `open` 全是 true（见 EveCampaignTiers.DIFFICULTIES）。
	#   ⇒ 改成逐档验证**去处**：首档（intro_seen=false）去开场，其余直接进对局；
	#     若哪档被人关掉（open=false），则必须「哪都不去」—— 两种情况都守住。
	var tiers: Array = EveCampaignTiers.difficulties()
	for i in tiers.size():
		var t: Dictionary = tiers[i]
		menu._pick["campaign"] = i
		var got: String = menu.target_scene_for_start()
		if bool(t.get("open", false)):
			var want := MENU_INTRO if i == 0 else MENU_BATTLE
			_ok(got == want, "难度 %d（%s，已开放）⇒ %s（实际 '%s'）"
					% [i, String(t.get("name", "")), want, got])
		else:
			_ok(got == "", "难度 %d（%s，未开放）⇒ 哪都不去（实际 '%s'）"
					% [i, String(t.get("name", "")), got])
	menu._pick["campaign"] = 0

	# ★ 跳过必须写盘（否则下次开局又被拦一次）
	print("\n[8] 跳过的副作用（把 next_scene 置空，只验写盘不真切场景）")
	_intro.next_scene = ""
	PROGRESS.save_one("intro_seen", false)
	_intro._finish("自检")
	await get_tree().process_frame
	_ok(PROGRESS.intro_seen(), "★ 走到「进入边境」⇒ 进度存档写成 true（下次不再拦人）")
	_ok(bool(_intro._done), "跳过置了 finished 标志（不会被重复触发）")
	_intro.next_scene = BATTLE_SCENE
	menu.queue_free()
