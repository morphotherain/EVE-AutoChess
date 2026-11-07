extends Node
## 热更客户端（PCK 覆盖）—— autoload，**必须排在 `EveBoot` 之前**。
##
## ══════════════════════════════════════════════════════════════════
##  一句话原理
## ══════════════════════════════════════════════════════════════════
##  Godot 支持的「热更」只有一件事：`ProjectSettings.load_resource_pack()`。
##  把服务器上的一份 `.pck` 挂进来，它就会**覆盖** `res://` 里同名资源
##  （GDScript 编译后也是 pck 里的资源，所以连逻辑、界面、数值一起能更）。
##
##  ⛔ 引擎本体（exe / Android 的 libgodot）**换不了** —— 这类更新仍要重发整包。
##
## ── 三条硬约束（都是踩过的坑，别改）──────────────────────────────
##  1. **全量 pck，绝不做增量**：`load_resource_pack` 是**叠加**不是替换，
##     删掉的文件在旧 pck 里还在。全量 = 每次都是完整快照，没有残留。
##  2. **必须校验 SHA256**：玩家网络差下到半个包，挂上去等于启动即崩。
##     校验不过就丢弃，照常用本地版本进游戏。
##  3. **服务器挂了不能拦路**：本文件任何一步失败都只是「不更新」，
##     `status_text` 写给界面看，⛔ 绝不 return / push_error 中断启动。
##
## ── 自愈：坏包三次自动回退 ───────────────────────────────────────
##  挂载 pck 前把 `boot_fail` +1，主菜单起来后 `mark_boot_ok()` 清零。
##  连续 3 次没走到主菜单 ⇒ 认定这个包有毒 ⇒ 删包回退，玩家照样能玩。
##  ⚠️ 这是**玩家人肉抢救不了**的唯一场景（pck 坏了进不去设置页），
##     所以必须自动，不能指望用户删文件。
##
## ── 版本号从哪来 ──────────────────────────────────────────────
##  `res://build_info.json`（由 `tools/export_release.sh` 在打包前生成：
##  version 取自 `project.godot`、code 取自 `export_presets.cfg` 的 version/code）。
##  ⚠️ 读它**必须晚于** `_try_mount()`：pck 里也带一份新的 build_info.json，
##     挂载后读到的自然就是新版本号 —— 省掉一套「已挂载版本」的记账。
##
## ── ★ 2026-11-07 改造：检查与下载**分成两步**，中间插一次玩家确认 ──────
##  改造前：`check()` 拉到清单就**直接下**，玩家全程无感，只有右下角一行小字。
##          好处是更新率 100%；坏处是**玩家不知道自己被更新了** ——
##          正在打一局、下一把重启后界面/数值全变，像是游戏被人改过。
##  改造后：`check()` 只负责「发现」，结果放进 `pending_update` 并广播
##          `update_available`；真正的下载要等玩家点「现在更新」→ `download_update()`。
##
##  ⚠️⚠️ **两条路都要留**（信号 + 字段），别只留一个：
##     `check()` 在 autoload 阶段就跑，主菜单 `_ready()` 未必赶得上连信号；
##     信号发出去没人接就是彻底丢了。所以主菜单既连信号、也读 `pending_update`，
##     谁先到都能补上（见 `eve_main_menu._wire_updater`）。
##  ⚠️ 「稍后」**不持久化**（用户 2026-11-07 定）：下次启动照样问。
##     所以本文件没有任何 skipped_code 之类的记忆 —— 别好心加回来。
##
## ── 进度怎么报 ────────────────────────────────────────────────
##  只有真在下载时才开 `_process`（平时关着，空转一帧都省）。
##  用 `HTTPRequest.get_downloaded_bytes()` 轮询，**按整数百分比节流**：
##  不节流的话每帧都 `changed.emit()`，主菜单那行小字会被刷爆。
##  ⚠️ 别指望 `download_file` 模式给进度回调 —— 它没有，只能轮询。

