extends Node
## 诊断上报（崩溃 / 手动反馈）—— autoload `EveReport`。
##
## ══════════════════════════════════════════════════════════════════
##  为什么要有它
## ══════════════════════════════════════════════════════════════════
##  玩家在千里之外，传回来的「闪退」两个字等于零信息：分不清是引擎 teardown 竞态、
##  显存不够被系统杀、还是 GPU 驱动超时 —— 而**要玩家连电脑抓 logcat 是不现实的**。
##  ⇒ 让游戏自己把现场打包发回来，是唯一跑得通的取证方式。
##
## ── 三条硬约束（与 `EveUpdater` 同一套纪律，别松）──────────────
##  1. **服务器挂了不能拦路**：任何失败都只是「这次没发出去」，落本地队列下次补发。
##     ⛔ 绝不在上报路径上 push_error / 阻断启动。
##  2. **玩家知情**：只在「上次异常退出」时弹窗询问，点「不用了」就真的一个字节都不发。
##     手动反馈是玩家自己点右下角版本号才打开 ⇒ 天然知情。
##  3. **体积封顶**：日志只取尾部 120 行 / 硬上限 64KB。那台服务器只有 4Mbps，
##     别把一个 5MB 的日志怼上去把热更通道挤了。
##
## ── 和 EveBoot 的分工 ────────────────────────────────────────
##  `EveBoot` 负责**本地取证**（run marker + 切后台快照），本文件负责**把证据送出去**。
##  ⚠️ 崩溃当次的日志只有 `EveBoot` 那个快照里才有（引擎启动就截断了 godot.log），
##     所以这里的 `_log_tail()` 优先读快照，读不到才退回当前 godot.log。

## 上报端点。与 `EveUpdater.META_URL` 同一台机器、同一个 http 通道
## （Android 9+ 默认禁明文，但 Godot 的模板放开了 —— 热更能用就说明这条路通）。
const ENDPOINT := "http://49.233.138.141/report"
const REQ_TIMEOUT := 15.0

const LOG_LINES := 120
const LOG_BYTES_MAX := 64 * 1024
const BODY_BYTES_MAX := 300 * 1024

const QUEUE_DIR := "user://report_queue"
const QUEUE_MAX := 8
const QUEUE_KEEP_SEC := 14 * 24 * 3600

## 「这个现场报过了」的标识文件（内容 = 那一次启动的时间戳）。
const REPORTED_TS := "user://report_last.txt"

var _posting := false
## 最近一次上报的结果（给界面/日志看，⛔ 不要拿它做流程判断）。
var last_status := ""


func _ready() -> void:
	# 上报排在最后：先让主菜单把画面铺出来，别让玩家觉得启动卡住了。
	await get_tree().process_frame
	await get_tree().process_frame
	# [WHY] 网页版跨域会被浏览器拦（服务端故意没开 CORS，否则谁都能往上报接口里灌）。
	#       与其在控制台刷一串红色错误，不如在这里直接收手。
	if OS.has_feature("web"):
		return
	_trim_queue()
	await _flush_queue()
	if EveBoot != null and EveBoot.had_unclean_exit:
		_prompt_crash()


## ── 手动反馈入口（主菜单右下角版本号被点击时调用）────────────────
func open_feedback() -> void:
	_ask(
		"发送诊断信息",
		"把当前状态发给作者吗？\n\n包含：设备型号、屏幕与渲染参数、版本号、"
		+ "当前所在场景、最近 %d 行日志。\n**不包含存档、不包含任何账号信息。**" % LOG_LINES,
		"发送", "取消",
		func() -> void: _send("manual", ""))


## ── 崩溃上报：上次没走完退出流程时问一次 ────────────────────────
func _prompt_crash() -> void:
	# [WHY] 同一个现场只问一次：不然玩家每次启动都要点一次「不用了」，
	#       点烦了以后连真崩溃都不会再看。
	if _reported_ts() == EveBoot.unclean_ts:
		return
	_ask(
		"上次没有正常退出",
		"这可能是闪退，也可能是切到后台被系统回收了。\n\n"
		+ "把诊断信息发给作者吗？包含设备型号、屏幕与渲染参数、版本号、"
		+ "切到后台那一刻的日志尾部。\n**不包含存档、不包含任何账号信息。**\n\n"
		+ "发一次就能定位问题，之后不会再问。",
		"发送", "不用了",
		func() -> void: _send("crash", ""))


