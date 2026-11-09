extends Control
class_name EveHudRoot

## ★ 字号缩放（2026-10-07）：⛔ 别直接调 `add_theme_font_size_override`，
## 一律走 `FONT.fs(node, 设计字号)` —— 它同时记住设计字号（供改滑块时就地重算）。
## ⚠️ 子类（`extends eve_window.gd` 的那 9 个）靠**继承**拿到这个常量，
##    它们自己再写一个会撞名（基类已有同名成员 ⇒ 子类编译失败，本工程踩过）。
const FONT := preload("res://scripts/ui/eve_font.gd")
## ★ 2026-10-11（i18n）：文案取词（见 `eve_text.gd` 顶注）。
const T := preload("res://scripts/core/eve_text.gd")
## ★ 非 16:9 分辨率下的**内容居中偏移**（`origin()`）+ 设计空间唯一真相源。
## ⚠️ 桌面端原本「布局是死坐标、与视口无关」；有了分辨率档之后这句话不再成立 ——
##    1920×1200 这类档会让设计空间比基准大，内容必须整体居中（见 EveLayout 顶注）。
const LAYOUT := preload("res://scripts/ui/eve_layout.gd")
## ★ 安卓线：安全区唯一真源（移动端布局必须避开左侧挖孔）。
##   ⛔ 桌面端不读它 —— 桌面没有安全区概念，`_safe_left()` 直接回 0。
const MOBILE := preload("res://scripts/mobile/eve_mobile_layout.gd")

## EVE 自走棋 —— HUD 根节点（V3 布局稿实装版）
##
## ══════════════════════════════════════════════════════════════════
##  默认位（1920 × 1080）—— 与设计稿 v3.html 的坐标一一对应
## ══════════════════════════════════════════════════════════════════
##    顶条 · 舰队指挥      620,   6,  680,  40   裸条，无标题栏
##    左上 · 舰队构成        8,  56,  172, 268
##    左下 · 装备栏位        8, 336,  172, 116
##    右上 · 舰船档案     1740,  56,  172, 128   默认收起；点选后 320 高
##    右下 · 战斗日志     1740, 384,  172, 200
##    底中 · 商店          389, 908, 1142, 158
##    备战席格带（非窗口）  360, 760, 1200, 140
##
##  UI 面积 ≈ 19.5%（云顶之弈实测 18.7%，上一版 51.2%）
##  中央纯空旷区 = 1560 × 792 全留给星空与场景（以后放建筑 / 矿石）
##
## ── 三条不可回退的约定（都来自用户逐条下达的规格）────────────────
##   ① 所有信息功能栏都是【可拖动 / 可缩放的独立窗口】（EVE 式）。
##      标题栏即拖动手柄，右下角三角即缩放柄，窗口之间留缝露出天空。
##   ② 天空盒必须看得见（满屏、原图直出亮度）；棋盘格子默认不显示。
##   ③ 备战席【不是窗口】，但也**不再是裸刻度线**（2026-09-22 改版）：
##      它是一排 8 个看得见的方格，紧贴棋盘近端、整体微微上浮（悬空分层）。
##      **格子里画的是 2D 立绘**（2026-09-23 改版，见下），不是 3D 模型。
##
## ⚠️ 2026-09-23 备战席改版（用户口径：「把备战席的船也改为 2D 立绘卡牌吧，
##    现在这样特别别扭，尤其是放上去的模型朝向还不一样」）：
##      船的呈现方式：EveBenchStage（3D 模型层）→ **EveBenchRail 内画官方立绘**
##      · 立绘 = res://assets/ships/<id>.png，与商店卡片同一套、同一主键
##      · 3D 层停用（EveBenchStage 文件保留，回退方法见该文件与
##        EveBattleArena._ready() 里的注释）
##      · 顺带把 HIT_ABOVE 48 → 10（立绘不再伸到格子外）
##
##      这一改解决的：① 压暗（HUD 格底曾把 3D 船蒙黑）、② 清晰度。
##      ⚠️ **它没有解决朝向** —— 官方 render 图的机位固定、但 52 艘船的
##         模型自身朝向各不相同，所以立绘本身就有「正视 / 侧视」两种构图
##         （实测：横构图 bbox 约 439×294，竖构图约 336×439）。
##         要看全貌跑 tools/probe_ship_art.tscn。
##
## ⚠️ 2026-09-22 备战席改版（用户口径：「把备战席和棋盘放到一个位置，
##    做得明显大一点，做得不一样一点」）：
##      旧：RECT_BENCH(389, 838, 1142,  52) —— 一条两端渐隐的裸轨道线
##      新：RECT_BENCH(360, 760, 1200, 140) —— 8 个方格 + 顶部金色层高线
##    纵向排布（1080 高，底部留 14px 边距）：
##      棋盘区 55..760（3D）→ 格带 760..900 → 缝隙 8 → 商店 908..1066
##    ⚠️ 商店同时从 168px 压到 158px（卡面 56→50、按钮 26→24），否则格带吃不下。
##      商店内容的最小高度需求约 128~135px，158 仍有富余。
##
##    ⚠️ 宽度取 1200（而不是"铺满整屏 1920"）是**美学判断**，不是省事：
##      棋盘在布阵取景下投影宽 1055px（单格 96px，见
##      EveBattleArena.BOARD_VIEW_ZOOM）。格带铺满 1920 会比棋盘宽 865px，
##      读起来是「棋盘坐在一条过长的台上」；1200 只宽 145px，
##      两者看起来才像同一块地上的两层。单格 150px 也比旧版的 142.8px 略大。
##      ⚠️ 做到「格带单格 = 棋盘单格」是不可能的：那需要格带宽 768px
##      （8 × 96），反而比旧版窄一半 —— 因为棋盘横向被纵向高度（710px）锁死了。
##
## 变更清单（实装版）：
##   - 六窗 + 一条轨道，全部按 V3 坐标落位
##   - demo_content：一键填演示数据（装备 / 商店卡 / 日志 / 羁绊），
##     让首次启动就能看到完整形态；接真实玩法时置 false
##   - 商店的「拿起备战舰船 → 整块化作出售区」链路已打通（set_selling）

# ── V3 默认位（改这里就等于改默认布局）────────────────────────────
#
# ⚠️ 2026-09-20 阶段 A：顶条从 620,6,680,40 加宽到 560,6,800,40。
#    加宽的唯一原因是**信标上了顶条**（交接文档 §11 P0：
#    它是一局的生命线，必须在场，否则「失败」没有载体），
#    顺带给计时段加了阶段名（准备 / 交战 / 结算）。
#    中心仍是 960（560 + 800/2），左右各让出 60px，仍不足屏宽一半。
#    后面再往顶条塞东西之前，先算一次「UI 面积占屏比」（当前 19.x%）。
const RECT_TOP := Rect2(560, 6, 800, 40)
# ⚠️ 2026-10-26：`舰队构成` 从 268 加到 **352**，`装备栏位`/`事件增益` 各下移 40。
#    唯一原因是羁绊组合从 3 组（势力/武器/防御）加到 5 组（+后勤 +电子战）：
#    内容最小高实测 306，而外框（标题栏 33 + 下内距 8）还要 41 ⇒ 347 起才「不裁」，
#    352 留 5px 余量。⛔ 不要靠压字号/压行距硬塞回 268 —— 那会把 12 条羁绊行
#    压到 15px 以下，手机更难读。
#    左列下方直到 838 本来就是空的（见 RECT_AUG 那条注释），下移不影响任何其他窗。
const RECT_SYN := Rect2(8, 56, 172, 352)
const RECT_EQ := Rect2(8, 420, 172, 116)
const RECT_INFO := Rect2(1740, 56, 172, 128)
# ⚠️ 2026-10-26：再加「电子战」⇒ 档案展开态 360 → **376**（内容最小 332 + 外框 41 = 373），
#    日志再下移 16 → 440（档案底边 432，仍留 8px 间隙）。
const RECT_LOG := Rect2(1740, 440, 172, 200)
const RECT_SHOP := Rect2(389, 908, 1142, 158)
const RECT_BENCH := Rect2(360, 760, 1200, 140)

# ── 阶段 C 新增的两块（2026-09-20）──────────────────────────────────
#
# ⚠️ RECT_AUG 接在左列已有的两窗下面（8, 420..536 → 8, 544）：
#    左列在 V3 稿里 452..838 是空的，所以它是**唯一**既在左列、
#    又不挤压现有窗口的位置，而且补上了左列「有头无尾」的观感。
#    它默认**隐藏**（没拿到增益时不占屏），所以开局占屏比与 V3 的 19.3% 一致。
#    （2026-10-26：随 `舰队构成` 加高，整列同步下移到 544。）
#
# ⚠️ RECT_EVENT 是全局唯一的**打断式决策面板**：4 张卡横排居中压在战场上。
#    它不算「功能区」——功能区是常驻的，它一局只出现三次、每次点一下就消失。
#    y 取 292（而不是正中 540-186=354）是为了把底部备战席 / 商店那一带留干净，
#    让「面板浮在海盗船与星空之上」这层关系一眼看得懂。
const RECT_AUG := Rect2(8, 544, 172, 140)
## 高度 296 是**按内容反推**的：标题栏 26 + 上内距 6 + 引导语 16 + 间距 6
## + 卡片 215 + 间距 6 + 脚注 13 + 下内距 8 ≈ 296。
## ⚠️ 别再随手调大 —— `EveWindow` 修好 `_content_margin` 的扩张之后，
##    卡片会**吃掉所有富余高度**，窗高给多 100px 就是卡片里多 100px 空洞。
const RECT_EVENT := Rect2(460, 300, 1000, 296)

# ── 阶段 D 新增的两块（2026-09-20）──────────────────────────────────
#
# 结算页：居中、比事件面板窄（它是「读一屏数字」，不是「四选一」）。
# 宽 420 / 高 356 是按内容反推的（规则 11）：
#   标题栏 26 + 内距 6 + 结论 30 + 副标题 14 + 分隔 1 + 间距 7
#   + 信标行 30 + 分隔 1 + 战果 3×18 + 分隔 1 + 收益 2×18 + 分隔 1 + 按钮 28 + 下内距 8 ≈ 356
# ⚠️ 别再随手调大 —— EveWindow 的 _content_margin 修好 EXPAND 之后，
#    富余高度会被内容吃掉，给多 100px 就是窗里的空洞（本工程的既有教训）。
const RECT_RESULT := Rect2(750, 330, 420, 356)

# ── 舰船抽奖窗（2026-10-31 · 炼狱专属事件「黑市情报」）────────────────
#
# 窗口要摊开**整张候选矩阵**（3 个费用档 × 3 个定位列 + ★2 一段）
# 让玩家挨个看、再点一张当愿望。宽沿用 1000。
# y / 高：可用带是「顶条 46 以下、备战席 760 以上」= 714 高 ⇒ 居中放 590
# 高（y = 46 + (714-590)/2 ≈ 108），下沿 698 仍在备战席之上。
#
# ★ 2026-11-01（用户要求分类排版）实测：矩阵本体 434px 高，加上说明行 /
#   许愿行 / 按钮共 ~526px ⇒ 560 的旧高度会挤出一条 22px 的滚动条，
#   把最后一整行（★2）推到视野外。抬到 590 后一屏装完、无滚动条。
const RECT_LOTTERY := Rect2(460, 108, 1000, 590)
## 抽奖窗的最大高度（紧凑 / 手机档要按可用带夹一次）
const LOTTERY_MAX_H := 590.0

# 设置窗：**全平台同一套栏目窗**（2026-10-13 用户定「把设置更新也同步改到PC端」）。
#
# 桌面 / 紧凑档的矩形由 static `settings_rect()` 算（半屏宽 + 定高，设计空间居中）；
# 手机档仍走 `mobile_rects()`（y 受「顶条以下」带约束）。原来的 320 竖条常量
# `RECT_SETTINGS` 已随之退役（竖向长条不再使用）。


## 设置窗矩形（桌面 / 紧凑档共用）：与手机同一形态 —— 宽 = 设计宽 ×0.5
## 夹 [420,1000]、定高 560（不超屏），在设计空间里居中。
## ⚠️ 静态纯函数：`verify_ui_scale` 直接拿它当期望值比对。
static func settings_rect(d: Vector2) -> Rect2:
	var w := maxf(640.0, d.x)
	var h := maxf(480.0, d.y)
	# ★★ 2026-10-21（UI 比例基线 · 阶段 0-2）：**删掉了一条手机分支**。
	#   它曾返回 `0.72W × 0.78H`，而真正给手机用的是 `mobile_rects()` 里的
	#   `0.5W × min(0.70H, 560)` ⇒ **同一扇窗两套公式**，改一处另一处不变（静默漂移）。
	#   实测该分支在运行时是**死代码**（手机走 `_mobile_layout`，不进 `compact_rects`），
	#   故统一到下面这一条：宽 = 0.5W（夹 [420,1000]）、高 = min(560, 0.70H 余量)。
	#   ⛔ 别再加「按平台分叉」—— 要改就改 `MOBILE_SETTINGS_*` 这组常量。
	var bw := clampf(w * MOBILE_SETTINGS_W_FRAC,
			MOBILE_SETTINGS_W_MIN, MOBILE_SETTINGS_W_MAX)
	bw = minf(bw, w - 2.0 * MOBILE_EDGE)
	var bh := minf(MOBILE_SETTINGS_H, h - 2.0 * MOBILE_EDGE)
	return Rect2((w - bw) * 0.5, (h - bh) * 0.5, bw, bh)

# 备战席格数（与 EveBenchRail.SLOTS 对齐）
const BENCH_SLOTS := 8

