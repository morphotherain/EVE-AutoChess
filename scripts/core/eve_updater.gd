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

## 给界面读的一行字（空 = 不显示）。
var status_text := ""

var _busy := false
var _http: HTTPRequest = null


func _init() -> void:
	# ⚠️ 挂载必须**最早**：再晚一点别的脚本已经被实例化，挂上去也换不掉它们。
	_try_mount()


func _ready() -> void:
	# [WHY] 网页版的包是站点直接分发的，不存在"本地热更"这回事；
	#       而且跨域拉 49.233.138.141 会被 CORS 拦掉，刷一堆报错还白等两帧。
	if OS.has_feature("web"):
		set_process(false)
		return
	# 联网检查放两帧之后：让主菜单先把画面铺出来，别让启动像卡住。
	await get_tree().process_frame
	await get_tree().process_frame
	check()


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


## ── 版本对比 + 下载 ────────────────────────────────────────────
func check() -> void:
	if _busy:
		return
	_busy = true
	_set_status("")

	_http = HTTPRequest.new()
	_http.timeout = REQ_TIMEOUT
	add_child(_http)
	_http.request_completed.connect(_on_meta_done)
	var err := _http.request(META_URL)
	if err != OK:
		# 拿不到清单 = 不更新。⛔ 不是错误路径，静默走人。
		_finish("")
		return


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

	_set_status("发现新版本 V%s · 准备下载" % String((meta as Dictionary).get("version", "?")))
	_download(urls, 0, String(pck.get("sha256", "")), remote_code,
			String((meta as Dictionary).get("version", "")))


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
		_finish("")
		return
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
				_finish("更新包校验不通过，已放弃（不影响游戏）")
			return

	# 覆盖旧包。`DirAccess.rename` 在同目录下是原子的。
	var dir := DirAccess.open("user://")
	if dir == null or dir.rename(TMP_PCK.get_file(), USER_PCK.get_file()) != OK:
		_clean_tmp()
		_finish("")
		return

	_write_state({"boot_fail": 0})
	_set_status("V%s 已下载 · 重启游戏后生效" % ver)
	changed.emit()


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