## 发出去。失败就落队列，下次启动补发。
func _send(kind: String, note: String) -> void:
	var payload := collect(kind, note)
	if await _post(payload):
		last_status = "已发送"
		print("[EveReport] %s 上报成功" % kind)
		_mark_reported(EveBoot.unclean_ts)
	else:
		last_status = "网络不通，已存入本地队列"
		_queue(payload)
		print("[EveReport] %s 上报失败，已入队" % kind)


## 记下「这个现场报过了」，下次启动不再追问。
## ⚠️ 不要用删除 run marker 来代替：marker 还兼着「崩溃检测」的职责，
##    这一局要是再崩一次，下次启动还得能认出来。
func _reported_ts() -> int:
	if not FileAccess.file_exists(REPORTED_TS):
		return -1
	var f := FileAccess.open(REPORTED_TS, FileAccess.READ)
	if f == null:
		return -1
	var s := f.get_as_text().strip_edges()
	f.close()
	return int(s) if s.is_valid_int() else -1


func _mark_reported(ts: int) -> void:
	if ts <= 0:
		return
	var f := FileAccess.open(REPORTED_TS, FileAccess.WRITE)
	if f == null:
		return
	f.store_line(str(ts))
	f.close()


## ── 采集 ────────────────────────────────────────────────────────
func collect(kind: String, note: String = "") -> Dictionary:
	var vp := get_viewport()
	return {
		"kind": kind,
		"ts": int(Time.get_unix_time_from_system()),
		"version": String(EveUpdater.build_info().get("version", "")),
		"code": int(EveUpdater.build_info().get("code", 0)),
		"engine": String(Engine.get_version_info().get("string", "")),
		"os": OS.get_name(),
		"model": OS.get_model_name(),
		"scene": _scene_name(),
		"screen": str(DisplayServer.screen_get_size()),
		"window": str(DisplayServer.window_get_size()),
		"logical": str(vp.get_visible_rect().size) if vp != null else "",
		"max_fps": Engine.max_fps,
		"msaa": int(vp.msaa_3d) if vp != null else -1,
		"fxaa": int(vp.screen_space_aa) if vp != null else -1,
		"fps": Engine.get_frames_per_second(),
		"static_mem_kb": int(OS.get_static_memory_usage() / 1024),
		"note": note,
		"metrics": EveDeviceInfo.read_report(),
		"log_tail": _log_tail(),
	}


func _scene_name() -> String:
	var t := get_tree()
	if t == null or t.current_scene == null:
		return ""
	return String(t.current_scene.name)


## 日志尾部。**优先读切后台快照** —— 崩溃当次的 godot.log 已经被引擎截断了。
func _log_tail() -> String:
	var path := ""
	if FileAccess.file_exists(EveBoot.log_snapshot_path):
		path = EveBoot.log_snapshot_path
	elif FileAccess.file_exists(EveBoot.log_path):
		path = EveBoot.log_path
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


## ── 网络 ────────────────────────────────────────────────────────
func _post(payload: Dictionary) -> bool:
	if _posting:
		return false
	_posting = true

	var body := JSON.stringify(payload)
	if body.length() > BODY_BYTES_MAX:
		# [WHY] 兜底砍日志：宁可少发细节，也不能发一个 1MB 的包去挤 4Mbps 的出口。
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


## ── 离线队列 ────────────────────────────────────────────────────
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


## 队列维护：过期清掉 + 只留最新 QUEUE_MAX 条（防止长期离线攒一堆）。
func _trim_queue() -> void:
	var dir := DirAccess.open(QUEUE_DIR)
	if dir == null:
		return
	var now := int(Time.get_unix_time_from_system())
	var names := dir.get_files()
	var alive: Array[String] = []
	for n in names:
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


## ── 询问框 ──────────────────────────────────────────────────────
## [WHY] 不用 AcceptDialog 塞 LineEdit：那个布局要靠内部 VBox，Godot 版本一动就错位。
##       v1 只要「发 / 不发」两个选择，文字说明放进正文明细里，够用。
func _ask(title: String, text: String, ok_text: String, cancel_text: String,
		on_ok: Callable) -> void:
	if get_tree() == null or get_tree().root == null:
		return
	var dlg := ConfirmationDialog.new()
	dlg.title = title
	dlg.dialog_text = text
	dlg.ok_button_text = ok_text
	dlg.cancel_button_text = cancel_text
	dlg.min_size = Vector2i(560, 260)
	dlg.confirmed.connect(on_ok)
	dlg.close_requested.connect(dlg.queue_free)
	get_tree().root.add_child(dlg)
	dlg.popup_centered()
