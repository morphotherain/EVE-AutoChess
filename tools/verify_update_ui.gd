extends SceneTree

## 客户端自更新检查器验收（`godot --headless --script tools/verify_update_ui.gd`）
##
## ══════════════════════════════════════════════════════════════════
##  它钉的是什么
## ══════════════════════════════════════════════════════════════════
##  **更新链路绝不能挂在 autoload 的新成员上。**
##
##  2026-11-07 第一版「主动提示更新」写在 `EveUpdater` 里，主菜单用 `_up_has()`
##  查它的新成员再连信号。但 `EveUpdater` 是 autoload —— 节点在 pck 挂载**之前**
##  就实例化，脚本永远是基础包里的老版本 ⇒ 三个成员全 false ⇒ 直接 return
##  ⇒ **弹窗在真实玩家机器上一次都没跑过**（发了版、写了代码、没人见过）。
##
##  修法：整条链路搬到 `eve_update_ui.gd`（主菜单自己 `new()` 的普通 Node），
##  它自己读 build_info / 自己拉清单 / 自己下载校验，**不碰任何 autoload 成员**。
##
##  ⚠️ 第 ① 条是防回归的牙齿：谁在检查器里写回 `EveUpdater.xxx`，它立刻变红。
##     注释里提到 `EveUpdater` 是允许的（讲事故经过），所以扫描前必须**剥注释**。
##
##  ── 不联网 ────────────────────────────────────────────────────
##  只跑纯逻辑 + UI 状态机，⛔ 不调 `start()`（那会真打 49.233.138.141）。

const UPDATE_UI := preload("res://scripts/core/eve_update_ui.gd")
const UPDATE_PANEL := preload("res://scripts/ui/eve_update_panel.gd")

const PROJECT_FILE := "res://project.godot"
const UI_FILE := "res://scripts/core/eve_update_ui.gd"
const PANEL_FILE := "res://scripts/ui/eve_update_panel.gd"
const MENU_FILE := "res://scripts/eve_main_menu.gd"

var _fails := 0
var _checks := 0


func _initialize() -> void:
	print("[自检] 更新检查器 / 进度面板")
	print("")
	_check_static()
	_check_logic()
	await _check_panel()
	print("")
	if _fails == 0:
		print("[自检] 全部通过（%d 条）" % _checks)
	else:
		print("[自检] %d/%d 条失败" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)


# ══════════════════════════════════════════════════════════════════
#  静态：不许依赖 autoload
# ══════════════════════════════════════════════════════════════════
func _check_static() -> void:
	print("── 静态：不许依赖 autoload ──")

	# ① 检查器里不许出现 `EveUpdater.`
	#    [WHY] 它是 autoload，老客户端上是老脚本。这条是整次重构的核心目的。
	var ui := _strip_comments(_read(UI_FILE))
	_ok(not ui.contains("EveUpdater."),
			"① 检查器不访问 `EveUpdater.xxx`（老客户端上那些成员不存在）")

	# ② 检查器不许被注册成 autoload
	var autoload_block := _autoload_block()
	_ok(not autoload_block.contains("eve_update_ui.gd"),
			"② 检查器不在 autoload 列表里（否则老客户端永远拿不到新逻辑）")

	# ③ 主菜单不再连 EveUpdater 的更新信号
	var menu := _strip_comments(_read(MENU_FILE))
	var hits: Array = []
	for bad in ["EveUpdater.update_available", "EveUpdater.download_finished",
			"EveUpdater.pending_update", "EveUpdater.download_update"]:
		if menu.contains(bad):
			hits.append(bad)
	_ok(hits.is_empty(),
			"③ 主菜单不再访问 EveUpdater 的新成员（改走 eve_update_ui.gd）")
	for h in hits:
		print("      ✗ 仍在引用：", h)

	# ④ 主菜单确实把检查器 new 出来了（否则整条链没接上）
	_ok(menu.contains("UPDATE_UI.new()"),
			"④ 主菜单 `new()` 了检查器")
	_ok(menu.contains("_start_update_check()"),
			"⑤ `_ready()` 之后调用了 `_start_update_check()`")

	# ⑥ 面板必须是 Control（不是 Window：系统窗口换不掉皮，见文件顶注 ①）
	_ok(_read(PANEL_FILE).contains("extends Control"),
			"⑥ 面板 `extends Control`（⛔ 不是 Window）")

	# ⑦ 面板/检查器都不许有 class_name（注册表与 autoload 同款风险）
	_ok(not _read(UI_FILE).contains("class_name"),
			"⑦ 检查器没有 `class_name`（注册表跨 pck 边界同样不可靠）")


