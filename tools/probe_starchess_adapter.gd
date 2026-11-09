extends SceneTree
## 探针：验证 ScShipAdapter 能把 EVE 船表正确翻成自走棋卡池。

const A := preload("res://scripts/starchess/sc_ship_adapter.gd")
const ART := preload("res://scripts/visual/eve_ship_art.gd")

func _init() -> void:
	var cards := A.all_cards()
	print("TOTAL = ", cards.size())

	# 按吨位分布
	var by_tier := {}
	for c in cards:
		var t := int(c["tier"])
		by_tier[t] = int(by_tier.get(t, 0)) + 1
	print("BY_TIER = ", by_tier)

	# 按帝国分布
	var by_emp := {}
	for c in cards:
		by_emp[str(c["empire"])] = int(by_emp.get(str(c["empire"]), 0)) + 1
	print("BY_EMPIRE = ", by_emp)

	# 立绘命中率
	var hit := 0
	var miss: Array = []
	for c in cards:
		var id := StringName(str(c["id"]))
		if ART.has_portrait(id):
			hit += 1
		else:
			miss.append(str(c["id"]))
	print("PORTRAIT hit=", hit, " miss=", miss.size(), " ", str(miss))

	# 抽一艘打印完整字段
	var raven := A.find_card("raven")
	print("RAVEN = ", raven)

	# 每吨位抽一艘看
	for t in range(1, 6):
		var arr := A.cards_of_tier(t)
		if arr.size() > 0:
			var c: Dictionary = arr[0]
			print("T", t, " n=", arr.size(), " sample=", c["name"], " hp=", c["hp"], " atk=", c["atk"], " flow=", c["flow"])

	quit(0)
