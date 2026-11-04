extends Node
## 联机 · 房间协调器 —— **UI 只跟这个类打交道**。
##
## 它把四样东西串起来：
##   `ddz_net`（会话层：房主权威 + 裁剪快照）
##   `eve_ddz_transport`（传输层：ENet）
##   `eve_tunnel`（连通层：内置 EasyTier 内核）
##   `eve_room_code`（房间码 → 网络名/密钥/网段/端口）
##
## 配套设计：`F:\EVE自走棋\牌面\牌面\联机方案-内置EasyTier-工程设计-2026-10-12.md`
##
## ★ 三条产品规则（都来自实测/用户决定）：
##   ① **全员连同一个地址** `127.0.0.1:27015`：房主是本地直连，加入者由内核转发。
##      ⇒ 游戏侧没有「联机逻辑」和「单机逻辑」两套。
##   ② **房主确认加入**：8 位房间码 + 房主点「允许」（`needs_approval`）。默认开。
##   ③ **降级**：内核起不来 / 玩家拒绝权限 ⇒ `skip_tunnel = true` 走局域网直连，
##      或者用 `peer_ip` 指定一个已知 IP。⛔ 任何情况下都**不能静默失败**。

signal state_changed()
signal join_requested(peer_id: int, player_name: String)
signal failed(reason: String)
signal log_line(text: String)
## 某座位的头像更新（远程或本地）。`tex` 为 `null` 表示「该座位暂无头像」。
## ★ 牌桌接它去调 `set_avatar()`；这是头像数据唯一的对外出口，⛔ 别绕过它直接读字节。
signal avatar_updated(seat: int, tex: Texture2D)

const N := preload("res://scripts/net/ddz_net.gd")
const RC := preload("res://scripts/net/eve_room_code.gd")
const RELAY := preload("res://scripts/net/eve_relay_list.gd")
const TUN := preload("res://scripts/net/eve_tunnel.gd")
const TP := preload("res://scripts/net/eve_ddz_transport.gd")
## ★ 2026-11-04：网页版走 WebSocket（浏览器没有 UDP socket，ENet 那条路不存在）。
##   两套传输层**接口一致**，本类只负责选一个 —— 会话层与 UI 完全不用知道差别。
const TP_WS := preload("res://scripts/net/eve_ws_transport.gd")
## 房主在传输层的固定 id（两套传输层都用 1 = 房主）。⛔ 别再写 `TP.SERVER_ID`：
## 一旦改走 WS 传输层，那个常量属于另一个脚本，指过去就解析不到了。
const SERVER_PEER := 1

enum State { IDLE, TUNNEL, LISTENING, CONNECTING, PLAYING, FAILED }
enum Msg { HELLO, ACCEPT, REJECT, SNAP, CMD, PING, AVATAR }

## 房主是否要手动确认每个加入者（2026-10-12 用户定：要）
var needs_approval := true
## 跳过内核，直接用 ENet 连（局域网模式 / 无头验收）
## ★ 网页版恒为 true：浏览器既没有 TUN 也没有 UDP，内核那条路整条不存在。
var skip_tunnel := false
## 强行走 WebSocket 传输层（只在本地做 WS 中继验收时置 true；正常运行按平台判断）
var force_ws := false
## 目标 IP。默认 127.0.0.1（内核转发口）；局域网降级时可填房主的局域网 IP
var peer_ip := "127.0.0.1"
## 玩家自定义会合节点（设置面板里填；空 = 只用内置）
var custom_relays: Array = []

var code := ""
var is_host := false
var display_name := ""
## 本机玩家上传的头像字节（进房时随 HELLO 发出；= 空表示没传）。
var my_avatar: PackedByteArray = PackedByteArray()
## 座位 → 头像字节。★ 头像属于「公开信息」，放在协调器层（与 peer↔seat 同源），
##   不进 `ddz_net` 的快照，也不碰手牌隔离红线。
var _avatars: Dictionary = {}
var state := State.IDLE
var last_error := ""