var command_bar: EveWindow            ## 顶条
## 联机准备阶段最后 10 秒的中央倒计时（非窗口；压在所有窗之下、鼠标穿透）
var round_countdown: Control = null
var synergy_window: EveWindow         ## 左上：舰队构成
var equipment_window: EveWindow       ## 左下：装备栏位
var augments_window: EveWindow        ## 左中：事件增益（阶段 C；无增益时隐藏）
var dossier_window: EveWindow         ## 右上：舰船档案
var log_window: EveWindow             ## 右下：战斗日志
var shop_window: EveWindow            ## 底中：商店
var event_window: EveWindow           ## 居中：事件四选一（阶段 C；平时隐藏）
## 居中：舰船抽奖（炼狱专属；平时隐藏）。见 `eve_lottery.gd`。
var lottery_window: EveWindow = null
## 居中：节点结算页（阶段 D；平时隐藏）
var result_window: EveWindow = null

## 设置窗（阶段 D；平时隐藏，点顶条 ≡ 打开）
var settings_window: EveWindow = null
## 全屏暂停遮罩（阶段 D+；平时隐藏）。见 `set_paused()` 的口径说明。
var pause_veil: Control = null
var bench_rail: EveBenchRail          ## 备战席轨道（非窗口）
## 当前阶段（0 准备 / 1 战斗 / 2 结算）—— 与顶条 `command_bar.phase` 同源。
##
## ⚠️ 本类需要它做一件事：**决定备战席金线要不要读秒**。
##    只有准备阶段的倒计时才是「备战席还能操作多久」；战斗阶段的顶条走的是
##    战斗时限，那两件事毫不相干 —— 让金线跟着战斗时限收缩，
##    玩家会以为备战席快要没了。
var _phase: int = 0
## 伤害数字层（阶段 D）—— 屏幕空间的飘字，压在所有窗口之上、幽灵之下。
var damage_feed: Control = null
## ★ 2026-10-30：战斗播报条（中央靠上 3 行）。与飘字分属两层，见脚本顶注。
var damage_band: Control = null
## 节点进场词横幅（阶段 C 收尾）—— 同样压在所有窗口之上、飘字之下。
var entry_banner: Control = null

## 首次启动是否填演示数据。
##
## ⚠️ 2026-09-20（阶段 A）默认改为 **false**：真实数据已经接上了
##    （EveRunState 喂商店 / 经济 / 备战席 / 羁绊 / 日志），
##    再默认打开演示数据就等于「开局先骗玩家一次」。
##    想看 V3 稿的满配形态时，把 run 的 demo_content 打开即可 ——
##    它仍然遵守「只填还没有真实数据的窗口」这条规则。
@export var demo_content: bool = false

## 按钮皮肤（沿用 EveButtonTheme 的可替换机制）
@export_enum("default", "accent", "plain", "hud", "hud_main", "hud_warn")
var button_skin: String = "hud"

signal start_battle_requested()
signal settings_requested()
signal shop_buy_requested(offer_index: int)
## ★ 2026-11-07：商店卡被「选中」（第一次点击）—— 主控据此把右上角
## 舰船档案换成这艘船的完整属性。**不含买入**，买入仍走 `shop_buy_requested`。
signal shop_preview_requested(offer_index: int)
signal shop_refresh_requested()
signal shop_levelup_requested()
signal shop_lock_toggled(on: bool)
signal salvage_requested()
## 顶条倒计时归零（准备阶段到点 / 战斗时限到点）
signal stage_timer_expired()
## 事件四选一：玩家点了某一条（id = EveEventTable 的主键）
signal event_option_chosen(id: StringName)
## 事件「选 1 艘船」：玩家点了第 index 艘（对应 `show_ship_pick` 传进来的数组）
signal event_ship_picked(index: int)

# ── 舰船抽奖（2026-10-31 · 炼狱专属事件「黑市情报」）──
## 玩家点了「抽取」：愿望原样传出。空 StringName = 没许愿；
## `wish_star` 与 `wish_key` 一起才唯一（同名 ★1/★2 是池子里两个不同奖品）。
signal lottery_draw_requested(wish_key: StringName, wish_star: int)
## 玩家点了「完成」：场景据此推进节点（抽奖窗是**打断式**的，必须走完）
signal lottery_finished

# ── 阶段 D 新增 ──
## 结算页：继续下一节点 / 结束本局
signal result_next_requested()
signal result_end_requested()
## ★ 打捞区（2026-10-04 改版：按钮在结算页**下方**，逐艘直接点「打捞」）。
##   · 点某一艘的「打捞」按钮（参数 = 残骸下标）
##   · 零选二次确认通过（「确定放弃本回合全部残骸」）
signal salvage_pick_one(idx: int)
signal salvage_pick_zero()
signal salvage_section_closed()      ## 点「关闭」收起打捞区
## 设置窗
signal settings_closed()
signal settings_background_changed(id: String)
signal settings_mood_changed(mode: int)
signal settings_fog_toggled(on: bool)
signal settings_board_toggled(on: bool)
signal settings_camera_reset()
signal settings_restart()
## 设置窗「放弃本局 · 回主界面」→ 主控切回主菜单
signal settings_back_to_menu()
## 设置窗的暂停 / 继续。`on = true` = 请求暂停（主控才是真相源）。
signal settings_pause_toggled(on: bool)
## 音量滑杆。`kind` = &"master" / &"sfx" / &"amb" / &"music"
signal settings_volume_changed(kind: StringName, v: float)
## 静音开关
signal settings_mute_toggled(on: bool)
## 暂停遮罩上的「继续」按钮 —— 暂停期间设置窗可以被关掉，
## 那时鼠标唯一能点的东西就是它（否则玩家只能靠空格脱身）。
signal pause_resume_requested()
## ⚠️ DEBUG-ONLY: 调试期加币信号，发布时删除
signal settings_add_coins(amount: int)

## 全刷请求 —— 调试按钮 / 自动化脚本（探针 / 录制回放）调 `hud.refresh()` 触发，
## 主控接住后调自己的 `_refresh_run_ui()`。解耦 hud 与主控类型。
signal refresh_requested()

# 以下两个为兼容旧调用方保留：新布局里姿态与圆环开关没有落位（V3 稿没有这两块），
# 设置页会接管它们。信号先留着，免得旧代码连不上。
signal stance_changed(ship: EveShip, stance: int)
signal range_rings_toggled(enabled: bool)

const COMMAND_BAR_SCRIPT := preload("res://scripts/ui/panels/eve_command_bar.gd")
const COUNTDOWN_SCRIPT := preload("res://scripts/ui/eve_round_countdown.gd")
const SYNERGY_SCRIPT := preload("res://scripts/ui/panels/eve_fleet_synergy.gd")
const EQUIPMENT_SCRIPT := preload("res://scripts/ui/panels/eve_equipment.gd")
const DOSSIER_SCRIPT := preload("res://scripts/ui/panels/eve_ship_dossier.gd")
const LOG_SCRIPT := preload("res://scripts/ui/panels/eve_combat_log.gd")
const SHOP_SCRIPT := preload("res://scripts/ui/panels/eve_shop.gd")
const BENCH_SCRIPT := preload("res://scripts/ui/panels/eve_bench.gd")
const AUGMENTS_SCRIPT := preload("res://scripts/ui/panels/eve_augments.gd")
const EVENT_SCRIPT := preload("res://scripts/ui/panels/eve_event.gd")
const LOTTERY_SCRIPT := preload("res://scripts/ui/panels/eve_lottery.gd")
const DAMAGE_FEED_SCRIPT := preload("res://scripts/ui/eve_damage_feed.gd")
const DAMAGE_BAND_SCRIPT := preload("res://scripts/ui/eve_damage_feed_band.gd")
## 节点进场词横幅（阶段 C 收尾）—— 瞬时元素，见 eve_entry_banner.gd 的口径说明
const ENTRY_BANNER_SCRIPT := preload("res://scripts/ui/eve_entry_banner.gd")
const SETTINGS_SCRIPT := preload("res://scripts/ui/panels/eve_settings.gd")
const RESULT_SCRIPT := preload("res://scripts/ui/panels/eve_result.gd")
## ★ 平台 UI 缩放档（2026-10-07）。⛔ 用 preload 常量而不是裸写 class_name
##   —— 新 class_name 要等 .godot 重扫才注册得上（红线 22）。
const UI_SCALE_SCRIPT := preload("res://scripts/ui/eve_ui_scale.gd")
## ★ 2026-10-21（UI 比例基线）：宽度/间距按全站刻度算（桌面端自动回落原常量）。
const UI_METRICS := preload("res://scripts/ui/eve_ui_metrics.gd")

var _selected_ship: EveShip = null
var _fleet: Array = []
var _demo_used := false
var _drag_ghost: _DragGhost = null


func _ready() -> void:
	# ⚠️ 必须铺满整个视口。裸 Control 若不设锚点，size 就是 0×0，
	#    所有子窗口会塌缩到原点（实测现象：整个 HUD 只剩一个 40px 小方块）。
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS
	_build_layout()
	# ★ 设计空间变了（设备旋转 / 换分辨率 / 切缩放档）⇒ 紧凑档要重铺一遍。
	#   桌面端 `_on_resized()` 会立刻返回 —— 它的布局是设计稿的绝对坐标，
	#   跟视口无关（这也是「Windows 端逐像素不变」的一部分）。
	resized.connect(_on_resized)
	# ⛔ 删除记录（2026-11-08 晚，当天回滚）：
	#    这里曾挂 `get_viewport().gui_focus_changed → release_focus()`，
	#    想解决「点过刷新后按空格又刷一次」。**它把全游戏按钮点死了** ——
	#    焦点变更就发生在鼠标按下那一刻，释放焦点会连带清掉 `BaseButton.press_attempt`，
	#    抬手时 `pressed` 不触发 ⇒ 现象是「只能买船（卡片走 gui_input），
	#    刷新 / 加速 / 继续·下一节点 全都点不动」。
	#    现在改成从 `ui_accept` 动作里摘掉空格：`scripts/ui/eve_input_guard.gd`。
	#    一次性探针实测：正常点击 pressed=true，按下后 release_focus / focus_mode=NONE 都是 false。
	if demo_content:
		_apply_demo_content()


