extends Node
## 诊断上报（心跳 / 崩溃 / 手动反馈）—— **由主菜单创建**，⛔ 不是 autoload。
##
## ══════════════════════════════════════════════════════════════════
##  ★★ 2026-11-07 事故后重写：为什么它不是 autoload
## ══════════════════════════════════════════════════════════════════
##  第一版把本文件注册成 autoload `EveReport`，然后主菜单里直接写
##  `EveReport.open_feedback()`。这炸了，而且是整包性的：
##
##    autoload 列表在**引擎启动那一刻**就定死了，`load_resource_pack` 改不了它。
##    ⇒ 老客户端（列表里没有 EveReport）挂上含 `EveReport.xxx` 的新 pck，
##      GDScript 在**编译期**就报
##        `Parse Error: Identifier "EveReport" not declared in the current scope`
##      ⇒ `eve_main_menu.gd` 整个脚本加载失败 ⇒ 场景没有脚本 ⇒ **黑屏**。
##    ⇒ b39 因此让所有 b38 及以前的客户端黑屏（详见
##      `docs/事故-b39黑屏-2026-11-07.md`）。
##
##  改成「主菜单 `preload()` + `new()`」之后，依赖只剩 `res://` 里的一个文件，
##  而文件会被 pck 覆盖 ⇒ **热更就能更新上报逻辑本身**，这正是最初想要的效果。
##
##  ⛔⛔ 三条铁律，别破：
##    1. 本文件**不许**注册回 autoload。
##    2. 别的脚本**不许**写 `EveReport.xxx`（裸引用 autoload 名）。
##    3. 本文件**不许**读 `EveBoot.had_unclean_exit` / `unclean_ts` / `log_snapshot_path`
##       —— 那些是 2026-11-07 才加的字段，而 `EveBoot` 节点在 pck 挂载**之前**
##       就实例化了，脚本永远是基础包里的老版本 ⇒ 老客户端上这些字段不存在。
##       （`EveBoot` 排在 `EveUpdater` 前面，所以它永远吃不到热更。见 `_prev_dict()`。）
##
##  ⚠️ 同理，**任何**跨 pck 边界访问 autoload 成员都得先做存在性检查：
##     autoload 节点是老脚本，调用方是新脚本。见 `eve_main_menu._up_has()`。
##
## ── 三条纪律（与 `EveUpdater` 同一套）────────────────────────
##  1. **服务器挂了不能拦路**：失败只是「这次没发出去」，落本地队列下次补发。
##     ⛔ 绝不在上报路径上 push_error / 阻断启动。
##  2. **体积封顶**：日志只取尾部 120 行 / 硬上限 64KB。那台机器 4Mbps，
##     别把 5MB 日志怼上去把热更通道挤了。
##  3. **不碰存档、不碰账号**：只发设备/渲染参数/版本/日志尾部。
##
## ── 发什么、什么时候发 ──────────────────────────────────────
##  | kind      | 时机                                | 含日志 | 玩家要点吗 |
##  |-----------|-------------------------------------|--------|-----------|
##  | `heartbeat` | 每 24 小时最多一条；**首次启动立刻发** | 否     | 不需要    |
##  | `crash`     | 上次启动没走到主菜单 / 没正常退出     | 是     | 不需要    |
##  | `manual`    | 玩家点右下角版本号                    | 是     | 要点      |
##
##  [WHY] 心跳是 2026-11-07 用户定的「一定要把上传通道打通」：
##        崩溃是低频事件，只靠它验证通道等于永远验不出来。心跳每台机器每天一条，
##        几百字节，既能证明链路通，又能顺便收设备/版本分布。
##  [WHY] `crash` 也不弹窗了：玩家黑屏时**根本点不到按钮**，
##        弹窗等于永远收不到现场。诊断信息不含存档不含账号，静默发是划算的。
##  ⚠️ 玩家退出通道：在 `user://` 建一个空文件 `report_off`，本文件就彻底闭嘴。

