extends SceneTree
## 诊断上报器验收（`godot --headless --script tools/verify_report.gd`）
##
## ══════════════════════════════════════════════════════════════════
##  它钉的是什么
## ══════════════════════════════════════════════════════════════════
##  **上报宿主绝不能依赖 autoload，也绝不能跨 pck 边界读老节点的新字段。**
##
##  2026-11-07 的 b39 事故就是这么来的：`EveReport` 被注册成 autoload，
##  主菜单里裸写 `EveReport.open_feedback()`。老客户端的 autoload 注册表里
##  没有这个名字（引擎启动时定死，`load_resource_pack` 改不了），
##  GDScript 编译期直接
##      Parse Error: Identifier "EveReport" not declared in the current scope
##  ⇒ 主菜单脚本加载失败 ⇒ 场景没脚本 ⇒ **整屏黑**。b38 及以前全中。
##
##  所以这份验收里有好几条是**静态检查**（扫源码文本）而不是跑行为：
##  这类错误在编译期就发生，运行时根本跑不到。
##
##  ⚠️ 第 1、2、3 条是防回归的牙齿：把 `EveReport` 加回 autoload、
##     或在任何脚本里写回 `EveReport.xxx`，它们立刻变红。
##
##  ── 不联网 ────────────────────────────────────────────────────
##  全程只读文件 + 试探私有函数，⛔ 不调 `_post()` / `_boot()`。
##  `start()` 那一组靠 `user://report_off` 短路（见第 11 条）。

const REPORTER := preload("res://scripts/core/eve_report.gd")

const PROJECT_FILE := "res://project.godot"
const REPORT_FILE := "res://scripts/core/eve_report.gd"
const MENU_FILE := "res://scripts/eve_main_menu.gd"

var _fails := 0
var _checks := 0


func _init() -> void:
	var local := _build_info()
	print("[自检] 本地 version=%s code=%d" % [
			String(local.get("version", "?")), int(local.get("code", 0))])
	print("")

	_check_static()
	_check_runtime()

	print("")
	if _fails == 0:
		print("[自检] 全部通过（%d 条）" % _checks)
	else:
		print("[自检] %d/%d 条失败" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)


# ══════════════════════════════════════════════════════════════════
#  静态检查：这类错误在编译期就炸，必须扫源码
# ══════════════════════════════════════════════════════════════════
func _check_static() -> void:
	print("── 静态：不许依赖 autoload ──")

	# ① project.godot 的 [autoload] 里不许有 EveReport
	var proj := _read(PROJECT_FILE)
	var autoload_block := ""
	var in_block := false
	for line in proj.split("\n"):
		var s := String(line).strip_edges()
		if s.begins_with("["):
			in_block = s == "[autoload]"
			continue
		if in_block and s != "":
			autoload_block += s + "\n"
	_ok(not autoload_block.contains("EveReport="),
			"① EveReport 不在 autoload 列表里（否则热更救不了老客户端）")
	if autoload_block.contains("EveReport="):
		print("      实际 autoload：", autoload_block.replace("\n", " | "))

	# ② 全工程不许有 `EveReport.xxx` 裸引用
	var hits := _grep_all_gd("EveReport.")
	_ok(hits.is_empty(),
			"② 没有脚本裸引用 `EveReport.xxx`（会 Parse Error）")
	for h in hits:
		print("      ✗ ", h)

	# ③ eve_report.gd 不许读 EveBoot 的新字段
	#    [WHY] EveBoot 排在 EveUpdater 前面 ⇒ 它在 pck 挂载之前就实例化了，
	#          脚本永远是基础包里的老版本；had_unclean_exit 等是 2026-11-07 才加的。
	#    ⚠️ 必须**去掉注释**再判：本文件的注释里大段引用这些名字讲事故经过，
	#       不剥注释的话这条永远红。
	var rep := _strip_comments(_read(REPORT_FILE))
	var boot_hits: Array = []
	for bad in ["EveBoot.had_unclean_exit", "EveBoot.unclean_ts",
			"EveBoot.log_snapshot_path", "EveBoot.log_path"]:
		if rep.contains(bad):
			boot_hits.append(bad)
	_ok(boot_hits.is_empty(),
			"③ 上报器不读 EveBoot 的字段（老客户端上它们不存在）")
	for h in boot_hits:
		print("      ✗ 仍在引用：", h)

	# ④ 主菜单不许再访问 EveUpdater 的新成员
	#    [WHY] 2026-11-07 二版：更新链路整体搬到 `eve_update_ui.gd`（主菜单 `new()`
	#          出来的普通 Node）。主菜单不再连 autoload 的信号 —— 那条路在老客户端
	#          上是死的（节点用老脚本，成员根本不存在）。
	var menu := _strip_comments(_read(MENU_FILE))
	var up_hits: Array = []
	for bad in ["EveUpdater.update_available", "EveUpdater.download_finished",
			"EveUpdater.pending_update", "EveUpdater.download_update"]:
		if menu.contains(bad):
			up_hits.append(bad)
	_ok(up_hits.is_empty(),
			"④ 主菜单不再访问 EveUpdater 的新成员（改走 eve_update_ui.gd）")
	for h in up_hits:
		print("      ✗ 仍在引用：", h)

	# ⑤ 上报器保留 static 去重（主菜单 + autoload 两条路会打架）
	_ok(rep.contains("static var _started"),
			"⑤ 上报器有 `static var _started` 去重")

	# ⑥ 主菜单不许再出现 `EveReport.` 裸引用（第 ② 条已覆盖，单独再钉一次）
	_ok(not menu.contains("EveReport."),
			"⑥ 主菜单不再出现 `EveReport.xxx`（注释也一起清掉了）")


