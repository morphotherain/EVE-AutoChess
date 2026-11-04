# -*- coding: utf-8 -*-
"""从 Godot 导出模板 .tpz（本质是 zip）里只取 web 相关条目，不整包下载。

[WHY] 整包 1.2 GB，网速 0.15~0.6 MB/s，等不起；而 ZIP 的中央目录在文件尾部，
      配合 HTTP Range 就能精确取出指定成员。目标只有 ~50 MB。
[NOTE] 只处理 stored(0) 与 deflate(8) 两种压缩方式，Godot 官方包就是这两种。
"""
import io
import struct
import sys
import urllib.request
import zlib

URL = sys.argv[1]
OUTDIR = sys.argv[2]
WANT = ("web_debug.zip", "web_release.zip", "web_dlink_debug.zip",
        "web_dlink_release.zip", "version.txt")


def fetch(start, end, tries=6):
    # [WHY] 镜像（gh-proxy）大文件经常中途断流，这里按块重试，不能一次失败就整包重来
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(URL, headers={"Range": f"bytes={start}-{end}"})
            with urllib.request.urlopen(req, timeout=90) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            last = e
            print(f"   ! 重试 {i + 1}/{tries}: {e}", flush=True)
            import time
            time.sleep(1.5 * (i + 1))
    raise last


def total_size():
    req = urllib.request.Request(URL, method="HEAD")
    with urllib.request.urlopen(req, timeout=30) as r:
        return int(r.headers["Content-Length"])


size = total_size()
print(f"远程大小 {size} 字节")

# 1) 取尾部，找 EOCD
tail_len = min(65536, size)
tail = fetch(size - tail_len, size - 1)
i = tail.rfind(b"PK\x05\x06")
if i < 0:
    sys.exit("没找到 EOCD，可能不是标准 zip")
cd_size, cd_off = struct.unpack("<II", tail[i + 12:i + 20])
n_entries = struct.unpack("<H", tail[i + 10:i + 12])[0]
print(f"中央目录 offset={cd_off} size={cd_size} entries={n_entries}")

# zip64 兜底
if cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF:
    j = tail.rfind(b"PK\x06\x06")
    if j < 0:
        sys.exit("zip64 EOCD 缺失")
    n_entries = struct.unpack("<Q", tail[j + 32:j + 40])[0]
    cd_size, cd_off = struct.unpack("<QQ", tail[j + 40:j + 56])
    print(f"[zip64] offset={cd_off} size={cd_size} entries={n_entries}")

cd = fetch(cd_off, cd_off + cd_size - 1)

# 2) 解析中央目录
entries = []
p = 0
while p < len(cd) - 4 and cd[p:p + 4] == b"PK\x01\x02":
    (method,) = struct.unpack("<H", cd[p + 10:p + 12])
    csize, usize = struct.unpack("<II", cd[p + 20:p + 28])
    nlen, elen, clen = struct.unpack("<HHH", cd[p + 28:p + 34])
    (lho,) = struct.unpack("<I", cd[p + 42:p + 46])
    name = cd[p + 46:p + 46 + nlen].decode("utf-8", "replace")
    extra = cd[p + 46 + nlen:p + 46 + nlen + elen]
    # zip64 扩展字段：把 0xFFFFFFFF 的真实值捞出来
    if 0xFFFFFFFF in (csize, usize) or lho == 0xFFFFFFFF:
        q = 0
        while q + 4 <= len(extra):
            hid, hsz = struct.unpack("<HH", extra[q:q + 4])
            if hid == 1:
                vals = extra[q + 4:q + 4 + hsz]
                k = 0
                if usize == 0xFFFFFFFF:
                    usize = struct.unpack("<Q", vals[k:k + 8])[0]; k += 8
                if csize == 0xFFFFFFFF:
                    csize = struct.unpack("<Q", vals[k:k + 8])[0]; k += 8
                if lho == 0xFFFFFFFF:
                    lho = struct.unpack("<Q", vals[k:k + 8])[0]; k += 8
                break
            q += 4 + hsz
    entries.append((name, method, csize, usize, lho))
    p += 46 + nlen + elen + clen

print(f"解析到 {len(entries)} 个条目")

# 3) 逐个下载需要的成员
for name, method, csize, usize, lho in entries:
    base = name.split("/")[-1]
    # [WHY] Godot 4.7 的非线程模板叫 web_nothreads_*.zip，和 web_*.zip 是两套，
    #       variant/thread_support=false 时只认 nothreads 那套，所以整组都要。
    if not (base.startswith("web") and base.endswith(".zip")):
        continue
    # 本地头长度：30 + name + extra
    head = fetch(lho, lho + 29)
    nlen, elen = struct.unpack("<HH", head[26:30])
    data_off = lho + 30 + nlen + elen
    print(f"取 {name}  ({usize} 字节, method={method}) ...", flush=True)
    raw = b""
    got = 0
    step = 1 << 20
    while got < csize:
        end = min(got + step, csize) - 1
        chunk = fetch(data_off + got, data_off + end)
        raw += chunk
        got += len(chunk)
        print(f"   {got/1048576:.1f}/{csize/1048576:.1f} MB", flush=True)
    blob = zlib.decompress(raw, -15) if method == 8 else raw
    with open(f"{OUTDIR}/{base}", "wb") as f:
        f.write(blob)
    print(f"   -> {OUTDIR}/{base} {len(blob)} 字节")

print("完成")
