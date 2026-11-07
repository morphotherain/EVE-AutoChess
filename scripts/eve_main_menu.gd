extends Control


## ★ 字号缩放（2026-10-07）：⛔ 别直接调 `add_theme_font_size_override`，
## 一律走 `FONT.fs(node, 设计字号)` —— 它同时记住设计字号（供改滑块时就地重算）。
## ⚠️ 子类（`extends eve_window.gd` 的那 9 个）靠**继承**拿到这个常量，
##    它们自己再写一个会撞名（基类已有同名成员 ⇒ 子类编译失败，本工程踩过）。
const FONT := preload("res://scripts/ui/eve_font.gd")
## EVE 自走棋 —— 主界面（启动后的第一个页面）
##
## ══════════════════════════════════════════════════════════════════
##  术语与它在整局里的位置
## ══════════════════════════════════════════════════════════════════
##
##     MainMenu（本文件）  ──「开始」──→  battle_scene.tscn（一局）
##            ↑                                    │
##            └────── 设置窗「返回主界面」──────────┘
##
##  这个页面叫**主界面 / 大厅（Main Menu / Lobby）**，不叫启动页
##  （Splash 是只显示 logo 的几秒过渡）、也不叫引导页（Onboarding 只在首次出现、
##  教操作）。「模式选择」本来就属于主界面这一层 —— 本页面把模式与难度合并进来了。
##
## ── 为什么是「左列模式按钮 + 右侧并列竖长条」────────────────────
##  用户明确要求：不要"大块大方框里放图"，要干净的左列选项 + 右侧内容；
##  难度分级要能放"三个甚至更多" ⇒ 一难一条竖长条，并列排。
##  定稿为作者本地的 HTML 高保真稿与出图（`<流水线工作目录>/ui_mainmenu/`，未入库）。
##
## ── 为什么背景是一张贴图而不是 3D 天空盒 ────────────────────────
##  菜单相机不动、也不缩放，所以用**离线烘好的 1920x1080** 最省也最准：
##  那张图是从 EVE 立方体星云**直接投出的针孔视角**（不经过等距柱状，
##  见 skill eve-nebula-skybox 第 5 节），星点层按用户实机截图统计量拟合。
##  ⚠️ 星点**不能**烘进游戏天空盒：局内相机 zoom 会变（DEFAULT_ZOOM=3.32），
##     zoom 改的是 FOV ⇒ 天空盒整体放大 ⇒ 1px 星点会跟着变大。
##     菜单没有这个问题（FOV 固定），所以这里烘进图里是安全的。
##
## ── 三层结构 ────────────────────────────────────────────────────
##  ① 底图 TextureRect（铺满，1:1 不缩放）
##  ② 品牌 + 系统项
##  ③ 左列模式按钮（3 个）+ 右侧难度长条（数量由难度表决定）
##
## ⚠️ 配色一律取自 EveWindow 的常量口径，禁止另起一套。
## ⚠️ 难度数据全部来自 EveCampaignTiers.difficulties() —— 本文件不许写死难度。
##    加一档难度 = 在表里加一条记录，本文件的条数与位置会自动跟上。

const TIERS := preload("res://scripts/data/eve_campaign_tiers.gd")
const BTN_THEME := preload("res://scripts/ui/eve_button_theme.gd")
const MENU_BG := preload("res://assets/backgrounds/caldari-c07-menu-1920x1080.png")
## 平台 UI 缩放档（主菜单只用它的 `apply_scene_default`）
const UI_SCALE_SCRIPT := preload("res://scripts/ui/eve_ui_scale.gd")
## ★ 非 16:9 分辨率下的**内容居中偏移**（见 EveLayout 顶注）。
const LAYOUT := preload("res://scripts/ui/eve_layout.gd")
## ★ 窗口分辨率档（2026-10-07）。⚠️ 只在桌面端生效，见 `EveResolution.is_enabled()`。
const RESOLUTION := preload("res://scripts/ui/eve_resolution.gd")
## ★ user:// 目录迁移（2026-10-07 项目名去掉「918」的收尾，见该文件顶注）
const USER_DIR := preload("res://scripts/core/eve_user_dir.gd")

## 一局场景（「开始」按钮的去处）
const BATTLE_SCENE := "res://scenes/battle_scene.tscn"
## ★ 2026-10-06 棋牌室（斗地主先行）。独立场景，与自走棋零耦合。
## 方案见 `docs/棋牌室-执行方案.md`。
const CARD_ROOM_MODE_ID := "cardroom"
## 斗地主牌局场景（观战模式：三个 AI 自动打）。P2 起从棋牌室卡片进入。
const DOUDIZHU_SCENE := "res://scenes/doudizhu.tscn"
## 联机对战大厅（真联机：建房 / 加入）
const VERSUS_LOBBY_SCENE := "res://scenes/versus_lobby.tscn"
## 开场剧情场景（**只在第一次玩时**经过它，见 `_on_start_pressed`）
const INTRO_SCENE := "res://scenes/intro_scene.tscn"
## 「第一次玩」的判据：第 1 模式（任务关卡）的第 1 难度（守卫边境）
const FIRST_MODE_ID := "campaign"
## 首次游玩播开场的「那一档难度」。
##
## ⛔⛔ 2026-10-28 修一个**静默失效八天**的 bug：这里原来写 `"guard_border"`
##    —— 那是任务关卡还没拆成四档难度时的旧 id。四档化之后难度 id 变成
##    `simple / normal / hard / inferno`（见 `EveCampaignTiers.DIFFICULTIES`），
##    于是 `tier_id == FIRST_TIER_ID` **永远为 false** ⇒
##    `target_scene_for_start()` 永远返回 BATTLE_SCENE ⇒
##    **新玩家第一次点「开始」直接跳进战斗，开场片头一次都没播过**。
##    表现是 `verify_intro` 长期挂一条红（"第一次玩 ⇒ 去开场（实际 battle_scene）"），
##    而人和代码都以为是测试过时 —— 实际是功能断了。
##    ⇒ `verify_intro` 已加断言「本常量必须等于 DIFFICULTIES[0].id」，
##      以后难度再改名会当场红，不会再静默。
const FIRST_TIER_ID := "simple"
const PROGRESS := preload("res://scripts/core/eve_progress_store.gd")
## ★ 2026-10-10 主界面 BGM。菜单原本**没有音频宿主**（见 `_build_sys` 里那条
##    「菜单上没有这个宿主」的说明）⇒ 要出声必须自己起一个只做
##    「总线音量 + 一条 BGM」的实例，与牌桌（ddz_table）同一套做法。
const AUDIO_SCRIPT := preload("res://scripts/core/eve_audio.gd")
## 设置存档（读音量初值 —— 让玩家在设置窗里调的音乐音量**在主界面照样生效**）
const STORE := preload("res://scripts/core/eve_settings_store.gd")
## ★ 2026-10-10 i18n：文案取词入口（见 eve_text.gd 顶注）。
const T := preload("res://scripts/core/eve_text.gd")
## ★ 2026-10-28 舰船图鉴：全屏浮层（见 `scripts/ui/eve_ship_codex.gd` 顶注）。
const CODEX_SCRIPT := preload("res://scripts/ui/eve_ship_codex.gd")
const SHIP_DB := preload("res://scripts/core/eve_ship_database.gd")
## 对局存档（`user://run.cfg`）—— 「继续上局」入口靠它判断有没有档。
const RUN_STORE := preload("res://scripts/core/eve_run_store.gd")
## ★ 2026-10-10 主界面「设置」窗 —— 与战场 / 牌桌**共用同一个类**，只是换档案。
##   用 `PROFILE_MENU`（音频 + 分辨率；⛔ 无字号、无返回主界面，理由见该类顶注）。
const SETTINGS_SCRIPT := preload("res://scripts/ui/panels/eve_settings.gd")
## 设置窗宽度（设计空间像素）。高度由窗自己按内容反推，⛔ 别在这里定。
const SETTINGS_W := 320.0

## ★ 2026-10-10 版权声明。它不是"游戏模式"，但对玩家来说就是**左边按钮列表最下面**
##   的一项，而且要和模式按钮**共用同一套选中样式与键盘导航** ⇒ 作为伪模式挂在
##   `_modes` 末尾（`credits = true`）。⛔ 不放进 EXTRA_MODES：那里是"可玩模式"的数据。
##
## ⚠️ 它是 `_modes` 里唯一 `cards` 为空的项 ⇒ 所有"按卡片下标"的路径都要先
##    `_is_credits()` 挡一下，否则左右键的 `% 0` 与开始的 `cards[0]` 会越界报错。
const CREDITS_MODE_ID := "credits"
## 版权声明大方框（右侧，正好占满难度卡片那块地方：3 列 × 964 宽 / 470 高）。
const CREDITS_W := 964.0
const CREDITS_H := 470.0

## ★ 2026-10-12 侧栏改**两层**（用户定）：第一层 自走棋 / 娱乐总汇 / 版权声明；
##   「自走棋」是**父项**（`parent: true`），`children` 为第二层（缩进显示，竖条排列）：
##   任务关卡 / 无尽模式 / 联机对战。
##   ⚠️ 父项**本身不承载卡片**：点它 = 展开/收起；展开时自动选中第一个子项。
##   ⚠️ 子项不新建 key 以外的文案 —— 模式名一律走 `MODE_<id>_NAME`（i18n 口径不变）。
## ★★ 2026-10-28 用户：「删除主菜单疆域选项，其他按钮顺势上移」⇒ 原来的第一项
##   「疆域」占位整项删除（连同 `TERRITORY_MODE_ID`）。侧栏是 VBoxContainer，
##   删掉后其余行自然上移，⛔ 不需要手工改任何 Y 坐标。
const AUTOCHESS_MODE_ID := "autochess"
## 联机对战（1 人类 + N AI）—— 多人架构的单机落地形态
const VERSUS_MODE_ID := "versus"
## 对手人数卡片：1v1 / 1v3 / 1v7（云顶是 8 人，这里给三档先跑通）
const VERSUS_AI_COUNTS := [1, 3, 7]
## 第二层行的缩进与高度（父行 MODE_H=62；子行略矮，形成层级感）
const SUB_INDENT := 26.0
const SUB_MODE_H := 54.0

# ══════════════════════════════════════════════════════════════════
#  配色（口径同 scripts/ui/eve_window.gd）
# ══════════════════════════════════════════════════════════════════
const C_TEXT := Color(0.70, 0.82, 0.85)
const C_TEXT_HI := Color(0.91, 0.96, 0.97)
const C_DIM := Color(0.44, 0.55, 0.59)
const C_ACCENT := Color(0.55, 0.78, 0.82)
const C_ACCENT_HI := Color(0.84, 0.95, 0.97)
const C_GOLD := Color(0.91, 0.76, 0.35)
const C_STRIP := Color(0.039, 0.055, 0.067, 0.66)
const C_STRIP_ON := Color(0.063, 0.094, 0.110, 0.78)
const C_STRIP_LOCK := Color(0.035, 0.047, 0.055, 0.60)
const C_STRIP_LOCK_ON := Color(0.051, 0.071, 0.082, 0.72)
const C_BORDER := Color(0.42, 0.55, 0.60, 0.34)
const C_BORDER_LOCK := Color(0.42, 0.55, 0.60, 0.26)
const C_SEP := Color(0.42, 0.55, 0.60, 0.24)

# ══════════════════════════════════════════════════════════════════
#  布局（照抄定稿稿，基准 1920x1080）
#
#  ⚠️ 坐标是**绝对像素**，与 EveHudRoot 的 RECT_* 同一口径。
#     窗口是 1920x1080 + stretch canvas_items/expand（见 project.godot），
#     所以这里按设计分辨率写死即可。
# ══════════════════════════════════════════════════════════════════
const BRAND_POS := Vector2(56, 76)
const MODES_POS := Vector2(56, 296)
const MODE_W := 300.0
const MODE_H := 62.0
const MODE_GAP := 14.0
const STRIP_POS := Vector2(660, 296)
## ⚠️ 2026-10-26：难度长条改成 **4 列**。原来是 3 列，4 个难度里的第 4 个
##    （炼狱）被挤到第二行、整块掉到屏幕外（按钮 y≈1194 > 视口 1080）
##    ⇒ **人也点不到**，AI 更点不到。宽度按「4 列 + 3 间隙」反推：
##    660 + 4×268 + 3×24 = 1804 < 1920，右侧还剩 116。
const STRIP_W := 268.0
const STRIP_H := 470.0
const STRIP_GAP := 24.0
## 棋牌室用**方框**（2 行 2 列），比难度竖条矮得多。
## ⚠️ 两套尺寸都由模式表里的 `layout` 决定，⛔ 不在卡片代码里写死 ——
##    见 `_layout_of()`。将来再加网格型模式（比如更多棋牌）直接复用。
const GRID_W := 300.0
const GRID_H := 196.0
const GRID_GAP_V := 24.0
const SYS_MARGIN_R := 120.0
const SYS_TOP := 88.0

## ★ 2026-10-12 改**两层侧栏**（用户定）：第一层 自走棋 / 娱乐总汇；
##   版权声明仍作为伪模式追加在最后（见 `_build_top_table()`）。
##
## ⚠️ `任务关卡` 不在这里 —— 它的副标题是**运行时取词拼出来的**（`_campaign_meta()`），
##    const 初始化器里调不了函数 ⇒ 由 `_build_top_table()` 现拼进 `autochess.children`。
##
## ⚠️ 认「自走棋」的是 `id` 而不是下标（见 `AUTOCHESS_MODE_ID`）。
## 联机对战的对手人数卡片。
##
## ⚠️ 做成函数而不是 const：EXTRA_MODES 是 const 数组，
##    里面要放「按 VERSUS_AI_COUNTS 生成」的卡片就只能调函数。
static func versus_cards() -> Array:
	var out: Array = []
	# ── 真人联机（放在最前面：这才是「联机对战」该有的入口）──
	# ⛔ 2026-10-27 用户口径：**不要**「人机 1v2 / 1v4」那种档位。
	#    人机是「补空位」用的，在房间座位表里点「加电脑」，不是一个独立玩法。
	out.append({
		"name": "创建房间", "code": "VERSUS_HOST", "open": true,
		"desc": "开一个房，把本机地址告诉对方；对方在大厅里填地址加入。"
				+ "房主点「开始对战」后双方同时进入同一局。",
		"stats": [["模式", "真人联机 · 房主", ""], ["端口", "37015", ""],
				["对手", "1~3 名真人", ""]],
	})
	out.append({
		"name": "加入房间", "code": "VERSUS_JOIN", "open": true,
		"desc": "填房主的地址（例如 192.168.1.10:37015）连进去，等房主开始。",
		"stats": [["模式", "真人联机 · 加入方", ""], ["地址", "大厅里填", ""],
				["对手", "真人 + 空位", ""]],
	})
	return out


