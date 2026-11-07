extends Node
class_name EveRunState

## EVE 自走棋 —— 一局的状态机（阶段 A / Playable Loop v0）
##
## ══════════════════════════════════════════════════════════════════
##  这个类存在的唯一理由：把「一局游戏」这条循环从战斗场景里拆出来。
## ══════════════════════════════════════════════════════════════════
##
## 在此之前，`eve_battle_scene.gd` 的 `_start_battle()` 一个人干完了
## 「随机抽舰队 + 开打 + 打完 4 秒自动重开」，所以玩家赢了输了都只是
## 「重开一局随机舰队」，星币/等级/信标全是 demo 假数据（见路线文档 §0）。
##
## 现在四个阶段的职责是分开的：
##
##     PREP     准备：倒计时 + 商店 + 买船 + 升级      ← play 的唯一决策窗口
##     BATTLE   战斗：锁定操作，只有相机可动
##     RESOLVE  结算：漏船扣信标 / 发经验发钱 / 推进节点
##     ENDING   结局：通关（节点 15 打完）或撤离（信标归零）
##
## ⚠️ 本类【不碰任何 3D / UI】。它只有数字与信号。
##    战斗场景负责把数字变成船和窗口，HUD 负责把数字变成字。
##    所以 `tools/verify_run.tscn` 能在无头环境里把整局跑完并断言数值。
##
## ── 数值口径全部来自交接文档 §8，一律照抄，不在这里做平衡调整 ──────
##    §8.1 收入    基础 +5 / 利息 min(⌊gold/10⌋,5) / 刷新 2 / 买经验 4→4点
##                 每节点自动 +2 经验
##    §8.2 等级    MAX_LEVEL 6 / LEVEL_XP 累计阈值 / LEVEL_CAP 上场上限
##    §8.3 概率    8 档（1~6 是等级，7/8 是满级后的超频档）
##
## ── 唯一一处【工程侧反解】的数值：战败的信标代价（见 LOSS_BASE 注释）────
##
## 变更清单（阶段 A）：
##   - 四阶段状态机 + 信号（changed / phase_changed / offers_changed /
##     log_event / run_ended）
##   - 经济与等级：买船 / 刷新 / 加速等级 / 每节点自动经验 / 利息收入
##   - 商店 8 档概率表抽取（唯一抽取入口 _roll_one）
##   - 备战席 8 格 + 上场（**买入只进备战席**，上场唯一入口 = 玩家拖放，
##   - 信标 100 起步、战败扣血、通关/撤离判定
##   - 敌方数值叠加：base → star(×1.8^Δ) → power_scale（交接文档 §6.4）

signal changed()                                  ## 任何状态变化（HUD 重刷）
signal phase_changed(phase: int)
signal offers_changed()
signal log_event(text: String, category: StringName)
signal run_ended(cleared: bool)

enum Phase { PREP, BATTLE, RESOLVE, ENDING }
enum Ending { NONE, CLEARED, EVACUATED }

# ══════════════════════════════════════════════════════════════════
#  权威常数（交接文档 §8 · 与云顶之弈同口径 · 勿动）
# ══════════════════════════════════════════════════════════════════

const MAX_LEVEL := 6
## 下标 = 目标等级，值是【累计】经验阈值
const LEVEL_XP: Array[int] = [0, 0, 2, 4, 10, 20, 40]
## 上场上限 = 等级 + 2
const LEVEL_CAP: Array[int] = [0, 3, 4, 5, 6, 7, 8]
const BUY_XP_AMOUNT := 4
const BUY_XP_COST := 4
const NODE_XP_REWARD := 2
## 满级后每投 16 星币买经验 → 商店品质 +1 档（超频 1 / 超频 2）
const OVERTIER_COST := 16
const MAX_TIER := 8

## ── 战败追加伤害（连败递增，2026-10-01）────────────────────────
## 把「战胜不掉血」修掉之后，玩家只在**输**的时候掉血，而单场战败伤害
## 在后期也就 14~26 —— 连输三四场才掉得完 100 点信标，节奏偏松。
## 用户要求：「十多回合如果在后面几回合连续输，那真的会被打掉的。」
## ⇒ 连败每多一场 +2，封顶 +8。
## ⚠️ **第一场不加**（`lose_streak <= 1` 返回 0）—— 这样 BOSS 首败仍是
##    交接文档 §13 反解出来的那个锚点 −26，既有验收不被打破。
const LOSS_STREAK_STEP := 2
const LOSS_STREAK_BONUS_MAX := 8

const REFRESH_COST := 2
const START_GOLD := 5
const START_BEACON := 100
const SHOP_SLOTS := 5
const BENCH_SLOTS := 8

# ══════════════════════════════════════════════════════════════════
#  装备（2026-10-31 用户定案）
# ══════════════════════════════════════════════════════════════════
#
#  用户原话：「装备携带量，护卫驱逐一个，巡洋战巡两个，战列3个。
#    我在研究装备长啥样了，背包先定8个，但我感觉不是很够，
#    以后会研究装备合成路线的。」
#
#  ⇒ 槽位按**吨位**给（不看星级、不看羁绊）：
#       护卫(1费) / 驱逐(2费) = 1 格
#       巡洋(3费) / 战巡(4费) = 2 格
#       战列(5费)             = 3 格
#  ⇒ 背包固定 8 格（`EQUIP_BAG_SIZE`）。用户已经预判「不太够」，
#    做合成路线时这里要跟着改 —— 所以**别把 8 写死在 UI 里**，读这个常量。
#
# ⚠️ 物品属性表**还没定**（用户在设计中）。这一版只落三样东西：
#    ① 槽位容量（`equip_slots_for_cost`）—— UI / 掉落 / 验收的共同依据
#    ② 背包与增减（`bag` / `grant_equip` / `take_equip_at`）
#    ③ 掉落管道（`roll_equip` 产出**结构正确**的占位物）
#  ⛔ 别在这里编装备数值 —— 等用户的物品表到了再填 `apply_equips()`。
## 每格能放几件（键 = `cost`，也就是吨位档 1~5）
const EQUIP_SLOTS_BY_COST := {1: 1, 2: 1, 3: 2, 4: 2, 5: 3}
## 背包格数
const EQUIP_BAG_SIZE := 8
## 打捞时掉装备的概率（用户定：5%）
const EQUIP_SALVAGE_CHANCE := 0.05
const BASE_INCOME := 5
const INTEREST_STEP := 10
const INTEREST_MAX := 5

## 商店概率 8 档（交接文档 §8.3 冻结表）。值 = [1费, 2费, 3费, 4费, 5费]
##
## ⚠️ `shop_tier()` 是唯一的档位算法，`_roll_one()` 是唯一的抽取入口 ——
##    别在别处再造一份映射，那正是「两处真相源会漂移」的老坑。
const SHOP_ODDS := {
	1: [100, 0, 0, 0, 0],
	2: [80, 20, 0, 0, 0],
	3: [60, 30, 10, 0, 0],
	4: [50, 30, 20, 0, 0],
	5: [40, 20, 25, 15, 0],
	6: [30, 25, 25, 15, 5],
	7: [22, 25, 26, 17, 10],
	8: [15, 22, 28, 20, 15],
}

## ══════════════════════════════════════════════════════════════
##  ★ 战败的信标代价（2026-10-01 简化：**删掉「漏网」机制**）
## ══════════════════════════════════════════════════════════════
##  用户原话：「漏网机制我理解不了，删除，我真没发现这玩意儿有啥用」
##
##  **现在的规则只有三句话：**
##      打赢  → 信标一滴不掉
##      打输  → 信标掉【本表按阶段给定的定值】
##      连败  → 每多一场 +2，封顶 +8（见 `LOSS_STREAK_*`）
##
##  ⛔ **不再有「漏了几艘船」这个概念** —— 原来那一项
##     `Σ 漏网舰船费用` 已整个删除，代价只跟「这是什么类型的节点」有关。
##
##  数值怎么来的（不是拍脑袋）：
##     旧公式 = 阶段基础(battle2/elite3/boss4) + Σ漏网舰船费用
##     实测 15 个节点的 Σ费用：battle 2~12（**中位 6**）· elite 7~11（中位 11）· boss 22
##     ⇒ 把中位并进基础值 ⇒ battle 2+6=**8** · elite 3+11=**14** · boss 4+22=**26**
##     ⇒ ★ BOSS **−26** 这个交接文档 §13 的锚点**保持不变**
##
##  ⚠️ 取舍（改定值必然带来）：编组规模不再影响代价 ——
##     前期小编组节点（原 4）变 8、后期小编组（原 14）也变 8。
##     这是「简单」的代价，用户要的就是简单。**要恢复规模感，
##     正解是调这张表或按节点索引分档 —— 不要把 Σ 加回来。**
##
##  ★★ 2026-10-24（阶段 A）：本表现在是**回退表**。
##    真正生效的是难度档的 `EveCampaignTiers.DIFFICULTIES[].loss_curve`
##    （逐节点 15 个数字，理由是"同一个失误的代价要随进程上涨"，
##     见 `loss_damage()` 的长注释）。本表只在曲线缺失/越界时兜底。
##    ⚠️ 简单档的曲线逐节点等于本表的值 ⇒ 简单档行为与改之前完全一致。
const LOSS_BASE := {
	&"battle": 8,
	&"elite": 14,
	&"boss": 26,
	&"event": 0,
}

## 星级的数值倍率（交接文档 §6.4：star ×1.8^Δ）
const STAR_MULT := 1.8

# ── 打捞（阶段 C 第二件）────────────────────────────────────────────
#
# 设计规格（路线文档 §阶段C）：「战斗中击毁的敌船 → 残骸 → 玩家逐艘勾选
# → 延迟到账并占商店槽位」。四句话各自对应一个必须有的机制：
#
#   ① 击毁 → 残骸      = 残骸**只能从战斗里来**，不能凭空发。所以打捞是
#                        「打得好」的奖励，而不是一个独立商店。
#   ② 一个节点的生命周期 = 战斗结算时出现，玩家在这个节点的**结算页**上决定；
#                        再进下一节点还没选就整批漂走。
#                        这样它永远是一个**当下就要决定**的东西，不会攒着。
#   ③ 延迟到账 + 占槽位 = 下单当场付钱，但**不在本节点给你**；下个节点的
#                        商店里，它会**顶掉一个槽位**（且刷新不掉）。
#   ④ **敌我双方都进列表**（2026-10-01 定案）：原先只捞敌方，等于
#                        「打赢赔本货、输赢无所谓」。我方那几艘也进，
#                        但**定价不同**（见下）。
#
# 于是取舍是干净的：**用「少一个槽位」+ 一笔打捞费，换一艘你现在买不到的船**
# （敌方编组里有高费船，而你的商店档位受等级限制摇不出来）。
# 这条也解释了为什么不能「下单立刻给」——那样它只是打八折的购买，没有代价。
#
# ★★ 2026-10-04 用户定案：**两档定价**，制造「捞谁的取舍」：
#   我方残骸 × **0.5**（半价回收自己的船 —— 亏了要花钱补回来）
#   敌方残骸 × **1.0**（全价 —— 抢对面的要付溢价）
#   两档差价就是玩家每回合要做的博弈：钱只够捞一艘时，捞回自己死掉的
#   3 费划算，还是抢敌方那艘 4 费划算。
const SALVAGE_COST_RATIO := 0.5    ## ★ 我方残骸打捞费 = ⌈费用 × 0.5⌉，下限 1
const SALVAGE_COST_RATIO_ENEMY := 1.0  ## ★ 敌方残骸打捞费 = ⌈费用 × 1.0⌉，下限 1

## ★ 2026-10-28 事件「打捞折扣」生效期间的定价（比例是**相对船价**，不是相对上面那两档）：
##   我方 1/4、敌方 1/4 —— 两边**同价**。
##   用户原话（第二轮）：「我方也砍半的话那就太低了，所以降低敌方的打捞价格」
##   ⇒ 我方维持 1/4 不动，把敌方从 1/2 也压到 1/4。
##   ⚠️ 谈不上「敌方更贵」的差：折扣期就是一律 1/4 船价，
##      3 费及以下的地板价统一是 1 ◆。
##   ⚠️ 取整口径也换了：事件期间用**向下取整**（用户原话「就低不就高」），
##      非事件期间仍沿用原来的 `ceil` —— ⛔ 别把两套口径合并成一套。
const SALVAGE_DISCOUNT_RATIO_SELF := 0.25
const SALVAGE_DISCOUNT_RATIO_ENEMY := 0.25

## ★ 一次最多能勾几艘（2026-10-04 用户定案）。
## 为什么要有上限：下一节点的商店只有 `SHOP_SLOTS`(5) 个货位，
## 打捞品要**顶掉**货位 —— 勾 6 艘就必然有 1 艘无处可放。
## 勾到第 6 艘时**直接拒绝并提示**（不静默截断，否则玩家会以为自己勾上了）。
const SALVAGE_MAX_PICK := 5

## 星级上限。3 张 1★ → 2★，3 张 2★ → 3★（云顶同口径）—— 所以 9 张同名 1★ 才是满星。
const MAX_STAR := 3

## ── 残骸的星级：**只能用来自店面的证据，不能用当前场上读数** ────────
##
## ⚠️ 2026-10-01 修的一个真 bug（会「看着对、其实错」）：
##    原来 `_set_wreck_from()` 拿的是 `EveShip.star`，而**敌方舰队是把星级
##    烘进数值里的**（`apply_enemy_scaling()` 只放大 atk/shield/armor，
##    `ship.star` 从不被写）⇒ 这个字段**恒为 1**。
##    后果：节点 10 的 1★ 敌舰（power_scale ≈ 1.8）被打捞上来，
##    到玩家手里变成 1★ 的裸船，比玩家自己商店买的还弱 —— 打捞直接失去意义。
##
## ⚠️ 而且「从场上读数」这条路是走不通的：结算弹窗延迟 1 秒弹出，
##    `resolve_battle()` 那一刻舰队还活着、字段还准；但在那之后
##    主控会重建舰队，等到 HUD 真要画打捞框时，敌船对象已经**不在场上**了。
##    ⇒ 残骸必须在**结算那一刻**把证据抄下来，事后再读一定是陈的。
##
## 本函数 = 结算期「反解」与展示期「复算」**共用的唯一一份纯函数**。
## 返回 {star, atk_base, def_base}：
##   §1 shot / scale ≤ 1 → 由 `shot` 反解出星级（对**我方**舰船有真实含义）
##      门槛：`shot ≥ atk_base × 1.8^(k−1) × (1 − TOL)`
##      ⚠️ 基准就是 `atk_base` 本身，**不乘任何 0.5** ——
##         `warhead_scale(m)` 做的是 `weapon_damage *= m`、`attack *= m`，
##         1★ 的读数就等于权威表原值。凭空加一个 0.5 会把 1★ 读成 2★
##         （实测：裸 13 会被判成 2★ 并显示 23）。
##   §2 scale > 1        → **击杀的是被放大过的敌掠袭舰队**，不是原版敌舰。
##      此时星级反解无意义（逐节点星级的机制没实装，星永远出 1），
##      一律判 1★；补偿改走**费用**：残骸自带打折、且是玩家当前商店档位
##      摇不出来的高费船。⛔ 别在 §2 里"顺手按 scale 往上猜"——
##      猜出来的数字没有任何依据。
##   ★ 判据只用整数，不含浮点 epsilon ⇒ 与序列化/调用点无关（幂等）。
static func derive_wreck_tier(shot: float, scale: float,
		atk_base: float, def_base: float) -> Dictionary:
	const TOL := 0.12
	var star := 1
	if scale <= 1.0 + TOL:
		for k in range(MAX_STAR, 1, -1):
			if shot >= atk_base * pow(STAR_MULT, float(k - 1)) * (1.0 - TOL):
				star = k
				break
	return {"star": star, "atk_base": atk_base, "def_base": def_base}


## 把证据还原成「星级对应的裸数值」。
##
## ⚠️ 只在「未放大」（scale ≤ 1）时成立 —— 放大的那支算出的裸值只是参考，
##    HUD 一个数字都不许按它显示（见 `WreckDisplay`）。
static func tier_base_from(star: int, atk_base: float, def_base: float) -> Dictionary:
	var d := pow(STAR_MULT, float(maxi(1, star) - 1))
	return {"atk": atk_base * d, "def": def_base * d}

# ══════════════════════════════════════════════════════════════════
#  状态
# ══════════════════════════════════════════════════════════════════

var phase: int = Phase.PREP
## 上一场的胜负（`advance()` 判「第 15 节点要不要重打」用）
var last_won: bool = true
## BOSS 重打了多少次（只为日志与验收，不参与数值）
var boss_attempts: int = 0

## 难度档（唯一真源 = EveCampaignTiers.DIFFICULTIES）。
## ⚠️ 它影响收入 / 利息 / 战败代价 / 敌方强度，**不影响节点顺序**。
var difficulty_id: String = "simple"

## ★ 2026-11-07（玩家反馈）：「正式进入游戏时自己选择是否进入新手模式」
##
## 新手模式 = **取消一切倒计时**：
##   准备阶段不限时（不自动开战、不会因"没布阵"判负）；
##   战斗阶段不限时（不判超时，只有一方被打光才结束）；
##   结算页本来就要玩家点「继续」，天然不限时。
##
## [WHY] 做成 run 的字段而不是场景的开关：它必须**跟存档走** ——
##       「继续上一局」读回来还是新手模式，否则玩家下次进来突然开始读秒。
## [NOTE] `start_run()` 会把它打回 false（新的一局默认标准节奏），
##       入口弹框选「开启」之后再置真；局内 `restart_run()` 会显式把它带回来。
var novice_mode: bool = false

var coin: int = START_GOLD
var level: int = 1
var xp: int = 0
var beacon: int = START_BEACON
var node_index: int = 1
var overtier: int = 0                      ## 满级后的超频档（0 = 未超频）
var win_streak: int = 0
var lose_streak: int = 0
var shop_locked: bool = false
var ending: int = Ending.NONE

## 备战席（≤ BENCH_SLOTS）。元素 = {"ship_key": StringName, "star": int}
var bench: Array[Dictionary] = []
## 上场（≤ field_limit()）。元素 = {"ship_key": StringName, "star": int, "cell": Vector2i}
##
## ⚠️ `cell` 是【棋盘格】（阶段 B 起）：(-1,-1) = 还没被玩家摆过，位置由 arena 的
##    默认阵型给。存格号而不是存世界坐标，是因为「棋盘是布阵台」——
##    接敌线（compute_deploy_z）每个节点都会变，存绝对坐标会让摆好的阵型
##    在下一节点悄悄漂走；存格号则永远钉在棋盘上。
##    真正的世界坐标在每个准备阶段由 EveBattleArena 现算（落格 → 世界坐标）。
## ⚠️ 进场的**唯一入口**是 `deploy_from_bench()`（玩家从备战席拖到棋盘）——
##    2026-09-20 起不再有任何「自动上场」。理由见 buy() 与本文件
##    「已删除：auto_deploy()」那一节。
var field: Array[Dictionary] = []

## ★ 2026-10-31（用户定案）：背包装备（≤ `EQUIP_BAG_SIZE`）。
##
## 元素结构（**占位口径**，等物品表定了按表填）：
##   {"id": StringName, "name": String, "tier": int, "icon": StringName, "color": Color}
##
## ⚠️ 装备挂在**背包**里，不是挂在船上 —— 玩家自己把背包里的拖到船上。
##    船身上的槽位是 `EveShip.equips`（每艘 length = `equip_slots_for_cost(cost)`）。
##    两条是**独立**的容器：背包满了掉落会被拒（`grant_equip` 返回 false），
##    但不会顶掉已装在船上的东西。
var bag: Array[Dictionary] = []
## 商店 5 个槽位。元素 = EveShipDatabase 的派生 Dictionary（已售出的槽位会被立刻重摇）
var offers: Array = []

## 已获取的事件增益（EveEventTable 的 id，按获取顺序）。
## ⚠️ 存 id 而不是存 Dictionary：效果一律**现查表**再落地，
##    这样改表里的数值只需改一处，存档里的旧 id 也不会带着过期的数值。
var event_picks: Array[StringName] = []

## ★ 待应用的事件效果（2026-10-10，审查 R05）。
##
## 事件「黑市情报」承诺的「下一节点保底 1 艘 cost ≥ 3」**不能当场刷新** ——
## 事件选完同一帧就会 `advance()` 推进节点，货架会被普通 `roll_shop()` 覆盖
## （见 `free_advanced_roll()` 顶注）。⇒ 登记成计数，等货架定型后统一落地。
var _pending_advanced_roll: int = 0

## ★ 2026-10-30：事件「黑市情报」追加的「本批船半价」。
## 与 `_pending_advanced_roll` 同一次刷新、同一个落地时机（货架定型之后）——
## 半价的是**那一批货**，不是「之后所有货」。
var _pending_half_price: bool = false

## ★ 2026-10-28 事件「打捞折扣」的生效区间（**节点号闭区间**，0 = 未生效）。
##
## 为什么不存「还剩几回合」：剩余数要每回合减一，得在 `advance()` 里扎一个钩子，
## 一旦有别的路径改了节点（重开、读档、跳关）计数就会跟实际节点错位。
## 存绝对节点区间则**永远对得上** —— 判定只看 `node_index`（见 `salvage_discount_active()`）。
var salvage_discount_from: int = 0
var salvage_discount_to: int = 0

## ★ 2026-10-28：「打捞折扣」的计时基准（**联机专用覆盖值**，0 = 跟随 `node_index`）。
##
## 为什么要这个：单机是「1 节点 = 1 回合」，`node_index` 天然就是回合号；
## 联机（`EveMatchState`）是另一套 17 回合表，`node_index` 在联机里不推进
## （联机不按节点跑，敌方编组来自 `PVE_SOURCE_NODE` 映射）⇒ 用 node_index 计时
## 会让折扣永远不生效、也永远不过期。
## ⇒ 联机由战斗场景每回合写一次真实回合号（`set_event_clock(versus.global_round())`），
##    单机不写、保持 0，行为与改动前**一字不差**。
var _event_clock_override: int = 0


