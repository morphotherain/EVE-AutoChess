#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 Godot 4 的 .pck 里**剔掉指定文件**，重排出一份更小的包。

═══ 为什么需要它 ═══════════════════════════════════════════════════

`icudt_godot.dat`（4.58 MB）和 `icon.png`（81 KB）是 Godot **引擎在导出时
强制追加**的两项 —— 它们不受 `exclude_filter` 约束（实测：把名字写进
exclude_filter 完全无效，照打不误）。

于是热更包 6 MB 里有 4.66 MB 是玩家**本来就已经有**的东西：
  · icudt 随 APK/EXE 一起发，res:// 里一定有；
  · icon 同理，且运行时根本不读它。
`load_resource_pack` 是**叠加**语义 ⇒ pck 里没有这两个文件，客户端照样用
基础包里的那份，一行都不缺。

为什么要拼命缩这 4.66 MB：
  分发节点只有 4 Mbps 出网（实测 504 KB/s）。
  · 6.0 MB → 12 秒
  · 1.1 MB → 2.2 秒
而 **0.14.10 那批已发出去的客户端，下载超时只有 6 秒**（那个 bug 后来才修）。
=> 不剥掉，老客户端每次都「下到一半被自己砍断」，热更等于不可用。

═══ 用法 ═══════════════════════════════════════════════════════

    python tools/pck_strip.py <in.pck> <out.pck> [--drop a,b,c] [--drop-prefix p1,p2] [--list]

  默认 --drop = icudt_godot.dat,icon.png

  `--drop`        按**文件名**精确匹配
  `--drop-prefix` 按**路径前缀**匹配（例如 `.godot/imported/`）

═══ 为什么需要 --drop-prefix（2026-11-07 加）══════════════════════

热更包只该含 `scripts/` + `data/`，但导出时 `.godot/imported/` 下的
**导入产物（.ctex 等）会被一起打进去**，而且这一项**写进 exclude_filter
同样无效**（跟 icudt 一个毛病）。

平时它不大，因为里面只有 assets 的导入缓存；但只要开发机跑过截图类验证脚本
（`shot*.png` / `local_s0_3s.png` 之类），那些 png 哪怕后来被删掉，
`.godot/imported/` 里的 ctex 仍然留着 —— 而且 Godot 导出**照打不误**。
实测 2026-11-07：热更包从 1.02 MB 涨到 24.44 MB，多出来的 23.34 MB 全是这种孤儿。

⇒ 按前缀整个剥掉 `.godot/imported/`。安全性：热更包本来就不含 assets，
运行时那些 ctex 由基础包（APK/EXE）提供，`load_resource_pack` 是叠加语义，
剥掉不会缺东西。⚠️ 别顺手把整个 `.godot/` 都剥了 —— 里面还有
`global_script_class_cache.cfg` 之类导出器要读的小文件。

═══ 格式（Godot 4.7 实测，pack_version = 4）═══════════════════════

  off 0   4   magic "GDPC"
  off 4   4   pack_version (u32, = 4)
  off 8   4   ver_major
  off 12  4   ver_minor
  off 16  4   ver_rev
  off 20  4   pack_flags
  off 24  8   file_base        (u64, = 112，数据区起点)
  off 32  8   dir_offset       (u64，目录表起点)   ← **本工具唯一要改的字段**
  off 40  72  预留（全 0，原样拷贝）

  目录表： u32 count，然后每项：
            u32 path_len(含结尾 \0)
            path_len 字节路径
            u64 offset       ← ⚠️⚠️ **相对 file_base 的偏移，不是文件绝对偏移**
            u64 size
            16 字节 md5
            u32 flags

  ⚠️⚠️ offset 的语义是**相对 file_base(112)**，不是绝对偏移。
    这个坑是我第一版踩的：拿 `buf[off]` 直接切片，每个文件都错位 112 字节，
    结果 manifest 里的字符串被截断，Godot 以 `--main-pack` 启动直接崩溃。
    判定方法（本工具每次都会自检）：条目里带 md5 ⇒ 拿 `buf[off]` 与
    `buf[base+off]` 各算一遍，261/261 只命中后者 —— 这就是证据，不靠猜。
