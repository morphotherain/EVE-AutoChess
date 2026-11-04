extends Node
## 联机 · 传输层（**WebSocket 版**）—— 给网页版用。
##
## ══════════════════════════════════════════════════════════════════
##  为什么需要第二套传输层
## ══════════════════════════════════════════════════════════════════
##  桌面/安卓走的是 `eve_ddz_transport.gd`（ENet，UDP）。浏览器**没有 UDP socket**，
##  也没法建 TUN（EasyTier 那条路在网页上整条不存在）⇒ ENet 在 web 上不可能跑通。
##  唯一能用的出网方式是 WebSocket（TCP，天然穿透所有代理和防火墙）。
##
##  所以这里**照着 `eve_ddz_transport.gd` 的接口重写一份**，让 `ddz_room.gd`
##  一行网络逻辑都不用改：同样的信号、同样的 `send_to/broadcast` 语义、
##  同样「1 = 房主」的 peer id 约定。会话层（`ddz_net.gd` 的房主权威）完全不知道
##  底下是 UDP 还是 WS。
##
## ── 拓扑差别（这是唯一需要想清楚的地方）──────────────────────
##      ENet：房主真的在监听端口，加入者连房主。
##      WS  ：所有端（**含房主**）都是同一条连接的客户端，由中继服务器按房间码分组。
##            房主的「服务端身份」是中继替它扮演的：中继给房主分配 id=1，
##            并且把加入者注册/掉线翻译成 `PEER_JOINED` / `PEER_LEFT` 塞给房主。
##      ⇒ 房主视角与 ENet 完全一致（peer_id=1 是自己，收到 2/3/4 的包），
##        加入者视角也一致（永远只跟 id=1 说话）。
##
## ── 帧格式（8 字节头 + 负载，全部大端/单字节）─────────────────
##      [0] 类型  [1] target_id  [2] from_id  [3..] 负载
##      类型见下方 T_* 常量；服务端 `tools/relay/ws_relay_server.js` 必须同步改。
##
## ⚠️ 中继服务器**不解析游戏数据**：它只按 target 转发 + 改写 from_id，
##    和 UDP 中继（同目录 `eve_relay_server.js`）的定位一致。

## 房主在每条连接上的固定 id（与 ENet 约定一致，会话层依赖它）
const SERVER_ID := 1
const MAX_CLIENTS := 4
const CONNECT_TIMEOUT_MS := 15000
const MAX_WIRE_BYTES := 64 * 1024

## ── 帧类型 ──（服务端一一对应，改这里必须同步改 js）
const T_HELLO_HOST := 1   ## 客户端→服务端：我是房主，房间码在负载里
const T_HELLO_GUEST := 2  ## 客户端→服务端：我是加入者，房间码在负载里
const T_WELCOME := 3      ## 服务端→客户端：负载 1 字节 = 分配给我的 id
const T_PEER_JOINED := 4  ## 服务端→房主：负载 1 字节 = 新成员 id
const T_PEER_LEFT := 5    ## 服务端→房主：负载 1 字节 = 离开的 id
const T_DATA := 6         ## 双向：负载 = [target][from] + 游戏数据
const T_ERROR := 7        ## 服务端→客户端：负载 = UTF-8 错误文本

## 联机服务器地址。默认走域名（有正式证书）；可用 `set_relay_url()` 覆盖。
##
## ⚠️ 必须 `wss://`：页面本身是 https 时浏览器**禁止**发起明文 ws 连接
##   （混合内容拦截），且不会给任何可读的错误。
const DEFAULT_RELAY_URL := "wss://xshy.top/relay"

signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal connected_ok()
signal connect_failed()
signal packet(peer_id: int, d: Dictionary)

var relay_url := DEFAULT_RELAY_URL
## 8 位房间码（`set_room()` 写入，⛔ 要在 `host_start()/join()` 之前调）
var room := ""
var is_server := false
var my_id := SERVER_ID
var last_error := ""

var _ws: WebSocketPeer = null
var _hello_sent := false
var _welcomed := false
var _closed_emitted := false
var _connect_started_ms := 0
## 统计（验收 / 日志用）
var packets_up := 0
var packets_down := 0


static func to_wire(d: Dictionary) -> PackedByteArray:
	return var_to_bytes(d)


static func from_wire(b: PackedByteArray) -> Dictionary:
	if b.size() < 4 or b.size() > MAX_WIRE_BYTES:
		return {}
	var v = bytes_to_var(b)
	return v if v is Dictionary else {}


func _ready() -> void:
	set_process(true)


func _process(_d: float) -> void:
	poll()


## 设置房间码。⛔ 必须在 `host_start()/join()` 前调用，否则握手包里的房间码是空的，
## 服务端会直接回 `房间码不对`。
func set_room(p_room: String) -> void:
	room = p_room.strip_edges().to_upper()


func set_relay_url(url: String) -> void:
	relay_url = url.strip_edges()


## 解析实际要连的中继地址。
##
## ★ 网页版支持用页面参数临时覆盖：`?relay=ws://127.0.0.1:27101/relay`
##   [WHY] 没有这个开关，本地调试就只能改代码重导包；有了它，同一个包既能连
##   生产也能连本机（排查「到底是中继的问题还是客户端的问题」时非常省事）。
##   ⛔ 只在 `relay_url` 还是默认值时才看参数，`set_relay_url()` 显式设过就不覆盖
##   —— 调试开关不该盖掉代码里的明确意图。
func _resolve_url() -> String:
	if relay_url != DEFAULT_RELAY_URL:
		return relay_url
	if not OS.has_feature("web"):
		return relay_url
	var v := str(JavaScriptBridge.eval(
		"new URLSearchParams(location.search).get('relay')||''", true))
	if v == "" or v == "null":
		return relay_url
	return v


