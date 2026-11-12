#!/usr/bin/env bash
# =============================================================================
#  一键导出发布包（Android APK + Windows EXE）
#
#  用法：
#      tools/export_release.sh                       # 输出目录取本机配置
#      OUT_DIR="/somewhere/游戏版本" tools/export_release.sh
#      GODOT_BIN=/path/to/godot tools/export_release.sh
#
#  输出目录优先级：OUT_DIR → tools/pipeline/paths.local.json 的 `export_dir`
#  ⛔ 仓库里**不写死**任何本机路径（2026-10-29 用户定死：「GitHub 上不能出现
#     本机绝对路径，会被指假开源」）。所以默认目录只能来自未入库的 local.json。
#
#  版本号：直接读 project.godot 的 `config/version`，文件名拼成
#          `<OUT_DIR>/EVE自走棋正式版V<版本>.apk` / `.exe`
#          ⚠️ 版本号本身仍是**手工**改的两处（project.godot 与 export_presets.cfg，
#             后者还要 `version/code` 递增，Android 覆盖安装靠它）。
#
# ── 为什么签名要在这里临时注入 ────────────────────────────────────────
#  Godot 的 Android 签名字段（`keystore/debug*` + `keystore/release*` 共 6 行）
#  **只能填绝对路径**，而绝对路径里带本机用户名、口令也是明文。
#  ⇒ 那 6 行不能入库。开源的 preset 里必须一处本机路径都没有。
#  做法：本脚本注入 → 导出 → **无论成败都还原**（trap）。所以导出完 cfg 还是干净的。
#
#  ⚠️ 用的是 Godot 自带的 debug.keystore（别名 androiddebugkey / 口令 android）。
#     历史包（V0.14.6 起）签名证书 SHA-256 全是 db34b12b…，换密钥 = 老用户
#     无法覆盖安装（只能卸载重装，存档全丢）。
#  ⚠️ 用编辑器「项目 → 导出」手动打包时，这 6 行不在 cfg 里 ⇒ Android 会报
#     「Release keystore not configured」。要么用本脚本，要么自己在导出面板里填。
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "${SCRIPT_DIR}/.." && pwd)"
CFG="${PROJ}/export_presets.cfg"

# ── 引擎 ─────────────────────────────────────────────────────────────
local_cfg() {
  local f="${SCRIPT_DIR}/pipeline/paths.local.json" key="$1"
  [ -f "${f}" ] || return 1
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${f}" | head -1
}
GODOT="${GODOT_BIN:-$(local_cfg godot_bin)}"
GODOT="${GODOT:-C:/godot/Godot_v4.7.2-stable_win64_console.exe}"
[ -x "${GODOT}" ] || command -v "${GODOT}" >/dev/null 2>&1 || {
  echo "✗ 找不到 Godot：请设 GODOT_BIN 或写进 tools/pipeline/paths.local.json 的 godot_bin" >&2
  exit 2
}

# ── 输出目录 ─────────────────────────────────────────────────────────
OUT_DIR="${OUT_DIR:-$(local_cfg export_dir)}"
if [ -z "${OUT_DIR}" ]; then
  echo "✗ 没指定输出目录：设 OUT_DIR，或把 export_dir 写进 tools/pipeline/paths.local.json" >&2
  exit 2
fi
mkdir -p "${OUT_DIR}"

# ── 版本号 ───────────────────────────────────────────────────────────
VER="$(sed -n 's/^config\/version="\(.*\)"/\1/p' "${PROJ}/project.godot" | head -1)"
[ -n "${VER}" ] || { echo "✗ project.godot 里读不到 config/version" >&2; exit 2; }

NAMESPACE="EVE自走棋正式版V${VER}"
APK="${OUT_DIR}/${NAMESPACE}.apk"
EXE="${OUT_DIR}/${NAMESPACE}.exe"

# ── 签名库 ───────────────────────────────────────────────────────────
APPDATA_DIR="${APPDATA:-${HOME}/AppData/Roaming}"
# ⚠️ Windows 的 %APPDATA% 是反斜杠（C:\Users\x\AppData\Roaming），
#    直接拼会写出 `C:\Users\x\AppData\Roaming/Godot/...` 这种混合斜杠。
#    虽然 Godot 多半能吃，但 cfg 是要给所有人看的东西，统一成正斜杠。
APPDATA_DIR="${APPDATA_DIR//\\//}"
KEYSTORE="${APPDATA_DIR}/Godot/keystores/debug.keystore"
if [ ! -f "${KEYSTORE}" ]; then
  echo "✗ 找不到 debug.keystore：${KEYSTORE}" >&2
  echo "  Godot 首次导出 Android 时会自动生成；没有就先在编辑器里导出一次。" >&2
  exit 2