## 当前回合号（折扣计时的唯一口径）。单机 = node_index；联机 = 战斗场景写入的回合号。
func event_clock() -> int:
	return _event_clock_override if _event_clock_override > 0 else node_index


## 联机写回合号（传 0 取消覆盖，回到跟随 node_index）。
func set_event_clock(v: int) -> void:
	_event_clock_override = maxi(0, v)

## ★★ 2026-10-04 打捞改为**多选列表**（用户定案）。
##
## 原来这里是**单个** `wreck: Dictionary`（且 `_set_wreck_from()` 只挑「费用最高」
## 的一艘，其余全丢）。现在：本回合敌我双方**所有**被击毁的舰船都进这个列表，
## 玩家在**结算页**逐艘勾选，最多 5 艘。
## 元素结构 = EveShipDatabase 派生 Dictionary + 以下附加键：
##   "team"     → 0=我方 / 1=敌方（**定价用**，决定 ×0.5 还是 ×1）
##   "wreck_id" → 本列表内的稳定下标（UI 勾选与下单都靠它，跨帧不变）
##   "from_node"→ 下单时才写，标记「这是修复品」
##
## ⚠️ 生命周期仍然是**恰好一个节点**：新一次结算时整体 `clear()` 重填。
var wrecks: Array[Dictionary] = []

## 残骸的世代号。每产生**一批**新残骸 +1，**过期/下单都不动它**。
##
## ⚠️ 为什么不把世代号塞进元素里就完事：
##    `wrecks[i] = best.duplicate()` 换的是 Dictionary **引用**，
##    UI 侧拿它比对时看不出差别 —— UI 需要一个
##    「单调递增、永不复用」的号才能可靠地判「这是不是新的一批」。
var wreck_evt: int = 0

## 残骸数值展示用的持久记录。**与 `wrecks` 一一对应的并行数组**。
##
## ⚠️ 为什么必须单独存：`wrecks[i]` 是 `EveShipDatabase` 的派生 Dictionary，
##    它里面**没有** star 键的语义（那是权威表原值列，不是星级）；
##    而结算那 1 秒延迟里舰队会被重建 ⇒ 事后再去数舰船对象一定数不到。
##    所以证据（三个整数 + 阵营）在结算那一刻抄下来，随残骸一起过期。
##    第 i 项的结构 = {"star":…, "atk_base":…, "def_base":…, "m":…, "team":…}
var wrecks_display: Array[Dictionary] = []

## 已下单、下个节点到账的修复队列。元素同 `wrecks` 的一项。
## 用 Array 而不是单个：一局里可能连续两个节点都打捞，前一件还没买走。
var repair_queue: Array[Dictionary] = []

## 被「修复品」占住的商店槽位号。刷新（含付费刷新）**不许**重摇这些槽位，
## 否则玩家花钱下的单会被一次刷新刷掉 —— 那就是「说了延迟到账却没到账」。
var salvage_slots: Array[int] = []

var rng := RandomNumberGenerator.new()

## ★ 2026-10-10（审查 #4）：本局的种子（0 = 随机局）。
##   战斗模拟器的种子由它派生（见 `battle_seed()`）⇒ 固定种子的一局**全链路可复现**
##   （商店 / 事件 / 战斗命中判定都不再受全局随机影响）。
var run_seed: int = 0

## ── ★ 2026-10-27：程序化敌方编组的种子基准 ────────────────────────
##
## 难度 2/3/4 档的编组由 `EveEnemyPlans` 按「节点配方 + 本基准 + 节点号」
## 现摇（见 `enemy_roster_seed()`）。要求有两条，缺一不可：
##   ① **本局内恒定** —— 重载存档 / 重进同一关必须摇出同一批船
##      （否则玩家能靠反复重载"刷"到更弱的敌人）；
##   ② **跨局不同** —— 否则每一局的敌人都一模一样。
##
## ⛔ 为什么不能直接用 `run_seed`：`start_run(0)` 是「随机局」，此时
##    `run_seed` 恒为 0 ⇒ 所有随机局的敌人会完全相同（违反 ②）。
##    所以开局时把基准**定死**在这里：固定种子局就等于 `run_seed`，
##    随机局则从 `rng` 抽一个，再随存档持久化（见 `to_dict`/`from_dict`）。
var _comp_seed_base: int = 0

## 本局已摇出的编组：comp_id → true（只用于避免重复登记，成员在
## `EveEnemyComps` 的运行时表里）。
var _gen_comps: Dictionary = {}

var _pools: Dictionary = {}                ## cost → Array[Dictionary]（52 艘派生一次就够）


# ══════════════════════════════════════════════════════════════════
#  开局
# ══════════════════════════════════════════════════════════════════

## 本局的难度参数（唯一真源在 EveCampaignTiers，这里只取用）。
func difficulty_row() -> Dictionary:
	return EveCampaignTiers.difficulty(difficulty_id)


## 切难度。⛔ 必须在 `start_run()` **之前**调用 —— 开局星币按档位给。
func set_difficulty(id: String) -> void:
	difficulty_id = String(EveCampaignTiers.difficulty(id).get("id", "simple"))
	changed.emit()


## 多人对战：**敌方侧**固定按这一档算（强度系数 / 吃羁绊 / 按阵型）。
##
## ⚠️ 为什么不直接 `set_difficulty("inferno")`：那一改会把**玩家自己**的
##    收入 / 利息 / 败亡代价一起换成炼狱口径。多人对局的经济该按玩家在主菜单
##    选的档走，只有「电脑舰队」这一侧必须统一成炼狱
##    （`EveMatchState.PVE_DIFFICULTY`，用户 2026-10-28 定案：
##      多人 PvE 回合一律吃羁绊 + 1.40 系数）。
##    所以单独开一个**只影响敌方**的覆盖位。空串 = 不覆盖 ⇒ 单机一个字节不变。
var enemy_tier_override := ""


## 敌方侧要用的难度行 —— `enemy_scale()` / 敌方羁绊 / 敌方阵型都读它。
## ⚠️ 单机（覆盖为空）时逐字段等价于 `difficulty_row()`。
func enemy_tier_row() -> Dictionary:
	if enemy_tier_override == "":
		return difficulty_row()
	return EveCampaignTiers.difficulty(enemy_tier_override)


# ══════════════════════════════════════════════════════════════════
#  炼狱的「钥匙」机制
# ══════════════════════════════════════════════════════════════════
## 难度档声明的机制钥匙（空串 = 本档没有机制壁垒）
func key_mechanic() -> String:
	return String(difficulty_row().get("key_mechanic", ""))


## ★★ 2026-11-01（用户定案）：**四族靠齐** —— 壁垒不再按武器类型分档。
##
## 上一版（10-24 定案）的判据是「Σ 每艘船 × 该武器的破甲权重」：
##   导弹 1.0 / 射弹炮 0.9 / 混合炮 0.5（盖伦特 4 档转 1.0）/ 激光 0.25（凑 6 艘转 1.0）。
##
## 病根（用户原话：「四族等靠齐，现在这样不是搞歧视？玩家该闹了」）：
##   族与武器在本作里是 **100% 一一对应** 的（每族 13 艘：艾玛=激光、加达里=导弹、
##   盖伦特=混合炮、米玛塔尔=射弹炮）⇒ 按武器分权重 = **按族分权重**。
##   实测 8 艘满编：
##     8 加达里 8.00 ✔ ｜ 8 米玛塔尔 7.20 ✔ ｜ 8 盖伦特 8.00 ✔ ｜ 8 艾玛 8.00 ✔
##     4 加达里+4 射弹 7.60 ✔ ｜ 4 盖伦特+4 导弹 8.00 ✔
##     4 艾玛+4 导弹 **5.00 ✘** ｜ 4 混合+4 激光 **5.00 ✘**    ← 只有艾玛崩
##   ⇒ 同样八个上场位，玩艾玛的必须凑满 6 艘激光，玩加达里的随手混编就过。
##
## 而且这是**同一个克制收两次税**：抗性层已经按伤害类型分过档
##   （甲抗 EM 60% / 热能 35% / 动能 25% / 爆炸 10%），壁垒层又按同一维度罚一遍。
##   职责本该分开 —— 抗性管「这一发打进去还剩多少」，壁垒管「你有没有专精」。
##
## 新口径（四族同构，只看船数，不看武器）：
##     破甲强度 = 最大同族簇的艘数 + `BREAK_OFF_CLUSTER` × 其余艘数
##     族羁绊 4 档再 +1（读 `EFFECTS` 的 `break_bonus`，四族各一条，见该表）
##   8 艘同族 = 8.0 ｜ 7+1 = 7.5 ｜ 6+2 = 7.0 ｜ 4+4 = 6.0 ｜ 3+3+2 = 5.5 ｜ 2+2+2+2 = 5.0
##   ⛔ 「专精」这个要求没变软：门槛仍是 6.0，4+4 混编刚好压线，
##      四族大杂烩（2+2+2+2）依旧过不去 —— 变的是**四族站在同一起跑线上**。
const ARMOR_BREAK_NEED := 6.0
## 不属于最大簇的船，破甲只算半艘。
## ⚠️ 0.5 是反推出来的、不是拍的：4+4 混编 = 4 + 0.5×4 = **6.0**，刚好压线。
##    调它等于调「混编能有多滥」，改之前先跑 `tools/sim_winrate.gd` 的四族对照。
const BREAK_OFF_CLUSTER := 0.5


## 当前上阵的**破甲强度**（单位：等效专职破甲船）。0 = 完全没有破甲能力。
##
## 算法见上方 `ARMOR_BREAK_NEED` 的顶注：**最大同族簇 + 半艘 × 其余**，四族同构。
## ⚠️ 分母口径是"上阵"（`field_entries()`），不是备战席 —— 钥匙只认要上场的东西。
## ⚠️ 按**族**统计而不是按武器：两者在本作里一一对应（13 艘/族），
##    但族是"玩家看得见、能报出来的"单位，UI 也按族显示。⛔ 别改回按武器。
func armor_break_power() -> float:
	var total := 0
	var per_faction: Dictionary = {}
	for e in field_entries():
		var d := EveShipDatabase.by_id(String(e.get("ship_key", "")))
		var fac := int(d.get("faction", -1))
		if fac < 0:
			continue
		total += 1
		per_faction[fac] = int(per_faction.get(fac, 0)) + 1
	if total == 0:
		return 0.0
	var best := 0
	for f in per_faction:
		best = maxi(best, int(per_faction[f]))
	# 最大簇整艘计，其余船半艘 —— 见 `BREAK_OFF_CLUSTER` 的取值理由。
	var power := float(best) + BREAK_OFF_CLUSTER * float(total - best)
	power += _faction_break_bonus()
	return power


## 族羁绊 4 档给的破甲加成（四族同构，取 `EFFECTS[...][4].apply.break_bonus`）。
##
## ⚠️ 用 `maxf` 而不是累加：两族都到 4 档时不该叠成 +2 —— 4 档是「这一族专精了」，
##    不是「多专精一族再多一份」。与 `tier_of` 的「替换不叠加」口径一致。
func _faction_break_bonus() -> float:
	var out := 0.0
	for a in active_synergies():
		if StringName(a["group"]) != &"faction":
			continue
		out = maxf(out, float(a.get("apply", {}).get("break_bonus", 0.0)))
	return out


## 玩家阵容是否凑出了钥匙。
##
## ⚠️ 这仍然**只是阵容条件**，不是抽卡条件：玩家可以靠留船 / 换船去凑，
##    而且四条路（四族）现在是同一把尺子量。
func key_mechanic_satisfied() -> bool:
	match key_mechanic():
		"armor_pierce":
			return armor_break_power() >= ARMOR_BREAK_NEED
		_:
			return true


## 壁垒未破时的**最低**受伤倍率（斜坡下限）。
## ⚠️ 0.15 而不是 0.1：原来那个 0.1 是"开关"的下半段，现在它是曲线的最低点，
##    留 1.5 成是因为 0 艘同族 = 你根本没在打这个机制，而不是"差一点"。
##    真实对局里破甲强度很少低于 4（8 个上场位），所以玩家实际感受到的
##    最低值大约是 `barrier_mult_for(4.0)` ≈ 0.62，不是这个 0.15。
const BARRIER_FLOOR := 0.15
## 斜坡的弯曲指数（>1 = 低破甲段爬得慢、越接近门槛涨得越快）。
## 1.6 是拿下面这张表反推的，改之前先看表：
##   破甲 0 → 0.15 ｜ 2 → 0.30 ｜ 4 → 0.62 ｜ 5 → 0.81 ｜ 6 → 1.00
## 想要"差一艘就很疼"就把它调大（曲线更凸），想温柔就调小。
const BARRIER_CURVE := 1.6


## 破甲强度 → 敌方全体受伤倍率（**连续**，不再是 0.1/1.0 的开关）。
##
## ★★ 2026-11-01（用户定案，B 项）：用户原话「我看着这个词有点恶心」。
##   开关的毛病不是"惩罚重"，是**没有中间态**：差 0.5 和差 5.0 结果一模一样，
##   玩家在"差一点"那一格受的挫最重，而这一格恰好是唯一没有反馈的。
##   改成斜坡之后，每多一艘同族船都能立刻看见伤害数字变大。
##
## ⚠️ 只在 `armor_pierce` 这个 key_mechanic 下有意义 —— 别的机制有自己的判据，
##    别把这条曲线当通用公式套上去。
func barrier_mult_for(power: float) -> float:
	if power >= ARMOR_BREAK_NEED:
		return 1.0
	var t := clampf(power / ARMOR_BREAK_NEED, 0.0, 1.0)
	return BARRIER_FLOOR + (1.0 - BARRIER_FLOOR) * pow(t, BARRIER_CURVE)


## 本节点敌方全体受到的伤害倍率。
##   1.0 = 无壁垒 / 已穿透；<1.0 = 壁垒部分穿透（见 `barrier_mult_for`）
## 只在 BOSS 节点 + 该档声明了 `armor_pierce` 时生效；其余恒 1.0。
func boss_barrier_mult() -> float:
	if node_type() != &"boss":
		return 1.0
	if key_mechanic() != "armor_pierce":
		return 1.0
	return barrier_mult_for(armor_break_power())


## 开一局新的。p_seed = 0 时用系统随机；>0 时固定种子（回归用）。
func start_run(p_seed: int = 0) -> void:
	if p_seed == 0:
		rng.randomize()
	else:
		rng.seed = p_seed
	run_seed = p_seed
	# ★ 程序化编组的基准：固定种子局用它；随机局抽一个再随存档带走。
	# ⚠️ 必须在 `rng.seed/randomize()` 之后取 —— 随机局的 `rng` 此刻才可用。
	_comp_seed_base = p_seed if p_seed != 0 else rng.randi()
	_gen_comps.clear()
	EveEnemyComps.clear_runtime()

	coin = int(difficulty_row().get("start_gold", START_GOLD))
	level = 1
	xp = 0
	beacon = START_BEACON
	node_index = 1
	overtier = 0
	win_streak = 0
	lose_streak = 0
	shop_locked = false
	ending = Ending.NONE
	# ★ 2026-11-07：新的一局默认**标准节奏**（读秒全开）。
	#   新手模式的入口弹框在 `start_run()` **之后**才会置真；局内重开由
	#   `restart_run()` 显式把上一局的选择带回来（见那里的注释）。
	novice_mode = false
	# ★★ 2026-10-10（审查 R01）：**局内状态必须整体归零**，别逐个补。
	#    `restart_run()` 复用同一个 run 对象 ⇒ 这里漏一个字段，它就会带着
	#    上一局的值进新局。已踩过的两个：
	#      · `event_picks` 未清 ⇒ 上一局选过的事件仍算"已获取"，事件禁重复选，
	#        新局到事件节点可能**一个选项都没有**（无法继续）。
	#      · `last_won` / `boss_attempts` 未清 ⇒ 第 15 节点的重打判定被污染。
	#    ⇒ 新增局内字段时，**同时**加到这里（把这里当成"新局的完整初始态"）。
	event_picks.clear()
	last_won = true
	boss_attempts = 0
	_pending_advanced_roll = 0
	_pending_half_price = false
	salvage_discount_from = 0
	salvage_discount_to = 0
	bench.clear()
	field.clear()
	offers.clear()
	wrecks.clear()
	wrecks_display.clear()
	wreck_evt = 0
	repair_queue.clear()
	salvage_slots.clear()
	_build_pools()

	phase = Phase.PREP
	roll_shop()
	log_event.emit("一局开始（%s）：信标 %d · 星币 %d · 15 个节点"
			% [String(difficulty_row().get("name", "简单")), beacon, coin], &"system")
	log_event.emit("节点 1／%d · %s" % [EveNodeTable.TOTAL, entry_line()], &"hint")
	changed.emit()
	phase_changed.emit(phase)


func _build_pools() -> void:
	if not _pools.is_empty():
		return
	for c in range(1, 6):
		_pools[c] = EveShipDatabase.by_cost(c)


## ★ 2026-10-10（审查 #4）：本节点战斗的随机种子。
##
## 由「局种子 + 节点号」**纯函数派生** —— ⚠️ 不许去动 `rng`（rng 的消费顺序
## 决定了商店/事件序列，顺手摇一下就会把整条链子错位）。
## 返回 0 = 本局是随机局 ⇒ 主控应改调 `sim.randomize_seed()`。
func battle_seed() -> int:
	if run_seed == 0:
		return 0
	return absi(run_seed * 1000003 + node_index * 7919) + 1


# ══════════════════════════════════════════════════════════════════
#  对局存档（审查 2#2）
# ══════════════════════════════════════════════════════════════════
#
#  一局 15 个节点、动辄半小时，而本对象**只活在内存里** ⇒ 关掉游戏就没了。
#  这里给它一对 `to_dict()` / `from_dict()`，由 `eve_battle_scene` 在
#  每次进入新准备阶段前存一次（磁盘交互全在 `EveRunStore`，本文件不碰 IO）。
#
#  ⚠️ 两条口径：
#    ① 序列化**只做类型搬运**，⛔ 不重算任何数值（不重摇商店、不重算羁绊、
#       不重推残骸星级）—— 存的必须和存之前一模一样；
#    ② `StringName` 一律降级成 `String`（ConfigFile 存不住 StringName，读回来
#       会退化成 String ⇒ typed Array 赋值会炸）。好在全工程读这两类键都走了
#       `String(...)` / 用 String 字面量（`buffs` 的 `armor_pct` 等），所以
#       降级后语义完全一致。

## 本局**全部**存活状态 → 可 `ConfigFile` 化的 Dictionary。
func to_dict() -> Dictionary:
	return {
		"run_seed": run_seed,
		"comp_seed": _comp_seed_base,
		"difficulty": difficulty_id,
		"novice_mode": novice_mode,
		"phase": phase,
		"ending": ending,
		"coin": coin, "level": level, "xp": xp, "beacon": beacon,
		"node_index": node_index, "overtier": overtier,
		"win_streak": win_streak, "lose_streak": lose_streak,
		"shop_locked": shop_locked,
		"last_won": last_won, "boss_attempts": boss_attempts,
		"pending_advanced_roll": _pending_advanced_roll,
		"pending_half_price": _pending_half_price,
		"salvage_discount_from": salvage_discount_from,
		"salvage_discount_to": salvage_discount_to,
		"event_clock_override": _event_clock_override,
		"event_picks": _plain(event_picks),
		"bench": _plain(bench),
		"field": _plain(field),
		"offers": _plain(offers),
		"repair_queue": _plain(repair_queue),
		"salvage_slots": _plain(salvage_slots),
		"wrecks": _plain(wrecks),
		"wrecks_display": _plain(wrecks_display),
		"wreck_evt": wreck_evt,
	}


## 还原一局。返回 false = 数据不可用（调用方应改走 `start_run()`）。
## ⚠️ 只赋值 + `_build_pools()`（派生缓存），⛔ 不发 log、不 roll 商店 ——
##    否则"继续上一局"会平白多出几条日志、甚至换掉刚存下来的货架。
func from_dict(d: Dictionary) -> bool:
	if d.is_empty():
		return false
	run_seed = int(d.get("run_seed", 0))
	# ★ 程序化编组基准也要还原 —— 不还原的话「继续上一局」的敌人会重摇，
	#   而玩家在上一次进关时已经见过那批船了（HUD/存档语义都会错位）。
	# ⚠️ 字段缺省回退到 `run_seed`：老存档没有这个键，用 run_seed 重算即可
	#   （固定种子局本来就等于 run_seed；随机局的老存档会退化成"当局固定"，
	#    可以接受，比直接崩好）。
	_comp_seed_base = int(d.get("comp_seed", run_seed))
	_gen_comps.clear()
	EveEnemyComps.clear_runtime()
	difficulty_id = String(d.get("difficulty", "simple"))
	# 老存档没有这个键 ⇒ 默认标准节奏（与读档前的行为一字不差）
	novice_mode = bool(d.get("novice_mode", false))
	phase = int(d.get("phase", Phase.PREP))
	ending = int(d.get("ending", Ending.NONE))
	coin = int(d.get("coin", START_GOLD))
	level = clampi(int(d.get("level", 1)), 1, MAX_LEVEL)
	xp = maxi(0, int(d.get("xp", 0)))
	beacon = maxi(0, int(d.get("beacon", START_BEACON)))
	node_index = clampi(int(d.get("node_index", 1)), 1, EveNodeTable.TOTAL)
	overtier = clampi(int(d.get("overtier", 0)), 0, MAX_TIER - MAX_LEVEL)
	win_streak = maxi(0, int(d.get("win_streak", 0)))
	lose_streak = maxi(0, int(d.get("lose_streak", 0)))
	shop_locked = bool(d.get("shop_locked", false))
	last_won = bool(d.get("last_won", true))
	boss_attempts = maxi(0, int(d.get("boss_attempts", 0)))
	_pending_advanced_roll = maxi(0, int(d.get("pending_advanced_roll", 0)))
	_pending_half_price = bool(d.get("pending_half_price", false))
	salvage_discount_from = maxi(0, int(d.get("salvage_discount_from", 0)))
	salvage_discount_to = maxi(0, int(d.get("salvage_discount_to", 0)))
	_event_clock_override = maxi(0, int(d.get("event_clock_override", 0)))

	event_picks.clear()
	for id in _as_array(d.get("event_picks", [])):
		event_picks.append(StringName(id))

	bench = _entries_in(d.get("bench", []))
	field = _entries_in(d.get("field", []))
	offers = _as_array(d.get("offers", []))
	repair_queue = _entries_in(d.get("repair_queue", []))
	salvage_slots.clear()
	for i in _as_array(d.get("salvage_slots", [])):
		salvage_slots.append(int(i))
	wrecks = _entries_in(d.get("wrecks", []))
	wrecks_display = _entries_in(d.get("wrecks_display", []))
	wreck_evt = maxi(0, int(d.get("wreck_evt", 0)))

	_build_pools()
	changed.emit()
	return true