func _build_layout() -> void:
	# ① 备战席轨道（先加，让它落在最底层：窗口永远压在它上面）
	bench_rail = BENCH_SCRIPT.new()
	bench_rail.name = "BenchRail"
	bench_rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bench_rail)
	bench_rail.set_anchors_preset(Control.PRESET_TOP_LEFT)
	# 位置/尺寸由 `_apply_rects()` 统一铺（档位表决定）

	# ② 顶条
	command_bar = COMMAND_BAR_SCRIPT.new()
	command_bar.name = "CommandBar"
	add_child(command_bar)
	command_bar.start_battle_requested.connect(func(): start_battle_requested.emit())
	command_bar.settings_requested.connect(func(): settings_requested.emit())
	command_bar.timer_expired.connect(func(): stage_timer_expired.emit())

	# ②b 联机中央倒计时 —— 必须**在窗之前**加：它要压在战场之上、所有功能窗之下。
	#    ⚠️ 它只读顶条的 `time_left` / `phase`（唯一真相源），自己不存时间。
	round_countdown = COUNTDOWN_SCRIPT.new()
	round_countdown.name = "RoundCountdown"
	add_child(round_countdown)
	round_countdown.call("bind", command_bar)

	# ③ 左上：舰队构成
	synergy_window = SYNERGY_SCRIPT.new()
	synergy_window.name = "FleetSynergy"
	add_child(synergy_window)
	synergy_window.set_status(T.t("HUD_TRAITS", "羁绊"))

	# ④ 左下：装备栏位
	equipment_window = EQUIPMENT_SCRIPT.new()
	equipment_window.name = "Equipment"
	add_child(equipment_window)

	# ④b 左中：事件增益（阶段 C）—— 默认隐藏，拿到第一条增益才现身
	augments_window = AUGMENTS_SCRIPT.new()
	augments_window.name = "Augments"
	add_child(augments_window)
	augments_window.visible = false

	# ⑤ 右上：舰船档案（默认收起）
	dossier_window = DOSSIER_SCRIPT.new()
	dossier_window.name = "ShipDossier"
	add_child(dossier_window)

	# ⑥ 右下：战斗日志
	log_window = LOG_SCRIPT.new()
	log_window.name = "CombatLog"
	add_child(log_window)

	# ⑦ 底中：商店
	shop_window = SHOP_SCRIPT.new()
	shop_window.name = "Shop"
	add_child(shop_window)

	shop_window.buy_requested.connect(func(i: int): shop_buy_requested.emit(i))
	# ★ 2026-11-07：商店卡「第一下 = 看档案」。少这行的话，卡片会亮金边、
	#   状态栏写「再点一次购买」，但右上档案一动不动 —— 典型的静默断线。
	shop_window.preview_requested.connect(func(i: int): shop_preview_requested.emit(i))
	shop_window.refresh_requested.connect(func(): shop_refresh_requested.emit())
	shop_window.levelup_requested.connect(func(): shop_levelup_requested.emit())
	shop_window.lock_toggled.connect(func(on: bool): shop_lock_toggled.emit(on))
	shop_window.salvage_requested.connect(func(): salvage_requested.emit())

	# ⑧ 居中：事件四选一（阶段 C）
	#
	# ⚠️ 顺序要紧：它要压在商店 / 备战席之上（事件节点玩家仍可以整理舰队，
	#    但点面板时不能被商店的卡片抢走点击），同时又要被拖动幽灵压住。
	#    所以位置是「商店之后、幽灵之前」。
	event_window = EVENT_SCRIPT.new()
	event_window.name = "EventChoice"
	add_child(event_window)
	event_window.visible = false
	event_window.option_chosen.connect(func(id: StringName): event_option_chosen.emit(id))
	event_window.ship_picked.connect(func(i: int): event_ship_picked.emit(i))

	# ⑧-b 居中：舰船抽奖（2026-10-31 · 炼狱专属）
	#
	# ⚠️ 建在事件窗**之后**：抽奖是"选了黑市情报"的下一个画面，
	#    两者理论上不同时出现，但真撞上时抽奖必须在上层（它才是当前该点的那个）。
	lottery_window = LOTTERY_SCRIPT.new()
	lottery_window.name = "ShipLottery"
	add_child(lottery_window)
	lottery_window.visible = false
	lottery_window.draw_requested.connect(
			func(key: StringName, star: int): lottery_draw_requested.emit(key, star))
	lottery_window.finished.connect(func(): lottery_finished.emit())

	# ⑨ 居中：结算页（阶段 D）—— 默认隐藏，战斗结束时上台。
	#
	# ⚠️ 它必须**压过事件面板**（两者都是居中大窗，理论上不会同时出现，
	#    但「不可能同时出现」这种假设不值得靠顺序之外的东西保证）。
	result_window = RESULT_SCRIPT.new()
	result_window.name = "Result"
	add_child(result_window)
	result_window.visible = false
	result_window.next_requested.connect(func(): result_next_requested.emit())
	result_window.end_requested.connect(func(): result_end_requested.emit())
	# ★ 打捞区接两条信号（2026-10-04 改版：逐艘点，没有浮层了）
	result_window.salvage_pick_requested.connect(
			func(i: int): salvage_pick_one.emit(i))
	result_window.salvage_pick_zero.connect(func(): salvage_pick_zero.emit())
	result_window.salvage_section_closed.connect(
			func(): salvage_section_closed.emit())

	# ⑩ 设置窗（阶段 D）—— 默认隐藏，点顶条 ≡ 打开。
	settings_window = SETTINGS_SCRIPT.new()
	settings_window.name = "Settings"
	add_child(settings_window)
	settings_window.visible = false
	settings_window.background_changed.connect(func(id: String): settings_background_changed.emit(id))
	settings_window.mood_changed.connect(func(m: int): settings_mood_changed.emit(m))
	settings_window.fog_toggled.connect(func(on: bool): settings_fog_toggled.emit(on))
	settings_window.range_rings_toggled.connect(func(on: bool): range_rings_toggled.emit(on))
	settings_window.board_toggled.connect(func(on: bool): settings_board_toggled.emit(on))
	settings_window.camera_reset_requested.connect(func(): settings_camera_reset.emit())
	settings_window.run_restart_requested.connect(func(): settings_restart.emit())
	settings_window.back_to_menu_requested.connect(func(): settings_back_to_menu.emit())
	settings_window.pause_toggled.connect(func(on: bool): settings_pause_toggled.emit(on))
	settings_window.volume_changed.connect(func(kind: StringName, v: float):
			settings_volume_changed.emit(kind, v))
	settings_window.mute_toggled.connect(func(on: bool): settings_mute_toggled.emit(on))
	# ★ 2026-10-10：设置窗标题栏的 ✕ 按下也会发 `closed` ⇒ 这里统一收口成
	#   「隐藏 + 转发」。hide_settings() 是唯一入口（三场景共用）。
	settings_window.closed.connect(func():
			hide_settings()
			settings_closed.emit())
	# ★ 缩放档：HUD 自己消化（见 `_on_ui_scale_picked` 的说明）
	settings_window.ui_scale_changed.connect(_on_ui_scale_picked)
	# ★ 字号变了 ⇒ 底部两条要按新字高重新上抬（字体本身由设置窗 reapply）
	settings_window.font_scale_changed.connect(_on_font_scale_changed)
	# ★ 分辨率变了 ⇒ 重铺（非 16:9 的档会改居中偏移，见 `on_resolution_changed`）。
	#   ⚠️ 窗口尺寸由**设置窗自己**改（`EveResolution.apply_index`），这里只负责重铺；
	#      不看那个信号也行（`resized` 会来），但**两条路重复重铺一次**比
	#      「刚好漏掉"清拖动记录"那一步」安全 —— 后者表现为窗停在半路上，极难查。
	settings_window.resolution_changed.connect(func(_i: int): on_resolution_changed())
	# ⚠️ DEBUG-ONLY: 加币信号转发（与 settings_window.add_coins_requested 同源）
	# 发布时**整组删除**（按钮 / signal / connect 三处一致删）。
	settings_window.add_coins_requested.connect(func(amt: int): settings_add_coins.emit(amt))

	# ⑪ 伤害数字层（阶段 D）—— 屏幕空间飘字。
	#
	# ⚠️ 位置很讲究：**在窗口之后、拖动幽灵之前**。
	#    在窗口之前的话，飘字会被商店窗盖住（而战斗时玩家就盯着战场中央，
	#    那里恰好是商店窗上方）；在幽灵之后的话，拖动时飘字会盖住手上的卡。
	damage_feed = DAMAGE_FEED_SCRIPT.new()
	damage_feed.name = "DamageFeed"
	add_child(damage_feed)

	# ★ 2026-10-30：**战斗播报条**（屏幕中央靠上，3 行滚动）。
	#   与上面的飘字是两层东西：飘字跟着船走、播报条按时间排队。
	#   ⚠️ 加在飘字之后 ⇒ 万一重叠，播报条压在数字上面：
	#      「谁打谁」这句结论比单次伤害数字更该被读到。
	damage_band = DAMAGE_BAND_SCRIPT.new()
	damage_band.name = "DamageBand"
	add_child(damage_band)

	# ⑫ 节点进场词横幅（阶段 C 收尾）
	#
	# ⚠️ 加在飘字**之前**：两者极少同时出现（横幅在准备阶段入口、飘字在交战），
	#    万一撞上，让伤害数字压在上面 —— 战斗中的读数永远优先于氛围字幕。
	entry_banner = ENTRY_BANNER_SCRIPT.new()
	entry_banner.name = "EntryBanner"
	add_child(entry_banner)

	# ⑫b 暂停遮罩（阶段 D+）—— 默认隐藏。
	#
	# ⚠️ 位置必须在【所有窗口之后】，否则它遮不住商店 / 备战席 ——
	#    那就成了「暂停了还能买船」。同时必须在【拖动幽灵之前】：
	#    幽灵是手上的东西，任何遮罩都不该盖住它（虽然暂停时不会在拖）。
	pause_veil = _build_pause_veil()
	add_child(pause_veil)

	# ⑬ 拖动幽灵（阶段 B）—— 最后加 + 常驻最前，保证它压在所有窗口之上
	_drag_ghost = _DragGhost.new()
	_drag_ghost.name = "DragGhost"
	_drag_ghost.visible = false
	add_child(_drag_ghost)

	# ★ 全部窗建完 ⇒ 按当前档位统一铺一遍矩形。
	#   ⚠️ 必须在**最后**：窗建到一半时 `_win_of()` 还会拿到 null。
	#   ⚠️⚠️ 走 `refresh_layout()` 而**不是** `_apply_rects()` ——
	#      后者只铺、不算档位表。少了「先算表」这一步，
	#      `_r()` 全部回落 `RECT_TOP` ⇒ **十扇窗叠在顶条上**（实测踩过），
	#      而且 `_rect_tbl` 为空会让「档位没变就早退」那道守卫失效。
	refresh_layout()


# ------------------------------------------------------------------ 平台档位（2026-10-07）

## 是不是「紧凑档」。
## ⚠️ 桌面端**恒 false** ⇒ `_rect_tbl` 逐项等于 `RECT_*` ⇒ 布局与从前逐像素一致。
var _compact := false
## ★ 是不是「手机专用布局」档（2026-10-13 评审稿）。
##
## ⛔⛔ **唯一的移动端闸门**：`_compact` 只说明"放大了"，本档才说明"这是手机"。
##    桌面端（含无头自检）恒 false ⇒ 走 `RECT_*` / 旧紧凑档，**一个像素都不变**。
var _mobile_layout := false
## ⚠️ **只给自检用**：真机由 `EveUiScale.is_mobile()` 决定；桌面端跑不到手机档，
##    而手机档的几何是纯函数、必须能在 Windows 上验（见 `verify_ui_scale` 第 8 段）。
@export var force_mobile_layout: bool = false
## 当前生效的缩放倍数（1.0 = 设计稿原尺寸）
var _ui_scale := 1.0
## 键 → 实际矩形。`_build_layout()` / `refresh_layout()` 都读它。
## ⛔ 唯一真相源：别在别处直接引用 `RECT_*` 去摆窗 ——
##    那样紧凑档会**静默漏掉那一扇**（窗还在 1080 的坐标上，掉出屏幕）。
var _rect_tbl: Dictionary = {}
## 上次铺矩形时的设计空间（用来判断「视口真的变了」，避免白刷）
var _last_design := Vector2.ZERO
## 上次铺矩形时用的**居中偏移**（非 16:9 分辨率档下不为零，见 `_apply_rects`）。
## ⚠️ 它让 `_on_resized()` 能在**桌面端**判断出「换分辨率档了、要重铺」——
##    没有它，从 1920×1080 切到 1920×1200 时内容会偏在半路上。
var _origin_applied := Vector2.ZERO

## 紧凑档默认收起的侧列。
##
## ⚠️ 是**收起**不是隐藏：点标题栏就能展开，功能一个不少（红线 9：不许摆
##    「看着在、点不了」的东西）。手机屏的纵向是稀缺资源，侧列默认让位给战场。
##
## ⛔ **不许把 `info`（舰船档案）写进来** —— 它自己实现了 128↔320 的收起/展开，
##    在 `_ready()` 里把 `collapsible` 置成了 false（两套收起会互相打架）。
##    写进来是个**静默的空操作**：看着像收了，其实什么都没发生。
##    （它只有 172×128，本来也不占地方。）
const COMPACT_COLLAPSED := ["syn", "eq", "aug", "log"]

## 紧凑档的边距常量（口径与设计稿一致：底部留 14、两条之间留 8）。
const COMPACT_PAD := 12.0
const COMPACT_BOTTOM := 14.0
const COMPACT_GAP := 8.0
## 字号放大时「商店」会长高多少（**实测标定**）。
##
## ⚠️⚠️ 为什么必须有这个数：商店的**矩形**是设计稿写死的 158 高，但它里面的
##    行会被字撑开 ⇒ 实测 1.00 档 **161**、1.30 档 **173**。
##    而它是**贴底**摆的（y 908 + 高）⇒ 高出来的部分直接往屏幕外长：
##    实测 1.30 档底边 **1081 > 1080**，最后一行被切掉。
##    ⇒ 按这个斜率把底部两条整体**上抬**同样的量，底边就钉住不动。
##    代价是战场少一条 —— 这是「只放大字」必然要付的（界面缩放那种整齐放大不会）。
##
## ⚠️ 改字号上限、或改商店内部排版之后，**必须重新量一次**这个斜率
##    （量法：跑 `tools/_probe_font.tscn`，看两次打印的商店 `size.y` 之差）。
const SHOP_FONT_GROW := 40.0

