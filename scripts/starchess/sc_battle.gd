extends Control

## 星舰万象棋 —— 对局主界面
##
## 信息架构按真实游戏：顶部 4 张商店大卡 / 左侧玩家列 / 中央战场 / 底部上阵区 / 右下能量。
## 视觉全部复用 EVE：真立绘 EveShipArtView、字体 FONT、按钮 EveButtonTheme、船表 ScShipAdapter。
##
## 当前阶段：只做**界面与买/上阵/合流闭环**，战斗表现后续接。

const FONT := preload("res://scripts/ui/eve_font.gd")
const THEME := preload("res://scripts/ui/eve_button_theme.gd")
const ADAPTER := preload("res://scripts/starchess/sc_ship_adapter.gd")
const CARD := preload("res://scripts/starchess/sc_shop_card.gd")
const CONTEXT := preload("res://scripts/starchess/sc_context.gd")

const C_TEXT := Color(0.70, 0.82, 0.85)
const C_TEXT_HI := Color(0.91, 0.96, 0.97)
const C_DIM := Color(0.44, 0.55, 0.59)
const C_ACCENT := Color(0.55, 0.78, 0.82)
const C_GOLD := Color(0.91, 0.76, 0.35)
const C_BORDER := Color(0.42, 0.55, 0.60, 0.34)

const SHOP_SLOTS := 4
const CARD_W := 236.0
const CARD_H := 248.0
const CARD_GAP := 8.0
const SHIP_COST := 3
const START_ENERGY := 6
const ENERGY_PER_ROUND := 6
const ENERGY_CAP := 30
const REROLL_COST := 1
const MERGE_BONUS := 3
const BOARD_CAP := [3, 4, 5, 6, 7, 8]

const PLAYER_NAMES := [
	"星舰V小鱼（你）", "让我取暖", "风住雨停雾散尽",
	"只在须臾", "你很认真", "无知又无畏",
]

var _round: int = 1
var _energy: int = START_ENERGY
var _level: int = 1
var _free_rerolls: int = 1
var _life: Array = [60, 60, 60, 60, 60, 60]
var _hand: Array = []
var _units: Array = []
var _slots: Array = []
var _rng := RandomNumberGenerator.new()

var _shop_holder: HBoxContainer = null
var _hand_holder: HBoxContainer = null
var _player_rows: Array = []
var _energy_lb: Label = null
var _round_lb: Label = null
var _level_lb: Label = null
var _log_lb: Label = null
var _reroll_btn: Button = null
var _upgrade_btn: Button = null