const META_URL := "http://49.233.138.141/update/version.json"
const USER_PCK := "user://update.pck"
const TMP_PCK := "user://update.pck.part"
const STATE_PATH := "user://update_state.cfg"

## 拉**清单**的超时（秒）。很短 —— 启动阶段宁可放弃更新，也不能让玩家干等。
const REQ_TIMEOUT := 6.0

## 下载**包**的超时（秒）。⚠️ 跟拉清单不是一回事，别混用：
##   6 MB 的包在 506 KB/s 下要 12 秒，用 6 秒的清单超时去下包，
##   等于**永远下不完就被自己砍断**（这个 bug 躺了两天没被发现，
##   因为一直没真下载过）。
##
## 两个值分开的原因：
##   · 前面那几源是「能用就更快、不能用就算了」，给 REGION 短超时快点换源；
##   · **最后一个源是保底**，可能是慢速移动网络，必须给足时间慢慢下。
const DL_TIMEOUT_TRY := 15.0
const DL_TIMEOUT_LAST := 300.0

## 连续多少次没进到主菜单就判这个包有毒。
const MAX_BOOT_FAIL := 3

signal changed

## ★ 2026-11-07：检测到可用更新，**等玩家决定**（不自动下载）。
##   `info` 结构见 `pending_update`。
signal update_available(info: Dictionary)

## ★ 2026-11-07：一次下载尝试有了结果。
##   `ok = false` 也发 —— 主菜单靠这个把「下载中」的提示收掉。
signal download_finished(ok: bool, version: String)

## 给界面读的一行字（空 = 不显示）。
var status_text := ""

## ★ 2026-11-07：检测到的可用更新（空 = 没有）。
##   结构：`{version, code, notes, size, sha256, urls}`。
##   ⚠️ 下载成功后**不清空** —— 保留到进程结束，方便「已就绪」的后续提示读版本号。
var pending_update: Dictionary = {}

## 下载中？
var _downloading := false
## 进度节流用的上一档整数百分比（-1 = 还没报过）。
var _dl_pct := -1
## 已下载字节数（只用来判断"有没有前进"，避免同一数值反复刷 UI）。
var _dl_seen := 0
## 本次下载的总字节数（清单里的 `pck.size`；0 = 未知 ⇒ 只显示"下载中"）。
var _dl_total := 0

var _busy := false
var _http: HTTPRequest = null


func _init() -> void:
	# ⚠️ 挂载必须**最早**：再晚一点别的脚本已经被实例化，挂上去也换不掉它们。
	_try_mount()


func _ready() -> void:
	# 进度心跳默认关着：只有真在下载才开（见 `_process`）。
	set_process(false)
	# [WHY] 网页版的包是站点直接分发的，不存在"本地热更"这回事；
	#       而且跨域拉 49.233.138.141 会被 CORS 拦掉，刷一堆报错还白等两帧。
	if OS.has_feature("web"):
		return
	# 联网检查放两帧之后：让主菜单先把画面铺出来，别让启动像卡住。
	await get_tree().process_frame
	await get_tree().process_frame
	check()


## 下载进度心跳。平时 `set_process(false)`，只有 `_download()` 期间在跑。
##
## ⚠️ `download_file` 模式**没有进度回调**，只能轮询 `get_downloaded_bytes()`。
## ⚠️ 按整数百分比节流：不节流就是每帧一次 `changed.emit()`，
##    主菜单那行小字会被刷到闪，还白烧 CPU。
func _process(_delta: float) -> void:
	if not _downloading or _http == null:
		return
	var got := int(_http.get_downloaded_bytes())
	if got <= _dl_seen:
		return
	_dl_seen = got
	if _dl_total <= 0:
		# 清单没给 size（老清单）⇒ 只说"下载中"，不编一个假百分比
		if _dl_pct != 0:
			_dl_pct = 0
			_set_status("正在下载更新…")
		return
	var pct := clampi(int(float(got) * 100.0 / float(_dl_total)), 0, 100)
	if pct == _dl_pct:
		return
	_dl_pct = pct
	_set_status("正在下载更新 %d%%" % pct)


