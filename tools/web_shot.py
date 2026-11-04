# -*- coding: utf-8 -*-
"""用 CDP 驱动无头 Chromium 打开一个页面，等够时间再截图，并回收控制台报错。

[WHY] Edge/Chrome 的 --screenshot 在 load 事件后立刻拍，Godot Web 还要接着拉
      wasm + pck 再初始化，拍到的是引擎启动条；--virtual-time-budget 也不会等网络。
      Playwright 在这个网络下装不上，所以用裸 WebSocket 走一遍 CDP。
用法：
  python web_shot.py <url> <输出png> [等待秒数] [宽] [高]
"""
import base64
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request

URL = sys.argv[1]
OUT = sys.argv[2]
WAIT = float(sys.argv[3]) if len(sys.argv) > 3 else 12.0
W = int(sys.argv[4]) if len(sys.argv) > 4 else 1280
H = int(sys.argv[5]) if len(sys.argv) > 5 else 800
# 可选：第 6 个参数 "x,y"（CSS 像素）表示加载完先点一下，再等 6 秒截图
CLICK = sys.argv[6] if len(sys.argv) > 6 else ""
AFTER = float(sys.argv[7]) if len(sys.argv) > 7 else 6.0

CHROME = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"


class WS:
    """最小 WebSocket 客户端：够发 JSON 文本帧、收回服务端帧就行。"""

    def __init__(self, url):
        assert url.startswith("ws://")
        host_port, path = url[5:].split("/", 1)
        host, port = host_port.split(":")
        self.s = socket.create_connection((host, int(port)), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET /{path} HTTP/1.1\r\nHost: {host_port}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
               f"Sec-WebSocket-Version: 13\r\n\r\n")
        self.s.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.s.recv(4096)
        self.rest = buf.split(b"\r\n\r\n", 1)[1]

    def _recv_exact(self, n):
        out = self.rest[:n]
        self.rest = self.rest[n:]
        while len(out) < n:
            chunk = self.s.recv(n - len(out))
            if not chunk:
                raise ConnectionError("ws closed")
            out += chunk
        return out

    def recv(self):
        h = self._recv_exact(2)
        opcode = h[0] & 0x0F
        ln = h[1] & 0x7F
        if ln == 126:
            ln = struct.unpack(">H", self._recv_exact(2))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", self._recv_exact(8))[0]
        data = self._recv_exact(ln) if ln else b""
        if opcode == 8:
            raise ConnectionError("ws close frame")
        return data.decode("utf-8", "replace")

    def send(self, text):
        payload = text.encode()
        mask = os.urandom(4)
        n = len(payload)
        head = b"\x81"
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.s.sendall(head + mask + masked)


def main():
    profile = tempfile.mkdtemp(prefix="cdp_")
    proc = subprocess.Popen([
        CHROME, "--headless=new", "--remote-debugging-port=0",
        f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
        "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
        "--hide-scrollbars", f"--window-size={W},{H}", "about:blank",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    port_file = os.path.join(profile, "DevToolsActivePort")
    for _ in range(100):
        if os.path.exists(port_file):
            break
        time.sleep(0.2)
    port = open(port_file).read().split("\n")[0].strip()
    targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list"))
    page = next(t for t in targets if t["type"] == "page")

    ws = WS(page["webSocketDebuggerUrl"])
    mid = 0

    def call(method, params=None, timeout=30):
        nonlocal mid
        mid += 1
        ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
        end = time.time() + timeout
        while time.time() < end:
            msg = json.loads(ws.recv())
            if msg.get("id") == mid:
                return msg.get("result", {})
        raise TimeoutError(method)

    logs = []
    call("Log.enable")
    call("Runtime.enable")
    call("Page.enable")
    call("Page.navigate", {"url": URL})

    end = time.time() + WAIT
    ws.s.settimeout(0.5)
    while time.time() < end:
        try:
            msg = json.loads(ws.recv())
        except socket.timeout:
            continue
        except Exception:
            break
        m = msg.get("method")
        if m == "Log.entryAdded":
            e = msg["params"]["entry"]
            if e.get("level") in ("error", "warning"):
                logs.append(f"[{e['level']}] {e.get('text')}")
        elif m == "Runtime.consoleAPICalled":
            # [NOTE] Godot 的 print/printerr 全走 console.log/warn/error，必须单独收
            p = msg["params"]
            txt = " ".join(str(a.get("value", a.get("description", ""))) for a in p.get("args", []))
            if txt.strip():
                logs.append(f"[{p.get('type')}] {txt[:400]}")
        elif m == "Runtime.exceptionThrown":
            d = msg["params"]["exceptionDetails"]
            logs.append("[exception] " + (d.get("text") or "") + " " +
                        str(d.get("exception", {}).get("description", ""))[:300])

    ws.s.settimeout(30)

    if CLICK:
        cx, cy = [float(v) for v in CLICK.split(",")]
        for t in ("mouseMoved", "mousePressed", "mouseReleased"):
            call("Input.dispatchMouseEvent", {
                "type": t, "x": cx, "y": cy, "button": "left",
                "clickCount": 1, "buttons": 1 if t == "mousePressed" else 0,
            })
        # [WHY] CDP 的合成鼠标事件不一定能喂到 Godot 的 canvas 监听上，
        #       再直接往 canvas 派发一轮 pointer 事件兜底。
        js = """
        (function(){
          var c = document.querySelector('canvas'); if(!c) return 'no canvas';
          var r = c.getBoundingClientRect();
          var x = r.left + %f * r.width / %f, y = r.top + %f * r.height / %f;
          ['pointermove','pointerdown','pointerup'].forEach(function(t){
            c.dispatchEvent(new PointerEvent(t,{clientX:x,clientY:y,bubbles:true,
              cancelable:true,button:0,buttons:t==='pointerdown'?1:0,
              pointerType:'mouse',isPrimary:true,pointerId:1}));
          });
          return 'ok';
        })()
        """ % (cx, W, cy, H)
        r = call("Runtime.evaluate", {"expression": js, "returnByValue": True})
        print("canvas 注入:", r.get("result", {}).get("value"))
        print(f"已点击 ({cx},{cy})，再等 {AFTER}s")
        time.sleep(AFTER)

    shot = call("Page.captureScreenshot", {"format": "png"})
    open(OUT, "wb").write(base64.b64decode(shot["data"]))
    print("saved", OUT, os.path.getsize(OUT), "bytes")
    if logs:
        print("--- 控制台异常 ---")
        for l in logs[:15]:
            print(l)
    else:
        print("控制台无 error/warning")
    proc.kill()


main()