var net = null
var _tp: Node = null
var _tun = null
## 房主侧：peer_id → {"name":String, "seat":int}
## ⚠️ 座位↔连接的唯一真相在会话层（`net.seats[i]["peer"]` / `net.seat_of_peer(peer)`）——
##   本类**不再自己维护第二份映射**（两份迟早会漂移，而漂移的后果是「发给错的人」）。
var _pending := {}          ## peer_id → 名字（等房主确认）
var _pending_avatar := {}    ## peer_id → 头像字节（等房主确认，与 _pending 同步清空）
var _last_snap := {}        ## seat → 上次下发的负载（避免无变化时反复发）
## ★ 本帧的房主本地时钟（由 `tick()` 写入）。★ 2026-10-12 审查 N05：
##   客户端心跳里带的是**它自己进程**的 `Time.get_ticks_msec()`，两个进程的启动时刻不同、
##   这个数**不能直接相减**（实测能差出十分钟，托管要么永不触发、要么过早触发）。
##   ⇒ 收到心跳一律记「房主此刻的时间」，客户端的值只当诊断数据。
var _now_ms := 0
var _last_ping_ms := -99999 ## ⚠️ 心跳限流：⛔ 别每帧发（60 包/秒纯属浪费）
const PING_INTERVAL_MS := 1000


func _ready() -> void:
	set_process(true)


func _process(_d: float) -> void:
	tick(Time.get_ticks_msec())


## 每帧推进（也由无头验收手动调；本类不读时钟，now_ms 外部传入）。
func tick(now_ms: int) -> void:
	_now_ms = now_ms
	if _tun != null and state == State.TUNNEL:
		if _tun.poll(now_ms) == TUN.State.FAILED:
			_fail(_tun.last_error)
			return
		if _tun.is_up():
			if is_host:
				_start_net_host()
			else:
				_start_net_client(now_ms)
	if _tp != null:
		if not is_host:
			_tp.check_timeout(now_ms)
		if is_host and state == State.PLAYING and net != null:
			var r: Dictionary = net.tick(now_ms)
			if not (r["takeover"] as Array).is_empty() or not (r["auto"] as Array).is_empty():
				for line in r["events"]:
					log_line.emit(String(line))
				_push_all()
		if not is_host and state == State.PLAYING \
				and now_ms - _last_ping_ms >= PING_INTERVAL_MS:
			_last_ping_ms = now_ms
			_send_ping(now_ms)


# ══════════════════════════════════════════════════════════ 房主

## 开房：生成房间码 → 起内核（TUN）→ 起 ENet 服务器 → 等玩家。
## `avatar` 为本机玩家头像字节（可为空）。
func create_room(name: String, now_ms: int, seed_for_code: int = 0,
		avatar: PackedByteArray = PackedByteArray()) -> bool:
	_force_web_mode()
	is_host = true
	display_name = name
	my_avatar = avatar
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_for_code if seed_for_code != 0 else int(Time.get_unix_time_from_system() * 1000.0)
	# ★ 房间码是那条虚拟网络的密码 ⇒ 用密码学安全随机数（传 null 走 Crypto）。
	#   仅在验收需要复现时才传固定种子的 rng。
	code = RC.generate(rng if seed_for_code != 0 else null)
	_pending = {}
	_pending_avatar = {}
	_avatars = {}
	_last_snap = {}
	net = N.new()
	net.host_setup([name, "座位1", "座位2"])
	net.my_seat = 0
	if not my_avatar.is_empty():
		_avatars[0] = my_avatar
	_start_transport()
	if skip_tunnel:
		_start_net_host()
		return true
	_tun = TUN.new()
	state = State.TUNNEL
	state_changed.emit()
	log_line.emit("正在启动联机内核…")
	if not _tun.start(code, 0, true, RELAY.peers_with(custom_relays), name, now_ms):
		_fail(_tun.last_error)
		return false
	return true


## 房主确认某个玩家的加入请求。
func approve(peer_id: int) -> void:
	if not _pending.has(peer_id):
		return
	var nm := String(_pending[peer_id])
	_pending.erase(peer_id)
	_assign(peer_id, nm)


## 房主拒绝。
func decline(peer_id: int) -> void:
	if not _pending.has(peer_id):
		return
	_pending.erase(peer_id)
	_tp.send_to(peer_id, {"t": Msg.REJECT, "reason": "房主没有放行"})
	log_line.emit("已拒绝 %d 的加入请求" % peer_id)


## 开局（房主调）。★ seed 只在房主侧，不下发。
func start_game(seed_value: int) -> bool:
	if not is_host or net == null:
		return false
	# 人没到齐也能开（空座位由托管接手），但要给房主一句实话
	var humans := _bound_seats()
	if humans < N.SEATS:
		log_line.emit("还有 %d 个座位空着，将由电脑托管" % (N.SEATS - humans))
	var r: Dictionary = net.host_start(seed_value, Time.get_ticks_msec())
	if not bool(r["ok"]):
		return false
	state = State.PLAYING
	_push_all()
	state_changed.emit()
	return true