## ── 挂载已下载的包（启动时唯一会被调用的地方）──────────────────
func _try_mount() -> void:
	if not FileAccess.file_exists(USER_PCK):
		return

	var st := _read_state()
	var fails := int(st.get("boot_fail", 0))
	if fails >= MAX_BOOT_FAIL:
		# 挂了这个包之后连续 3 次都没进到主菜单 ⇒ 包有毒，扔掉回退。
		DirAccess.remove_absolute(ProjectSettings.globalize_path(USER_PCK))
		_write_state({"boot_fail": 0})
		print("[updater] 热更包连续 %d 次启动失败，已删除并回退到本地版本" % fails)
		return

	# 先记账再挂载：万一挂完就崩，下次启动计数已经 +1 了。
	_write_state({"boot_fail": fails + 1})

	if ProjectSettings.load_resource_pack(USER_PCK, true):
		print("[updater] 已挂载热更包 %s" % USER_PCK)
	else:
		print("[updater] 挂载失败（包可能损坏），本次用本地版本")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(USER_PCK))
		_write_state({"boot_fail": 0})


## 主菜单起来后调用：说明这次启动是好的，清掉失败计数。
func mark_boot_ok() -> void:
	var st := _read_state()
	if int(st.get("boot_fail", 0)) != 0:
		_write_state({"boot_fail": 0})


## ★ 2026-11-07：重启游戏（玩家点「立即重启」时走这里）。
##
## ⚠️ 三个平台各有各的坑，别合并：
##   · **web** —— 没有"重启进程"这回事，退出也不生效 ⇒ 什么都不做，让玩家刷页。
##   · **移动端** —— Android 上退出后能否重建进程由系统决定，要自拉起得走 Intent
##     （我们没有这层集成）⇒ 老实退出，玩家点图标进来即可。⛔ 别去试
##     `create_instance`，它在 Android 上没有可用实现。
##   · **编辑器** —— ⛔⛔ 绝不能调 `create_instance`：它会把**编辑器本身**
##     再开一份，玩家/开发者都会一脸问号。
func restart_app() -> void:
	if OS.has_feature("web"):
		return
	if not OS.has_feature("mobile") and not OS.has_feature("editor"):
		# 拉起失败（返回 -1）也不报错：后面照样 quit，效果等同"玩家自己重启"
		OS.create_instance(PackedStringArray())
	get_tree().quit()


## ── 版本对比（只发现，不下载）─────────────────────────────────
func check() -> void:
	if _busy:
		return
	_busy = true
	_set_status("")

	_ensure_http()
	# ⚠️ 复用同一个 `_http` ⇒ 先清掉上一轮的回调，否则一次响应会触发多个 handler
	#    （`bind` 每次造新 Callable，拿原函数 disconnect 是匹配不上的，见 `_reset_sig`）。
	_reset_sig()
	_http.timeout = REQ_TIMEOUT
	_http.request_completed.connect(_on_meta_done)
	var err := _http.request(META_URL)
	if err != OK:
		# 拿不到清单 = 不更新。⛔ 不是错误路径，静默走人。
		_finish("")
		return


## `_http` 是**复用**的：清单请求和下载请求共用一个实例。
## ⚠️ 所以每次换用途前必须先 `_reset_sig()` 清回调（见那里的说明）。
func _ensure_http() -> void:
	if _http == null:
		_http = HTTPRequest.new()
		add_child(_http)


