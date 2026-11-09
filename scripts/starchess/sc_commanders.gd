extends RefCounted

## 星舰万象棋 —— 指挥官表（6 个）。

## [WHY 是 .gd 而不是 data/*.json] ⚠️ 踩过的坑，别改回去：
##   `data/` 目录下有 **`.gdignore`**，整个目录对 Godot 资源系统不可见。
##   原先把本表写成 `data/starchess/sc_commanders.json`，
##   结果热更包 pck 里**根本没有这个文件**，运行时读到空表 ⇒ 指挥官全空。
##   而且它不会被报错，只是 `JSON.parse_string` 返回 null，静默降级。
##
##   `data/` 是**设计侧源数据**（见 data/README.md），不进包；
##   游戏真正读的一律是 `scripts/data/*.gd`。本表服从同一约定。
##
## [约定] 指挥官**可以重复选**（用户明确要求），所以这里不做唯一性约束。

const ROWS: Array = [
	{
		"id": "caldari_warp", "name": "折跃指挥官",
		"empire": "caldari", "empire_cn": "加达里", "flow": "warp",
		"desc": "折跃空投：开局获得一次免费空投，直接把一艘舰船送到前台。",
		"bias": "导弹 / 盾抗",
	},
	{
		"id": "gallente_tender", "name": "整备指挥官",
		"empire": "gallente", "empire_cn": "盖伦特", "flow": "tender",
		"desc": "母舰整备：每回合开始为全体友舰回复少量耐久。",
		"bias": "混合炮 / 甲抗",
	},
	{
		"id": "amarr_stargate", "name": "星门指挥官",
		"empire": "amarr", "empire_cn": "艾玛", "flow": "stargate",
		"desc": "星门阵地：前排受到伤害时按比例转化为能量。",
		"bias": "激光炮 / 甲抗",
	},
	{
		"id": "minmatar_command", "name": "战术指挥官",
		"empire": "minmatar", "empire_cn": "米玛塔尔", "flow": "command",
		"desc": "战术指令：每回合首次刷新免费，且同流派舰船更易出现。",
		"bias": "射弹炮 / 盾抗",
	},
	{
		"id": "mix_salvage", "name": "回收指挥官",
		"empire": "gallente", "empire_cn": "盖伦特", "flow": "salvage",
		"desc": "残骸回收：己方舰船阵亡时掉落资源，可用于强化幸存者。",
		"bias": "混编 / 耐久",
	},
	{
		"id": "mix_siphon", "name": "虹吸指挥官",
		"empire": "amarr", "empire_cn": "艾玛", "flow": "siphon",
		"desc": "能量虹吸：攻击时按伤害比例吸取能量，滚雪球型。",
		"bias": "混编 / 输出",
	},
]


## 全部指挥官（调用方拿到的是**副本**，改它不会污染本表）。
static func all() -> Array:
	var out: Array = []
	for r in ROWS:
		out.append((r as Dictionary).duplicate(true))
	return out


## 按 id 找；找不到返回空字典（不返回 null，调用方少一处判空）。
static func find(id: String) -> Dictionary:
	for r in ROWS:
		var d: Dictionary = r
		if str(d.get("id", "")) == id:
			return d.duplicate(true)
	return {}


## 自检：id 不重复、字段齐全。返回问题列表（空 = 通过）。
static func validate() -> Array:
	var problems: Array = []
	var seen: Dictionary = {}
	var need := ["id", "name", "empire", "flow", "desc"]
	for r in ROWS:
		var d: Dictionary = r
		for k in need:
			if not d.has(k) or str(d.get(k, "")) == "":
				problems.append("%s 缺字段 %s" % [str(d.get("id", "?")), k])
		var id := str(d.get("id", ""))
		if seen.has(id):
			problems.append("id 重复：%s" % id)
		seen[id] = true
	return problems
