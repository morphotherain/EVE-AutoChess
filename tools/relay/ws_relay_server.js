// EVE 自走棋 · **WebSocket 中继**（给网页版用，零依赖）
//
// 为什么需要它：浏览器没有 UDP socket，ENet 那条路在网页上整条不存在。
// 网页版的房主和加入者都是「同一条 WS 连接的客户端」，由本服务按 8 位房间码分组，
// 再把包按 target 转发 —— 房主的「服务端身份」由本服务替它扮演（id=1）。
//
// 用法：node ws_relay_server.js [port]        （默认 27101，**只监听 127.0.0.1**）
//       由 Caddy 反代 wss://xshy.top/relay → 127.0.0.1:27101
//       ⛔ 不要改成 0.0.0.0：对外只该有 443 一个入口，否则又要多开一个防火墙洞。
//
// ── 帧格式（与 scripts/net/eve_ws_transport.gd 一一对应，改一边必须改另一边）
//      [0] 类型  [1] target  [2] from  [3..] 负载
//        1 HELLO_HOST   客户端→服务  负载 = 8 字节房间码
//        2 HELLO_GUEST  客户端→服务  负载 = 8 字节房间码
//        3 WELCOME      服务→客户端  负载 = 1 字节「分配给你的 id」
//        4 PEER_JOINED  服务→房主    负载 = 1 字节「新成员 id」
//        5 PEER_LEFT    服务→房主    负载 = 1 字节「离开的 id」
//        6 DATA         双向         负载 = [target][from] + 游戏数据（不解析）
//        7 ERROR        服务→客户端  负载 = UTF-8 错误文本
//
// ⚠️ 本服务**不解析游戏数据**：只按 target 转发 + 改写 from。
//    和同目录的 UDP 中继（eve_relay_server.js）定位完全一致。
//
// ⚠️ 手写 WebSocket 只为实现零依赖（npm 装包在这台机器上要连外网、还得多维护一份
//    node_modules）。代价是只支持**不带扩展、不分片、单帧**的文本以外的二进制消息
//    —— 正好是 Godot WebSocketPeer 发的形态。收到分片帧（FIN=0）直接断开，
//    ⛔ 不要「尽力拼一下」：拼错了会变成半包投递，比断开更难查。

const http = require('http');
const crypto = require('crypto');

const PORT = parseInt(process.argv[2] || process.env.PORT || '27101', 10);
const HOST = process.env.HOST || '127.0.0.1';
const ROOM_TTL_MS = 30 * 60 * 1000;   // 房间闲置 30 分钟回收
const MAX_GUESTS = 4;                 // 斗地主 3 人，留一个余量
const MAX_CONNS = 200;                // 粗暴的连接上限，防止被打爆内存

const T_HELLO_HOST = 1;
const T_HELLO_GUEST = 2;
const T_WELCOME = 3;
const T_PEER_JOINED = 4;
const T_PEER_LEFT = 5;
const T_DATA = 6;
const T_ERROR = 7;

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/** 房间码 → { host, guests: Map<id, conn>, nextId, last } */
const rooms = new Map();
let connSeq = 0;
let stat = { conns: 0, rooms_open: 0, relayed: 0, rejected: 0 };

// ────────────────────────────────────────────── WebSocket 底层

function wsAccept(key) {
  return crypto.createHash('sha1').update(key + WS_GUID).digest('base64');
}

/** 发一帧（服务端→客户端：不加掩码）。opcode 1=text 2=binary 8=close 9=ping 10=pong */
function wsSend(conn, opcode, payload) {
  const sock = conn.sock;
  if (!sock || sock.destroyed || !conn.open) return;
  const len = payload ? payload.length : 0;
  let head;
  if (len < 126) {
    head = Buffer.alloc(2);
    head[0] = 0x80 | opcode;
    head[1] = len;
  } else if (len < 65536) {
    head = Buffer.alloc(4);
    head[0] = 0x80 | opcode;
    head[1] = 126;
    head.writeUInt16BE(len, 2);
  } else {
    head = Buffer.alloc(10);
    head[0] = 0x80 | opcode;
    head[1] = 127;
    head.writeBigUInt64BE(BigInt(len), 2);
  }
  try {
    sock.write(len ? Buffer.concat([head, payload]) : head);
  } catch (e) {
    destroyConn(conn, 'write failed');
  }
}

function sendFrame(conn, bytes) {
  wsSend(conn, 0x2, Buffer.from(bytes));
}

function sendError(conn, text) {
  const body = Buffer.from(text, 'utf8');
  const out = Buffer.alloc(1 + body.length);
  out[0] = T_ERROR;
  body.copy(out, 1);
  sendFrame(conn, out);
  stat.rejected++;
}

function destroyConn(conn, why) {
  if (!conn || conn.closed) return;
  conn.closed = true;
  conn.open = false;
  try { conn.sock.destroy(); } catch (e) { /* 已经没了 */ }
  leaves(conn, why);
}

// ────────────────────────────────────────────── 房间逻辑