## 递归降级：`StringName` → `String`；其余原样（含 `Vector2i`，ConfigFile 支持）。
static func _plain(v: Variant) -> Variant:
	if v is StringName:
		return String(v)
	if v is Array:
		var out: Array = []
		for x in v:
			out.append(_plain(x))
		return out
	if v is Dictionary:
		var o: Dictionary = {}
		for k in (v as Dictionary).keys():
			o[String(k)] = _plain((v as Dictionary)[k])
		return o
	return v


static func _as_array(v: Variant) -> Array:
	return v if v is Array else []


static func _entries_in(v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in _as_array(v):
		if e is Dictionary:
			out.append((e as Dictionary).duplicate(true))
	return out


# ══════════════════════════════════════════════════════════════════
#  商店
# ══════════════════════════════════════════════════════════════════

## 当前商店档位（1~8）。等级 1~6；满级后每超频一次 +1 档，封顶 8。
func shop_tier() -> int:
	return clampi(level + overtier, 1, MAX_TIER)


## 重摇 5 个槽位 —— 但**跳过被修复品占住的槽位**（`salvage_slots`）。
##
## ⚠️ 这条是「延迟到账」能不能成立的关键。玩家已经为打捞付过钱了，
##    如果一次刷新就把它刷掉，玩家看到的是「花了钱、什么都没拿到」。
##    `refresh()`（付费刷新）走的就是这个函数，所以锁定必须做在这里，
##    光在 `advance()` 里塞进去是不够的。
func roll_shop() -> void:
	var locked: Dictionary = {}
	for i in salvage_slots:
		if i >= 0 and i < offers.size():
			locked[i] = offers[i]
	offers.clear()
	for i in SHOP_SLOTS:
		offers.append(locked[i] if locked.has(i) else _roll_one())
	offers_changed.emit()
	changed.emit()


## 单槽抽取 —— **全工程唯一的抽取入口**
##
## 两步：① 按当前档位的概率表摇出费用档；② 在该费用档里等概率取一艘船。
func _roll_one() -> Dictionary:
	_build_pools()
	# ★★ 2026-10-31（用户定案）：超频到顶（第二次超频）后，货架切成「精英货」。
	#   理由（用户原话）：「如果升6级第二次是超频，那品质就得升级一下，
	#   商店页刷新将将只有巡洋以上的二星舰船，全部巡洋以上吨位的舰船的二星，
	#   然后价格全部按一星舰船计价，不然超频没有意义」。
	#   ⚠️ **不分难度**：这是超频机制本身的价值，四档都要给。
	if _shop_elite():
		return _roll_elite()
	var odds: Array = SHOP_ODDS[shop_tier()]
	var total := 0
	for v in odds:
		total += int(v)
	var r := rng.randi_range(1, total)
	var cost := 1
	var acc := 0
	for i in odds.size():
		acc += int(odds[i])
		if r <= acc:
			cost = i + 1
			break
	var pool: Array = _pools.get(cost, [])
	if pool.is_empty():
		pool = _pools.get(1, [])
	if pool.is_empty():
		return {}
	# ★ 2026-10-29：走 `pick_from_pool`（加强型战列权重 0.35，其余等价）。
	return EveShipDatabase.pick_from_pool(pool, rng)


## 精英货架是否生效 —— 条件：满级 **且** 超频到顶（两次超频都点完）。
##
## ⚠️ 用 `overtier >= MAX_TIER - MAX_LEVEL`（= 2）而不是 `== 2`：
##    以后若把 MAX_TIER 往上抬，这里会自动跟着走，不会「超频了但货架没变」。
## ⚠️ 用 `shop_tier() >= MAX_TIER` 表达同一件事会更好读，但 `shop_tier()` 会被
##    `clampi` 压到 8 —— level 5 + overtier 2 也是 8。**必须两个条件同时成立**，
##    ⛔ 别偷懒只判 shop_tier()。
func _shop_elite() -> bool:
	return level >= MAX_LEVEL and overtier >= MAX_TIER - MAX_LEVEL


## 精英货：只在**巡洋以上**（cost 3/4/5）里摇，固定 ★2，**价格按一星计**。
##
##   · 星级：`d["star"] = 2` —— 战斗侧 `×1.8^(star-1)` 会把它算成 1.8 倍属性。
##   · 价格：**直接沿用船表的 `cost`（一星价），⛔ 不乘 3^(star-1)**。
##     这就是用户要的「按一星舰船计价」。
##     ⚠️ 因此这类船的**卖价必须按实付返还**，否则「买 3 卖 9」能无限刷钱 ——
##        见 `sell_value()` 里 `paid` 字段那一整套说明。
func _roll_elite() -> Dictionary:
	# 权重沿用当前档位（8 档 = [15,22,28,20,15] ⇒ 巡洋 28 / 战巡 20 / 战列 15）。
	# 不另造一张表：玩家在超频前后看到的"贵船占比"变化因此是可解释的。
	var odds: Array = SHOP_ODDS[shop_tier()]
	var buckets: Array = []
	var total := 0
	for c in range(3, 6):
		var idx := c - 1
		var w := int(odds[idx]) if idx < odds.size() else 0
		if w <= 0:
			continue
		if (_pools.get(c, []) as Array).is_empty():
			continue
		buckets.append({"cost": c, "w": w})
		total += w
	if total <= 0:
		# 池子异常（理论上不会）：退回普通抽取，⛔ 不返回空 —— 那会让货架整排空卡。
		return EveShipDatabase.pick_from_pool(_pools.get(3, []), rng)
	var r := rng.randi_range(1, total)
	var cost := 3
	var acc := 0
	for b in buckets:
		acc += int(b["w"])
		if r <= acc:
			cost = int(b["cost"])
			break
	var row := EveShipDatabase.pick_from_pool(_pools.get(cost, []), rng)
	if row.is_empty():
		return {}
	# ⚠️ `pick_from_pool` 返回的是**池里的那一份**（引用，不是拷贝）。
	#    就地改 `star` 会污染 `_pools` ⇒ 之后所有普通抽取都变成 2 星。
	#    必须 duplicate 一份再改。
	var d: Dictionary = (row as Dictionary).duplicate()
	d["star"] = 2
	return d


## 买第 index 个槽位。返回 {"ok": bool, "reason": String, "data": Dictionary}
##
## ══════════════════════════════════════════════════════════════════
##  ⚠️ 买入【只进备战席】，**绝不自动上场**（2026-09-20 用户定稿）
## ══════════════════════════════════════════════════════════════════
##  用户原话：「我是要先购买，购买后舰船就出现在备战席，不然备战席拿来干嘛？
##             然后备战席再拖到棋盘上，这样棋盘的显示与关闭才有操作上的意义。」
##
##  这是云顶之弈的口径。旧实现买完会顺手 `auto_deploy()`，理由是
##  「买了东西不出现在战场上会让人以为系统是假的」—— 那条理由是错的：
##  它顺手把两个系统都变成了死的：
##    ① **备战席**：永远 0~1 艘、永远不用看，8 个格子形同装饰；
##    ② **棋盘**：既然买完自己就上场，玩家一辈子不需要手动落格，
##       于是「拖动时才显形」这条视觉规则永远触发不了。
##  失去这两条之后，玩家看到的就是「花了钱 → 船自己会打」，
##  和阶段 A 那套假系统没有区别。棋盘与备战席是这个游戏【仅有的两个操作面】，
##  不能由引擎替玩家按掉。
func buy(index: int) -> Dictionary:
	if phase != Phase.PREP:
		return _deny("只有准备阶段能买船")
	if index < 0 or index >= offers.size():
		return _deny("槽位不存在")
	var raw = offers[index]
	if raw == null or not (raw is Dictionary) or (raw as Dictionary).is_empty():
		return _deny("槽位已空")
	var d: Dictionary = raw
	# ★★ 2026-10-06 用户口径：**打捞品取货不再收费**（治「双重扣费」）。
	#
	#   用户原话：「我第1回合打捞了伐木者级，花费了1星币，然后被扣费了，
	#   到第2回合，伐木者级到了商店，我点击之后，又扣了我1星币，
	#   这就导致双重扣费，这不对，所以改成第1回合的结算的时候扣费吧，
	#   到后面商店选择的时候不要扣费」
	#
	#   ⇒ 打捞费已在**结算页**付清（见 `salvage_order()` 的 `coin -= c`）；
	#     打捞品在商店里占一个货位、等玩家取走 —— 那一步是**取货，不是购买**。
	#     再收一次 `cost` 就是同一艘船收两遍钱。
	#
	#   ⚠️ 判据用 `from_node`：它是打捞品的**既有标记**（卡面的「修复」前缀
	#     也靠它判），语义一致 ——「是打捞来的」⇒「钱已经付过了」。
	#   ⚠️ 这也顺带治好了 2026-10-05 那个「打捞品买了没进备战席」：
	#     打捞已经花掉星币，到第 2 回合常常**买不起**第二次 ⇒ `buy()` 被拒
	#     （只有战斗日志一行提示）⇒ 玩家以为点了没反应。免费之后不会再被拒。
	var is_salvage := d.has("from_node")
	var cost := 0 if is_salvage else int(d.get("cost", 1))
	if coin < cost:
		return _deny("星币不足（需 %d，现有 %d）" % [cost, coin])
	if bench.size() >= BENCH_SLOTS:
		return _deny("备战席已满（%d / %d）—— 先拖一艘上场或卖掉" % [bench.size(), BENCH_SLOTS])

	coin -= cost
	# 星级取报价自带的（普通货架没有 star 键 → 默认 ★1；
	# 打捞来的修复品可能是敌方编组的星级，这里一并继承；
	# 超频满档的精英货是 ★2 但**只收一星价**）。
	var star_bought := int(d.get("star", 1))
	var entry := _make_entry(StringName(d.get("ship_key", &"")), star_bought)
	# ★ 2026-10-31：★2 却只付了 `cost`（一星价）⇒ 记下实付，
	#   卖价才不会按 3 倍返还（那 = 买 3 卖 9，无限刷钱）。详见 `sell_value()`。
	#   ⚠️ 打捞品（`is_salvage`）不记：它走的是"打捞费已付 + 取货免费"那条账，
	#      卖价仍沿用原公式，行为与改动前完全一致。
	if not is_salvage and star_bought > 1:
		entry["paid"] = cost
	bench.append(entry)
	# ★ 2026-10-01 用户定稿：买走的那格**留空**，不立刻补新船。
	#
	#   用户原话：「我买一艘那个地方就给我空着，别马上补充上来一艘，
	#             这样凑二星三星就太容易了。除非点击刷新商店，不然不补」
	#
	#   这正是云顶的口径：槽位空着，直到玩家**花钱刷新**或**进入下一回合**
	#   （`advance()` 里会 `roll_shop()` 整体重摇 —— 那是回合刷新，不是补货）。
	#   ⛔ 别把 `_roll_one()` 加回这里：一买就补等于"想买几艘有几艘"，
	#      凑二星三星的成本直接归零。
	offers[index] = {}
	# ⚠️ 若买走的正是「修复品」占的那个槽位，必须**解锁**它。
	#    不解锁的话，之后每次刷新都会把这个槽位当成锁定槽位保留下来 ——
	#    等于玩家买完之后，那个格子再也刷不动了（而且完全不报错）。
	salvage_slots.erase(index)
	# 日志必须写明「去备战席」，否则玩家会以为买失败了（东西不在战场上）。
	# ⚠️ 打捞品走另一句：它是**取货**（钱早在结算页付过），
	#    写成「−0 ◆」会让玩家以为自己捡了便宜，写「−N ◆」则是重复扣费。
	if is_salvage:
		log_event.emit("%s → 备战席（打捞费已在结算页付清，取货免费）"
				% String(d.get("name", "?")), &"buy")
	else:
		log_event.emit("%s −%d ◆ → 备战席（拖到棋盘上场）"
				% [String(d.get("name", "?")), cost], &"buy")

	# 三连合成照旧在买入那一刻结算（云顶同款）：同 id 同星满 3 张立刻升星。
	# 合成品留在它原来的位置 —— 备战席凑的留备战席、场上凑的留场上
	# （见 _merge_once 的「位置继承」）。
	var merged := _try_merge()
	if not merged and bench.size() >= BENCH_SLOTS:
		log_event.emit("备战席已满 %d／%d —— 拖一艘上场，或者拖到商店右下角出售"
				% [bench.size(), BENCH_SLOTS], &"hint")

	offers_changed.emit()
	changed.emit()
	return {"ok": true, "reason": "", "data": d}


## 造一条新的编制记录。cell = (-1,-1) 表示「位置交给默认阵型」
static func _make_entry(key: StringName, star: int) -> Dictionary:
	var out := {"ship_key": key, "star": star, "cell": Vector2i(-1, -1)}
	# 2026-10-27: traits must be stored in the roster entry too.
	# Before, only ship_key was kept, so EveTraitTable._traits_of() could
	# never read labels from roster entries (trait counting was blind).
	var d := EveShipDatabase.by_id(key)
	if not d.is_empty():
		out["traits"] = d.get("traits", [])
		out["name"] = d.get("name", "")
		out["cost"] = d.get("cost", 1)
		out["faction_cn"] = d.get("faction_cn", "")
		out["weapon_type"] = d.get("weapon_type", "")
		out["defense_type"] = d.get("defense_type", "")
		out["is_logistics"] = d.get("logistics", false)
	return out


## 付费刷新（2 星币）
func refresh() -> Dictionary:
	if phase != Phase.PREP:
		return _deny("只有准备阶段能刷新")
	if coin < REFRESH_COST:
		return _deny("星币不足（刷新需 %d）" % REFRESH_COST)
	coin -= REFRESH_COST
	roll_shop()
	log_event.emit("刷新加速列表 −%d ◆" % REFRESH_COST, &"buy")
	return {"ok": true, "reason": "", "data": {}}


## B03 加速等级：4 星币 = 4 点经验；满级后 16 星币 = 超频 +1 档
func levelup() -> Dictionary:
	if phase != Phase.PREP:
		return _deny("只有准备阶段能加速等级")
	if level < MAX_LEVEL:
		if coin < BUY_XP_COST:
			return _deny("星币不足（加速等级需 %d）" % BUY_XP_COST)
		coin -= BUY_XP_COST
		log_event.emit("加速等级 −%d ◆ · 经验 +%d" % [BUY_XP_COST, BUY_XP_AMOUNT], &"buy")
		add_xp(BUY_XP_AMOUNT)
	else:
		if overtier >= MAX_TIER - MAX_LEVEL:
			return _deny("加速列表已到最高档（超频 %d）" % (MAX_TIER - MAX_LEVEL))
		if coin < OVERTIER_COST:
			return _deny("星币不足（超频需 %d）" % OVERTIER_COST)
		coin -= OVERTIER_COST
		overtier += 1
		# ★ 2026-10-31（仅炼狱）：第二次超频可能额外 +1 上场名额，
		#   必须**当场说明**——否则玩家只看到"商店品质+1"，多出来的一格
		#   不知道从哪来（也可能因为备战席满了而没给，同样要说）。
		var tier_line := "加速列表 超频档 %d／%d（商店品质 +1）" \
				% [overtier, MAX_TIER - MAX_LEVEL]
		if difficulty_id == "inferno" and overtier >= MAX_TIER - MAX_LEVEL:
			if _overtier_slot_bonus():
				tier_line += " · 上场上限 %d（备战席未满 +1）" % field_limit()
			else:
				tier_line += " · 备战席已满（%d/%d），本次不给额外上场名额" \
						% [bench.size(), BENCH_SLOTS]
		log_event.emit(tier_line, &"buy")
		roll_shop()
	changed.emit()
	return {"ok": true, "reason": "", "data": {}}


func set_shop_locked(on: bool) -> void:
	shop_locked = on
	log_event.emit("加速列表已锁定（本节点结束后不重摇）" if on
			else "加速列表已解锁", &"system")
	changed.emit()


# ══════════════════════════════════════════════════════════════════
#  打捞（阶段 C 第二件）
# ══════════════════════════════════════════════════════════════════
#
#  残骸从哪来：**战斗击毁的船，敌我双方都算**（`resolve_battle` 的 destroyed 参数）。
#    ⚠️ 2026-10-01 之前**只有敌方**，玩家原话：
#    「打捞要么只打捞我方的，要么打捞敌我双方的，断然没有只打捞敌方的道理」。
#  残骸怎么走：战斗结算时出现 → 准备阶段可下单 → 下个节点顶掉 1 个货位 → 买走。
#  为什么这样设计、为什么不能「下单立刻给」，见 SALVAGE_COST_RATIO 上方那段。

## ★ 事件「打捞折扣」当前是否生效（按 `node_index` 落在闭区间里判）。
## ⚠️ 区间由 `apply_event` 写入：起点 = 事件节点的**下一个**节点，终点 = 起点 + N − 1。
func salvage_discount_active() -> bool:
	if salvage_discount_from <= 0:
		return false
	var c := event_clock()
	return c >= salvage_discount_from and c <= salvage_discount_to


## ★★ 某一艘残骸的打捞费（2026-10-04 多选后**按艘**算）。
##
## 定价**看阵营**（用户定案的两档博弈）：
##   我方（team 0）→ ×0.5   敌方（team 1）→ ×1.0
##
## ★ 2026-10-28 事件「打捞折扣」期间改成：**双方都 ×0.25**
##   （我方原 1/2、敌方原全价 ⇒ 各减半），
##   且**向下取整**（用户：「四舍五入，就低不就高」⇒ 一律就低），最低 1。
##
## ⚠️ 参数是**下标**不是 Dictionary —— 定价必须从 `wrecks[i]["team"]` 取，
##    不能让调用方自己传 team（两处判阵营必然分叉）。
## ⛔ 越界/空列表一律返回 0（**不抛错**：UI 可能在列表变空的同帧还在问价）。
func salvage_cost_of(idx: int) -> int:
	if idx < 0 or idx >= wrecks.size():
		return 0
	var w: Dictionary = wrecks[idx]
	var c := int(w.get("cost", 1))
	var own := int(w.get("team", 0)) == 0
	if salvage_discount_active():
		var dr := SALVAGE_DISCOUNT_RATIO_SELF if own else SALVAGE_DISCOUNT_RATIO_ENEMY
		return maxi(1, int(floor(float(c) * dr)))
	var ratio := SALVAGE_COST_RATIO if own else SALVAGE_COST_RATIO_ENEMY
	return maxi(1, int(ceil(float(c) * ratio)))


## ★ 勾选若干艘的**合计**打捞费（供 UI 实时显示「已选 N 艘 · 需 M ◆」）。
## ⚠️ 这是「全部勾中的总价」，**不是**「实际会付的价」——
##    买得起几艘要另问 `salvage_affordable()`（部分成交，见 `salvage_order()`）。
func salvage_cost_of_picks(idxs: Array) -> int:
	var sum := 0
	for i in idxs:
		sum += salvage_cost_of(int(i))
	return sum


## 照当前星币，**这批勾选里买得起几艘**（按勾选顺序贪心）。
## 贪心而不是「按费用排序」：玩家是自己勾的，那个顺序本身就是意图。
func salvage_affordable(idxs: Array) -> int:
	var left := coin
	var n := 0
	for i in idxs:
		var c := salvage_cost_of(int(i))
		if c <= left:
			left -= c
			n += 1
	return n


## 现在能不能打捞（**整批**的准入，不是某一艘）。返回 {"ok": bool, "reason": String}
##
## ⚠️ 阶段口径 2026-10-04 放宽：打捞在**结算页（RESOLVE）**上做，
##    不再是「准备阶段」。理由 = 时序直觉（用户原话）：
##    「第一回合打捞要到第三回合才到位，这不符合直觉，要到第二回合」。
##    在结算页下单 ⇒ 点「继续」进下一节点就顶掉货位，**正好第二回合到手**。
##    准备阶段（PREP）现在**不再**允许打捞 —— 那是「上一回合的旧账」，
##    留着只会让玩家能反悔白嫖已付的钱。
func can_salvage() -> Dictionary:
	if phase != Phase.RESOLVE:
		return {"ok": false, "reason": "只能在战斗结算页打捞"}
	if wrecks.is_empty():
		return {"ok": false, "reason": "没有可打捞的残骸"}
	return {"ok": true, "reason": ""}


## ★★ 下单打捞（多选版）：**当场扣钱**，但东西下个节点才到账（延迟到账）。
##
## `idxs` = 玩家在列表里勾选的下标数组（可空 ⇒ 什么都不打捞）。
##
## ## 四条口径（改之前先读 SALVAGE_COST_RATIO 上方那段）
## ##   ① **部分成交**（用户定案「买得起就买，买不起弹提示」）：
## ##      按勾选顺序逐艘扣钱，**买得起就买、买不起就跳过**，
## ##      最后返回「实际买到哪几艘 + 哪几艘因没钱被跳过」，由 UI 弹提示。
## ##      ⛔ 不是「钱不够就整单拒绝」—— 那样玩家得多试几次，很烦。
## ##   ② **上限 `SALVAGE_MAX_PICK`(5)**：下一节点商店只有 5 个货位，
## ##      超出的那几艘**买不了**（跳过 + 提示），不是静默截断。
## ##   ③ 剩下的**没买的仍留在列表里** —— 玩家还可以再勾一次别的，
## ##      但**本节点不能再拖到下一节点**（生命周期仍是一个节点）。
## ##   ④ 货位的竞争是**玩家的责任**：钱只够买 2 艘却勾了 4 艘时，
## ##      买得起的 2 艘进队列，剩下的跳过 —— 不做二次分摊。
##
## ⚠️ 故意**不检查备战席是否满**：到账是「占商店货位」而不是「进备战席」，
##    玩家可以到账后先把备战席腾出来再买。在这里挡一刀只会变成莫名其妙的拒绝。
##
## 返回 = {"ok", "reason", "bought": Array[int], "skipped": Array[int],
##          "paid": int, "names": Array[String], "data": Array[Dictionary]}
func salvage_order(idxs: Array = []) -> Dictionary:
	var v := can_salvage()
	if not bool(v.get("ok", false)):
		return _deny(String(v.get("reason", "打捞失败")))
	if wrecks.is_empty():
		return _deny("没有可打捞的残骸")

	# ── ① 先把勾选去重、剔除越界下标（UI 可能传来重复项）──
	#
	# ⚠️⚠️ 2026-10-05：越界**不能静默丢弃**！
	#    场景：玩家打捞掉一艘后 UI 没来得及重画，他点的是**旧列表**里的行 ⇒
	#    传来的下标已经越界 ⇒ 全部被剔掉 ⇒ `picked` 为空 ⇒
	#    返回一句「没有勾选任何残骸」—— 玩家明明点了，却被告知「没勾选」，
	#    他会当成「点了没反应」，而且这句提示**指错了方向**。
	#    ⇒ 明确报「列表已变化，请重新选择」，让玩家知道该刷新。
	var picked: Array[int] = []
	var dropped := 0
	for x in idxs:
		var i := int(x)
		if i >= 0 and i < wrecks.size() and not picked.has(i):
			picked.append(i)
		else:
			dropped += 1
	if picked.is_empty() and dropped > 0:
		return _deny("残骸列表已变化 —— 请按最新的列表重新选择")

	# ── ② 交易：按勾选顺序「买得起就买」──
	var bought: Array[int] = []
	var skipped: Array[int] = []
	var names: Array[String] = []
	var paid := 0
	# ⚠️⚠️ 勾选总价必须在**删列表之前**算出来（见下方 ③ 的注释）。
	#    实测踩过：钱为 0 时 3 艘全被 skip 并从 wrecks 删掉，
	#    事后再算「本批需多少」得到 0 —— 提示文案变成「需 0 ◆」，
	#    玩家完全看不懂哪里错了。
	var picked_total := salvage_cost_of_picks(picked)
	# ★★ 2026-10-10（审查 R02）：上限必须按「**本节点已预订 + 本次成交**」判，
	#    ⛔ 不能只看本次批次的 `bought.size()`。UI 是「每点一艘调一次
	#    `salvage_order([idx])`」⇒ 每次计数都从 0 开始，第 6 艘照样收钱，
	#    到账时却只有 5 个货位 ⇒ 第六艘**扣了费却消失**（不退不排队）。
	#    `repair_queue` 正是「本节点已下单未到账」的权威计数（`advance()` 到账后清空）。
	var already := repair_queue.size()
	var cap_blocked := 0
	for i in picked:
		if already + bought.size() >= SALVAGE_MAX_PICK:
			skipped.append(i)          # 货位满了 ⇒ 超出部分买不了（含已预订的）
			cap_blocked += 1
			continue
		var c := salvage_cost_of(i)
		if c > coin:
			skipped.append(i)          # 钱不够 ⇒ 跳过（已勾的更便宜的那些还能买）
			continue
		coin -= c
		paid += c
		bought.append(i)
		names.append(String(wrecks[i].get("name", "?")))

	# ── ③ 进队列 ──
	var out: Array[Dictionary] = []
	for i in bought:
		var item: Dictionary = (wrecks[i] as Dictionary).duplicate()
		item["from_node"] = node_index
		# 世代号随修复品一起走 —— 到账时主控要靠它区分「新到货」与「上一件旧货」。
		item["evt"] = wreck_evt
		out.append(item)
	# ⚠️⚠️ 只删**买成的**（`bought`），**买不起的必须留在列表里**（用户定案：
	#    「买得起就买，买不起弹提示」）—— 留着玩家才能换组合再试，
	#    一删掉就等于「钱不够 ⇒ 这批货永远没了」，那不是提示，是判决。
	#    ⛔ 删下标一律**倒序**：正序删会让后面的下标前移，指错船
	#      （与 2026-09-17「打捞上错船」同类）。
	for i in range(wrecks.size() - 1, -1, -1):
		if bought.has(i):
			wrecks.remove_at(i)
			if i < wrecks_display.size():
				wrecks_display.remove_at(i)

	if bought.is_empty():
		return {
			"ok": false, "reason": _short_of_msg(picked, skipped, picked_total, cap_blocked),
			"bought": bought, "skipped": skipped, "paid": 0,
			"names": [] as Array[String], "data": [] as Array[Dictionary],
		}
	# ⚠️⚠️ 必须真的**进队列**（2026-10-04 自查抓到）：重构时把「构造 out」与
	#    「入队」拆成了两段，忘了写 `repair_queue.append_array(out)` ——
	#    症状是**钱扣了、货没了**（最坏的一类：玩家白花钱）。
	#    ⇒ 凡是「钱已扣」的功能，必须有一条断言证明「东西真的到了」。
	repair_queue.append_array(out)
	log_event.emit("打捞下单：%s −%d ◆ · 下节点到账（顶掉 %d 个货位）"
			% [", ".join(names), paid, bought.size()], &"salvage")

	# ★ 2026-10-31（用户定案）：打捞**有 5% 概率**额外掉一件装备。
	#   ⚠️ 每次**成功下单**掷一次，不是每艘掷一次 —— 一次勾 5 艘的期望掉落
	#      必须等于勾 1 艘，否则「多勾多掉」会变成鼓励拆单的无意义操作。
	#   ⚠️ 掷在**扣费之后**：这是「捞着捞着翻出个好东西」的惊喜，
	#      不是失败补偿 ⇒ 不中也不该退钱、不该垫概率。
	#   ⚠️ 背包满 ⇒ 直接丢弃（与精英/BOSS 掉落同口径），并明说，
	#      否则玩家会怀疑「是不是掉了但没显示」。
	var salvage_equip := {}
	if rng.randf() < EQUIP_SALVAGE_CHANCE:
		salvage_equip = roll_equip(rng, 1)
		if grant_equip(salvage_equip):
			log_event.emit("打捞时翻出了装备：%s（背包 %d/%d）"
					% [String(salvage_equip["name"]), bag_used(), EQUIP_BAG_SIZE], &"salvage")
		else:
			salvage_equip = {}
			log_event.emit("背包已满（%d/%d），打捞出的装备被丢弃" % [EQUIP_BAG_SIZE, EQUIP_BAG_SIZE], &"hint")

	changed.emit()
	return {
		"ok": true, "reason": "", "bought": bought, "skipped": skipped,
		"paid": paid, "names": names, "data": out,
	}


## 「一艘都没买成」的提示文案。
##
## ⚠️ 这里区分两种「买不起」，因为玩家该知道**下一步该做什么**：
##   · 货位满了但还有钱 → 提示是货位不够（这跟钱无关，攒钱也没用）
##   · 纯粹星币不够     → 报出还差多少
##
## ⚠️ `need` 必须由调用方**在删列表之前**算好传进来：那时列表里的船已经被
##    移走了，现算会得到 0（实测踩过：「本批需 0 ◆，现有 0 ◆」）。
## ⚠️ `cap_blocked` = 被「货位已订满」挡下的数量（≠ 钱不够）——
##    两种拒绝**必须给不同方向**的话：货位满了攒钱也没用，报「星币不足」是骗人。
func _short_of_msg(picked: Array[int], skipped: Array[int], need: int,
		cap_blocked: int = 0) -> String:
	if picked.is_empty():
		return "没有勾选任何残骸"
	if cap_blocked >= picked.size() and cap_blocked > 0:
		return "本节点货位已订满（最多 %d 艘）—— 已预约的下回合到账" % SALVAGE_MAX_PICK
	if picked.size() > SALVAGE_MAX_PICK:
		return "最多只能打捞 %d 艘（商店货位数）" % SALVAGE_MAX_PICK
	return "星币不足：本批需 %d ◆，现有 %d ◆" % [need, coin]


## 给 HUD 的展示数据（★ 结算页打捞浮层的**唯一输入源**）。
##
## ## 三条口径
## ##   ① **列表形态**（2026-10-04 多选）：`state=="list"` 时带 `items` 数组，
## ##      每项自带上桌要显示的全部字段（舰名/星级/阵营/单价/数值）。
## ##      UI **不许**自己再算一遍价钱或星级 —— 那是本函数存在的唯一理由。
## ##   ② 保留 `state=="repairing"`：已下单未到账的修复品，商店面板要显示。
## ##   ③ 空 = `{}`（无残骸且无在途）。
##
## ## ⚠️ `base_exact` 是**判据**不是装饰（见 derive_wreck_tier() §2）。
##    为 false 时（残骸来自被放大过的敌掠袭舰队），数值**不许**
##    反向折算「原版裸值」—— 那会明显偏离船表，玩家一眼看出不对。
##    此时 UI 应显示「敌掠袭 · 强化版」而不是假装它是原版船。
func salvage_info() -> Dictionary:
	if not wrecks.is_empty():
		var items: Array[Dictionary] = []
		for i in wrecks.size():
			var w: Dictionary = wrecks[i]
			var dv: Dictionary = wrecks_display[i] if i < wrecks_display.size() else {}
			var star := int(dv.get("star", int(w.get("star", 1))))
			var atk_base := float(dv.get("atk_base", w.get("attack", 0.0)))
			var def_base := float(dv.get("def_base", w.get("armor_struct", 0.0)))
			var m := float(dv.get("m", 1.0))
			var tb := tier_base_from(star, atk_base, def_base)
			items.append({
				"idx": i,
				"name": String(w.get("name", "?")),
				"star": star,
				"cost": int(w.get("cost", 1)),
				"team": int(w.get("team", 0)),
				"price": salvage_cost_of(i),
				"atk": int(roundf(float(tb["atk"]))),
				"def": int(roundf(float(tb["def"]))),
				"scan_res": int(w.get("scan_res", 0)),
				"cap": int(roundf(float(w.get("cap_max", 0.0)))),
				"base_exact": m <= 1.0 + 0.12,
				# ★ 打捞区每行前缀「节点 N ·」（参考图 1 的排版）
				"node": node_index,
			})
		return {
			"state": "list",
			"items": items,
			"total": wrecks.size(),
			"max_pick": SALVAGE_MAX_PICK,
			# ★ 本节点还能再订几艘（= 上限 − 已预约）。UI 用它显示剩余货位。
			"remaining": maxi(0, SALVAGE_MAX_PICK - repair_queue.size()),
			"coin": coin,
			"evt": wreck_evt,
			# ★ 已下单未到账的（在途）—— 结算页打捞区的「修复队列（下回合到账）」行读它。
			#    ⚠️ 之前没这个键 ⇒ UI 那一行永远空白（实测漏过）。
			"queue": repair_queue.duplicate(true),
			# 向后兼容的顶层字段（旧商店框读它；多选下它等于「列表第一艘」）
			"name": String((wrecks[0] as Dictionary).get("name", "?")),
			"cost": int((wrecks[0] as Dictionary).get("cost", 1)),
		}
	if not repair_queue.is_empty():
		var it: Dictionary = repair_queue[0]
		return {
			"state": "repairing",
			"name": String(it.get("name", "?")),
			"star": int(it.get("star", 1)),
			"cost": int(it.get("cost", 1)),
			"price": 0,
			"total": repair_queue.size(),
			"evt": int(it.get("evt", 0)),
		}
	return {}


## 把任意形态的「船」统一成派生 Dictionary（EveShip / Dictionary / ship_key）。
##
## ⚠️ **全工程只有这一处做「怎么算一艘船」的判定**。`_cost_of` 也走它 ——
##    这个判据原本在 `_cost_of` 里写了一份，加打捞时又写了一份，
##    两处一旦分叉就会出现「信标记了账、残骸却认不出来」这种半边生效的怪事。
##    返回 {} = 认不出来。
static func _as_ship_dict(e) -> Dictionary:
	if e == null:
		return {}
	if e is EveShip:
		var s: EveShip = e
		var d := EveShipDatabase.by_id(String(s.ship_key))
		if d.is_empty():
			return {}
		var out := d.duplicate()
		out["star"] = s.star
		return out
	if e is Dictionary:
		var dd: Dictionary = e
		if dd.is_empty():
			return {}
		# 只给了 key 的裸字典 → 现查表补全
		if dd.has("ship_key") and not dd.has("name"):
			return EveShipDatabase.by_id(String(dd["ship_key"]))
		return dd
	if e is String or e is StringName:
		return EveShipDatabase.by_id(String(e))
	return {}


## ★★ 从「本节点被击毁的船」里做出一**批**残骸。**敌我双方都在内，一艘不漏**。
##
## ## 2026-10-04 用户定案，与旧版的四处差异
## ##   ① **不再只挑「费用最高的一艘」** —— 原来那个筛选逻辑整条删掉了。
## ##      玩家原话：「本回合所有被击毁的船都进打捞列表」。
## ##   ② 旧的、还没下单的残骸在这里**整批作废** —— 生命周期恰好一个节点。
## ##   ③ 每条都带 `"team"`（0 我方 / 1 敌方）—— **定价要靠它**分两档。
## ##   ④ 产出**按费用降序**排（贵的在前）：UI 列表从上到下就是「先看贵的」，
## ##      而 `sources` 的下标对应关系在排序后**必须重算**（见下）。
##
## ⚠️ 2026-10-01 起 `sources` 是并行数组，抄下「结算那一刻」的**原始属性证据**
##    （星级 / 裸攻击 / 裸防御）。原因见 `derive_wreck_tier()` 上方那段 ——
##    结算弹窗延迟 1 秒 + 舰队重建，事后再去读 `EveShip` 上的字段一定是陈的。
##    ⇒ **排序时必须把 sources 跟着一起搬**，否则星级会张冠李戴
##      （这类「两个并行数组排序后错位」的 bug 最隐蔽：数量对得上、值全错）。
##
## 签名兼容：`destroyed` 不传 / 元素是派生 Dictionary 时，
## 星级一律取 1（无证据 ⇒ 不假装知道），不会崩。
## 本节点必掉的装备（返回 {} = 不掉）。
##
## 用户定案（2026-10-31）：**精英怪和 BOSS 必掉**。档位跟着节点走：
##   精英 → tier 2 · BOSS → tier 3 · 其余节点 → 不掉。
## ⚠️ 判据用 `node_type()`（走节点表的 `type`），⛔ 不要用 `node_index` 硬编码 ——
##    节点表以后加/删精英关时，硬编码会静默错位（`BOSS_INDEXES` 已经有这个隐患）。
func _node_equip_drop(won: bool) -> Dictionary:
	if not won:
		return {}
	var t := node_type()
	if t != &"elite" and t != &"boss":
		return {}
	return roll_equip(rng, 3 if t == &"boss" else 2)


func _set_wreck_from(destroyed: Array, sources: Array = [],
		power_scale: float = 1.0) -> void:
	wrecks.clear()
	wrecks_display.clear()
	wreck_evt += 1
	if destroyed.is_empty():
		return

	# ── ① 先把 (残骸, 证据, 阵营) 打包成同下标的三元组 ──
	#    ⚠️ 阵营从 `EveShip.team` 取；派不上（传字典进来）时默认 0（按我方半价算，
	#    比让玩家多付钱安全）。
	var rows: Array[Dictionary] = []
	for i in destroyed.size():
		var e = destroyed[i]
		var d := _as_ship_dict(e)
		if d.is_empty():
			continue
		var src: Dictionary = {}
		if i < sources.size() and sources[i] is Dictionary:
			src = sources[i]
		var team := 0
		if e is EveShip:
			team = int((e as EveShip).team)
		elif src.has("team"):
			team = int(src.get("team", 0))
		rows.append({"ship": d, "src": src, "team": team})

	# ── ② 按费用降序排（贵的前面），并排进两个输出数组 ──
	#    ⚠️ 排序键必须**显式**给 compare 函数：Array.sort_unstable() 直接调用时
	#       传的是**元素本身**（Dictionary），不是下标。
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int((a["ship"] as Dictionary).get("cost", 1)) \
				> int((b["ship"] as Dictionary).get("cost", 1)))

	var m := maxf(0.01, power_scale)
	for r in rows:
		var d: Dictionary = (r["ship"] as Dictionary).duplicate()
		var src: Dictionary = r["src"]
		var team := int(r["team"])
		# ── 证据：优先权威表裸值（sources 为空时现查一次表，口径同一份）──
		var dbase := EveShipDatabase.by_id(String(d.get("ship_key", "")))
		var atk_base := float(src.get("atk_base", dbase.get("attack", 1.0)))
		var def_base := float(src.get("def_base", dbase.get("armor_struct", 1.0)))
		var star := 1
		var mm := m
		if team == 0:
			# ★★ 2026-10-10（审查 R03）：我方残骸**直接取编制/快照里的真实星级**。
			#    ⛔ 不能把敌方关卡倍率 `m` 喂给 `derive_wreck_tier()` ——
			#    我方舰船根本没被放大，而该函数在 m > 1.12 时一律判 1★
			#    （复现：同一艘我方二星船，m=1.0 → 2★，m=1.25 → 1★）。
			#    我方数值本就是原版裸值 ⇒ `mm` 固定 1.0，让 `base_exact` 成立。
			star = clampi(int(src.get("star", 1)), 1, MAX_STAR)
			mm = 1.0
		else:
			var shot := float(src.get("shot", atk_base * m))
			star = int(derive_wreck_tier(shot, m, atk_base, def_base)["star"])
		d["star"] = star
		d["team"] = team
		wrecks.append(d)
		wrecks_display.append({
			"star": star, "atk_base": atk_base, "def_base": def_base,
			"m": mm, "team": team, "evt": wreck_evt,
		})

	# ── ③ 一行汇总日志（逐艘打日志会把战斗日志刷爆）──
	var own_n := 0
	for w in wrecks:
		if int(w.get("team", 0)) == 0:
			own_n += 1
	log_event.emit("残骸 %d 艘（我方 %d · 敌方 %d）—— 可在结算页挑选打捞"
			% [wrecks.size(), own_n, wrecks.size() - own_n], &"salvage")


