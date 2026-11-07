#!/usr/bin/env bash
# =============================================================================
#  发布热更包（**增量**：只含 scripts/ + data/，不含 assets/）
#
#  为什么不是全量 pck
#  ----------------------------------------------------------------------------
#  实测全量 pck = **320 MB**（assets 占 304 MB），而增量包只有 **6 MB**。
#  服务器出网带宽 4 Mbps ⇒ 320MB 要 11 分钟/人，几十个玩家同时更新直接把带宽打满。
#  6 MB 只有 12 秒，这才是能用的。
#
#  ⚠️ 代价（必须知道）：
#    · **改美术资源没法热更**（贴图/音频/模型）⇒ 那种更新要重发整包到群里
#    · 删掉的脚本不会从旧包里消失（`load_resource_pack` 是叠加语义）
#      ⇒ 只要没人引用它就没影响，但别指望"删文件"能热更生效
#
#  用法：
#      tools/publish_hotfix.sh                    # 版本号读 project.godot
#      DRY_RUN=1 tools/publish_hotfix.sh          # 只打包+算哈希，不上传
#
#  产出：
#      <OUT_DIR>/EVE-hotfix-<版本>.pck            （本地留档）
#      build/version.json                          （服务器要的那份清单）
#      GitHub Release `hotfix-<版本>` 上的同名 asset
#
#  上传完之后还要让服务器拉下来（这一步需要 lighthouse 通道，见 docs/联机部署指南）
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "${SCRIPT_DIR}/.." && pwd)"

local_cfg() {
  local f="${SCRIPT_DIR}/pipeline/paths.local.json" key="$1"
  [ -f "${f}" ] || return 1
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${f}" | head -1
}

GODOT="${GODOT_BIN:-$(local_cfg godot_bin)}"
GODOT="${GODOT:-C:/godot/Godot_v4.7.2-stable_win64_console.exe}"
OUT_DIR="${OUT_DIR:-$(local_cfg export_dir)}"
REPO="${REPO:-xshynews/EVE-AutoChess}"
# 分发节点的公网地址（只出现在**运行时**的清单里，不入库成配置）
PUBLIC_BASE="${PUBLIC_BASE:-http://49.233.138.141}"

[ -n "${OUT_DIR}" ] || { echo "✗ 没指定输出目录：设 OUT_DIR 或写 export_dir 到 paths.local.json" >&2; exit 2; }
mkdir -p "${OUT_DIR}"

VER="$(sed -n 's/^config\/version="\(.*\)"/\1/p' "${PROJ}/project.godot" | head -1)"
[ -n "${VER}" ] || { echo "✗ 读不到 config/version" >&2; exit 2; }
CODE="$(sed -n 's/^version\/code=\([0-9]*\)/\1/p' "${PROJ}/export_presets.cfg" | head -1)"
[ -n "${CODE}" ] || { echo "✗ 读不到 export_presets.cfg 的 version/code" >&2; exit 2; }

PCK="${OUT_DIR}/EVE-hotfix-${VER}-b${CODE}.pck"

echo "版本 : ${VER} (code ${CODE})"
echo "输出 : ${PCK}"
echo ""

# ── build_info.json：客户端靠它决定要不要热更 ────────────────────────
# ⚠️ 必须**导出前**写好 —— 它会跟着 hotfix pck 一起打进去，
#    挂载后客户端读到的就是这份新版本号（`EveUpdater.build_info()`）。
cat > "${PROJ}/build_info.json" <<EOF
{
  "_note": "导出时由 tools/publish_hotfix.sh / export_release.sh 自动重写。客户端 EveUpdater 读它决定是否需要热更，别手改。",
  "version": "${VER}",
  "code": ${CODE}
}
EOF

rm -f "${PCK}"
"${GODOT}" --headless --path "${PROJ}" --export-pack "Hotfix" "${PCK}" > /tmp/hotfix_pack.log 2>&1
if [ ! -f "${PCK}" ]; then
  echo "✗ 打包失败：" >&2
  tail -20 /tmp/hotfix_pack.log >&2
  exit 1
fi

# ── 剥掉引擎强行塞进来的两个大件 ─────────────────────────────────────
#  `icudt_godot.dat`(4.58MB) 和 `icon.png`(81KB) **不受 exclude_filter 约束**
#  （实测：名字写进 exclude_filter 完全无效，照打不误）。但它们随 APK/EXE 一起
#  发过，客户端 res:// 里本来就有 —— pck 是叠加语义，不放也不会缺。
#  ★ 不剥的话 5.68MB 在 4Mbps 上要 12 秒，而**老客户端下载超时只有 6 秒**
#    （那个 bug 在 0.14.10 之后才修）⇒ 老客户端每次都下到一半被自己砍断。
#  剥完 1.02MB = 2.2 秒，才对所有版本都成立。
#
#  ★ 2026-11-07 追加：连 `.godot/imported/` 一起剥（`--drop-prefix`）。
#    那一坨是**导入产物**（.ctex 等），exclude_filter 里写了 `.godot/imported/*`
#    同样无效（跟 icudt 一个毛病）。平时不算大，但只要开发机跑过截图类验证脚本，
#    那些 png 即使后来删了、ctex 还留在 `.godot/imported/` 里，导出照打不误。
#    实测这天热更包从 1.02MB 涨到 24.44MB，多出来的 23.34MB 全是这种孤儿。
#    ⚠️ 只剥 `imported/`，别把整个 `.godot/` 剥了 —— 里面还有导出器要读的小文件。
PYBIN="${PYBIN:-C:/Users/Administrator/.workbuddy/binaries/python/envs/default/Scripts/python.exe}"
[ -x "${PYBIN}" ] || PYBIN="python"
"${PYBIN}" "${PROJ}/tools/pck_strip.py" "${PCK}" "${PCK}.tmp" \
  --drop-prefix ".godot/imported/" --list || {
  echo "✗ 热更包瘦身失败（见上）" >&2
  rm -f "${PCK}.tmp"
  exit 1
}
mv -f "${PCK}.tmp" "${PCK}"

