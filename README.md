# EVE 自走棋 (EVE Auto-Chess)

一款以 EVE 题材为背景的**开源自走棋**（auto-battler），使用 **Godot 4** + **GDScript** 开发，支持 **Windows / Android** 双端。

- 3D 战斗、无格子布阵，52 艘舰船（4 派系 × 13 艘），吨位 1~5 档对应舰船体型档位
- 4 派系羁绊、打捞、信标、事件四选一等玩法
- 主玩法「守卫边境」PVE 流程 + 内置「娱乐总汇 · 斗地主」小游戏
- 五分区设置（分辨率 / 音频 / 界面缩放 / 字号 / 平台 UI 缩放）、非 16:9 自动居中

## 引擎与平台

| 项 | 版本 / 说明 |
|---|---|
| 引擎 | Godot **4.7.2**（导出模板需与引擎同号） |
| 语言 | GDScript |
| 桌面端 | Windows（单文件 exe） |
| 移动端 | Android（arm64-v8a） |

> 注意：本项目工程名与对外名称均为 **EVE 自走棋 / EVE-AutoChess**，与任何数字后缀无关。

## 下载

最新版见 [**Releases**](https://github.com/xshynews/EVE-AutoChess/releases)：Windows 单文件 exe + Android apk（arm64-v8a）。

> **装一次就够**：从 V0.14.10 起客户端支持热更新，脚本 / 数值 / 界面的改动会在启动时自动下载并生效，**不需要重新下载安装包**。

## 热更新（Hot Update）

客户端内置了基于 PCK 覆盖的热更（`scripts/core/eve_updater.gd`，autoload `EveUpdater`）：

1. 启动时拉取一份几百字节的版本清单，比对 `code`，有新版本就下载补丁包（**约 1 MB**）；
2. 下载完成后先校验 **SHA256**，校验不过直接丢弃 —— 半个包挂上去等于启动即崩；
3. 校验通过才 `ProjectSettings.load_resource_pack()` 挂进 `user://update.pck`，覆盖 `res://` 里的同名资源，**逻辑、界面、数值一起生效**；
4. 全程不阻塞启动：服务器挂了 / 网络断了 / 下载失败都只是「这次不更新」，照常用本地版本进游戏；
5. **自愈**：挂载前记一次启动计数，连续 3 次进不到主菜单就认定这个包有毒，自动删包回退。

**能热更什么**：`scripts/`（逻辑与界面）、`data/`（数值表）、i18n 文案 —— 每次都是**全量快照**，不做增量（`load_resource_pack` 是叠加语义，删掉的文件不会消失）。

**不能热更什么**：美术资源（模型 / 贴图 / 音频，占整包约 300 MB）和引擎本体（exe / Android 的 libgodot）—— 这类更新仍需重新安装整包。

补丁包挂在 GitHub Releases 的 `hotfix-*` 标签下，客户端按「加速站 → 自建节点」顺序多源回退下载；清单与发布流程见 [`docs/联机与热更部署.md`](./docs/联机与热更部署.md)，打包脚本是 `tools/publish_hotfix.sh`。


## 如何运行 / 构建

1. 安装 [Godot 4.7.2](https://godotengine.org/)。
2. 用 Godot 打开本仓库根目录（`project.godot`）。
3. 编辑器内按 **F5** 直接运行；或 **项目 → 导出** 选择 Windows / Android 预设。
4. Android 导出需在 `export_presets.cfg` 填入自己的 keystore 与签名口令（仓库内已**移除**示例签名配置，避免密钥泄露）。

## 战斗视效与音效

四类主武器、持续电子战、护盾／舰体受击和击毁表现已接入正常对局。武器按舰船吨位使用不同的短尾音素材，界面及阶段声音按实际操作播放；正常启动仍进入主菜单。实现和资源说明见 [战斗视效与音效](docs/combat-vfx.md)。

## 目录结构（节选）

```
scripts/        游戏逻辑（ui / core / card/ddz / data 等）
scenes/         Godot 场景（主菜单、战斗、斗地主牌桌、片头等）
assets/         美术 / 音频资源（见下方版权说明）
data/           设计侧数据源（CSV 原稿 + 开场时间轴，见 data/README.md）
tools/          无头验证与探针脚本（verify_* / probe_*）
tools/pipeline/ 离线生成脚本（舰船/朝向/牌面/天空盒，见其 README）
export_presets.cfg  导出预设（不含签名密钥）
```

## 跑验收

统一入口（CI 用的也是它）：

```bash
GODOT_BIN=/path/to/Godot_v4.7.2-stable_win64_console.exe tools/run_verifies.sh
```

不设 `GODOT_BIN` 时，脚本会在 `PATH` 中查找 `godot` / `godot4` 等可执行文件。

以下任一条件不满足即判失败：

1. 进程退出码为 0；
2. 输出中没有 `SCRIPT ERROR` / `Parse Error`；
3. 输出中出现完成标记（防止脚本中途退出被当成通过）；
4. 输出中的失败计数（`failed=N` / `N 项失败`）为 0。

> 历史：`verify_run` 曾因 provider 回调以 lambda 形式存进 static var、退出时脚本先卸载而段错误
> （退出码 139）——根因已修，现在连跑稳定 exit 0。

诊断型脚本（`verify_background` / `verify_camera` / `probe_*`）只出数、没有通过/失败语义，**不在套件里**；
`verify_battle` 已补断言（13 条）但仍是诊断入口。

### CI（GitHub Actions）

每次 push / PR 到 `main` 会自动跑 [`.github/workflows/verify.yml`](./.github/workflows/verify.yml)：

1. **无头验收套件** —— 同一份 `tools/run_verifies.sh`（windows-latest 上跑，与本地同构）；
2. **数据一致性** —— 设计表 `data/source_csv/01..` ↔ 代码 `scripts/data/*.gd` 逐行逐列对拍
   （`_gen_ship_table.py`，这是「人工手抄会漂移」的那条链）；
3. **产物可复现** —— 用仓库内清单重跑 `_gen_ship_index.py`，产物必须与仓库文件逐字节一致。

## 美术资源版权说明

仓库内的舰船模型、图标、音频等游戏美术资源**提取自 EVE Echoes 客户端资源**。
EVE 相关的 IP 与素材著作权归 **Fenris Creations** 所有（该公司于 2026 年 5 月由 CCP Games 更名而来；
CCP 原名 *Crowd Control Productions*），**本开源项目不持有这些素材的任何权利**，相关内容**不**在本项目的 GNU GPL v3 许可证覆盖范围内。

- 这些资源**仅用于开发、调试与体验目的**；
- 若你分发包体，请自行确认相关素材的授权合规；
- 代码（GDScript / 配置 / 工具脚本）以 **GNU GPL v3** 许可证使用、修改与再分发（衍生作品须同样以 GPL v3 开源）。

### 背景音乐（BGM）

- 五首 BGM 原曲：**City of Night / Pixel Wars / DJ BO$$ / Lantern / Start the Battle**，
  作者 **乌鸦Producer**（取自其「免费可商用」原创音乐集合包，
  B 站合集 [BV1uFcwe1EDV](https://www.bilibili.com/video/BV1uFcwe1EDV/)）。
- 本项目使用的版本为适配游戏时长与无缝循环经 **重编曲**处理，**原曲版权仍归原作者所有**。
- 对应用途：主菜单 City of Night · 守卫边境 Pixel Wars · 终局 DJ BO$$ ·
  斗地主 Start the Battle（`ddz_01.ogg`，92.2s / 48 小节无缝循环）。
  ★ 循环的具体做法（量节拍网格 → 在小节线切断 → 短交叉淡化 → 响度对齐）
  记在 [`assets/audio/README.md`](./assets/audio/README.md) 的「BGM 无缝循环配方」。
- ⚠️ Lantern 已从牌桌撤下，改名 `lantern_01.ogg` 留在音库里备用（当前没有任何场景播它）。
- 其余音效与环境音提取自 EVE 客户端资源（见 [`assets/audio/README.md`](./assets/audio/README.md)）。

## 许可证

- **代码**：[GNU GPL v3](./LICENSE)（Copyright © 2026 xshynews）
- **美术 / 音频资源**：归 Fenris Creations 所有，非本项目许可证覆盖范围，见上。

## 多语言（i18n）：目前**只出中文**，英文有意冻结

仓库里有一套 i18n 基建（`i18n/strings.csv` 是唯一文案真相源，代码一律经 `EveText.t()` 取词），
但**当前交付语言只有简体中文**——英文不是"做了一半丢在那"，是**有意冻结**：

- **为什么**：英文文案本身还没过审（`strings.csv` 的 `en` 列大量是占位/直译），
  UI 面也只迁了一半。这时开放语言切换，玩家只会看到中英混杂的半成品。
- **表现**：设置窗里**没有**「语言」这一行。开关是 `scripts/core/eve_text.gd` 的
  **`LANGUAGE_ENABLED = false`**（唯一真源，代码都保留着，只是被这个常量挡住）。
- **要不要紧**：不影响中文版任何行为——默认 locale 是 `zh_CN`，取词原样返回中文、逐字不变；
  `verify_i18n` 就是这条的护栏（它同时也断言"冻结期语言行不存在 / 存档语言会被忽略"）。
- **想启用 / 想加语言**：见 [`i18n/README.md`](./i18n/README.md) 顶部的解冻四步，
  **翻那一个常量**就能先看到界面入口；英文文案（`en` 列）是最欢迎 PR 的部分。

## 贡献

欢迎issue与PR。提交前请保持 `scripts/` 下 snake_case 命名、关键行为附 `verify_*` 无头验收。
