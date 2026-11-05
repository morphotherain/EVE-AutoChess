# -*- coding: utf-8 -*-
"""网页试玩版「能不能真打」的端到端探针：就绪即拍，之后按时间点连拍。

[WHY] 判「网页版能不能打」不能只看首页有没有画出来 —— 要看到「上阵 → 自动
      开战 → 接敌开火 → 掉血」这条链。这里用 Godot 自己 print 的
      `[web] 初始舰队已上阵` 当就绪信号（不能像 web_shot.py 那样固定 WAIT：
      线上包 75 MB、本机直连约 490 KB/s ⇒ 加载 2~4 分钟，固定等待必然拍早），
      之后按 SHOT_AT 的累计秒数连拍，一眼就能看出画面是在动还是卡死。

⚠️⚠️ 默认无头模式**测不了节奏**：无头 Chrome 会把页面当成不可见，
      rAF 被节流到 ~1 fps，实测 59 秒真实时间只推进 3 秒游戏时钟
      （00:07→00:04），舰船坐标一动不动。要判断「打不打得起来」必须
      `HEADED=1`（有头 + 关后台节流），此时 30 秒准备倒计时按真实时间走完。

用法：
  python web_play_probe.py <url> <输出前缀> [加载超时秒]
  HEADED=1 python web_play_probe.py http://127.0.0.1:8765/index.html build/headed
  SHOTS="3,36,65,95" python web_play_probe.py ...     # 自定义连拍时间点

产物：<前缀>_s0_3s.png ... 并打印控制台 error/warning 与全部 Godot print。
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

# ⚠️ 不能 import web_shot：它在模块层就调 main()，import 会直接跑起来。
#    这里照抄那份最小 WebSocket 客户端（同一套代码，改的时候两边都看）。
CHROME = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"


class WS:
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


URL = sys.argv[1]
PREFIX = sys.argv[2]
LOAD_TIMEOUT = float(sys.argv[3]) if len(sys.argv) > 3 else 420.0
W, H = 1280, 800

# 准备阶段 30s（scripts/eve_battle_scene.gd: PREP_SECONDS）。
# 就绪后按这些「累计秒数」各拍一张：3s 是准备阶段，36s 起应该已经自动开战。
SHOT_AT = [float(v) for v in os.environ.get("SHOTS", "3,36,50,65,80,95").split(",")]


def main():
    profile = tempfile.mkdtemp(prefix="cdp_pve_")
    args = [
        CHROME, "--remote-debugging-port=0",
        f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
        "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
        "--hide-scrollbars", f"--window-size={W},{H}",
        # ★★ 关键：无头模式下 rAF 会被当成「不可见页面」节流到 ~1 fps，
        #    实测 59 秒真实时间只推进 3 秒游戏时钟（00:07→00:04）、
        #    舰船坐标一动不动 ⇒ 拿它判断"能不能打"是错的。
        #    这里改有头 + 关掉后台节流，让 rAF 跑真实帧率。
        "--disable-backgrounding-occluded-windows",
        "--disable-renderer-backgrounding",
        "--disable-background-timer-throttling",
        "--disable-features=CalculateNativeWinOcclusion",
        "about:blank",
    ]
    if not os.environ.get("HEADED"):
        args.insert(1, "--headless=new")
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

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

    def call(method, params=None, timeout=40):
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
    # [WHY] 有头模式下窗口一旦被别的窗口盖住，Chromium 仍会降帧 ⇒ 把标签页提到最前，
    #       否则「有头」也白搭（实测不提就掉到和节流差不多）。
    try:
        call("Page.bringToFront")
    except Exception:
        pass
    t0 = time.time()
    call("Page.navigate", {"url": URL})

    ws.s.settimeout(0.5)
    ready = False
    end = time.time() + LOAD_TIMEOUT
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
            txt = e.get("text", "")
            if e.get("level") in ("error", "warning"):
                logs.append(f"[{e['level']}] {txt}")
            if "初始舰队已上阵" in txt:
                ready = True
                break
        elif m == "Runtime.consoleAPICalled":
            p = msg["params"]
            txt = " ".join(str(a.get("value", a.get("description", ""))) for a in p.get("args", []))
            if txt.strip():
                logs.append(f"[{p.get('type')}] {txt[:300]}")
            if "初始舰队已上阵" in txt:
                ready = True
                break
        elif m == "Runtime.exceptionThrown":
            d = msg["params"]["exceptionDetails"]
            logs.append("[exception] " + (d.get("text") or "") + " " +
                        str(d.get("exception", {}).get("description", ""))[:300])

    print(f"加载完成={ready} 用时={time.time()-t0:.1f}s")
    ws.s.settimeout(40)

    def shot(name):
        s = call("Page.captureScreenshot", {"format": "png"})
        p = f"{PREFIX}_{name}.png"
        open(p, "wb").write(base64.b64decode(s["data"]))
        print("saved", p, os.path.getsize(p), "bytes")

    if not ready:
        shot("fail")
    else:
        t_ready = time.time()
        for i, at in enumerate(SHOT_AT):
            wait = t_ready + at - time.time()
            if wait > 0:
                time.sleep(wait)
            shot(f"s{i}_{int(at)}s")
            # [NOTE] 每张截图前后都强制刷一次 stdout：重定向到文件时 python 是块缓冲，
            #        不刷就只能等进程退出才看得见进度。
            sys.stdout.flush()

    print("--- 控制台（后 40 条）---")
    for l in logs[-40:]:
        print(l)
    proc.kill()


main()