## ⚠️ **延迟到账的落地点**，由 `advance()` 调用。
## 槽位从 0 开始占，并记进 `salvage_slots` —— 本节点内所有刷新都绕开它们。
func _deliver_repairs() -> void:
	if repair_queue.is_empty():
		return
	salvage_slots.clear()
	var delivered := 0
	for i in repair_queue.size():
		if i >= SHOP_SLOTS:
			break
		offers[i] = repair_queue[i]
		salvage_slots.append(i)
		delivered += 1
	for i in delivered:
		var it: Dictionary = repair_queue[i]
		log_event.emit("修复完成：%s ★%d 已占货位（本节点刷新刷不掉）"
				% [String(it.get("name", "?")), int(it.get("star", 1))], &"salvage")
	# ★ 2026-10-10（审查 R02）：**只移除真正交付的**。
	#    ⛔ 旧代码「先只写前 5 个，再把整个队列 clear()」—— 溢出（理论上
	#    已由下单上限堵住）时会**凭空吞掉玩家已付费的货**。这里保留溢出项，
	#    下个节点继续到账，绝不静默丢弃。
	if delivered >= repair_queue.size():
		repair_queue.clear()
	else:
		var rest: Array[Dictionary] = []
		for i in range(delivered, repair_queue.size()):
			rest.append(repair_queue[i])
		repair_queue = rest
	offers_changed.emit()


## 没买走的修复品在**离开节点时作废** —— 「只占 1 个节点」这个成本才成立。
##
## ⚠️ 这里自己把槽位重摇掉，不依赖后面的 `roll_shop()`：
##    `shop_locked = true` 时 `advance()` 会**跳过** roll_shop，
##    那时陈旧的修复品会一直挂在货架上（而且不报错）。
##
## ⚠️ 2026-10-01：**同时清掉卡面可能读到的陈旧数值**。
##    `offers[i]` 被重摇成普通报价之后，它身上若还挂着 `from_node` 系列键
##    （star / evt），商店画卡时会读到上一件修复品的星级 —— 那就是
##    「打捞框里的数字有残留」的同一个病根，只不过换了个地方暴露。
func _expire_repairs() -> void:
	if salvage_slots.is_empty():
		return
	for i in salvage_slots:
		if i < 0 or i >= offers.size():
			continue
		var o = offers[i]
		# 只清「还是修复品」的槽位；玩家买走后那里已经是新摇的报价了
		if o is Dictionary and (o as Dictionary).has("from_node"):
			offers[i] = _roll_one()
	salvage_slots.clear()


# ══════════════════════════════════════════════════════════════════
#  等级与经验
# ══════════════════════════════════════════════════════════════════

## 上场上限 = 等级 + 2
##
## ★ 2026-10-31（用户定案，仅炼狱）：满级 6 之后的**第二次**超频
##   （`overtier` 到 2 = `MAX_TIER - MAX_LEVEL`），若**备战席没坐满**，
##   额外 +1 个上场名额。用户原话：
##     「等级6我看可升级两次，第二次升级如果备战席上不是舰船满额的情况，
##       可以多加一个派舰船到战斗区的名额」。
##
## ⚠️ 为什么条件里要「备战席未满」：这是用户给的原样条件，**不要自作主张删掉**。
##   读法是「你还有空位囤船 ⇒ 说明你缺的是上场位而不是货架」，给名额才有意义。
## ⚠️ 名额是**动态**的：玩家往备战席塞满第 8 艘，名额会立刻掉回 8；
##   已经在场上的第 9 艘**不会**被强制撤回（没有任何代码会踢人），
##   只是此时不能再往上拖。这是可接受的边界，⛔ 别加"自动下场"。
## ⚠️ 只对炼狱生效（用户当次声明的总前提「以下更新只对炼狱难度生效」）。
func field_limit() -> int:
	var cap := LEVEL_CAP[clampi(level, 1, MAX_LEVEL)]
	if _overtier_slot_bonus():
		cap += 1
	return cap


