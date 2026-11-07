extends Node

## EVE 自走棋 —— 客户端自更新检查器（主菜单侧，不依赖任何 autoload 新成员）
##
## ══════════════════════════════════════════════════════════════════
##  这个文件为什么存在（b39 事故的直接产物）
## ══════════════════════════════════════════════════════════════════
##  2026-11-07 第一版「主动提示更新」写在 `EveUpdater` 里（那是 autoload）。
##  它加了 `update_available` 信号 / `pending_update` 字段 / `download_update()`
##  方法，然后主菜单用 `_up_has()` 检测这三个成员 —— 检测不到就 return。
##
##  问题是：**autoload 节点在 pck 挂载之前就实例化了**，用的永远是基础包里的
##  老脚本 ⇒ 老客户端上 `_up_has()` 三个全部 false ⇒ **弹窗一次都没执行过**。
##  写了代码、跑了测试、发了版，玩家却永远看不到。
##
##  [WHY] 所以这里把整条链路搬到**主菜单自己 new 出来的 Node** 上：
##    · 自己读 `res://build_info.json`（pck 挂载后自动是新版本号）
##    · 自己拉 `version.json`、自己比 `code`、自己下载、自己校验 sha256
##    · ⛔ **一个 `EveUpdater.xxx` 都不访问** —— 老客户端上那些成员不存在
##  主菜单脚本会被 pck 覆盖，所以本文件里的逻辑**以后可以靠热更改**。
##
##  ── 与老 `EveUpdater` 的共存（重要，别删）────────────────────────
##  基础包（≤ b35）里的 `EveUpdater._ready()` 在启动两帧后**无条件静默下载**，
##  这段代码在 autoload 里、热更改不掉。所以本检查器可能一启动就发现
##  `user://update.pck.part` 正在被别人写。
##
##  ⇒ 两个数据源都要认：
##     · 老 EveUpdater 在下 → `EXT_PART` 在长 → **观察它**，面板显示同一个进度条
##     · 没人下          → 自己下到 `UI_PART`（独立文件名，⛔ 绝不和它抢同名文件）
##
##  这也是「玩家至少有了知情权」的实现方式：哪怕下载不是你点的，
##  面板也会告诉你「在下 / 下完了 / 重启生效」。

const META_URL := "http://49.233.138.141/update/version.json"
const USER_PCK := "user://update.pck"
## 老 `EveUpdater` 的临时文件名（`TMP_PCK`），只读不写。
const EXT_PART := "user://update.pck.part"
## 本检查器自己的临时文件名。⛔ 不能复用 EXT_PART：两边同时写会互相截断。
const UI_PART := "user://update_ui.part"

const REQ_TIMEOUT := 8.0
## 轮询间隔。0.25s 足够让进度条看起来是连续的，又不会每帧读盘。
const POLL_SEC := 0.25

## 发现新版本，问玩家要不要下。`size_mb` 由清单算，未知时 <= 0。
signal asked(cur: String, new_ver: String, size_mb: float)
## 进度。`allow_dismiss` = 这波下载不是玩家点的（老 EveUpdater 在下），
## 所以允许「后台继续」收起面板 —— 收起与否都不影响它。
signal progressed(pct: float, done: int, total: int, allow_dismiss: bool)
## 包已就位（`user://update.pck`），重启生效。
signal ready_to_restart(ver: String)
## 失败。`msg` 是给玩家看的一行中文。
signal failed(msg: String, cur: String, new_ver: String)

var cur_ver := ""
var new_ver := ""

var _cur_code := 0
var _new_code := 0
var _size := 0
var _sha := ""
var _urls: Array = []
var _meta_str := ""

var _asked := false
var _finished := false
var _http: HTTPRequest = null
var _dl_idx := 0
var _poll := 0.0
var _last_pct := -1
var _last_bytes := -1
## 当前是否处在「观察老 EveUpdater 下载」的模式（见 `_monitor_ext`）。
var _watch_ext := false
## 玩家点了「重试」但清单还没拉到 ⇒ 拉完直接下，⛔ 不再问一遍。
var _auto_dl := false