func _on_meta_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_finish("")
		return
	var meta: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(meta) != TYPE_DICTIONARY:
		_finish("")
		return

	var remote_code := int((meta as Dictionary).get("code", 0))
	var local := build_info()
	if remote_code <= int(local.get("code", 0)):
		_finish("")
		return

	var pck: Dictionary = (meta as Dictionary).get("pck", {})
	var urls := _pick_urls(pck)
	if urls.is_empty():
		_finish("")
		return

	# ★ 2026-11-07：到此为止。⛔ 不在这里 `_download()`（改造前是直接下的）。
	#   把结论交给界面，谁来问玩家由主菜单决定（见文件顶注）。
	pending_update = {
		"version": String((meta as Dictionary).get("version", "")),
		"code": remote_code,
		"notes": String((meta as Dictionary).get("notes", "")),
		"size": int(pck.get("size", 0)),
		"sha256": String(pck.get("sha256", "")),
		"urls": urls,
	}
	_finish("")
	update_available.emit(pending_update)


## ── 玩家点了「现在更新」之后才走这里 ──────────────────────────
##
## ⚠️ 没检测过 / 已经在下 / 没有可用更新 ⇒ 直接 return，不报错。
##    这几种都是「界面状态和后台不一致」的边角，喊出来只会让人以为出故障了。
func download_update() -> void:
	if _busy or _downloading or pending_update.is_empty():
		return
	var urls: Array = pending_update.get("urls", [])
	if urls.is_empty():
		return
	# 占住 `_busy`：下载期间再来一次 `check()` 会把清单请求塞进同一个 `_http`，
	# 把正在跑的下载打断（复用实例，不可能并发）。
	_busy = true
	_downloading = true
	_dl_pct = -1
	_dl_seen = 0
	_dl_total = int(pending_update.get("size", 0))
	set_process(true)
	_set_status("准备下载更新…")
	_download(urls, 0,
			String(pending_update.get("sha256", "")),
			int(pending_update.get("code", 0)),
			String(pending_update.get("version", "")))


## 从清单里取出**候选下载地址**，按顺序试。
##
## `pck.urls` 是数组（新格式，推荐）；`pck.url` 是单值（老格式，兼容 0.14.10
## 已发出去的客户端）。两者都支持，数组优先、单值补在后面去重。
##
## ⚠️ 为什么需要多个源：分发节点只有 4 Mbps 出网，二十几个玩家同时拉 6 MB
##    就能把带宽吃干；把包放到 GitHub + 加速站后，服务器只剩几百字节的清单。
##    但加速站是第三方、说挂就挂 ⇒ 必须留自己服务器作兜底，不能单点。
static func _pick_urls(pck: Dictionary) -> Array:
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


## 清空 `_http` 上的所有回调。
##
## ⚠️ 必须这么做，不能只 `disconnect(_on_pck_done)` —— 我们连的是
##    `_on_pck_done.bind(...)`，`bind` 每次都造一个新 Callable，
##    拿原始函数去 disconnect 是**匹配不上**的（不报错，只是没断开），
##    结果换源后旧回调还挂着，一次响应触发多个 handler。
func _reset_sig() -> void:
	if _http == null:
		return
	for c in _http.request_completed.get_connections():
		_http.request_completed.disconnect(c["callable"])


## 按 `idx` 试第 `idx` 个源；失败（连不上 / 非 200 / 校验不过）自动换下一个。
func _download(urls: Array, idx: int, want_sha: String, remote_code: int, ver: String) -> void:
	if idx >= urls.size():
		_clean_tmp()
		_finish_download(false, "网络不顺畅，更新包没下下来（不影响游戏，下次再试）")
		return
	# ⚠️ 清单请求结束时 `_finish()` 已经把 `_http` 释放掉了 ⇒ 这里必须重建。
	_ensure_http()
	_reset_sig()
	_http.download_file = TMP_PCK
	# 最后一个源给足时间；前面的是"能用就更快"的备选，连不上就快点换
	_http.timeout = DL_TIMEOUT_LAST if idx == urls.size() - 1 else DL_TIMEOUT_TRY
	_http.request_completed.connect(
			_on_pck_done.bind(urls, idx, want_sha, remote_code, ver))
	var err := _http.request(String(urls[idx]))
	if err != OK:
		# 连请求都发不出去（多半是地址不合法），直接换下一个
		_download(urls, idx + 1, want_sha, remote_code, ver)