## ── 手机专用布局（2026-10-13 评审稿定稿）────────────────────────────
##
## ⛔⛔ **这条路的唯一入口是 `_mobile_layout`**，它只在「移动平台 + 紧凑档」为真。
##    桌面端恒 false ⇒ 11 项矩形逐项等于 `RECT_*`（见 `verify_ui_scale` 第 3 段）。
##
## 与桌面档的差别（评审稿：默认战场态 / 边缘吸附态 / 结算态 + 2026-10-13 二修）：
##   ① **侧列加宽** 172 → 274（左）/ 259（右）：手机上「窗口太小」是实测第一条反馈；
##   ② **顶条加高** 40 → 54：按钮是 `SIZE_FILL`，条一高就跟着高 ⇒ 手指够得着；
##   ③ **底部两条高度沿用设计稿**（⛔ 不许压矮 —— 商店内容最小约 135px，
##      压到 100 会把最后一行静默切掉），只把「让出的侧列宽度」188 → 300；
##   ④ **折叠 = 吸附到屏幕边缘**（`MOBILE_DOCK_*`），每组各自成标签、单组点开。
##
## ★★ 2026-10-13 二修（用户四点反馈，样稿 `outputs/android_ui_review/index_v2.html`）：
##   ① 左列再收窄 274 → 242（约 12%）—— 右列不动（用户只说左边栏）；
##   ② 左列纵向重分配：舰队构成 268 → 240，装备栏位 116 → **300**
##      （「左边还有高度」；装备是 8 格 2×4，格子越大越好点）；
##   ③ 设置窗改**横向栏目**（视频/音频/界面/游戏）+ 宽窗定高，不再纵向堆叠出屏；
##   ④ 舰船档案**默认整窗隐藏**，只有点中具体舰船才亮起（不再常驻占右列）。
##
## ⚠️ 手机档**不**默认收起侧列（旧紧凑档是收的）：评审稿的默认战场态里
##    舰队构成 / 战斗日志是**展开**的 —— 它们是玩家做选择的参考信息，
##    收起来就失去了「扫一眼就能拿到」的初衷；想让位给战场时由玩家自己折叠。
const MOBILE_TOP_H := 64.0
const MOBILE_SIDE_W := 242.0          ## 左列宽（舰队构成 / 装备 / 增益）
const MOBILE_SIDE_W_R := 259.0        ## 右列宽（舰船档案 / 战斗日志）
const MOBILE_EDGE := 25.0             ## 侧列离屏幕边缘
const MOBILE_SIDE_RESERVE := 300.0    ## 底部两条必须让出的侧列宽度
const MOBILE_COL_GAP := 10.0          ## 侧列内部上下间距
## 左列纵向分配（2026-10-13 二修）：构成压矮、装备吃高度
## ⚠️ 2026-10-26：羁绊组合 3 → 5 组（+后勤 +电子战）⇒ 桌面内容最小高 306，
##    手机字号 120% 下折算 ≈（306−32 间距）×1.174＋32 ≈ 354，加外框 41 ≈ 395。
##    给到 **412** 留 17px（字号再大一档也不切行）。
##    ⚠️ 短屏（设计高 720）仍不重叠：左列会自动让装备压到设计稿下限 116，增益窗贴到屏底。
const MOBILE_SYN_H := 412.0           ## 舰队构成（手机字号 120% 下的完整内容槽位）
const MOBILE_EQ_H := 300.0            ## 装备栏位（PC 设计稿是 116；8 格 2×4 拉高）
## 事件增益：**内容真实最小高度实测 158**（3 条增益 + 标题栏）。
## ⚠️ 旧值借用 `RECT_AUG.size.y`=140 —— 用内容最小高度撑破 ⇒ 一出现就压住装备栏
##    甚至顶出屏（2026-10-20 实测）。⛔ 别再用设计稿高度当手机档高度。
const MOBILE_AUG_H := 158.0
## 设置窗（横向栏目态）：**屏宽的一半**。
##
## ★ 2026-10-13 二修：用户「设置页面太宽，收窄到 1/3 或者 1/2」。
##   取 **1/2** 而不是 1/3，两个理由：
##    ① 1/3（~470）会把「背景星云」的 2 列选择块和底栏（恢复默认 + 说明 + 完成）
##       压到刚好放下 —— 手机上是给手指点的，不留余量就是误触；
##    ② 视频类设置（天空盒 / 氛围 / 雾）改完要**能看见背后的画面**，
##       半屏窗两侧各留 1/4 屏，1/3 只留 1/6。
##   上下界：420 = 2 列选择块 + 底栏仍放得下的最小宽；1000 = 平板级封顶
##   （⛔ 别随屏宽无限放大 —— 那会退回「太宽」的老问题）。
const MOBILE_SETTINGS_W_FRAC := 0.5
const MOBILE_SETTINGS_W_MIN := 420.0
const MOBILE_SETTINGS_W_MAX := 1000.0
## 高度定死、内容区自己滚（「栏目只切换内容，不改变设置窗高度」）
const MOBILE_SETTINGS_H := 560.0
## 折叠后贴在边缘的那枚标签（评审稿：约 160 × 60 物理像素）
const MOBILE_DOCK_W := 118.0
const MOBILE_DOCK_H := 44.0
const MOBILE_DOCK_GAP := 8.0
## 结算页（评审稿 1300 × 770 物理 ⇒ 963 × 570 设计）：手机上要「读一屏数字」
const MOBILE_RESULT_W := 963.0
const MOBILE_RESULT_H := 570.0

## 底部两条**必须让出**的侧列宽度（左列 8..180，再留 8px 缝）。
## ⚠️ 少了它，窄屏（1.35 档下的 16:9 手机：设计宽只有 1422）上
##    备战席会横着压到装备栏上。
const COMPACT_SIDE := 188.0


## 当前设计空间（= 视口 ÷ 拉伸倍数）。
##
## ⚠️ **实现已收口到 `EveLayout.design_space()`**（唯一真相源）——
##    主菜单 / 牌桌 / 战场三处都要按同一口径算，抄第二份必然漂移。
func _design_space() -> Vector2:
	return LAYOUT.design_space(get_window())


## 紧凑档（移动端）布局 —— **纯函数**：设计空间进、矩形出。
##
## ⚠️ 提成 static 是为了**能单独自检**（verify_ui_scale 直接喂真实手机尺寸，
##    不需要真的跑在安卓上）。这也是本工程「抽单一来源函数」那条惯例。
##
## 与设计稿（`RECT_*`）的区别只有三处，但每一处都是必需的：
##   ① 顶条 / 底部两条**水平居中** —— 手机屏比 16:9 宽，设计稿按 1920 靠左会飘；
##   ② 商店 / 备战席**贴底** —— 设计高不再是 1080，绝对 y 会让它们掉出屏幕；
##   ③ 底部两条**让出侧列宽度** —— 否则窄屏上会横向压到装备栏。
## 侧列（舰队构成 / 装备 / 增益 / 档案 / 日志）**保持设计稿的纵坐标**：
## 它们是收起态的细条（见 `COMPACT_COLLAPSED`），而保持设计稿间距能保证
## 「展开之后彼此仍然不重叠」。
static func compact_rects(d: Vector2) -> Dictionary:
	var w := maxf(640.0, d.x)
	var h := maxf(480.0, d.y)
	# ① 顶条：居中
	var top_w := minf(RECT_TOP.size.x, w - 2.0 * COMPACT_PAD)
	var top := Rect2((w - top_w) * 0.5, RECT_TOP.position.y, top_w, RECT_TOP.size.y)
	# ② 底部两条：先让出侧列宽度，再居中；商店贴底、备战席骑在它头上
	var avail := maxf(320.0, w - 2.0 * COMPACT_SIDE)
	var shop_w := minf(RECT_SHOP.size.x, avail)
	var shop := Rect2((w - shop_w) * 0.5, h - RECT_SHOP.size.y - COMPACT_BOTTOM,
			shop_w, RECT_SHOP.size.y)
	var bench_w := minf(RECT_BENCH.size.x, avail)
	var bench := Rect2((w - bench_w) * 0.5,
			shop.position.y - COMPACT_GAP - RECT_BENCH.size.y,
			bench_w, RECT_BENCH.size.y)
	# ③ 居中的大窗（事件 / 结算 / 设置）：在「顶条以下、备战席以上」这段里居中
	var mid := (RECT_TOP.position.y + RECT_TOP.size.y + bench.position.y) * 0.5
	var ev_w := minf(RECT_EVENT.size.x, w - 2.0 * COMPACT_PAD)
	var res_w := minf(RECT_RESULT.size.x, w - 2.0 * COMPACT_PAD)
	# 抽奖窗：比事件窗高一大截，按「顶条以下、备战席以上」这段可用高度夹一次
	var lot_h := minf(LOTTERY_MAX_H,
			maxf(220.0, bench.position.y - RECT_TOP.end.y - 16.0))
	return {
		"top": top,
		"syn": Rect2(RECT_SYN.position, RECT_SYN.size),
		"eq": Rect2(RECT_EQ.position, RECT_EQ.size),
		"aug": Rect2(RECT_AUG.position, RECT_AUG.size),
		"info": Rect2(w - 8.0 - RECT_INFO.size.x, RECT_INFO.position.y,
				RECT_INFO.size.x, RECT_INFO.size.y),
		"log": Rect2(w - 8.0 - RECT_LOG.size.x, RECT_LOG.position.y,
				RECT_LOG.size.x, RECT_LOG.size.y),
		"shop": shop,
		"bench": bench,
		"event": Rect2((w - ev_w) * 0.5, mid - RECT_EVENT.size.y * 0.5,
				ev_w, RECT_EVENT.size.y),
		"lottery": Rect2((w - ev_w) * 0.5, mid - lot_h * 0.5, ev_w, lot_h),
		"result": Rect2((w - res_w) * 0.5, mid - RECT_RESULT.size.y * 0.5,
				res_w, RECT_RESULT.size.y),
		"settings": settings_rect(Vector2(w, h)),
	}


## 手机档侧列宽（左 / 右）—— 按全站刻度 **0.18 × 屏宽**（见 `EveUiMetrics.R_SIDE`）。
##
## ★ 2026-10-21（阶段 0-5）：242/259 → 18%W（1784 宽上是 **321**）。
##   依据：主菜单模式列 22.4%W，HUD 侧列原来只有 13.6%W ⇒ 差一档，所以手机上"窗太小"。
##   取 18% 而非 22.4% 是**折中**：战场仍要留得下（⛔ 别改成对齐）。
## ⚠️ `mobile_rects()` **只给手机档用**，所以这里直接按比例算、不判平台；
##    桌面端走 `RECT_*`，永远不经过这里。
static func _side_w(d: Vector2, _left: bool) -> float:
	return maxf(200.0, maxf(320.0, d.x) * UI_METRICS.R_SIDE)


## 手机专用布局（移动端 + 紧凑档）—— **纯函数**：设计空间进、矩形出。
##
## ⚠️ 提成 static 是为了**能单独自检**（`verify_ui_scale` 直接喂真实手机尺寸，
##    不需要真的跑在安卓上）。⛔ 桌面端**永远不调用**它。
##
## ⚠️ 只输出「位置与尺寸」，不折叠任何窗 —— 折叠与否是玩家的事（见
##    `MOBILE_SIDE_W` 那段注释），折叠后的落位由 `mobile_dock_rects()` 给。
##
## ★ 2026-10-19：加 `safe_left`。真机横屏左侧有 96px 挖孔，原来左列贴 `MOBILE_EDGE`
##   直接压在挖孔上（用户：「安全区还是要避让一下」）。现在左列从
##   `safe_left + MOBILE_EDGE` 起，底部两条的居中带也按左右真实占用重新算，
##   ⛔ 不能只挪左列 —— 那会让商店/备战席与左列重叠。
##   ⚠️ 默认值 0 ⇒ 桌面/探针/旧断言的行为**一像素不变**。
static func mobile_rects(d: Vector2, safe_left: float = 0.0,
		aug_visible: bool = true, syn_need: float = 0.0,
		aug_need: float = 0.0) -> Dictionary:
	var w := maxf(640.0, d.x)
	var h := maxf(480.0, d.y)
	var lx := MOBILE_EDGE + maxf(0.0, safe_left)
	var rx := MOBILE_EDGE
	# ① 顶条：在「左安全区 ~ 右边缘」之间居中 + 加高
	var top_w := minf(1000.0, w - lx - rx)
	var top := Rect2(lx + (w - lx - rx - top_w) * 0.5, 18.0, top_w, MOBILE_TOP_H)
	# ② 底部两条：贴底；高度沿用设计稿（内容最小高度决定的，⛔ 不能压矮）
	#    ⚠️ 居中带 = 左右两列**实际占用**之间的剩余宽度（⛔ 不再是固定 300/侧）；
	#       含安全区时左右不对称，用固定 reserve 会让两条压到左列上。
	#       ★ 无安全区时必须与旧口径（固定 `MOBILE_SIDE_RESERVE`）**逐像素一致**，
	#         否则既有断言/桌面手机档全部平移 —— 故两者取 max。
	var left_res := maxf(MOBILE_SIDE_RESERVE, lx + _side_w(d, true) + MOBILE_COL_GAP)
	var right_res := maxf(MOBILE_SIDE_RESERVE, rx + _side_w(d, false) + MOBILE_COL_GAP)
	var band_l := left_res
	var band_w := maxf(320.0, w - left_res - right_res)
	var shop_h := RECT_SHOP.size.y
	var shop_w := minf(RECT_SHOP.size.x, band_w)
	var shop := Rect2(band_l + (band_w - shop_w) * 0.5, h - COMPACT_BOTTOM - shop_h, shop_w, shop_h)
	var bench_h := RECT_BENCH.size.y
	var bench_w := minf(RECT_BENCH.size.x, band_w)
	var bench := Rect2(band_l + (band_w - bench_w) * 0.5,
			shop.position.y - COMPACT_GAP - bench_h, bench_w, bench_h)
	# ③ 侧列：加宽 + 贴边（纵向间距沿用「展开后仍不重叠」的那套口径）
	#    ★ 2026-10-13 二修：左列内部纵向重分配 —— 构成压矮、装备吃高度
	#      （「左边还有高度」；装备 8 格 2×4，格子在手机上越大越好点）
	var col_top := top.end.y + 12.0
	var syn := Rect2(lx, col_top, _side_w(d, true), MOBILE_SYN_H)
	# ★ 装备吃高度，但**不许把增益窗顶出屏**：左列总高（构成+间距+装备+间距+增益）
	#   必须留在屏内。增益默认隐藏，可「一旦出现」就是在 screen 外 —— 那种bug
	#   不报错、只是玩家永远点不到它。短屏（设计高 720）上装备按上界收缩，
	#   ⛔ 但不小于设计稿的 116（再小就没法用了）。
	#
	# ★★ 2026-10-20 实测修正（真机重叠的根因）：
	#   ① `舰队构成` 的内容最小高度 = **277**，旧值 240 ⇒ PanelContainer 被内容撑到
	#      277，正好压住下面 27px 的装备栏 —— 这是用户截图里那处重叠。
	#   ② `事件增益` 带 3 条增益时最小高度 = **158**，旧值借了设计稿 140 ⇒ 同样会涨。
	#   ③ `装备栏位` 反而是**可压缩**的（最小 150），所以让它吃剩余高度。
	#   ⇒ 口径改成「定值取实测最小、装备取剩余」，且**按增益是否可见**分配。
	#
	# ★★★ 2026-10-20 二次修正（用户「还是那样」的真因）：
	#   常数 280 只在**桌面字号 110%** 下成立。手机字号默认 **120%**（`EveUiScale`
	#   的移动端默认），同样的 242 宽会多折出一行 ⇒ 内容最小高度 > 280，窗口再次
	#   被撑高、再次压住装备栏。**任何写死的高度都会在这条路上迟早失效。**
	#   ⇒ 由调用方传入**实测内容高度**（`syn_need` / `aug_need`），纯函数只做像素运算；
	#     默认 0 = 回落到常量，验收/桌面调用不受影响。
	var syn_h := MOBILE_SYN_H
	# 短屏上先保住装备栏最小槽位，再压缩增益窗外框；其内容由窗口内裁剪宿主承接。
	var aug_h := minf(maxf(MOBILE_AUG_H, aug_need),
			maxf(0.0, h - col_top - syn_h - 2.0 * MOBILE_COL_GAP - RECT_EQ.size.y))
	var eq_h := maxf(minf(MOBILE_EQ_H,
			h - col_top - syn_h - 2.0 * MOBILE_COL_GAP
			- (aug_h if aug_visible else 0.0)),
			RECT_EQ.size.y)
	var eq := Rect2(lx, syn.end.y + MOBILE_COL_GAP, _side_w(d, true), eq_h)
	var aug := Rect2(lx, eq.end.y + MOBILE_COL_GAP,
			_side_w(d, true), aug_h)
	var info_x := w - rx - _side_w(d, false)
	var info := Rect2(info_x, col_top, _side_w(d, false), RECT_INFO.size.y)
	var log := Rect2(info_x, info.end.y + MOBILE_COL_GAP,
			_side_w(d, false), RECT_LOG.size.y)
	# ④ 居中的大窗：在「顶条以下、备战席以上」那段里居中
	#    ⚠️ 结算页例外 —— 它是打断式页面，允许盖住底部两条（评审稿就是这么排的），
	#        但整扇必须在屏内（否则「继续下一节点」按钮点不到）。
	var band_top := top.end.y
	var band_bot := maxf(band_top + 120.0, bench.position.y)
	var mid := (band_top + band_bot) * 0.5
	var ev_w := minf(RECT_EVENT.size.x, band_w)
	var res_w := minf(MOBILE_RESULT_W, band_w)
	# 抽奖窗（手机档）：与事件窗同宽同列，高度按「顶条以下、备战席以上」夹
	var lot_h := minf(LOTTERY_MAX_H,
			maxf(220.0, bench.position.y - band_top - 16.0))
	var res_h := minf(MOBILE_RESULT_H, h - band_top - 2.0 * MOBILE_EDGE)
	var res_y := clampf(band_top + (h - band_top - res_h) * 0.5,
			band_top + 8.0, maxf(band_top + 8.0, h - MOBILE_EDGE - res_h))
	# ★ 设置窗（横向栏目态）：**屏宽一半** + 定高，在「顶条以下」整段里竖直居中。
	#   ⚠️ 不再按 `mid`（顶条~备战席的中线）摆 —— 定高 560 会把备战席盖住一半；
	#      它是模态窗，允许压底部两条，但**整扇必须在屏内**（`set_tabbed` 由
	#      `_apply_rects` 同步铺，见那里）。
	var set_w := clampf(w * MOBILE_SETTINGS_W_FRAC,
			MOBILE_SETTINGS_W_MIN, MOBILE_SETTINGS_W_MAX)
	set_w = minf(set_w, band_w)
	var set_h := minf(MOBILE_SETTINGS_H, h - band_top - 2.0 * MOBILE_EDGE)
	var set_y := band_top + (h - band_top - set_h) * 0.5
	return {
		"top": top,
		"syn": syn,
		"eq": eq,
		"aug": aug,
		"info": info,
		"log": log,
		"shop": shop,
		"bench": bench,
		"event": Rect2(band_l + (band_w - ev_w) * 0.5, mid - RECT_EVENT.size.y * 0.5,
				ev_w, RECT_EVENT.size.y),
		"lottery": Rect2(band_l + (band_w - ev_w) * 0.5, mid - lot_h * 0.5, ev_w, lot_h),
		"result": Rect2(band_l + (band_w - res_w) * 0.5, res_y, res_w, res_h),
		"settings": Rect2(band_l + (band_w - set_w) * 0.5, set_y, set_w, set_h),
	}