# ══════════════════════════════════════════════════════════════════
#  纯逻辑
# ══════════════════════════════════════════════════════════════════
func _check_logic() -> void:
	print("")
	print("── 逻辑：取源 / 长度容差 / sha256 / 清单读取 ──")

	var ui = UPDATE_UI.new()

	# ① 多源：数组优先 + 单值兜底 + 去重（GitHub 加速站说挂就挂）
	var urls: Array = ui._pick_urls({
		"urls": ["https://a/x.pck", "https://b/x.pck"],
		"url": "https://b/x.pck",
	})
	_ok(urls.size() == 2 and urls[0] == "https://a/x.pck" and urls[1] == "https://b/x.pck",
			"① 多源去重（数组去重后 2 条，单值不重复追加）")

	# ② 只有单值的老格式也要认
	var urls2: Array = ui._pick_urls({"url": "http://c/x.pck"})
	_ok(urls2.size() == 1, "② 兼容只有 `url` 的老清单格式")

	# ③ 长度容差 ±1（不同 FS 对 flush 的读数略有差异）
	ui._size = 1000
	_ok(ui._size_matches(1000) and ui._size_matches(999) and ui._size_matches(1001),
			"③ 长度容差 ±1 字节")
	_ok(not ui._size_matches(1002), "③ 超出 1 字节判定为不匹配")

	# ④ 清单没给 size 时一律不 match（⛔ 防止 0==0 误判成「已下载」）
	ui._size = 0
	_ok(not ui._size_matches(0), "④ `size` 未知时不算匹配（防 0==0 假阳性）")

	# ⑤ sha256 对已知内容
	var path := "user://_verify_sha.txt"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("abc")
	f.close()
	var got := ui._sha256_file(path)
	_ok(got == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
			"⑤ sha256('abc') 与标准值一致")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	# ⑥ 清单没给 sha 时信任（老格式兼容）
	ui._sha = ""
	_ok(ui._verify_sha(), "⑥ 清单无 sha256 时不卡校验（兼容老清单）")

	# ⑦ 能读到本地 build_info
	var info: Dictionary = ui.read_build_info()
	_ok(int(info.get("code", 0)) > 0, "⑦ `read_build_info()` 拿到 code")
	_ok(String(info.get("version", "")) != "0.0.0", "⑦ `read_build_info()` 拿到 version")

	ui.free()

	# ⑧ 清单比较（喂捏造响应体，绕开网络）
	_check_meta()


## 直接调 `_on_meta_done()`，用捏造的 HTTP 响应体测「比较 code → 发 asked」。
##
## ⚠️ code 用 `本地 ± 1` 算，⛔ 不写死数字 —— 否则每次升版本这条就变红。
func _check_meta() -> void:
	var local := int(UPDATE_UI.new().read_build_info().get("code", 0))
	var mine := local + 1

	var ui = UPDATE_UI.new()
	ui.cur_ver = "0.0.0"
	ui._cur_code = local
	var fired := {"asked": false, "new": ""}
	ui.asked.connect(func(_c: String, n: String, _s: float) -> void:
		fired["asked"] = true
		fired["new"] = n)
	ui._on_meta_done(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(),
			_meta_body(mine))
	_ok(bool(fired["asked"]) and String(fired["new"]) == "9.9.9.9",
			"⑧ 清单 code 更高 ⇒ 发 asked（带版本号）")
	ui.free()

	# ⑨ 清单 code 不比本地高 ⇒ 什么都不发
	var ui2 = UPDATE_UI.new()
	ui2.cur_ver = "0.0.0"
	ui2._cur_code = local
	var fired2 := {"asked": false}
	ui2.asked.connect(func(_c: String, _n: String, _s: float) -> void:
		fired2["asked"] = true)
	ui2._on_meta_done(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(),
			_meta_body(local))
	_ok(not bool(fired2["asked"]), "⑨ code 相同/更低 ⇒ 静默（不打扰玩家）")
	ui2.free()

	# ⑩ 非 JSON 响应 ⇒ 静默，不崩
	var ui3 = UPDATE_UI.new()
	ui3.cur_ver = "0.0.0"
	ui3._cur_code = local
	var fired3 := {"asked": false}
	ui3.asked.connect(func(_c: String, _n: String, _s: float) -> void:
		fired3["asked"] = true)
	ui3._on_meta_done(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(),
			"<html>404</html>".to_utf8_buffer())
	_ok(not bool(fired3["asked"]), "⑩ 响应不是 JSON ⇒ 静默（服务器被换页也不炸）")
	ui3.free()


func _meta_body(code: int) -> PackedByteArray:
	return JSON.stringify({
		"version": "9.9.9.9",
		"code": code,
		"pck": {"urls": ["http://127.0.0.1/x.pck"], "size": 1000,
				"sha256": ""},
	}).to_utf8_buffer()