# ⚠️ 体积闸：超过 8MB 说明有人把 assets 塞进来了（多半是 preset 的 exclude 被改坏）。
#    4000 个玩家 × 8MB 会把这台 4M 带宽的机器打死，所以这里**直接拒绝发布**。
SIZE=$(stat -c%s "${PCK}")
if [ "${SIZE}" -gt 8388608 ]; then
  echo "✗ 热更包 ${SIZE} 字节 > 8MB —— exclude_filter 可能失效（assets 被打进去了）。" >&2
  echo "  自查：python tools/pck_ls.py \"${PCK}\" 看前几名是谁" >&2
  exit 1
fi

SHA=$(sha256sum "${PCK}" | cut -d' ' -f1)
MB=$(awk -v s="${SIZE}" 'BEGIN{printf "%.2f", s/1048576}')

echo "体积 : ${SIZE} 字节（${MB} MB）"
echo "SHA256 : ${SHA}"
echo ""

# ── version.json：服务器上的那份清单 ─────────────────────────────────
#  ⚠️ 包**不放自己的服务器**了（2026-10-30 定）：分发节点只有 4 Mbps 出网，
#    二十几个玩家同时拉 6 MB 就能把带宽吃干，那不是攻击，是正常发版。
#    现在包挂 GitHub Release，玩家从加速站拉；自己的机器只发这份几百字节的清单。
#  ⚠️ 必须留 `urls` 里的**自建兜底**：加速站是第三方，说挂就挂，不能单点。
#  ⚠️ `url`（单值）是给 0.14.10 那批**已发出去**的老客户端读的 ——
#    它们只认识 `url`，**没有多源回退能力**，所以必须指向最可靠的那个：
#    自建节点（实测 506 KB/s 稳定）。指向加速站的话，加速站一挂，
#    老客户端就永远收不到更新了（还不报错，只是静默不更）。
#  ⚠️ `urls` 是给带多源能力的新客户端用的，顺序 = 免带宽优先：
#    先试加速站（通了就不占自己带宽），失败/超时 15 秒后回自建。
#    ★ 2026-10-31 实测（**从服务器上量**，这才是玩家真实的网络位置）：
#      ghfast.top  → 连 443 直接 15 秒超时（连续两轮发版都挂）
#      gh-proxy.com→ 862 KB/s，1.04MB 用 1.27 秒
#    所以首选源换成 gh-proxy.com。
#    ⚠️ 这里踩过一个坑：URL 写错不会在任何一步报错 —— 服务器 `curl -f` 会失败、
#       脚本照样往下走，玩家端只是"静默回退到自建"，看起来一切正常。
#       ⇒ 换加速站之后**必须在服务器上真拉一遍**（见脚本末尾的步骤 1）。
TAG="hotfix-${VER}-b${CODE}"
GH_URL="https://gh-proxy.com/https://github.com/${REPO}/releases/download/${TAG}/EVE-hotfix-${VER}-b${CODE}.pck"
SELF_URL="${PUBLIC_BASE}/update/pck/EVE-hotfix-${VER}-b${CODE}.pck"

mkdir -p "${PROJ}/build"
cat > "${PROJ}/build/version.json" <<EOF
{
  "version": "${VER}",
  "code": ${CODE},
  "channel": "stable",
  "notes": "scripts and data update (no assets)",
  "pck": {
    "urls": [
      "${GH_URL}",
      "${SELF_URL}"
    ],
    "url": "${SELF_URL}",
    "size": ${SIZE},
    "sha256": "${SHA}"
  },
  "relay": "49.233.138.141:27100"
}
EOF

echo "清单 : build/version.json"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo ""
  echo "DRY_RUN=1 ⇒ 不推 GitHub。"
  exit 0
fi

# ── 推到 GitHub Release（服务器从那里拉，比接口传文件可靠）────────────
# ⚠️ 必须走代理：直连 github 经常 CONNECT tunnel failed（见项目记忆）。
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:10808}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:10808}"

if gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
  echo "Release ${TAG} 已存在 ⇒ 覆盖上传 asset"
  gh release upload "${TAG}" "${PCK}" --repo "${REPO}" --clobber
else
  gh release create "${TAG}" "${PCK}" --repo "${REPO}" \
    --title "热更包 V${VER}（脚本+数值，不含美术）" \
    --notes "增量热更包：仅 scripts/ 与 data/，不含 assets。

SHA256: ${SHA}
大小: ${MB} MB" --latest=false
fi

echo ""
echo "✓ 已上传 https://github.com/${REPO}/releases/tag/${TAG}"
echo ""
echo "下一步（把包和清单送到服务器）："
echo "  1) 服务器拉包（⛔ 别直连 github：实测只有 2.8 KB/s，必须走 gh-proxy.com 加速）："
echo "     wget -O /var/www/eve/update/pck/EVE-hotfix-${VER}-b${CODE}.pck \\"
echo "       https://gh-proxy.com/https://github.com/${REPO}/releases/download/${TAG}/EVE-hotfix-${VER}-b${CODE}.pck"
echo "     拉完必须对一遍 SHA256：${SHA}"
echo "  2) 把 build/version.json 覆盖到 /var/www/eve/update/version.json"
echo "     ⚠️ 该清单的 notes 已写成英文（lighthouse 通道拒绝含中文的命令）"
echo "  3) 验收：curl -s http://127.0.0.1/update/version.json 应看到 code=${CODE}"