const ENDPOINT := "http://49.233.138.141/report"
const REQ_TIMEOUT := 15.0

const LOG_LINES := 120
const LOG_BYTES_MAX := 64 * 1024
const BODY_BYTES_MAX := 300 * 1024

const QUEUE_DIR := "user://report_queue"
const QUEUE_MAX := 8
const QUEUE_KEEP_SEC := 14 * 24 * 3600

## 「这个现场报过了」的标识（内容 = 上次会话的启动时间戳）。
const REPORTED_TS := "user://report_last.txt"

## ★ 本次会话的存活标记。三个阶段，用数字记：
##   0 = 引擎起来了（但界面还没铺出来）
##   1 = 主菜单已经能看见（`mark_ui_ready()` 写的）
##   2 = 正常退出了（`WM_CLOSE_REQUEST` 写的）
## 下次启动读它：
##   · 文件不存在       → 首次运行，或玩家删过 user:// ⇒ 不算崩溃
##   · 0                → **上次黑屏/启动期崩溃**（正是 Windows 黑屏要抓的）
##   · 1                → 运行中崩溃 / 被系统杀（安卓切后台被回收最常见）
##   · 2                → 正常退出
const ALIVE_MARK := "user://report_alive.cfg"

## 心跳节流：每台机器 24 小时最多一条。
const HEARTBEAT_TS := "user://report_hb.txt"
const HEARTBEAT_GAP_SEC := 24 * 3600

## 玩家关闭上报的开关（存在即闭嘴）。
const OPT_OUT := "user://report_off"

## 全进程只允许跑一份（autoload 若还在 + 主菜单自建，会打架）。
static var _started := false

var _posting := false
## 最近一次上报的结果（给界面/日志看，⛔ 不要拿它做流程判断）。
var last_status := ""
## 上次会话的状态，`start()` 时算好存着（`mark_ui_ready()` 之后会被覆盖）。
var _prev_stage := -1
var _prev_ts := 0


## [NOTE] 本文件被 `new()` 出来 add_child 时也会走这里。
##        ⛔ 不要在这里做重活 —— 由 `start()` 统一管，`_started` 去重。
func _ready() -> void:
	if get_parent() != null and get_parent().name == "root":
		# 万一日后被谁又注册成 autoload，这里兜住；主菜单那条路径会调 start()。
		start()


## 入口。可以重复调，只有第一次生效。
func start() -> void:
	if _started:
		return
	_started = true
	# [WHY] 网页版跨域会被浏览器拦（服务端故意没开 CORS，否则谁都能往接口灌垃圾）。
	if OS.has_feature("web"):
		return
	if FileAccess.file_exists(OPT_OUT):
		print("[EveReport] 玩家已关闭诊断上报（user://report_off 存在）")
		return
	_boot()


func _boot() -> void:
	# 顺序有讲究：先读上次状态（晚一步就被本次的 `_write_stage(0)` 盖掉了）。
	_prev_stage = _read_stage()
	_prev_ts = _read_ts_of_alive()
	_write_stage(0)

	# 日志尾部必须在**本次启动写满之前**抓：晚点就混进本次的噪音了。
	await _flush_queue()
	await _maybe_heartbeat()

	# [WHY] 0 = 上次连主菜单都没出来 ⇒ 黑屏。这是最该拿到现场的形态。
	#       1 = 主菜单出来了但没正常退出 ⇒ 运行中崩溃/被系统杀。
	if _prev_stage >= 0 and _prev_stage <= 1:
		await _report_crash(_prev_stage)


## 主菜单铺好后由 `eve_main_menu` 调用。写 stage=1，下次启动就知道「这次是好的」。
func mark_ui_ready() -> void:
	if _started:
		_write_stage(1)