## 炼狱「二次超频 + 备战席未满」的那 1 格名额是否生效。
## ⚠️ 单独抽出来是为了让 HUD / 日志能显示「这 1 格是怎么来的」，
##    而不是在 `field_limit()` 里读一个算好的数却讲不出原因。
func _overtier_slot_bonus() -> bool:
	if difficulty_id != "inferno":
		return false
	if level < MAX_LEVEL:
		return false
	if overtier < MAX_TIER - MAX_LEVEL:
		return false
	return bench.size() < BENCH_SLOTS


## 本级内已获得的经验
func xp_in_level() -> int:
	if level >= MAX_LEVEL:
		return 0
	return xp - LEVEL_XP[level]


## 升到下一级还需要多少经验（满级后返回 0）
func xp_need() -> int:
	if level >= MAX_LEVEL:
		return 0
	return LEVEL_XP[level + 1] - LEVEL_XP[level]


## 加经验并处理升级。
##
## ⚠️ 这条是**两条腿**里的第 ① 条（交接文档 §5.3：「补漏不是新增设计」）：
##    云顶的经验 = ① 每回合自动 +2 ＋ ② 4 金币买 4 点，我们原来只搬了 ②。
##    漏了 ① 的后果是不主动点「加速等级」的玩家整关卡在 Lv1
##    （人口 3、商店 100% 只出 1 费船），而 BOSS 是 6 艘。
func add_xp(amount: int) -> void:
	if amount <= 0:
		return
	if level >= MAX_LEVEL:
		# 满级后经验没有去处（超频走硬币，不走经验），不再累积，
		# 免得顶栏挂一个永远不动的「40 / 40」。
		return
	xp += amount
	while level < MAX_LEVEL and xp >= LEVEL_XP[level + 1]:
		level += 1
		# ⚠️ 升级【不】把人推上场（2026-09-20）：上限抬高只是「多了位置」，
		#    上谁、上几艘是玩家的决定。见「已删除：auto_deploy()」。
		log_event.emit("等级提升 → Lv.%d（上场上限 %d —— 备战席的船可以再拖上去一艘）"
				% [level, field_limit()], &"economy")
	changed.emit()


# ══════════════════════════════════════════════════════════════════
#  备战席 / 上场
# ══════════════════════════════════════════════════════════════════

## ── 已删除：auto_deploy()（2026-09-20）────────────────────────────
##
## 原实现：把备战席的船按购入顺序自动补进场上空位，买船 / 升级 / 卖掉场上的船
## 都会顺手调它一次。**整条机制已移除，不要再恢复。**
##
## ── 为什么删（用户 2026-09-20 定稿，对齐云顶之弈）──────────────────
##  原文：「我是要先购买，购买后舰船就出现在备战席，不然备战席拿来干嘛？
##         然后备战席再拖到棋盘上，这样棋盘的显示与关闭才有操作上的意义。」
##
##  「自动上场」这条捷径的代价是同时废掉两个系统：
##    ① **备战席**退化成「0~1 艘的过道」，8 个格子和那条轨道永远不需要看；
##    ② **棋盘**永远不必显形 —— 玩家从不手动落格，
##       于是「格子只在拖动时显形」这条视觉规则一次也触发不了。
##  剩下玩家能看到的就只有「花钱 → 船自己会打」，与阶段 A 的假系统无异。
##
##  现在：进场只有 `deploy_from_bench()`，退场只有 `recall_to_bench()` /
##  `sell_from_field()`。三处触发点（buy / add_xp / _do_sell）里那句
##  `auto_deploy()` 也一并删掉 —— 否则「卖掉场上的一艘，备战席自动顶上来」
##  同样会替玩家做决定。
##
## ⚠️ 由此带来的一条**玩法后果**（如实记录）：开局场上是一艘都没有的。
##    玩家必须自己从备战席拖到棋盘，否则开战直接判负（见 _forfeit_no_deploy）。
##    这是云顶之弈本来就要玩家学的那一课，不是缺陷。


# ══════════════════════════════════════════════════════════════════
#  三连合成（阶段 B1）
# ══════════════════════════════════════════════════════════════════

## 三连合成：同 id 同星 ×3 → 升一星。
##
## ── 三条口径 ────────────────────────────────────────────────────
##  ① **同 id 同星**才算一组 —— 2★ 和 1★ 不混着凑（云顶同口径）。
##  ② **合成品继承场上的位置**：三张里只要有一张在场上，升星后的船就留在
##     那个格子里（`cell` 一起继承）。否则合成品留在备战席。
##     这条决定了「把两张放场上、第三张买进来」是一个有效打法 ——
##     如果合成品总是落回备战席，玩家每次升星都要重新摆位。
##  ③ **可连锁**：3×1★ → 2★ 之后，如果场上已有两张 2★，会立刻再合成 3★。
##     所以用 while 循环而不是 if。
##
## 返回 true 表示这一轮至少合成了一次。
func _try_merge() -> bool:
	var any := false
	# 上限 8 次 —— 结构上最多 3 层连锁，8 是防御性的（防止逻辑写错时空转）。
	for _guard in 8:
		if not _merge_once():
			break
		any = true
	return any


func _merge_once() -> bool:
	# 找第一组满足「同 id 同星且满 3 张」的
	var key := &""
	var star := 0
	for star_level in range(1, MAX_STAR):
		var seen := {}
		for e in all_owned():
			var k := StringName(e.get("ship_key", &""))
			var s := int(e.get("star", 1))
			if s != star_level:
				continue
			var tag := "%s@%d" % [String(k), s]
			seen[tag] = int(seen.get(tag, 0)) + 1
			if int(seen[tag]) >= 3:
				key = k
				star = s
				break
		if star > 0:
			break
	if star == 0:
		return false

	# 收集这三张：优先消费场上的（合成品就能留在场上）
	var field_hits: Array[int] = []
	var bench_hits: Array[int] = []
	for i in field.size():
		if _is_same(field[i], key, star):
			field_hits.append(i)
	for i in bench.size():
		if _is_same(bench[i], key, star):
			bench_hits.append(i)
	if field_hits.size() + bench_hits.size() < 3:
		return false

	var keep_in_field := not field_hits.is_empty()
	var take_field: Array[int] = []
	var take_bench: Array[int] = []
	var need := 3
	for i in field_hits:
		if need == 0:
			break
		take_field.append(i)
		need -= 1
	for i in bench_hits:
		if need == 0:
			break
		take_bench.append(i)
		need -= 1

	# 继承位置：先摘出「保留的那一张」，别的删掉
	var inherited := Vector2i(-1, -1)
	if keep_in_field:
		inherited = field[take_field[0]].get("cell", Vector2i(-1, -1))
	else:
		inherited = bench[take_bench[0]].get("cell", Vector2i(-1, -1))

	# ★★ 2026-10-10（审查 R04）：**合成必须继承永久事件强化**（`buffs`）。
	#
	#   旧实现用 `_make_entry()` 造新条目、只继承 `cell` ⇒ 三张材料上的
	#   `buffs`（武器调校 attack_pct / 结构加固 def_pct …）全部丢失，而对应
	#   事件仍记「已获取」 ⇒ 玩家白白损失一次事件机会，且再也补不回来。
	#
	#   规则：把三张材料的 buffs **按 key 合并去重（取最大值）**。
	#   ⚠️ 事件在本局不可重复选 ⇒ 同一 key 只可能来自一条事件，「取 max」=
	#      正确继承，同时天然防止「同一强化被三张材料重复叠乘」。
	#   📌 将来若引入可重复来源，应把 buffs 改成「带来源 id 的效果集合」再合并。
	var merged_buffs: Dictionary = {}
	for i in take_field:
		_merge_buffs_into(merged_buffs, field[i].get("buffs", {}))
	for i in take_bench:
		_merge_buffs_into(merged_buffs, bench[i].get("buffs", {}))

	# ★ 2026-10-31：实付累加 —— 材料里只要有一张带 `paid`（精英货 ★2 是一星价买的），
	#   合成品也必须是"实付口径"，否则「两张精英 2★ + 一张普通 2★ 合出 3★，
	#   按 9 倍卖」又是一条刷钱路（成本 3+3+9=15，卖出 27）。
	#   ⚠️ 没有 `paid` 的材料用 `sell_value()` 取它的原价 —— 恰好就是
	#      「3^(star-1) 张原价」，和原公式同值，所以普通材料合出来
	#      和不加这段完全一样（不会因浮点/取整产生 1 币漂移）。
	#   ⚠️ 必须在删除材料**之前**收集（下面 drop_field / drop_bench 会清空数组）。
	var paid_total := 0
	var any_paid := false
	for i in take_field:
		if field[i].has("paid"):
			any_paid = true
			paid_total += int(field[i]["paid"])
		else:
			paid_total += sell_value(field[i])
	for i in take_bench:
		if bench[i].has("paid"):
			any_paid = true
			paid_total += int(bench[i]["paid"])
		else:
			paid_total += sell_value(bench[i])

	# 倒序删除（先删大下标，免得前面的下标失效）
	var drop_field: Array[int] = take_field.duplicate()
	drop_field.sort()
	drop_field.reverse()
	for i in drop_field:
		field.remove_at(i)
	var drop_bench: Array[int] = take_bench.duplicate()
	drop_bench.sort()
	drop_bench.reverse()
	for i in drop_bench:
		bench.remove_at(i)

	var merged := _make_entry(key, star + 1)
	merged["cell"] = inherited
	if not merged_buffs.is_empty():
		merged["buffs"] = merged_buffs
	if any_paid:
		merged["paid"] = paid_total
	if keep_in_field:
		field.append(merged)
	else:
		bench.append(merged)

	var d := EveShipDatabase.by_id(String(key))
	var nm := String(d.get("name", String(key)))
	log_event.emit("★ 三连合成：%s ×3 → %s★%d%s" % [
			nm, nm, star + 1, "（留在场上）" if keep_in_field else "（留在备战席）"],
			&"economy")
	return true


static func _is_same(e: Dictionary, key: StringName, star: int) -> bool:
	return StringName(e.get("ship_key", &"")) == key and int(e.get("star", 1)) == star


## 把一条 entry 的 `buffs` 合并进 `dst` —— **按 key 取最大值**（去重，防重复叠乘）。
static func _merge_buffs_into(dst: Dictionary, src) -> void:
	if not (src is Dictionary):
		return
	for k in (src as Dictionary).keys():
		dst[k] = maxf(float(dst.get(k, 0.0)), float((src as Dictionary)[k]))


# ══════════════════════════════════════════════════════════════════
#  拖放部署（阶段 B5）
# ══════════════════════════════════════════════════════════════════
#
# ⚠️ 这里只管【编制】，不管 3D 与鼠标：
#    鼠标 → 格号 的换算在 EveBattleScene（它才知道相机与棋盘），
#    格号 → 世界坐标 也在那一侧（arena.board_cell_to_world）。
#    本类只回答「这一步允许吗、编制怎么变」。

## 拿起备战席第 index 艘，放到棋盘的 (row, col) 格。
##
## ★★ 2026-11-07（玩家要求）：「拖到已有船的格子」不再被拒，而是**互换**。
##    玩家原话：「棋盘上的船需要能互换位子，现在需要三个步骤去调位子，太过于麻烦。
##    比如鲲鹏想跟死亡旋涡换位子，目前只能先把鲲鹏丢一边，然后移动死亡旋涡去
##    原来鲲鹏的位子，最后再让鲲鹏去原来死亡旋涡的位子。」
##
##    口径（与云顶一致）：备战席那艘进场，**被顶掉的那艘回它腾出来的那个备战席格**
##    ⇒ 上场数、备战席数都不变，所以：① 不受 `field_limit()` 限制
##      ② 不需要「备战席有没有空位」这个前提（永远够）。
func deploy_from_bench(bench_index: int, row: int, col: int) -> Dictionary:
	if phase != Phase.PREP:
		return _deny("只有准备阶段能布阵")
	if bench_index < 0 or bench_index >= bench.size():
		return _deny("这一格是空的")
	if not _cell_ok(row, col):
		return _deny("只能放在我方部署区（棋盘下 4 行）")

	# ── 落点有人 ⇒ 互换（先判这个，因为它要跳过上场位上限）──────────────
	var occ := field_index_at(row, col)
	if occ >= 0:
		var e0: Dictionary = bench[bench_index]
		var other: Dictionary = field[occ]
		var other_name := entry_name(other)
		var other_star := int(other.get("star", 1))
		e0["cell"] = Vector2i(row, col)
		other["cell"] = Vector2i(-1, -1)
		# ⚠️ 先动 `cell` 再换位：`field[occ] = e0` 之后 `other` 已经不在 field 里，
		#    但它是同一个 Dictionary 引用，改 cell 仍然生效。
		field[occ] = e0
		bench[bench_index] = other
		log_event.emit("互换：%s★%d 上场 → 第 %d 行第 %d 列，%s★%d 回备战席" % [
				entry_name(e0), int(e0.get("star", 1)), row + 1, col + 1,
				other_name, other_star], &"deploy")
		changed.emit()
		return {"ok": true, "reason": "", "data": {"swap": true}}

	if field.size() >= field_limit():
		return _deny("上场已满 %d／%d —— 先把场上一艘拖回备战席（或出售）"
				% [field.size(), field_limit()])

	var e: Dictionary = bench[bench_index]
	e["cell"] = Vector2i(row, col)
	field.append(e)
	bench.remove_at(bench_index)
	var d := EveShipDatabase.by_id(String(e.get("ship_key", &"")))
	log_event.emit("%s★%d 上场 → 第 %d 行第 %d 列（%d／%d）" % [
			String(d.get("name", String(e.get("ship_key", "?")))), int(e.get("star", 1)),
			row + 1, col + 1, field.size(), field_limit()], &"deploy")
	changed.emit()
	return {"ok": true, "reason": "", "data": {}}


## 把场上第 index 艘挪到棋盘的 (row, col) 格
##
## ★★ 2026-11-07：落点已有船 ⇒ **两艘互换格子**（原因见 `deploy_from_bench`）。
##    ⚠️ 前提是**这两艘都有真实格号**。「没有格号」（`cell = (-1,-1)`，走默认阵型
##    自动摆位的那种）没法定义「换到哪」，这种数据形态只可能来自老存档，
##    此时退回原行为（拒绝），不去猜。
func move_field(field_index: int, row: int, col: int) -> Dictionary:
	if phase != Phase.PREP:
		return _deny("只有准备阶段能布阵")
	if field_index < 0 or field_index >= field.size():
		return _deny("这一格是空的")
	if not _cell_ok(row, col):
		return _deny("只能放在我方部署区（棋盘下 4 行）")
	var occ := field_index_at(row, col)
	if occ >= 0 and occ != field_index:
		var mine = field[field_index].get("cell", Vector2i(-1, -1))
		if not (mine is Vector2i) or mine.x < 0:
			return _deny("这一格已经有船了")
		var a_name := entry_name(field[field_index])
		var b_name := entry_name(field[occ])
		field[field_index]["cell"] = Vector2i(row, col)
		field[occ]["cell"] = mine
		log_event.emit("互换：%s ↔ %s" % [a_name, b_name], &"deploy")
		changed.emit()
		return {"ok": true, "reason": "", "data": {"swap": true}}
	field[field_index]["cell"] = Vector2i(row, col)
	changed.emit()
	return {"ok": true, "reason": "", "data": {}}


## 把场上第 index 艘撤回备战席（腾出人口）
func recall_to_bench(field_index: int) -> Dictionary:
	if phase != Phase.PREP:
		return _deny("只有准备阶段能调整编制")
	if field_index < 0 or field_index >= field.size():
		return _deny("这一格是空的")
	if bench.size() >= BENCH_SLOTS:
		return _deny("备战席已满（%d／%d）" % [bench.size(), BENCH_SLOTS])
	var e: Dictionary = field[field_index]
	e["cell"] = Vector2i(-1, -1)
	bench.append(e)
	field.remove_at(field_index)
	var d := EveShipDatabase.by_id(String(e.get("ship_key", &"")))
	log_event.emit("%s★%d 撤回备战席（上场 %d／%d）" % [
			String(d.get("name", "?")), int(e.get("star", 1)),
			field.size(), field_limit()], &"deploy")
	changed.emit()
	return {"ok": true, "reason": "", "data": {}}


## 出售返还的星币。
##
## ⚠️ 口径：合成品按 **3^(star-1) 张原价**返还 ——
##    2★ 是 3 张 1★ 合成的，所以退 3 倍；3★ 是 9 张，退 9 倍。
##    这样「合成"然后再卖」不亏不赚，玩家不会因为怕亏而不敢合成。
##
## ★★ 2026-10-31（精英货架）：**实际付过钱的船按实付返还**。
##
##   超频满档后商店卖的是「★2 巡洋，按一星计价」。如果卖价还按
##   `cost × 3^(star-1)` 算，就是：花 3 买进、卖 9 ⇒ **每次刷新白赚 6**，
##   而刷新本身只花 2 —— 这是能无限印钞的死洞（不是"略赚"，是"无脑刷"）。
##
##   ⇒ 引入 `paid` 字段（可选）：**玩家实际为这艘船花掉的星币总额**。
##      · 精英货买入时 = 一星价（`_buy` 里写）
##      · 三连合成时 = 三张材料的实付之和（`_merge_once` 里累加）
##      · 没有这个字段的老船（普通货 / 打捞品）走原公式，行为**完全不变**
##    这样「买 → 卖」始终不赚不亏，与原公式的语义（合成不亏）一致。
func sell_value(entry: Dictionary) -> int:
	if entry.has("paid"):
		return maxi(0, int(entry["paid"]))
	var key := String(entry.get("ship_key", ""))
	var d := EveShipDatabase.by_id(key)
	var cost := int(d.get("cost", 1))
	return cost * int(pow(3.0, float(maxi(0, int(entry.get("star", 1)) - 1))))


## 可以出售的阶段：准备 **和** 结算（打捞期）。
##
## ★ 2026-10-28（用户：「打捞的时候如果钱不够，应该允许玩家卖掉船换星币」）：
##   原来只放行 `PREP` ⇒ 玩家在结算页看中一艘残骸、差几块星币时只能干瞪眼。
##   ⚠️ **战斗期不放行**：那时场上的船正在打，卖掉会让战报与实际编制对不上。
func can_sell() -> bool:
	return phase == Phase.PREP or phase == Phase.RESOLVE


func sell_from_bench(bench_index: int) -> Dictionary:
	if not can_sell():
		return _deny("只有准备阶段和打捞结算时能出售")
	if bench_index < 0 or bench_index >= bench.size():
		return _deny("这一格是空的")
	var e: Dictionary = bench[bench_index]
	return _do_sell(e, bench_index, true)


func sell_from_field(field_index: int) -> Dictionary:
	if not can_sell():
		return _deny("只有准备阶段和打捞结算时能出售")
	if field_index < 0 or field_index >= field.size():
		return _deny("这一格是空的")
	var e: Dictionary = field[field_index]
	return _do_sell(e, field_index, false)


## 按**条目本体**出售（⛔ 不是下标）。
##
## ★★ 2026-11-07 修的真 bug（玩家反馈：「结算时想卖船，卖完发现少了另一艘」）：
##
##   战斗结束时 `resolve_battle()` 会把**阵亡的我方舰船从 `field` 里删掉**
##   （见那里的长注释），于是：
##     · 拖放控制器手里的 `_own_field_index` 是**开战前**算出来的映射；
##     · 战后再拿它去 `sell_from_field(idx)`，下标已经整体前移 ⇒
##       卖掉的是**另一艘**（或者直接越界失败，玩家以为"结算期不能卖"）。
##
##   下标在结算期根本不可靠（列表被改过），所以这段时间按**条目引用**找：
##   拖起来时抓住的就是那个 Dictionary 本体，`is_same()` 一定认得出它。
##
## ⚠️ 用 `is_same()` 而不是 `==`：两艘同名同星的船字典**值**可能完全一样
##    （都在备战席、`cell` 都是 -1,-1），值比较会卖掉先找到的那一艘。
##    `is_same()` 比的是"是不是同一个对象"，这才是"我刚拖的那一艘"。
func sell_entry(entry: Dictionary) -> Dictionary:
	if not can_sell():
		return _deny("只有准备阶段和打捞结算时能出售")
	if entry.is_empty():
		return _deny("这一格是空的")
	for i in field.size():
		if is_same(field[i], entry):
			return _do_sell(entry, i, false)
	for i in bench.size():
		if is_same(bench[i], entry):
			return _do_sell(entry, i, true)
	# 找不到 = 这艘船在这一帧之前已经被卖掉了（连点 / 两次松手）。
	return _deny("这艘船已经不在编队里了")


func _do_sell(e: Dictionary, index: int, from_bench: bool) -> Dictionary:
	var back := sell_value(e)
	var d := EveShipDatabase.by_id(String(e.get("ship_key", "")))
	coin += back
	if from_bench:
		bench.remove_at(index)
	else:
		field.remove_at(index)
	log_event.emit("出售 %s★%d → 返还 %d ◆（星币 %d）" % [
			String(d.get("name", "?")), int(e.get("star", 1)), back, coin], &"sell")
	# ⚠️ 卖掉场上的船【不】自动从备战席补人（2026-09-20）——
	#    那同样是在替玩家做「谁上场」的决定。见「已删除：auto_deploy()」。
	changed.emit()
	return {"ok": true, "reason": "", "data": {"refund": back}}


