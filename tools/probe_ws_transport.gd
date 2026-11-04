extends SceneTree
## WebSocket 传输层 headless 探针 —— 验证 GDScript 侧与中继服务真的能对上话。
##
## [WHY] 中继服务端的自检（`tools/relay/ws_relay_test.js`）只证明了「服务端逻辑对」，
##       但它用的是手写的 Node 客户端。真正要上线的是 Godot 的 `WebSocketPeer`，
##       两者在**分帧、掩码、close 语义**上都可能不同。这个探针用游戏自己的
##       传输层跑一遍「建房 → 加入 → 双向收发 → 断开」的全流程。
##
## 用法：先起中继，再跑探针
##   node tools/relay/ws_relay_server.js 27101
##   godot --headless --path . --script tools/probe_ws_transport.gd
##
## 可通过环境变量覆盖：EVEWS_URL、EVEWS_ROOM

const TP := preload("res://scripts/net/eve_ws_transport.gd")

var url := "ws://127.0.0.1:27101/relay"
var room := "PROBROM1"

var host = null
var guest = null
var t0 := 0
var step := 0
var ok_count := 0
var fail_count := 0
var done := false
var got_host := {}
var got_guest := {}


func _initialize() -> void:
	url = OS.get_environment("EVEWS_URL") if OS.get_environment("EVEWS_URL") != "" else url
	room = OS.get_environment("EVEWS_ROOM") if OS.get_environment("EVEWS_ROOM") != "" else room
	t0 = Time.get_ticks_msec()

	host = TP.new()
	host.name = "Host"
	root.add_child(host)
	host.set_relay_url(url)
	host.set_room(room)
	host.connected_ok.connect(func(): _mark("host connected_ok"))
	host.connect_failed.connect(func():
		_fail("host connect_failed: " + str(host.last_error)))
	host.packet.connect(func(from: int, d: Dictionary):
		got_host = {"from": from, "d": d}
		print("  [host] 收到包 from=%d %s" % [from, d]))

	guest = TP.new()
	guest.name = "Guest"
	root.add_child(guest)
	guest.set_relay_url(url)
	guest.set_room(room)
	guest.connected_ok.connect(func():
		_mark("guest connected_ok id=%d" % guest.my_id))
	guest.connect_failed.connect(func():
		_fail("guest connect_failed: " + str(guest.last_error)))
	guest.packet.connect(func(from: int, d: Dictionary):
		got_guest = {"from": from, "d": d}
		print("  [guest] 收到包 from=%d %s" % [from, d]))
	guest.peer_left.connect(func(pid: int):
		print("  [guest] peer_left %d" % pid))

	print("== 探针开始 url=%s room=%s ==" % [url, room])
	if host.host_start(0):
		ok_count += 1
		print("  host.host_start -> ok")
	else:
		_fail("host.host_start 失败：" + host.last_error)


func _mark(msg: String) -> void:
	ok_count += 1
	print("PASS  " + msg)


func _fail(msg: String) -> void:
	fail_count += 1
	print("FAIL  " + msg)


func _process(_delta: float) -> bool:
	if done:
		return true
	var elapsed := Time.get_ticks_msec() - t0
	host.poll()
	guest.poll()

	match step:
		0:
			# 房主连上之后再加客人（顺序很重要：中继要求房间先有 host）
			if host.is_ready():
				guest.set_room(room)
				guest.join("", 0, Time.get_ticks_msec())
				step = 1
				print("  guest.join -> %s" % ("ok" if guest.is_active() else "失败：" + guest.last_error))
		1:
			# 客人的 WELCOME 到了 ⇒ 发一个包给房主
			if guest.is_ready():
				guest.send_to(1, {"t": 1, "hello": "from-guest"})
				step = 2
		2:
			if not got_host.is_empty():
				if int(got_host["from"]) == guest.my_id:
					_mark("房主收到客人包，from=%d 与客人 id 一致" % guest.my_id)
				else:
					_fail("房主收到的 from=%d，应为客人 id=%d" % [int(got_host["from"]), guest.my_id])
				host.send_to(guest.my_id, {"t": 2, "reply": "from-host"})
				step = 3
		3:
			if not got_guest.is_empty():
				if int(got_guest["from"]) == 1:
					_mark("客人收到房主回包，from=1")
				else:
					_fail("客人收到的 from=%d，应为 1" % int(got_guest["from"]))
				step = 4
				guest.stop()
		4:
			# 客人断开后，房主应当在几秒内收到 peer_left
			if elapsed > 2500:
				done = true

	if elapsed > 15000 and not done:
		_fail("总超时（step=%d，host_ready=%s guest_ready=%s）"
				% [step, host.is_ready(), guest.is_ready()])
		done = true

	if done:
		print("== 结果：PASS %d / FAIL %d ==" % [ok_count, fail_count])
		host.stop()
		return true
	return false