## 手机档「折叠后贴边」的标签位 —— **纯函数**（与 `mobile_rects` 同源）。
##
## ⛔ **不含 `info`（舰船档案）**：它自己实现了 128↔320 的收起/展开，
##    `collapsible == false`，把停靠位塞给它是个静默的空操作（点了不会贴边）。
##    ⇒ 它保持原位（本来就只有 259×128，不占地方），其余各组各自吸附。
##
## 排布：左右两组各自**在可用带里垂直居中**成一列，从上到下按「侧列原有顺序」。
static func mobile_dock_rects(d: Vector2, safe_left: float = 0.0) -> Dictionary:
	var tbl := mobile_rects(d, safe_left)
	var w := maxf(640.0, d.x)
	var top: Rect2 = tbl["top"]
	var bench: Rect2 = tbl["bench"]
	var band_top := top.end.y
	var band_bot := maxf(band_top + 120.0, bench.position.y)
	var cy := (band_top + band_bot) * 0.5
	var out := {}
	var left := ["syn", "eq", "aug"]
	var lh := float(left.size()) * MOBILE_DOCK_H \
			+ float(left.size() - 1) * MOBILE_DOCK_GAP
	var ly := cy - lh * 0.5
	for i in left.size():
		out[left[i]] = Rect2(maxf(0.0, safe_left),
				ly + float(i) * (MOBILE_DOCK_H + MOBILE_DOCK_GAP),
				MOBILE_DOCK_W, MOBILE_DOCK_H)
	# 右列：只有战斗日志能折叠（舰船档案自带收起，见上面注释）
	var right := ["log"]
	var rh := float(right.size()) * MOBILE_DOCK_H \
			+ float(right.size() - 1) * MOBILE_DOCK_GAP
	var ry := cy - rh * 0.5
	for i in right.size():
		out[right[i]] = Rect2(w - MOBILE_DOCK_W,
				ry + float(i) * (MOBILE_DOCK_H + MOBILE_DOCK_GAP),
				MOBILE_DOCK_W, MOBILE_DOCK_H)
	return out


## 按当前档位算出矩形表。
## ⚠️ 桌面分支的 10 扇窗仍是 `RECT_*` 原封不动；唯独设置窗在 2026-10-13
##    改成与手机同一套栏目窗（`settings_rect()`）—— 用户：「同步改到PC端」。
func _refresh_rect_tbl() -> void:
	_last_design = _design_space()
	if _mobile_layout:
		# ⚠️ 增益窗默认隐藏：不占位 ⇒ 装备栏能吃到 300（否则白留 168px 空档）。
		#    `set_augments()` 会触发 refresh_layout，所以显隐变化后表会重算。
		var aug_on := augments_window != null and augments_window.visible
		# ★ 2026-10-30（玩家反馈）：「事件变多了，事件栏位没变多，多于 3 个不显示」。
		#   真凶就是这里 —— 以前不带 `aug_need`，`mobile_rects` 只能回落到
		#   `MOBILE_AUG_H`=158（正好 3 行），第 4 行被内容宿主裁掉。
		#   现在把增益窗自己算的 `content_need_h()` 传进去，槽位随条数长。
		var aug_need := 0.0
		if aug_on and augments_window.has_method("content_need_h"):
			aug_need = float(augments_window.call("content_need_h"))
		_rect_tbl = mobile_rects(_last_design, _safe_left(), aug_on, 0.0, aug_need)
	elif _compact:
		_rect_tbl = compact_rects(_last_design)
	else:
		_rect_tbl = {
			"top": RECT_TOP, "syn": RECT_SYN, "eq": RECT_EQ, "aug": RECT_AUG,
			"info": RECT_INFO, "log": RECT_LOG, "shop": RECT_SHOP,
			"bench": RECT_BENCH, "event": RECT_EVENT, "result": RECT_RESULT,
			"lottery": RECT_LOTTERY,
			"settings": settings_rect(_last_design),
		}
	# ★ 字号放大 ⇒ 底部两条整体上抬（两个档位都要，见 `SHOP_FONT_GROW`）。
	#   ⚠️ 放在两个分支**之外**：紧凑档同样是贴底摆的，同样会被字撑出去。
	var g := _bottom_grow()
	if g > 0.01:
		for key in ["shop", "bench"]:
			var r: Rect2 = _rect_tbl[key]
			_rect_tbl[key] = Rect2(r.position.x, r.position.y - g, r.size.x, r.size.y)


## 字号带来的底部抬升量（设计字号档 = 0：⛔ 不能让默认档有一像素漂移）。
## 一扇窗**内容**需要的高度（内容最小高 + 外框：标题栏 + 内边距）。
##
## ⚠️ 为什么不用 `get_combined_minimum_size()`：`EveWindow` 会把当前矩形写进
##    `custom_minimum_size`，于是「最小高度 ≥ 当前高度」⇒ 读它只会**越撑越大**
##    （棘轮效应）。内容节点（`content`）的最小高度只由子控件决定，才是真需求。
## ⚠️ 外框高度取「窗口实际高 − 内容实际高」，首帧还没布局时回落标题栏 26。
func _win_need_h(w: EveWindow) -> float:
	if w == null:
		return 0.0
	var c: Control = w.get("content")
	if c == null:
		return 0.0
	var chrome := w.size.y - c.size.y
	if chrome < 1.0:
		chrome = 26.0
	return maxf(0.0, c.get_combined_minimum_size().y + chrome)


## 移动端左侧安全区（**设计空间**像素）—— 桌面恒 0。
##
## ⚠️ 安全区来自 `EveMobileLayout.safe_rect()`（逻辑视口口径），而 HUD 布局吃的是
##    `_design_space()`。两者在真机上通常相等（2408×1080），但分辨率档会乘
##    `content_scale_factor` ⇒ 必须按比例换算一次，⛔ 不能直接拿逻辑像素去摆。
func _safe_left() -> float:
	if not _mobile_layout or not is_inside_tree():
		return 0.0
	var safe := MOBILE.safe_rect(get_tree())
	var lv := MOBILE.logical_size(get_tree())
	if lv.x < 1.0:
		return maxf(0.0, safe.position.x)
	return maxf(0.0, safe.position.x * (_last_design.x / lv.x))


func _bottom_grow() -> float:
	return maxf(0.0, (FONT.scale - 1.0) * SHOP_FONT_GROW)


## 取当前档位的矩形（表还没算出来时回落设计稿）。
func _r(key: String) -> Rect2:
	var v = _rect_tbl.get(key)
	return RECT_TOP if v == null else v


## 键 → 窗对象。
func _win_of(key: String) -> EveWindow:
	match key:
		"top": return command_bar
		"syn": return synergy_window
		"eq": return equipment_window
		"aug": return augments_window
		"info": return dossier_window
		"log": return log_window
		"shop": return shop_window
		"event": return event_window
		"lottery": return lottery_window
		"result": return result_window
		"settings": return settings_window
	return null


## 把当前档位的矩形铺到所有窗 + 备战席轨道。
##
## ★ 2026-10-07：**加居中偏移** `o` —— 非 16:9 的分辨率档（1920×1200 之类）下
##   设计空间比 1920×1080 大，按死坐标摆的内容会贴在左上、边缘露出空白。
##   ⚠️ 紧凑档**不加**：`compact_rects()` 自己就是按设计空间居中排的，
##      再叠一层就是重复偏移。
##   ⚠️ 偏移记进 `_origin_applied`，`_on_resized()` 靠它判断「桌面端要不要重铺」。
func _apply_rects() -> void:
	if command_bar == null:
		return                       # 还没建（`_ready` 之前）
	if _rect_tbl.is_empty():
		# 防御：正常路径（`_build_layout` / `refresh_layout`）都会先算表。
		# ⛔ 但少了这一道，空表会让每扇窗都摆到 `RECT_TOP`（叠成一堆），
		#    而且**不报任何错** —— 值得一行兜底。
		_refresh_rect_tbl()
	var o := Vector2.ZERO if _compact else LAYOUT.origin(get_window())
	_origin_applied = o
	# ★★ 2026-10-13 二修之四：手机档舰船档案**默认整窗隐藏**，
	#    只有选中具体舰船才亮起 —— 不再常驻占右列 259×128（用户原话
	#    「不要一直在那」）。桌面档恒可见（PC 一个像素都不动）。
	#    ⚠️ 必须在铺矩形**之前**算：下面「日志上移」要读它的 visible。
	if dossier_window != null:
		if _mobile_layout:
			dossier_window.visible = _selected_ship != null
		else:
			dossier_window.visible = true
	# ★★ 二修之三：设置窗**全平台**横向栏目（2026-10-13 用户定「把设置更新也
	#    同步改到PC端」）—— `_ready` 自建时就已 `_tabbed = true`，这里不再反向
	#    下命令（原来按 `_mobile_layout` 强设，会把 PC 拽回竖向长条）。
	for key in ["top", "syn", "eq", "aug", "info", "log",
			"shop", "event", "lottery", "result", "settings"]:
		var w: EveWindow = _win_of(key)
		if w == null:
			continue
		var r := _r(key)
		# ★ 档案隐藏时，战斗日志上移到档案位（右列不留一个空洞）；
		#   档案亮起时它退到档案**当前高度**的下方（展开 320 / 收起 128
		#   —— 高度由档案窗自己管，`set_window_height` 已把 `_height_owned`
		#   置真，所以这里读 `size.y` 就是真值，⛔ 别去 `get()` 脚本常量）。
		if _mobile_layout and key == "log" and dossier_window != null:
			var log_y := _r("info").position.y
			if dossier_window.visible:
				log_y += dossier_window.size.y + MOBILE_COL_GAP
			r = Rect2(r.position.x, log_y, r.size.x, r.size.y)
		w.set_window_rect(r.position.x + o.x, r.position.y + o.y, r.size.x, r.size.y)
	if bench_rail != null:
		var b := _r("bench")
		bench_rail.position = b.position + o
		bench_rail.size = b.size
		bench_rail.custom_minimum_size = b.size
	# ★ 手机档：把「折叠后贴边」的落位告诉侧列（设计空间会变 ⇒ 每次重铺都要重设）
	_apply_mobile_docks()


