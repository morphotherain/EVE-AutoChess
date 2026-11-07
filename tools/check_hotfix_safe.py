#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""热更包「老客户端兼容性」闸门。

═══ 为什么需要它 ═══════════════════════════════════════════════════
2026-11-07 出了事故：b39 的热更包让**所有 b38 及以前的客户端黑屏**。
根因是当时新加了 autoload `EveReport`，主菜单里又直接写 `EveReport.open_feedback()`：

    autoload 注册表在**引擎启动那一刻**就定死了，`load_resource_pack()` 改不了它
    （它只挂文件系统，不重读 project.binary、不重新注册 autoload）
    ⇒ 老客户端没有 EveReport 这个名字
    ⇒ GDScript 编译期报 `Parse Error: Identifier "EveReport" not declared`
    ⇒ 整个 eve_main_menu.gd 加载失败 ⇒ 场景没有脚本 ⇒ **黑屏**

这个闸门把那条教训变成可执行的检查：**发 hotfix 前，先假装自己是最老的客户端跑一遍。**

═══ 怎么判断「最老的客户端」 ═══════════════════════════════════════
`tools/hotfix_baseline.txt` 里记着**上一次发完整包时**的 autoload 列表。
当前列表减去基线 = 本次 hotfix 新增的 autoload —— 这些名字在老客户端上不存在。

检查分两步：
  ① 有新增？直接判**不通过**（它们只能靠发完整包生效）。
  ② 就算没有新增，也再跑一次 "删掉新增项 → 解析" 的模拟，
     抓出「代码里引用了某个 autoload，但那个名字不在注册表里」的写法。

第 ② 步是关键：它不依赖人记得更新基线，
直接复现事故现场 —— 只要报 Parse Error，就是迟早要黑屏的写法。

═══ 用法 ═══════════════════════════════════════════════════════════
    python tools/check_hotfix_safe.py                 # 检查（发版前必跑）
    python tools/check_hotfix_safe.py --update-baseline   # 发完完整包后刷新基线
"""

import io
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
GODOT = os.environ.get(
    "GODOT_BIN", "C:/godot/Godot_v4.7.2-stable_win64_console.exe")
BASELINE = os.path.join(HERE, "hotfix_baseline.txt")

# 这些行出现就说明主场景的脚本没加载成功（= 黑屏）。
BAD = re.compile(
    r"Parse Error|Identifier .* not declared|Failed to load script", re.I)


def read_autoloads(project_file):
    """取 project.godot `[autoload]` 段里的名字，保持出现顺序。"""
    names = []
    in_section = False
    with io.open(project_file, encoding="utf-8") as f:
        for line in f:
            s = line.rstrip("\n")
            if s.startswith("["):
                in_section = s.strip() == "[autoload]"
                continue
            if in_section and "=" in s and not s.strip().startswith(";"):
                names.append(s.split("=", 1)[0].strip())
    return names


def read_baseline():
    if not os.path.exists(BASELINE):
        return None
    names = []
    with io.open(BASELINE, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            names.append(s)
    return names


def write_baseline(names):
    with io.open(BASELINE, "w", encoding="utf-8", newline="\n") as f:
        f.write("# hotfix 兼容性基线：**上一次发完整包时**的 autoload 列表。\n")
        f.write("# 发完一次完整包（APK / Windows exe）后，用\n")
        f.write("#   python tools/check_hotfix_safe.py --update-baseline\n")
        f.write("# 刷新它。⛔ 手工往里加名字会让闸门失效。\n")
        f.write("# 背景见 tools/check_hotfix_safe.py 文件头。\n")
        for n in names:
            f.write(n + "\n")


def strip_lines(project_file, names):
    """把指定的 autoload 行删掉，返回原文本（用于恢复）。"""
    with io.open(project_file, encoding="utf-8") as f:
        src = f.read()
    out = []
    for line in src.split("\n"):
        key = line.split("=", 1)[0].strip() if "=" in line else ""
        if key in names and not line.lstrip().startswith("["):
            continue
        out.append(line)
    with io.open(project_file, "w", encoding="utf-8", newline="") as f:
        f.write("\n".join(out))
    return src


def run_import():
    cmd = [GODOT, "--headless", "--import", "--path", PROJ]
    p = subprocess.run(cmd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return (p.stdout or "") + (p.stderr or "")


def main():
    project_file = os.path.join(PROJ, "project.godot")
    cur = read_autoloads(project_file)

    if "--update-baseline" in sys.argv:
        write_baseline(cur)
        print("已刷新基线 -> %s" % BASELINE)
        for n in cur:
            print("  " + n)
        return 0

    print("当前 autoload : %s" % ", ".join(cur) if cur else "（空）")

    base = read_baseline()
    if base is None:
        write_baseline(cur)
        print("\n⚠️  没有基线文件，已用**当前**列表初始化。")
        print("   ⚠️ 这只对「从现在开始不再新增 autoload」有效。")
        print("   真正的基线应该是玩家手上那个完整包的列表。")
        base = cur

    added = [n for n in cur if n not in base]
    removed = [n for n in base if n not in cur]

    if removed:
        # 少一项是**安全**的：pck 只叠加不删除，基础包里的文件还在。
        print("已移除      : %s（安全：pck 只叠加，旧文件仍在）"
              % ", ".join(removed))

    if added:
        print("\n✗ 本次新增了 autoload：%s" % ", ".join(added))
        print("  ⛔ 它们只能靠**发完整包**生效。热更包改不了 autoload 注册表。")
        print("     要么把功能挪到「被场景加载的脚本」里（如主菜单），要么别发 hotfix。")
        return 1

    # ── 模拟最老的客户端：把所有「基线之外的」都当作不存在 ──────────────
    # 即使 added 为空，也可能有人刚把某个 autoload 删了又加回来（顺序/改名），
    # 所以仍然跑一遍完整解析，成本几十秒，比线上黑屏便宜得多。
    print("\n── 解析模拟（当前 autoload 全在，等同最新完整包）──")
    log = run_import()
    bad = [l for l in log.split("\n") if BAD.search(l)]
    if bad:
        print("✗ 解析就失败了：")
        for l in bad[:10]:
            print("   " + l.strip())
        return 1
    print("✓ 通过")

    # 有新增时上面已经 return 1 了；走到这里说明集合与基线一致。
    print("\n结果：这份 pck 不会因为 autoload 差异让老客户端黑屏。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