func _ready() -> void:
	# 只有需要轮询时才开 _process（清单请求用信号回调就够）
	set_process(false)


# ══════════════════════════════════════════════════════════════════
#  对外
# ══════════════════════════════════════════════════════════════════

## 开始检查。调用方（主菜单）负责延迟到界面铺好之后。
##
## ⚠️ 这里**不预检本地包**：`_size` / `_sha` 都来自清单，没有清单就没法判断
##    「本地这份包是不是最新」。所有比对一律放到 `_on_meta_done` 里做。
func start() -> void:
	var info := read_build_info()
	cur_ver = String(info.get("version", "0.0.0"))
	_cur_code = int(info.get("code", 0))
	_request_meta()


func read_build_info() -> Dictionary:
	## 自己读，⛔ 不走 `EveUpdater.build_info()`：老客户端上有这个方法，
	## 但万一将来签名变了就是跨 pck 边界的运行时错误。读文件最稳。
	if not FileAccess.file_exists("res://build_info.json"):
		return {"version": String(ProjectSettings.get_setting("application/config/version", "0.0.0")),
				"code": 0}
	var f := FileAccess.open("res://build_info.json", FileAccess.READ)
	if f == null:
		return {"version": "0.0.0", "code": 0}
	var v: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(v) != TYPE_DICTIONARY:
		return {"version": "0.0.0", "code": 0}
	return v


## 重启生效。三平台分开处理。
##
## [PITFALL] 编辑器里 ⛔ 绝不能调 `OS.create_instance()` —— 那会把 **Godot 编辑器
##   本身**再开一份（用户在编辑器里点「立即重启」时会看到两个编辑器窗口）。
func restart_app() -> void:
	if OS.has_feature("web"):
		return                      # 网页版没有「进程重启」这回事
	if OS.has_feature("editor"):
		quit_game()
		return
	if OS.has_feature("mobile"):
		# 自拉起要走 platform Intent，本工程没集成这层 ⇒ 老实退出，
		# 玩家再从桌面点图标（Android 上这是最可靠的行为）。
		quit_game()
		return
	# 桌面：先退出再拉起。⚠️ `create_instance` 要在退出前调，否则进程没了。
	OS.create_instance(OS.get_cmdline_args())
	quit_game()


func quit_game() -> void:
	var t := get_tree()
	if t != null:
		t.quit()


# ══════════════════════════════════════════════════════════════════
#  拉清单
# ══════════════════════════════════════════════════════════════════

func _request_meta() -> void:
	_http = HTTPRequest.new()
	_http.timeout = REQ_TIMEOUT
	add_child(_http)
	_http.request_completed.connect(_on_meta_done)
	if _http.request(META_URL) != OK:
		# 拿不到清单 = 不更新。⛔ 不是错误路径，静默走人（网络差是常态）。
		_cleanup()