const EXTRA_MODES: Array = [
	{
		# ★ 2026-10-12：新增父项「自走棋」。`children` = 第二层（缩进、竖条排列）。
		#   ⚠️ 它**没有 `cards`**：所有"按卡片下标"的路径都由 `_content_row_of()`
		#      回落到第一个子项（任务关卡），见该函数注释。
		"id": AUTOCHESS_MODE_ID, "name": "自走棋", "meta": "守卫边境 · 无尽 · 联机",
		"locked": false, "parent": true, "cards": [],
		"children": [
			{
				# ★ 2026-10-06 用户定：**「棋牌室」→「娱乐总汇」**（见下方 cardroom）。
				# ★ 2026-10-12：无尽模式从顶层**移进**「自走棋」第二层，显示为待开发。
				"id": "endless", "name": "无尽模式", "meta": "待开发", "locked": true,
				"cards": [{
					"name": "无尽模式", "code": "ENDLESS", "open": false,
					"desc": "没有终点。一波接一波的敌方舰队，波数越高吨位越重、编制越脏。"
							+ "撑到撑不住为止，只比谁走得更远。",
					"stats": [["对手", "电脑舰队 · 无限波次", ""], ["终点", "无 · 直到全灭", ""],
							["纪录", "—", "gold"], ["状态", "待开发", ""]],
				}],
			},
			{
				# ★ 2026-10-12：原顶层「多人对战」改名**「联机对战」**并移入第二层。
				#   ⚠️ id 仍是 `versus`（沿用既有 key，⛔ 别改 id —— 会连带动 i18n/验收）。
				# ★★ 2026-10-27：**从占位改成真模式** —— 单机落地形态是「1 人类 + N AI」，
				#    跑的就是 EveMatchState 那套多人架构（阶段 x 回合 / 配对 / 掉血 / 淘汰）。
				#    以后接真人联机只换「同时准备」那一步，房间逻辑不动。
				"id": VERSUS_MODE_ID, "name": "联机对战",
				"meta": "人机 · 1v1 / 1v4 / 1v8", "locked": false,
				# ⚠️ cards 留空 —— EXTRA_MODES 是 const，调不了 versus_cards()。
				#   真卡片由 _build_top_table() 注入（见那里的 versus 分支）。
				"cards": [],
			},
		],
	},
	{
		# ★ 2026-10-06：娱乐总汇（原「棋牌室」）。用户定的名字来源：EVE 里本来就有
		#   「娱乐总汇」这种供人消遣的场所；而且它顺手解决了「代币叫什么」
		#   —— ⇒ **娱乐币**。
		#   ⚠️ 2026-10-12 起它排在第 3 位（第一层第 3 项），展示方式不变。
		"id": CARD_ROOM_MODE_ID, "name": "娱乐总汇", "meta": "斗地主 · 可试玩", "locked": false,
		# ★ 2026-10-06 改：**不再用独立场景**（原 `card_room.tscn` 已删）。
		#   点「娱乐总汇」直接在主菜单右侧铺开这 4 张卡，排成 2 行 2 列
		#   （列数与卡片尺寸见 `_layout_of()`）。
		#   ⚠️ `open` 决定两件事：卡片是否压暗 + 「开始」按钮是否可点。
		#      斗地主 `open=true`（P0 阶段点了会给「制作中」提示，⛔ 不静默）；
		#      其余三个 `open=false` ⇒ 真禁用。
		"cards": [
			{
				"name": "斗地主", "code": "DOUDIZHU", "open": true,
				"desc": "一副牌，三个对手。抢地主、炸弹、王炸。",
				"stats": [["玩法", "斗地主", ""], ["对手", "电脑 · 3 人", ""],
						["状态", "开发中", ""]],
			},
			{
				"name": "川麻", "code": "SICHUAN", "open": false,
				"desc": "四川麻将 · 血战到底。缺一门、刮风下雨。",
				"stats": [["玩法", "四川麻将", ""], ["对手", "电脑 · 3 人", ""],
						["状态", "待开发", ""]],
			},
			{
				"name": "日麻", "code": "RIICHI", "open": false,
				"desc": "立直麻将。役种、宝牌、振听。",
				"stats": [["玩法", "立直麻将", ""], ["对手", "电脑 · 3 人", ""],
						["状态", "待开发", ""]],
			},
			{
				"name": "升级", "code": "SHENGJI", "open": false,
				"desc": "拖拉机 · 4 人 2 队。亮主反主、甩牌抠底。",
				"stats": [["玩法", "升级", ""], ["对手", "电脑 · 3 人", ""],
						["状态", "待开发", ""]],
			},
		],
	},
]

var _modes: Array = []
var _mode_idx: int = 0
var _pick: Dictionary = {}          ## mode_id → 选中的难度下标

var _mode_btns: Array[Button] = []
var _mode_names: Array[Label] = []
var _mode_metas: Array[Label] = []
var _mode_bars: Array[ColorRect] = []
var _mode_arrows: Array[Label] = []
## ★ 2026-10-12 两层侧栏：`_top` = 第一层（自走棋 / 娱乐总汇 / 版权声明），
##   `_modes` = **可见行**（父项 + 展开时的子项）—— 下游（选中 / 卡片 / 键盘）一律
##   按 `_modes` 索引，父项/子项展开收起只影响这张可见表（见 `_rebuild_rows()`）。
var _top: Array = []
## 「自走棋」的子项是否展开（默认展开：新玩家一眼能看到三个玩法）。
var _expanded := true
## 侧栏行的容器（展开/收起要整列重建，所以持有引用）。
var _modes_col: VBoxContainer = null
var _strip_row: GridContainer = null
## 当前模式的卡片尺寸 / 列数 —— 由 `_rebuild_strips()` 每次按模式设好，
## `_make_strip()` 只读它。⛔ 别在 `_make_strip` 里直接引用 STRIP_W/H：
## 那样棋牌室会被画成 470 高的竖条。
var _card_w := STRIP_W
var _card_h := STRIP_H
var _strip_panels: Array[PanelContainer] = []
var _strip_bars: Array[ColorRect] = []
## ★ 内容居中层：除底图之外的一切都挂在它身上（非 16:9 分辨率下整体平移）。
var _content: Control = null
## ★ 主界面 BGM 宿主。
## ⚠️ 声明成 **Variant** 而不是 `Node`：`AudioStreamPlayer` 之外的成员
##    （`set_volume` / `play_music`）在 `Node` 基类上没有，写死类型会**解析失败**
##    —— 牌桌踩过同一个坑，见 `ddz_table` 的同款说明。
var _audio: Variant = null
## ★ 2026-10-10 版权声明大方框。**只建一次**，之后靠 `visible` 切换 ——
##    每次 `_refresh()` 重建会让文字闪一下，也白白丢掉旧节点的引用。
var _credits_panel: PanelContainer = null
## ★ 2026-10-10 设置窗（`eve_settings.gd` 的 `PROFILE_MENU` 档案）。
## ⚠️ 声明成 **Variant**：要调 `set_state()` / `set_window_rect()` / `move_to_front()`
##    这些 `Control` 基类上没有的成员，写成具体类型会**解析失败**（牌桌踩过同款坑）。
var _settings: Variant = null
## 右上角「设置」按钮（开 / 关同一扇窗）。
var _settings_btn: Button = null
## 「继续上局」（有对局存档时才 `visible`；见 `_build_sys`）。
var _continue_btn: Button = null
## ★ 2026-10-28 图鉴入口按钮（只在「任务关卡」难度卡片下面显示）与浮层实例。
var _codex_btn: Button = null
var _codex: Control = null
## ★ 2026-10-30 热更状态行（版本号**上方**那行小字）。
##   ⚠️ 文本为空时整行隐藏 —— 平时玩家看到的还是干净的主界面，
##      只有「正在下载 / 已就绪重启生效 / 校验失败」时才有话说。
## ★ 2026-11-07：诊断上报宿主（心跳 / 崩溃取证 / 手动反馈）。
## ⛔⛔ **不许**写成 `EveReport.xxx` —— 它不是 autoload。见 `_boot_reporter()`。
const REPORT_SCRIPT := preload("res://scripts/core/eve_report.gd")
var _reporter: Node = null

var _update_tag: Label = null
## ★ 2026-11-07（二版）：更新检查器 + 进度面板。
##
## ⛔⛔ **第一版的教训（b39 事故，别再重犯）**：那时把「检测/下载/进度」全放进
##      `EveUpdater`（autoload），主菜单靠 `_up_has()` 查它的新成员再连信号。
##      可 autoload 节点在 pck 挂载**之前**就实例化了，用的永远是基础包里的老脚本
##      ⇒ 老客户端上三个成员全是 false ⇒ `_wire_updater()` 直接 return
##      ⇒ **弹窗代码在真实玩家机器上一次都没跑过**。
##
## [WHY] 现在：检查器是本文件 `new()` 出来的普通 Node，自己读 build_info、自己拉
##       清单、自己下载校验，**一个 `EveUpdater.xxx` 都不碰**。主菜单脚本会被 pck
##       覆盖，所以这套逻辑以后可以靠热更改。
const UPDATE_UI := preload("res://scripts/core/eve_update_ui.gd")
const UPDATE_PANEL := preload("res://scripts/ui/eve_update_panel.gd")
## ⚠️ 不标注类型（`Node` / `Control`）：它们各自有自定义方法（`show_ask` /
##    `begin_download` …），标成基类会让静态检查在调用点报「不存在该方法」。
var _upd = null
var _upd_panel = null
## ★ 2026-11-01 鸣谢名单：版本号上方按钮 + 右侧独立面板。
##   ⚠️ 只建一次，之后靠 `visible` 切换（与版权声明面板同口径，避免闪烁 / 丢引用）。
var _ack_panel: PanelContainer = null
var _ack_btn: Button = null


func _ready() -> void:
	# ★ 2026-10-10 i18n：**必须早于任何 UI 构建** —— 文案是建的时候取词的。
	T.apply_saved()
	# ★★ 第一件事：把**旧项目名**下的存档搬过来（2026-10-07 改显示名的一次性收尾）。
	#    ⚠️ 必须排在所有 `user://` 读写**之前** —— 下面 `RESOLUTION.apply_from_settings()`
	#       就要读 `settings.cfg`，晚了会读到"空设置"再用默认值覆盖回去，
	#       玩家的音量/字号/分辨率就**静默重置**了（迁移反而变成破坏）。
	#    ⚠️ 幂等：目标已存在的文件不动 ⇒ 每次启动都跑也无所谓。
	USER_DIR.migrate_legacy()
	# 防御：被 `SCRIPT.new()` 直接造出来时锚点是默认值（尺寸 0x0），
	# 底图 TextureRect 锚满父节点就等于没画 ⇒ 整张图全黑。真场景（.tscn）里
	# 锚点已经设好了，这一行不会生效。
	if size == Vector2.ZERO:
		set_anchors_preset(Control.PRESET_FULL_RECT)
	# ★ 主菜单**恒定 1.0 缩放**（2026-10-07）。
	#   ⚠️ `content_scale_factor` 是根窗口属性，跨场景不会自动复位 ——
	#      不写这一句就变成「进过一次战场 ⇒ 回主菜单也被放大」，
	#      而本菜单是按 1920×1080 死坐标 + 1:1 烘好的背景图做的（放大就散了）。
	#   ⚠️ 它不是「清掉玩家的设置」：值还在 settings.cfg 里，下次进战场照样放大。
	UI_SCALE_SCRIPT.apply_scene_default(get_window())
	# ★ 字号缩放：主菜单**恒定 100%**（2026-10-07，用户实测）。
	#   ⚠️ 为什么不是 `load_from_settings()`：主菜单是按 1920×1080 死坐标排的
	#      —— 模式按钮只有 62px 高，字一放大就顶破方框（用户实测 130% 超出）。
	#      与 `apply_scene_default` 是同一个理由：非战斗场景 = 固定版面。
	#   ⚠️ 它不是「清掉玩家的设置」：值还在 settings.cfg 里，进战场照样按档位放大。
	FONT.reset_scale()
	# ★ 分辨率：读盘并应用（桌面端才有；无头/移动端内部直接返回）。
	#   ⚠️ 必须在量 `_content` 之前 —— 窗口尺寸变了，设计空间才定得下来。
	RESOLUTION.apply_from_settings(get_window())
	# ★ 底图**先加**：它挂在根上、铺满整个窗口（含非 16:9 多出来的边）。
	#   ⚠️⚠️ 顺序不能反！Godot 里**后加的子节点画在上面** ——
	#      把 `_content` 建在 `_build_bg()` 之前的话，底图会盖住全部内容，
	#      表现是「4:3 下主菜单整屏只剩星云」（2026-10-07 出图实测踩到，
	#      而 verify_menu 那 38 条断言**全绿** —— 它不看像素）。
	_build_bg()
	# ★ 2026-10-10：主界面 BGM（见 `_build_audio` 的说明）。
	#   ⚠️ 放在建内容层之前：它只往根上挂两个 AudioStreamPlayer、与版面无关，
	#      但越早起播越不容易听出「进了菜单半秒没声」。
	_build_audio()
	# ★ 内容居中层（非 16:9 分辨率档：1920×1200 之类）。
	#   为什么是**另一层**而不是直接挪 root：底图要铺满整个窗口（含多出来的边），
	#   而品牌 / 模式 / 卡片全部按 1920×1080 死坐标排 ⇒ 内容整体平移即可。
	_content = Control.new()
	_content.name = "Content"
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_content)
	_top = _build_top_table()
	_rebuild_rows()
	for m in _all_rows():
		_pick[String(m["id"])] = 0
	# ★ 2026-10-12：默认选中**「任务关卡」**（自走棋的主玩法）—— 主入口必须仍是自走棋。
	# ★ 2026-10-28：疆域行已删 ⇒ 第一行就是「自走棋」父项，默认仍落在任务关卡。
	_mode_idx = maxi(0, _index_of_id("campaign"))
	_build_brand()
	_build_sys()
	_build_version_tag()
	_build_modes()
	_build_strips()
	_build_credits_panel()
	_build_ack_panel()
	# ★ 2026-10-10 设置窗**最后建** —— Godot 里后加的子节点画在上面，
	#   建早了会被模式按钮 / 难度卡片盖住（底图那处踩过同一个坑）。
	#   ⚠️ 它挂在 `_content` 上 ⇒ 坐标即基准区坐标，跟着内容一起居中。
	_build_settings()
	_refresh()
	_layout_content()
	resized.connect(_layout_content)
	# ★ 2026-10-30：走到这里说明「挂了热更包还能起得来主菜单」⇒ 清掉失败计数。
	#   ⚠️ 必须放在界面全部建完之后：前面任何一步崩掉都算「这次启动失败」，
	#      计数留着才有意义（见 `EveUpdater` 的坏包三次自动回退）。
	EveUpdater.mark_boot_ok()
	# ★ 2026-11-07：更新检查 —— 等 1.5 秒再问，不打断开场动画（用户拍板）。
	_start_update_check()
	# ★ 2026-11-07：诊断上报（心跳 / 崩溃取证 / 补发积压）。
	#   放最后：界面全铺完了，才叫「这次启动是好的」⇒ 这一步写 stage=1。
	_boot_reporter()


