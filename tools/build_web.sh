#!/usr/bin/env bash
# 一键出「斗地主网页试玩版」。
#
# [WHY] 网页版必须以 doudizhu.tscn 当主场景，且不能带 MCPRuntimeProbe 这个调试
#       autoload（它的脚本不在导出白名单里，进包就报 "Failed to load autoload"）。
#       这两处都得临时改 project.godot，导完必须还原，否则下次发版会带着改坏的主场景。
# [NOTE] 用 trap 还原，中途失败也不会把工程改脏。
#
# 用法：bash tools/build_web.sh [Godot可执行文件路径]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${1:-C:/godot/Godot_v4.7.2-stable_win64_console.exe}"
OUT="$ROOT/build/web"
BAK="$ROOT/project.godot.bak-web"

[ -x "$GODOT" ] || [ -f "$GODOT" ] || { echo "找不到 Godot：$GODOT"; exit 1; }

restore() {
	if [ -f "$BAK" ]; then
		mv -f "$BAK" "$ROOT/project.godot"
		echo "[build_web] project.godot 已还原"
	fi
}
trap restore EXIT INT TERM

cp "$ROOT/project.godot" "$BAK"
sed -i 's|run/main_scene="res://scenes/main_menu.tscn"|run/main_scene="res://scenes/doudizhu.tscn"|' "$ROOT/project.godot"
sed -i '/^MCPRuntimeProbe=/d' "$ROOT/project.godot"

mkdir -p "$OUT"
"$GODOT" --headless --path "$ROOT" --export-release "Web" "build/web/index.html"

# [WHY] Caddy 开了 precompressed gzip：有 index.wasm.gz 就直接吐压缩版，
#       38MB → 9.7MB，4Mbps 的机器上首屏能少等半分钟。
gzip -9 -c "$OUT/index.wasm" > "$OUT/index.wasm.gz"

echo "--- 产物 ---"
ls -lh "$OUT" | awk '{print $5, $9}'
echo "首屏实际传输 ≈ $(du -cm "$OUT/index.wasm.gz" "$OUT/index.pck" | tail -1 | cut -f1) MB（gzip 后）"