## 手机档的停靠位下发 / 非手机档的清理。
##
## ⚠️ 必须在**每次**重铺时跑：手机横竖屏一转，设计空间就变了，
##    边缘标签还留在旧坐标上就会跑出屏幕（而且它是折叠态，玩家一眼看不出）。
## ⚠️ 非手机档必须**主动清空** —— 否则「先跑过一次手机档、再切回桌面档」时，
##    窗上还挂着停靠位，折叠就会莫名贴边（桌面端不允许这种行为）。
func _apply_mobile_docks() -> void:
	var docks := mobile_dock_rects(_last_design, _safe_left()) if _mobile_layout else {}
	for key in ["syn", "eq", "aug", "log", "info"]:
		var w: EveWindow = _win_of(key)
		if w == null:
			continue
		if _mobile_layout:
			w.set_dock_rect(docks.get(key, Rect2()))
			w.set_collapsed_height(MOBILE_DOCK_H)
		else:
			w.set_dock_rect(Rect2())
			w.set_collapsed_height(0.0)


## 应用 UI 缩放档。
##
## ⚠️ **只有一个入口**（开局由主控调、玩家改设置由设置窗信号调）——
##    分散成两处必然出现「窗里写着 135%、实际是 125%」。
##
## ⚠️ 档位**真的变了**才会重铺：桌面端主控也会调一次（传 1.0），
##    那时 `_ui_scale` 已经是 1.0 ⇒ 直接返回 ⇒ **一个字节都不动**
##    （否则每次开局都会把玩家的窗口布局重置掉）。
func apply_ui_profile(scale: float) -> void:
	var s := maxf(1.0, scale)
	var compact := UI_SCALE_SCRIPT.is_compact(s)
	# ★ 手机档 = 移动平台 + 紧凑档（`force_mobile_layout` 只给自检开）
	#   ⚠️ 平台判据收口到 `EveUiScale.is_mobile_tier()`（唯一真源，
	#      设置窗的横向栏目读同一个函数）—— 别在这里再写一遍 and。
	#   ⛠⛠ 但 `force` **仍在 `compact` 的与关系里**：旧口径是
	#      `compact and (is_mobile or force)`，⛔ 不是 `(is_mobile and compact) or force`
	#      —— 后者会让「桌面档 + 自检强制」在切回 1.0 时赖在手机档不走
	#      （实测：停靠位清不掉，verify_ui_scale 第 8 段当场红）。
	var mobile := compact and (UI_SCALE_SCRIPT.is_mobile_tier(s) or force_mobile_layout)
	var changed := (not is_equal_approx(s, _ui_scale)) or compact != _compact \
			or mobile != _mobile_layout
	_ui_scale = s
	_compact = compact
	_mobile_layout = mobile
	var win := get_window()
	if win != null and not is_equal_approx(win.content_scale_factor, s):
		win.content_scale_factor = s
	if not changed and not _rect_tbl.is_empty():
		# ★ 即便不重建表，也要在内容排完后再校一次高度 —— 首次进战场时
		#   `_ready` 里的那次 refresh 跑在内容布局之前，量到的高度是 0。
		if _mobile_layout:
			_relayout_until_stable()
		return
	# 档位变了 ⇒ 先让每扇窗忘掉旧档位下摆的位置。
	# ⚠️ 必须做：设计空间都不一样了，旧坐标留着只会错位
	#（玩家拖动记录是绝对像素，`_effective_rect()` 会优先用它）。
	for key in ["top", "syn", "eq", "aug", "info", "log",
			"shop", "event", "lottery", "result", "settings"]:
		var w: EveWindow = _win_of(key)
		if w != null:
			w.reset_layout()
	refresh_layout()
	# ⚠️ 手机档**不**默认收起侧列：评审稿的默认战场态里它们是展开的
	#    （决策参考信息，收起来就丢了「扫一眼就能拿到」的初衷）。
	#    ⇒ 只有非手机的紧凑档（如今只剩自检会走到）沿用旧的默认收起。
	if _compact and not _mobile_layout:
		for key in COMPACT_COLLAPSED:
			var w2: EveWindow = _win_of(key)
			if w2 != null:
				w2.set_collapsed(true)
	# ★★ 2026-10-20（真机 364 vs 280 的真因）：上面这次 `refresh_layout()` 跑在
	#   **内容还没完成第一次布局**的时候 ⇒ `_win_need_h()` 量到的是 0/旧值，
	#   于是按 280 排；下一帧内容长到 364，窗口被撑高、压住装备栏（用户截图那处）。
	#   ⇒ 等布局稳定后再排（幂等；最多三帧）。
	if _mobile_layout:
		_relayout_until_stable()


## 按当前档位重铺一遍（切档位 / 设备旋转 / 设计空间变化）。
func refresh_layout() -> void:
	if command_bar == null:
		return
	_refresh_rect_tbl()
	_apply_rects()


## ★ 玩家换了**窗口分辨率**（设置窗的「显示」分区）⇒ 重铺。
##
## ⚠️ 两件事都要做，少一件都是静默错位：
##   ① **清掉玩家的拖动记录**（`_user_rect` 是绝对像素，基准原点变了之后
##      它指向的位置就不再是玩家想要的那个地方）—— 与 `apply_ui_profile`
##      切档位时的处理同源；顺带也清掉「已收起」的记忆，避免新旧坐标混着用。
##   ② 重铺：偏移 `o` 由 `_apply_rects()` 按**新的**设计空间算。
func on_resolution_changed() -> void:
	for key in ["top", "syn", "eq", "aug", "info", "log",
			"shop", "event", "lottery", "result", "settings"]:
		var w: EveWindow = _win_of(key)
		if w != null:
			w.reset_layout()
	refresh_layout()


## 设计空间变了 ⇒ 重铺。
##
## ⚠️ 桌面端**原本立刻返回**（布局是设计稿的绝对坐标、与视口无关）。
##    2026-10-07 加了分辨率档之后这条不再完全成立：**非 16:9 的档**会让设计空间
##    比基准大 ⇒ 居中偏移 `o` 变了 ⇒ 必须重铺，否则内容还停在旧偏移上。
##    ⇒ 桌面端只在「偏移真的变了」时重铺。**这一条是本函数的全部要点**：
##      少了它，从 1920×1080 切到 1920×1200 时 HUD 会偏在半路上。
func _on_resized() -> void:
	var o := Vector2.ZERO if _compact else LAYOUT.origin(get_window())
	if o != _origin_applied:
		refresh_layout()
		return
	if not _compact:
		return
	if _design_space().is_equal_approx(_last_design):
		return
	refresh_layout()


## 玩家在设置窗里换了缩放档。
##
## ⚠️ 这个信号**不往主控转发** —— 缩放是 HUD 自己的事：
##    3D 战场跑在原生分辨率上（`canvas_items` 只缩放 2D 画布），
##    所以它不需要任何「跟着改相机」的动作。转发出去只会让两层都以为该管。
func _on_ui_scale_picked(v: float) -> void:
	apply_ui_profile(UI_SCALE_SCRIPT.resolve(v))


## 玩家改了字号。
##
## ⚠️ 分两件事，⛔ 别混在一处：
##    · 「字体本身」由**设置窗**就地 `FONT.reapply()`（它离玩家最近，要即时）；
##    · 「版面」由 HUD 重铺 —— 字号会撑高商店，底部两条得跟着上抬（见 `SHOP_FONT_GROW`）。
func _on_font_scale_changed(_v: float) -> void:
	refresh_layout()



# ------------------------------------------------------------------ 对外接口

## 选中一艘船 → 刷新右上档案窗（同时把它所在舰队喂给羁绊统计）
func show_ship(ship: EveShip) -> void:
	_selected_ship = ship
	if dossier_window and dossier_window.has_method("set_ship"):
		dossier_window.set_ship(ship)
	# ★ 2026-10-13 二修之四：手机档档案是「点船才亮起」的 ⇒ 选中态一变
	#   就重铺一次（`_apply_rects` 里同步可见性，并让战斗日志让位/回位）。
	#   ⚠️ 只在手机档做 —— 桌面档档案恒可见，重铺纯属浪费。
	if _mobile_layout:
		refresh_layout()


func get_selected_ship() -> EveShip:
	return _selected_ship


## 喂当前场上/备战席的舰队 —— 羁绊窗与档案窗的 n/m 都从这一份算
func set_fleet(ships: Array, fleet_is_demo: bool = false) -> void:
	_fleet = ships
	if fleet_is_demo:
		return
	if synergy_window and synergy_window.has_method("set_fleet"):
		synergy_window.set_fleet(ships)
	if dossier_window and dossier_window.has_method("set_fleet"):
		dossier_window.set_fleet(ships)


## 装甲墙状态（炼狱 BOSS 关）—— 由 `battle_scene._refresh_barrier_ui()` 喂。
##
## ★★ 2026-11-01（用户定案，A 项）：这个机制以前在界面上完全不显示。
## ⚠️ 参数是**算好的数值**而不是 run 对象：羁绊窗不该知道 `EveRunState` 的存在，
##    否则"UI 读业务对象"这条线一破，下次谁都能从面板里摸局内状态。
func set_barrier(power: float, need: float, mult: float, on: bool) -> void:
	if synergy_window and synergy_window.has_method("set_barrier"):
		synergy_window.set_barrier(power, need, mult, on)


func append_log(entry) -> void:
	if log_window and log_window.has_method("append_entry"):
		log_window.append_entry(entry)


func clear_log() -> void:
	if log_window and log_window.has_method("clear_log"):
		log_window.clear_log()


## 商店报价（元素 = EveShipDatabase 出来的 Dictionary）
func set_shop_offers(offers: Array) -> void:
	if shop_window and shop_window.has_method("set_offers"):
		shop_window.set_offers(offers)


## ★ 阶段闸门：只有准备阶段能买卖（2026-10-05）。
##
## ⚠️ 商店面板是**常驻**的（不随阶段显隐），少了这道闸门就会出现
##    「结算/战斗阶段卡片亮着，点了被 run 拒、卡片毫无变化」——
##    玩家理解成「点了没反应、东西也没到手」。
func set_shop_buy_enabled(on: bool) -> void:
	if shop_window and shop_window.has_method("set_buy_enabled"):
		shop_window.set_buy_enabled(on)


## 打捞框。入参 = `EveRunState.salvage_info()` 的输出（**唯一输入源**）。
## ★ C-P1-1 契约收口（2026-10-11）：值域以数据源为准——
##   {"state": "list", …}       有残骸待捡（**结算页**打捞区消费；
##                              商店框按空态+引导渲染，见 eve_shop.set_salvage）
##   {"state": "repairing", …}  已下单等到账
##   {}                         空
func set_salvage(info: Dictionary) -> void:
	if shop_window:
		shop_window.set_salvage(info)


## 已获取的事件增益（元素 = EveRunState.picked_event_info() 的输出）。
## 空数组 = 整窗隐藏（开局与 V3 稿逐像素一致）。
func set_augments(list: Array) -> void:
	if augments_window == null or not augments_window.has_method("set_augments"):
		return
	var was := augments_window.visible
	augments_window.set_augments(list)
	# ★ 手机档：增益窗**显隐会改变左列分配**（不占位 ↔ 占 158px）⇒ 必须重排，
	#   否则「窗口出现」这一下仍按旧表摆，装备栏会与它叠在一起。
	if _mobile_layout and augments_window.visible != was:
		refresh_layout()
		# ⚠️ 还得多排：`set_augments` 刚把行显示出来时，容器的**最小尺寸**
		#   还没重算（实测首帧仍是空态的 367）⇒ 等到稳定再铺，否则会把 158
		#   的矩形撑成 367，增益窗顶出屏。
		_relayout_until_stable()


## 等内容布局稳定后再排（最多 `tries` 帧）。
##
## ⚠️ 为什么不是「等一帧」：`_ready` 里那次 refresh 跑在容器排序之前，一帧后
##    内容最小高度往往还是 0（实测要第二帧才量到真值 364）。
## ⚠️ 判据用**内容真实高度是否不再变化**，不是比较矩形 —— 矩形相同时也可能
##    内容刚刚变高（那正是「撑破窗口」的前一刻）。
func _relayout_until_stable(tries: int = 3) -> void:
	var last := -1.0
	for i in tries:
		await get_tree().process_frame
		if not is_inside_tree() or command_bar == null:
			return
		var need := _win_need_h(synergy_window)
		if i > 0 and absf(need - last) < 0.5:
			break
		last = need
		refresh_layout()


## 打开事件四选一面板。
##
## meta 走标题栏右侧（如「节点 4 · 4 选 1」），line 是节点的进场词。
func show_event(options: Array, line: String = "", meta: String = "") -> void:
	if event_window == null:
		return
	event_window.show_options(options, line, meta)
	event_window.visible = true
	event_window.move_to_front()


## 打开事件「选 1 艘船」面板（与四选一共用同一个窗口，只是换成选船模式）
func show_ship_pick(options: Array, line: String = "", meta: String = "") -> void:
	if event_window == null:
		return
	event_window.show_ship_pick(options, line, meta)
	event_window.visible = true
	event_window.move_to_front()


func hide_ship_pick() -> void:
	if event_window:
		event_window.visible = false
		event_window.close_panel()


