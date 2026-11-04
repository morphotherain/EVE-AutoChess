# -*- coding: utf-8 -*-
"""把系统里的 Noto Sans SC（OFL 授权）裁剪成只含本工程实际用到的字符。

[WHY] 网页版没有系统字体，SystemFont 会退化成无中文字形的默认字体 ⇒ 全站乱码。
      整包字体 17 MB 又太重，所以按工程里真实出现的字符做子集化。
[NOTE] 字符来源必须覆盖「运行时会显示但源码里没有」的部分 —— 舰船名/羁绊名
       来自 data/ 下的 csv，所以 data 目录也要扫。
用法：python subset_font.py <源字体ttf> <工程根目录> <输出目录>
"""
import os
import re
import sys

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

SRC = sys.argv[1]
ROOT = sys.argv[2]
OUTDIR = sys.argv[3]

SCAN_DIRS = ["scripts", "scenes", "i18n", "data", "assets/ui"]
SCAN_EXT = (".gd", ".tscn", ".csv", ".json", ".tres", ".cfg", ".godot")

chars = set()
for d in SCAN_DIRS:
    base = os.path.join(ROOT, d)
    if not os.path.isdir(base):
        continue
    for dirpath, _, files in os.walk(base):
        for fn in files:
            if not fn.endswith(SCAN_EXT):
                continue
            try:
                txt = open(os.path.join(dirpath, fn), encoding="utf-8", errors="ignore").read()
            except OSError:
                continue
            chars.update(txt)

# 只保留基本 ASCII 可打印字符 + 所有非 ASCII（汉字、全角标点、·—… 等）
keep = {"".join(chr(c) for c in range(0x20, 0x7F))}
for ch in chars:
    o = ord(ch)
    if o > 0x7F:
        keep.add(ch)

# 兜底：常用中文标点与几个常见符号，防止动态拼接的文案缺字
keep.update("　·—…、。，！？“”‘’（）《》【】％＋－×÷≥≤→←↑↓★☆■□●○✓✗")
text = "".join(sorted(keep))
print(f"字符数 {len(text)}（含 ASCII 95）")

os.makedirs(OUTDIR, exist_ok=True)

for weight, name in ((400, "NotoSansSC-Regular.ttf"), (700, "NotoSansSC-Bold.ttf")):
    font = TTFont(SRC)
    if "fvar" in font:
        instantiateVariableFont(font, {"wght": weight}, inplace=True)
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    opts.recalc_bounds = True
    sub = subset.Subsetter(options=opts)
    sub.populate(text=text)
    sub.subset(font)
    out = os.path.join(OUTDIR, name)
    font.save(out)
    print(f"{name}  {os.path.getsize(out)/1024:.0f} KB")