## 开房 = 「连上中继并登记为这个房间的房主」。
##
## ⚠️ 参数 `_port` 只是为了和 ENet 版接口一致，WS 没有端口概念。
## ⚠️ 返回 true 只代表**发起了连接**，真正可用要等 `connected_ok()`。
func host_start(_port: int = 0) -> bool:
	is_server = true
	my_id = SERVER_ID
	return _open()


## 加入 = 「连上中继并登记为这个房间的成员」。
## ⚠️ `_ip` / `_port` 同样只是接口兼容；中继地址由 `relay_url` 决定。
func join(_ip: String = "", _port: int = 0, now_ms: int = 0) -> bool:
	is_server = false
	_connect_started_ms = now_ms if now_ms > 0 else Time.get_ticks_msec()
	return _open()


func _open() -> bool:
	_hello_sent = false
	_welcomed = false
	_closed_emitted = false
	packets_up = 0
	packets_down = 0
	if room.length() != 8:
		last_error = "房间码必须是 8 位（当前：%s）" % room
		return false
	_ws = WebSocketPeer.new()
	# [NOTE] 不传 TLSOptions：浏览器内核自己处理证书，传了也会被忽略。
	var err := _ws.connect_to_url(_resolve_url())
	if err != OK:
		last_error = "无法连接联机服务器（%d）" % err
		_ws = null
		return false
	return true


func poll() -> void:
	if _ws == null:
		return
	_ws.poll()
	var st := _ws.get_ready_state()
	match st:
		WebSocketPeer.STATE_CONNECTING:
			return
		WebSocketPeer.STATE_OPEN:
			if not _hello_sent:
				_hello_sent = true
				_send_hello()
			while _ws.get_available_packet_count() > 0:
				_on_frame(_ws.get_packet())
		WebSocketPeer.STATE_CLOSING:
			return
		WebSocketPeer.STATE_CLOSED:
			_on_closed()


func _on_closed() -> void:
	if _closed_emitted:
		return
	_closed_emitted = true
	var code := _ws.get_close_code()
	var reason := _ws.get_close_reason()
	_ws = null
	set_process(false)
	if not _welcomed:
		# 还没握上手就断了 —— 对上层来说是「连不上」
		last_error = "连不上联机服务器（%s）" % (
			reason if reason != "" else "%d" % code)
		connect_failed.emit()
		return
	# 已经握过手 ⇒ 当对端离开处理。房主侧由中继逐条发 PEER_LEFT，
	# 这里只补一条「房主没了」给加入者（否则客户端会一直等快照）。
	if not is_server:
		peer_left.emit(SERVER_ID)


func check_timeout(now_ms: int) -> bool:
	if _ws == null or is_server or _welcomed:
		return false
	if now_ms - _connect_started_ms >= CONNECT_TIMEOUT_MS:
		last_error = "连接联机服务器超时"
		stop()
		connect_failed.emit()
		return true
	return false


func send_to(target_peer_id: int, d: Dictionary) -> void:
	if _ws == null or not _welcomed:
		return
	var body := to_wire(d)
	if body.size() > MAX_WIRE_BYTES:
		push_warning("[ws] 负载过大已丢弃：%d 字节" % body.size())
		return
	var out := PackedByteArray()
	out.resize(3 + body.size())
	out[0] = T_DATA
	out[1] = target_peer_id & 0xFF
	out[2] = my_id & 0xFF
	for i in body.size():
		out[3 + i] = body[i]
	_ws.send(out, WebSocketPeer.WRITE_MODE_BINARY)
	packets_up += 1


func broadcast(d: Dictionary) -> void:
	send_to(0, d)


func stop() -> void:
	if _ws != null:
		_ws.close(1000, "bye")
		_ws = null
	_closed_emitted = true
	set_process(false)


func is_active() -> bool:
	return _ws != null


## 是否已经握手完成（可以收发游戏包）。
func is_ready() -> bool:
	return _welcomed


# ────────────────────────────────────────────── 内部

func _send_hello() -> void:
	var rb := room.to_ascii_buffer()
	var out := PackedByteArray()
	out.resize(1 + 8)
	out[0] = T_HELLO_HOST if is_server else T_HELLO_GUEST
	for i in 8:
		out[1 + i] = rb[i] if i < rb.size() else 0x30
	_ws.send(out, WebSocketPeer.WRITE_MODE_BINARY)


func _on_frame(pkt: PackedByteArray) -> void:
	if pkt.is_empty():
		return
	var t := int(pkt[0])
	match t:
		T_WELCOME:
			if pkt.size() < 2:
				return
			my_id = int(pkt[1])
			_welcomed = true
			connected_ok.emit()
		T_PEER_JOINED:
			if pkt.size() < 2:
				return
			peer_joined.emit(int(pkt[1]))
		T_PEER_LEFT:
			if pkt.size() < 2:
				return
			peer_left.emit(int(pkt[1]))
		T_DATA:
			if pkt.size() < 3:
				return
			var from_id := int(pkt[2])
			var d := from_wire(pkt.slice(3))
			packets_down += 1
			if not d.is_empty():
				packet.emit(from_id, d)
		T_ERROR:
			last_error = pkt.slice(1).get_string_from_utf8()
			if last_error == "":
				last_error = "联机服务器拒绝了这个房间"
			# ⚠️ 这里**必须**先记 `_welcomed = true` 再 stop：
			#    否则 `_on_closed()` 会把它当成「连不上」，把真正的原因盖成
			#    「连不上联机服务器」—— 玩家看到的是完全没用的那句话。
			_welcomed = true
			stop()
			connect_failed.emit()