## 打开舰船抽奖（炼狱专属 · 事件「黑市情报」）。
##
## ⚠️ 与事件面板一样是**打断式**的：没有关闭按钮，玩家必须抽完点「完成」。
##    这是有意的 —— 抽奖是白给的东西，但流程上它挡着节点推进，
##    不给"关掉它"就等于不给"跳过奖励"这种自伤选项。
func show_lottery(pool: Array, line: String = "", meta: String = "") -> void:
	if lottery_window == null:
		return
	lottery_window.show_lottery(pool, line, meta)
	lottery_window.visible = true
	lottery_window.move_to_front()


## 把抽取结果画进抽奖窗（几条都行，取决于 `EveRunState.LOTTERY_DRAW_TIMES`）。
func show_lottery_result(results: Array) -> void:
	if lottery_window == null:
		return
	lottery_window.show_result(results)


func hide_lottery() -> void:
	if lottery_window:
		lottery_window.visible = false


func lottery_is_open() -> bool:
	return lottery_window != null and lottery_window.visible


func hide_event() -> void:
	if event_window:
		event_window.visible = false


func event_is_open() -> bool:
	return event_window != null and event_window.visible


## 「选 1 艘船」面板是否开着（事件节点需要指定目标时）。
## AI 操作面靠它区分「四选一」和「选船」两个子状态。
## 「放弃打捞」确认框（AI 操作面透传，见 EveResult）。
func salvage_ask_open() -> bool:
	if result_window == null or not is_instance_valid(result_window):
		return false
	return bool(result_window.call("salvage_ask_open"))


func confirm_salvage_ask() -> void:
	if result_window != null and is_instance_valid(result_window):
		result_window.call("confirm_salvage_ask")


func cancel_salvage_ask() -> void:
	if result_window != null and is_instance_valid(result_window):
		result_window.call("cancel_salvage_ask")


func ship_pick_is_open() -> bool:
	return event_window != null and event_window.visible \
			and event_window.has_method("ship_pick_is_open") \
			and bool(event_window.call("ship_pick_is_open"))


# ------------------------------------------------------------------ 结算页（阶段 D）

## 打开结算页。res 的形状见 EveResult.show_result 的说明。
func show_result(res: Dictionary) -> void:
	if result_window == null:
		return
	result_window.show_result(res)
	result_window.visible = true
	result_window.move_to_front()


## 收起结算页。**顺手把打捞浮层也收掉**（2026-10-04）。
##
func hide_result() -> void:
	if result_window:
		result_window.visible = false


func result_is_open() -> bool:
	return result_window != null and result_window.visible


# ------------------------------------------------------------------ 设置窗（阶段 D）

## 打开设置窗。
##
## ⚠️ 打开时必须**回写当前真实状态**（state 参数）——
##    否则窗里显示的是上次的旧值，玩家看到一个和实际不符的开关，
##    点一下反而把状态改成了他不想要的那个。
## ⚠️ state 是**一整份**字典而不是拆开的参数列：设置项每加一项就要改一次
##    签名的话，迟早会漏改一处调用点（而漏改的表现是「窗里少同步了一项」，
##    不报错）。现在主控把真实状态整包递进来，窗自己按 key 取。
func show_settings(state: Dictionary) -> void:
	if settings_window == null:
		return
	settings_window.set_state(state)
	# ★ 2026-10-20 用户定：**每次打开都回到「视频」栏目**（图一同款默认态）。
	#   ⚠️ 窗是常驻实例，不重置就会停在上次看的那一页（比如关掉前在「音频」）——
	#      玩家会以为「设置自己跳页了」。⛔ 别改成"记住上次栏目"。
	if settings_window.has_method("_show_tab"):
		settings_window.call("_show_tab", "video")
	settings_window.visible = true
	settings_window.move_to_front()


func hide_settings() -> void:
	if settings_window:
		settings_window.visible = false


func settings_is_open() -> bool:
	return settings_window != null and settings_window.visible


## 设置窗里的「棋盘」开关状态由场景侧回写（KEY_B 也能改它，两条路要一致）
func sync_settings_toggle(key: String, on: bool) -> void:
	if settings_window and settings_window.has_method("_set_toggle"):
		settings_window.call("_set_toggle", key, on)


## 暂停 / 解除暂停 —— 遮罩的**唯一**入口。
##
## ══ 为什么必须有一层全屏遮罩 ══════════════════════════════════════
##  「暂停之后禁止操作」这句话在 Godot 里有三种实现，只有一种是对的：
##    ① 在每个 handler 里加 `if paused: return` —— 漏一个就是「暂停了还能买船」，
##       而且漏掉一个**不报错**（本工程红线：散落的守卫必然腐烂）；
##    ② `get_tree().paused = true` —— 会把整个场景树停掉，
##       连设置窗自己的按钮都点不动（玩家直接卡死在暂停里）；
##    ③ **全屏遮罩吃掉鼠标** —— 一处生效，天然覆盖所有控件与 3D 输入，
##       且「谁还能被点到」变成**排列顺序**这个显式的、看得见的事实。
##  这里选 ③，键盘侧的守卫留给主控（遮罩管不到键盘）。
##
## ⚠️ 遮罩**不能**盖住设置窗 —— 否则玩家点完暂停、顺手关掉设置窗，
##    就再也没有鼠标能点的东西了（只能按空格）。所以每次上遮罩都把
##    设置窗提到最前；遮罩自己也带一个「继续对局」按钮作为兜底。
func set_paused(on: bool) -> void:
	if pause_veil == null:
		if not on:
			return
		pause_veil = _build_pause_veil()
		add_child(pause_veil)
	pause_veil.visible = on
	if on:
		if settings_window != null:
			# 设置窗开着才需要提到最前；关着的话遮罩上的按钮负责恢复
			if settings_window.visible:
				settings_window.move_to_front()
		if _drag_ghost != null:
			_drag_ghost.move_to_front()


## 主控改了暂停态（键盘空格 / 结算 / 重开）之后回写设置窗的按钮文字。
func sync_settings_pause(on: bool) -> void:
	if settings_window != null and settings_window.has_method("set_paused"):
		settings_window.call("set_paused", on)


## 暂停遮罩：半透明压暗 + 居中大字 + 一个「继续」按钮。
func _build_pause_veil() -> Control:
	var veil := Control.new()
	veil.name = "PauseVeil"
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_STOP
	veil.visible = false

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.04, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(box)

	var big := Label.new()
	big.text = T.t("HUD_PAUSED", "‖ 已暂停")
	FONT.fs(big, 34)
	big.add_theme_color_override("font_color", Color(0.55, 0.78, 0.82))
	big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	big.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(big)

	var small := Label.new()
	small.text = T.t("HUD_PAUSED_SUB", "对局已冻结 · 操作已锁定")
	FONT.fs(small, 13)
	small.add_theme_color_override("font_color", Color(0.44, 0.55, 0.59))
	small.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	small.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(small)

	var resume := Button.new()
	resume.text = T.t("HUD_RESUME", "▶ 继续对局")
	resume.custom_minimum_size = Vector2(180, 34)
	EveButtonTheme.apply(resume, "hud_main")
	FONT.fs(resume, 14)
	resume.pressed.connect(func(): pause_resume_requested.emit())
	box.add_child(resume)

	return veil


# ------------------------------------------------------------------ 伤害数字（阶段 D）

## 冒一个伤害飘字（屏幕坐标）。
##
## ⚠️ 屏幕坐标由**场景侧**算好传进来（`arena.world_to_screen`），
##    HUD 不认识 3D 世界，不该在这里反向依赖相机。
func pop_damage(screen_pos: Vector2, damage: float, quality: int, hit: bool) -> void:
	if damage_feed and damage_feed.has_method("pop"):
		damage_feed.call("pop", screen_pos, damage, quality, hit)


func clear_damage() -> void:
	if damage_feed and damage_feed.has_method("clear"):
		damage_feed.call("clear")
	# ★ 2026-10-30：播报条与飘字同一时刻清（重开 / 进准备阶段），
	#   否则上一局的战报会挂在新一局的布阵台上面。
	if damage_band and damage_band.has_method("clear"):
		damage_band.call("clear")


## 战斗播报：播一条「谁对谁打了多少 / 破了哪层」。
##
## `kind` = &"hit" / &"pierce" / &"shield" / &"armor" / &"kill"
## `mine` = true 我方造成（亮蓝），false 我方承受（红）
func push_damage_line(amount: int, mine: bool, kind: StringName, target_name: String) -> void:
	if damage_band and damage_band.has_method("push"):
		damage_band.call("push", amount, mine, kind, target_name)


# ------------------------------------------------------------------ 节点进场词横幅（阶段 C 收尾）

## 弹一段节点进场字幕。
##
## 参数：index = 节点号（1-based）· type_key = `EveNodeTable` 的 type 键 ·
##       line = 该节点的进场词。
##
## ⚠️ 只收 `type_key` 不收现成的中文标签 —— 类型文案的唯一真源是
##    `EveNodeTable.TYPE_LABELS`，在这里再传一个字符串进来就等于开了第二份。
func show_entry(index: int, type_key: StringName, line: String) -> void:
	if entry_banner and entry_banner.has_method("show_entry"):
		entry_banner.call("show_entry", index, type_key, line)


## 收掉横幅（开战 / 重开一局）。
func hide_entry() -> void:
	if entry_banner and entry_banner.has_method("clear"):
		entry_banner.call("clear")


## 横幅当前是否在显示（验收断言用）
func entry_banner_active() -> int:
	if entry_banner and entry_banner.has_method("active_count"):
		return int(entry_banner.call("active_count"))
	return 0


## 拿起 / 放下备战席舰船 —— 整块化作出售区
##
## ★ 2026-11-07：加了 `bench` 开关。结算（打捞）期要把商店**常亮成出售区**，
##   好让玩家知道「钱不够可以卖船」；但备战席轨道**不能**跟着亮 ——
##   它的 `_draw_selling()` 会写「拖到此处出售」，而落点判定里
##   备战席是**撤回 / 换位**、出售区只有商店窗。两处都亮橙就是撒谎。
func set_selling(on: bool, bench: bool = true) -> void:
	if shop_window:
		shop_window.set_selling(on)
	if bench and bench_rail:
		bench_rail.set_selling(on)
	elif bench_rail and not on:
		# 关的时候无论如何都要收（否则上一阶段的橙条会留在轨道上）
		bench_rail.set_selling(false)


## 备战席拿起的是第几格（-1 = 没拿起）—— 轨道上显示出「已拿起」标记
func set_bench_drag(index: int) -> void:
	if bench_rail:
		bench_rail.set_dragging(index)


func set_economy(coin: int, level: int, xp: int, xp_need: int,
		refresh_cost: int, levelup_cost: int) -> void:
	if shop_window:
		shop_window.set_economy(coin, level, xp, xp_need, refresh_cost, levelup_cost)


## 顶层"全刷"入口 —— 通过 `refresh_requested` signal 通知主控刷。
##
## ⚠️ 存在原因：调试按钮 / 自动化脚本（探针 / 录制回放）调 `hud.refresh()`
##    时不应该需要知道具体刷哪些子模块。把"全刷"封一个稳定接口名，调用方
##    写 `hud.refresh()` 就行；后续加新字段（信标 / 备战席 / 羁绊）也只需要
##    在主控 `_refresh_run_ui()` 里挂一句，不会让所有调用方跟着改。
##
## 实现走 signal 而非直接引用主控 —— hud 不需要知道主控的类型，
## 任何容器（主控 / 录制回放 / 自动化）接上 signal 都能响应。
##
## 性能上不是"每帧调"的接口（每帧调会刷一整组 set_* + 羁绊 list + 立绘），
## 调试按钮 / 一次性脚本触发 OK，**别放进 _process**。
func refresh() -> void:
	refresh_requested.emit()


func set_bench(used: int, cap: int) -> void:
	if shop_window:
		shop_window.set_bench(used, cap)


func set_equipment(items: Array) -> void:
	if equipment_window and equipment_window.has_method("set_slots"):
		equipment_window.set_slots(items)


func set_stage(index: int, label: String, total_time: float) -> void:
	if command_bar and command_bar.has_method("set_stage"):
		command_bar.set_stage(index, label, total_time)
	# 新阶段一开就把金线摆到正确长度（满条 / 不读秒），
	# 不等下一帧 tick —— 否则开镜那一帧会看到上一回合的残留长度。
	_push_stage_clock()


func tick_stage(delta: float) -> void:
	if command_bar and command_bar.has_method("tick"):
		command_bar.tick(delta)
	_push_stage_clock()


## 把顶条的倒计时读数推给备战席金线（读条）。
##
## ⚠️ 这是**单向投影**：本函数只读 `command_bar.time_left/time_total`，
##    不存时间、不递减 —— 那份计时器的唯一真相源在顶条（与
##    `stage_seconds_left()` 同一条规矩）。在这里减一次就等于两个时钟。
## ⚠️ 只有准备阶段读秒，理由见 `_phase` 的注释。
func _push_stage_clock() -> void:
	if bench_rail == null or not is_instance_valid(bench_rail):
		return
	if not bench_rail.has_method("set_stage_time"):
		return
	if _phase != 0 or command_bar == null:
		bench_rail.set_stage_time(0.0, 0.0)
		return
	bench_rail.set_stage_time(command_bar.time_left, command_bar.time_total)


## 当前阶段剩余秒数（向上取整）—— 倒计时滴答音要用。
##
## ⚠️ 为什么不让音频层自己去持有倒计时：
##    倒计时的**唯一真相源**是 `command_bar.time_left`（阶段总时长由
##    `set_stage` 给，`tick` 每帧递减）。音频层再存一份就会漂移 ——
##    和「别造第二份真相源」是同一条规则。
##    这里只做一个「读出来」的口子，不新增状态。
func stage_seconds_left() -> int:
	if command_bar == null:
		return -1
	return int(ceil(maxf(0.0, command_bar.time_left)))