"""
import hashlib
import struct
import sys

HEADER_LEN = 112  # 实测 file_base = 112；头部 0..111 原样保留
DEFAULT_DROP = ("icudt_godot.dat", "icon.png")


def read_entries(buf):
    base, = struct.unpack_from("<Q", buf, 24)
    diroff, = struct.unpack_from("<Q", buf, 32)
    if buf[:4] != b"GDPC":
        raise SystemExit("不是 pck：magic = %r" % buf[:4])
    pv, = struct.unpack_from("<I", buf, 4)
    cnt, = struct.unpack_from("<I", buf, diroff)
    pos = diroff + 4
    ents = []
    for _ in range(cnt):
        ln, = struct.unpack_from("<I", buf, pos)
        pos += 4
        name = buf[pos:pos + ln].rstrip(b"\x00").decode("utf-8", "replace")
        pos += ln
        off, size = struct.unpack_from("<QQ", buf, pos)
        pos += 16
        md5 = buf[pos:pos + 16]
        pos += 16
        flags, = struct.unpack_from("<I", buf, pos)
        pos += 4
        ents.append({"name": name, "off": off, "size": size, "md5": md5, "flags": flags})
    return base, diroff, pv, ents


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    src, dst = argv[1], argv[2]
    drop = set(DEFAULT_DROP)
    drop_prefix = []
    show = False
    i = 3
    while i < len(argv):
        if argv[i] == "--drop" and i + 1 < len(argv):
            drop = {s.strip() for s in argv[i + 1].split(",") if s.strip()}
            i += 2
        elif argv[i] == "--drop-prefix" and i + 1 < len(argv):
            drop_prefix = [s.strip() for s in argv[i + 1].split(",") if s.strip()]
            i += 2
        elif argv[i] == "--list":
            show = True
            i += 1
        else:
            i += 1

    buf = open(src, "rb").read()
    base, old_diroff, pv, ents = read_entries(buf)
    print("输入 : %s (%.2f MB, %d 项, pack_version=%d)" %
          (src, len(buf) / 1048576.0, len(ents), pv))

    # ── 自检：确认 offset 是「相对 file_base」而不是绝对偏移 ──────────
    # 不靠猜：条目自带 md5，两种解释各验一遍，只认命中的那种。
    hit_rel = sum(1 for e in ents
                  if hashlib.md5(buf[base + e["off"]:base + e["off"] + e["size"]]).digest() == e["md5"])
    hit_abs = sum(1 for e in ents
                  if hashlib.md5(buf[e["off"]:e["off"] + e["size"]]).digest() == e["md5"])
    if hit_rel != len(ents) or hit_abs >= hit_rel:
        raise SystemExit("offset 语义自检失败：相对命中 %d / 绝对命中 %d / 共 %d"
                         % (hit_rel, hit_abs, len(ents)))
    print("自检 : offset 相对 file_base(%d) · md5 全命中 %d/%d" % (base, hit_rel, len(ents)))

    keep, gone = [], []
    for e in ents:
        hit = e["name"] in drop or any(e["name"].startswith(p) for p in drop_prefix)
        (gone if hit else keep).append(e)

    out = bytearray(buf[:HEADER_LEN])
    # 数据区：按原顺序紧凑排列，起点仍是 file_base
    # ⚠️ 写回目录表时 offset 必须再减掉 file_base（相对值），否则客户端整体错位。
    for e in keep:
        e["newoff"] = len(out) - HEADER_LEN
        out += buf[base + e["off"]:base + e["off"] + e["size"]]

    new_diroff = len(out)
    out += struct.pack("<I", len(keep))
    for e in keep:
        nb = e["name"].encode("utf-8") + b"\x00"
        out += struct.pack("<I", len(nb)) + nb
        out += struct.pack("<QQ", e["newoff"], e["size"])
        out += e["md5"]
        out += struct.pack("<I", e["flags"])

    struct.pack_into("<Q", out, 32, new_diroff)

    # ── 写出前再自检一遍：用刚写下的目录表回读，逐项验 md5 ────────────
    bad = 0
    for e in keep:
        if hashlib.md5(out[HEADER_LEN + e["newoff"]:HEADER_LEN + e["newoff"] + e["size"]]).digest() != e["md5"]:
            bad += 1
    if bad:
        raise SystemExit("重排后 md5 不匹配的文件有 %d 个，拒绝写出" % bad)

    open(dst, "wb").write(out)
    print("输出 : %s (%.2f MB, %d 项)" %
          (dst, len(out) / 1048576.0, len(keep)))
    print("剥离 : %d 项 / %.2f MB" %
          (len(gone), sum(e["size"] for e in gone) / 1048576.0))
    if show:
        for e in sorted(gone, key=lambda x: -x["size"]):
            print("   - %-40s %.3f MB" % (e["name"], e["size"] / 1048576.0))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