## ── 手动反馈（玩家点主菜单右下角版本号）──────────────────────────
func open_feedback() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "发送诊断信息"
	dlg.dialog_text = (
		"把当前状态发给作者吗？\n\n"
		+ "包含：设备型号、屏幕与渲染参数、版本号、当前所在场景、最近 %d 行日志。\n"
		+ "**不包含存档、不包含任何账号信息。**") % LOG_LINES
	dlg.ok_button_text = "发送"
	dlg.cancel_button_text = "取消"
	dlg.min_size = Vector2i(560, 260)
	dlg.confirmed.connect(func() -> void: _send("manual", ""))
	dlg.close_requested.connect(dlg.queue_free)
	if get_tree() != null and get_tree().root != null:
		get_tree().root.add_child(dlg)
		dlg.popup_centered()


## ── 心跳：正常运行也传一条 ────────────────────────────────────
## [WHY] 崩溃是低频事件，只靠它验证通道等于永远验不出来。
##       心跳带全套环境参数但不带日志，几百字节，是确认「链路真的通」的唯一办法。
func _maybe_heartbeat() -> void:
	var now := int(Time.get_unix_time_from_system())
	var last := _read_ts(HEARTBEAT_TS)
	if last > 0 and now - last < HEARTBEAT_GAP_SEC:
		return
	_write_ts(HEARTBEAT_TS, now)
	var p := collect("heartbeat", "")
	# 心跳不带日志：省流量，也避免日志里出现玩家自己的东西被顺手传走。
	p["log_tail"] = ""
	if await _post(p):
		last_status = "心跳已发送"
		print("[EveReport] heartbeat 已送达")
	else:
		# [PITFALL] 心跳**不入队**：它没有单独价值，攒 8 条心跳去挤队列
		#           会把真正值钱的 crash 报告挤掉。
		last_status = "心跳发送失败"


## ── 崩溃上报 ──────────────────────────────────────────────────
## [WHY] 不弹窗。玩家黑屏时看不到、也点不到任何按钮，
##       弹窗 = 永远收不到现场。这是我们和玩家之间唯一的信息通道。
func _report_crash(stage: int) -> void:
	# [WHY] 同一个现场只报一次：不然玩家每次启动都要重传一遍同样的东西。
	if _read_ts(REPORTED_TS) == _prev_ts and _prev_ts > 0:
		return
	var note := "启动期黑屏/崩溃（未到主菜单）" if stage == 0 else "运行中未正常退出"
	await _send("crash", note)
	_write_ts(REPORTED_TS, _prev_ts)


func _send(kind: String, note: String) -> void:
	var payload := collect(kind, note)
	if await _post(payload):
		last_status = "已发送"
		print("[EveReport] %s 上报成功" % kind)
	else:
		last_status = "网络不通，已存入本地队列"
		_queue(payload)
		print("[EveReport] %s 上报失败，已入队" % kind)


## ── 存活标记 ──────────────────────────────────────────────────
func _write_stage(stage: int) -> void:
	var f := FileAccess.open(ALIVE_MARK, FileAccess.WRITE)
	if f == null:
		return
	f.store_line("stage=%d" % stage)
	f.store_line("ts=%d" % int(Time.get_unix_time_from_system()))
	f.store_line("version=%s" % String(_build_info().get("version", "")))
	f.close()


func _read_stage() -> int:
	if not FileAccess.file_exists(ALIVE_MARK):
		return -1
	var f := FileAccess.open(ALIVE_MARK, FileAccess.READ)
	if f == null:
		return -1
	var txt := f.get_as_text()
	f.close()
	# [NOTE] 手写 key=value 而不是 ConfigFile：省一层依赖，也不会被段落名绊住。
	for line in txt.split("\n"):
		var s := String(line).strip_edges()
		if s.begins_with("stage="):
			var v := s.substr(6).strip_edges()
			return int(v) if v.is_valid_int() else -1
	return -1