## 出命令 —— **房主和加入者共用这一个入口**（UI 不用分情况）。
##   房主本地（座位 0）：直接裁决并广播；
##   加入者：打包发给房主，等房主回快照（⛔ 客户端本地不产生任何权威状态）。
## 返回房主的裁决结果（加入者拿不到，返回空字典 —— 它只能等快照）。
func send_command(kind: int, payload: Dictionary = {}) -> Dictionary:
	if is_host:
		var cmd := {"seat": 0, "kind": kind}
		cmd.merge(payload, true)
		return _host_apply(cmd)
	if net == null or state != State.PLAYING:
		return {}
	var c: Dictionary = net.client_make_command(kind, payload)
	_tp.send_to(SERVER_PEER, {"t": Msg.CMD, "d": c})
	return {}


func _start_net_host() -> void:
	if not _tp.host_start(RC.DEFAULT_PORT):
		_fail(_tp.last_error)
		return
	state = State.LISTENING
	log_line.emit("房间已创建，等待玩家加入")
	state_changed.emit()


func _assign(peer_id: int, nm: String) -> void:
	var seat := _free_seat()
	if seat < 0:
		_tp.send_to(peer_id, {"t": Msg.REJECT, "reason": "房间满了"})
		return
	net.seats[seat]["name"] = nm
	net.seats[seat]["online"] = true
	# ★ 把连接绑到座位：此后该连接发来的命令，座位号由会话层按 peer 查得，
	#   ⛔ 命令里自称的 seat 一律被忽略（防冒充他人）。
	if not net.bind_peer(seat, peer_id, Time.get_ticks_msec()):
		_tp.send_to(peer_id, {"t": Msg.REJECT, "reason": "座位已被占用"})
		return
	net.reclaim(seat, Time.get_ticks_msec())
	# 该玩家的头像（来自 HELLO）：存进协调器层，并把「这张脸」推给已经坐着的别人。
	var av: PackedByteArray = _pending_avatar.get(peer_id, PackedByteArray())
	_pending_avatar.erase(peer_id)
	_store_avatar(seat, av, peer_id)
	_tp.send_to(peer_id, {"t": Msg.ACCEPT, "seat": seat,
			"needs_approval": needs_approval})
	# ★ 2026-10-12 联网专项审查 N06：**新连接必须收到完整首份快照**，不能被去重缓存吃掉。
	#   `_last_snap` 按**座位**记签名；重连到同一座位、而局面恰好没变时签名相同 ⇒
	#   下面 `_push_seat()` 直接 return ⇒ 新客户端只拿到 ACCEPT、**没有手牌**
	#   （若正轮到它，就既不能出牌也没有牌可看，且后续局面不变时永远好不了）。
	#   ⇒ 绑定的那一刻清掉该座位的缓存签名。
	_last_snap.erase(seat)
	_push_seat(seat)
	log_line.emit("%s 加入了（座位 %d）" % [nm, seat])
	state_changed.emit()


## 存某个座位的头像，并做两件事：
##   ① 给本机牌桌发 `avatar_updated`（房主自己能看到新人的脸）；
##   ② 把这张脸发给「其他已在场的玩家」；
##   ③ 把**全场已有的脸**发给刚入座的这位（中途加入也能看到前面人的头像）。
## `new_peer` 是新人的连接 id；传 -1 表示「仅本地存储、不向网络发」（例如房主自己的头像）。
func _store_avatar(seat: int, bytes: PackedByteArray, new_peer: int = -1) -> void:
	if bytes.is_empty():
		return
	_avatars[seat] = bytes
	avatar_updated.emit(seat, bytes_to_texture(bytes))
	if _tp == null:
		return
	# 新人的脸 → 其他已在场（且不是新人自己）的玩家
	for s in range(1, N.SEATS):
		var p := int(net.seats[s]["peer"])
		if p != N.NO_PEER and p != new_peer:
			_tp.send_to(p, {"t": Msg.AVATAR, "seat": seat, "data": bytes})
	# 全场已有的脸 → 新人（含房主自己的，含新人自己的）
	if new_peer != N.NO_PEER:
		for s in _avatars.keys():
			_tp.send_to(new_peer, {"t": Msg.AVATAR, "seat": int(s),
					"data": _avatars[int(s)]})