## ══════════════════════════════════════════════════════════════════
##  ★★ 热更的**根本约束**：autoload 节点永远是老脚本
## ══════════════════════════════════════════════════════════════════
##  `EveUpdater._init()` 里才调 `_try_mount()` 挂 pck，而 autoload 是按
##  `project.godot` 的顺序逐个实例化的 ⇒ **在挂载之前就建好的节点，脚本永远是
##  基础包里的那一版**。`EveBoot`（排第一）和 `EveUpdater`（排第三）都在此列。
##
##  ⇒ 老客户端挂上新 pck 之后：
##      · 主菜单、战斗场景等**被 pck 覆盖**的脚本 = 新代码 ✅
##      · autoload 实例 = **老代码** ❌
##  ⇒ 新代码里访问 autoload 的**新增**成员 = 运行时错误
##     （`Invalid get index 'pending_update'`），`_ready()` 当场中断，界面只建一半。
##
##  这不是推演，是 b39 事故的**另一半原因**（另一半是 `EveReport` 裸引用的
##  Parse Error）。详见 `docs/事故-b39黑屏-2026-11-07.md`。
##
##  ⛔ 纪律：本文件里凡是访问 `EveUpdater` / `EveBoot` 的**新增**成员，
##     一律先过 `_up_has()`。
##
##  ⚠️ 2026-11-07 二版之后**本文件已无调用点**（更新链路搬到了
##     `eve_update_ui.gd`，那里一个 autoload 成员都不碰）。保留它是为了
##     给下一个人一把随时可用的尺子 —— 真要访问新成员，别裸写。
func _up_has(member: String) -> bool:
	if EveUpdater == null:
		return false
	if EveUpdater.has_method(member) or EveUpdater.has_signal(member):
		return true
	# GDScript 没有 `has_property()`，只能扫属性表（只在启动时跑几次，不必优化）。
	for p in EveUpdater.get_property_list():
		if String(p.get("name", "")) == member:
			return true
	return false


## ★ 2026-11-07：把诊断上报宿主挂到主菜单上。
##
## [WHY] 为什么是主菜单、不是 autoload —— 这是本次事故的核心教训：
##   autoload 注册表在引擎启动时定死，`load_resource_pack()` **改不了它**
##   （它只挂文件系统，不重读 project.binary、不重新注册 autoload）。
##   ⇒ 任何「只存在于 autoload 里的新功能」对老客户端永远无效。
##   主菜单脚本会被 pck 覆盖，所以把宿主放这里，热更才能激活它。
##
## [PITFALL] 第一版写的是 `EveReport.open_feedback()`（裸引用 autoload 名）。
##   老客户端没有这个 autoload ⇒ 编译期 `Parse Error: Identifier "EveReport"
##   not declared` ⇒ 整个脚本加载失败 ⇒ **黑屏**。⛔ 别再写回去。
func _boot_reporter() -> void:
	# 网页版跨域会被浏览器拦，没必要白跑一趟（`eve_report` 内部也会挡，双保险）。
	if OS.has_feature("web"):
		return
	var rep := _ensure_reporter()
	if rep == null:
		return
	if rep.has_method("start"):
		rep.start()          # 异步：内部自己 await，⛔ 不要在这里 await 卡住启动
	if rep.has_method("mark_ui_ready"):
		rep.mark_ui_ready()


func _ensure_reporter() -> Node:
	if _reporter != null and is_instance_valid(_reporter):
		return _reporter
	# 万一哪天 `/root/EveReport` 又存在（比如未来重新注册成 autoload），复用它，
	# 别建第二份 —— `eve_report.gd` 里还有 `static _started` 做最后一道去重。
	var existing := get_node_or_null("/root/EveReport")
	if existing != null:
		_reporter = existing
		return _reporter
	_reporter = REPORT_SCRIPT.new()
	_reporter.name = "EveReportRuntime"
	add_child(_reporter)
	return _reporter


## 把内容层摆到「基准区居中」的位置。
##
## ⚠️ 判据用**根 Control 自己的 `size`**（= 设计空间），⛔ 不用 `get_window().size`：
##    无头模式下窗口尺寸是假的 (64,64)，而 Control 的 size 是引擎已经拉伸好的真值。
func _layout_content() -> void:
	if _content == null:
		return
	var base := LAYOUT.BASE
	_content.position = LAYOUT.origin_of(size)
	_content.size = base


## 主界面 BGM（**只为「一条 BGM + 总线音量」存在**，不做任何打击反馈）。
##
## ⚠️ 音量读**存档**而不是 `_audio.volumes()`：后者是刚 new 出来的实例的
##    出厂默认值，写进总线会把玩家在战场/设置窗里调好的音乐音量重置回默认
##    （总线音量是全局的）。牌桌踩过同一个坑，见 `ddz_table._build_audio()`。
func _build_audio() -> void:
	_audio = AUDIO_SCRIPT.new()
	_audio.name = "MenuAudio"
	add_child(_audio)
	var s: Dictionary = STORE.load_all()
	_audio.set_volume(&"master", float(s.get("master", 1.0)))
	_audio.set_volume(&"sfx", float(s.get("sfx", 0.60)))
	_audio.set_volume(&"amb", float(s.get("amb", 0.39)))
	_audio.set_volume(&"music", float(s.get("music", 0.32)))
	_audio.set_muted(bool(s.get("muted", false)))
	# ★ 主界面 BGM = City of Night（逻辑名 "menu"，`menu_01.ogg`，68.25s 无缝循环）。
	_audio.play_music("menu")


## ★ 2026-10-10 主界面「设置」窗（与战场 / 牌桌**共用同一个类**，换 `PROFILE_MENU` 档案）。
##
## ⚠️ `profile` 必须在 `add_child` **之前**设好 —— `_ready` 里就按它决定建哪些分区。
## ⚠️ `layout_key` 用**独立的一个**：⛔ 别与战场 / 牌桌共用存档位（三方窗尺寸不同，
##    共用一个键会让窗一进来就落在别人的坐标上）。
## ⚠️ 它挂 `_content` 上（跟着内容居中），且是 `_content` 的**最后一个**子节点
##    （在 `_build_credits_panel()` 之后建）—— Godot 里后加的画在上面。
func _build_settings() -> void:
	_settings = SETTINGS_SCRIPT.new()
	_settings.name = "MenuSettings"
	_settings.profile = SETTINGS_SCRIPT.PROFILE_MENU
	_settings.layout_key = "menu_settings"
	_content.add_child(_settings)
	_settings.visible = false
	# 音量 / 静音直接回写到菜单自己的音频宿主（它已在 `_build_audio()` 里建好）。
	_settings.volume_changed.connect(func(kind: StringName, v: float):
		if _audio != null:
			_audio.set_volume(kind, v))
	_settings.mute_toggled.connect(func(on: bool):
		if _audio != null:
			_audio.set_muted(on))
	# 分辨率变了 ⇒ 窗口尺寸变 ⇒ 内容的居中偏移变 ⇒ 把窗与内容一起重摆。
	_settings.resolution_changed.connect(func(_i: int):
		_place_settings()
		_layout_content())
	# ★ 2026-10-10：标题栏右上角的 ✕ ⇒ 关掉本窗（与 `_toggle_settings()` 的隐藏口径一致）。
	_settings.closed.connect(func() -> void: _settings.visible = false)
	_place_settings()


## 把设置窗摆在设计空间**居中偏上**。
##
## ⚠️ 它挂在 `_content` 上 ⇒ 坐标即「基准区」坐标，⛔ 不用再补居中偏移
##    （`_content` 自己已经被 `_layout_content()` 挪到居中位置了）。
## ⚠️ 高度**不由这里定**：`EveSettingsWindow._fit_height()` 会按内容反推并接管 ——
##    但**横向栏目态**例外（`_fit_height` 早退，矩形说的就是最终值）。
## ★ 2026-10-13 三方统一：手机档（栏目态）用与战场/牌桌同一形态的**半屏宽栏目窗**
##   （宽 = 基准宽 ×0.5 夹 [420,1000]、定高 560）；桌面档保持原 320 竖条。
func _place_settings() -> void:
	if _settings == null:
		return
	var base := LAYOUT.BASE
	if bool(_settings.get("_tabbed")):
		var bw := clampf(base.x * 0.5, 420.0, 1000.0)
		_settings.set_window_rect((base.x - bw) * 0.5, 70.0, bw, 560.0)
	else:
		_settings.set_window_rect((base.x - SETTINGS_W) * 0.5, 70.0, SETTINGS_W, 480.0)


## 右上角「设置」：开 / 关同一扇窗（再点一次收起 —— 与牌桌同一个交互）。
##
## ⚠️ 打开时回写**全部真实状态**：窗里显示的必须就是实际值，否则玩家看到的
##    开关与实际不符，点一下反而改成了他不想要的那个。
func _toggle_settings() -> void:
	if _settings == null:
		return
	if _settings.visible:
		_settings.visible = false
		return
	_place_settings()
	var vols: Dictionary = _audio.volumes() if _audio != null else {}
	_settings.set_state({
		"resolution_index": RESOLUTION.current_index(),
		"ui_scale": float(STORE.load_all().get("ui_scale", 0.0)),
		"muted": bool(vols.get("muted", false)),
		"volumes": vols,
	})
	_settings.visible = true
	_settings.move_to_front()


## 「任务关卡」的副标题 —— **唯一构造点**：取词 + 格式化只在这里做**一次**。
##
## ⛔⛔ 别在渲染处再过 `T.t()`：那会拿拼好的「15 回合 · 共 3 个难度」去查
##    `MODE_CAMPAIGN_META`，命中后返回 CSV 的**模板** ⇒ 界面显示裸 `%d`
##    （2026-10-11 实际踩到；渲染走 `_mode_meta()`，`verify_i18n` 有断言）。
static func _campaign_meta() -> String:
	var first: Dictionary = TIERS.difficulties()[0]
	return T.t("MODE_CAMPAIGN_META", "%d 回合 · 共 %d 个难度") \
			% [int(first["rounds"]), TIERS.difficulties().size()]

## 第一层表 = EXTRA_MODES（自走棋 / 娱乐总汇）+ 末尾追加的版权声明伪模式。
##
## ⚠️ 「任务关卡」在这里**现拼**进 `autochess.children` 的第一位 ——
##    它的副标题 `_campaign_meta()` 要取词 + 代数字，const 里做不到。
## ⚠️ 版权声明**必须最后追加**（用户要求它落在左边按钮的最下方）。
func _build_top_table() -> Array:
	var campaign := {
		"id": "campaign", "name": "任务关卡", "meta": _campaign_meta(),
		"locked": false, "cards": TIERS.difficulties(),
	}
	# versus 的卡片在 EXTRA_MODES 里就地构造（见 versus_cards()）。
	# ⛔ 别在这里再建一个 versus 行 —— EXTRA_MODES 已经有一个同 id 的，
	#    两份会渲染出两行「联机对战」（2026-10-27 踩过）。
	var out: Array = []
	for m in EXTRA_MODES:
		var row: Dictionary = (m as Dictionary).duplicate(true)
		if String(row.get("id", "")) == AUTOCHESS_MODE_ID:
			# versus  already lives in EXTRA_MODES 的 children（见那里的「联机对战」项）。
			# ⛔ 别再往这里插一个同 id 的 —— 会渲染出两行「联机对战」。
			var kids: Array = [campaign] + (row.get("children", []) as Array)
			# EXTRA_MODES 是 const ⇒ versus 的卡片只能在这里注入。
			# ⚠️ versus 是 autochess 的**子项**，不在 EXTRA_MODES 顶层，
			#    所以必须遍历 children 找它，不能只看 row 自己（2026-10-27 踩过：
			#    写在顶层判断里，结果 cards 永远是空的）。
			for i in kids.size():
				var kd: Dictionary = kids[i]
				if String(kd.get("id", "")) == VERSUS_MODE_ID:
					kd["cards"] = versus_cards()
					kids[i] = kd
			row["children"] = kids
		out.append(row)
	out.append({
		"id": CREDITS_MODE_ID, "name": "版权声明", "meta": "致谢 · 开源许可",
		"locked": false, "credits": true, "cards": [],
	})
	return out


## 展平成**可见行**：每个顶层项一行 + （自走棋展开时）它的子项各一行。
##
## ★ 下游只认 `_modes`（可见行）—— 选中、卡片、键盘导航都不必知道层级。
## ⚠️ 重建时**按 id 找回原选中行**：原来选中的行消失（子项被收起）⇒ 回落到它的父行，
##    这样收起子项不会让选中态丢空、右侧也不会变空白。
func _rebuild_rows() -> void:
	var prev_id := ""
	var prev_parent := ""
	if _mode_idx >= 0 and _mode_idx < _modes.size():
		var pm: Dictionary = _modes[_mode_idx]
		prev_id = String(pm["id"])
		prev_parent = String(pm.get("child_of", ""))
	var rows: Array = []
	for m in _top:
		var row: Dictionary = (m as Dictionary)
		row["depth"] = 0
		if row.has("children"):
			row["parent"] = true
		else:
			row.erase("parent")
		rows.append(row)
		if bool(row.get("parent", false)) and _expanded:
			for c in (row["children"] as Array):
				var sub: Dictionary = (c as Dictionary)
				sub["depth"] = 1
				sub["child_of"] = String(row["id"])
				rows.append(sub)
	_modes = rows
	# 选中行没了（子项被收起）⇒ 回落到它的父项（自走棋），再不行才回第 0 行。
	_mode_idx = _index_of_id(prev_id)
	if _mode_idx < 0 and prev_parent != "":
		_mode_idx = _index_of_id(prev_parent)
	if _mode_idx < 0:
		_mode_idx = 0


## 不分展开与否的全量行（父 + 所有子）—— 只用于初始化 `_pick` 的键。
func _all_rows() -> Array:
	var out: Array = []
	for m in _top:
		var row: Dictionary = (m as Dictionary)
		out.append(row)
		for c in (row.get("children", []) as Array):
			out.append(c)
	return out


## 可见行里按 id 找下标（找不到 = -1）。
func _index_of_id(mode_id: String) -> int:
	if mode_id == "":
		return -1
	for i in _modes.size():
		if String((_modes[i] as Dictionary)["id"]) == mode_id:
			return i
	return -1


## ★ 选中行对应的**内容行**：父项（自走棋）自己没有卡片 ⇒ 回落到它的第一个子项
##   （任务关卡）。这样「收起子项后选中父项」时右侧仍然是任务关卡的内容，
##   ⛔ 不会出现一块空白面板。
func _content_row_of(idx: int) -> Dictionary:
	var m: Dictionary = _modes[idx]
	if bool(m.get("parent", false)):
		var ch: Array = m.get("children", [])
		if ch.size() > 0:
			return ch[0]
	return m


## 当前选中行对应的内容 id（= `_pick` 的键）。
func _content_id() -> String:
	return String(_content_row_of(_mode_idx)["id"])