func _read_ts_of_alive() -> int:
	if not FileAccess.file_exists(ALIVE_MARK):
		return 0
	var f := FileAccess.open(ALIVE_MARK, FileAccess.READ)
	if f == null:
		return 0
	var txt := f.get_as_text()
	f.close()
	for line in txt.split("\n"):
		var s := String(line).strip_edges()
		if s.begins_with("ts="):
			var v := s.substr(3).strip_edges()
			return int(v) if v.is_valid_int() else 0
	return 0


func _read_ts(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var s := f.get_as_text().strip_edges()
	f.close()
	return int(s) if s.is_valid_int() else 0


func _write_ts(path: String, ts: int) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_line(str(ts))
	f.close()


## ── 采集 ──────────────────────────────────────────────────────
## ⛔ 这里**不许**读任何 autoload 的新字段（见文件头铁律 3）。
func collect(kind: String, note: String = "") -> Dictionary:
	var vp := get_viewport()
	var bi := _build_info()
	return {
		"kind": kind,
		"ts": int(Time.get_unix_time_from_system()),
		"version": String(bi.get("version", "")),
		"code": int(bi.get("code", 0)),
		"engine": String(Engine.get_version_info().get("string", "")),
		"os": OS.get_name(),
		"model": OS.get_model_name(),
		"scene": _scene_name(),
		"screen": str(DisplayServer.screen_get_size()),
		"window": str(DisplayServer.window_get_size()),
		"logical": str(vp.get_visible_rect().size) if vp != null else "",
		"renderer": String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		"driver": str(RenderingServer.get_current_rendering_driver_name()),
		"max_fps": Engine.max_fps,
		"msaa": int(vp.msaa_3d) if vp != null else -1,
		"fxaa": int(vp.screen_space_aa) if vp != null else -1,
		"fps": Engine.get_frames_per_second(),
		"static_mem_kb": int(OS.get_static_memory_usage() / 1024),
		# ★ 热更状态：这两项对「黑屏是不是热更包害的」是决定性的。
		#   update_pck_bytes  == 0 → 没挂热更包
		#   update_pck_bytes  >  0 → 玩家本地有一份包（能对上服务器的大小就知道是哪一版）
		"update_pck_bytes": _file_size("user://update.pck"),
		"update_boot_fail": _boot_fail(),
		"prev_stage": _prev_stage,
		"note": note,
		"metrics": EveDeviceInfo.read_report(),
		"log_tail": _log_tail(),
	}


## 自己读 build_info.json，⛔ 不走 `EveUpdater.build_info()`：
## 那是 autoload 实例上的老脚本，虽然 b35 就有这个方法，但没必要给自己留这个依赖。
func _build_info() -> Dictionary:
	if FileAccess.file_exists("res://build_info.json"):
		var f := FileAccess.open("res://build_info.json", FileAccess.READ)
		if f != null:
			var d: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(d) == TYPE_DICTIONARY:
				return d
	return {"version": String(ProjectSettings.get_setting("application/config/version", "?")),
			"code": 0}


func _file_size(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return int(n)


## 热更包的「连续启动失败」计数。读不到就当 0。
## [WHY] 这个数 ≥ 1 说明玩家正在被坏包折磨；≥ 3 说明包已被自动删掉回退。
func _boot_fail() -> int:
	const ST := "user://update_state.cfg"
	if not FileAccess.file_exists(ST):
		return 0
	var f := FileAccess.open(ST, FileAccess.READ)
	if f == null:
		return 0
	var txt := f.get_as_text()
	f.close()
	var i := txt.find("\"boot_fail\"")
	if i < 0:
		return 0
	var rest := txt.substr(i + 11)
	var colon := rest.find(":")
	if colon < 0:
		return 0
	var num := ""
	for c in rest.substr(colon + 1):
		if String(c).is_valid_int() or c == "-":
			num += String(c)
		elif num != "":
			break
	return int(num) if num.is_valid_int() else 0


func _scene_name() -> String:
	# ⚠️ `get_tree()` 在节点没进树时**会 push_error**（`Parameter "data.tree" is null`），
	#    不是返回 null 那么温和。验收脚本里 `new()` 出来但没 add_child 的实例会踩到。
	if not is_inside_tree():
		return ""
	var t := get_tree()
	if t == null or t.current_scene == null:
		return ""
	return String(t.current_scene.name)


## 日志尾部。
## ⚠️ 桌面端没有切后台快照（老 `EveBoot` 那段只在 mobile 跑），所以退到 godot.log。
##    代价是「被强杀的当次」日志已被引擎截断 —— 能拿到的是本次启动的日志。
func _log_tail() -> String:
	const SNAP := "user://logs/last_session.log"
	const CUR := "user://logs/godot.log"
	var path := ""
	if FileAccess.file_exists(SNAP):
		path = SNAP
	elif FileAccess.file_exists(CUR):
		path = CUR
	if path == "":
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var txt := f.get_as_text()
	f.close()
	# 先按字节封顶再按行截：大文件直接 right() 比 split 整篇省内存。
	if txt.length() > LOG_BYTES_MAX:
		txt = txt.right(LOG_BYTES_MAX)
	var rows := txt.split("\n")
	if rows.size() > LOG_LINES:
		rows = rows.slice(rows.size() - LOG_LINES)
	return "\n".join(rows)


## ── 网络 ──────────────────────────────────────────────────────
func _post(payload: Dictionary) -> bool:
	if _posting:
		return false
	_posting = true

	var body := JSON.stringify(payload)
	if body.length() > BODY_BYTES_MAX:
		# [WHY] 兜底砍日志：宁可少发细节，也不能发个 1MB 的包去挤 4Mbps 的出口。
		payload["log_tail"] = String(payload.get("log_tail", "")).right(32 * 1024)
		payload["truncated"] = true
		body = JSON.stringify(payload)

	var http := HTTPRequest.new()
	http.timeout = REQ_TIMEOUT
	add_child(http)
	var err := http.request(ENDPOINT, ["Content-Type: application/json"],
			HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		_posting = false
		return false

	var res: Array = await http.request_completed
	http.queue_free()
	_posting = false
	var code := int(res[1]) if res.size() > 1 else 0
	return code >= 200 and code < 300


## ── 离线队列 ──────────────────────────────────────────────────
func _queue(payload: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(QUEUE_DIR))
	var path := "%s/%d.json" % [QUEUE_DIR, int(Time.get_unix_time_from_system())]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(payload))
	f.close()
	_trim_queue()


## 补发：一次只发一条（启动阶段不要在网络上逗留）。
func _flush_queue() -> void:
	var dir := DirAccess.open(QUEUE_DIR)
	if dir == null:
		return
	var names := dir.get_files()
	names.sort()
	for n in names:
		if not n.ends_with(".json"):
			continue
		var path := QUEUE_DIR + "/" + n
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var txt := f.get_as_text()
		f.close()
		var data: Variant = JSON.parse_string(txt)
		if typeof(data) != TYPE_DICTIONARY:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			continue
		var payload: Dictionary = data
		if await _post(payload):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			print("[EveReport] 补发成功：%s" % n)
			return


## 队列维护：过期清掉 + 只留最新 QUEUE_MAX 条。
func _trim_queue() -> void:
	var dir := DirAccess.open(QUEUE_DIR)
	if dir == null:
		return
	var now := int(Time.get_unix_time_from_system())
	var alive: Array[String] = []
	for n in dir.get_files():
		if not n.ends_with(".json"):
			continue
		var path := QUEUE_DIR + "/" + n
		var ts := int(n.get_basename())
		if ts <= 0 or now - ts > QUEUE_KEEP_SEC:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			continue
		alive.append(n)
	if alive.size() <= QUEUE_MAX:
		return
	alive.sort()
	for i in range(0, alive.size() - QUEUE_MAX):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(QUEUE_DIR + "/" + alive[i]))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# 走完了退出流程 = 正常退出，下次启动不该报「崩溃」。
		if _started:
			_write_stage(2)