# ══════════════════════════════════════════════════════════════════
#  运行时检查：行为
# ══════════════════════════════════════════════════════════════════
func _check_runtime() -> void:
	print("")
	print("── 运行时：存活标记 / 心跳节流 / 采集 ──")

	# 备份玩家真实状态，测完还回去（⛔ 验收脚本不许污染存档目录）
	var alive_bak := _read_opt("user://report_alive.cfg")
	var hb_bak := _read_opt("user://report_hb.txt")
	var had_alive := FileAccess.file_exists("user://report_alive.cfg")
	var had_hb := FileAccess.file_exists("user://report_hb.txt")

	var r = REPORTER.new()

	# ⑦ 采集能跑通，且带上热更诊断字段
	var p: Dictionary = r.collect("heartbeat", "selftest")
	_ok(typeof(p) == TYPE_DICTIONARY and p.has("version") and p.has("os"),
			"⑦ `collect()` 返回完整字典")
	_ok(p.has("update_pck_bytes") and p.has("update_boot_fail"),
			"⑦ 采集里带热更诊断字段（update_pck_bytes / update_boot_fail）")
	_ok(p.has("prev_stage"),
			"⑦ 采集里带 prev_stage（分辨黑屏 / 运行中崩溃）")

	# ⑧ 存活标记三态能写能读
	r._write_stage(0)
	_ok(r._read_stage() == 0, "⑧ stage=0（引擎起来了、界面没出来）可读写")
	r._write_stage(1)
	_ok(r._read_stage() == 1, "⑧ stage=1（主菜单已出现）可读写")
	r._write_stage(2)
	_ok(r._read_stage() == 2, "⑧ stage=2（正常退出）可读写")

	# ⑨ 没有文件时不许瞎猜
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://report_alive.cfg"))
	_ok(r._read_stage() == -1, "⑨ 没有标记文件 ⇒ 返回 -1（首次运行，不算崩溃）")

	# ⑩ 心跳节流：刚写过时间戳就不该再发
	r._write_ts("user://report_hb.txt", int(Time.get_unix_time_from_system()))
	var last := r._read_ts("user://report_hb.txt")
	_ok(last > 0, "⑩ 心跳时间戳可写可读")
	var now := int(Time.get_unix_time_from_system())
	_ok(now - last < r.HEARTBEAT_GAP_SEC,
			"⑩ 刚发过心跳 ⇒ 落在 24h 窗口内（不会重复发）")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://report_hb.txt"))

	# ⑪ `start()` 幂等，且玩家开了 opt-out 时一个字节都不发
	var f := FileAccess.open("user://report_off", FileAccess.WRITE)
	_ok(f != null, "⑪ 能创建 opt-out 开关（user://report_off）")
	if f != null:
		f.close()
	r.start()
	_ok(r._started, "⑪ `start()` 置起了 _started")
	r.start()  # 第二次
	_ok(r._started, "⑪ 重复调 `start()` 不炸（static 去重）")
	_ok(r.last_status == "", "⑪ opt-out 生效：没有发出任何东西")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://report_off"))

	r.free()

	# 还回玩家真实状态
	_restore("user://report_alive.cfg", alive_bak, had_alive)
	_restore("user://report_hb.txt", hb_bak, had_hb)


# ── 工具 ──────────────────────────────────────────────────────────
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


func _read_opt(path: String) -> String:
	return _read(path)


## 去掉所有 `#` 行尾注释，只留代码。
## [WHY] 静态检查必须看**代码**，不能看注释 —— 本工程注释里大量写事故经过
##       （"以前是 `EveReport.open_feedback()`"、"别读 EveBoot.had_unclean_exit"），
##       不剥的话检查永远红。
## [PITFALL] 这里不处理「字符串里的 #」。GDScript 里那种写法极少，
##           万一误剥只会让检查更严（宁可误报，不可漏报）。
func _strip_comments(txt: String) -> String:
	var out: Array[String] = []
	for line in txt.split("\n"):
		var cut := String(line).find("#")
		out.append(String(line) if cut < 0 else String(line).substr(0, cut))
	return "\n".join(out)


func _restore(path: String, content: String, existed: bool) -> void:
	if existed:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(content)
			f.close()
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## 递归扫所有 .gd，找含 `needle` 的**非注释**行。
## [PITFALL] `eve_report.gd` 自己的注释里大量提到 `EveReport.xxx`（讲事故经过），
##           必须跳过注释，否则这条永远红。
func _grep_all_gd(needle: String) -> Array:
	var out: Array = []
	_walk("res://scripts", needle, out)
	return out


func _walk(dir_path: String, needle: String, out: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	for sub in d.get_directories():
		_walk(dir_path + "/" + sub, needle, out)
	for fn in d.get_files():
		if not fn.ends_with(".gd"):
			continue
		var full := dir_path + "/" + fn
		var txt := _read(full)
		if txt == "":
			continue
		for line in txt.split("\n"):
			var s := String(line)
			var code := s.strip_edges()
			if code.begins_with("#"):
				continue
			# 去掉行尾注释再判（`foo()  # 见 EveReport.xxx` 不算引用）
			var cut := s.find("#")
			if cut >= 0:
				s = s.substr(0, cut)
			if s.contains(needle):
				out.append("%s :: %s" % [full.replace("res://", ""), s.strip_edges()])
	return


func _build_info() -> Dictionary:
	if FileAccess.file_exists("res://build_info.json"):
		var f := FileAccess.open("res://build_info.json", FileAccess.READ)
		if f != null:
			var d: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(d) == TYPE_DICTIONARY:
				return d
	return {}