function roomOf(code) {
  let r = rooms.get(code);
  if (!r) {
    r = { host: null, guests: new Map(), nextId: 2, last: Date.now() };
    rooms.set(code, r);
  }
  return r;
}

function normCode(buf) {
  return buf.toString('ascii').replace(/\0/g, '').trim().toUpperCase();
}

function leaves(conn, why) {
  const code = conn.room;
  if (!code) return;
  const r = rooms.get(code);
  if (!r) return;
  r.last = Date.now();
  if (conn.role === 'host' && r.host === conn) {
    r.host = null;
    // 房主走了 ⇒ 通知所有加入者「1 号没了」，然后清房间
    for (const g of r.guests.values()) {
      const out = Buffer.from([T_PEER_LEFT, 1]);
      sendFrame(g, out);
      destroyConn(g, 'host gone');
    }
    r.guests.clear();
    rooms.delete(code);
    console.log(`[ws] room ${code} closed (host left: ${why})`);
    return;
  }
  if (conn.role === 'guest' && r.guests.get(conn.id) === conn) {
    r.guests.delete(conn.id);
    if (r.host && r.host.open) {
      sendFrame(r.host, Buffer.from([T_PEER_LEFT, conn.id]));
    }
    console.log(`[ws] room ${code} guest ${conn.id} left (${why})`);
  }
}

function onMessage(conn, buf) {
  if (buf.length < 1) return;
  const type = buf[0];
  if (type === T_HELLO_HOST || type === T_HELLO_GUEST) {
    if (conn.room) {
      sendError(conn, '重复握手');
      return;
    }
    if (buf.length < 9) {
      sendError(conn, '握手包长度不对');
      return;
    }
    const code = normCode(buf.slice(1, 9));
    if (code.length !== 8) {
      sendError(conn, '房间码必须是 8 位');
      return;
    }
    const r = roomOf(code);
    if (type === T_HELLO_HOST) {
      if (r.host && r.host.open) {
        sendError(conn, '这个房间已经有房主了');
        return;
      }
      r.host = conn;
      r.host.closed = false;
      r.last = Date.now();
      conn.room = code;
      conn.role = 'host';
      conn.id = 1;
      sendFrame(conn, Buffer.from([T_WELCOME, 1]));
      console.log(`[ws] room ${code} host in (conn ${conn.seq})`);
      return;
    }
    // guest
    if (!r.host || !r.host.open) {
      sendError(conn, '房间不存在或房主已离线');
      return;
    }
    if (r.guests.size >= MAX_GUESTS) {
      sendError(conn, '房间满了');
      return;
    }
    const id = r.nextId++;
    if (id > 250) {           // 单字节 id 上限，超了就别再加（正常远到不了）
      sendError(conn, '房间号资源耗尽，请重建房间');
      return;
    }
    conn.room = code;
    conn.role = 'guest';
    conn.id = id;
    r.guests.set(id, conn);
    r.last = Date.now();
    sendFrame(conn, Buffer.from([T_WELCOME, id]));
    sendFrame(r.host, Buffer.from([T_PEER_JOINED, id]));
    console.log(`[ws] room ${code} guest ${id} in (conn ${conn.seq})`);
    return;
  }

  if (type === T_DATA) {
    if (buf.length < 3) return;
    if (!conn.room) return;              // 没握手就发数据 ⇒ 丢弃
    const target = buf[1];
    const r = rooms.get(conn.room);
    if (!r) return;
    r.last = Date.now();
    if (conn.role === 'host') {
      if (target === 0) {
        // 广播给所有加入者
        for (const g of r.guests.values()) {
          const out = Buffer.concat([Buffer.from([T_DATA, g.id, 1]), buf.slice(3)]);
          sendFrame(g, out);
        }
        stat.relayed++;
        return;
      }
      const g = r.guests.get(target);
      if (!g) return;
      const out = Buffer.concat([Buffer.from([T_DATA, target, 1]), buf.slice(3)]);
      sendFrame(g, out);
      stat.relayed++;
      return;
    }
    // guest → 只能发给房主（target 必须是 1）
    if (target !== 1) return;
    if (!r.host || !r.host.open) {
      sendFrame(conn, Buffer.from([T_PEER_LEFT, 1]));
      return;
    }
    const out = Buffer.concat([Buffer.from([T_DATA, 1, conn.id]), buf.slice(3)]);
    sendFrame(r.host, out);
    stat.relayed++;
    return;
  }
  // 其它类型：静默丢弃（未来扩展用）
}

// ────────────────────────────────────────────── 帧解析