func _cards_of(idx: int) -> Array:
	return (_content_row_of(idx)["cards"] as Array)


# ------------------------------------------------------------ 文案取词（i18n）
#
# ★★ 设计口径：**数据表里仍是中文源文** —— `EveCampaignTiers.difficulties()` 与
#    `EXTRA_MODES` 都保持 `const`（⛔ 别为了塞 `T.t()` 把它们改成函数：
#    const 初始化器里调不了函数，改成函数又会牵动 `verify_menu` 的读法）。
#    中文在这里既是**兜底**也是**活文档**；**渲染时**才过一遍 `T.t()`。
#    ⇒ 加语言不用改数据表，改数据表也不用碰 i18n。
# ⚠️ 默认 locale = zh_CN ⇒ 取词原样返回中文 ⇒ 既有行为/断言/截图逐字不变。

## ★ 下面四个都是 `static` —— 不碰任何实例状态，**自检可以静态调用**
##   （`verify_i18n` 的 ⑤ 就是静态跑的，⛔ 别改成实例方法）。

## 模式名 / 副标题（按模式 **id** 取 key：`MODE_CAMPAIGN_NAME` …）。
## ⚠️ `field` 一律 `to_upper()` —— 调用点写的是小写 `"name"`，不转就拼出
##    `MODE_CAMPAIGN_name` 这种对不上 CSV 的 key（英文**静默回落中文**，10-10 踩到）。
static func _mode_key(m: Dictionary, field: String) -> String:
	return "MODE_%s_%s" % [String(m["id"]).to_upper(), field.to_upper()]


static func _mode_txt(m: Dictionary, field: String) -> String:
	return T.t(_mode_key(m, field), String(m[field]))


## ⛔⛔ **副标题（meta）不许再过 `T.t()`** —— 它是**运行时拼好的最终串**
## （`_build_mode_table()` 里已经 `T.t(模板) % [数字]` 过一遍了）。
## 再取词就会拿「15 回合 · 共 3 个难度」去查 `MODE_CAMPAIGN_META`，
## 命中后返回 CSV 的**模板** ⇒ 界面显示裸 `%d 回合 · 共 %d 个难度`
## （2026-10-11 实际踩到；`verify_i18n` 已加断言钉死）。
## ✅ 英文版仍然正确：取词发生在 `_build_mode_table()` 里，英文模板在那儿就被选中了。
static func _mode_meta(m: Dictionary) -> String:
	return String(m["meta"])


## 卡片的 key 前缀：任务关卡用 `id`（`guard_border`…），娱乐总汇的卡用 `code`
## （`DOUDIZHU`…）—— 两边都取 ASCII 稳定标识，⛔ 别用中文当 key。
static func _card_key(card: Dictionary) -> String:
	var id := String(card.get("id", ""))
	if id == "":
		id = String(card.get("code", ""))
	return id.to_upper()


static func _card_txt(card: Dictionary, field: String) -> String:
	return T.t("CARD_%s_%s" % [_card_key(card), field.to_upper()],
			String(card.get(field, "")))


## `stats` 行的**键与值**取词表（中文源文 → key）。
## ⛔ 只用于显示；⛔ 别拿这些中文去分支（工程红线：逻辑只认 id）。
## ⚠️ 表里的中文必须与 CSV 的 `zh_CN` 列**逐字一致**（`verify_i18n` 会对拍）。
## ⚠️ 没登记进这张表的取值 ⇒ 原样返回中文（英文版会露中文，但不会崩、不会空）。
const STAT_KEYS: Dictionary = {
	"玩法": &"CARD_K_PLAY",
	"对手": &"CARD_K_OPP",
	"状态": &"CARD_K_STATUS",
	"终点": &"CARD_K_END",
	"纪录": &"CARD_K_RECORD",
	"前置": &"CARD_K_REQ",
	"回合数": &"CARD_K_ROUNDS",
	"解锁": &"CARD_K_UNLOCK",
	# ── 值 ──────────────────────────────────────────────────────
	"电脑 · 3 人": &"CARD_V_CPU3",
	"电脑舰队 · 4 派系": &"CARD_V_FLEET4",
	"电脑舰队 · 成建制": &"CARD_V_FLEET_FORMAL",
	"电脑舰队 · 无限波次": &"CARD_V_FLEET_WAVES",
	"其他玩家 · 8 人": &"CARD_V_PLAYERS8",
	"待定": &"CARD_V_TBD",
	"可进入": &"CARD_V_OPEN",
	"开发中": &"CARD_V_WIP",
	"尚未开放": &"CARD_V_CLOSED",
	"默认开放": &"CARD_V_UNLOCK_DEFAULT",
	"无 · 直到全灭": &"CARD_V_NO_END",
	"最后存活者获胜": &"CARD_V_LAST_ALIVE",
	"需要联网与服务器": &"CARD_V_NEED_NET",
	"斗地主": &"CARD_V_PLAY_DDZ",
	"四川麻将": &"CARD_V_PLAY_SICHUAN",
	"立直麻将": &"CARD_V_PLAY_RIICHI",
	"升级": &"CARD_V_PLAY_SHENGJI",
	"15 回合": &"CARD_V_ROUNDS15",
	"25 回合": &"CARD_V_ROUNDS25",
	"通关第 1 难度": &"CARD_V_UNLOCK_T1",
	"通关第 2 难度": &"CARD_V_UNLOCK_T2",
}


static func _stat_txt(s: String) -> String:
	var k := String(STAT_KEYS.get(s, ""))
	return T.t(k, s) if k != "" else s


# ------------------------------------------------------------------ 构建

func _build_bg() -> void:
	var t := TextureRect.new()
	t.name = "MenuBg"
	t.texture = MENU_BG
	t.set_anchors_preset(Control.PRESET_FULL_RECT)
	# ★ 铺满，但**保持比例**（2026-10-07 改）：底图是 1920×1080 的定稿。
	#   16:9 下 KEEP_ASPECT_COVERED == 铺满（行为不变）；非 16:9 的档
	#   （1920×1200 之类）下它按比例放大到盖满，多余的部分裁掉 ——
	#   ⛔ 绝不用 STRETCH_SCALE：那会把星点与星云整体拉变形。
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(t)


func _build_brand() -> void:
	var box := VBoxContainer.new()
	box.name = "Brand"
	box.position = BRAND_POS
	box.add_theme_constant_override("separation", 8)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := _label(T.t("MENU_BRAND", "EVE 自走棋"), 26, C_TEXT_HI)
	h.add_theme_constant_override("letter_spacing", 0)
	var s := _label("NEW EDEN AUTO CHESS", 9, Color(0.69, 0.80, 0.84, 0.80))
	box.add_child(h)
	box.add_child(s)
	_content.add_child(box)


func _build_sys() -> void:
	var box := VBoxContainer.new()
	box.name = "Sys"
	box.alignment = BoxContainer.ALIGNMENT_END
	box.add_theme_constant_override("separation", 10)
	box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	# ⚠️ 宽度要够放**四**个按钮（继续上局 / 设置 / 回看片头 / 退出游戏，
	#    各 84 + 三道 18 间隔 = 390）⇒ 留 400。原来 220 只够两个。
	#    「继续上局」无档时 `visible=false`（HBox 会把它从布局里摘掉），
	#    所以三个按钮时也不会留空。
	box.offset_left = -(SYS_MARGIN_R + 400.0)
	box.offset_right = -SYS_MARGIN_R
	box.offset_top = SYS_TOP
	box.offset_bottom = SYS_TOP + 70.0

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 18)
	# ★ 2026-10-10（审查 2#2）：「继续上局」—— 有对局存档时才可见。
	#
	#   ⚠️ **始终建出来**、只切 `visible`：① 无档时 HBox 自动把它摘出布局，
	#     不会留空；② 节点结构恒定 ⇒ 任何"数按钮"的验收不受存档影响。
	#   ⛔ 不做成"没档时也显示但点了没反应"（红线 9）。
	var cont_btn := Button.new()
	cont_btn.name = "ContinueRunBtn"
	cont_btn.text = T.t("MENU_CONTINUE", "继续上局")
	BTN_THEME.apply(cont_btn, "hud_main")
	FONT.fs(cont_btn, 12)
	cont_btn.custom_minimum_size = Vector2(84, 26)
	cont_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	cont_btn.visible = RUN_STORE.has_run()
	cont_btn.pressed.connect(_on_continue_run)
	row.add_child(cont_btn)
	_continue_btn = cont_btn
	# ★ 2026-10-10 补上「设置」（用户要求：主界面右上角要有设置，主要设置都放进去）。
	#   此前缺它的唯一理由是「菜单没有音频宿主 ⇒ 音量滑杆是死旋钮」（红线 9）；
	#   `_build_audio()` 之后菜单**已经有** `_audio` 宿主了 ⇒ 那个理由不再成立。
	#   ⚠️ 用 `PROFILE_MENU` 档案：音频 + 分辨率；⛔ 无字号（菜单恒定 100%）、
	#      无「返回主界面」（我们就在主界面）。
	var set_btn := Button.new()
	set_btn.name = "SettingsBtn"
	set_btn.text = T.t("MENU_SETTINGS", "设置")
	BTN_THEME.apply(set_btn, "plain")
	FONT.fs(set_btn, 12)
	set_btn.custom_minimum_size = Vector2(84, 26)
	set_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	set_btn.pressed.connect(_toggle_settings)
	row.add_child(set_btn)
	_settings_btn = set_btn
	#
	# 「回看片头」：开场剧情**默认只在第一次玩时出现**（存 progress.cfg），
	# 所以必须留一个显式的回看入口 —— **跳过不可以是不可逆的**。
	var replay_btn := Button.new()
	replay_btn.name = "ReplayIntroBtn"
	replay_btn.text = T.t("MENU_REPLAY_INTRO", "回看片头")
	BTN_THEME.apply(replay_btn, "plain")
	FONT.fs(replay_btn, 12)
	replay_btn.custom_minimum_size = Vector2(84, 26)
	replay_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	replay_btn.pressed.connect(_on_replay_intro)
	row.add_child(replay_btn)

	var quit_btn := Button.new()
	quit_btn.name = "QuitBtn"
	quit_btn.text = T.t("MENU_QUIT", "退出游戏")
	BTN_THEME.apply(quit_btn, "plain")
	FONT.fs(quit_btn, 12)
	quit_btn.custom_minimum_size = Vector2(84, 26)
	quit_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	quit_btn.pressed.connect(_on_quit)
	row.add_child(quit_btn)
	box.add_child(row)

	# ⚠️ 版本号**不再放这里**（2026-10-10 用户要求）：移到主界面**右下角**，
	#    见 `_build_version_tag()`。以后导出只改 `application/config/version`，
	#    右下角自动跟着变（永久管线，见 MEMORY「导出」章）。
	_content.add_child(box)


## 点右下角版本号 → 打开「发送诊断信息」（诊断上报入口，见 `EveReport`）。
## [NOTE] 安卓的触摸会额外模拟出鼠标事件，但这里两种都收：真机上万一没模拟，
##        至少触摸还能点得动。
func _on_version_tag_input(ev: InputEvent) -> void:
	var hit := false
	if ev is InputEventMouseButton:
		hit = ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT
	elif ev is InputEventScreenTouch:
		hit = ev.pressed
	if hit:
		# ⛔ 这里以前是 `EveReport.open_feedback()` —— 裸引用一个 autoload 名。
		#    老客户端的 autoload 列表里没有它 ⇒ 编译期 Parse Error ⇒ 整屏黑。
		#    改成运行时拿实例，见 `_ensure_reporter()`。
		var rep := _ensure_reporter()
		if rep != null and rep.has_method("open_feedback"):
			rep.open_feedback()


## ★ 2026-10-10 主界面**右下角**版本号（显示 `V<application/config/version>`）。
##
## ⚠️ 版本号**只读 `application/config/version`**（`project.godot` 的 `config/version`）
##    —— ⛔ 这里不许另写死一个数字。导出流程只改那一处，右下角就自动更新
##    （**永久管线**：导出改版本 ⇒ 右下角版本号默认跟着变）。
## ⚠️ 锚在 `_content` 上（=`LAYOUT.BASE` 1920×1080）⇒ 非 16:9 下跟着内容一起居中，
##    始终贴在基准区右下角。
## ⚠️ 用 `set_anchors_and_offsets_preset`（⛔ 不是 `set_anchors_preset`）：后者会
##    **保持 0×0 的当前矩形**、量不出正确位置（见 MEMORY §10 的同类坑）。
func _build_version_tag() -> void:
	# ★ 2026-10-30：改读 `EveUpdater.build_info()` —— 它优先读 `res://build_info.json`
	#   （导出脚本生成），热更包挂载后这个文件会被 pck 里那份覆盖 ⇒
	#   **右下角显示的版本号自动跟着热更走**，不会出现"更新完了却还写着旧版本号"。
	#   ⚠️ 取不到 build_info.json 时它内部会回退到 `application/config/version`，
	#      所以「只读配置、不许另写死数字」这条约定仍然成立。
	var ver := String(EveUpdater.build_info().get("version", "0.0.0"))
	# ⚠️ **不加暗底**（用户 2026-10-10 明确要求）⇒ 必须用**深色字**：底图右下角是
	#    亮星云（实测 RGB≈160,180,192），浅色字根本读不出来；深色字对比度 ≈ 6:1。
	var tag := _label(T.t("MENU_VERSION", "当前版本 V%s") % ver, 11, Color(0.12, 0.16, 0.19, 0.92))
	tag.name = "VersionTag"
	# ★ 2026-11-07 诊断上报入口：**点右下角版本号** = 打开「发送诊断信息」。
	# [WHY] 不新增按钮：系统行已经四个按钮、宽度卡死（见 _build_sys 的注释）；
	#       而玩家真出问题时，第一个会去看的就是版本号 —— 入口放这儿不占布局。
	tag.mouse_filter = Control.MOUSE_FILTER_STOP
	tag.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if not tag.gui_input.is_connected(_on_version_tag_input):
		tag.gui_input.connect(_on_version_tag_input)
	tag.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	tag.offset_left = -170.0
	tag.offset_right = -56.0
	tag.offset_top = -50.0
	tag.offset_bottom = -26.0
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_content.add_child(tag)

	# ── 热更状态行（版本号正上方）──
	# 拉得比版本号宽：这里可能出现「发现新版本 V0.14.10 · 准备下载」这种长句。
	var utag := _label("", 11, Color(0.12, 0.16, 0.19, 0.86))
	utag.name = "UpdateTag"
	utag.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	utag.offset_left = -460.0
	utag.offset_right = -56.0
	utag.offset_top = -98.0
	utag.offset_bottom = -74.0
	utag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	utag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	utag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	utag.visible = false
	_content.add_child(utag)
	_update_tag = utag
	# ⚠️ 先判重再 connect：`_build_version_tag` 可能在重建界面时被再调一次，
	#    重复 connect 会让回调跑两遍（Godot 4 会直接报 "already connected" 错）。
	if not EveUpdater.changed.is_connected(_refresh_update_tag):
		EveUpdater.changed.connect(_refresh_update_tag)
	_refresh_update_tag()

	# ── 「鸣谢名单」按钮（版本号正上方，紧挨着）──
	# ★ 2026-11-01：点开右侧独立的鸣谢名单面板（与版权声明面板同位置 / 同尺寸）。
	var ack_btn := Button.new()
	ack_btn.name = "AckBtn"
	ack_btn.text = T.t("MENU_ACK", "鸣谢名单")
	BTN_THEME.apply(ack_btn, "plain")
	FONT.fs(ack_btn, 12)
	ack_btn.custom_minimum_size = Vector2(84, 26)
	ack_btn.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ack_btn.offset_left = -170.0
	ack_btn.offset_right = -56.0
	ack_btn.offset_top = -74.0
	ack_btn.offset_bottom = -50.0
	ack_btn.pressed.connect(_on_ack_pressed)
	_content.add_child(ack_btn)
	_ack_btn = ack_btn