static func _cell_ok(row: int, col: int) -> bool:
	# 棋盘 11×11、我方部署区 = 下 4 行（7..10）、隔离区不可放。
	# ⚠️ 这三个数的真源在 EveBoard（COLS/ROWS/ENEMY_ROWS/ISOLATION_ROWS）。
	#    这里只做「显然不可能」的兜底拦截，真正的分区判定由调用方
	#    用 board.is_placeable_for_player() 先做一遍 —— 两份判定的职责不同：
	#    那边管「画出来的格子能不能放」，这边管「编制上允许吗」。
	return row >= 7 and row <= 10 and col >= 0 and col <= 10


## 第 (row, col) 格上站着的是 `field` 里的第几艘（空 / 越界 → −1）
##
## ★★ 2026-11-07 新增。取代原来的 `_cell_taken(ignore)` —— 那个只回答
##    「有没有人」，而互换需要知道「是谁」，否则没法把对方挪到我的格子上。
func field_index_at(row: int, col: int) -> int:
	for i in field.size():
		var c = field[i].get("cell", Vector2i(-1, -1))
		if c is Vector2i and c.x == row and c.y == col:
			return i
	return -1


## 条目 → 显示名（日志 / 互换提示用；查不到就退回 key，绝不返回空串）
static func entry_name(e: Dictionary) -> String:
	var key := String(e.get("ship_key", ""))
	var d := EveShipDatabase.by_id(key)
	return String(d.get("name", key))


## 落点预览：这一格现在能不能落（拖放时显示提示用）。
##
## ⚠️ 它存在的唯一理由是**让提示与实际结果共用一份判定**。
##    如果拖动时另写一套「能不能放」的判断，两套迟早会分叉，
##    症状是「提示说能放、松手却被拒」或者反过来 —— 玩家只会觉得游戏坏了。
##
## ★★ 2026-11-07：落点有船时返回 `swap = true` + `swap_name`，
##    让提示能说「与 死亡旋涡级 互换位置」而不是干巴巴的「移动到这里」。
##    ⚠️ 判定必须与 `deploy_from_bench` / `move_field` 一一对应：
##      · 备战席过来的互换**不看** `field_limit`（换人不换人数）
##      · 场上过来的互换要求自身有真实格号
func preview_place(row: int, col: int, source: StringName, index: int) -> Dictionary:
	if phase != Phase.PREP:
		return {"ok": false, "reason": "只有准备阶段能布阵"}
	if not _cell_ok(row, col):
		return {"ok": false, "reason": "只能放在我方部署区（棋盘下 4 行）"}
	var occ := field_index_at(row, col)
	if source == &"bench":
		if index < 0 or index >= bench.size():
			return {"ok": false, "reason": "这一格是空的"}
		if occ >= 0:
			return {"ok": true, "reason": "", "swap": true,
					"swap_name": entry_name(field[occ])}
		if field.size() >= field_limit():
			return {"ok": false, "reason": "上场已满 %d／%d" % [field.size(), field_limit()]}
		return {"ok": true, "reason": ""}
	if index < 0 or index >= field.size():
		return {"ok": false, "reason": "这一格是空的"}
	if occ >= 0 and occ != index:
		var mine = field[index].get("cell", Vector2i(-1, -1))
		if not (mine is Vector2i) or mine.x < 0:
			return {"ok": false, "reason": "这一格已经有船了"}
		return {"ok": true, "reason": "", "swap": true,
				"swap_name": entry_name(field[occ])}
	return {"ok": true, "reason": ""}


## 备战席还有没有空位（拖回预览用）
func can_recall() -> bool:
	return bench.size() < BENCH_SLOTS


## 上场的船（按上场顺序）—— 战斗场景按这个顺序造 EveShip 并摆位
func field_entries() -> Array[Dictionary]:
	return field


func bench_entries() -> Array[Dictionary]:
	return bench


## 拥有的全部船（上场 + 备战席），羁绊统计与三连合成用这一份
func all_owned() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append_array(field)
	out.append_array(bench)
	return out


func bench_used() -> int:
	return bench.size()


# ══════════════════════════════════════════════════════════════════
#  装备（2026-10-31 用户定案）
# ══════════════════════════════════════════════════════════════════
#
#  三条硬规则（都要先读 `EQUIP_SLOTS_BY_COST` 的顶注）：
#    · 槽位按**吨位**给，不看星级 —— 2★ 护卫仍然是 1 格
#    · 背包 8 格，满了掉落**直接丢弃**（不顶替已装的），并记一条日志
#    · 物品属性表待定 ⇒ `roll_equip` 只产出占位物，`apply_equips` 里明确空实现

## 这艘船能装几件装备（入参是 `cost`，也就是吨位档 1~5）。
##
## ⚠️ 越界一律夹到合法档位：`cost` 在程序临时造的船上可能是 0 或 6，
##    夹紧比让 `get()` 返回 null 再从 int(null) 崩掉要好。
static func equip_slots_for_cost(cost: int) -> int:
	return int(EQUIP_SLOTS_BY_COST.get(clampi(cost, 1, 5), 1))


## 背包里已放几件
func bag_used() -> int:
	return bag.size()


## 背包是否已满
func bag_full() -> bool:
	return bag.size() >= EQUIP_BAG_SIZE


## 往背包里放一件。满了返回 false（**不顶替、不覆盖** —— 玩家自己整理）。
func grant_equip(item: Dictionary) -> bool:
	if item.is_empty() or bag_full():
		return false
	bag.append(item)
	changed.emit()
	return true


## 取走背包第 i 件（越界返回 {}）。
func take_equip_at(i: int) -> Dictionary:
	if i < 0 or i >= bag.size():
		return {}
	var it: Dictionary = bag[i]
	bag.remove_at(i)
	changed.emit()
	return it


## 掷一件装备（占位实现）。
##
## ⚠️ **物品表还没定**（用户 2026-10-31：「我在研究装备长啥样了」）——
##    这里只保证**结构正确 + 名字可读**，好让 UI / 掉落 / 存档先跑通。
##    物品表到位后，把函数体换成「按 tier 权重查表」，其余调用点一行都不用改。
## ⚠️ `tier` 决定强度档次：普通节点 1、精英 2、BOSS 3、打捞 1。
static func roll_equip(rng: RandomNumberGenerator, tier: int = 1) -> Dictionary:
	# 占位名池：等物品表到了由它替换。命名刻意做成「未定名」的样子，
	# 免得测试截图里的假名字被当成真装备。
	var pool := ["装备·未定 A", "装备·未定 B", "装备·未定 C", "装备·未定 D"]
	var nm := String(pool[rng.randi_range(0, pool.size() - 1)])
	return {
		"id": StringName("placeholder_%d" % rng.randi_range(1000, 9999)),
		"name": nm,
		"tier": clampi(tier, 1, 3),
		# ⛔ TODO(用户物品表)：换真图标。`plus` 是现有安全值，不会缺资源。
		"icon": &"plus",
		"color": Color(0.55, 0.85, 1.0),
	}


# ══════════════════════════════════════════════════════════════════
#  羁绊（阶段 B3）
# ══════════════════════════════════════════════════════════════════
#
# ⚠️ 只统计【上场的船】—— 与云顶同口径（备战席不参与羁绊）。
#    这也是「备战席要不要留牌」这个决策的来源：留 2 张艾玛在备战席
#    不会给你任何加成，必须放上场。

## 当前生效的羁绊档位。
##
## 返回 [{group, member, count, n, text, apply, pending}]，按组的显示顺序排列。
func active_synergies() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for g in EveTraitTable.GROUPS:
		var key: StringName = g["key"]
		var counts := EveTraitTable.count(field, key)
		for m in EveTraitTable.members(key):
			var name := String(m["name"])
			var n := int(counts.get(name, 0))
			var t := EveTraitTable.tier_of(key, name, n)
			if t.is_empty():
				continue
			out.append({
				"group": key, "member": name, "count": n,
				"n": int(t["n"]), "text": String(t["text"]),
				"apply": t.get("apply", {}), "pending": t.get("pending", PackedStringArray()),
			})
	return out


## 电子战羁绊的「敌方开火间隔惩罚」系数（0 = 没凑出来，0.05 / 0.10 / 0.15 = 二/三档）。
##
## ⚠️ 这是全表**唯一**一条作用在敌方身上的羁绊 ⇒ 它**不进** `_apply_synergy`
##    （那条管道只改「自己的船」）。由 `EveFleetFactory.build_enemy()` 取用，
##    落到敌舰的 `weapon_cycle`（`cycle_scale(1 + pct)`）。
## ⚠️ 取 max 而不是累加：每档只有一个值生效（与 `tier_of` 的「替换不叠加」口径一致）。
func enemy_cycle_pct() -> float:
	var out := 0.0
	for a in active_synergies():
		if StringName(a["group"]) != &"ew":
			continue
		var apply: Dictionary = a.get("apply", {})
		out = maxf(out, float(apply.get("enemy_cycle_pct", 0.0)))
	return out


## 电子战：**被电子船锁定的那一艘**，输出要乘的衰减比例（0.3 = 削 30%）。
## 档位取值见 `eve_trait_table.gd`：2/4 艘 = 0.30，6 艘 = 0.40。
##
## ★ 2026-10-31 新增。与 `enemy_cycle_pct()` 同一条羁绊、两个不同的落点：
##   · `enemy_cycle_pct` → 敌方**全体**开火变慢（在 `build_enemy` 里一次性乘进去）
##   · `ew_lock_reduce`  → 只削「电子船当前锁定的目标」（每 tick 在模拟器里重算）
## ⚠️ 取值用 `maxf` 而不是相加：同一档位里只有一条生效，
##    相加是给「多来源同类加成」留的口子，目前没有这种来源。
func ew_lock_reduce() -> float:
	var out := 0.0
	for a in active_synergies():
		if StringName(a["group"]) != &"ew":
			continue
		var apply: Dictionary = a.get("apply", {})
		out = maxf(out, float(apply.get("ew_lock_reduce", 0.0)))
	return out


## 把生效的羁绊乘进一支舰队，返回生效清单（供 HUD / 日志用）。
##
## ⚠️ 受益范围：只有**带该羁绊的船**吃到加成（艾玛 +20% 装甲 = 场上艾玛船 +20%）。
##    CSV 没写范围，这是工程侧的一次明确选择；要改成全队受益，
##    把下面 `EveTraitTable.ship_has(...)` 那个判断去掉即可。
##
## ⚠️ 数值叠加顺序（在 EveFleetFactory.build_own 里）：
##      base → star(×1.8^Δ) → **synergy**（本函数）
##    星级在前、羁绊在后：羁绊的固定值加成（结构 +150）不会被星级放大，
##    这与「星级放大的是船本身的底子」这条口径一致。
func apply_synergies_to(fleet: Array) -> Array[Dictionary]:
	var act := active_synergies()
	if act.is_empty():
		return act
	for s in fleet:
		if not (s is EveShip):
			continue
		var ship: EveShip = s
		for a in act:
			if not EveTraitTable.ship_has(ship, a["group"], String(a["member"])):
				continue
			_apply_synergy(ship, a.get("apply", {}))
	return act


## 把「**这一支舰队自己的**羁绊」乘进这支舰队（敌方编组专用）。
##
## ⚠️ 与 `apply_synergies_to()` 的分工，别混：
##   `apply_synergies_to` 数的是 `run.field`（玩家备战区）⇒ 我方；
##   本函数数的是**传进来的舰队本身** ⇒ 敌方手写编组也能吃自己的羁绊。
##   敌方不是买来的，没有 field 名单，所以只能这么统计。
static func apply_fleet_traits(fleet: Array) -> Array[Dictionary]:
	var act := _fleet_synergies(fleet)
	for s in fleet:
		if not (s is EveShip):
			continue
		var ship: EveShip = s
		for a in act:
			if not EveTraitTable.ship_has(ship, a["group"], String(a["member"])):
				continue
			_apply_synergy(ship, a.get("apply", {}))
	return act


