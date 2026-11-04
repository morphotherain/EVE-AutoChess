#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""只改 export_presets.cfg 里 [preset.3] Web 段，不动其它 preset。

[WHY] 体积探针要临时把 Web 包的资源白名单换成「自走棋试玩」口径，
      导完必须原样写回。用 configparser 会破坏 Godot 的 cfg 方言
      （重复键 / 未转义的 PackedStringArray），所以只能按行文本替换。

用法：
  python tools/probe_web_preset.py apply <include> <files>
  python tools/probe_web_preset.py restore
"""
import os
import shutil
import sys

CFG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "export_presets.cfg")
BAK = CFG + ".probe-bak"


def _load_span(lines):
    """返回 [preset.3] 段的 [起, 止) 行号。"""
    start = None
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s == "[preset.3]":
            start = i
        elif start is not None and s.startswith("[") and s.endswith("]"):
            return start, i
    if start is None:
        raise SystemExit("找不到 [preset.3]")
    return start, len(lines)


def apply(include, files, export_filter=None, exclude=None):
    if not os.path.exists(BAK):
        shutil.copy2(CFG, BAK)
    with open(CFG, "r", encoding="utf-8") as f:
        lines = f.readlines()
    a, b = _load_span(lines)
    hit_inc = hit_files = False
    for i in range(a, b):
        if lines[i].startswith("include_filter="):
            lines[i] = 'include_filter="%s"\n' % include
            hit_inc = True
        elif lines[i].startswith("export_files="):
            lines[i] = 'export_files=PackedStringArray(%s)\n' % files
            hit_files = True
        elif export_filter is not None and lines[i].startswith("export_filter="):
            lines[i] = 'export_filter="%s"\n' % export_filter
        elif exclude is not None and lines[i].startswith("exclude_filter="):
            lines[i] = 'exclude_filter="%s"\n' % exclude
    if not (hit_inc and hit_files):
        raise SystemExit("include_filter / export_files 没找到：%s %s" % (hit_inc, hit_files))
    with open(CFG, "w", encoding="utf-8", newline="\n") as f:
        f.writelines(lines)
    print("[probe] preset.3 已临时改写")


def restore():
    if os.path.exists(BAK):
        shutil.move(BAK, CFG)
        print("[probe] export_presets.cfg 已还原")
    else:
        print("[probe] 无备份，跳过")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "apply":
        apply(sys.argv[2], sys.argv[3],
              sys.argv[4] if len(sys.argv) > 4 else None,
              sys.argv[5] if len(sys.argv) > 5 else None)
    else:
        restore()
