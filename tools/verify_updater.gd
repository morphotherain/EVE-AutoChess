extends SceneTree
## 热更器验收（`godot --headless --script tools/verify_updater.gd`）
##
## ══════════════════════════════════════════════════════════════════
##  它钉的是什么
## ══════════════════════════════════════════════════════════════════
##  **「发现新版本」绝不能自己下载。** 2026-11-07 之前 `_on_meta_done()` 拿到清单
##  就直接 `_download()`，玩家全程无感地被更新 —— 正在打一局，下次重启界面和数值
##  全变，像游戏被人动过。
##
##  ⚠️ 这条特别容易被人"好心"改回去（「自动更新多省事啊」）⇒ 必须有牙齿。
##     把 `_download()` 注回 `_on_meta_done()`，第 1 条必红。
##
##  顺带钉住四个边角：没有更新时不广播、没检测过点下载不崩、
##  下载收尾信号带对的版本号、清单不是 JSON 时静默放弃。
##
##  ── 为什么可以不联网就跑 ──────────────────────────────────────
##  直接调 `_on_meta_done()` 喂一个捏造的 HTTP 响应体，绕开真实网络。
##  ⚠️ `build_info()` 读的是 `res://build_info.json` ⇒ 断言里的 code 都用
##     `本地 code ± 1` 算，别写死数字（每次发版都会变）。
##
##  ① 拿到更新的清单 ⇒ 只填 `pending_update` + 发 `update_available`，**不下载**
##  ② 没有更新（remote_code <= local）⇒ 什么都不发
##  ③ `download_update()` 在没检测过时安全返回（不崩、不开进度）
##  ④ `_finish_download()` 会发 `download_finished` 并关掉进度心跳
##  ⑤ 清单不是 JSON ⇒ 静默放弃，不广播

const UP := preload("res://scripts/core/eve_updater.gd")

var _fails := 0


func _init() -> void:
	var local_code := int(_build_info().get("code", 0))
	print("[自检] 本地 code=%d version=%s" % [local_code, _build_info().get("version", "?")])

	# ── ① 有新版本 ────────────────────────────────────────────
	var u = UP.new()
	var seen: Array = []
	u.update_available.connect(func(info): seen.append(info))
	var body := JSON.stringify({
		"version": "9.9.9.9", "code": local_code + 1,
		"pck": {"sha256": "abc", "size": 1048576,
				"urls": ["http://example.invalid/a.pck"]},
	}).to_utf8_buffer()
	u._on_meta_done(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), body)
	_expect(not u.pending_update.is_empty(),
			"① 有新版本 ⇒ pending_update 被填（%s）" % u.pending_update.get("version", ""))
	_expect(seen.size() == 1, "① update_available 广播了 1 次（实测 %d）" % seen.size())
	_expect(int(u.pending_update.get("code", 0)) == local_code + 1,
			"① code 正确带出")
	_expect(int(u.pending_update.get("size", 0)) == 1048576, "① size 正确带出")
	_expect(Array(u.pending_update.get("urls", [])).size() == 1, "① urls 正确带出")
	_expect(not bool(u._downloading),
			"★★ ① 检测到更新后**没有自动下载**（这是本次改造的核心）")
	_expect(not bool(u._busy), "① 检测结束后 _busy 已释放（可以再 check）")
	_expect(String(u.status_text) == "",
			"① 发现更新时不该自己写状态字（弹窗负责说）")

	# ── ② 同版本 / 旧版本 ─────────────────────────────────────
	var u2 = UP.new()
	var seen2: Array = []
	u2.update_available.connect(func(info): seen2.append(info))
	var body2 := JSON.stringify({
		"version": "0.0.1", "code": maxi(0, local_code - 1),
		"pck": {"urls": ["http://example.invalid/a.pck"]},
	}).to_utf8_buffer()
	u2._on_meta_done(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), body2)
	_expect(u2.pending_update.is_empty(), "② 旧版本 ⇒ pending_update 保持空")
	_expect(seen2.is_empty(), "② 旧版本 ⇒ 不广播 update_available")

	# ── ③ 没检测过就点下载 ────────────────────────────────────
	var u3 = UP.new()
	u3.download_update()
	_expect(not bool(u3._downloading), "③ 没检测过 ⇒ download_update() 安全空转")
	_expect(u3.pending_update.is_empty(), "③ 没检测过 ⇒ 不会凭空造出 pending_update")

	# ── ④ 下载收尾的信号 ──────────────────────────────────────
	var u4 = UP.new()
	u4.pending_update = {"version": "9.9.9.9", "code": local_code + 1}
	var done: Array = []
	u4.download_finished.connect(func(ok, ver): done.append([ok, ver]))
	u4._downloading = true
	u4._finish_download(true, "V9.9.9.9 已下载 · 重启游戏后生效")
	_expect(done.size() == 1, "④ download_finished 广播了 1 次（实测 %d）" % done.size())
	if done.size() == 1:
		_expect(bool(done[0][0]) == true, "④ ok 透传为 true")
		_expect(String(done[0][1]) == "9.9.9.9", "④ 版本号透传（%s）" % done[0][1])
	_expect(not bool(u4._downloading), "④ 收尾后 _downloading 已复位")

	# ── ⑤ 清单结构不对 ────────────────────────────────────────
	var u5 = UP.new()
	var seen5: Array = []
	u5.update_available.connect(func(info): seen5.append(info))
	u5._on_meta_done(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(),
			"not json".to_utf8_buffer())
	_expect(seen5.is_empty(), "⑤ 清单不是 JSON ⇒ 静默放弃，不广播")

	print("")
	if _fails == 0:
		print("[自检] 全部通过")
	else:
		print("[自检] ✗ %d 条失败" % _fails)
	quit(0 if _fails == 0 else 1)


func _build_info() -> Dictionary:
	return UP.build_info()


func _expect(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ %s" % msg)
	else:
		_fails += 1
		print("  ✗ %s" % msg)