## 统计一支舰队自身能开到的羁绊档（口径与 `active_synergies()` 一致）
static func _fleet_synergies(fleet: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for g in EveTraitTable.GROUPS:
		var key: StringName = g["key"]
		for m in EveTraitTable.members(key):
			var name := String(m["name"])
			var n := 0
			for s in fleet:
				if s is EveShip and EveTraitTable.ship_has(s, key, name):
					n += 1
			var t := EveTraitTable.tier_of(key, name, n)
			if t.is_empty():
				continue
			out.append({
				"group": key, "member": name, "count": n,
				"n": int(t["n"]), "text": String(t["text"]),
				"apply": t.get("apply", {}),
				"pending": t.get("pending", PackedStringArray()),
			})
	return out


## 把一条羁绊的 `apply` 字典落到一艘船上
static func _apply_synergy(ship: EveShip, apply: Dictionary) -> void:
	if apply.is_empty():
		return
	var scale := {}
	var add := {}
	var armor := 1.0 + float(apply.get("armor_pct", 0.0))
	if not is_equal_approx(armor, 1.0):
		scale[&"armor"] = armor
		scale[&"hull"] = armor
	var shield := 1.0 + float(apply.get("shield_pct", 0.0))
	if not is_equal_approx(shield, 1.0):
		scale[&"shield"] = shield
	if apply.has("hull_flat"):
		add[&"hull"] = float(apply["hull_flat"])
	if apply.has("shield_flat"):
		add[&"shield"] = float(apply["shield_flat"])
	if not scale.is_empty() or not add.is_empty():
		ship.layer_hp_adjust(scale, add)

	var atk := 1.0 + float(apply.get("attack_pct", 0.0))
	if not is_equal_approx(atk, 1.0):
		ship.warhead_scale(atk)
	var cyc := 1.0 - float(apply.get("cycle_pct", 0.0))
	if not is_equal_approx(cyc, 1.0):
		ship.cycle_scale(cyc)
	var spd := 1.0 + float(apply.get("speed_pct", 0.0))
	if not is_equal_approx(spd, 1.0):
		ship.speed_scale(spd)
	# ★ 2026-10-24：穿甲（武器羁绊「激光炮 6 艘：无视 25% 装甲」）现在**真的生效**。
	#   落到 `EveShip.armor_pierce`，由模拟器传给 `EveCombatCore.apply_damage()`。
	ship.armor_pierce = maxf(ship.armor_pierce, float(apply.get("armor_pierce", 0.0)))
	# ★ 2026-10-26：后勤羁绊（放大已有维修：维修量 / 维修间隔）。
	#   ⚠️ 只对后勤船生效（`repair_scale` 内部按 `logistics_repair > 0` 拦掉）。
	if apply.has("repair_pct") or apply.has("repair_cycle_pct"):
		ship.repair_scale(1.0 + float(apply.get("repair_pct", 0.0)),
				1.0 - float(apply.get("repair_cycle_pct", 0.0)))
	# ★ 2026-10-31：电子战（锁定减伤）—— 只**记字段**，真正的乘法在模拟器里
	#   对「它当前锁定的目标」做（`EveBattleSimulator._ew_step`）。
	#   ⚠️ `is_ew` / `jam_chance` 不在这里补：干扰与羁绊**无关**（单艘电子船自带），
	#      由 `EveFleetFactory._apply_ew()` 统一写，否则 PvP 对手那条链会漏。
	if apply.has("ew_lock_reduce"):
		ship.ew_lock_reduce = maxf(ship.ew_lock_reduce, float(apply["ew_lock_reduce"]))


# ══════════════════════════════════════════════════════════════════
#  事件增益（阶段 C · 节点 4 / 10 / 14）
# ══════════════════════════════════════════════════════════════════
#
#  选项表在 `EveEventTable`（唯一真源，三个事件节点共用同一套）。
#  这里只负责「把 id 落地成数值」，以及把效果乘进舰队。

## 供事件面板使用：全部选项 + 每条是否已获取。
##
## ⚠️ 返回的是**复制品**（duplicate），面板可以随便在上面加字段，
##    不会污染常量表 —— 常量表被就地改过的话，那局结束也修不回来。
func event_options() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for o in EveEventTable.all():
		var d: Dictionary = (o as Dictionary).duplicate()
		d["taken"] = event_picks.has(StringName(d["id"]))
		out.append(d)
	return out


## 这一条现在还能不能选。
func can_pick_event(id: StringName) -> bool:
	if not EveEventTable.has_id(id):
		return false
	if event_picks.has(id) and not EveEventTable.ALLOW_REPICK:
		return false
	return true


## 落一条事件增益。返回 {} = 无效或被拒（面板因此可以放心重入）。
##
## 顺序很重要，别调换：
##   ① 先记 id（之后所有查询都以它为准）
##   ② 再落「一次性」效果（星币 / 经验 / 信标）
##   ③ 再写日志（add_xp 可能触发升级日志，晚写会被插到前面去）
##   ④ 最后 changed.emit()（HUD 重刷）
## `target` 只有「需要选船」的选项才会用到（武器调校 / 结构加固 / 双舰强化），
## 传的是**那一条 entry 本体**（`field_entries()` / `bench_entries()` 里的元素）。
## `target2` 只给「选 2 艘」的选项（`pick_count: 2`）用第二艘。
## 没给目标时**直接拒绝**（返回 {}），不静默落地一个"全队生效"的假效果。
func apply_event(id: StringName, target: Dictionary = {},
		target2: Dictionary = {}) -> Dictionary:
	if not can_pick_event(id):
		return {}
	var opt := EveEventTable.by_id(id)
	var need_n := int(opt.get("pick_count", 1))

	# ── 需要选船的：先校验目标，再落增益 ──
	# ⚠️ 校验放在 `event_picks.append` **之前** —— 否则选了个空目标却已经
	#    把这条记成"已获取"，玩家就白白损失一次事件机会。
	if bool(opt.get("pick_ship", false)):
		if target.is_empty():
			return {}
		if need_n >= 2 and target2.is_empty():
			return {}
		var star_up := int(opt.get("star_up", 0))
		if star_up > 0:
			# ★ 2026-10-30「双舰强化」：直接抬星级，不加 buff 字典
			#   （buff 是百分比加成，星级是 STAR_MULT 的整数倍 —— 两套口径别混）。
			_bump_entry_star(target, star_up)
			if not target2.is_empty():
				_bump_entry_star(target2, star_up)
		else:
			_bump_entry_buff(target, opt.get("ship_apply", {}))

	event_picks.append(id)

	var parts := PackedStringArray()
	var gain := int(opt.get("coin", 0))
	if gain > 0:
		coin += gain
		parts.append("星币 +%d" % gain)
	var per_node := int(opt.get("coin_per_node", 0))
	if per_node > 0:
		parts.append("每节点收入 +%d" % per_node)
	var exp := int(opt.get("xp", 0))
	if exp > 0:
		parts.append("经验 +%d" % exp)

	# 信标：**上限与当前值同步抬高**。
	# ⚠️ 只抬上限在满血时会变成「一点效果都没有」（100/100 → 100/120），
	#    玩家会以为选了个空牌。扩容的语义天然包含「这 20 点就是新到账的」。
	var bmax := int(opt.get("beacon_max", 0))
	if bmax > 0:
		beacon += bmax
		parts.append("信标 +%d / 上限 +%d" % [bmax, bmax])
	var heal := int(opt.get("beacon_heal", 0))
	if heal > 0:
		var before := beacon
		beacon = mini(beacon_max(), beacon + heal)
		parts.append("信标回复 %d" % (beacon - before))
	if bool(opt.get("free_advanced_roll", false)):
		free_advanced_roll()
		parts.append("免费高级刷新（保底 1 艘 cost ≥ 3）")
	# ★ 2026-10-30：「本批半价」跟着同一次高级刷新走（见 `_apply_advanced_roll_guarantee`）。
	if bool(opt.get("roll_half_price", false)):
		_pending_half_price = true
		parts.append("本批船半价")
	# ★ 2026-10-28 事件「打捞折扣」：从**下一节点**起算 N 个节点。
	#   ⚠️ 事件选完会立刻 `advance()`（node_index +1）⇒ 若这里写成「当前节点起算」，
	#      实际生效区间就会整体早一格，"未来三个回合"变成"包含本回合"。
	var dr := int(opt.get("salvage_discount_rounds", 0))
	if dr > 0:
		var base := event_clock()
		salvage_discount_from = base + 1
		salvage_discount_to = base + dr
		parts.append("未来 %d 回合打捞费：我方与敌方均 1/4 船价" % dr)
	# ★ 2026-10-31（用户定案）：事件「补给舱」—— 随机给 N 件装备。
	#   ⚠️ 逐件 `grant_equip`，满了就停（不是先判容量再全给）——
	#      否则「剩 1 格却掉进 2 件」会变成「一件都不给」。
	var eq_n := int(opt.get("equip_drop", 0))
	if eq_n > 0:
		var eq_got := 0
		for _i in eq_n:
			if grant_equip(roll_equip(rng, 2)):
				eq_got += 1
		if eq_got > 0:
			parts.append("获得 %d 件装备" % eq_got)
		if eq_got < eq_n:
			parts.append("背包已满，%d 件被丢弃" % (eq_n - eq_got))
	if bool(opt.get("pick_ship", false)) and not target.is_empty():
		var star_up2 := int(opt.get("star_up", 0))
		if star_up2 > 0 and not target2.is_empty():
			parts.append("%s / %s 各 +%d 星"
					% [_entry_name(target), _entry_name(target2), star_up2])
		elif star_up2 > 0:
			parts.append("%s +%d 星" % [_entry_name(target), star_up2])
		else:
			parts.append("%s 永久强化" % _entry_name(target))

	log_event.emit("事件增益「%s」—— %s" % [String(opt.get("name", id)),
			", ".join(parts) if not parts.is_empty()
			else EveEventTable.effect_text(opt)], &"economy")

	if exp > 0:
		add_xp(exp)

	changed.emit()
	return opt


## 已获取的增益（给 HUD 的「事件增益」窗用）。
## 元素 = {id, name, tag, icon, effect, color}
func picked_event_info() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in event_picks:
		var o := EveEventTable.by_id(id)
		if o.is_empty():
			continue
		out.append({
			"id": id,
			"name": String(o.get("name", id)),
			"tag": StringName(o.get("tag", &"")),
			"icon": StringName(o.get("icon", &"diamond")),
			"effect": EveEventTable.effect_text(o),
			"color": EveEventTable.tag_color(StringName(o.get("tag", &""))),
		})
	return out


## 给第 index 艘上场舰船挂一条**永久（本局内）**增益。
##
## 增益直接写在**那条 entry 上** —— 条目是跨节点持久的，所以"永久"天然成立，
## 不需要另开一张表去维护"哪艘船带什么"。Dictionary 是引用类型 ⇒ 就地改即可，
## 上场 ↔ 备战席之间换位也跟着走。
## ★ 2026-10-10（审查 R04）：三连合成**不再丢 buffs** —— `_merge_once()`
##    会按 key 合并三张材料的强化（见 `_merge_buffs_into`）。
func _bump_entry_buff(e: Dictionary, add: Dictionary) -> void:
	if add.is_empty() or e.is_empty():
		return
	var b: Dictionary = e.get("buffs", {})
	for k in add.keys():
		b[k] = float(b.get(k, 0.0)) + float(add[k])
	e["buffs"] = b


func _entry_name(e: Dictionary) -> String:
	var d := EveShipDatabase.by_id(String(e.get("ship_key", "")))
	return String(d.get("name", String(e.get("ship_key", "?"))))


## 把「挂在这一格上的永久增益」加到对应舰船上。
##
## `idx_map[i]` = 第 i 艘船对应的 `field` 下标（由 `_build_own_fleet` 同步维护，
## 拖放也用它）。⚠️ 必须走这张映射，不能假 ship[i] ↔ field[i] ——
## `instantiate_by_id` 失败时 `_build_own_fleet` 会 `continue`，两者就会错位。
func apply_field_buffs_to(fleet: Array, idx_map: Array[int]) -> void:
	for i in fleet.size():
		if i >= idx_map.size():
			break
		var fi := idx_map[i]
		if fi < 0 or fi >= field.size():
			continue
		var b: Dictionary = field[fi].get("buffs", {})
		if b.is_empty():
			continue
		_apply_synergy(fleet[i], b)


## 事件「黑市情报」：**免费**高级刷新，且 5 个槽位至少 1 艘 cost ≥ 3。
##
## ⚠️⚠️ 2026-10-10（审查 R05）：**登记为「一次性待应用效果」，不当场刷新**。
##
##   旧实现直接 `roll_shop()` + 替换 —— 但事件选完**同一帧**主控就调
##   `advance()` 推进节点，`advance()` 又会普通 `roll_shop()` 一次 ⇒
##   刚保底的货架被立刻覆盖，玩家看不到（复现：节点 4 事件生效
##   [4,2,1,1,1] → 推进后 [1,2,1,2,2]，保底消失，事件已被消耗）。
##   ⇒ 正确口径：记成待应用效果，等下一节点货架**定型之后**再落地
##     （见 `advance()` 末尾的 `_apply_advanced_roll_guarantee()`）。
##   ⛔ 不靠永久改 `shop_locked` 修补 —— 那会改掉玩家原本的锁店意图。
func free_advanced_roll() -> void:
	_pending_advanced_roll += 1
	log_event.emit("黑市情报：已预约高级刷新（下一节点保底 1 艘 cost ≥ 3）", &"economy")
	changed.emit()


## 货架上这一格的**原始档次**（`cost` 的本义：几费船）。
##
## ⚠️⚠️ 2026-10-30 新增。事件「黑市情报」会把报价里的 `cost` 直接覆写成半价，
##    但那只是**价钱**变了，船的档次没有变。
##    ⇒ 任何「是不是高级船 / 够不够 3 费」的判断，一律走这里，
##       ⛔ 不要再裸读 `d.get("cost")` —— 那会被半价批次骗过去。
##      （踩过：黑市保底放了艘 4 费船，紧接着半价批把它写成 2 费，
##        验收按 `cost >= 3` 判定 ⇒ 保底看起来"失效"，实际货架上就是艘 4 费船。）
static func offer_tier(d: Dictionary) -> int:
	return int(d.get("cost_base", d.get("cost", 1)))


## 把「保底 1 艘 cost ≥ 3」落到**当前**货架上（占最左的非打捞槽位）。
##
## ⚠️ 用**事后替换**而不是「重摇到满足为止」：商店 1 级时 cost ≥ 3 的概率是 0，
##    重摇会变成没有上界的死循环（交接文档 §7.2）。
## ⚠️ 替换位置固定为**最左**那个非打捞槽位（玩家视线落点，也是断言与截图的确定位置）。
## ⚠️ 对挂着的打捞船**豁免**：它是一次事件奖励，玩家并没有主动点「刷新」这个按钮，
##    「拿了个奖励，却赔掉一艘刚到手的东西」这个观感不成立。
## 由 `advance()` 在货架定型后调用。返回是否真的动了货架。
func _apply_advanced_roll_guarantee() -> bool:
	var target := -1
	for i in offers.size():
		if not salvage_slots.has(i):
			target = i
			break
	if target < 0:
		return false
	var cur = offers[target]
	# ⚠️ 读**档次**而不是 `cost` —— 货架刚被半价批改过时，`cost` 已经不等于档次了
	var cur_cost := offer_tier(cur as Dictionary) if cur is Dictionary else 0
	if cur_cost >= 3:
		return false                                  # 已经满足保底，不动它
	var cand: Array = []
	for c in range(3, 6):
		cand.append_array(_pools.get(c, []))
	if cand.is_empty():
		push_warning("[事件] 黑市保底找不到 cost ≥ 3 的船（船表为空？）")
		return false
	offers[target] = EveShipDatabase.pick_from_pool(cand, rng)
	log_event.emit("黑市情报：高级刷新落地（保底 1 艘 cost ≥ 3）", &"economy")
	return true


## ★ 2026-10-30 事件「黑市情报」：把**本批**货架全部改成半价。
## 做法是直接改报价里的 `cost`（原值留在 `cost_base` 里备查），而不是另开一个
## 「半价集合」—— 因为 `cost` 是商店卡面、买入扣费、出售返还**共用的那一个字段**，
## 另开一份就必然出现「卡面显示 1 费、买的时候扣 2 费」这类双口径漂移。
## ⚠️ 打捞品（`from_node` 标记）跳过：它的价钱在结算页付过，取货本来就是 0。
func _apply_half_price_batch() -> void:
	var n := 0
	for i in offers.size():
		if salvage_slots.has(i):
			continue
		var raw = offers[i]
		if raw == null or not (raw is Dictionary) or (raw as Dictionary).is_empty():
			continue
		var o: Dictionary = raw
		if not o.has("cost_base"):
			o["cost_base"] = int(o.get("cost", 1))
		o["cost"] = maxi(1, int(floor(float(int(o["cost_base"])) * 0.5)))
		n += 1
	if n > 0:
		offers_changed.emit()
		log_event.emit("黑市情报：本批 %d 艘船半价（费用向下取整，最低 1）" % n, &"economy")


# ══════════════════════════════════════════════════════════════════
#  舰船抽奖（炼狱专属 · 事件「黑市情报」）
# ══════════════════════════════════════════════════════════════════
#
#  ★★ 2026-10-31（用户定案，仅炼狱）：
#    「抽船事件单独做一个抽奖窗口 …… 下面会有一个许愿，让你在可能的舰船中选，
#      一星和二星舰船分开，选一个，如果真抽到了自己许愿的那个船，
#      就奖励舰船星币（二星舰船按一星舰船计价）」
#    「抽船 3 费以上舰船那个事件，添加所有种族的 2 星巡洋舰，不分定位，
#      也就是添加 12 艘 2 星巡洋舰进抽奖池」
#
#  ── 抽奖池 ─────────────────────────────────────────────────────
#    一星池 = 权威表里 cost ≥ 3 的**全部**船（巡洋 12 / 战巡 8 / 战列 12）
#    二星池 = 12 艘巡洋的 ★2 版本（4 派系 × 3 艘，**不分定位** —— 后勤也在内）
#
#  ⚠️ 二星船不是另建一份数值表：`star` 是 entry 的字段，舰队重建时
#     `EveFleetFactory.build_own` 会按 `STAR_MULT^(star-1)` 放大。
#     ⛔ 别在这里手动乘数值 —— 那就成了第二份星级口径。
#
#  ── 为什么要分池 ───────────────────────────────────────────────
#    许愿栏是「一星选一个、二星选一个」两栏。若两个愿望共用一个池，
#    玩家看到的永远是「一半的愿望不可能命中」。分池后两栏都真的有用。
#
#  ── 奖励口径 ───────────────────────────────────────────────────
#    抽中的船**免费**到手（这是奖品本身）；命中许愿再额外返还
#    **该船的一星价格**（`cost`）。二星巡洋按一星计价 ⇒ 也是 3。
#    ⚠️ 「一星价格」用的是 `EveShipDatabase.by_id().cost`（权威表原值），
#       ⛔ 不用货架上的 `cost`（那可能被黑市半价批改过）。

## 一星池的下限费用（与旧「黑市保底 cost ≥ 3」同一条线）
const LOTTERY_STAR1_MIN_COST := 3
## 二星池的船型费用（巡洋 = cost 3）
const LOTTERY_STAR2_COST := 3
## 一次抽奖抽几条。
##
## ★ 2026-10-31（用户定案）：**1 艘**。合并池后我一度沿用了"两池各抽一次"的
##   总产出（2 艘），用户明确否掉：「玩家抽到的是两艘，这不对，得是一艘，
##   不然奖励就太丰厚了」。奖品的定位是**彩头**，不是白送一艘 3 费船。
const LOTTERY_DRAW_TIMES := 1


## 本局有没有抽奖机制（= 难度档开了 `event_lottery`，当前只有炼狱）。
func event_lottery_enabled() -> bool:
	return bool(difficulty_row().get("event_lottery", false))


## 这一条事件选完要不要开抽奖窗口。
##
## ⚠️ 两个条件缺一不可：难度档允许（炼狱）+ 事件自己声明 `opens_lottery`。
##    ⛔ 只判难度会让**任何**带 select 的事件都弹窗；只判事件则普通档也弹。
func can_open_lottery(id: StringName) -> bool:
	if not event_lottery_enabled():
		return false
	return bool(EveEventTable.by_id(id).get("opens_lottery", false))


## 抽奖候选池 —— **一个池子**（一星 32 艘 + 二星 12 艘，靠每项的 `star` 字段区分）。
##
## ★ 2026-10-31 用户纠正：「一星二星全部进一个池子……二星不是单独的池子，
##   玩家只能选一艘」。第一版做成了「两栏两池、各许一个愿」，与这条不符。
##
## ⚠️ 合并后**必然有 12 对同名条目**：一星池是「cost ≥ 3 的全量」，本来就含
##    cost == 3 的那 12 艘巡洋；二星池又是同样这 12 艘的 ★2 版本。
##    ⇒ 同一 `ship_key` 会在池子里出现两次（star 1 和 star 2）。
##    UI 拿 `ship_key` 当卡片键会互相覆盖，必须用 `ship_key#star` 复合键
##    （见 `eve_lottery.gd` 的 `_card_id`）。
##    ⇒ 许愿也必须是「船 + 星级」精确匹配，否则没法表达"我要二星那艘"。
##
## 返回的是 `derive()` 产物 + 一个 `star` 字段（UI 直接拿去画卡）。
## ⚠️ 每次调用都 `duplicate()` —— UI 会往卡上写 `wished` 之类的临时键，
##    就地改会污染 `_pools` 这个**跨回合复用**的派生缓存。
func lottery_pool() -> Array[Dictionary]:
	_build_pools()
	var out: Array[Dictionary] = []
	# ① 一星：cost ≥ 3 全量（巡洋 12 + 战巡 8 + 战列 12 = 32）
	for c in range(LOTTERY_STAR1_MIN_COST, 6):
		for row in _pools.get(c, []):
			var d1: Dictionary = (row as Dictionary).duplicate()
			d1["star"] = 1
			out.append(d1)
	# ② 二星：巡洋的 ★2 版本（4 族 × 3 = 12，不分定位，后勤也在）
	for row in _pools.get(LOTTERY_STAR2_COST, []):
		var d2: Dictionary = (row as Dictionary).duplicate()
		if int(d2.get("cost", 0)) != LOTTERY_STAR2_COST:
			continue
		d2["star"] = 2
		out.append(d2)
	return out


## 抽一次（从上面那个**合并池**里等概率抽一条）。`wish` = 玩家许愿的船。
##
## 返回 `{ok, star, ship_key, name, cost, hit, reward, placed}`；
## `ok == false` 表示池子是空的（数据异常），调用方不该当成"抽到空"。
## `placed`：`bench` 进备战席 / `coin` 备战席满了折成星币。
##
## ⚠️ 一次调用**只掷一次** `pick_from_pool`（内部可能消费一次 randf）——
##    抽两次 = 调两次，否则复现性没法对账。
##
## ⚠️ 命中判定是 `ship_key` **且** 星级都对上（`wish_star`）。
##    不能只比 `ship_key`：同名的 ★1 / ★2 在池子里是**两个不同奖品**
##    （数值差 STAR_MULT 倍），只比名字会让"许愿一星巡洋却抽到二星"
##    也算命中 —— 那样许愿里那个星级选择就没有意义了。
##    `wish_star <= 0` = 不区分星级（目前没有调用方这么用，留给调试）。
func lottery_draw(wish_key: StringName = &"", wish_star: int = 0) -> Dictionary:
	var pool := lottery_pool()
	if pool.is_empty():
		push_warning("[抽奖] 池子为空 —— 船表或费用档有问题")
		return {"ok": false}
	var got := EveShipDatabase.pick_from_pool(pool, rng)
	if got.is_empty():
		return {"ok": false}
	var key := StringName(got.get("ship_key", &""))
	var st := clampi(int(got.get("star", 1)), 1, MAX_STAR)
	var placed := _lottery_grant(key, st)
	# 奖励按**一星价格**（权威表 cost）—— 「二星按一星计价」说的就是这里。
	var base_cost := int(EveShipDatabase.by_id(String(key)).get("cost", 0))
	var ship_name := String(got.get("name", "?"))
	# ① 备战席满了拿不到船 ⇒ 折成该船的一星价格（与许愿奖励**分开记**，
	#    两者是两笔钱：一笔是补偿，一笔是彩头）。
	if placed == "coin":
		coin += base_cost
		log_event.emit("抽奖：%s ★%d 无处安放（备战席已满）⇒ 折成 %d ◆"
				% [ship_name, st, base_cost], &"economy")
	else:
		log_event.emit("抽奖：获得 %s ★%d → 备战席" % [ship_name, st], &"buy")
	# ② 许愿命中（船 + 星级都对上）
	var hit := wish_key != &"" and key == wish_key \
			and (wish_star <= 0 or wish_star == st)
	var reward := 0
	if hit and base_cost > 0:
		reward = base_cost
		coin += reward
		log_event.emit("许愿命中「%s」★%d —— 额外奖励 %d ◆（按一星价格）"
				% [ship_name, st, reward], &"economy")
	changed.emit()
	return {
		"ok": true,
		"star": st,
		"ship_key": key,
		"name": ship_name,
		"cost": base_cost,
		"hit": hit,
		"reward": reward,
		"placed": placed,
	}


## 把抽到的船落到玩家手里：优先进备战席，满了折成星币（由调用方加钱）。
##
## ⚠️ 不往货架塞：货架的每一格都跟"玩家花不花钱、要不要刷新"绑定，
##    免费奖品插进去会引出「这格是不是我买的」「刷新会不会刷掉它」一整套歧义。
##    备战席满是一种**罕见**状态，折价补偿比制造歧义干净得多。
func _lottery_grant(key: StringName, star: int) -> String:
	if key == &"":
		return "coin"
	if bench.size() < BENCH_SLOTS:
		bench.append(_make_entry(key, star))
		return "bench"
	return "coin"


## 给一条 entry 抬星级（事件「双舰强化」用）。最高 `MAX_STAR`。
##
## ⚠️ 只改 entry 的 `star` —— 舰队是**每回合从 entry 重建**的
##    （`EveFleetFactory.build_own` 按 star 走 `STAR_MULT^Δ`），
##    所以不需要在这里碰任何舰船实例。
func _bump_entry_star(e: Dictionary, n: int) -> void:
	if e.is_empty() or n == 0:
		return
	e["star"] = clampi(int(e.get("star", 1)) + n, 1, MAX_STAR)


## 事件带来的「每节点收入」增量
func event_coin_per_node() -> int:
	var sum := 0
	for id in event_picks:
		sum += int(EveEventTable.by_id(id).get("coin_per_node", 0))
	return sum


## ⛔ 2026-10-01 删除：原来有个 `event_leak_reduce()`（事件减免漏网伤害）。
##    漏网机制整个删掉了，而按交接文档 §7.2 重写的四条事件**本来就没有**
##    `leak_reduce` 字段 ⇒ 它恒为 0，是死代码。以后要做「减伤」类事件，
##    直接在这里加一个新的减免项挂在 `loss_damage()` 上即可。


## 信标上限（事件可以把上限抬高）
func beacon_max() -> int:
	var add := 0
	for id in event_picks:
		add += int(EveEventTable.by_id(id).get("beacon_max", 0))
	return START_BEACON + add


## 把事件增益乘进一支舰队。
##
## ⚠️ 与 `apply_synergies_to` 的**关键差别**：羁绊只加在「带该羁绊的船」上，
##    而事件增益是**全队**的（面板文案写的是「全队」）。
##    两个函数都复用 `_apply_synergy` 那套键，所以数值口径（乘法叠加）一致。
##
## 叠加顺序（在 `EveFleetFactory.build_own` 里）：
##      base → star(×1.8^Δ) → 羁绊 → **事件增益**
##    事件放在最后：它是玩家用「事件机会」换来的，不该被星级反算进去。
func apply_events_to(fleet: Array) -> Array[Dictionary]:
	var act := picked_event_info()
	if act.is_empty():
		return act
	for s in fleet:
		if not (s is EveShip):
			continue
		var ship: EveShip = s
		for a in act:
			var o := EveEventTable.by_id(a["id"])
			_apply_synergy(ship, o.get("apply", {}))
	return act


# ══════════════════════════════════════════════════════════════════
#  节点与回合
# ══════════════════════════════════════════════════════════════════

func current_node() -> Dictionary:
	return EveNodeTable.by_index(node_index)


func node_type() -> StringName:
	var n := current_node()
	return StringName(n.get("type", &"battle")) if not n.is_empty() else &"battle"


func stage_label() -> String:
	return EveNodeTable.label_of(node_type())


## 本节点的战斗时限（秒）。事件节点返回 0。
##
## ★ 2026-10-28：兜底值 45 → `EveNodeTable.BATTLE_SECONDS`（60）。
##   联机模式下 `node_index` 不推进（见 `eve_battle_scene.gd` 的注释），
##   一旦索引越界就会走兜底 —— 硬编码 45 会让人误以为「联机还是 45 秒」。
func battle_seconds() -> float:
	var n := current_node()
	return float(n.get("time", EveNodeTable.BATTLE_SECONDS)) if not n.is_empty() \
			else EveNodeTable.BATTLE_SECONDS


## 本节点的编组 id。
##
## ★ 2026-10-27：分两条路 ——
##   · 难度档 `random_comps = true`（普通/困难/炼狱）⇒ 走 `EveEnemyPlans`
##     的程序化配方，现摇一副并登记，返回 `gen_N{节点号}`。
##     ⛔ 只有简单档是 `false`（用户要求「简单就现在的不变」），它继续用
##        节点表里的静态编组 —— 也是 verify_run 里两条既有锚点的载体。
##   ⚠️ 旧的 `comp_overrides`（按节点号换静态编组的替换表）**已废止**：
##      普通/困难/炼狱现在共用同一套配方，差别只剩倍率与羁绊。
func enemy_comp_id() -> String:
	var n := current_node()
	if n.is_empty():
		return ""
	if bool(difficulty_row().get("random_comps", false)):
		return _ensure_random_comp()
	return String(n.get("comp", ""))


## 程序化编组的随机种子 = `(本局基准, 节点号)`。
##
## ⚠️ **不含难度** —— 这是「困难与普通的舰船随机相同」的结构保证
##    （用户原话：「困难难度的舰船随机与上面的相同」）。别把 difficulty 混进来。
## ⚠️ 用 `* 7919` 式的质数错位，与 `battle_seed()` 同一手法，避免
##    相邻节点号摇出高度相关的编组。
func enemy_roster_seed() -> int:
	var src := comp_source_node if comp_source_node > 0 else node_index
	return absi(_comp_seed_base * 104729 + src * 7919) + 1


## 确保当前节点的程序化编组已摇出并登记，返回它的 comp_id。
##
## ⚠️ 幂等：同一节点重复调用只会登记一次（`_gen_comps` 挡住），
##    ⇒ HUD 每次刷新都拿得到同一批船，不会"看一眼就换一批"。
## 多人对战：把本回合的编组来源指定成另一个节点号。
## 0 = 不覆盖（用当前节点号）⇒ 单机永远为 0，行为不变。
##
## ⚠️ 为什么需要它：多人是「阶段 x 回合」，PvE 回合要按用户配的节点取编组
##    （见 EveMatchState.PVE_SOURCE_NODE）。直接改 node_index 会连带改动
##    败亡代价 / 事件 / 阶段标签等一堆东西，所以只覆盖「编组来源」这一件事。
var comp_source_node := 0


func _ensure_random_comp() -> String:
	var src := comp_source_node if comp_source_node > 0 else node_index
	var comp_id := "gen_N%d" % src
	if _gen_comps.has(comp_id):
		return comp_id
	var plan := EveEnemyPlans.build(src, enemy_roster_seed())
	if plan.is_empty():
		# 配方缺失（比如把某个战斗节点漏配了）⇒ 退回节点表静态编组。
		# ⚠️ 这里**故意不报错也不留半截状态**：退化成静态编组至少还能打，
		#    而报错会让整局卡死。数据层已由 `EveEnemyPlans.validate()` 兜底喊话。
		return String(current_node().get("comp", ""))
	EveEnemyComps.register_runtime(comp_id, String(plan["name"]),
			String(plan["formation"]), plan["ships"])
	_gen_comps[comp_id] = true
	return comp_id


func enemy_comp_name() -> String:
	return EveEnemyComps.display_name(enemy_comp_id())


func enemy_comp_size() -> int:
	return EveEnemyComps.size_of(enemy_comp_id())


## 本节点敌方强度 = 节点表 scale × 难度档的**单值**倍率。
##
## ★★ 2026-10-24（阶段 A）：**删掉三段爬升**（`SCALE_PLATEAU_FROM/TO`）。
##
##   旧口径是「节点 1→6 线性升到 scale_mid，6→10 保持，10→15 升到 scale_late」，
##   也就是**用敌人面板来造难度**。实测它造不出难度阶梯，只造出两个台阶：
##      · 乱点（spam）与认真玩（comp）的胜率几乎一样 —— 难度是常数，
##        不随玩家的任何决策变化，所以"认真玩"学不到东西；
##      · 死亡集中堆在两个台阶上（节点 5 与 13），玩家体感是"某关突然被秒"。
##
##   现在的口径：**节点表自己的 scale 已经写出了 15 关的强度梯度**
##   （1.00 → 1.30），难度档只再乘一个贴地的系数（1.00~1.25）。
##   难度改由「同一个失误的代价随进程上涨」承担（见 `loss_damage` /
##   `EveCampaignTiers` 的 `loss_curve`）—— 那才是玩家能感知、能学习的东西。
##
## ⚠️ 节点 1 的节点表 scale 恒为 1.00 ⇒ 第一关永远没有难度倍率（除档位系数）。
func enemy_scale() -> float:
	var n := current_node()
	var base := float(n.get("scale", 1.0)) if not n.is_empty() else 1.0
	return base * float(enemy_tier_row().get("scale", 1.0))


## ★ 2026-10-30：BOSS 主坦（cost ≥ 5 的加强型战列）的**额外**数值系数。
##
## 真源 = `EveNodeTable.ROWS[].bs_damp`（目前只有第 15 关写了 0.78）。
## ⚠️ 乘在 `enemy_scale()` **之外**、且只给 cost ≥ 5 的那一艘（调用点见
##    `EveFleetFactory.build_enemy`）—— 整节点一起削会把 BOSS 战的编排削没。
func boss_bs_damp() -> float:
	var n := current_node()
	if n.is_empty():
		return 1.0
	return clampf(float(n.get("bs_damp", 1.0)), 0.3, 1.0)


## 本节点的进场词（唯一真源 = EveNodeTable.ROWS[].line）。
##
## ⚠️ 转公开是给「节点进场字幕」用的 —— 在那之前场景侧是自己去读
##    `current_node().get("line")` 的，那种取法一多就会有人顺手改措辞。
func entry_line() -> String:
	var n := current_node()
	return String(n.get("line", "")) if not n.is_empty() else ""


## 当前节点的敌方编组（派生数据，尚未实例化）。
##
## ⚠️ 每次调用都返回**新造的数据**，调用方每次都要新造 EveShip ——
##    上一节点打残的血量绝不能带到下一节点，这是自走棋的基本盘。
func enemy_roster() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in EveEnemyComps.ship_ids(enemy_comp_id()):
		var d := EveShipDatabase.by_id(String(id))
		if not d.is_empty():
			out.append(d)
	return out


## 下回合收入 = 基础 + 利息 + 事件每节点 + **难度逐节点奖励**
##
## ★ 2026-10-31（用户定案）：炼狱的利息门槛从 10 降到 9。
##   门槛走难度档的 `interest_step`（缺省回退 `INTEREST_STEP` = 10），
##   ⛔ 别把 9 写成全局常量 —— 只有炼狱该吃这个便宜。
##
## ★★ 2026-10-31 二次定案（覆盖上面的 9）：
##   · 门槛 9 → **3**（每 3 星币 1 利息），仍只走炼狱的 `interest_step`。
##   · **取消上限**：难度档把 `interest_max` 填成 `-1` ⇒ 这里 `cap < 0` 直接返回
##     「不夹」的结果。其余三档 `interest_max` 仍是 5，行为一字未变。
##   ⚠️ `-1` 这个哨兵值只能在**难度档**出现；全局常量 `INTEREST_MAX` 仍是 5，
##      它只作 `row` 缺字段时的回退，⛔ 别把它也改成 -1（那会让所有档都无上限）。
func interest() -> int:
	var row := difficulty_row()
	var cap := int(row.get("interest_max", INTEREST_MAX))
	var step := maxi(1, int(row.get("interest_step", INTEREST_STEP)))
	var base := int(floor(float(coin) / float(step)))
	if cap < 0:
		return base
	return mini(base, cap)


func income() -> int:
	var base := int(difficulty_row().get("base_income", BASE_INCOME))
	return base + interest() + event_coin_per_node() + node_income_bonus()


## 难度档给的「逐节点收入奖励」。
##
## ★ 2026-10-31（用户定案）：炼狱节点 6~10 每关 +1、11~15 每关 +2。
##   取值理由见 `EveCampaignTiers.DIFFICULTIES` 炼狱块内 `node_income_bonus` 的注释。
##
## ★★ 2026-10-31 二次定案：整条曲线抬成 1/2/3，并且**15 关之后不断供**。
##   用户原话：「如果15回合每过，又重打15回合，也要给到这3星币」。
##
## ⚠️ 按 `node_index` 取（不是 `event_clock()`）：收入是在 `advance()` **推进之后**
##    才发的，那一刻 `node_index` 就是「即将进入的节点」——
##    节点 6 的 +1 落在进入节点 6 的那次结算里，正是玩家理解的「这一关多给一币」。
##
## ⚠️⚠️ **超出数组长度时钳到最后一格**（而不是返回 0）：
##    15 关打完重打第二轮时 `node_index` 会变成 16、17…… 旧写法
##    `node_index <= curve.size()` 会让第二轮起一分不加 —— 那等于"重打反而变穷"，
##    玩家的体感是经济突然断供。现在统一按末档（3）继续发。
## ⚠️ 空数组 / 老存档没有这个字段 ⇒ 返回 0（其余三档就是这条路）。
func node_income_bonus() -> int:
	var curve: Array = difficulty_row().get("node_income_bonus", [])
	if curve.is_empty() or node_index < 1:
		return 0
	var idx := mini(node_index, curve.size()) - 1
	return maxi(0, int(curve[idx]))


# ══════════════════════════════════════════════════════════════════
#  战斗结算
# ══════════════════════════════════════════════════════════════════

## 战败的信标代价。
##
## ⛔ 2026-10-01：这里原来还 +Σ「漏网舰船费用」，那个概念已删除。
##    它让「我 3 艘全活却因为敌人没死光而掉血」这件事变得无法解释，
##    而它对玩家的**唯一**作用就是制造这种困惑。
##
## ★★ 2026-10-24（阶段 A）：**改成读难度档的 `loss_curve`**（逐节点）。
##
##   为什么必须逐节点、而不是「阶段定值 × 难度倍率」：
##     旧口径下，节点 3 输和节点 13 输**一样疼**（都是 battle 8 × 倍率）。
##     于是「后期的每个失误都不比前期贵」⇒ 玩家没有理由认真规划，
##     乱点与认真玩的胜率自然一样（实测普通档 spam 94% / normal 69%）。
##
##     云顶之弈那条设计线（玩家伤害 0/2/5/7/9/11/17/150，血 100）说的是：
##     **同一个失误的代价随进程上涨**。所以现在代价表是 15 个数字，
##     曲线形状 = 前四关几乎免费 → 中盘稳步加码 → 末段精英/BOSS 一输掉一大块。
##
##   ⚠️ `LOSS_BASE`（阶段定值）保留为本函数的**回退**：曲线缺失或越界时
##     仍旧按「阶段 × loss_mult」算，老存档与老验收点不会因为缺字段而炸。
func loss_damage() -> int:
	var curve: Array = difficulty_row().get("loss_curve", [])
	if node_index >= 1 and node_index <= curve.size():
		return maxi(0, int(curve[node_index - 1]))
	# ── 回退：没有曲线时走旧公式（阶段定值 × 难度倍率）──────────────
	var base := int(LOSS_BASE.get(node_type(), 8))
	var mult := float(difficulty_row().get("loss_mult", 1.0))
	return int(roundf(float(base) * mult))


## 连败追加伤害。`lose_streak` 已在 `resolve_battle` 里加过本场，
## 所以第一场（= 1）返回 0。
func loss_streak_bonus() -> int:
	if lose_streak <= 1:
		return 0
	return mini((lose_streak - 1) * LOSS_STREAK_STEP, LOSS_STREAK_BONUS_MAX)


## 战败代价预测 —— 开战前挂在顶条上的那个数字（硬核判据 H2：代价必须提前可见）
##
## ⚠️ 算的是「**这一场真的输了**会掉多少」⇒ 必须带上连败加成，
##    否则顶条上的数字会比实际少，那就违背了「代价提前可见」这条判据。
##    （战胜 = 0 伤害，顶条写的是「战败 −N」，语义本来就是"最坏情况"。）
func loss_preview() -> int:
	return loss_damage() + loss_streak_bonus()


## 取费用。裸 int 直接当费用（漏怪单测里允许只传数字）。
## 「怎么算一艘船」交给 `_as_ship_dict`（唯一判定处），这里不自己再认一遍。
## ⛔ 2026-10-01 删除：这里原来有个 `_cost_of()`，它**只**服务于已删除的
##    「Σ 漏网舰船费用」那一项。别再照着它加回来。
##    （`_as_ship_dict` 打捞还在用，保留。）

## 一帧一帧的伤害倍率（数值叠加顺序见 apply_enemy_scaling）
##
## destroyed = 本节点**被击毁**的敌舰（EveShip / Dictionary / ship_key 混着放都行）。
## 它只用来生成残骸（打捞），不参与信标记账 —— 信标只按「输没输」算。
##
## ⚠️ 2026-10-01 新增两个**可选**关键字参数（不是位置参数，别调换）：
##   `sources[i]` 与 `destroyed[i]` 一一对应，是本节点第 i 艘敌舰的
##     {"star","atk_base","def_base","m"} —— 结算那一刻的原始证据。
##     不传时自动退化为「现查船表 + 按 power_scale 假定」。
##   `power_scale` = 本节点敌方倍率，`sources` 缺失时用它倒推。
##   两者都缺省时行为与旧版一致（验收里的老调用点不用改）。
##
## ★★ 2026-10-27 新增第 5 个**可选**参数 `lost_field`（同样别当位置参数乱插）：
##    阵亡的我方舰船在 `field` 里的**下标**列表。结算时按它把这批船从编队移除。
##    理由见函数体内的长注释（不传 = 旧行为不变）。
func resolve_battle(winner_team: int, destroyed: Array = [],
		sources: Array = [], power_scale: float = 1.0,
		lost_field: Array[int] = []) -> Dictionary:
	if phase == Phase.ENDING:
		return {}
	var won: bool = winner_team == 0

	# ⚠️ 顺序：**先更新连胜/连败，再算伤害** —— 伤害里的「连败递增」要用到本场。
	if won:
		win_streak += 1
		lose_streak = 0
	elif winner_team == 1:
		lose_streak += 1
		win_streak = 0
	# 平局（-1）两边都不动 —— 云顶也是这个口径

	# ★★ 战胜 = **零代价**（2026-10-01 修的致命 bug）
	#
	# 原来这里是无条件 `beacon -= leak_damage(leaked)`，而 `leak_damage()` 里
	# （`leak_damage` 现名 `loss_damage`，且不再接 leaked 参数）
	# 「类型基础伤害」那一项是**永远加上**的（battle 2 / elite 3 / boss 4）
	# ⇒ **全歼敌人也每回合掉 2~4 点信标**，15 个节点光这一项就掉 30~45。
	# 玩家原话：「为啥我打赢了信标还是会掉血啊？这不是有病吗，
	#            守卫成功了信标还掉血，那我不是白守卫了？」
	#
	# 现在的口径：**赢 = 不掉血**；打输了按「阶段定值 + 连败递增」扣。
	var dmg := 0
	if not won:
		dmg = loss_damage() + loss_streak_bonus()
	var before := beacon
	beacon = maxi(0, beacon - dmg)
	last_won = won
	log_event.emit("节点 %d 结算：%s · 信标 %d → %d"
			% [node_index, "拦截成功" if won else "拦截失败",
			before, beacon],
			&"economy" if won else &"damage")
	if win_streak >= 2:
		log_event.emit("连胜 %d" % win_streak, &"hint")
	elif lose_streak >= 2:
		log_event.emit("连败 %d" % lose_streak, &"hint")

	# 每完成一个节点自动 +2 经验（交接文档 §5.3 NODE_XP_REWARD）
	add_xp(NODE_XP_REWARD)

	# 残骸：击毁的敌船里最贵的一艘（旧的没下单的残骸在这里作废）
	_set_wreck_from(destroyed, sources, power_scale)

	# ── 阵亡的我方舰船：**从编队里移除**（2026-10-27 用户口径）──────────
	#
	# 用户原话：「我的船被击毁后，又回到了舰船队列，这不对，要回来只能通过
	# 打捞系统付费打捞回来」。
	#
	# ⚠️ 为什么必须在这一处收口：`EveFleetFactory.build_own()` 每个准备阶段都
	#    从 `field_entries()` **重建**舰队 —— 只要 `field` 里还留着这艘船，
	#    下一个准备阶段它就会照常出现在战场上、照常吃羁绊，等于"没死过"。
	#    而 `field` 在本函数之前**从不被这场战斗改动**（只有 deploy / recall /
	#    sell / merge 动它）⇒ 不在这里删，就没有任何地方会删。
	#
	# ⚠️ `lost_field` 是 `field` 的**下标**（调用方用 fleet→field 的 idx_map 算出，
	#    见 `EveFleetFactory.last_idx_map`）。移除必须**降序**：
	#    先删前面的会让后面的下标整体前移 ⇒ 删错船（最隐蔽的一类错）。
	#
	# ⚠️ 只在 `lost_field` 非空时动手 ⇒ 老的调用点（不传这个参数）行为一字不变。
	if not lost_field.is_empty() and not field.is_empty():
		var idxs: Array[int] = lost_field.duplicate()
		idxs.sort()
		idxs.reverse()
		var lost_names := PackedStringArray()
		for i in idxs:
			if i < 0 or i >= field.size():
				continue
			var e: Dictionary = field[i]
			var d := EveShipDatabase.by_id(String(e.get("ship_key", "")))
			lost_names.append("%s★%d" % [String(d.get("name",
					String(e.get("ship_key", "?")))), int(e.get("star", 1))])
			field.remove_at(i)
		if not lost_names.is_empty():
			log_event.emit("我方 %d 艘被击毁，已移出编队（%s）—— 可在结算页付费打捞"
					% [lost_names.size(), ", ".join(lost_names)], &"damage")

	# ★ 2026-10-31（用户定案）：精英 / BOSS 战**必掉**一件装备。
	#   ⚠️ 只在**赢**的时候掉：打输连残骸都要花钱捞，再送装备等于奖励失败。
	#   ⚠️ 普通 battle 节点不掉 —— 用户只点名了「精英怪和 BOSS 必掉」，
	#      其余两个渠道是「事件」与「打捞 5%」，三个渠道互不重叠。
	var eq_drop := _node_equip_drop(won)
	if not eq_drop.is_empty():
		if grant_equip(eq_drop):
			log_event.emit("获得装备：%s（背包 %d/%d）"
					% [String(eq_drop["name"]), bag_used(), EQUIP_BAG_SIZE], &"economy")
		else:
			# ⚠️ 满了就是丢弃，**不顶替**背包里已有的 —— 让玩家自己整理，
			#    否则「背包满了」会变成「莫名其妙少了一件我想要的」。
			log_event.emit("背包已满（%d/%d），装备 %s 被丢弃"
					% [EQUIP_BAG_SIZE, EQUIP_BAG_SIZE, String(eq_drop["name"])], &"hint")

	phase = Phase.RESOLVE
	phase_changed.emit(phase)
	changed.emit()
	return {"damage": dmg, "beacon": beacon, "won": won,
			"wreck": not wrecks.is_empty(),
			"wreck_count": wrecks.size()}


## 结算结束 → 推进节点（或收束到结局）
func advance() -> void:
	if phase == Phase.ENDING:
		return
	if beacon <= 0:
		_finish(false)
		return
	var at_last := node_index >= EveNodeTable.TOTAL
	if at_last and last_won:
		_finish(true)
		return
	# ★ 第 15 节点**打输了 ⇒ 重打**（交接文档 §5.4「BOSS 重打不推进节点」）。
	#
	# ⚠️ 原来这里是无条件 `_finish(true)` —— 打输了 BOSS 也照样算通关。
	#    那是本次修掉的一个真 bug，不只是手感问题。
	#    重打照常结算收入与商店（等于多给一个准备回合），
	#    直到打赢、或信标归零撤离（`beacon <= 0` 那条在上面拦住了）。
	if at_last:
		boss_attempts += 1
		log_event.emit("BOSS 重打 —— 节点不推进（第 %d 次重试）" % boss_attempts, &"hint")
	else:
		node_index += 1
	var inc := income()
	coin += inc
	# ★ 2026-10-31：日志补上「关卡奖励」那一段（炼狱专属）。
	#   基础收入也顺手改成读难度档 —— 原来硬写 `BASE_INCOME`，
	#   哪天一档把 base_income 调成 6，日志就会和实际到账对不上。
	var inc_parts := PackedStringArray([
			"基础 %d" % int(difficulty_row().get("base_income", BASE_INCOME)),
			"利息 %d" % interest()])
	if event_coin_per_node() > 0:
		inc_parts.append("事件 %d" % event_coin_per_node())
	if node_income_bonus() > 0:
		inc_parts.append("关卡奖励 %d" % node_income_bonus())
	log_event.emit("收入 +%d（%s）" % [inc, " · ".join(inc_parts)], &"economy")
	# 打捞的两步，顺序不能换：
	#   ① 先让上一节点的修复品**过期**（没买走就没了，并解锁槽位）；
	#   ② 再让本节点的到账**落位**（占掉槽位、记进 salvage_slots）。
	# 反过来的话，上一件还没买走的修复品会被新到账的覆盖掉 —— 玩家付了钱却看不到东西。
	_expire_repairs()
	if shop_locked:
		log_event.emit("加速列表已锁定，沿用上一轮报价", &"hint")
		# 锁定态下不重摇，但上一段可能刚重摇过个别槽位（过期清理），
		# 这是对的：过期的是「该消失的东西」，与锁不锁定无关。
	else:
		roll_shop()
	_deliver_repairs()
	# ★ 2026-10-10（审查 R05）：黑市预约的「保底 cost ≥ 3」必须在货架**定型之后**
	#   才落地 —— 也就是 `roll_shop()`（本节点重摇）与 `_deliver_repairs()`
	#   （到账占位）都做完之后。早一步都会被覆盖或顶掉。
	if _pending_advanced_roll > 0:
		_pending_advanced_roll = 0
		if _apply_advanced_roll_guarantee():
			offers_changed.emit()
	# ★ 2026-10-30：半价跟同一次黑市刷新一起落地（顺序在保底之后 ——
	#   保底会**替换**最左那一格，先标半价再替换就会漏掉那一艘）。
	if _pending_half_price:
		_pending_half_price = false
		_apply_half_price_batch()
	log_event.emit("节点 %d／%d · %s · %s"
			% [node_index, EveNodeTable.TOTAL, stage_label(), entry_line()], &"hint")

	phase = Phase.PREP
	phase_changed.emit(phase)
	changed.emit()


func _finish(cleared: bool) -> void:
	ending = Ending.CLEARED if cleared else Ending.EVACUATED
	phase = Phase.ENDING
	if cleared:
		log_event.emit("全部 %d 个节点通过 —— 守卫成功，增援已到" % EveNodeTable.TOTAL, &"economy")
	else:
		log_event.emit("信标归零 —— 撤离（止步于节点 %d／%d）"
				% [node_index, EveNodeTable.TOTAL], &"damage")
	phase_changed.emit(phase)
	run_ended.emit(cleared)
	changed.emit()


func set_phase(p: int) -> void:
	phase = p
	phase_changed.emit(phase)
	changed.emit()


# ══════════════════════════════════════════════════════════════════
#  敌方数值叠加（交接文档 §6.4 冻结顺序：base → star → power_scale）
# ══════════════════════════════════════════════════════════════════

## 把星级与 power_scale 叠到一艘船上。
##
## ⚠️ 两条口径不能改：
##   ① 顺序是 base → star(×1.8^Δ) → power_scale（先乘星级，再乘关卡缩放）
##   ② power_scale **只放大 atk / shield / armor**，不碰 speed / atk_speed / atk_range。
##      这里的「armor」是权威表的合并列（装甲/结构），
##      所以 armor 与 hull 两层一起放大 —— 它就是那一列的拆分结果。
static func apply_enemy_scaling(ship: EveShip, star: int, power_scale: float) -> void:
	if ship == null:
		return
	var s: float = pow(STAR_MULT, float(maxi(0, star - 1))) * maxf(0.01, power_scale)
	if is_equal_approx(s, 1.0):
		return
	ship.warhead_scale(s)
	ship.armor_scale(s)


# ══════════════════════════════════════════════════════════════════
#  工具
# ══════════════════════════════════════════════════════════════════

static func _deny(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "data": {}}


## 给 UI 一行摘要（顶条 / 自检用）
func summary() -> String:
	return "节点 %d/%d · Lv.%d(%d/%d) · 星币 %d · 信标 %d · 上场 %d/%d" % [
		node_index, EveNodeTable.TOTAL, level, xp_in_level(), xp_need(),
		coin, beacon, field.size(), field_limit(),
	]