fi

echo "版本      : ${VER}"
echo "引擎      : ${GODOT}"
echo "输出      : ${OUT_DIR}"
echo "签名库    : ${KEYSTORE}"
echo ""

BAK="$(mktemp)"
cp "${CFG}" "${BAK}"
cleanup() { cp "${BAK}" "${CFG}"; rm -f "${BAK}"; }
trap cleanup EXIT INT TERM

# 注入 6 行到 Android preset 的 options 段（已存在就跳过）
python - "${CFG}" "${KEYSTORE}" <<'PY'
import io, sys
cfg, ks = sys.argv[1], sys.argv[2]
s = io.open(cfg, encoding="utf-8", newline="").read()
if "keystore/debug=" in s:
    sys.exit(0)
lines = s.split("\n")
block = [
    'keystore/debug="%s"' % ks,
    'keystore/debug_user="androiddebugkey"',
    'keystore/debug_password="android"',
    'keystore/release="%s"' % ks,
    'keystore/release_user="androiddebugkey"',
    'keystore/release_password="android"',
]
for i, l in enumerate(lines):
    if l.strip() == "[preset.0.options]":
        lines[i + 1:i + 1] = block
        break
else:
    sys.exit("找不到 [preset.0.options]，preset 结构变了？")
io.open(cfg, "w", encoding="utf-8", newline="").write("\n".join(lines))
PY
[ $? -eq 0 ] || { echo "✗ 注入签名失败" >&2; exit 1; }

fail=0
echo "── Android ──"
if "${GODOT}" --headless --path "${PROJ}" --export-release "Android" "${APK}" 2>&1 \
        | tee /tmp/exp_apk.log | grep -qE "SCRIPT ERROR|Parse Error"; then
  echo "✗ APK 导出时出现脚本错误（导出并不会因此中止，包是坏的）"
  grep -m5 -E "SCRIPT ERROR|Parse Error" /tmp/exp_apk.log
  fail=1
fi
[ -f "${APK}" ] && echo "✓ ${APK}（$(du -m "${APK}" | cut -f1) MB）" || { echo "✗ APK 没生成"; fail=1; }

echo "── Windows ──"
if "${GODOT}" --headless --path "${PROJ}" --export-release "Windows" "${EXE}" 2>&1 \
        | tee /tmp/exp_exe.log | grep -qE "SCRIPT ERROR|Parse Error"; then
  echo "✗ EXE 导出时出现脚本错误"
  grep -m5 -E "SCRIPT ERROR|Parse Error" /tmp/exp_exe.log
  fail=1
fi
[ -f "${EXE}" ] && echo "✓ ${EXE}（$(du -m "${EXE}" | cut -f1) MB）" || { echo "✗ EXE 没生成"; fail=1; }

echo ""
if [ "${fail}" -eq 0 ]; then
  echo "导出完成 ✅（preset 里的签名行已还原，仓库保持干净）"
  echo ""
  echo "  完整包已落在：${OUT_DIR}"
  echo "    ${NAMESPACE}.apk"
  echo "    ${NAMESPACE}.exe"
  echo ""
  # [WHY] 2026-11-12：完整包和热更包是两条路，交叉点只有「autoload 列表」。
  #       发完完整包不刷基线 ⇒ 下次热更会被闸门拦住（多一步人工判断）；
  #       反过来，没发完整包就刷基线 ⇒ 闸门失效 ⇒ 老客户端黑屏（b39）。
  #       所以把「发完要刷基线」挂在导出成功这条路径上，而不是靠记忆。
  echo "  下一步："
  echo "    1) 把这两个包发出去，确认玩家能装上、能进主菜单"
  echo "    2) python tools/check_hotfix_safe.py --update-baseline"
  echo "       ⛔ 顺序不能反：基线记的是「玩家手上那个包」的 autoload 列表。"
  echo "    3) 之后才轮得到 tools/publish_hotfix.sh 发热更"
else
  echo "有失败项 ❌"
fi
exit "${fail}"
