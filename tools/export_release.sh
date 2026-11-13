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
# ── 为什么签名走环境变量 ──────────────────────────────────────────────
#  Godot 的 Android 签名字段（`keystore/debug*` + `keystore/release*` 共 6 行）
#  里带本机绝对路径和口令，不能入库 —— 开源的 preset 必须一处本机路径都没有。
#
#  [PITFALL] 2026-11-12：以前是「临时把这 6 行注入 cfg → 导出 → trap 还原」，
#    在 Godot 4.7.2 上**已失效**。keystore/* 现在带 PROPERTY_USAGE_SECRET，
#    读取走 `get_or_env()`，明文写进 cfg 读回来是空 ⇒ 报「找不到发布密钥库」。
#    （详见下面「签名」段的注释）
#
#  现在的做法：`export GODOT_ANDROID_KEYSTORE_*` 六个环境变量。
#  ⇒ cfg 永远不被改，仓库保持干净，也不会再出现"导出中途失败留下脏 cfg"。
#
#  ⚠️ 用的是 Godot 自带的 debug.keystore（别名 androiddebugkey / 口令 android）。
#     历史包（V0.14.6 起）签名证书 SHA-256 全是 db34b12b…，换密钥 = 老用户
#     无法覆盖安装（只能卸载重装，存档全丢）。
#  ⚠️ 在编辑器里「项目 → 导出」手动打包时没有这些环境变量 ⇒ Android 会报
#     「Release keystore not configured」。要么用本脚本，要么在导出面板里填。
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
#    虽然 Godot 多半能吃，但统一成正斜杠省事。
APPDATA_DIR="${APPDATA_DIR//\\//}"
KEYSTORE="${KEYSTORE_PATH:-$(local_cfg keystore_path)}"
KEYSTORE="${KEYSTORE:-${APPDATA_DIR}/Godot/keystores/debug.keystore}"
if [ ! -f "${KEYSTORE}" ]; then
  echo "✗ 找不到 keystore：${KEYSTORE}" >&2
  echo "  Godot 首次导出 Android 时会自动生成 debug.keystore；" >&2
  echo "  或把 keystore_path 写进 tools/pipeline/paths.local.json。" >&2
  exit 2
fi
KS_USER="${KEYSTORE_USER:-$(local_cfg keystore_user)}"
KS_USER="${KS_USER:-androiddebugkey}"
KS_PASS="${KEYSTORE_PASSWORD:-$(local_cfg keystore_password)}"
KS_PASS="${KS_PASS:-android}"

# ── 签名：走环境变量，⛔ 不要往 export_presets.cfg 里写这 6 行 ──────────
#
# [PITFALL] 2026-11-12 实测：老做法（把 keystore/* 六行注入 cfg、导完再 trap 还原）
#   在 Godot 4.7.2 上**已经失效**，症状是导出时报
#       ERROR: 代码签名: 找不到发布密钥库，无法导出。
#   但 keystore 文件确实存在、cfg 里字段也写得对。
#
#   根因（platform/android/export/export_plugin.cpp + .h）：
#     · keystore/* 注册时带 PROPERTY_USAGE_SECRET；
#     · 读取走 `p_preset->get_or_env("keystore/release", ENV_..._RELEASE_PATH)`；
#     · SECRET 字段的明文写进 export_presets.cfg **读不回来**（读到空）
#       ⇒ FileAccess::exists("") 为 false ⇒ 报上面那句。
#
#   正路就是下面这 6 个环境变量（官方注释：环境变量优先，覆盖凭据文件）。
#   顺带把「临时改 cfg 再还原」这套脆做法整个删了 —— cfg 现在永远不用被改，
#   仓库里也就不可能出现本机路径（2026-10-29 定的红线）。
export GODOT_ANDROID_KEYSTORE_DEBUG_PATH="${KEYSTORE}"
export GODOT_ANDROID_KEYSTORE_DEBUG_USER="${KS_USER}"
export GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD="${KS_PASS}"
export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="${KEYSTORE}"
export GODOT_ANDROID_KEYSTORE_RELEASE_USER="${KS_USER}"
export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="${KS_PASS}"

echo "版本      : ${VER}"
echo "引擎      : ${GODOT}"
echo "输出      : ${OUT_DIR}"
echo "签名库    : ${KEYSTORE}（别名 ${KS_USER}）"
echo ""

fail=0
# [WHY] 2026-11-12：原来只 grep "SCRIPT ERROR|Parse Error"，而签名失败时
#   Godot 打的是「ERROR: 代码签名: 找不到发布密钥库，无法导出。」+「Project export
#   for preset "Android" failed.」—— 一个都不命中，于是脚本只会含糊地说
#   「APK 没生成」，看不出是签名问题（我就被这个绕了一圈）。
BADPAT="SCRIPT ERROR|Parse Error|无法导出|Project export for preset"
echo "── Android ──"
if "${GODOT}" --headless --path "${PROJ}" --export-release "Android" "${APK}" 2>&1 \
        | tee /tmp/exp_apk.log | grep -qE "${BADPAT}"; then
  echo "✗ APK 导出失败（错误行见下）"
  grep -m5 -E "${BADPAT}" /tmp/exp_apk.log
  fail=1
fi
[ -f "${APK}" ] && echo "✓ ${APK}（$(du -m "${APK}" | cut -f1) MB）" || { echo "✗ APK 没生成"; fail=1; }

echo "── Windows ──"
if "${GODOT}" --headless --path "${PROJ}" --export-release "Windows" "${EXE}" 2>&1 \
        | tee /tmp/exp_exe.log | grep -qE "${BADPAT}"; then
  echo "✗ EXE 导出失败"
  grep -m5 -E "${BADPAT}" /tmp/exp_exe.log
  fail=1
fi
[ -f "${EXE}" ] && echo "✓ ${EXE}（$(du -m "${EXE}" | cut -f1) MB）" || { echo "✗ EXE 没生成"; fail=1; }

echo ""
if [ "${fail}" -eq 0 ]; then
  echo "导出完成 ✅（export_presets.cfg 未被改动）"
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