## 把更新状态同步到右下角那行小字。空文本 = 隐藏（绝大多数时候应该隐藏）。
##
## 把热更状态同步到版本号下面那行小字。空文本 = 隐藏。
##
## ⚠️ 2026-11-07 二改：这里**不再反映开屏页的状态**（用户原话：
##    「而不是现在在右下角一点小字」）。开屏页已经把版本对比、进度、
##    重启提示全部承担了，小字再报一遍属于重复且碍眼。
##
## 它现在只剩一个职责：**兜底显示老 `EveUpdater` 的静默下载进度**
## —— 那段代码在 autoload 里、热更改不掉，它的 `status_text` 是唯一出口。
## 正常情况下这一行是空的（`visible = false`）。
func _refresh_update_tag() -> void:
	if _update_tag == null:
		return
	var s := String(EveUpdater.status_text)
	_update_tag.text = s
	_update_tag.visible = s != ""


# ══════════════════════════════════════════════════════════════════
#  ★ 2026-11-07：发现新版本 → 弹窗询问 → 进度条 → 重启生效
# ══════════════════════════════════════════════════════════════════
#
#  设计口径（用户 2026-11-07 拍板，三条，二版仍然适用）：
#    ① 「稍后」= 本次不问，**下次启动再问**（不做「跳过此版本」的持久化记忆）
#    ② 下载完 → 面板换成「已就绪」，给「立即重启」
#    ③ 时机 = 主菜单铺好后约 1.5 秒（不打断开场动画）
#
#  ⚠️ 为什么延迟不能用 `await create_timer()`：玩家完全可能在这 1.5 秒里
#     就点了「开始游戏」⇒ 本节点被 free ⇒ 协程恢复时打
#     "Resumed function after await, but the object was freed" 的错。
#     用本节点的子 Timer，跟着一起销毁，回调根本不会跑。
#
#  ⚠️ 为什么整套逻辑不放在 `EveUpdater` 里：见字段区 `UPDATE_UI` 上面的长注释。
#     一句话 —— autoload 在 pck 挂载前就实例化，老客户端上永远是老脚本。

## 1.5 秒后启动检查。用子 Timer，理由见上面第 3 条注释。
## 开屏检查。
##
## ⚠️ 这里**只等 0.05 秒**（原来是 1.5 秒），原因见用户 2026-11-07 的原话：
##      「我觉得应该在最开始弹……做成完全开屏显示都行」
##    1.5 秒那种「主菜单先铺好、动画落下再浮个卡片」的节奏，读起来像一个
##    可以无视的提示；用户要的是**启动即挡**，所以这里几乎不延迟。
##
## ⚠️ 但也不能是 0：`_ready()` 里立刻 `add_child(HTTPRequest)` + `request()`
##    会拿到 `ERR_UNCONFIGURED`（节点还没真正进树）。一帧左右就够。
##    用子 Timer 而不是 `await create_timer()`：玩家可能立刻点「开始游戏」，
##    本节点被 free，`await` 恢复时会报 "object was freed"。
func _start_update_check() -> void:
	var t := Timer.new()
	t.name = "UpdateCheckDelay"
	t.one_shot = true
	t.wait_time = 0.05
	t.timeout.connect(_on_update_check_due)
	add_child(t)
	t.start()


func _on_update_check_due() -> void:
	if not is_inside_tree():
		return
	_upd = UPDATE_UI.new()
	_upd.name = "UpdateCheck"
	add_child(_upd)
	_upd.asked.connect(_on_upd_asked)
	_upd.progressed.connect(_on_upd_progressed)
	_upd.ready_to_restart.connect(_on_upd_ready)
	_upd.failed.connect(_on_upd_failed)
	_upd.start()


## 面板建一次、四态复用（⛔ 不要每次 new 一个，会叠出多张遮罩）。
##
## ⚠️ 挂在**根节点**上，⛔ 不挂 `_content`：`_content` 是 1920×1080 的居中基准区，
##    非 16:9 时四周有黑边，弹窗会被裁进那个内容框里，看着像贴了张纸。
##
## ⚠️ 返回类型与字段都不标注（`Control` / `Node`）—— 面板和检查器都有自己的
##    方法（`show_ask` / `begin_download` …），标成基类反而调不通。
func _ensure_update_panel():
	if _upd_panel == null:
		_upd_panel = UPDATE_PANEL.new()
		_upd_panel.name = "UpdatePanel"
		add_child(_upd_panel)
		_upd_panel.accepted.connect(_on_upd_accepted)
		_upd_panel.dismissed.connect(_on_upd_dismissed)
		_upd_panel.restart_now.connect(_on_upd_restart)
		_upd_panel.retry_requested.connect(_on_upd_retry)
	return _upd_panel


# ── 检查器回调 ─────────────────────────────────────────────────────

func _on_upd_asked(cur: String, new_ver: String, size_mb: float) -> void:
	if not is_inside_tree():
		return
	_ensure_update_panel().show_ask(cur, new_ver, size_mb)


func _on_upd_accepted() -> void:
	if _upd != null:
		_upd.begin_download()


func _on_upd_progressed(pct: float, done: int, total: int, allow_dismiss: bool) -> void:
	if not is_inside_tree() or _upd == null:
		return
	var p = _ensure_update_panel()
	# 首次进度可能是「观察老 EveUpdater 下载」来的（面板还没开过）⇒ 补一次 show_progress
	if not p.is_open():
		p.show_progress(String(_upd.cur_ver), String(_upd.new_ver), allow_dismiss)
	p.set_progress(pct, done, total)


func _on_upd_ready(ver: String) -> void:
	if not is_inside_tree():
		return
	_ensure_update_panel().show_ready(ver)


func _on_upd_failed(msg: String, cur: String, new_ver: String) -> void:
	if not is_inside_tree():
		return
	_ensure_update_panel().show_error(msg, cur, new_ver)


## 「稍后」= 本次不问，下次启动再问（用户拍板）。⛔ 不写任何持久化标记。
func _on_upd_dismissed() -> void:
	pass


func _on_upd_restart() -> void:
	if _upd != null:
		_upd.restart_app()


func _on_upd_retry() -> void:
	if _upd != null:
		_upd.begin_download()


## 「鸣谢名单」按钮：开 / 关同一扇面板。打开时把版权声明面板与难度卡片区让位收掉，避免盖住面板。
func _on_ack_pressed() -> void:
	if _ack_panel == null:
		return
	var open := not _ack_panel.visible
	_ack_panel.visible = open
	if open:
		if _credits_panel != null:
			_credits_panel.visible = false
		if _strip_row != null:
			_strip_row.visible = false
		if _codex_btn != null:
			_codex_btn.visible = false
	else:
		# 关闭时交还 _refresh 复原常态布局（非版权模式才显示 strips / 图鉴按钮）
		_refresh()


## 当前选中的是不是「版权声明」这一项。
func _is_credits() -> bool:
	return _content_id() == CREDITS_MODE_ID


## 版权声明大方框（右侧）。文字口径见下方各行 ——
##   · 游戏本体（架构 / 脚本 + 开源地址）→ 星视寰宇 / xshynews · GPL v3
##   · EVE 题材与美术素材             → Fenris Creations（原 CCP Games）
##   · 背景音乐                       → 乌鸦Producer · 本项目版本经 AI 重编曲
##
## ⚠️ 只建一次、之后靠 `visible` 切换（见 `_credits_panel` 的说明）。
## ⚠️ autowrap 的 Label **必须给死宽**（`CREDITS_W - 两侧留白`）——
##    宽度为 0 时它会按"一个字一行"折行，量出的最小高度大得离谱
##    （`_make_strip` 的 desc 踩过同一个坑）。
func _build_credits_panel() -> void:
	_credits_panel = PanelContainer.new()
	_credits_panel.name = "Credits"
	_credits_panel.position = STRIP_POS
	_credits_panel.size = Vector2(CREDITS_W, CREDITS_H)
	_credits_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_credits_panel.add_theme_stylebox_override("panel", _strip_style(false, true))
	_credits_panel.visible = false

	var mn := MarginContainer.new()
	mn.add_theme_constant_override("margin_left", 34)
	mn.add_theme_constant_override("margin_right", 34)
	mn.add_theme_constant_override("margin_top", 28)
	mn.add_theme_constant_override("margin_bottom", 26)
	_credits_panel.add_child(mn)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mn.add_child(col)

	# 正文可用宽度 = 面板宽 - 两侧留白（再减 2 给边框，与 desc 同口径）
	var inner := CREDITS_W - 68.0 - 2.0
	col.add_child(_label(T.t("MODE_CREDITS_NAME", "版权声明"), 20, C_TEXT_HI))
	col.add_child(_label("COPYRIGHT & CREDITS", 9, Color(0.55, 0.78, 0.82, 0.72)))
	col.add_child(_vspace(16))

	# 每条 = 小标题 + 若干正文行；正文自动折行。
	# ⚠️ `k` = i18n key 的**段名**（`CREDITS_<k>` / `CREDITS_<k>_<行号>`），
	#    中文仍是源文 ⇒ zh_CN 下逐字不变、英文走 CSV。
	var sections := [
		{
			"k": "GAME",
			"h": "游戏本体 · GAME",
			"b": [
				"EVE 自走棋（EVE-AutoChess）的游戏架构与全部脚本由 星视寰宇 创作，以 GNU GPL v3 开源。",
				"源码地址：https://github.com/xshynews/EVE-AutoChess",
				"Copyright © 2026 xshynews · 衍生作品须同样以 GPL v3 开源。",
			],
		},
		{
			"k": "ART",
			"h": "EVE 题材与美术素材 · EVE IP & ART",
			"b": [
				"EVE 相关的 IP 与素材（舰船模型、图标、贴图等）著作权归 Fenris Creations 所有"
						+ "（该公司于 2026 年 5 月由 CCP Games 更名而来，CCP 原名 Crowd Control Productions）。",
				"本项目不持有这些素材的任何权利，相关内容不在 GPL v3 覆盖范围内，"
						+ "仅用于学习、开发与体验目的。",
			],
		},
		{
			"k": "MUSIC",
			"h": "背景音乐 · MUSIC",
			"b": [
				"五首 BGM 原曲作者：乌鸦Producer"
						+ "（City of Night / Pixel Wars / DJ BO$$ / Lantern / Start the Battle）。",
				"本项目使用的版本为适配游戏时长与无缝循环经重编曲处理；"
						+ "原曲出自原作者的「免费可商用」原创音乐集合包，版权仍归原作者所有。",
			],
		},
		{
			"k": "LICENSE",
			"h": "开源许可 · LICENSE",
			"b": [
				"代码：GNU GPL v3（Copyright © 2026 xshynews）。",
				"美术 / 音频素材：归 Fenris Creations 及原作者所有，非本项目许可证覆盖范围。",
			],
		},
	]
	for sec in sections:
		var sec_k := String(sec["k"])
		col.add_child(_label(T.t("CREDITS_H_%s" % sec_k, String(sec["h"])), 13, C_ACCENT))
		col.add_child(_vspace(4))
		var bl: Array = sec["b"]
		for i in bl.size():
			var line := T.t("CREDITS_%s_%d" % [sec_k, i + 1], String(bl[i]))
			var l := _label(line, 12, Color(0.81, 0.89, 0.91, 0.90))
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size = Vector2(inner, 0)
			col.add_child(l)
		col.add_child(_vspace(16))

	_content.add_child(_credits_panel)