# ══════════════════════════════════════════════════════════════════
#  面板状态机（要入树才会 `_ready()` → `_build()`）
# ══════════════════════════════════════════════════════════════════
func _check_panel() -> void:
	print("")
	print("── 面板：四态切换 ──")

	var panel = UPDATE_PANEL.new()
	root.add_child(panel)
	await process_frame      # 等 `_ready()` 把控件建完

	_ok(not panel.is_open(), "① 初始不显示（不会一进菜单就糊一层遮罩）")

	panel.show_ask("0.14.10.5.35", "0.14.10.5.41", 1.12)
	_ok(panel.is_open(), "② `show_ask()` 打开")
	_ok(panel._title_lb.text == "发现新版本", "② 标题正确")
	# ⚠️ 用「分别包含」而不是整串相等：版本号与体积之间的分隔符是纯排版
	#    （单空格 / 双空格都出现过），钉死空格数会让这条断言下次排版微调就红。
	_ok(panel._new_lb.text.contains("0.14.10.5.41")
			and panel._new_lb.text.contains("1.12 MB"),
			"② 新版本行含版本与体积")
	_ok(panel._cur_lb.text.contains("0.14.10.5.35"), "② 当前版本行含旧版本号")
	_ok(not panel._bar.visible, "② 询问态不显示进度条")

	# ── 开屏形态（用户 2026-11-07 明确要求，别再退化成小卡片）──
	# ⚠️ 这三条是「看起来能跑」和「玩家真的看得见」的分界，改版式前先读这里。
	var has_backdrop := panel.get_node_or_null("Backdrop") != null
	_ok(has_backdrop, "② 有不透明全屏底（`Backdrop` 节点）")
	if has_backdrop:
		var bd = panel.get_node("Backdrop")
		_ok(bd.color.a >= 0.99, "② 全屏底不透明（读起来是「换了个界面」而非浮层）")
	_ok(panel.anchor_right >= 0.999 and panel.anchor_bottom >= 0.999,
			"② 面板铺满视口（否则点得到后面的主菜单）")
	_ok(panel.get_node_or_null("Center/Card") == null,
			"② 不再用 460 宽的居中卡片（已改为开屏页）")

	panel.show_progress("0.14.10.5.35", "0.14.10.5.41", false)
	_ok(panel._bar.visible, "③ 进度态显示进度条")
	panel.set_progress(0.43, 500000, 1169352)
	_ok(absf(panel._bar.value - 43.0) < 0.51, "③ 进度条数值 = 43")
	_ok(panel._pct_lb.text == "43%", "③ 百分比文案 = 43%")
	_ok(panel._detail_lb.text.contains("MB"), "③ 明细行显示已下/总量")

	# 下载态不给任何退出入口。
	# [WHY] 上一版给了「后台继续」，收起之后进度只剩右下角一行小字 ——
	#       那正是用户否掉的东西（「而不是现在在右下角一点小字」）。
	_ok(not panel._btn_secondary.visible and not panel._btn_primary.visible,
			"④ 下载中两个按钮都隐藏（既不「取消」也不「收起」）")

	panel.show_ready("0.14.10.5.41")
	_ok(panel._title_lb.text == "更新已就绪", "⑤ 就绪态标题")
	_ok(panel._btn_primary.text == "立即重启", "⑤ 主按钮 = 立即重启")
	_ok(not panel._bar.visible, "⑤ 就绪态收起进度条")
	# 旧版这里「当前版本」显示成一个破折号（`show_ready` 拿不到 cur），截图确认过。
	_ok(not panel._cur_row.visible,
			"⑤ 就绪态隐藏「当前版本」行（否则显示成破折号）")

	panel.show_error("网络不给力", "0.14.10.5.35", "0.14.10.5.41")
	_ok(panel._title_lb.text == "更新失败", "⑥ 失败态标题")
	_ok(panel._btn_primary.text == "重试", "⑥ 主按钮 = 重试")

	panel.close()
	_ok(not panel.is_open(), "⑦ `close()` 收起")
	panel.free()


# ══════════════════════════════════════════════════════════════════
#  工具
# ══════════════════════════════════════════════════════════════════


func _ok(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("  ✓ ", label)
	else:
		_fails += 1
		print("  ✗ ", label)


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s


## 剥掉 `#` 开头的行注释与行尾注释。
## ⚠️ 必须剥：本工程的注释里大段引用 `EveUpdater.xxx` 讲事故经过，
##    不剥的话「不许出现 EveUpdater.」这条永远红。
func _strip_comments(src: String) -> String:
	var out := ""
	for line in src.split("\n"):
		var s := String(line)
		var q := s.find("\"")
		var h := s.find("#")
		if h >= 0 and (q < 0 or h < q):
			s = s.substr(0, h)
		out += s + "\n"
	return out


func _autoload_block() -> String:
	var proj := _read(PROJECT_FILE)
	var block := ""
	var inside := false
	for line in proj.split("\n"):
		var s := String(line).strip_edges()
		if s.begins_with("["):
			inside = s == "[autoload]"
			continue
		if inside and s != "":
			block += s + "\n"
	return block
