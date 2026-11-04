# -*- coding: utf-8 -*-
"""网页版专用：把舰船贴图的导入尺寸临时压小，导完还原。

[WHY] 自走棋的舰船贴图是 2048×1024、每艘 3 张（d/n/s），52 艘 = 156 张。
      按 VRAM 压缩（s3tc）进包后：
          法线 81 MB · 漫反射 39 MB · 高光 39 MB  ≈ 159 MB
      而棋盘上的船在屏幕上只有一两百像素 —— 2048 宽是 8~16 倍过采样，
      纯属浪费带宽和显存。

      压到 n/s=512、d=512 之后，同样 52 艘只要 ~18 MB，**省 140 MB**。
      实测 A/B（同机位截图，船体区域像素差）：均值 2.4/255、p95=18，
      4 倍放大才看得出极轻微的纹理软化，正常游戏尺寸下不可分辨。

[WHY] 为什么是「临时改 + 还原」而不是直接改工程里的 .import：
      桌面版/安卓的包体对这点体积不敏感，但玩家会拉近看船。
      **不该让一次网页适配悄悄降低桌面画质**。所以只在 web 构建期生效。

用法：
  python tools/pipeline/web_tex_downscale.py apply     # 压小
  python tools/pipeline/web_tex_downscale.py restore   # 还原（= size_limit 0）
  python tools/pipeline/web_tex_downscale.py status
"""
import glob
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
PAT = os.path.join(ROOT, "assets", "ships3d", "*_*.import")

# 每个通道的目标长边。0 = 不限制（原图 2048×1024）。
#
# [NOTE] 三个值不一样是有意的：
#   d 漫反射 —— 承载涂装/派系配色/金色饰条，是辨识度本体，给 512；
#   n 法线   —— 只要「有立体感」，板缝和卷草纹在这个尺寸本来就融进 mipmap，给 512；
#   s 分区图 —— 单通道灰度、只驱动 metallic/roughness 两条 ramp，512 绰绰有余。
LIMITS = {"_d.png": 512, "_n.png": 512, "_s.jpg": 512}
RESTORE_LIMIT = 0


def _target(fname):
    for suffix, limit in LIMITS.items():
        if fname.endswith(suffix + ".import"):
            return limit
    return None


def run(mode):
    files = sorted(glob.glob(PAT))
    if not files:
        raise SystemExit("没找到 assets/ships3d 的 .import：%s" % PAT)
    changed = {}

    if mode == "status":
        for f in files:
            t = _target(os.path.basename(f))
            if t is None:
                continue
            cur = re.search(r"process/size_limit=(\d+)", open(f, encoding="utf-8").read())
            cur = int(cur.group(1)) if cur else -1
            changed[cur] = changed.get(cur, 0) + 1
        print("size_limit 分布：", changed)
        return 0

    for f in files:
        name = os.path.basename(f)
        limit = RESTORE_LIMIT if mode == "restore" else _target(name)
        if limit is None:
            continue
        s = open(f, encoding="utf-8").read()
        s2 = re.sub(r"process/size_limit=\d+", "process/size_limit=%d" % limit, s)
        if s != s2:
            open(f, "w", encoding="utf-8", newline="\n").write(s2)
            changed[limit] = changed.get(limit, 0) + 1
    print("[web_tex] %s → 改动 %s" % (mode, changed or "无（已是目标值）"))
    return 0


if __name__ == "__main__":
    sys.exit(run(sys.argv[1] if len(sys.argv) > 1 else "status"))