## 鸣谢名单面板（右侧，与版权声明面板同位置 / 同尺寸）。
## 名单较长 ⇒ 正文包一层 `ScrollContainer` 滚动，避免撑爆面板高度。
##
## ⚠️ 只建一次、之后靠 `visible` 切换（见 `_ack_panel` 说明）。
func _build_ack_panel() -> void:
	_ack_panel = PanelContainer.new()
	_ack_panel.name = "Ack"
	# ★ 2026-10-31 重做（用户：「太没意思了，丑得要死」）：
	#   ① 带图标 + 大标题的抬头（hero）
	#   ② 「—— 标题 ——」居中分段标题
	#   ③ 名单从单列长列表改成 4 列居中网格（大幅缩短、更好扫读）
	#   ④ 「2024」用金色强调的感谢语
	#   ⑤ 底部两小节并排
	#   ⚠️ 只换排版：配色仍取本文件 C_* 口径、字体仍走 FONT.fs、直角铁律不变。
	_ack_panel.position = Vector2(STRIP_POS.x, 240.0)
	_ack_panel.size = Vector2(CREDITS_W, 600.0)
	_ack_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_ack_panel.add_theme_stylebox_override("panel", _strip_style(false, true))
	_ack_panel.visible = false

	var mn := MarginContainer.new()
	mn.add_theme_constant_override("margin_left", 40)
	mn.add_theme_constant_override("margin_right", 40)
	mn.add_theme_constant_override("margin_top", 30)
	mn.add_theme_constant_override("margin_bottom", 28)
	_ack_panel.add_child(mn)

	# 内容若超面板高度 ⇒ 滚动兜底（禁横向滚动；正常应一屏内，不出滚动条）。
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.mouse_filter = Control.MOUSE_FILTER_STOP
	mn.add_child(sc)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# [PITFALL] ScrollContainer 不会自动把子节点撑满宽度：子节点最小宽 < 视口时
	#   会缩在左边（旧版靠名单 Label 的 custom_minimum_size 硬撑才满）。
	#   改成网格后最小宽只剩 ~480，必须显式 EXPAND_FILL 才会铺满面板。
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(col)

	# ── ① 抬头：图标（勋章式细框）+ 大标题 + 拉宽字距副标，整组居中 ──
	var hero := HBoxContainer.new()
	hero.alignment = BoxContainer.ALIGNMENT_CENTER
	hero.add_theme_constant_override("separation", 16)
	hero.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var frame := PanelContainer.new()
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color(0.075, 0.105, 0.125, 0.92)
	fsb.border_color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.55)
	fsb.set_border_width_all(1)
	fsb.set_corner_radius_all(0)          # [NOTE] 直角铁律
	fsb.set_content_margin_all(4)
	frame.add_theme_stylebox_override("panel", fsb)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var icon_tex := load("res://assets/icon/ic_launcher_xxxhdpi.png") as Texture2D
	if icon_tex != null:
		var tex := TextureRect.new()
		tex.texture = icon_tex
		tex.custom_minimum_size = Vector2(46, 46)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(tex)
		hero.add_child(frame)

	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", 3)
	tv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tv.add_child(_label("鸣谢", 26, C_TEXT_HI))
	# [NOTE] Label 无 letter-spacing 主题项 ⇒ 用小字号 + 手工空格拉字距。
	tv.add_child(_label("A C K N O W L E D G E M E N T S", 9, Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.82)))
	hero.add_child(tv)
	col.add_child(hero)

	col.add_child(_vspace(12))
	col.add_child(_ack_rule(C_ACCENT, 0.45))
	col.add_child(_vspace(18))

	# ── ② 分段标题 + ③ 4 列居中网格 ──────────────────────────────
	col.add_child(_ack_section("爱发电贡献人员", true))
	col.add_child(_vspace(10))

	var names := PackedStringArray([
		"Archer家今天的番", "Nafix", "次元旅行家", "我要潜行", "龙飞云",
		"星空", "龙飞云", "爱发电用户_KEh6", "覅是", "呆头鸭",
		"爱发电用户_01677", "国服手游玫瑰瀚海", "我要潜行", "铭丞志宇", "伪画师",
		"流光叶卡", "爱发电用户_afa09", "死海咸鸽", "爱发电用户_fexm", "爱发电用户_83b2e",
		"hppct", "零星之心", "爱发电用户_BaMv", "我是扁苹", "爱发电用户_e33cf",
		"They call me...Specter", "爱发电用户_vVb6", "thcy_awa", "梧桐无栖", "爱发电用户_19a36",
		"哈伦QAQ·哈哈哈?_?", "叶灵络", "81192", "爱发电用户_KG5B", "梧桐无栖",
		"thcy_awa", "叶灵络", "They call me...Specter", "梧桐无栖", "81192",
		"EVE Online", "铭丞志宇", "青轩の猫",
	])
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 9)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in names.size():
		var nl := _label(names[i], 12, C_TEXT)
		nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		grid.add_child(nl)
	# 补齐空位让 4 列对称（43 ⇒ 44），避免末行单挂一个显得歪。
	while grid.get_child_count() % grid.columns != 0:
		var pad := _label("", 12, C_TEXT)
		pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
		grid.add_child(pad)
	col.add_child(grid)

	# ── ④ 括号注 + 金色强调的 2024 感谢语 ────────────────────────
	col.add_child(_vspace(14))
	col.add_child(_ack_rule(C_SEP, 1.0))
	col.add_child(_vspace(12))
	var note := _label("（感谢上述人员在2024年为我们提供资金支持）", 10, C_DIM)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(note)
	col.add_child(_vspace(10))
	# 原文逐字保留，只把「2024」拆出来染金 ⇒ 不改文案、只加强调。
	var frow := HBoxContainer.new()
	frow.add_theme_constant_override("separation", 0)
	frow.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	frow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frow.add_child(_label("感谢", 13, C_TEXT_HI))
	frow.add_child(_label("2024", 13, C_GOLD))
	frow.add_child(_label("年为制作EVE自走棋付出过努力与智慧的所有人", 13, C_TEXT_HI))
	col.add_child(frow)

	# ── ⑤ 底部两小节并排（动画制作支持 / 测试支持）─────────────────
	col.add_child(_vspace(18))
	# [WHY] 原版用 EXPAND_FILL 把两节拉满整行 ⇒ 名字靠左、列宽是弹性的、
	#   两节间距随面板/分辨率一直变大（用户：「没锁死、会一直增长」）。
	#   改为「固定列宽 + 整体居中 + 名字居中」，与上面 4 列网格一样锁死。
	var pair := HBoxContainer.new()
	pair.alignment = BoxContainer.ALIGNMENT_CENTER
	pair.add_theme_constant_override("separation", 56)
	pair.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pair_cols := [
		["感谢以下人员为游戏动画制作提供支持", "吴良    雪奈川"],
		["感谢以下人员为游戏测试提供支持", "Aliya    Tαoうぎ    小香"],
	]
	for pc in pair_cols:
		var sec := VBoxContainer.new()
		sec.add_theme_constant_override("separation", 0)
		sec.custom_minimum_size = Vector2(340, 0)   # 定宽 = 「锁死」，不随宽度增长
		sec.add_child(_ack_section(String(pc[0]), false))
		sec.add_child(_vspace(6))
		var nml := _label(String(pc[1]), 12, C_TEXT)
		nml.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nml.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sec.add_child(nml)
		pair.add_child(sec)
	col.add_child(pair)

	_content.add_child(_ack_panel)


## 鸣谢面板的强调细线（1px、直角、横向铺满）。
func _ack_rule(col: Color, alpha: float) -> ColorRect:
	var ln := ColorRect.new()
	ln.color = Color(col.r, col.g, col.b, alpha)
	ln.custom_minimum_size = Vector2(0, 1)
	ln.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return ln


## 鸣谢面板的分段标题：「—— 标题 ——」居中 + 两侧青色细短线。
## ⚠️ 只服务鸣谢面板；版权面板仍是原来的纯文字小标题（不动它）。
func _ack_section(title: String, with_rule: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if with_rule:
		var l1 := _ack_rule(C_SEP, 1.0)
		l1.custom_minimum_size = Vector2(48, 1)
		l1.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(l1)
	var lb := _label(title, 13, C_ACCENT)
	lb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lb)
	if with_rule:
		var l2 := _ack_rule(C_SEP, 1.0)
		l2.custom_minimum_size = Vector2(48, 1)
		l2.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(l2)
	return row


func _build_modes() -> void:
	var cap := _label(T.t("MENU_MODES_CAP", "游戏模式　MODE"), 9, Color(0.73, 0.83, 0.87, 1.0))
	cap.position = MODES_POS - Vector2(0, 32)
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(cap)

	_modes_col = VBoxContainer.new()
	_modes_col.name = "Modes"
	_modes_col.position = MODES_POS
	_modes_col.add_theme_constant_override("separation", int(MODE_GAP))
	_content.add_child(_modes_col)
	_rebuild_rail()


## 按 `_modes`（可见行）重建整列按钮 —— 展开/收起时要整列重建。
##
## ⚠️ 子行包一层 `MarginContainer` 做**缩进**：`VBoxContainer` 会覆盖子节点的
##    `position` ⇒ 直接在按钮上写偏移没用。
func _rebuild_rail() -> void:
	for c in _modes_col.get_children():
		c.queue_free()
	_mode_btns.clear()
	_mode_names.clear()
	_mode_metas.clear()
	_mode_bars.clear()
	_mode_arrows.clear()
	for i in _modes.size():
		var b := _make_mode_row(_modes[i])
		b.pressed.connect(_on_mode_pressed.bind(i))
		var depth := int((_modes[i] as Dictionary).get("depth", 0))
		if depth > 0:
			var wrap := MarginContainer.new()
			wrap.add_theme_constant_override("margin_left", int(SUB_INDENT))
			wrap.add_child(b)
			_modes_col.add_child(wrap)
		else:
			_modes_col.add_child(b)
		_mode_btns.append(b)


## 某个模式的卡片区布局：「几列 + 卡片多大」。
##
## ⚠️ 由**模式 id** 决定，⛔ 不写在卡片代码里、也不散落成 if ——
##    加一种新布局只改这里一处。
##    任务关卡：3 列 × 470 高（原样，视觉不变）
##    棋牌室：  2 列 × 196 高 ⇒ 2 行 2 列的方框（用户 2026-10-06 定的形态）
func _layout_of(mode_id: String) -> Dictionary:
	if mode_id == CARD_ROOM_MODE_ID:
		return {"cols": 2, "w": GRID_W, "h": GRID_H}
	return {"cols": 4, "w": STRIP_W, "h": STRIP_H}


## 模式项 = 按钮（皮肤抄 EveButtonTheme；两行文字用子 Label，别指望 Button 自带）
##
## ★ 2026-10-12：两种行 —
##   · `depth == 0`（第一层）：原尺寸原字号；
##   · `depth == 1`（第二层 / 缩进子项）：略窄略矮、字号小一档（层级感）；
##   · `parent == true`（自走棋）：右侧箭头常显，文字是 `▾`（展开）/ `▸`（收起）。
func _make_mode_row(m: Dictionary) -> Button:
	var depth := int(m.get("depth", 0))
	var is_parent := bool(m.get("parent", false))
	var b := Button.new()
	b.name = "Mode_" + String(m["id"])
	b.custom_minimum_size = Vector2(
			MODE_W - (SUB_INDENT if depth > 0 else 0.0),
			SUB_MODE_H if depth > 0 else MODE_H)
	b.text = ""
	b.clip_contents = true
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.tooltip_text = _mode_txt(m, "name")

	# 选中态左侧亮条。⚠️ Button 不是 Container，子节点不会被 fit ⇒ 锚点可用。
	var bar := ColorRect.new()
	bar.color = C_ACCENT
	bar.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	bar.offset_right = 3.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.visible = false
	b.add_child(bar)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 18.0
	box.offset_top = 12.0 if depth == 0 else 9.0
	box.offset_right = -40.0
	box.offset_bottom = -12.0 if depth == 0 else -9.0
	box.add_theme_constant_override("separation", 5)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nm := _label(_mode_txt(m, "name"), 19 if depth == 0 else 16, C_TEXT)
	var mt := _label(_mode_meta(m), 11 if depth == 0 else 10, C_DIM)
	box.add_child(nm)
	box.add_child(mt)
	b.add_child(box)

	var ch := _label("›", 15, C_ACCENT)
	ch.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	ch.offset_left = -34.0
	ch.offset_right = -15.0
	ch.offset_top = -10.0
	ch.offset_bottom = 10.0
	ch.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# ★ 父项：箭头常显且是折叠指示（▾ 展开 / ▸ 收起）；其余沿用「选中才显示 ›」。
	if is_parent:
		ch.text = "▾" if _expanded else "▸"
		ch.visible = true
	else:
		ch.visible = false
	b.add_child(ch)

	_mode_names.append(nm)
	_mode_metas.append(mt)
	_mode_bars.append(bar)
	_mode_arrows.append(ch)
	return b


func _build_strips() -> void:
	# ★ 2026-10-06：HBox → Grid。任务关卡仍是「3 列排一行」，视觉与从前一致；
	#   棋牌室用「2 列」⇒ 自然排成 2×2。⛔ 别为棋牌室另开一套控件 ——
	#   同一套卡片，只换列数与尺寸。
	_strip_row = GridContainer.new()
	_strip_row.name = "Strips"
	_strip_row.position = STRIP_POS
	_strip_row.columns = 3
	_strip_row.add_theme_constant_override("h_separation", int(STRIP_GAP))
	_strip_row.add_theme_constant_override("v_separation", int(GRID_GAP_V))
	_content.add_child(_strip_row)

	# ★ 2026-10-28 图鉴入口：难度卡片**下面**一颗按钮（用户定的位置）。
	#   只在「任务关卡」这一行显示（`_refresh()` 里按 `_content_id()` 收放）。
	_codex_btn = Button.new()
	_codex_btn.name = "CodexButton"
	_codex_btn.text = T.t("CODEX_OPEN", "舰船图鉴 · %d 艘") % SHIP_DB.count()
	_codex_btn.custom_minimum_size = Vector2(300, 42)
	_codex_btn.size = Vector2(300, 42)
	_codex_btn.position = Vector2(STRIP_POS.x, STRIP_POS.y + STRIP_H + 16.0)
	_codex_btn.add_theme_font_size_override("font_size", 15)
	BTN_THEME.apply(_codex_btn, "hud")
	_codex_btn.pressed.connect(_open_codex)
	_content.add_child(_codex_btn)


## 打开舰船图鉴（懒建；浮层挂根节点 = 屏幕空间，手机档不会被设计空间裁掉）。
func _open_codex() -> void:
	if _codex == null:
		_codex = CODEX_SCRIPT.new()
		_codex.name = "ShipCodex"
		add_child(_codex)
	_codex.call("open")


## 一条难度 = 一个竖长条
func _make_strip(card: Dictionary, idx: int) -> void:
	var open := bool(card["open"])
	var p := PanelContainer.new()
	p.name = "Strip_%d" % idx
	p.custom_minimum_size = Vector2(_card_w, _card_h)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	p.add_theme_stylebox_override("panel", _strip_style(false, open))
	p.gui_input.connect(_on_strip_input.bind(idx))

	var mn := MarginContainer.new()
	mn.add_theme_constant_override("margin_left", 22)
	mn.add_theme_constant_override("margin_right", 22)
	mn.add_theme_constant_override("margin_top", 26)
	mn.add_theme_constant_override("margin_bottom", 22)
	p.add_child(mn)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mn.add_child(col)

	var nm := _label(_card_txt(card, "name"), 23, C_TEXT_HI if open else Color(0.91, 0.96, 0.97, 0.72))
	col.add_child(nm)
	col.add_child(_vspace(10))
	col.add_child(_label(_card_txt(card, "code"), 9,
			Color(0.55, 0.78, 0.82, 0.55 if open else 0.38)))
	col.add_child(_vspace(18))

	# ⚠️ autowrap 的 Label **必须给死宽**：宽度为 0 时它会按"一个字一行"折行，
	#    量出的最小高度大得离谱（设置窗踩过，见 MEMORY 第 1 章）。
	var desc := _label(_card_txt(card, "desc"), 13,
			Color(0.81, 0.89, 0.91, 0.88) if open else Color(0.71, 0.79, 0.81, 0.62))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(_card_w - 2.0 - 44.0, 0)
	desc.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	col.add_child(desc)
	col.add_child(_vspace(22))
	col.add_child(_make_kv(card["stats"], open))

	var sp := Control.new()
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(sp)

	var sep := ColorRect.new()
	sep.color = C_SEP
	sep.custom_minimum_size = Vector2(0, 1)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(sep)
	col.add_child(_vspace(20))

	var act := HBoxContainer.new()
	act.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var b := Button.new()
	b.name = "Start"
	# ⚠️ 按钮文案由 open **推导**，不放进难度表 ——
	#    "按钮写什么"是 UI 决策，数据表只描述"这一档开没开"。
	# ⚠️ 中英语序不同（中「▶　开始X」/ 英「▶ Start X」）⇒ 整句做成带 `%s` 的一条，
	#    ⛔ 别把「开始」和名字拼起来 —— 拼出来的英文是 "StartDou Dizhu"。
	b.text = (T.t("MENU_START", "▶　开始%s") % _card_txt(card, "name")) \
			if open else T.t("CARD_TODO", "待开发")
	b.custom_minimum_size = Vector2(0, 44)
	BTN_THEME.apply(b, "hud_main" if open else "hud")
	b.disabled = not open
	FONT.fs(b, 13)
	# ⚠️ 禁用按钮仍然 mouse_filter=STOP，会把点击吃掉 ⇒ 显式让给父面板，
	#    否则「点这条待开发长条也选中它」这个交互会失效。
	b.mouse_filter = Control.MOUSE_FILTER_STOP if open else Control.MOUSE_FILTER_IGNORE
	if open:
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		# ⚠️⚠️ 2026-10-26：按钮文案是「▶ 开始%s」，所以点它必须**真的用这一档开局**。
		#    旧写法直接连 _on_start_pressed()，而那个函数读的是「当前选中的卡片」
		#    ⇒ 按钮文案是「开始炼狱」，实际用「简单」开局（人和 AI 都会被骗）。
		#    现在带上自己的 idx：先选中自己，再走原来那条开始路径。
		b.pressed.connect(_on_start_pressed_for.bind(idx))
	act.add_child(b)
	col.add_child(act)

	# 选中亮条 —— ⚠️ 必须垫一层普通 Control 当覆盖层：
	#    PanelContainer 是 Container，会把**每一个**子节点 fit 成自己的整块矩形，
	#    直接挂 ColorRect 的话锚点全被覆盖（eve_window 的缩放把手踩过这个坑）。
	var ov := Control.new()
	ov.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(ov)
	var bar := ColorRect.new()
	bar.color = C_ACCENT
	bar.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	bar.offset_right = 3.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ov.add_child(bar)
	bar.visible = false

	_strip_panels.append(p)
	_strip_bars.append(bar)
	_strip_row.add_child(p)