## 空座位：1..2（0 是房主自己）
func _free_seat() -> int:
	for s in range(1, N.SEATS):
		if int(net.seats[s]["peer"]) == N.NO_PEER:
			return s
	return -1


func _host_apply(cmd: Dictionary) -> Dictionary:
	var res: Dictionary = net.apply_command(cmd)
	if bool(res["ok"]):
		_push_all()
		state_changed.emit()
	return res


## 网络来的命令：**座位由连接决定**（会话层按 peer 查得，命令里自称的 seat 被忽略），
## 本类只负责「转发 + 成功后广播」。
func _host_apply_remote(peer: int, cmd) -> Dictionary:
	if net == null:
		return {"ok": false, "reason": "尚未开局", "result": {}}
	var res: Dictionary = net.apply_remote(peer, cmd)
	if bool(res.get("ok", false)):
		_push_all()
		state_changed.emit()
	return res


## 已入座的玩家数（含房主自己）。
func _bound_seats() -> int:
	var n := 1                      ## 座位 0 恒为房主
	for s in range(1, N.SEATS):
		if int(net.seats[s]["peer"]) != N.NO_PEER:
			n += 1
	return n


## 把「按座位裁剪」的快照发给对应的玩家。**变化了才发**（省流量、也少一次出错机会）。
func _push_all() -> void:
	for s in range(1, N.SEATS):
		_push_seat(s)


func _push_seat(seat: int) -> void:
	if _tp == null or seat < 0 or seat >= N.SEATS:
		return
	var holder := int(net.seats[seat]["peer"])
	if holder == N.NO_PEER:
		return
	var snap: Dictionary = net.snapshot_for(seat)
	if snap.is_empty():
		return
	var sig := str(snap["turn"]) + "|" + str(snap["phase"]) + "|" + str(snap["landlord"]) \
			+ "|" + str(snap["base_score"]) + "|" + str(snap["pass_streak"]) \
			+ "|" + str(snap["counts"]) + "|" + str(snap["played"]) \
			+ "|" + str(snap["bottom"]) + "|" + str(snap["winner"]) \
			+ "|" + str(snap["passed"]) + "|" + str(snap["seats"]) \
			+ "|" + str(snap["your_hand"])
	# ⚠️ 签名必须覆盖**全部会变的局面字段**。早先只算了 turn/phase/counts ⇒
	#    「三家叫完分定地主、而 turn 恰好还是同一个人」时签名不变 ⇒ **该发的没发**，
	#    客户端永远停在叫分界面。这类漏发极难查，所以宁可多算几个字段。
	if String(_last_snap.get(seat, "")) == sig:
		return
	_last_snap[seat] = sig
	_tp.send_to(holder, {"t": Msg.SNAP, "d": snap})


# ══════════════════════════════════════════════════════════ 加入者

## 加入房间。`avatar` 为本机玩家头像字节（可为空）。
func join_room(room_code: String, name: String, now_ms: int,
		avatar: PackedByteArray = PackedByteArray()) -> bool:
	_force_web_mode()
	is_host = false
	display_name = name
	my_avatar = avatar
	code = RC.normalize(room_code)
	if not RC.is_valid(code):
		_fail("房间码不对（应是 8 位）")
		return false
	net = N.new()
	_start_transport()
	if skip_tunnel:
		_start_net_client(now_ms)
		return true
	_tun = TUN.new()
	state = State.TUNNEL
	state_changed.emit()
	log_line.emit("正在启动联机内核…")
	# ★ 加入者的隧道「座位」只用来派生端口/实例名（虚拟 IP 由 DHCP 自动取，见 eve_tunnel）。
	#   随机取一个 slot ⇒ 同一台机器上跑多个加入者也不会撞端口。
	var slot := RandomNumberGenerator.new()
	slot.seed = int(Time.get_unix_time_from_system() * 1000.0) ^ int(name.hash())
	if not _tun.start(code, slot.randi_range(1, 63), false,
			RELAY.peers_with(custom_relays), name, now_ms):
		_fail(_tun.last_error)
		return false
	return true


func _start_net_client(now_ms: int) -> void:
	if not _tp.join(peer_ip, RC.DEFAULT_PORT, now_ms):
		_fail(_tp.last_error)
		return
	state = State.CONNECTING
	log_line.emit("正在连接房主…")
	state_changed.emit()