func _ready() -> void:
	_rng.seed = int(CONTEXT.seed_value)
	_build()
	_refresh_shop()
	_refresh_all()


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.012, 0.02, 0.028, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# ---- 顶部状态栏
	_round_lb = Label.new()
	_round_lb.text = "第 1 回合"
	_round_lb.add_theme_color_override("font_color", C_TEXT_HI)
	FONT.fs(_round_lb, 15)
	_round_lb.position = Vector2(20, 12)
	add_child(_round_lb)

	var ban := Label.new()
	ban.text = "禁用：河洛"
	ban.add_theme_color_override("font_color", C_DIM)
	FONT.fs(ban, 12)
	ban.position = Vector2(1660, 14)
	add_child(ban)

	# ---- 顶部商店（4 张大卡）
	var cards_w := float(SHOP_SLOTS) * CARD_W + float(SHOP_SLOTS - 1) * CARD_GAP
	var shop_x := 960.0 - cards_w * 0.5 + 40.0
	_shop_holder = HBoxContainer.new()
	_shop_holder.add_theme_constant_override("separation", int(CARD_GAP))
	_shop_holder.position = Vector2(shop_x, 44)
	_shop_holder.size = Vector2(cards_w, CARD_H)
	add_child(_shop_holder)

	# 刷新按钮（商店右侧）
	_reroll_btn = Button.new()
	_reroll_btn.text = "↻ 刷新\n免费"
	_reroll_btn.custom_minimum_size = Vector2(84, 84)
	_reroll_btn.position = Vector2(shop_x + cards_w + 14.0, 60)
	THEME.apply(_reroll_btn, "default")
	FONT.fs(_reroll_btn, 12)
	_reroll_btn.pressed.connect(_on_reroll)
	add_child(_reroll_btn)

	# ---- 左侧玩家列
	for i in range(6):
		var row := _make_player_row(i)
		row.position = Vector2(16, 236 + i * 64)
		add_child(row)
		_player_rows.append(row)

	# ---- 中央战场网格
	var field := GridContainer.new()
	field.columns = 7
	field.add_theme_constant_override("h_separation", 4)
	field.add_theme_constant_override("v_separation", 4)
	field.position = Vector2(520, 328)
	add_child(field)
	for i in range(28):
		var cell := Panel.new()
		cell.custom_minimum_size = Vector2(118, 66)
		var cb := StyleBoxFlat.new()
		cb.bg_color = Color(0.06, 0.10, 0.15, 0.28)
		cb.border_color = Color(0.16, 0.30, 0.38, 0.35)
		cb.set_border_width_all(1)
		cb.set_corner_radius_all(0)
		cell.add_theme_stylebox_override("panel", cb)
		field.add_child(cell)
		_slots.append(cell)

	# ---- 底部上阵区
	_hand_holder = HBoxContainer.new()
	_hand_holder.add_theme_constant_override("separation", 6)
	_hand_holder.position = Vector2(420, 760)
	_hand_holder.size = Vector2(1080, 140)
	add_child(_hand_holder)

	# ---- 左下等级 + 升级
	_level_lb = Label.new()
	_level_lb.text = "Lv1   上阵 0/3"
	_level_lb.add_theme_color_override("font_color", C_TEXT)
	FONT.fs(_level_lb, 13)
	_level_lb.position = Vector2(20, 940)
	add_child(_level_lb)

	_upgrade_btn = Button.new()
	_upgrade_btn.text = "升级"
	_upgrade_btn.custom_minimum_size = Vector2(84, 36)
	_upgrade_btn.position = Vector2(20, 964)
	THEME.apply(_upgrade_btn, "default")
	FONT.fs(_upgrade_btn, 12)
	_upgrade_btn.pressed.connect(_on_upgrade)
	add_child(_upgrade_btn)

	# ---- 右下能量 + 开战
	_energy_lb = Label.new()
	_energy_lb.text = str(START_ENERGY)
	_energy_lb.add_theme_color_override("font_color", C_GOLD)
	FONT.fs(_energy_lb, 30)
	_energy_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_energy_lb.position = Vector2(1770, 930)
	_energy_lb.size = Vector2(110, 44)
	add_child(_energy_lb)

	var gain := Label.new()
	gain.text = "+%d" % ENERGY_PER_ROUND
	gain.add_theme_color_override("font_color", C_DIM)
	FONT.fs(gain, 12)
	gain.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gain.position = Vector2(1770, 908)
	gain.size = Vector2(110, 20)
	add_child(gain)

	var go := Button.new()
	go.text = "▶ 开战"
	go.custom_minimum_size = Vector2(140, 44)
	go.position = Vector2(1600, 936)
	THEME.apply(go, "accent")
	FONT.fs(go, 14)
	go.pressed.connect(_on_battle)
	add_child(go)

	# ---- 日志
	_log_lb = Label.new()
	_log_lb.text = ""
	_log_lb.add_theme_color_override("font_color", C_DIM)
	FONT.fs(_log_lb, 11)
	_log_lb.position = Vector2(420, 1000)
	_log_lb.size = Vector2(1200, 40)
	_log_lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_log_lb)