function attachSocket(sock, req) {
  const conn = {
    sock, seq: ++connSeq, id: 0, role: null, room: null,
    open: true, closed: false, buf: Buffer.alloc(0), ip: req.socket.remoteAddress,
  };
  stat.conns++;

  sock.on('data', (chunk) => {
    conn.buf = conn.buf.length ? Buffer.concat([conn.buf, chunk]) : chunk;
    if (conn.buf.length > 1 << 20) { destroyConn(conn, 'frame too large'); return; }
    for (;;) {
      const done = parseFrame(conn);
      if (!done) break;
    }
  });
  sock.on('error', () => destroyConn(conn, 'socket error'));
  // ⚠️ 必须单独接 'end'：http 升级拿到的 socket 在部分平台上不会把 FIN 转成 'close'，
  //    只挂 'close' 会让「对方直接断网/关进程」这种情况永远不清理房间。
  sock.on('end', () => destroyConn(conn, 'peer end'));
  sock.on('close', () => {
    conn.open = false;
    stat.conns--;
    destroyConn(conn, 'closed');
  });
  return conn;
}

/** 返回 true = 有待继续解析的完整帧已被消费；false = 数据不够，等下一次 data */
function parseFrame(conn) {
  const b = conn.buf;
  if (b.length < 2) return false;
  const b0 = b[0];
  const fin = (b0 & 0x80) !== 0;
  const opcode = b0 & 0x0f;
  const masked = (b[1] & 0x80) !== 0;
  let len = b[1] & 0x7f;
  let off = 2;
  if (len === 126) {
    if (b.length < 4) return false;
    len = b.readUInt16BE(2);
    off = 4;
  } else if (len === 127) {
    if (b.length < 10) return false;
    const big = b.readBigUInt64BE(2);
    if (big > BigInt(1 << 20)) { destroyConn(conn, 'frame too large'); return false; }
    len = Number(big);
    off = 10;
  }
  const maskOff = masked ? 4 : 0;
  if (b.length < off + maskOff + len) return false;

  let payload = Buffer.from(b.slice(off + maskOff, off + maskOff + len));
  if (masked) {
    const mask = b.slice(off, off + 4);
    for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
  }
  conn.buf = b.slice(off + maskOff + len);

  // 分片：Godot 从不发，收到就断，别把半包当整包投给上层
  if (!fin) {
    destroyConn(conn, 'fragmented frame');
    return false;
  }
  switch (opcode) {
    case 0x1:   // text（不用，但按二进制同样处理）
    case 0x2:   // binary
      onMessage(conn, payload);
      return true;
    case 0x8:   // close
      wsSend(conn, 0x8, payload.slice(0, 2));
      destroyConn(conn, 'client close');
      return false;
    case 0x9:   // ping
      wsSend(conn, 0xa, payload);
      return true;
    case 0xa:   // pong
      return true;
    default:
      return true;
  }
}

// ────────────────────────────────────────────── HTTP 升级

const server = http.createServer((req, res) => {
  // 非升级请求：给一句人话，方便运维用 curl 探活
  res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end(`eve ws relay ok · rooms=${rooms.size} conns=${stat.conns} relayed=${stat.relayed}\n`);
});

server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  if (!key) {
    socket.destroy();
    return;
  }
  if (stat.conns >= MAX_CONNS) {
    socket.end('HTTP/1.1 503 Service Unavailable\r\n\r\n');
    return;
  }
  socket.setNoDelay(true);
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${wsAccept(key)}\r\n\r\n`
  );
  attachSocket(socket, req);
});

// 心跳：浏览器/Godot 都会自动回 pong，用来让中间的 NAT/代理别把空闲连接掐掉
setInterval(() => {
  const now = Date.now();
  for (const [code, r] of [...rooms.entries()]) {
    if (now - r.last < ROOM_TTL_MS) continue;
    if (r.host) destroyConn(r.host, 'idle timeout');
    for (const g of [...r.guests.values()]) destroyConn(g, 'idle timeout');
    rooms.delete(code);
    console.log(`[ws] room ${code} idle-reaped`);
  }
}, 60 * 1000);

// ★ 保活：每 30 秒给房间里每条连接发一帧 WebSocket ping（opcode 9）。
//
// [WHY] 斗地主一局中间可能长时间没有游戏包（等对手思考、房主在大厅等人）。
//       中间的 Caddy/NAT 对「完全没流量」的连接有 idle 超时，超了就静默断开，
//       玩家看到的是「莫名其妙掉线」。ping/pong 是最便宜的心跳（浏览器和
//       Godot 的 WebSocketPeer 都会**自动**回 pong，上层代码一个字都不用改）。
setInterval(() => {
  const empty = Buffer.alloc(0);
  for (const r of rooms.values()) {
    if (r.host && r.host.open) wsSend(r.host, 0x9, empty);
    for (const g of r.guests.values()) if (g.open) wsSend(g, 0x9, empty);
  }
}, 30 * 1000);

setInterval(() => {
  console.log(`[ws] rooms=${rooms.size} conns=${stat.conns} relayed=${stat.relayed} ` +
    `rejected=${stat.rejected} rss=${(process.memoryUsage().rss / 1048576).toFixed(1)}MB`);
}, 60 * 1000);

server.listen(PORT, HOST, () => {
  console.log(`[ws] listening ws://${HOST}:${PORT} (behind Caddy at /relay)`);
});

process.on('SIGTERM', () => {
  console.log('[ws] shutting down');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000);
});