func _make_kv(stats: Array, open: bool) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for s in stats:
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(0, 24)
		row.add_theme_constant_override("separation", 6)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var k := _label(_stat_txt(String(s[0])), 11, C_DIM)
		k.custom_minimum_size = Vector2(66, 0)
		row.add_child(k)
		var tint := String(s[2]) if s.size() > 2 else ""
		var vcol := C_TEXT
		if tint == "gold":
			vcol = C_GOLD
		elif not open:
			vcol = Color(0.63, 0.71, 0.73, 0.70)
		var v := _label(_stat_txt(String(s[1])), 11, vcol)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.clip_text = true
		row.add_child(v)
		box.add_child(row)
	return box


func _strip_style(on: bool, open: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	if open:
		sb.bg_color = C_STRIP_ON if on else C_STRIP
		sb.border_color = C_ACCENT if on else C_BORDER
	else:
		sb.bg_color = C_STRIP_LOCK_ON if on else C_STRIP_LOCK
		sb.border_color = Color(0.55, 0.78, 0.82, 0.45) if on else C_BORDER_LOCK
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)          # 工程铁律：直角
	sb.set_content_margin_all(0)
	return sb


func _label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	FONT.fs(l, size)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _vspace(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# ------------------------------------------------------------------ 刷新

func _refresh() -> void:
	for i in _modes.size():
		var m: Dictionary = _modes[i]
		_on_sel(_mode_btns[i], _mode_names[i], _mode_metas[i], _mode_bars[i],
				_mode_arrows[i], i == _mode_idx, bool(m.get("locked", false)))
		# ★ 父项（自走棋）的箭头是**折叠指示**，必须常显（`_on_sel` 只在选中时显示）。
		if bool(m.get("parent", false)):
			_mode_arrows[i].visible = true

	# 难度条整体重建（数量随模式变）
	for c in _strip_panels:
		c.queue_free()
	_strip_panels.clear()
	_strip_bars.clear()
	for c in _strip_row.get_children():
		c.queue_free()

	# ★ 2026-10-10 版权声明：右侧换成大方框，收掉卡片区。
	if _is_credits():
		_strip_row.visible = false
		if _codex_btn != null:
			_codex_btn.visible = false
		if _credits_panel != null:
			_credits_panel.visible = true
		# ★ 2026-11-01：版权声明面板出现时，把鸣谢名单面板让位收掉（同一位置，避免重叠）。
		if _ack_panel != null:
			_ack_panel.visible = false
		return
	# ★ 鸣谢名单面板打开时同样收掉卡片区（与版权声明同款），避免盖住面板
	if _ack_panel != null and _ack_panel.visible:
		_strip_row.visible = false
	else:
		_strip_row.visible = true
	if _credits_panel != null:
		_credits_panel.visible = false
	# ★ 图鉴按钮只在「任务关卡」显示（放难度卡片正下方，别的模式不占版面）
	if _codex_btn != null:
		var ack_open2 := _ack_panel != null and _ack_panel.visible
		_codex_btn.visible = (not ack_open2) and (String(_content_id()) == "campaign")

	var cards := _cards_of(_mode_idx)
	# 先按模式定好「列数 + 卡片尺寸」，再让 `_make_strip` 去建 ——
	# 顺序不能反：`_make_strip` 读的就是这两个量。
	var grid := _layout_of(_content_id())
	_strip_row.columns = int(grid["cols"])
	_card_w = float(grid["w"])
	_card_h = float(grid["h"])
	for i in cards.size():
		_make_strip(cards[i], i)
	var rows := int(ceil(float(cards.size()) / float(_strip_row.columns)))
	_strip_row.size = Vector2(
			_card_w * _strip_row.columns + STRIP_GAP * (_strip_row.columns - 1),
			_card_h * rows + GRID_GAP_V * (rows - 1))
	_refresh_strips()


func _refresh_strips() -> void:
	var cards := _cards_of(_mode_idx)
	var sel := int(_pick[_content_id()])
	for i in _strip_panels.size():
		var open := bool(cards[i]["open"])
		_strip_panels[i].add_theme_stylebox_override("panel", _strip_style(i == sel, open))
		_strip_bars[i].visible = i == sel


func _on_sel(b: Button, nm: Label, mt: Label, bar: ColorRect, ch: Label,
		on: bool, locked: bool) -> void:
	BTN_THEME.apply(b, "hud")
	if on:
		for st in ["normal", "hover", "pressed", "focus"]:
			var sb := b.get_theme_stylebox(st)
			if sb == null:
				continue
			var d: StyleBoxFlat = sb.duplicate()
			d.border_color = C_ACCENT if not locked else Color(0.55, 0.78, 0.82, 0.45)
			d.bg_color = Color(0.11, 0.17, 0.20, 0.92) if not locked \
					else Color(0.078, 0.11, 0.125, 0.85)
			b.add_theme_stylebox_override(st, d)
	bar.visible = on
	ch.visible = on
	nm.add_theme_color_override("font_color",
			C_TEXT_HI if on else (Color(0.55, 0.78, 0.82, 0.34) if locked else C_TEXT))
	mt.add_theme_color_override("font_color",
			Color(0.63, 0.78, 0.82, 0.90) if on else Color(0.44, 0.55, 0.59, 0.55))
	ch.add_theme_color_override("font_color",
			C_ACCENT if not locked else Color(0.55, 0.78, 0.82, 0.45))


# ------------------------------------------------------------------ 交互

func _on_mode_pressed(i: int) -> void:
	var m: Dictionary = _modes[i]
	# ★ 2026-10-12：父项（自走棋）—— 点击 = 展开 / 收起（用户定：展开后自动选中
	#   第一个子项「任务关卡」，玩家一步到位，不用点两次）。
	if bool(m.get("parent", false)):
		var ch: Array = m.get("children", [])
		_expanded = not _expanded
		_rebuild_rows()          # 收起时选中行自动回落到父项（见该函数）
		_rebuild_rail()
		if _expanded and ch.size() > 0:
			var sub := _index_of_id(String((ch[0] as Dictionary)["id"]))
			if sub >= 0:
				_mode_idx = sub
		_refresh()
		return
	if i == _mode_idx:
		return
	_mode_idx = i
	_refresh()


func _on_strip_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var id := _content_id()
		if int(_pick[id]) == idx:
			return
		_pick[id] = idx
		_refresh_strips()


## 「开始」——目前只有守卫边境是开放难度。
## ★ 开场剧情：**只在第一次玩时播**（`user://progress.cfg` 的 `intro_seen`）。
##   第一次 ⇒ 先进 intro_scene（看完/跳过后写盘）再进对局；之后 ⇒ 直接进对局。
##   菜单顶右有「回看片头」可以随时再看 —— 跳过不可以是不可逆的。
## ⚠️ 以后多难度都做好时，这里要按选中的难度把参数带给对局/开场场景
##    （`mode: String` / `tier_id: String`）。现在对局场景还没有这个入参，
##    所以先只做「进去」这一件事，不做假参数。
## ★ 纯函数：返回「开始」该去哪（"" = 不该去，这一档还没开放）。
##   抽出来的理由：验收要能**在不真的切场景**的前提下测「首次 / 非首次」这条分支
##   —— 自检节点本身是 current_scene，真切场景会把它一起销毁。
func target_scene_for_start() -> String:
	# ⚠️ 版权声明没有卡片（`cards` 为空）⇒ 必须先挡掉，否则下面的 `cards[sel]` 越界。
	if _is_credits():
		return ""
	var cards := _cards_of(_mode_idx)
	var sel := int(_pick[_content_id()])
	if not bool(cards[sel]["open"]):
		return ""
	var mode_id := _content_id()
	# 联机对战：两张真人卡片都先进大厅（建房/加入在那里握手）。
	# ⚠️ 必须在 tier_id 分支之前判：联机卡片没有 `id` 字段。
	if mode_id == VERSUS_MODE_ID:
		var vcode := String(cards[sel].get("code", ""))
		if vcode == "VERSUS_HOST" or vcode == "VERSUS_JOIN":
			RUN_STORE.pending_versus_role = "host" if vcode == "VERSUS_HOST" else "join"
			RUN_STORE.pending_versus_ai = 0
			return VERSUS_LOBBY_SCENE
	# ★ 棋牌室（2026-10-06 二次改）：**不再切独立场景**，所以这里返回 ""。
	#   ⚠️ 放在 tier_id 之前判：棋牌室的卡片没有 `id` 字段，
	#      落到下面会被当成「非首次」而错误地进 BATTLE_SCENE。
	#   ⚠️ 返回 "" 会被 `_on_start_pressed` 拦下并**给明确提示**
	#      （⛔ 不许静默 return —— 红线 9）。
	#   ▶ P2 接上牌局后改成：选中斗地主 ⇒ 返回牌局场景；否则 ""。
	if mode_id == CARD_ROOM_MODE_ID:
		# ★ 选中「斗地主」⇒ 进牌局场景；其余三张待开发 ⇒ 返回 ""（不切，
		#   由 `_on_start_pressed` 给明确提示，⛔ 不静默）。
		# ⚠️ 判据用 `code` 而不是下标 —— 卡片顺序将来可能变。
		if String(cards[sel].get("code", "")) == "DOUDIZHU":
			return DOUDIZHU_SCENE
		return ""
	var tier_id := String(cards[sel].get("id", ""))
	# ★ Web 试玩版**不播开场**：那段是 13 MB 的视频 + 一整套逐句演出，
	#   网页首屏等不起，而且玩家从落地页点「试玩」的期待就是直接开打。
	#   ⇒ `web` 下 `first_time` 恒 false，直接进战场。
	var first_time := (mode_id == FIRST_MODE_ID and tier_id == FIRST_TIER_ID
			and not PROGRESS.intro_seen() and not OS.has_feature("web"))
	return INTRO_SCENE if first_time else BATTLE_SCENE


## 底部一行临时提示（点「开始」但目标还没做出来时用）。
## ⚠️ 存在的唯一理由是**红线 9**：别摆「看着能点、点了没反应」的东西。
var _toast: Label = null


func _show_toast(text: String) -> void:
	if _toast == null:
		_toast = Label.new()
		_toast.name = "Toast"
		FONT.fs(_toast, 14)
		_toast.add_theme_color_override("font_color", C_GOLD)
		_toast.position = Vector2(STRIP_POS.x, 852)
		_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_content.add_child(_toast)
	_toast.text = text


## 「▶ 开始X」按钮：先选中自己这一档，再走统一的开始路径。
##
## ⚠️ 只在「有难度概念」的模式（任务关卡）里切选中；其它模式的卡片不是难度，
##    强行写 _pick 会破坏它们自己的选中语义。
func _on_start_pressed_for(idx: int) -> void:
	if _content_id() == FIRST_MODE_ID:
		var cards := _cards_of(_mode_idx)
		if idx >= 0 and idx < cards.size():
			_pick[_content_id()] = idx
			_refresh_strips()
	_on_start_pressed()


func _on_start_pressed() -> void:
	var cards := _cards_of(_mode_idx)
	var sel := int(_pick[_content_id()])
	var target := target_scene_for_start()
	if target == "":
		# ⚠️ 不能静默 return：玩家点了「开始」必须知道为什么没动静（红线 9）。
		if _content_id() == CARD_ROOM_MODE_ID:
			if String(cards[sel]["code"]) == "DOUDIZHU":
				_show_toast(T.t("MENU_TOAST_DDZ",
						"斗地主制作中 —— 规则内核与人机对战开发中，开放后这里直接进牌局"))
			else:
				_show_toast(T.t("MENU_TOAST_MODE_WIP", "「%s」还在开发中")
						% _card_txt(cards[sel], "name"))
		return
	print("[主界面] 开始 %s / %s → %s%s"
			% [_content_row_of(_mode_idx)["name"], cards[sel]["name"], target,
			   "（首次 ⇒ 先播开场）" if target == INTRO_SCENE else "（已看过开场）"])
	# ★ 2026-10-10（审查 2#2）：只有**真实会话**才允许写对局存档
	#   （40 多个 probe/自检会直接加载 battle_scene，不设闸就会覆盖玩家的一局）。
	# ★★ 2026-10-26 真 bug 修复：切场景带不了参数，必须把选中的难度 id 存进
	#    EveRunStore.pending_difficulty，战场启动时取用。
	#    这段以前从来没写过 —— pending_difficulty 只有声明/清空/读取三处，
	#    没有赋值，所以战场永远走默认 "simple"，菜单选什么都打成简单。
	#    ⚠️ 只对任务关卡生效（棋牌室 / 斗地主没有难度概念）。
	if _content_id() == FIRST_MODE_ID:
		RUN_STORE.pending_difficulty = String(cards[sel].get("id", "simple"))
	# ★ 2026-10-27：联机对战把 AI 对手数带给战场（EveMatchState 用它建房）
	if _content_id() == VERSUS_MODE_ID:
		var code := String(cards[sel].get("code", "VERSUS_1"))
		# ⚠️ VERSUS_HOST / VERSUS_JOIN 走大厅（真联机），不是人机档。
		#    原来无条件 substr(7) ⇒ 会把它们变成「0 个 AI」的假人机局。
		if code == "VERSUS_HOST" or code == "VERSUS_JOIN":
			RUN_STORE.pending_versus_ai = 0
		elif code.begins_with("VERSUS_"):
			RUN_STORE.pending_versus_ai = int(code.substr(7))
		else:
			RUN_STORE.pending_versus_ai = 0
		print("[versus] menu picked code = ", code, " ai = ", RUN_STORE.pending_versus_ai)
	else:
		RUN_STORE.pending_versus_ai = 0
		RUN_STORE.pending_versus_role = ""
	RUN_STORE.session_active = true
	get_tree().change_scene_to_file(target)


## 「继续上局」：直接恢复上一局的存档（⛔ 不经过开场剧情）。
func _on_continue_run() -> void:
	if not RUN_STORE.has_run():
		_show_toast(T.t("MENU_TOAST_NO_RUN", "没有可继续的对局"))
		return
	print("[主界面] 继续上一局 → %s" % BATTLE_SCENE)
	RUN_STORE.session_active = true
	RUN_STORE.resume_requested = true
	get_tree().change_scene_to_file(BATTLE_SCENE)


## 菜单顶右「回看片头」：不看进度，直接进开场；**不重置** intro_seen
## （它本来就已经是 true；重置反而会让"下次开局又被拦一次"）。
func _on_replay_intro() -> void:
	print("[主界面] 回看片头 → %s" % INTRO_SCENE)
	get_tree().change_scene_to_file(INTRO_SCENE)


func _on_quit() -> void:
	print("[主界面] 退出游戏")
	get_tree().quit()


## 键盘：上下切模式、左右切难度、回车=开始
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	# ★ 2026-10-10 设置窗开着 ⇒ 菜单的键盘导航**让位**（只留 Esc 关窗）：
	#   否则玩家在窗里调设置时，背后的模式/难度还跟着上下左右键乱跳；
	#   而 Esc 原本是「退出游戏」——窗开着时直接退游会吓人，先关窗才对。
	if _settings != null and _settings.visible:
		if event.keycode == KEY_ESCAPE:
			_settings.visible = false
			get_viewport().set_input_as_handled()
		return
	var cards := _cards_of(_mode_idx)
	var id := _content_id()
	match event.keycode:
		KEY_DOWN:
			_on_mode_pressed((_mode_idx + 1) % _modes.size())
		KEY_UP:
			_on_mode_pressed((_mode_idx - 1 + _modes.size()) % _modes.size())
		KEY_RIGHT:
			# ⚠️ 版权声明没有难度可切，且 `cards.size() == 0` ⇒ `% 0` 会报除零。
			if not _is_credits():
				_pick[id] = (_pick[id] + 1) % cards.size()
				_refresh_strips()
		KEY_LEFT:
			if not _is_credits():
				_pick[id] = (_pick[id] - 1 + cards.size()) % cards.size()
				_refresh_strips()
		KEY_ENTER, KEY_KP_ENTER:
			_on_start_pressed()
		KEY_ESCAPE:
			_on_quit()
		_:
			return
	get_viewport().set_input_as_handled()


# ══════════════════════════════════════════════════════════════════
#  AI 操作面（2026-10-26）—— 主菜单
# ══════════════════════════════════════════════════════════════════
# 与战斗场景那一节同源：AI 从这里开机进一局，不用人去点。


func ai_kind() -> String:
	return "menu"


## 界面上所有可点按钮的矩形（AI 用鼠标点，不后台调）。
func ai_ui_map() -> Dictionary:
	var out := {"buttons": [], "strips": [],
			"viewport": [get_viewport().get_visible_rect().size.x,
					get_viewport().get_visible_rect().size.y]}
	# 难度长条本体：点它才「选中」该难度（点里面的开始按钮不会切换！）
	var srow = _strip_row
	if srow != null:
		for i in srow.get_child_count():
			var sp: Control = srow.get_child(i)
			if not (sp is Control) or not sp.is_visible_in_tree():
				continue
			var sr: Rect2 = sp.get_global_rect()
			(out["strips"] as Array).append({
					"index": i,
					"name": String(sp.name),
					"rect": [sr.position.x, sr.position.y, sr.size.x, sr.size.y],
					"path": String(sp.get_path()),
				})
	var btns: Array[Button] = []
	var stack: Array[Node] = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Button and (n as Button).is_visible_in_tree():
			btns.append(n)
		for c in n.get_children():
			stack.append(c)
	for b in btns:
		var r: Rect2 = b.get_global_rect()
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		(out["buttons"] as Array).append({
				"name": b.text.strip_edges() if b.text.strip_edges() != "" else String(b.name),
				"rect": [r.position.x, r.position.y, r.size.x, r.size.y],
			})
	return out


## 按名字 / 文字找按钮，用鼠标点它。
##
## ⚠️ 自带坐标校准：`get_global_rect()` 与 `Input.warp_mouse()` 的坐标空间
##    在「设计空间 ≠ 视口」时会对不上（实测右上角一排系统性偏 +102px，
##    而左侧模式栏又不偏）。所以这里**不信矩形**，先在报告位置附近螺旋搜一圈，
##    用 `gui_get_hovered_control()` 找「命中测试确实命中它」的那个点，
##    再真的挪鼠标过去点。
##    ⇒ AI 只说「点设置」，光标自己会找到该去的地方。仍然是纯鼠标操作。
func ai_ui_click(query: String) -> Dictionary:
	var btn := _ai_find_button(query)
	if btn == null:
		return {"ok": false, "reason": "找不到按钮「%s」" % query}
	var r: Rect2 = btn.get_global_rect()
	var cx := r.position.x + r.size.x * 0.5
	var cy := r.position.y + r.size.y * 0.5
	var hit := Vector2(cx, cy)
	var calibrated := false
	for ring in range(0, 10):
		var pts: Array = []
		if ring == 0:
			pts.append(Vector2(cx, cy))
		else:
			var step := 14.0 * float(ring)
			for a in range(8):
				var ang := float(a) * PI * 0.25
				pts.append(Vector2(cx + cos(ang) * step, cy + sin(ang) * step))
		for p in pts:
			ai_mouse_move(p.x, p.y)
			await get_tree().create_timer(0.02).timeout
			if get_viewport().gui_get_hovered_control() == btn:
				hit = p
				calibrated = true
				break
		if calibrated:
			break
	var res: Dictionary = await ai_mouse_click(hit.x, hit.y)
	res["data"]["target"] = String(btn.name)
	res["data"]["calibrated"] = calibrated
	return res


func _ai_find_button(query: String) -> Button:
	var q := query.strip_edges()
	if q == "":
		return null
	var all: Array[Button] = []
	var stack: Array[Node] = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Button and (n as Button).is_visible_in_tree():
			all.append(n)
		for c in n.get_children():
			stack.append(c)
	# 先按名字精确匹配，再按文字
	for b in all:
		if String(b.name) == q:
			return b
	for b in all:
		if b.text.strip_edges() == q:
			return b
	for b in all:
		if q in b.text or q in String(b.name):
			return b
	return null


## 把光标挪到 (x,y) 并回报**真正命中**的那个控件。
##
## 为什么需要它：`get_global_rect()` 与 `Input.warp_mouse()` 的坐标空间
## 在「设计空间 ≠ 视口」时会对不上（实测差 102px，用户看到的就是
## 「光标在按钮上但点到别处」）。用命中测试反查可以当场校准。
func ai_hover(x: float, y: float) -> Dictionary:
	ai_mouse_move(x, y)
	await get_tree().create_timer(0.1).timeout
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "reason": "no viewport"}
	var c := vp.gui_get_hovered_control()
	var out := {"ok": true, "data": {
		"asked": [x, y],
		"hovered": String(c.name) if c != null else "",
		"hovered_text": c.text.strip_edges() if (c is Button) else "",
		"hovered_rect": [c.get_global_rect().position.x, c.get_global_rect().position.y,
				c.get_global_rect().size.x, c.get_global_rect().size.y] if c != null else [],
	}}
	return out