## 左侧玩家行：名字 + 血量 + 棋盘槽
func _make_player_row(i: int) -> Control:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(210, 56)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.10, 0.15, 0.72) if i != 0 else Color(0.07, 0.15, 0.21, 0.86)
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	row.add_theme_stylebox_override("panel", sb)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	row.add_child(hb)

	var nm := Label.new()
	nm.text = str(PLAYER_NAMES[i % PLAYER_NAMES.size()])
	nm.add_theme_color_override("font_color", C_TEXT_HI if i == 0 else C_TEXT)
	FONT.fs(nm, 12)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hb.add_child(nm)

	var hp := Label.new()
	hp.text = str(int(_life[i]))
	hp.add_theme_color_override("font_color", C_ACCENT)
	FONT.fs(hp, 13)
	hp.name = "Hp"
	hb.add_child(hp)

	var slot := ColorRect.new()
	slot.custom_minimum_size = Vector2(22, 22)
	slot.color = Color(0, 0, 0, 0.35)
	hb.add_child(slot)
	return row


func _refresh_shop() -> void:
	for c in _shop_holder.get_children():
		c.queue_free()
	# 同一批内不重复：把已展示的 id 传进去排除
	var shown: Array = []
	for i in range(SHOP_SLOTS):
		var tier := _roll_tier()
		var pool := ADAPTER.cards_of_tier(tier)
		# 排除本批已出现的
		var avail: Array = []
		for c in pool:
			if not shown.has(str(c["id"])):
				avail.append(c)
		if avail.is_empty():
			avail = pool
		if avail.is_empty():
			continue
		var pick: Dictionary = avail[_rng.randi_range(0, avail.size() - 1)]
		shown.append(str(pick["id"]))
		var card := CARD.new()
		card.index = i
		card.custom_minimum_size = Vector2(CARD_W, CARD_H)
		_shop_holder.add_child(card)
		card.set_ship(pick, SHIP_COST, _ability_of(pick), _flow_name(pick))
		card.set_affordable(_energy >= SHIP_COST)
		card.card_pressed.connect(_on_buy)


## 商店等级概率（对齐真实游戏：等级越高越容易出高吨位）
func _roll_tier() -> int:
	var odds: Array = [
		[1.0, 0.0, 0.0, 0.0, 0.0],
		[0.70, 0.30, 0.0, 0.0, 0.0],
		[0.55, 0.35, 0.10, 0.0, 0.0],
		[0.40, 0.35, 0.20, 0.05, 0.0],
		[0.25, 0.35, 0.28, 0.11, 0.01],
		[0.15, 0.25, 0.35, 0.22, 0.03],
	]
	var row: Array = odds[clampi(_level - 1, 0, odds.size() - 1)]
	var r := _rng.randf()
	var acc := 0.0
	for i in range(row.size()):
		acc += float(row[i])
		if r <= acc:
			return i + 1
	return 1


## 技能文案：EVE 船表没有技能，这里按定位给一档（后续接独立技能表）。
func _ability_of(c: Dictionary) -> String:
	var role := str(c.get("role", "攻击型"))
	var t := int(c.get("tier", 1))
	match role:
		"后勤":
			return "开团：为相邻友舰回复 %d 点耐久。" % (t * 12)
		"防御型":
			return "上场：获得 %d 点护盾，替前排吸收伤害。" % (t * 18)
		_:
			return "开团：首次命中造成 %d%% 额外伤害。" % (100 + t * 25)


func _flow_name(c: Dictionary) -> String:
	var f := str(c.get("flow", ""))
	match f:
		"warp": return "折跃空投"
		"tender": return "母舰整备"
		"stargate": return "星门阵地"
		"command": return "战术指令"
		"salvage": return "残骸回收"
		"siphon": return "能量虹吸"
		_: return "通用"


func _refresh_all() -> void:
	if _round_lb != null:
		_round_lb.text = "第 %d 回合" % _round
	if _energy_lb != null:
		_energy_lb.text = str(_energy)
	if _level_lb != null:
		_level_lb.text = "Lv%d   上阵 %d/%d" % [_level, _units.size(), _cap()]
	if _reroll_btn != null:
		_reroll_btn.text = "↻ 刷新\n免费" if _free_rerolls > 0 else "↻ 刷新\n%d" % REROLL_COST
	for i in range(_player_rows.size()):
		var row: Control = _player_rows[i]
		var hp: Label = row.find_child("Hp", true, false)
		if hp != null:
			hp.text = str(int(_life[i]))
	_refresh_hand()


func _cap() -> int:
	return int(BOARD_CAP[clampi(_level - 1, 0, BOARD_CAP.size() - 1)])


