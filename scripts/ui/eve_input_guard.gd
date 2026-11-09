extends RefCounted

## 空格键语义守卫 —— 把「空格」从 `ui_accept` 动作里摘掉。
##
## ══════════════════════════════════════════════════════════════════
##  为什么需要它
## ══════════════════════════════════════════════════════════════════
##  `BaseButton` 除了响应鼠标点击，还会响应 `ui_accept` 动作
##  （默认 = 空格 / 回车 / 手柄 A）。而鼠标点过按钮之后，按钮会**拿走键盘焦点**
##  （`focus_mode` 默认 `FOCUS_ALL`），于是此后按空格 = 又按了它一次。
##
##  实测症状（2026-11-08 玩家反馈）：
##    点完商店「↻ 刷新」→ 按空格想暂停 ⇒ 又刷了一次（刷新扣钱）；
##    点完「▲ 等级加速」→ 按空格 ⇒ 又升一级。
##  空格在本游戏里只有一个含义：暂停 / 继续（顶条写的就是这个）。
##
## ── 为什么摘 `ui_accept` 里的空格，而不是去抢焦点 ────────────────
##  ⛔ 试过「拿到焦点就 `release_focus()`」，**把全游戏的按钮点死了**：
##     `gui_focus_changed` 是在鼠标**按下**那一刻发的，此时 `BaseButton` 的
##     `press_attempt` 刚置位；释放焦点会连带把这个状态清掉，抬手时 `pressed`
##     不再触发 —— 按钮看起来"按得下去但没反应"。一次性探针实测：
##        A 正常点击            ⇒ pressed 触发
##        B 按下后 release_focus ⇒ pressed **不**触发
##        C 按下后 focus_mode=NONE ⇒ pressed **不**触发
##     而商店卡走的是 `gui_input`（不看 `press_attempt`）⇒ 只有卡片还能点，
##     于是现象变成「只能买船，刷新 / 加速 / 继续·下一节点 全都点不动」。
##
##  摘动作是**唯一不碰焦点**的解法：焦点照常留着（回车激活、Tab 导航都不受影响），
##  只是空格不再等于「按下这个按钮」。`_unhandled_input()` 的暂停分支也因为
##  GUI 不再吃掉空格而恢复正常。
##
## ⚠️ 为什么不直接改 `project.godot` 的 `[input]`：那是 **project.binary**，
##    引擎启动时就读完了，热更 pck 挂上去也改不动它 ⇒ 只能运行时摘。
##
## ⚠️ 幂等：`static var` 兜住重复调用（主菜单 / 战斗场景都会叫）。
## ⚠️ 只摘空格，**回车与手柄 A 保留** —— `eve_confirm_dialog` / `eve_update_panel`
##    会 `grab_focus()` 到一个按钮上让玩家直接敲回车，那是真实需求。


static var _applied := false


## 摘掉 `ui_accept` 里的所有空格事件。可以重复调用。
static func detach_space_from_accept() -> void:
	if _applied:
		return
	_applied = true
	if not InputMap.has_action("ui_accept"):
		return
	# 先收集再删：`action_get_events()` 返回的是副本，但边遍历边 erase 容易写错，
	# 两段式更保险（而且删完还能知道删了几条）。
	var doomed: Array = []
	for ev in InputMap.action_get_events("ui_accept"):
		if ev is not InputEventKey:
			continue
		var k: InputEventKey = ev
		# 默认动作表里空格是以 physical_keycode 存的；两种都判，防止版本差异。
		if k.keycode == KEY_SPACE or k.physical_keycode == KEY_SPACE:
			doomed.append(ev)
	for ev in doomed:
		InputMap.action_erase_event("ui_accept", ev)
	if not doomed.is_empty():
		print("[INPUT] ui_accept 摘掉空格 %d 条（回车 / 手柄 A 保留）"
				% doomed.size())