## 主菜单快照：模式 / 难度 / 有没有存档可续。
func ai_snapshot() -> Dictionary:
	var id := _content_id()
	var cards := _cards_of(_mode_idx)
	var card_list: Array = []
	for i in cards.size():
		var c: Dictionary = cards[i]
		card_list.append({
			"index": i,
			"id": String(c.get("id", "")),
			"name": String(c.get("name", "")),
			"meta": String(c.get("meta", "")),
		})
	var mode_list: Array = []
	for i in _modes.size():
		var m: Dictionary = _modes[i]
		mode_list.append({
			"index": i,
			"id": String(m.get("id", "")),
			"name": String(m.get("name", "")),
			"parent": bool(m.get("parent", false)),
		})
	return {
		"scene": "menu",
		"modes": mode_list,
		"mode_index": _mode_idx,
		"content_id": id,
		"difficulties": card_list,
		"difficulty_index": int(_pick.get(id, 0)),
		"has_run": bool(RUN_STORE.has_run()),
		"settings_open": bool(_settings != null and _settings.visible),
		"toast": String(_toast.text) if _toast != null else "",
	}


## 选左侧模式（父项 = 展开/收起）。
func ai_select_mode(index: int) -> Dictionary:
	if index < 0 or index >= _modes.size():
		return {"ok": false, "reason": "模式下标越界（0~%d）" % (_modes.size() - 1)}
	_on_mode_pressed(index)
	return {"ok": true}


## 选右侧难度卡（只改选中项，不开局）。
func ai_select_difficulty(index: int) -> Dictionary:
	var cards := _cards_of(_mode_idx)
	if index < 0 or index >= cards.size():
		return {"ok": false, "reason": "难度下标越界（0~%d）" % (cards.size() - 1)}
	_pick[_content_id()] = index
	_refresh_strips()
	return {"ok": true}


## 开始一局。可选先指定难度下标 / 难度 id。
## ⚠️ 走的是 `_on_start_pressed()` —— 与点「开始」按钮同一条路
##    （含首次进开场剧情的分派），不另造第二份启动逻辑。
func ai_start(difficulty_index: int = -1, difficulty_id: String = "") -> Dictionary:
	if difficulty_index >= 0:
		var r := ai_select_difficulty(difficulty_index)
		if not bool(r.get("ok", false)):
			return r
	elif difficulty_id != "":
		var cards := _cards_of(_mode_idx)
		var hit := -1
		for i in cards.size():
			if String((cards[i] as Dictionary).get("id", "")) == difficulty_id:
				hit = i
				break
		if hit < 0:
			return {"ok": false, "reason": "当前模式没有难度 id=%s" % difficulty_id}
		_pick[_content_id()] = hit
		_refresh_strips()
	_on_start_pressed()
	return {"ok": true}


## 继续上一局（直接恢复存档，不进片头）。
func ai_continue() -> Dictionary:
	if not RUN_STORE.has_run():
		return {"ok": false, "reason": "没有可继续的对局"}
	_on_continue_run()
	return {"ok": true}


## 设置窗开 / 关。
func ai_settings(on: bool) -> Dictionary:
	if _settings == null:
		return {"ok": false, "reason": "设置窗未建"}
	var open_now: bool = _settings.visible
	if open_now != on:
		_toggle_settings()
	return {"ok": true}


## 回看片头。
func ai_replay_intro() -> Dictionary:
	_on_replay_intro()
	return {"ok": true}


## 退出游戏。
func ai_quit_game() -> Dictionary:
	_on_quit()
	return {"ok": true}


# ── 鼠标合成（与战斗场景同一套口径）────────────────────────────
# 用户定案：不准后台操作。AI 必须像人一样挪光标、点按钮。
## 光标托管状态（与战斗场景同一套语义）：用完即还，不和用户抢鼠标。
var _cursor_locked := false
var _cursor_home := Vector2.ZERO
var _cursor_restore_ms := 0.0


func ai_cursor_lock(on: bool) -> Dictionary:
	_cursor_locked = on
	if on:
		_cursor_home = DisplayServer.mouse_get_position()
		_cursor_restore_ms = 0.0
	return {"ok": true, "data": {"home": [_cursor_home.x, _cursor_home.y], "locked": on}}


func ai_mouse_move(x: float, y: float) -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "reason": "no viewport"}
	var sz := vp.get_visible_rect().size
	var p := Vector2(clampf(x, 0.0, sz.x), clampf(y, 0.0, sz.y))
	# ⛔ 2026-10-27：不再 warp 真实光标（不和用户抢鼠标），只推事件；
	#    引擎会把 OS 光标同步过去，所以托管开启时**用完立刻还回去**。
	var m := InputEventMouseMotion.new()
	m.position = p
	m.global_position = p
	m.relative = Vector2.ZERO
	# motion 走 parse_input_event（只更新 hover，不同步 OS 光标）
	Input.parse_input_event(m)
	return {"ok": true, "data": {"x": p.x, "y": p.y}}


func ai_mouse_down(x: float, y: float, button: int = MOUSE_BUTTON_LEFT) -> Dictionary:
	ai_mouse_move(x, y)
	await get_tree().create_timer(0.05).timeout
	_press(true, button, Vector2(x, y))
	return {"ok": true, "data": {"x": x, "y": y}}


func ai_mouse_up(x: float, y: float, button: int = MOUSE_BUTTON_LEFT) -> Dictionary:
	_press(false, button, Vector2(x, y))
	return {"ok": true, "data": {"x": x, "y": y}}


func ai_mouse_click(x: float, y: float, button: int = MOUSE_BUTTON_LEFT) -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "reason": "no viewport"}
	var sz := vp.get_visible_rect().size
	var p := Vector2(clampf(x, 0.0, sz.x), clampf(y, 0.0, sz.y))
	ai_mouse_move(p.x, p.y)
	await get_tree().create_timer(0.06).timeout
	_press(true, button, p)
	await get_tree().create_timer(0.06).timeout
	_press(false, button, p)
	return {"ok": true, "data": {"x": p.x, "y": p.y}}


func ai_mouse_drag(ax: float, ay: float, bx: float, by: float, steps: int = 12) -> Dictionary:
	ai_mouse_move(ax, ay)
	await get_tree().create_timer(0.08).timeout
	_press(true, MOUSE_BUTTON_LEFT, Vector2(ax, ay))
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		ai_mouse_move(lerpf(ax, bx, t), lerpf(ay, by, t))
		await get_tree().create_timer(0.03).timeout
	await get_tree().create_timer(0.06).timeout
	_press(false, MOUSE_BUTTON_LEFT, Vector2(bx, by))
	return {"ok": true}


func ai_mouse_path(points: Array, hold: bool = false) -> Dictionary:
	for i in points.size():
		var pt: Vector2 = points[i]
		if hold and i == 0:
			_press(true)
		ai_mouse_move(pt.x, pt.y)
		await get_tree().create_timer(0.03).timeout
	if hold:
		_press(false)
	return {"ok": true}


## ⚠️ 坐标必须**显式传进来**，不能回读 `vp.get_mouse_position()`：
##    `Input.warp_mouse()` 之后要等几帧才反映到 Viewport._mouse_pos，
##    回读会拿到上一个位置 —— 症状是「光标明明在按钮上，点的却是别处」
##    （实测：难度卡能点中、右上角按钮点不中，就是这个原因）。
func _press(down: bool, button: int = MOUSE_BUTTON_LEFT, p: Variant = null) -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var pos: Vector2 = p if p is Vector2 else vp.get_mouse_position()
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = down
	ev.position = pos
	ev.global_position = pos
	Input.parse_input_event(ev)
