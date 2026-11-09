extends RefCounted

## [⚠️ 刻意不写 class_name] 全局类表在**引擎启动时**读，
## 和 autoload 一样会让老客户端解析失败（见 sc_context.gd 的说明）。
## 使用方一律 `const ADAPTER := preload("res://scripts/starchess/sc_ship_adapter.gd")`。

## 星舰万象棋 —— 舰船适配层
##
## [WHY] 星舰万象棋需要的是"自走棋卡池"，EVE 工程有的是"战斗数值表"。
##   两边字段语义不同（tier vs cost、hp vs shield+armor），但**数据源必须唯一**：
##   ⛔ 不要在星舰万象棋里另抄一份舰船表 —— 那会立刻和 EVE 侧平衡脱钩。
##   ⇒ 本文件是唯一的翻译层：EveShipTable.ROWS → 自走棋卡池条目。
##
## [SRC] 数据源：scripts/data/eve_ship_table.gd 的 ROWS（52 艘）
## [SRC] 立绘：assets/ships/<id>.png —— id 直接可用，无需映射

const TABLE := preload("res://scripts/data/eve_ship_table.gd")

## 四帝国 → 自走棋流派（一个流派一个主帝国 + 可能的副帝国）
##
## ⚠️ 这里只是**初始归属**。用户 2026-11 说流派之后再定，
##    所以先用「帝国 = 流派」的直连，改流派只动这张表。
const FACTION_FLOW := {
	"加达里": "warp",      # 折跃空投流
	"盖伦特": "tender",    # 母舰整备流
	"艾玛": "stargate",    # 星门阵地流
	"米玛塔尔": "command", # 战术指令流
}

## 四帝国 → 英文 key（给 UI 取帝国色用；EVE 侧没有英文 faction 字段）
const FACTION_KEY := {
	"艾玛": "amarr",
	"加达里": "caldari",
	"盖伦特": "gallente",
	"米玛塔尔": "minmatar",
}

## 帝国色 —— 与星舰万象棋原色板一致，也与 EVE 派系观感吻合
const FACTION_COLOR := {
	"amarr": Color(1.00, 0.79, 0.30),      # 金
	"caldari": Color(0.21, 0.90, 1.00),    # 青
	"gallente": Color(0.24, 1.00, 0.71),   # 绿
	"minmatar": Color(1.00, 0.42, 0.21),   # 橙
}

## 吨位 → 颜色（T1 冷灰 → T5 亮金）
const TIER_COLOR := [
	Color(0.55, 0.65, 0.72),
	Color(0.40, 0.78, 0.85),
	Color(0.45, 0.90, 0.62),
	Color(0.72, 0.62, 1.00),
	Color(1.00, 0.79, 0.30),
]


static func faction_key(faction: String) -> String:
	return str(FACTION_KEY.get(faction, "caldari"))


static func faction_color(faction: String) -> Color:
	return FACTION_COLOR.get(faction_key(faction), Color(0.55, 0.78, 0.82))


static func tier_color(tier: int) -> Color:
	return TIER_COLOR[clampi(tier - 1, 0, TIER_COLOR.size() - 1)]


## 把 EVE 船表的一行翻成自走棋卡池条目。
##
## ⚠️ 字段名保持「自走棋口径」（tier / empire / hp / atk），
##    因为核心逻辑层是按这套名字写的；只在**边界**做翻译。
static func row_to_card(row: Dictionary) -> Dictionary:
	var cost := int(row.get("cost", 1))
	var faction := str(row.get("faction", "加达里"))
	var role := str(row.get("role", "攻击型"))
	var shield := int(row.get("shield", 0))
	var armor := int(row.get("armor_struct", 0))
	return {
		"id": str(row.get("id", "")),
		"name": str(row.get("name", "")),
		"tier": cost,
		"empire": faction_key(faction),
		"faction_cn": faction,
		"flow": str(FACTION_FLOW.get(faction, "warp")),
		"role": role,
		# 自走棋只关心一个总血量：护盾 + 装甲结构
		"hp": shield + armor,
		"shield": shield,
		"armor": armor,
		"atk": int(row.get("attack", 1)),
		"range": int(row.get("range_cells", 1)),
		"speed": float(row.get("speed_cells", 0.3)),
		"atk_interval": float(row.get("attack_interval", 1.0)),
		"weapon": str(row.get("weapon", "")),
		"defense": str(row.get("defense", "")),
		"logistics": bool(row.get("logistics", false)),
	}


## 全部 52 艘 → 卡池数组（按吨位升序，同吨位按帝国聚拢，便于商店/图鉴浏览）
static func all_cards() -> Array:
	var out: Array = []
	for raw in TABLE.ROWS:
		var row: Dictionary = TABLE.row_to_dict(raw)
		out.append(row_to_card(row))
	return out


## 按 id 取一艘（商店卡买下后回查、图鉴详情用）
static func find_card(ship_id: String) -> Dictionary:
	var row: Dictionary = TABLE.find_row(ship_id)
	if row.is_empty():
		return {}
	return row_to_card(row)


## 按吨位取（商店 roll 时按 tier 过滤，比全表扫一遍快）
static func cards_of_tier(tier: int) -> Array:
	var out: Array = []
	for c in all_cards():
		if int(c["tier"]) == tier:
			out.append(c)
	return out
