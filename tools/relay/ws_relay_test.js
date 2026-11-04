// WebSocket 中继的端到端自检（不需要浏览器，也不需要 ws 包）。
//
// 覆盖 6 条行为：
//   ① 房主登记拿到 id=1
//   ② 加入者拿到递增 id，房主收到 PEER_JOINED
//   ③ 加入者 → 房主（target=1），房主看到的 from 是对方 id
//   ④ 房主 → 指定加入者（target=N）
//   ⑤ 房主广播（target=0）能到所有加入者
//   ⑥ 加入者断开，房主收到 PEER_LEFT
//
// 用法：node ws_relay_test.js [port]      （默认连 127.0.0.1:27101）

const net = require('net');
const tls = require('tls');
const crypto = require('crypto');

// 用法：node ws_relay_test.js [port] [host] [ws|wss]
const PORT = parseInt(process.argv[2] || '27101', 10);
const HOST = process.argv[3] || '127.0.0.1';
const TLS = (process.argv[4] || 'ws') === 'wss';
const ROOM = 'TESTROOM';

function connect() {
  return new Promise((resolve, reject) => {
    const sock = TLS
      ? tls.connect({ host: HOST, port: PORT, servername: HOST })
      : net.connect(PORT, HOST);
    const key = crypto.randomBytes(16).toString('base64');
    sock.on(TLS ? 'secureConnect' : 'connect', () => {
      sock.write(
        `GET /relay HTTP/1.1\r\nHost: ${HOST}\r\n` +
        'Upgrade: websocket\r\nConnection: Upgrade\r\n' +
        `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`);
    });
    let handshook = false;
    let buf = Buffer.alloc(0);
    const c = { sock, frames: [], waiters: [], closed: false };
    sock.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      if (!handshook) {
        const i = buf.indexOf('\r\n\r\n');
        if (i < 0) return;
        const head = buf.slice(0, i).toString();
        if (!head.includes('101')) return reject(new Error('handshake failed: ' + head));
        handshook = true;
        buf = buf.slice(i + 4);
        resolve(c);
      }
      for (;;) {
        const r = parse(c, buf);
        if (!r) break;
        buf = r;
      }
    });
    sock.on('error', reject);
    sock.on('close', () => { c.closed = true; });
  });
}

function parse(c, b) {
  if (b.length < 2) return null;
  const op = b[0] & 0x0f;
  let len = b[1] & 0x7f;
  let off = 2;
  if (len === 126) { if (b.length < 4) return null; len = b.readUInt16BE(2); off = 4; }
  else if (len === 127) { if (b.length < 10) return null; len = Number(b.readBigUInt64BE(2)); off = 10; }
  if (b.length < off + len) return null;
  const payload = b.slice(off, off + len);
  if (op === 0x2 || op === 0x1) {
    const f = { type: payload[0], target: payload[1], from: payload[2], len: payload.length };
    // ⚠️ 有等待者就**直接交付**，别再 push 一份 —— 否则同一帧会被取两次，
    //    后续断言全部错位一格（2026-11-04 第一次跑就是这么被坑的）。
    const w = c.waiters.shift();
    if (w) w(f); else c.frames.push(f);
  }
  return b.slice(off + len);
}

function send(c, bytes, opcode = 0x2) {
  const payload = Buffer.from(bytes);
  const mask = crypto.randomBytes(4);
  const len = payload.length;
  let head;
  if (len < 126) { head = Buffer.from([0x80 | opcode, 0x80 | len]); }
  else { head = Buffer.alloc(4); head[0] = 0x80 | opcode; head[1] = 0x80 | 126; head.writeUInt16BE(len, 2); }
  const masked = Buffer.from(payload);
  for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i & 3];
  c.sock.write(Buffer.concat([head, mask, masked]));
}

function next(c, ms = 2000) {
  if (c.frames.length) return Promise.resolve(c.frames.shift());
  return new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error('等待帧超时')), ms);
    c.waiters.push((f) => { clearTimeout(t); res(f); });
  });
}

const out = [];
function check(name, cond, extra = '') {
  out.push(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) process.exitCode = 1;
}

(async () => {
  const codeBuf = Buffer.alloc(8);
  codeBuf.write(ROOM, 'ascii');

  // ① 房主
  const host = await connect();
  send(host, Buffer.concat([Buffer.from([1]), codeBuf]));
  const w1 = await next(host);
  check('① 房主拿到 id=1', w1.type === 3 && w1.target === 1, JSON.stringify(w1));

  // ② 加入者
  const g1 = await connect();
  send(g1, Buffer.concat([Buffer.from([2]), codeBuf]));
  const w2 = await next(g1);
  const id1 = w2.target;
  check('② 加入者拿到 id≥2', w2.type === 3 && id1 >= 2, `id=${id1}`);
  const j = await next(host);
  check('② 房主收到 PEER_JOINED', j.type === 4 && j.target === id1, JSON.stringify(j));

  // ③ 加入者 → 房主
  send(g1, Buffer.concat([Buffer.from([6, 1, id1]), Buffer.from('hello-host')]));
  const d1 = await next(host);
  check('③ 房主收到加入者的包且 from 正确',
    d1.type === 6 && d1.from === id1 && d1.len === 3 + 'hello-host'.length, JSON.stringify(d1));

  // ④ 房主 → 指定加入者
  send(host, Buffer.concat([Buffer.from([6, id1, 1]), Buffer.from('hi-guest')]));
  const d2 = await next(g1);
  check('④ 加入者收到房主的包且 from=1',
    d2.type === 6 && d2.from === 1 && d2.len === 3 + 'hi-guest'.length, JSON.stringify(d2));

  // ⑤ 广播
  const g2 = await connect();
  send(g2, Buffer.concat([Buffer.from([2]), codeBuf]));
  const w3 = await next(g2);
  const id2 = w3.target;
  await next(host);  // 吃掉 PEER_JOINED(id2)
  send(host, Buffer.concat([Buffer.from([6, 0, 1]), Buffer.from('broadcast')]));
  const b1 = await next(g1);
  const b2 = await next(g2);
  check('⑤ 广播到两个加入者', b1.type === 6 && b2.type === 6 && b2.from === 1,
    `g1=${JSON.stringify(b1)} g2=${JSON.stringify(b2)}`);

  // ⑥ 加入者断开
  // 用 close 帧断开（浏览器关标签页就是这个行为），比 RST 更接近真实
  send(g2, Buffer.from([0x03, 0xe8]), 0x8);
  setTimeout(() => { try { g2.sock.destroy(); } catch (e) {} }, 50);
  const l = await next(host, 3000);
  check('⑥ 房主收到 PEER_LEFT', l.type === 5 && (l.target === id1 || l.target === id2),
    JSON.stringify(l));

  // ⑦ 房主断开 ⇒ 加入者收到 PEER_LEFT(1)
  send(host, Buffer.from([0x03, 0xe8]), 0x8);
  setTimeout(() => { try { host.sock.destroy(); } catch (e) {} }, 50);
  const lg = await next(g1, 3000);
  check('⑦ 房主断开后加入者收到 PEER_LEFT(1)', lg.type === 5 && lg.target === 1,
    JSON.stringify(lg));

  console.log(out.join('\n'));
  try { g1.sock.destroy(); } catch (e) { /* ignore */ }
  setTimeout(() => process.exit(process.exitCode || 0), 200);
})().catch((e) => {
  console.error('测试中断：', e.message);
  console.log(out.join('\n'));
  process.exit(2);
});