func _send_hello() -> void:
	_tp.send_to(SERVER_PEER, {"t": Msg.HELLO, "name": display_name,
			"ver": TUN.VERSION, "avatar": my_avatar})


func _send_ping(now_ms: int) -> void:
	_tp.send_to(SERVER_PEER, {"t": Msg.PING, "now_ms": now_ms})


# ══════════════════════════════════════════════════════════ 传输接线

func _start_transport() -> void:
	var tp_script = TP_WS if _use_ws() else TP
	_tp = tp_script.new()
	_tp.name = "DdzTransport"
	add_child(_tp)
	# ⚠️ 只有 WS 版需要房间码（ENet 靠隧道内部的网络名隔离）。
	#    用 `has_method` 判断而不是按平台分支：同一份调用在两种传输层下都成立。
	if _tp.has_method("set_room"):
		_tp.set_room(code)
	_tp.peer_joined.connect(_on_peer_joined)
	_tp.peer_left.connect(_on_peer_left)
	_tp.connected_ok.connect(_on_connected)
	_tp.connect_failed.connect(func(): _fail(_tp.last_error))
	_tp.packet.connect(_on_packet)


## 是否走 WebSocket 传输层。
##
## [WHY] 网页版**必须**：浏览器没有 UDP socket，也没有 TUN 可建。
##   非网页版一律仍用 ENet（延迟更低，且已有的 UDP 中继/隧道全都依赖它）。
func _use_ws() -> bool:
	return OS.has_feature("web") or force_ws


## 网页版恒跳过内核：浏览器既没有 TUN（VpnService/网卡都没有）也没有 UDP socket。
## ⚠️ 放在 `create_room()/join_room()` 开头而不是 `_init()`：验收脚本会在
##    运行中途改 `skip_tunnel` 去测「内核起不来」的降级路径，构造期写死会把那条路堵死。
func _force_web_mode() -> void:
	if OS.has_feature("web"):
		skip_tunnel = true


func _on_peer_joined(peer_id: int) -> void:
	if is_host:
		log_line.emit("有玩家接入（等待身份）…")
	else:
		pass


func _on_peer_left(peer_id: int) -> void:
	if not is_host:
		# 房主没了 ⇒ 牌局结束（不静默：给玩家一句话）
		if state == State.PLAYING:
			_fail("房主已离开，牌局结束")
		return
	# ⚠️ 显式标注：`net` 是动态类型，`:=` 推不出返回类型（实测 Parse Error）
	var seat: int = net.seat_of_peer(peer_id)
	if seat < 0:
		# 可能还在等确认阶段就断了
		_pending.erase(peer_id)
		return
	net.unbind_peer(peer_id)
	net.mark_offline(seat)
	log_line.emit("座位 %d 掉线，稍后由电脑托管" % seat)
	for line in net.events.slice(maxi(0, net.events.size() - 1)):
		log_line.emit(String(line))
	state_changed.emit()


func _on_connected() -> void:
	if not is_host:
		_send_hello()
		log_line.emit("已连上房主，等待放行…")


func _on_packet(from_peer: int, d: Dictionary) -> void:
	var t := int(d.get("t", -1))
	if is_host:
		_host_handle(from_peer, t, d)
	else:
		_client_handle(t, d)


func _host_handle(from_peer: int, t: int, d: Dictionary) -> void:
	match t:
		Msg.HELLO:
			var nm := String(d.get("name", "玩家"))
			var av: PackedByteArray = d.get("avatar", PackedByteArray())
			if String(d.get("ver", TUN.VERSION)) != TUN.VERSION:
				_tp.send_to(from_peer, {"t": Msg.REJECT, "reason": "游戏版本不一致"})
				return
			if _free_seat() < 0:
				_tp.send_to(from_peer, {"t": Msg.REJECT, "reason": "房间满了"})
				return
			if needs_approval:
				_pending[from_peer] = nm
				_pending_avatar[from_peer] = av
				join_requested.emit(from_peer, nm)
				log_line.emit("%s 请求加入，等待房主确认" % nm)
			else:
				_assign(from_peer, nm)
		Msg.CMD:
			# ★★ 走 `apply_remote()`：座位由连接查得，命令里自称的 seat 被忽略。
			#   本类**不再**自己覆盖 seat —— 那道防线现在在会话层里，离数据更近。
			var res := _host_apply_remote(from_peer, d.get("d", {}))
			if not bool(res["ok"]):
				# 被拒也要回一句，免得客户端按钮灰错后一脸茫然
				_tp.send_to(from_peer, {"t": Msg.REJECT, "reason": String(res["reason"])})
		Msg.PING:
			# ★ 用**房主本地时钟**记账（审查 N05）：客户端的 now_ms 来自另一个进程，
			#   与我们的 Time.get_ticks_msec() 不可比。
			net.touch(net.seat_of_peer(from_peer), _now_ms)