func _on_meta_done(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_cleanup()
		return
	var m: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(m) != TYPE_DICTIONARY:
		_cleanup()
		return
	_new_code = int((m as Dictionary).get("code", 0))
	_meta_str = String((m as Dictionary).get("version", ""))
	var pck: Dictionary = (m as Dictionary).get("pck", {})
	_size = int(pck.get("size", 0))
	_sha = String(pck.get("sha256", "")).to_lower()
	_urls = _pick_urls(pck)
	new_ver = _meta_str

	if _new_code <= _cur_code:
		_cleanup()
		return
	if _urls.is_empty() or _size <= 0:
		_cleanup()
		return

	# ── 本地已经有一份对得上清单的包？那就是「已就绪」，不必再问 ──
	var local_bytes := _file_size(USER_PCK)
	if local_bytes > 0 and _size_matches(local_bytes):
		if _verify_sha():
			_finished = true
			ready_to_restart.emit(new_ver)
			_cleanup()
			return
		# 大小对、哈希不对 = 半包/坏包。删掉重下（⛔ 绝不能拿去挂载）。
		DirAccess.remove_absolute(ProjectSettings.globalize_path(USER_PCK))

	# ── 老 EveUpdater 正在下？改成「观察」而不是重复下载 ──
	# [WHY] 它从启动 2 帧后就开始，而我们 1.5 秒后才检查 ⇒ 大概率已经在写了。
	#       两边同时写两个不同的临时文件是安全的，但会给分发服务器双倍流量，
	#       而且谁先完成不确定。观察它更省事，玩家看到的进度也一致。
	if _file_size(EXT_PART) > 0:
		_monitor_ext()
		return

	# ── 没人下 → 问玩家（除非这是「重试」路径，那就直接下）──
	if _auto_dl:
		_auto_dl = false
		_cleanup()
		begin_download()
		return
	_asked = true
	asked.emit(cur_ver, new_ver, float(_size) / 1048576.0)
	_cleanup()


# ══════════════════════════════════════════════════════════════════
#  A. 观察老 EveUpdater 的下载
# ══════════════════════════════════════════════════════════════════

func _monitor_ext() -> void:
	_watch_ext = true
	_cleanup()
	_last_pct = -1
	_last_bytes = -1
	set_process(true)
	progressed.emit(0.0, _file_size(EXT_PART), _size, true)


func _tick_monitor() -> void:
	var pck_bytes := _file_size(USER_PCK)
	# ① 已经改名成功 = 完成
	if pck_bytes > 0 and _size_matches(pck_bytes):
		set_process(false)
		_watch_ext = false
		if _verify_sha():
			_finished = true
			ready_to_restart.emit(new_ver)
		else:
			# 大小对但哈希不对：不是我们写的，只能提示重来
			_finished = true
			failed.emit("下载的更新包校验不通过，请重启后再试", cur_ver, new_ver)
		return

	# ② 还在写 .part → 报进度
	var part := _file_size(EXT_PART)
	if part > 0:
		_emit_pct(float(part) / float(_size), part, true)
		return

	# ③ .part 没了、包也没到位 = 对方放弃了（网络断 / 换源都不成）
	#    ⇒ 交回给玩家：问一次「要不要自己下」。
	set_process(false)
	_watch_ext = false
	if _asked:
		return
	if _file_size(USER_PCK) == 0:
		_asked = true
		asked.emit(cur_ver, new_ver, float(_size) / 1048576.0)


# ══════════════════════════════════════════════════════════════════
#  B. 自己下载
# ══════════════════════════════════════════════════════════════════

## 玩家点了「现在更新」（或失败后点「重试」）。
func begin_download() -> void:
	if _finished:
		return
	if _urls.is_empty():
		# 清单还没拉成功（首检时网络不通 / 玩家先点了重试）⇒ 拉完直接下，
		# ⛔ 不再弹一次询问窗 —— 玩家已经表达过「我要更新」了。
		_auto_dl = true
		_request_meta()
		return
	# 先清掉可能存在的旧临时文件（上一次中断留下的）
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UI_PART))
	_dl_idx = 0
	_download_next()


func _download_next() -> void:
	if _dl_idx >= _urls.size():
		failed.emit("更新包下载失败，请检查网络后重试", cur_ver, new_ver)
		return
	_cleanup()
	_http = HTTPRequest.new()
	# ⚠️ 首包 1.1 MB，给 60 秒；慢网（2G/限速）也够。
	_http.timeout = 60.0
	_http.download_file = UI_PART    # ← 这个模式下没有进度**回调**，只能轮询
	add_child(_http)
	_http.request_completed.connect(_on_dl_done)
	var err := _http.request(String(_urls[_dl_idx]))
	if err != OK:
		_dl_idx += 1
		_download_next()
		return
	_last_pct = -1
	_last_bytes = -1
	set_process(true)
	progressed.emit(0.0, 0, _size, false)


func _on_dl_done(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
	set_process(false)
	var ok := result == HTTPRequest.RESULT_SUCCESS and code == 200
	var got := _file_size(UI_PART)
	# 长度 + 哈希双验：长度对但内容坏（加速站缓存了旧包 / 被劫持）必须换源。
	if ok and got > 0 and _size_matches(got) and _sha256_file(UI_PART) == _sha:
		_install()
		return
	# 换下一个源
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UI_PART))
	_dl_idx += 1
	_download_next()