func _on_pck_done(result: int, code: int, _headers: PackedStringArray,
		_body: PackedByteArray, urls: Array, idx: int,
		want_sha: String, remote_code: int, ver: String) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		# 这个源不行（连不上 / 404 / 加速站挂了）⇒ 换下一个，别让玩家卡住
		_clean_tmp()
		_download(urls, idx + 1, want_sha, remote_code, ver)
		return

	if want_sha != "":
		var got := _sha256(TMP_PCK)
		if got != want_sha.to_lower():
			# 下坏了。⛔ 绝不能拿半个包装上去。
			# ⚠️ 校验不过有两种可能：玩家网络差，或者**这个源给的内容是错的**
			#    （加速站缓存了旧包 / 被劫持）。两种情况换一个源都是对的。
			_clean_tmp()
			if idx + 1 < urls.size():
				_download(urls, idx + 1, want_sha, remote_code, ver)
			else:
				_finish_download(false, "更新包校验不通过，已放弃（不影响游戏）")
			return

	# 覆盖旧包。`DirAccess.rename` 在同目录下是原子的。
	var dir := DirAccess.open("user://")
	if dir == null or dir.rename(TMP_PCK.get_file(), USER_PCK.get_file()) != OK:
		_clean_tmp()
		_finish_download(false, "")
		return

	_write_state({"boot_fail": 0})
	_finish_download(true, "V%s 已下载 · 重启游戏后生效" % ver)


## 一次下载尝试的统一收尾（成功 / 失败都走）。
##
## ⚠️ 必须清 `_downloading` 并 `set_process(false)`，否则进度心跳会一直跑、
##    而且下一次 `download_update()` 会被 `_downloading` 挡死。
func _finish_download(ok: bool, text: String) -> void:
	var ver := String(pending_update.get("version", ""))
	_downloading = false
	set_process(false)
	_dl_seen = 0
	_dl_pct = -1
	_finish(text)
	download_finished.emit(ok, ver)


func _clean_tmp() -> void:
	if FileAccess.file_exists(TMP_PCK):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PCK))


func _finish(text: String) -> void:
	if _http != null:
		_http.queue_free()
		_http = null
	_busy = false
	if text != "":
		_set_status(text)
	changed.emit()


func _set_status(text: String) -> void:
	status_text = text
	changed.emit()


# ── 工具 ──────────────────────────────────────────────────────

## 当前生效的版本信息 `{version:String, code:int}`。
## ⚠️ 读的是 `res://build_info.json` —— 已挂载 pck 时它会**自动**变成 pck 里那份。
static func build_info() -> Dictionary:
	var v := str(ProjectSettings.get_setting("application/config/version", "0.0.0"))
	var c := 0
	if FileAccess.file_exists("res://build_info.json"):
		var f := FileAccess.open("res://build_info.json", FileAccess.READ)
		if f != null:
			var d: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(d) == TYPE_DICTIONARY:
				v = String((d as Dictionary).get("version", v))
				c = int((d as Dictionary).get("code", 0))
	return {"version": v, "code": c}


static func _sha256(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while f.get_position() < f.get_length():
		ctx.update(f.get_buffer(1 << 20))
	f.close()
	return ctx.finish().hex_encode()


static func _read_state() -> Dictionary:
	var cf := ConfigFile.new()
	if cf.load(STATE_PATH) != OK:
		return {}
	var d: Variant = cf.get_value("update", "state", {})
	return d if typeof(d) == TYPE_DICTIONARY else {}


static func _write_state(patch: Dictionary) -> void:
	var cur := _read_state()
	cur.merge(patch, true)
	var cf := ConfigFile.new()
	cf.set_value("update", "state", cur)
	cf.save(STATE_PATH)