func _refresh_hand() -> void:
	for c in _hand_holder.get_children():
		c.queue_free()
	if _hand.is_empty():
		var hint := Label.new()
		hint.text = "点击上方商店卡购买 → 手牌出现在这里 → 点手牌上阵"
		hint.add_theme_color_override("font_color", C_DIM)
		FONT.fs(hint, 12)
		_hand_holder.add_child(hint)
		return
	for i in range(_hand.size()):
		var c: Dictionary = _hand[i]
		var card := CARD.new()
		card.index = i
		card.custom_minimum_size = Vector2(96, 110)
		_hand_holder.add_child(card)
		card.set_ship(c, 1, "", _flow_name(c))
		card.card_pressed.connect(_on_deploy)


func _on_buy(idx: int) -> void:
	if _energy < SHIP_COST:
		_log("能量不足（需要 %d）" % SHIP_COST)
		return
	var card: Node = _shop_holder.get_child(idx) if idx < _shop_holder.get_child_count() else null
	if card == null:
		return
	var data: Dictionary = (card as CARD).ship
	if data.is_empty():
		return
	_energy -= SHIP_COST
	_hand.append(data.duplicate())
	_log("购入 %s" % str(data.get("name", "")))
	_refresh_all()


func _on_reroll() -> void:
	if _free_rerolls > 0:
		_free_rerolls -= 1
	else:
		if _energy < REROLL_COST:
			_log("能量不足（刷新需要 %d）" % REROLL_COST)
			return
		_energy -= REROLL_COST
	_refresh_shop()
	_refresh_all()


func _on_upgrade() -> void:
	var cost := _level_cost()
	if cost < 0:
		_log("已满级")
		return
	if _energy < cost:
		_log("能量不足（升级需要 %d）" % cost)
		return
	_energy -= cost
	_level += 1
	_log("指挥官升级 → Lv%d" % _level)
	_refresh_all()


func _level_cost() -> int:
	if _level >= BOARD_CAP.size():
		return -1
	return [4, 6, 9, 12, 16][clampi(_level - 1, 0, 4)]


## 上阵：同名合流 +3，否则占一个格子。
func _on_deploy(idx: int) -> void:
	if idx < 0 or idx >= _hand.size():
		return
	var c: Dictionary = _hand[idx]
	for u in _units:
		if str(u.get("id", "")) == str(c.get("id", "")):
			u["level"] = int(u.get("level", 1)) + MERGE_BONUS
			_hand.remove_at(idx)
			_log("合流 %s +%d 级" % [str(c.get("name", "")), MERGE_BONUS])
			_refresh_all()
			return
	if _units.size() >= _cap():
		_log("上阵已满（%d）" % _cap())
		return
	var u := c.duplicate()
	u["level"] = 1
	_units.append(u)
	_hand.remove_at(idx)
	_log("上阵 %s" % str(c.get("name", "")))
	_refresh_all()


## 开战：本轮结算（战斗表现后续接），然后进下一回合。
func _on_battle() -> void:
	var power := 0
	for u in _units:
		power += int(u.get("atk", 0)) * int(u.get("level", 1))
	_log("— 战斗结算 · 我方战力 %d —" % power)
	# 简化结算：战力低的一方掉血
	for i in range(1, 6):
		var enemy := 40 + _round * 6
		if power < enemy:
			_life[i] = int(_life[i]) - 4
	if power < 60:
		_life[0] = int(_life[0]) - 6
	if int(_life[0]) <= 0:
		get_tree().change_scene_to_file("res://scenes/starchess/sc_over.tscn")
		return
	_round += 1
	_energy = mini(ENERGY_CAP, _energy + ENERGY_PER_ROUND)
	_free_rerolls = 1
	_refresh_shop()
	_refresh_all()


func _log(msg: String) -> void:
	if _log_lb == null:
		return
	var t := msg + "\n" + _log_lb.text
	var lines := t.split("\n")
	if lines.size() > 3:
		lines = lines.slice(0, 3)
	_log_lb.text = "\n".join(lines)