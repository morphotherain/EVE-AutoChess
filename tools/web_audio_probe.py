#!/usr/bin/env python3
"""从公网/本地加载 Godot web 包，回读「音频到底有没有起来」。

[WHY] 游戏静音在网页上分三种完全不同的原因，光看画面区分不了：
      ① 音频流没进包（导出器没看见依赖）→ 控制台一条 `[EveAudio] … 未识别到音源`
      ② 流进包了但 AudioContext 被浏览器挂起 → `ctx.state == "suspended"`，
         必须有一次**真实用户手势**才会 resume（不是 bug，是自动播放策略）
      ③ 都正常但玩家把音量拉到 0
      所以探针要同时报告：包内音源告警、AudioContext 状态、总线音量。

用法：python tools/web_audio_probe.py <url> [等待秒数]
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

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "web_shot.py"), encoding="utf-8").read()
exec(SRC[SRC.index("class WS:"):SRC.index("def main():")])

CHROME = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
URL = sys.argv[1]
WAIT = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0

prof = tempfile.mkdtemp(prefix="cdp_audio_")
p = subprocess.Popen(
    [CHROME, "--headless=new", "--remote-debugging-port=0",
     f"--user-data-dir={prof}", "--use-angle=swiftshader",
     "--enable-unsafe-swiftshader", "--autoplay-policy=no-user-gesture-required",
     "--window-size=1280,800", "about:blank"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

f = os.path.join(prof, "DevToolsActivePort")
for _ in range(150):
    if os.path.exists(f):
        break
    time.sleep(0.2)
port = open(f).read().split("\n")[0].strip()
target = next(t for t in json.load(urllib.request.urlopen(
    f"http://127.0.0.1:{port}/json/list")) if t["type"] == "page")
ws = WS(target["webSocketDebuggerUrl"])
mid = 0
logs = []


def call(method, params=None, timeout=40):
    global mid
    mid += 1
    ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
    end = time.time() + timeout
    while time.time() < end:
        msg = json.loads(ws.recv())
        if msg.get("method") == "Runtime.consoleAPICalled":
            for a in msg["params"].get("args", []):
                logs.append(str(a.get("value", "")))
        elif msg.get("method") == "Log.entryAdded":
            logs.append("[log] " + str(msg["params"]["entry"].get("text", "")))
        elif msg.get("id") == mid:
            return msg.get("result", {})
    return {}


call("Page.enable")
call("Runtime.enable")
call("Log.enable")
call("Page.navigate", {"url": URL})
time.sleep(WAIT)

probe = """(function(){
  var out = {ctxs: [], godot: (typeof GodotAudio !== 'undefined')};
  try {
    if (typeof GodotAudio !== 'undefined' && GodotAudio.ctx) {
      out.ctxs.push({name: 'GodotAudio.ctx', state: GodotAudio.ctx.state,
                     rate: GodotAudio.ctx.sampleRate});
    }
  } catch (e) { out.err = String(e); }
  out.globalNames = Object.keys(window).filter(function(k){
    return /audio|godot/i.test(k); });
  return JSON.stringify(out);
})()"""
r = call("Runtime.evaluate", {"expression": probe, "returnByValue": True})
print("== 页面内音频对象 ==")
print(r.get("result", {}).get("value"))

print("\n== 控制台里与音频相关的行 ==")
hits = [l for l in logs if "EveAudio" in l or "音频" in l or "音源" in l
        or "audio" in l.lower()]
for l in hits[-25:]:
    print("  " + l[:300])
if not hits:
    print("  (无)")

print(f"\n== 控制台总行数 {len(logs)}，最后 12 行 ==")
for l in logs[-12:]:
    print("  " + l[:200])

p.kill()
