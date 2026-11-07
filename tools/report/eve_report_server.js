// EVE 自走棋 · 诊断上报接收端（Node 版，部署到 VPS 用）
//
// 用法：  node eve_report_server.js [port]        （默认 27102）
//        PORT=27102 OUT_DIR=/var/lib/eve-reports node eve_report_server.js
//
// 职责单一：**收 POST /report 的 JSON，落盘一个文件，回 ok**。
//   · 不解析游戏数据、不做统计、不返回任何内容给客户端（避免变成可读接口）
//   · 只监听 127.0.0.1，对外由 Caddy 反代（同 /relay 的做法）
//   · 落盘目录按日期分桶：/var/lib/eve-reports/2026-11-07/141233-a1b2c3.json
//
// ── 三道闸，缺一不可 ────────────────────────────────────────────────
//  1. **体积**：超过 MAX_BODY 直接 413。游戏那边日志尾部 64KB 封顶，
//     300KB 足够，再大多半是有人在拿它当网盘。
//  2. **频率**：同一 IP 每分钟 20 条。公网上没限速的写接口，一晚上就能被塞满磁盘。
//  3. **方法**：只认 POST /report，其余一律 404（不给探测者任何信息）。
//
// ⚠️ 磁盘会一直长：一条典型上报 20~60KB。自己看着点 df，别把热更通道挤没了。

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const port = parseInt(process.argv[2] || process.env.PORT || '27102', 10);
const OUT_DIR = process.env.OUT_DIR || '/var/lib/eve-reports';
const MAX_BODY = 300 * 1024;
const RATE_PER_MIN = 20;

const buckets = new Map(); // ip -> { n, resetAt }
let total = 0;

function rate_ok(ip) {
  const now = Date.now();
  let b = buckets.get(ip);
  if (!b || now > b.resetAt) {
    b = { n: 0, resetAt: now + 60000 };
    buckets.set(ip, b);
  }
  b.n++;
  return b.n <= RATE_PER_MIN;
}

function pad(n, w = 2) {
  return String(n).padStart(w, '0');
}

function stamp(d) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function save(raw) {
  const now = new Date();
  const dir = path.join(OUT_DIR, stamp(now));
  fs.mkdirSync(dir, { recursive: true });
  const name = `${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`
    + `-${crypto.randomBytes(3).toString('hex')}.json`;
  const file = path.join(dir, name);
  fs.writeFileSync(file, raw, 'utf8');
  return file;
}

const server = http.createServer((req, res) => {
  const ip = req.socket.remoteAddress || '?';

  if (req.method === 'GET' && req.url === '/report/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, total }));
    return;
  }

  if (req.method !== 'POST' || req.url !== '/report') {
    // 404 而不是 405：不告诉探测者「这里其实有个接口」。
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('not found');
    return;
  }

  if (!rate_ok(ip)) {
    res.writeHead(429, { 'Content-Type': 'text/plain' });
    res.end('slow down');
    return;
  }

  let body = '';
  let over = false;
  req.on('data', (chunk) => {
    if (over) return;
    body += chunk;
    if (body.length > MAX_BODY) {
      over = true;
      res.writeHead(413, { 'Content-Type': 'text/plain' });
      res.end('too large');
      req.destroy();
    }
  });

  req.on('end', () => {
    if (over) return;
    // 必须能解析成对象：否则就是把这儿当网盘了。
    try {
      const obj = JSON.parse(body);
      if (typeof obj !== 'object' || obj === null) throw new Error('not object');
    } catch (e) {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      res.end('bad json');
      return;
    }
    try {
      save(body);
      total++;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end('{"ok":true}');
    } catch (e) {
      console.error('[report] write failed:', e.message);
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end('write failed');
    }
  });
});

server.listen(port, '127.0.0.1', () => {
  console.log(`[report] listening 127.0.0.1:${port} -> ${OUT_DIR}`);
});