## 顶条上的「战败 −N」预览。
## ⛔ 2026-10-01 改名：原来叫 `set_leak`，跟着已删除的漏网机制来的。
func set_loss_cost(damage: int) -> void:
	if command_bar:
		command_bar.loss_cost = damage
		command_bar.refresh()


## 信标结构值 —— 一局的生命线（交接文档 §11 P0，必须常驻可见）
func set_beacon(value: int, max_value: int = -1) -> void:
	if command_bar and command_bar.has_method("set_beacon"):
		command_bar.set_beacon(value, max_value)


## 顶条上的阶段：0 准备 / 1 战斗 / 2 结算
func set_phase(p: int) -> void:
	_phase = clampi(p, 0, 2)
	if command_bar and command_bar.has_method("set_phase"):
		command_bar.set_phase(p)
	# 切阶段立刻同步读条状态：别等下一次 tick_stage ——
	# 战斗开始时若还留着准备阶段的半截金线，会读成「准备还没结束」。
	_push_stage_clock()


## 开战按钮的文案 + 可用性（随阶段变：开战 / 交战中 / 下一节点 / 再来一局）
func set_start_button(text: String, enabled: bool = true) -> void:
	if command_bar and command_bar.has_method("set_start_button"):
		command_bar.set_start_button(text, enabled)


## 联机对战专用：整个撤掉开战按钮（一切以倒计时为准）。
func set_start_visible(on: bool) -> void:
	if command_bar and command_bar.has_method("set_start_visible"):
		command_bar.set_start_visible(on)


## 联机对战专用：开/关最后 10 秒的中央倒计时。单机恒关（那边仍靠开战键）。
func set_round_countdown_active(on: bool) -> void:
	if round_countdown != null and round_countdown.has_method("set_active"):
		round_countdown.call("set_active", on)


## 倒计时归零、真正开打的一瞬间：中央闪一下「开战」。
func play_countdown_flash() -> void:
	if round_countdown != null and round_countdown.has_method("flash"):
		round_countdown.call("flash")


## 同步商店的「锁定加速列表」按钮状态（锁定真正的语义在 EveRunState）
func set_shop_locked(on: bool) -> void:
	if shop_window and shop_window.has_method("set_locked"):
		shop_window.set_locked(on)


## 商店卡片是否买得起 —— 买不起的卡压暗，别让玩家点了才知道
func set_shop_affordable(coin: int) -> void:
	if shop_window and shop_window.has_method("set_affordable"):
		shop_window.set_affordable(coin)


# ------------------------------------------------------------------ 拖放（阶段 B5）

## 备战席格带的【可点击区域】。
##
## ⚠️ 比画出来的格带高 EveBenchRail.HIT_ABOVE。
##    ⚠️ 2026-09-23 改 2D 立绘后该值 48 → 10：立绘完全落在格子内，
##    不再需要为「3D 船身伸到控件外」留热区。留着 48 反而是隐患 ——
##    备战席顶 760、命中区一直伸到 712，而棋盘近端就在 762，
##    于是「点棋盘最下一行」会被判成「点备战席空格」（不报错、点了没反应）。
func bench_hit_rect() -> Rect2:
	if bench_rail == null:
		return Rect2(RECT_BENCH)
	var p := bench_rail.position
	var s := bench_rail.size
	if s.x <= 4.0:
		s = RECT_BENCH.size
		p = RECT_BENCH.position
	return Rect2(Vector2(p.x, p.y - EveBenchRail.HIT_ABOVE),
			Vector2(s.x, s.y + EveBenchRail.HIT_ABOVE + 4.0))


## 屏幕点落在备战席第几格（-1 = 没落在轨道上）
func bench_slot_at(screen_pos: Vector2) -> int:
	if bench_rail == null:
		return -1
	var r := bench_hit_rect()
	if not r.has_point(screen_pos):
		return -1
	return bench_rail.slot_at(screen_pos - bench_rail.position)


func set_bench_hover(index: int) -> void:
	if bench_rail:
		bench_rail.set_hover(index)


## 喂备战席名单（格子里画 2D 立绘用）。entries 元素 = {"ship_key", "star"}
##
## ⚠️ 转发而不是让 battle_scene 直接摸 bench_rail：
##    HUD 的对外接口一律走本类（bench_hit_rect / bench_slot_at / set_bench_drag
##    都是这样），多一层转发换来的是「谁能改 HUD 内部状态」这件事只有一个答案。
func set_bench_fleet(entries: Array) -> void:
	if bench_rail:
		bench_rail.set_fleet(entries)


## 出售区矩形 = 商店窗的实时矩形（含标题栏）。
##
## ⚠️ 必须读实时矩形，不能读 RECT_SHOP 常量 —— 商店是【可拖动/可缩放的窗口】，
##    玩家把它挪走之后，常量指向的位置就成了一张空桌子。
func sell_zone_rect() -> Rect2:
	if shop_window == null:
		return Rect2(RECT_SHOP)
	return Rect2(shop_window.position, shop_window.size)


## 设置拖动幽灵。info：{} = 隐藏；
## 否则 {name, star, cost, color, hint, hint_ok, screen}
func set_drag_ghost(info: Dictionary) -> void:
	if _drag_ghost == null:
		return
	_drag_ghost.apply(info)


## 拖动中「指针真的进了出售区」的高亮（出售区 = 商店窗实时矩形）。
##
## ⚠️ 与 set_selling() 的区别，别混用：
##    set_selling()     = 整块变橙（商店窗 **+** 备战席轨道），是「出售模式」的总开关，
##                        只在进入/退出准备阶段时用。
##    set_sell_hot()    = 只点亮商店窗，跟随指针进出，语义是「松手就卖在这里」。
##
##    为什么不把备战席轨道也点亮：轨道是「撤回 / 换位」的落点。
##    两个区域都亮橙的话，玩家想撤回的船会被卖在自己脚下 —— 这是不可逆的损失。
func set_sell_hot(on: bool) -> void:
	if shop_window:
		shop_window.set_selling(on)


# ------------------------------------------------------------------ 演示数据

## 一键填演示内容。
##
## ⚠️ 只填「还没有真实数据」的部分 —— 每个窗口填之前都先看它是不是空的，
##    这样一旦 battle_scene 开始喂真数据，演示内容自然退场，不用手改开关。
func _apply_demo_content() -> void:
	if _demo_used:
		return
	_demo_used = true

	# 装备栏位（沿用 V3 稿的 6 件）
	set_equipment([
		{"icon": &"armor_plate", "color": Color(0.85, 0.68, 0.28)},
		{"icon": &"shield", "color": Color(0.35, 0.70, 0.90)},
		{"icon": &"chevrons", "color": Color(0.88, 0.52, 0.30)},
		{"icon": &"capacitor", "color": Color(0.50, 0.62, 0.86)},
		{"icon": &"targeting", "color": Color(0.55, 0.78, 0.82)},
		{"icon": &"railgun", "color": Color(0.52, 0.76, 0.55)},
	])

	# 商店：从权威表里按 1/1/1/2/3 费各取一艘（就是 V3 稿那 5 张卡的位置）
	var offers: Array = []
	var want := [["punisher", 0], ["kestrel", 0], ["rifter", 0],
			["coercer", 0], ["omen", 0]]
	for w in want:
		var d := EveShipDatabase.by_id(String(w[0]))
		if not d.is_empty():
			offers.append(d)
	set_shop_offers(offers)

	set_economy(47, 3, 14, 68, 2, 4)
	set_bench(2, BENCH_SLOTS)
	# 演示备战席立绘（2 艘，与上面的「2 / 8」对上）。
	# ⚠️ 只填「还没被真数据覆盖」的部分 —— battle_scene 一旦喂真数据，
	#    它会用 set_bench_fleet 覆盖掉这里（与其余窗口同一条约定）。
	set_bench_fleet([
		{"ship_key": &"executioner", "star": 1},
		{"ship_key": &"cormorant", "star": 2},
	])
	set_stage(6, "精英战", 60.0)

	# 舰队构成：拿演示商店那几艘当「当前舰队」，好让羁绊条有数
	_demo_fleet()

	append_log({"time": 6.0, "category": &"economy", "text": "胜利 星币 +5 连胜 +1"})
	append_log({"time": 6.1, "category": &"loot", "text": "刽子手级★1 → 备战席"})
	append_log({"time": 6.2, "category": &"salvage", "text": "下单 断崖级★1 −2 ◆"})
	append_log({"time": 6.3, "category": &"hint", "text": "距窗口关闭 00:24"})
	append_log({"time": 5.4, "category": &"buy", "text": "茶隼级 −1 ◆ → 备战席"})
	_set_demo_salvage()


func _demo_fleet() -> void:
	var ships: Array = []
	for key in ["punisher", "kestrel", "rifter", "executioner", "coercer",
			"cormorant", "omen"]:
		var s := EveShipDatabase.instantiate_by_id(key, 0, 0)
		if s != null:
			ships.append(s)
	set_fleet(ships)
	# 顺带把档案窗展开给一艘船看效果
	if ships.size() > 0:
		show_ship(ships[0])


func _set_demo_salvage() -> void:
	# ⚠️ 必须按 salvage_info() 的**真实值域**填（"list"/"repairing"/{}）。
	#    C-P1-1 收口前这里填的是 "wreck"——数据源永不产出的形态（旧口径遗留）。
	#    演示用 "repairing"：只读看板唯一能出内容的状态（空态只有引导文案）。
	set_salvage({"state": "repairing", "name": "断崖级", "star": 1, "cost": 4, "evt": 3})


# ------------------------------------------------------------------ 自绘件

## 拖动幽灵（阶段 B5）
##
## 跟手的小标签，回答玩家此刻最关心的两个问题：
##    「我手上拿的是哪艘」→ 名称 + ★n + ◆c
##    「松手会发生什么」  → 底部一行提示（放到第几行 / 出售返还多少 / 为什么不行）
##
## ⚠️ 为什么不在鼠标下放第二艘 3D 船：
##    投影进世界的第二艘船会随相机改变大小，而落格提示是屏幕空间的东西，
##    两种尺寸语言混在一起，玩家反而读不出「我到底要放到哪一格」。
##    云顶用的也是「手上挂一张卡」，不是把棋子贴在世界里。
class _DragGhost extends Control:
	## ⚠️ 内嵌类**看不到**文件级的 `FONT` ⇒ 自己 preload 一份（别写 `EveHudRoot.FONT`：
	##    那要等 class_name 注册，多一层「记得跑 --import」的隐性前提）。
	const FONT := preload("res://scripts/ui/eve_font.gd")
	const GHOST_SIZE := Vector2(178.0, 44.0)
	const OFFSET := Vector2(18.0, 16.0)

	var ship_name: String = ""
	var star: int = 1
	var cost: int = 1
	var accent: Color = Color(0.55, 0.78, 0.82)
	var hint: String = ""
	var hint_ok: bool = true

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = GHOST_SIZE
		size = GHOST_SIZE

	## info = {} 或 active=false → 隐藏；否则按字段重绘
	func apply(info: Dictionary) -> void:
		if info.is_empty() or not bool(info.get("active", false)):
			visible = false
			return
		ship_name = String(info.get("name", "—"))
		star = int(info.get("star", 1))
		cost = int(info.get("cost", 1))
		accent = info.get("color", accent)
		hint = String(info.get("hint", ""))
		hint_ok = bool(info.get("hint_ok", true))
		visible = true
		move_to_front()
		_follow(info.get("screen", Vector2.ZERO))
		queue_redraw()

	## 跟手，但整体夹在视口内（贴着屏幕右/下边缘时自动翻到鼠标另一侧）
	func _follow(sp: Vector2) -> void:
		var vp := get_viewport()
		var vs := vp.get_visible_rect().size if vp != null else Vector2(1920, 1080)
		var p := sp + OFFSET
		if p.x + GHOST_SIZE.x > vs.x - 4.0:
			p.x = sp.x - OFFSET.x - GHOST_SIZE.x
		if p.y + GHOST_SIZE.y > vs.y - 4.0:
			p.y = sp.y - OFFSET.y - GHOST_SIZE.y
		position = Vector2(maxf(4.0, p.x), maxf(4.0, p.y))

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, GHOST_SIZE)
		draw_rect(r, Color(0.055, 0.071, 0.082, 0.92), true)
		draw_rect(r, Color(0.42, 0.55, 0.60, 0.55), false, 1.0)
		draw_rect(Rect2(Vector2.ZERO, Vector2(3.0, GHOST_SIZE.y)), accent, true)

		var font := ThemeDB.fallback_font
		var tf := FONT.s(12)
		var tf_small := FONT.s(10)
		draw_string(font, Vector2(11.0, 18.0), "%s ★%d" % [ship_name, star],
				HORIZONTAL_ALIGNMENT_LEFT, GHOST_SIZE.x - 70.0, tf,
				Color(0.918, 0.969, 0.980))
		var cost_text := "◆ %d" % cost
		var cw := font.get_string_size(cost_text, HORIZONTAL_ALIGNMENT_LEFT, -1, tf).x
		draw_string(font, Vector2(GHOST_SIZE.x - 11.0 - cw, 18.0), cost_text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, tf, Color(0.851, 0.678, 0.278))
		draw_string(font, Vector2(11.0, 36.0), hint,
				HORIZONTAL_ALIGNMENT_LEFT, GHOST_SIZE.x - 22.0, tf_small,
				Color(0.522, 0.761, 0.851) if hint_ok else Color(0.878, 0.522, 0.302))
