#!/usr/bin/env bash
# 一键出「自走棋试玩」网页版（PVE 任务关卡 · 单机）。
#
# 与 build_web.sh（斗地主）的区别：
#   ① 主场景 = battle_scene，**打开就是战场** —— 网页试玩没有主菜单这一步，
#      落地页的「试玩」点进来直接能开打。
#   ② 资源白名单不同：要 52 艘船的 glb + 贴图 + 战斗音效，但**不要**卡牌、
#      开场视频、多余 BGM。（体积差 250MB vs 100MB）
#   ③ 引擎侧靠 `OS.has_feature("web")` 做三件事（都在脚本里，不在这里）：
#      · 跳过开场剧情（`eve_main_menu.target_scene_for_start`）
#      · 开局送 3 艘船并上阵（`eve_battle_scene._seed_web_starter_fleet`）
#      · 联机走 WebSocket 中继（`ddz_room._use_ws`）
#
# 用法：bash tools/build_web_pve.sh [Godot可执行文件路径]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${1:-C:/godot/Godot_v4.7.2-stable_win64_console.exe}"
PY="C:/Users/Administrator/.workbuddy/binaries/python/envs/default/Scripts/python.exe"
OUT="$ROOT/build/web_pve"
BAK="$ROOT/project.godot.bak-pve"

[ -f "$GODOT" ] || { echo "找不到 Godot：$GODOT"; exit 1; }

restore() {
	if [ -f "$BAK" ]; then
		mv -f "$BAK" "$ROOT/project.godot"
	fi
	"$PY" "$ROOT/tools/probe_web_preset.py" restore >/dev/null 2>&1 || true
	# 贴图尺寸也要还原，否则下一次桌面版导出会带着网页档的糊贴图
	"$PY" "$ROOT/tools/pipeline/web_tex_downscale.py" restore >/dev/null 2>&1 || true
}
trap restore EXIT INT TERM

# ── ⓿ 舰船贴图降采样（只作用于本次构建）─────────────────────────
# [WHY] 2048×1024 × 156 张按 VRAM 压缩后占 159 MB，而棋盘上的船只有一两百像素。
#       压到 512 长边后同样 52 艘只要 ~18 MB ⇒ 包体省 140 MB。
#       ⚠️ 必须在**导出之前**改 + 重新导入，导出读的是 .godot/imported 缓存。
echo "[build_web_pve] ① 压缩舰船贴图…"
"$PY" "$ROOT/tools/pipeline/web_tex_downscale.py" apply
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1

# ── ① 临时改 Web 预设的资源口径 ────────────────────────────────
# [WHY] 导出预设存在 export_presets.cfg（git 跟踪、桌面/安卓共用），
#       直接改文件会污染其它平台的发布配置 ⇒ 用工具改、trap 还原。
# [NOTE] `all_resources` + 黑名单：之前用纯白名单漏了 assets/vfx，
#       导致 `eve_shield_impact.gd` 的 preload 失败、整条编译链崩掉。
#       黑名单只会「少带资源」，不会「带到不存在的路径」。
# ⚠️ `build/*` 必须排掉：调试截图（web_shot.py 的产物）会被 `--import`
#    当成资源生成 .import，然后 all_resources 把它们一起打进 pck。
#    实测混进 1 MB 无关截图，且每次截图都改包体 ⇒ 只会在发布时才发现。
"$PY" "$ROOT/tools/probe_web_preset.py" apply \
	'scripts/*, data/*' \
	'"res://scenes/battle_scene.tscn", "res://scenes/main_menu.tscn"' \
	'all_resources' \
	'assets/audio_candidates/*, assets/video/*, assets/beacon/*, disk-cleaner/*, tools/*, build/*, assets/cards/*, assets/audio/music/battle_02.ogg, assets/audio/music/border_01.ogg, assets/audio/music/border_final_01.ogg, assets/audio/music/ddz_01.ogg, assets/audio/music/lantern_01.ogg, assets/audio/music/prep_02.ogg'

# ── ② 主场景换成本场景 ─────────────────────────────────────────
# ⚠️ 备份必须在 sed **之前** —— 备份到的是「改完主场景」的版本的话，
#    第 ③ 步还原回来的还是 battle_scene，桌面版下次启动就进战场了。
cp "$ROOT/project.godot" "$BAK"
sed -i 's|run/main_scene="res://scenes/main_menu.tscn"|run/main_scene="res://scenes/battle_scene.tscn"|' "$ROOT/project.godot"

mkdir -p "$OUT"
"$GODOT" --headless --path "$ROOT" --export-release "Web" "build/web_pve/index.html"

# ── ③ 还原工程 ─────────────────────────────────────────────────
# 导出会把 MCPRuntimeProbe 这个 autoload 删掉（累计第 5 次复现），必须还原。
# 贴图尺寸也要还原 + 重导入 —— 否则 .godot/imported 里留着的是网页档的小图，
# 下次桌面版导出会直接拿它打包，桌面画质就**悄悄降级**了。
cp "$BAK" "$ROOT/project.godot"
rm -f "$BAK"
"$PY" "$ROOT/tools/probe_web_preset.py" restore >/dev/null 2>&1 || true
echo "[build_web_pve] ③ 还原贴图并重建桌面档导入缓存（约 20s）…"
"$PY" "$ROOT/tools/pipeline/web_tex_downscale.py" restore
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1

# ── ④ 左上角回落地页的入口 ─────────────────────────────────────
# ⚠️ 每次导出都会被模板覆盖，只能在构建脚本里注入。
# ⚠️⚠️ sed 替换串里的 `&` 表示整个匹配，必须转义成 `\&`。
RETURN_LINK='<a href="/" style="position:fixed;left:14px;top:12px;z-index:9;padding:7px 14px;border-radius:999px;background:rgba(10,18,30,.72);border:1px solid rgba(120,160,220,.34);color:#BFD3EF;font:13px/1.2 system-ui,-apple-system,sans-serif;text-decoration:none;backdrop-filter:blur(6px);-webkit-backdrop-filter:blur(6px)">&#8592; &#36820;&#22238;&#32593;&#39029;</a>'
RETURN_LINK_ESC=${RETURN_LINK//&/\\&}
sed -i "s|</body>|$RETURN_LINK_ESC</body>|" "$OUT/index.html"

# ── ⑤ wasm 预压缩（Caddy 开了 precompressed gzip）──────────────
gzip -9 -c "$OUT/index.wasm" > "$OUT/index.wasm.gz"

echo "--- 产物 ---"
ls -lh "$OUT" | awk '{print $5, $9}'
echo "首屏实际传输 ≈ $(du -cm "$OUT/index.wasm.gz" "$OUT/index.pck" | tail -1 | cut -f1) MB"