func _client_handle(t: int, d: Dictionary) -> void:
	match t:
		Msg.ACCEPT:
			var seat := int(d.get("seat", -1))
			if seat < 0:
				return
			net.client_setup(seat, display_name)
			if not my_avatar.is_empty():
				_avatars[seat] = my_avatar
				avatar_updated.emit(seat, bytes_to_texture(my_avatar))
			state = State.PLAYING
			log_line.emit("已加入房间（座位 %d）" % seat)
			state_changed.emit()
		Msg.REJECT:
			if state == State.PLAYING:
				log_line.emit("操作被拒：%s" % String(d.get("reason", "")))
			else:
				_fail(String(d.get("reason", "无法加入房间")))
		Msg.SNAP:
			net.client_apply_snapshot(d.get("d", {}))
			state_changed.emit()
		Msg.AVATAR:
			var seat := int(d.get("seat", -1))
			var data: PackedByteArray = d.get("data", PackedByteArray())
			if seat < 0 or data.is_empty():
				return
			_avatars[seat] = data
			avatar_updated.emit(seat, bytes_to_texture(data))


# ══════════════════════════════════════════════════════════ 收尾

func _fail(reason: String) -> void:
	if state == State.FAILED:
		return
	last_error = reason
	state = State.FAILED
	log_line.emit(reason)
	close()
	state_changed.emit()
	failed.emit(reason)


## 退出房间 / 关房：⛔ 一定要把内核停掉，绝不留残余进程。
func close() -> void:
	if _tp != null:
		_tp.stop()
		_tp.queue_free()
		_tp = null
	if _tun != null:
		_tun.stop()
		_tun = null
	if state != State.FAILED:
		state = State.IDLE
		state_changed.emit()


## ★★ 生命周期兜底（2026-10-12 联网专项审查 N03）。
##
## 牌桌的「返回菜单」是直接 `change_scene_to_file()` —— 它**不会**走面板的关房入口；
## 而 `OS.create_process()` 起的进程**不会随 Godot 一起结束**（官方 API 明确如此）。
## 实测：把房间 `queue_free()` 之后，EasyTier 进程仍然活着（它的 RPC 端口还能连），
## 占着 UDP 27015 ⇒ 下一次加入要么端口冲突、要么连到**旧房间的转发器**上。
##
## ⇒ 只要本节点被释放（场景切换 / 退出游戏 / 上层被 free）就一定停内核。
##   `close()` 是幂等的，重复调用安全。
func _exit_tree() -> void:
	close()


## 当前玩家该看的视图（房主看自己的裁剪快照，加入者看下发的）。
func view() -> Dictionary:
	if net == null:
		return {}
	return net.host_self_snapshot() if is_host else net.view


func my_seat() -> int:
	if net == null:
		return -1
	return int(net.my_seat)


## 某座位的头像字节（公开信息）。空 = 该座位暂无头像。
func avatar_bytes(seat: int) -> PackedByteArray:
	return _avatars.get(seat, PackedByteArray())


## 当前已知的所有头像（座位 → 字节）。牌桌开局接管时用来一次性补齐。
func known_avatars() -> Dictionary:
	return _avatars.duplicate()


## 把 PNG/WebP 字节解成贴图。解码失败返回 `null`（上游照常画几何占位剪影）。
func decode_avatar(b: PackedByteArray) -> Texture2D:
	return bytes_to_texture(b)


## 字节 → 贴图（房主/客户端/UI 共用同一份解码逻辑）。
## ⚠️ 只认 PNG 与 WebP：进房前 UI 已统一压成 PNG，这里不兜底其它格式。
static func bytes_to_texture(b: PackedByteArray) -> Texture2D:
	if b.is_empty():
		return null
	var img := Image.new()
	var err := img.load_png_from_buffer(b)
	if err != OK:
		err = img.load_webp_from_buffer(b)
	if err != OK:
		return null
	return ImageTexture.create_from_image(img)