## 把临时包改名成 `user://update.pck`（下一次启动时由 autoload 挂载）。
func _install() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		failed.emit("无法写入更新文件", cur_ver, new_ver)
		return
	# 先删旧的：`rename` 覆盖同名文件在不同平台上行为不一致，删掉最稳。
	if dir.file_exists(USER_PCK.get_file()):
		dir.remove(USER_PCK.get_file())
	# ⚠️ 老 EveUpdater 的失败计数可能在 `update_state.cfg` 里攒着。
	#    我们这份包是校验过的，启动一定能进主菜单 ⇒ 清零，别让它被误判成坏包删掉。
	_reset_boot_fail()
	if dir.rename(UI_PART.get_file(), USER_PCK.get_file()) != OK:
		failed.emit("无法写入更新文件", cur_ver, new_ver)
		return
	_finished = true
	ready_to_restart.emit(new_ver)


## `boot_fail` 归零。⛔ 不写别的键 —— 那个文件归 `EveUpdater` 管。
func _reset_boot_fail() -> void:
	if not FileAccess.file_exists("user://update_state.cfg"):
		return
	var f := FileAccess.open("user://update_state.cfg", FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	if txt.find("\"boot_fail\"") < 0:
		return
	var out := FileAccess.open("user://update_state.cfg", FileAccess.WRITE)
	if out == null:
		return
	out.store_string("[update]\n\nstate={\n\"boot_fail\": 0\n}\n")
	out.close()


# ══════════════════════════════════════════════════════════════════
#  轮询 / 校验 / 工具
# ══════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	_poll += delta
	if _poll < POLL_SEC:
		return
	_poll = 0.0
	if _watch_ext:
		_tick_monitor()
		return
	if _http != null and _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		var done := _http.get_downloaded_bytes()
		if done > 0:
			_emit_pct(float(done) / float(_size), done, false)


## 整数百分比变化才发信号。⛔ 不节流 = 每 0.25 秒一次 GUI 更新，进度条会抖。
func _emit_pct(pct: float, done: int, allow_dismiss: bool) -> void:
	var p := clampf(pct, 0.0, 1.0)
	var ip := int(round(p * 100.0))
	if ip == _last_pct and done == _last_bytes:
		return
	_last_pct = ip
	_last_bytes = done
	progressed.emit(p, done, _size, allow_dismiss)


func _size_matches(got: int) -> bool:
	if _size <= 0:
		return false
	# 允许 1 字节误差：不同文件系统对「已写入但未 flush」的读数略有差异
	return absi(got - _size) <= 1


func _verify_sha() -> bool:
	if _sha == "":
		return true        # 清单没给哈希 = 信任（老格式兼容）
	return _sha256_file(USER_PCK) == _sha


func _sha256_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	while f.get_position() < f.get_length():
		var chunk := f.get_buffer(65536)
		if chunk.is_empty():
			break
		ctx.update(chunk)
	f.close()
	return ctx.finish().hex_encode()


func _file_size(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := int(f.get_length())
	f.close()
	return n


## 候选下载地址：数组优先，单值兜底，去重。
## [WHY] GitHub 加速站是第三方、说挂就挂 ⇒ 必须留自建服务器兜底。
func _pick_urls(pck: Dictionary) -> Array:
	var out: Array = []
	var arr: Variant = pck.get("urls", [])
	if typeof(arr) == TYPE_ARRAY:
		for u in arr:
			var s := String(u).strip_edges()
			if s != "" and not out.has(s):
				out.append(s)
	var one := String(pck.get("url", "")).strip_edges()
	if one != "" and not out.has(one):
		out.append(one)
	return out


func _cleanup() -> void:
	if _http != null:
		_http.queue_free()
		_http = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# 玩家在下载中途点了「开始游戏」⇒ 主菜单被 free ⇒ 本节点跟着销毁。
		# 留下半个临时文件是垃圾，清掉（它和 EveUpdater 的文件名不同，不会误伤）。
		DirAccess.remove_absolute(ProjectSettings.globalize_path(UI_PART))
