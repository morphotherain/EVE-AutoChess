extends Node
class_name EveAudio

## EVE 自走棋 —— 音频层（阶段 D 子项 ④）
##
## ══════════════════════════════════════════════════════════════════
##  它解决什么
## ══════════════════════════════════════════════════════════════════
##  阶段 A~D 一路做下来，战斗在玩家眼里已经完全成立：船在动、曳光在飞、
##  爆点在闪、伤害数字在飘。但它**一直是静音的**。静音的战斗有个很具体的
##  副作用：玩家感知不到「打得多狠」—— 7 档命中品质（MISS→WRECKING）在
##  视觉上只差别在爆点大小，而声音是**瞬间**传达量级的通道。
##
##  音源全部来自本机 EVE Online 客户端解包（客户端路径见 `tools/pipeline/_paths.py` 的 CLIENT），
##  用 vgmstream 从 Wwise SoundBank 导出 —— 也就是**玩家在 EVE 里听到的
##  同一个音源**，不是仿制品。
##
## ── 三条总线的分工 ──────────────────────────────────────────────
##     SFX       打击反馈：开火 / 命中（按品质分档）/ 击毁爆炸
##     Ambience  阶段环境：准备倒计时 / 开战读秒 / 结算
##     Music     背景音乐：准备段 / 战斗段
##
##  分开的理由不是「看着整齐」：玩家在准备阶段会反复进出商店、翻看舰船
##  详情，那时打击音早停了而 BGM 还在响；如果只有一条总线，调音量就变成
##  「要么都吵要么都听不见」。三条独立音量是**可调旋钮清单**的落点。
##
## ── 为什么用 AudioStreamPlayer 池而不是 AudioStreamPlayer3D ───────
##  自走棋的战术视角是**俯视全局**，声音不该按相机距离衰减 ——
##  相机拉远时「听不见远处的爆炸」会让玩家漏掉战况。
##  EVE 自己的战斗音也是**全向汇报**（tactical overview 的听觉版本），
##  所以这里刻意不做 3D 衰减，只用音量 + 随机音高做「层次感」。
##
## ── 无头环境下的行为（验收必须能跑）────────────────────────────
##  `--headless` 没有音频设备，AudioServer 仍然存在且能 add_play 不报错，
##  但**不会有声音**。所以验收不验「有没有响」，只验：
##    · `play_*` 调用链有没有通（`stats()` 里的计数器）
##    · 节流有没有生效（开火 200 次 → sfx_played 远小于 200）
##  这与 `eve_battle_fx.active_count()` 是同一套验收哲学：
##  **把「发生过」变成可断言的整数**。
##
## 变更清单（阶段 D 子项 ④）：
##   - 三条总线（SFX / Ambience / Music）+ 独立音量
##   - 音效池（SFX_POOL 个 player 轮转）+ 每类节流窗口
##   - 打击反馈：开火 / 命中 7 档品质映射 / 击毁爆炸
##   - 阶段环境：倒计时滴答 / 开战 / 结算 / 节点推进
##   - 背景音乐：准备段 / 战斗段交叉淡入
##   - 音源缺失时**静默降级**（不报错、不崩，只记一次日志）

# ══════════════════════════════════════════════════════════════════
#  总线与池
# ══════════════════════════════════════════════════════════════════

const BUS_SFX := &"SFX"
const BUS_AMB := &"Ambience"
const BUS_MUSIC := &"Music"
## 总音量走引擎的 Master 总线 —— 三条分总线都 send 到它下面，
## 所以它是「一处调、三条一起变」的真实总闸，不必在三条上各乘一次系数
## （各乘一次会导致 master 与分档互相污染：调完总音量，音效/音乐的**比例**也变了）。
const BUS_MASTER := &"Master"

## 短音（开火 / 命中）同时可播的条数。
##
## ⚠️ 这个数是「同时发声数」不是「总音效数」：BOSS 战 6v6、30Hz 开火时
##    每帧都有新开火，池子太小会**互相打断**（后一个 play 把前一个顶掉，
##    听起来像卡带）；太大则混成一片白噪音。
##    12 是实测下来「密集但有层次」的档位。
const SFX_POOL := 12

## 击毁爆炸单独一个池 —— 爆炸音长（0.5~2s），和短音抢池子会让开火音
## 在爆炸期间集体消失。
const BOOM_POOL := 4

## 阶段环境（倒计时 / 开战 / 结算）单独一个池，挂在 BUS_AMB 上 ——
## 不能复用 SFX 池，否则环境音会走打击总线（音量被打击旋钮接管）。
const AMB_POOL := 4

## 牌桌 / UI 具名音效（`play_cue`）的池，挂在 BUS_SFX 上。
##
## ⚠️ 为什么挂 SFX 总线却另开一个池：牌桌与战场是**两个场景**，永远不会同时响，
##    所以共用总线（＝共用「音效音量」旋钮）是对的；
##    但绝不能共用同一个池 —— 战斗那 12 个 player 被 30Hz 开火占满时，
##    玩家按下「出牌」会抢不到 player，听感是**按键失灵**。
## 6 是牌桌实测够用的档位（最密的是连点选牌，人手上限就在这附近）。
const CUE_POOL := 6

## 音乐用两个 player 做交叉淡入（A 响 B 备），不是池
const MUSIC_FADE := 1.2

## BGM **额外增益**（鸭音）的默认淡化时长（秒）。
##
## ★ 2026-10-17 用户：「BGM 一开始音量比较大…玩家点击某个按钮之后，音量减小」。
## ⛔ 不能瞬时切：整轨音乐的增益跳变就是一次**波形断口**，听感是「嗒」一声。
const MUSIC_GAIN_FADE := 0.8

# ══════════════════════════════════════════════════════════════════
#  节流窗口（秒）
# ══════════════════════════════════════════════════════════════════
#
# ⚠️ 节流是**必须**的，不是优化：30Hz × 12 艘船 = 每秒 360 次开火信号。
#    不节流的话声音层会变成一堵噪音墙，玩家反而听不出战况。
#    Windows 的取值逻辑是「人类能分辨的相邻同种声音间隔」——
#    开火比命中密（开火是连续动作，命中有品质差异需要被听见）。

const THROTTLE_FIRE := 0.045
const THROTTLE_HIT := 0.040
const THROTTLE_BOOM := 0.010

## 每个节流窗口内**允许**放几声（令牌桶容量）。
##
## ⚠️ 只有「窗口」没有「容量」会踩一个很具体的坑：战斗是固定步长推进的，
##    同一 tick 里 6 艘船同时开火 —— 它们的 `sim.elapsed` **完全相同**，
##    于是窗口节流把 6 声压成 1 声。实测 12 秒战斗 32 次开火只响 8 声，
##    听感是「零零星星放了两枪」，而画面上是六艘船在齐射。
##    容量 = 3 是「同一瞬间最多三声」：既不成噪音墙，也不把齐射吃掉。
const BURST_FIRE := 3
const BURST_HIT := 3
const BURST_BOOM := 2
## 命中品质越高，节流窗口越短 —— 重击绝不能被吞掉。
## 下标 = 品质档（EveCombatCore.HitQuality 7 档）
const THROTTLE_BY_QUALITY: Array[float] = [0.12, 0.10, 0.06, 0.045, 0.035, 0.022, 0.016]

# ══════════════════════════════════════════════════════════════════
#  音频目录
# ══════════════════════════════════════════════════════════════════

const DIR_SFX := "res://assets/audio/sfx/"
const DIR_AMB := "res://assets/audio/ambience/"
const DIR_MUS := "res://assets/audio/music/"

## 打击音表：键 = 逻辑名，值 = 该类的候选文件名（随机挑一个）。
##
## ⚠️ 候选是**列表**不是单文件：同一件事重复放同一个采样，玩家 3 秒内
##    就会听出「复读机」。EVE 原始 bank 里每类都有几十个变体，我们取几个
##    轮换，代价是 0 而收益是「听起来像真的在打」。
var _sfx_bank: Dictionary = {}
var _amb_bank: Dictionary = {}
var _mus_bank: Dictionary = {}

# ══════════════════════════════════════════════════════════════════
#  运行时状态
# ══════════════════════════════════════════════════════════════════

var _sfx_players: Array[AudioStreamPlayer] = []
var _boom_players: Array[AudioStreamPlayer] = []
var _amb_players: Array[AudioStreamPlayer] = []
var _cue_players: Array[AudioStreamPlayer] = []
var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer

## ⚠️ 独立 RNG：音效挑变体 / 抖音高**必须**走它，绝不能碰全局 randi()。
##    理由不是洁癖 —— 战斗 sim 的命中判定吃全局随机序列，音效一插手，
##    同一个种子跑出来的战斗结果就变了，验收会变成玄学。
##    这条由 tools/verify_audio.gd 的「随机隔离」用例守着。
var _rng := RandomNumberGenerator.new()
var _music_active: AudioStreamPlayer
var _music_idle: AudioStreamPlayer
var _music_current := ""

## ══════════════════════════════════════════════════════════════
##  BGM 额外增益（鸭音）—— `set_music_gain()`
## ══════════════════════════════════════════════════════════════
##  用来表达「同一首曲子在不同状态下的响度」：例如牌桌**空桌时响、玩家一动手就变轻**。
##
##  ⛔ 为什么**不**改总线音量（`set_volume(&"music", …)`）：
##    ① 总线音量是**设置窗那条滑杆**的值 —— 牌桌偷偷改掉它，玩家看到的读数就是假的
##       （工程红线：玩家看到的开关必须与实际一致）；
##    ② Music 总线是**所有曲目共用**的（准备/战斗/主菜单/牌桌），改它会把牌桌的状态
##       串到别的场景去。
##  ⇒ 落点是一个挂在 Music 总线上的 `AudioEffectAmplify`：它**叠在**滑杆之上，
##    既不动滑杆的读数，也不改任何 bus volume。
##
##  ⚠️⚠️ 它挂在**全局 AudioServer** 上，不是本实例的子节点 ⇒ 会被"上一个场景/上一个
##    实例"留下来（实测：牌桌空桌态的 +5 dB 会被带进主菜单）。所以有两道归零：
##      · `_ready()` 归零 —— 新场景/新实例从 0 开始；
##      · `play_music()` 换曲时归零 —— 别让上一首的状态跟着下一首走。
##    这两条由 `tools/verify_audio.gd::_music_gain_test()` 守着。
var _music_gain_fx: AudioEffectAmplify
var _music_gain_db := 0.0
var _music_gain_from_db := 0.0
var _music_gain_to_db := 0.0
var _music_gain_t := 0.0
var _music_gain_fade := MUSIC_GAIN_FADE

## 节流：键 -> 最近几次播放的时间戳（令牌桶，见 `_throttle`）
var _recent: Dictionary = {}

## 每个键**上一次**用过的变体下标（`_pick_variant` 用来换一句）。
##
## ★ 2026-10-18 用户：「过和不要需要交替出现，用来增加趣味性」、
##   「避免出现连续两个"抢地主"听着很乏味」⇒ 同一个键连说两遍同一句最乏味。
var _last_variant: Dictionary = {}

## 可断言的计数器（验收用）
var _count := {
	"fire": 0, "hit": 0, "boom": 0, "amb": 0, "cue": 0, "music": 0, "missing": 0,
	"fire_throttled": 0, "hit_throttled": 0, "boom_throttled": 0,
	"break":0,
}

## 总音量（0~1）。1.0 = 不额外衰减，分档音量原样生效。
var volume_master := 1.0

## 音量（0~1），外部可调。
##
## ⚠️ 这**不是**线性增益 —— `_set_bus_vol` 里走的是平方曲线（`gain = lin²`），
##    所以「降一半响度」= 这里乘 `1/√2 ≈ 0.707`，**不是乘 0.5**。
##    乘 0.5 会变成 −12 dB（听感上只剩四分之一），过头了。
##    当前这组 = 原始 `0.85 / 0.55 / 0.45` 统一 −6 dB（各乘 1/√2，比例不变）：
##      sfx   0.60 → 20·log10(0.60²) = −8.9 dB（原 −2.8 dB）
##      amb   0.39 → −16.4 dB（原 −10.4 dB）
##      music 0.32 → −19.8 dB（原 −13.9 dB）
##    要再整体挪一档就三个数一起乘同一个系数（保持 sfx : amb : music 的配比）。
var volume_sfx := 0.60
var volume_amb := 0.39
var volume_music := 0.32

## 全局静音开关（设置窗用）
var muted := false

## 音源缺失计数 —— 只记一次，避免刷屏
var _missing_reported := {}


# ══════════════════════════════════════════════════════════════════
#  生命周期
# ══════════════════════════════════════════════════════════════════

## ══════════════════════════════════════════════════════════════
##  音效总开关（2026-10-01 用户要求）
## ══════════════════════════════════════════════════════════════
##  用户原话：「音效和攻击的动画都不是认真做的，所以看着听着很别扭，
##             先全部关闭吧，**是关闭，不是删除**，我怕以后会用到。」
##
##  ⛔ 这是**开关**不是删除：音源银行、总线、节流、「缺源计数」逻辑**全部保留**，
##     把 `sfx_enabled` 置 true 即完整恢复。以后做「设置窗里的音效开关」
##     直接把这一项挂上去就行。
##
##  只管 **sfx + amb**（开火 / 命中 / 爆炸 / 阶段 / 滴答 / 读秒 / 结算 / 节点推进）；
##  ⛔ **不碰 music** —— BGM 是从 EVE 客户端正经解出来的素材，用户没抱怨过。
##
##  ⚠️ 为什么是 `var` 而不是 `const`：验收要能**双向测** ——
##     打开时断言「播了、计数 +1」，关掉时断言「一声没响、计数不变」。
##
## ★ 2026-10-25 改回 `true`（用户：「音量只能调全局，音效和环境两个滑杆没用」）
##   根因就是这一行：`sfx_off()` 同时挡住 sfx 与 amb 两条总线 ⇒ 两个滑杆
##   无论拉到哪都听不到任何变化（音乐不受影响，所以只有全局与音乐"看起来有效"）。
##   接通条件早已具备：`docs/音效落地执行方案-1016.md` 第五节第 5 步写的正是
##   「全部接线完成后把 `SFX_ENABLED_DEFAULT` 置 true」，而接线（斗地主 47 键 +
##   战斗/阶段音 + 超长变体剔除）已经完成，只有这一行忘了翻。
##   ⛔ 不想听时不用改代码：设置窗的「音效」滑杆拉到 0 即静音（`set_volume(&"sfx", 0)`）。
const SFX_ENABLED_DEFAULT := true
var sfx_enabled := SFX_ENABLED_DEFAULT


## 音效是否被总开关挡住。每个公开的 play_* 第一行都要过这一关。
##
## ⛔ **不要把它塞进 `_play_from()`** —— 那会让 `_play_from` 返回 false，
##    调用方随即走 `_note_missing()`，于是「关掉音效」反而刷一屏「音源缺失」告警。
func sfx_off() -> bool:
	return not sfx_enabled


func _ready() -> void:
	_ensure_buses()
	_add_music_gain_effect()
	_build_banks()
	_build_players()
	_apply_volumes()
	# ★ BGM 增益归零：效果器挂在**全局** AudioServer 上，⛔ 不归零的话
	#   「上一个场景留下的响态」（例如牌桌空桌的 +5 dB）会跟着新场景一起响。
	set_music_gain(0.0, 0.0)


## 建三条总线（幂等 —— 已经存在就不重复建）。
##
## ⚠️ 用 `AudioServer.add_bus` 而不是在 `default_bus_layout.tres` 里配：
##    后者需要额外资源文件，而本工程**没有**该文件（一直是单总线默认布局）。
##    代码建总线还有一个好处：三条总线的父子关系（都挂在 Master 下）
##    在这里一眼可见，不必去翻二进制布局文件。
func _ensure_buses() -> void:
	for b in [BUS_SFX, BUS_AMB, BUS_MUSIC]:
		var idx := AudioServer.get_bus_index(b)
		if idx < 0:
			AudioServer.add_bus()
			idx = AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, b)
			AudioServer.set_bus_send(idx, &"Master")


## 装载音源清单。
##
## ⚠️ 目录可能**不存在**（音源尚未解包 / 用户删了 assets/audio）。
##    这里必须静默降级 —— 阶段 D 的验收脚本要能在没有音频资产的
##    持续集成环境里跑通。缺音源 = 不播，不是崩。
func _build_banks() -> void:
	_sfx_bank = _scan_dir(DIR_SFX)
	_amb_bank = _scan_dir(DIR_AMB)
	_mus_bank = _scan_dir(DIR_MUS)
	_cull_overlong_sfx()


## ══════════════════════════════════════════════════════════════════
##  素材时长闸（2026-10-17 打击感改造）
## ══════════════════════════════════════════════════════════════════
##  2026-10-01 用户关掉全部战斗音效，原话是「音效和攻击的动画都不是认真做的，
##  所以看着听着很别扭」。当时大家以为是"音色风格问题"，实测下来不是：
##
##    assets/audio/sfx 实测时长
##      boom_01.ogg       36.24 s   ← 一整段，不是一次爆炸
##      fire_capital_01   3.82 s
##      fire_heavy_01     2.81 s
##      fire_01           0.98 s
##      hit_*             0.09~0.32 s   ✅ 正常
##
##  战斗事件间隔是 0.07~0.3 s（6v6 实测每 70ms 一次开火）。
##  一发 2.8 秒的重炮音会盖住后面**十几发**；36 秒的"爆炸"会一直响到
##  下一次击毁之后 ⇒ 声音层叠成一堵墙。**这就是"别扭"的物理原因**，
##  和音色好不好听是两件事。
##
##  ⇒ 每个音色族给时长上限，超长的变体**不入选**。
##  ⛔ 为什么不是"截断前 N 秒"：截断会把爆炸的尾音切在任意相位上，
##     听起来是"被掐断"，比长音更假。宁可少一个变体。
##  ⛔ 这是修素材错配，不是改游戏默认行为 —— 删掉本函数即完整回滚。
const MAX_SFX_SECONDS := {
	&"fire_light": 0.80,
	&"fire": 1.20,
	&"fire_heavy": 1.70,
	&"fire_capital": 2.10,
	&"hit_light": 0.60,
	&"hit_shield": 0.60,
	&"hit_armor": 0.60,
	&"hit_structure": 0.90,
	&"miss": 0.50,
	&"boom": 2.60,
}


func _cull_overlong_sfx() -> void:
	var dropped: PackedStringArray = []
	for key in MAX_SFX_SECONDS.keys():
		var list: Array = _sfx_bank.get(key, [])
		if list.is_empty():
			continue
		var keep: Array = []
		var shortest: AudioStream = null
		var shortest_len := INF
		for st in list:
			var secs := _stream_seconds(st)
			if secs < shortest_len:
				shortest_len = secs
				shortest = st
			if secs <= float(MAX_SFX_SECONDS[key]):
				keep.append(st)
			else:
				dropped.append("%s(%.1fs)" % [String(key), secs])
		# 兜底：整族都被判超长时，至少留最短的那一个 ——
		# 「这族没声音」比「这族声音长」更难排查（前者是静默失效）。
		if keep.is_empty() and shortest != null:
			keep.append(shortest)
		_sfx_bank[key] = keep
	if not dropped.is_empty():
		print("[EveAudio] 已剔除超长音效变体（防止叠成噪音墙）：%s"
				% ", ".join(dropped))


## 取音频流时长（秒）。未知格式返回 0 = 不参与剔除（宁放行不错杀）。
func _stream_seconds(st: AudioStream) -> float:
	if st is AudioStreamOggVorbis:
		return (st as AudioStreamOggVorbis).get_length()
	return 0.0


## 扫一个目录，返回 {逻辑名: [AudioStream, ...]}。
##
## 命名约定：`<逻辑名>_<序号>.ogg` —— 例如 `fire_01.ogg` / `hit_03.ogg`。
## 逻辑名取第一个下划线之前的部分，序号只用来区分变体。
##
## ⚠️ 判据**不能**只看 `fn.get_extension() == "ogg"`：
##    编辑器里目录内容就是磁盘上的 `menu_01.ogg`，但**导出包**（PCK）里
##    同一个音源会同时出现 `menu_01.ogg` 与 `menu_01.ogg.import` 两条记录，
##    且不同引擎版本对 `.remap` 的暴露方式不一样（有的把 `menu_01.ogg.remap`
##    原样列出来）。判死一种写法 → 导出后 BGM 全静音**且不报错**。
##    所以：先剥掉 `.remap` 再按扩展名认。
## 文件名（**不带扩展名**）→ 音效逻辑名：去掉末尾的 `_NN` 变体号。
##
## ⚠️ 抽成函数是因为「扫目录」和「网页版清单」两条路都要用它 ——
##    两份实现迟早会漂，漂了的表现就是「同一个音在某些端上找不到」。
func _logical_name(base: String) -> String:
	var logical := base
	var us := base.rfind("_")
	if us > 0:
		var tail := base.substr(us + 1)
		if tail.is_valid_int():
			logical = base.substr(0, us)
	return logical


func _scan_dir(dir_path: String) -> Dictionary:
	var out: Dictionary = {}
	var names := _list_files(dir_path)
	var seen := {}
	for fn in names:
		var real := _strip_import_suffix(fn)
		if real.get_extension().to_lower() != "ogg":
			continue
		# 同一音源在导出包里可能同时以 `<名>.ogg` 与 `<名>.ogg.import` 两条出现
		# （编辑器里两者都在）⇒ 按还原后的名字去重，别把同一个流塞两次。
		if seen.has(real):
			continue
		seen[real] = true
		var base := real.get_basename()
		# 逻辑名 = 去掉末尾的 _NN 变体号
		var logical := _logical_name(base)
		var stream := _load_stream(dir_path.path_join(real))
		if stream != null:
			if not out.has(logical):
				out[logical] = []
			out[logical].append(stream)
	# 目录里明明有文件，却一个音源都没认出来 —— 只可能是导出包的命名变了。
	# ⚠️ 这条告警是「BGM 静默静音」的探针：正常包 / 编辑器里不会出现。
	if out.is_empty() and not names.is_empty() and not _missing_reported.has(dir_path):
		_missing_reported[dir_path] = true
		var probe := "(无 .ogg 候选)"
		for fn in names:
			var real := _strip_import_suffix(fn)
			if real.get_extension().to_lower() == "ogg":
				var full := dir_path.path_join(real)
				probe = "%s exists=%s" % [full, ResourceLoader.exists(full)]
				break
		push_warning("[EveAudio] %s 未识别到音源；目录内容：%s；探针：%s"
				% [dir_path, ", ".join(PackedStringArray(names)), probe])
	return out


## 把「目录里列出来的文件名」还原成**资源路径用的文件名**。
##
## ⚠️⚠️ Godot **导出包对导入资源（.ogg 等）不保留源文件** —— 目录里列出来的是
##    `<名>.ogg.import`（编辑器里则是 `<名>.ogg` **和** `<名>.ogg.import` 两条）。
##    历史版本还可能用 `<名>.ogg.remap`。⇒ 三种后缀都要剥掉再按扩展名认，
##    认出来后按**原始路径**（`<名>.ogg`）去 load —— `ResourceLoader` 会自己
##    顺着 `.import` 里 `[remap] path=` 找到 `res://.godot/imported/...`。
##    ⛔ 只认 `.ogg` 会让**导出后 BGM/SFX/环境音全静音、且一条报错都没有**
##    （2026-10-10 在 MuMu 上实测踩到：整个音源库为空）。
func _strip_import_suffix(fn: String) -> String:
	for suf in [".remap", ".import"]:
		if fn.ends_with(suf):
			return fn.substr(0, fn.length() - suf.length())
	return fn


## 列出一个目录下的**文件**名（不含子目录）。
##
## ⚠️ 带不带尾斜杠都试一遍：编辑器里 `res://.../music/` 两种写法都行，
##    但导出包里 `DirAccess.open()` 对尾斜杠的处理与磁盘不一致，
##    会直接返回 null —— 于是「明明有音源却扫不到，且不报错」。
func _list_files(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	for p in [dir_path, dir_path.trim_suffix("/")]:
		var d := DirAccess.open(p)
		if d == null:
			continue
		d.list_dir_begin()
		var fn := d.get_next()
		while fn != "":
			if not d.current_is_dir() and not fn.begins_with("."):
				out.append(fn)
			fn = d.get_next()
		d.list_dir_end()
		if not out.is_empty():
			break
	return out



func _load_stream(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		return null
	var r := ResourceLoader.load(path)
	if r is AudioStream:
		return r as AudioStream
	return null


## 建 player 池。
func _build_players() -> void:
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		p.bus = BUS_SFX
		p.name = "Sfx%d" % i
		add_child(p)
		_sfx_players.append(p)
	for i in BOOM_POOL:
		var p := AudioStreamPlayer.new()
		p.bus = BUS_SFX
		p.name = "Boom%d" % i
		add_child(p)
		_boom_players.append(p)
	# ⚠️ 环境音单独一池并挂 BUS_AMB：挂到 SFX 池上会被打击音量旋钮接管，
	#    玩家在准备阶段调低打击音就听不见倒计时了。
	for i in AMB_POOL:
		var p := AudioStreamPlayer.new()
		p.bus = BUS_AMB
		p.name = "Amb%d" % i
		add_child(p)
		_amb_players.append(p)

	# ★ 2026-10-17：牌桌/UI 具名音效池（挂 BUS_SFX，理由见 CUE_POOL 顶注）
	for i in CUE_POOL:
		var p := AudioStreamPlayer.new()
		p.bus = BUS_SFX
		p.name = "Cue%d" % i
		add_child(p)
		_cue_players.append(p)

	_music_a = AudioStreamPlayer.new()
	_music_a.bus = BUS_MUSIC
	_music_a.name = "MusicA"
	add_child(_music_a)
	_music_b = AudioStreamPlayer.new()
	_music_b.bus = BUS_MUSIC
	_music_b.name = "MusicB"
	add_child(_music_b)
	_music_active = _music_a
	_music_idle = _music_b


## 外部改音量 / 静音的**唯一入口**。
##
## ⚠️ 直接写 `audio.volume_sfx = 0.3` 是**不会生效**的 ——
##    总线音量只在 `_set_bus_vol` 里被写进 AudioServer，改了变量没人读它，
##    于是「拖动滑块没反应」且**不报错**。设置窗要走这两个方法。
func set_volume(kind: StringName, v: float) -> void:
	match kind:
		&"master":
			volume_master = clampf(v, 0.0, 1.0)
		&"sfx":
			volume_sfx = clampf(v, 0.0, 1.0)
		&"amb":
			volume_amb = clampf(v, 0.0, 1.0)
		&"music":
			volume_music = clampf(v, 0.0, 1.0)
		_:
			push_warning("[EveAudio] 未知音量通道：%s" % kind)
			return
	_apply_volumes()


func set_muted(on: bool) -> void:
	muted = on
	_apply_volumes()


func _apply_volumes() -> void:
	# ⚠️ Master 必须**最后**写：三条分总线的 send 目标就是它，
	#    顺序反了不会报错，但同一帧内会先静音再解除，听感上是一次爆音。
	_set_bus_vol(BUS_SFX, volume_sfx)
	_set_bus_vol(BUS_AMB, volume_amb)
	_set_bus_vol(BUS_MUSIC, volume_music)
	_set_bus_vol(BUS_MASTER, volume_master)


## 当前四档音量的快照（设置窗回写 / 验收断言用）。
##
## ⚠️ 设置窗**必须**从这里读初值而不是自己写死一份 ——
##    写死的话，「音频层默认值改了而窗里没改」就会变成静默的不同步。
func volumes() -> Dictionary:
	return {
		"master": volume_master,
		"sfx": volume_sfx,
		"amb": volume_amb,
		"music": volume_music,
		"muted": muted,
	}


func _set_bus_vol(bus: StringName, v: float) -> void:
	var idx := AudioServer.get_bus_index(bus)
	if idx < 0:
		return
	var lin := 0.0 if muted else maxf(0.0, minf(1.0, v))
	# 线性音量对听感太"陡"，用平方律（感知上是等步的）
	AudioServer.set_bus_volume_db(idx, linear_to_db(lin * lin) if lin > 0.0 else -80.0)
	AudioServer.set_bus_mute(idx, muted or lin <= 0.0)


# ══════════════════════════════════════════════════════════════════
#  打击反馈（战斗 sim 的三条信号）
# ══════════════════════════════════════════════════════════════════

## 开火音。
##
## `quality` 用来选音色族：低档用轻武器、高档用重武器。
## 未命中（MISS）也响 —— 但音色不同（更闷、更短），
## 让玩家**听着**就知道这一轮是空放还是打中。
func play_fire(quality: int = 3, pitch_jitter: bool = true) -> void:
	if sfx_off():
		return
	if _throttle("fire", THROTTLE_FIRE, BURST_FIRE):
		return
	var key := _fire_key(quality)
	if not _play_from(_sfx_bank, key, _sfx_players, 0.96, 1.06, pitch_jitter):
		# 退到通用开火音（音源未解包时静默返回）
		if not _play_from(_sfx_bank, "fire", _sfx_players, 0.96, 1.06, pitch_jitter):
			return
	_count["fire"] += 1


## 命中音。`quality` = EveCombatCore.HitQuality 的 7 档。
##
## ⚠️ 节流窗口按品质分档（`THROTTLE_BY_QUALITY`）：
##    MISS 可以密集地吞，WRECKING（结构击穿）绝不能吞 ——
##    玩家最该听见的就是那一发。
func play_hit(quality: int, layer: StringName = &"") -> void:
	if sfx_off():
		return
	var q := clampi(quality, 0, THROTTLE_BY_QUALITY.size() - 1)
	if _throttle("hit", THROTTLE_BY_QUALITY[q], BURST_HIT):
		return
	var key := _hit_key(q, layer)
	if not _play_from(_sfx_bank, key, _sfx_players, 0.94, 1.08, true):
		if not _play_from(_sfx_bank, "hit", _sfx_players, 0.94, 1.08, true):
			return
	_count["hit"] += 1


## 击毁爆炸。
func play_boom() -> void:
	if sfx_off():
		return
	if _throttle("boom", THROTTLE_BOOM, BURST_BOOM):
		return
	if not _play_from(_sfx_bank, "boom", _boom_players, 0.92, 1.04, true):
		return
	_count["boom"] += 1


func play_layer_break(layer: StringName) -> void:
	if sfx_off() or not [&"shield",&"armor"].has(layer): return
	var key:="break_"+String(layer)
	if _throttle(key,0.08,2): return
	if not _sfx_bank.has(key):
		_sfx_bank[key]=[_break_transient(layer)]
	if _play_from(_sfx_bank,key,_sfx_players,1.0,1.0,false):
		_count["break"]+=1


func _break_transient(layer: StringName) -> AudioStreamWAV:
	# Short original confirmation layers: inharmonic glass for shield collapse,
	# lower damped metal for armor. Generated once, through the existing SFX bus.
	var rate:=22050
	var length:=0.28 if layer==&"shield" else 0.24
	var bytes:=PackedByteArray()
	bytes.resize(int(rate*length)*2)
	var partials:Array=[760.0,1120.0,1710.0,2290.0] if layer==&"shield" else [210.0,337.0,510.0,780.0]
	for i in range(bytes.size()/2):
		var t:=float(i)/rate
		var value:=0.0
		for j in range(partials.size()):
			value+=sin(TAU*partials[j]*t)*exp(-t*(19.0+float(j)*7.0))*0.16
		var noise:=fposmod(sin(float(i)*12.9898+78.233)*43758.5453,1.0)*2.0-1.0
		value+=noise*exp(-t*95.0)*0.25
		value+=sin(TAU*(120.0 if layer==&"shield" else 82.0)*t)*exp(-t*18.0)*0.24
		value*=smoothstep(0.0,0.0015,t)*(1.0-smoothstep(length-0.035,length,t))
		bytes.encode_s16(i*2,int(clampf(value,-0.95,0.95)*18000.0))
	var stream:=AudioStreamWAV.new()
	stream.format=AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate=rate
	stream.data=bytes
	return stream


## 品质档 -> 开火音色族。
##
## 类比 EVE 的武器谱系：低档 = 小型速射（清脆）、高档 = 大型炮（沉）。
func _fire_key(quality: int) -> String:
	var q := clampi(quality, 0, 6)
	if q <= 1:
		return "fire_light"
	if q <= 3:
		return "fire"
	if q <= 5:
		return "fire_heavy"
	return "fire_capital"


## 命中音色族。
##
## 优先按**真实受击层**选（能确定层时由场景传 layer）；
## 层未知时退回品质映射（与 EveBattleFx.QUALITY_COLORS 的口径对应）：
## MISS 暗灰 / PENETRATING 护盾蓝 / SMASHING 装甲金 / WRECKING 结构橙红。
## ⚠️ 品质≠层：品质只是兜底，真实层优先。
func _hit_key(quality: int, layer: StringName = &"") -> String:
	if layer == &"shield":
		return "hit_shield"
	if layer == &"armor":
		return "hit_armor"
	if layer == &"hull":
		return "hit_structure"
	match quality:
		0:
			return "miss"
		1, 2:
			return "hit_light"
		3:
			return "hit"
		4:
			return "hit_shield"
		5:
			return "hit_armor"
		_:
			return "hit_structure"


# ══════════════════════════════════════════════════════════════════
#  阶段环境音
# ══════════════════════════════════════════════════════════════════

## 阶段切换音。phase 用 EveRunState.Phase 的整数。
func play_phase(phase: int) -> void:
	if sfx_off():
		return
	var selected_ui := get_node_or_null("/root/EveUiAudio")
	if selected_ui != null and selected_ui.handles("round.prep"):
		if phase == 0 or phase == 1:
			if selected_ui.play("round.prep" if phase == 0 else "round.battle"):
				_count["amb"] += 1
		# Resolve/ending have explicit win/lose events, not a second generic cue.
		return
	var key := ""
	match phase:
		0:
			key = "phase_prep"
		1:
			key = "phase_battle"
		2:
			key = "phase_resolve"
		_:
			key = "phase_end"
	# 阶段音不节流 —— 一局里只会响几次，每次都该被听见
	if _play_from(_amb_bank, key, _amb_players, 0.98, 1.02, false):
		_count["amb"] += 1
	else:
		_note_missing(key)


## 准备阶段的倒计时滴答。`seconds_left` 用来分档：
## 最后 5 秒换更急的音色，并**顶音量**。
##
## ★★ 2026-10-31（玩家：「开战倒计时 最后 5 秒 给提示音吧」）：
##   真相不是「没响」，是**响了听不见**。实测三个音源的电平（ffmpeg volumedetect）：
##     tick_01        mean −8.5 dB · max −1.2     ← 10~6 秒用
##     tick_urgent_01 mean −14.0 dB · max −4.5    ← 5~4 秒用，**比普通 tick 还轻 5.5 dB**
##     phase_prep_bgm mean −13.8 dB · max −1.7    ← 同时还在放
##   ⇒ 本想「最后 5 秒更强调」，实际素材电平更低，0.17 秒的短促点击被 BGM 整个盖住，
##     玩家听到的就是「最后一秒突然一声 count，前面没提示」。
##   ⇒ 用**增益补偿**把它顶上来（不换素材：换素材要重录，且短音本身是对的）。
## ⚠️ 补偿量按实测差值给，不是随手加：要让 tick_urgent 与普通 tick 至少打平，
##    再加 2 dB 当「紧迫感」；改素材的话这两个常量要重新量。
const TICK_URGENT_DB := 7.5
## 读秒语音更轻（count_3 实测 mean −16.5 dB）—— 三声 count 是全流程最关键的提示，
## 被音乐盖住等于没有。给同样的量级。
const COUNT_VOICE_DB := 7.0

func play_tick(seconds_left: int) -> void:
	if sfx_off():
		return
	var selected_ui := get_node_or_null("/root/EveUiAudio")
	if selected_ui != null and selected_ui.handles("round.tick"):
		if selected_ui.play("round.urgent" if seconds_left <= 5 else "round.tick"):
			_count["amb"] += 1
		return
	var urgent := seconds_left <= 5
	var key := "tick_urgent" if urgent else "tick"
	var vol := TICK_URGENT_DB if urgent else 0.0
	if _play_from(_amb_bank, key, _amb_players, 1.0, 1.0, false, vol):
		_count["amb"] += 1
	else:
		_note_missing(key)


## 开战读秒（3 / 2 / 1），`n` = 剩余数。
##
## ⚠️ 缺音源时**不计数**：早期实现无论播没播都 `amb += 1`，
##    验收看到「倒计时响了 3 次」其实一声没响 —— 这是静默的假通过。
func play_countdown(n: int) -> void:
	if sfx_off():
		return
	var selected_ui := get_node_or_null("/root/EveUiAudio")
	if selected_ui != null and selected_ui.handles("round.count1"):
		if selected_ui.play("round.count%d" % clampi(n, 1, 3)):
			_count["amb"] += 1
		return
	var key := "count_%d" % clampi(n, 1, 3)
	if _play_from(_amb_bank, key, _amb_players, 1.0, 1.0, false, COUNT_VOICE_DB):
		_count["amb"] += 1
		return
	# 没有 count_N 就退到通用滴答；连滴答也没有才算真的缺
	if _play_from(_amb_bank, "tick", _amb_players, 1.0, 1.0, false, COUNT_VOICE_DB):
		_count["amb"] += 1
		return
	_note_missing(key)


## 节点推进 / 结算
func play_resolve() -> void:
	if sfx_off():
		return
	var selected_ui := get_node_or_null("/root/EveUiAudio")
	if selected_ui != null and selected_ui.handles("round.win"):
		return  # Outcome-specific feedback is emitted by the completed transaction.
	if _play_from(_amb_bank, "resolve", _amb_players, 1.0, 1.0, false):
		_count["amb"] += 1
	else:
		_note_missing("resolve")


func play_node_advance() -> void:
	if sfx_off():
		return
	var selected_ui := get_node_or_null("/root/EveUiAudio")
	if selected_ui != null and selected_ui.handles("run.next"):
		if selected_ui.play("run.next"):
			_count["amb"] += 1
		return
	if _play_from(_amb_bank, "node", _amb_players, 1.0, 1.0, false):
		_count["amb"] += 1
	else:
		_note_missing("node")


## ══════════════════════════════════════════════════════════════════
##  具名音效（牌桌 / UI）—— 2026-10-17 用户拍板入库
## ══════════════════════════════════════════════════════════════════

## 调用方只给**逻辑名**（`ddz_play` / `ddz_card_14` / `ddz_pair_13` / `boom` / `resolve` …），
## 由这里去 fx / amb 两个库里找。
##
## ⚠️ 为什么要找两个库：牌型音在 `assets/audio/sfx/`，而用户给「失败」拍的是
##    **复用现成的 `resolve`**（它在 ambience）⇒ 同一张事件表里会同时出现两个库的键。
##    调用方（牌桌）不该关心音源躺在哪个目录，这个转换只在这里做一次。
##
## ⛔ 不做节流：牌桌上的动作全部由**人手**触发（上限就是手速），
##    节流在这里只会把玩家刚按下的那一下吞掉 —— 听起来像按键失灵。
func play_cue(key: String) -> void:
	if sfx_off():
		return
	# ⛔ 不用音高抖动：叫地主/顺子 这类是**人声**，±几 % 的抖动毫无价值却有听感风险；
	#    需要变化的地方（boom）靠「一个键多份变体」在 _play_from 里随机挑，本来就够。
	if not _play_from(_sfx_bank, key, _cue_players, 1.0, 1.0, false) \
			and not _play_from(_amb_bank, key, _cue_players, 1.0, 1.0, false):
		_note_missing(key)
		return
	_count["cue"] = int(_count.get("cue", 0)) + 1


## 记一次「音源缺失」。只记一次避免刷屏，但**计数**要准 ——
## 验收靠 `stats()["missing"]` 判断「到底有没有真的播出来」。
func _note_missing(key: String) -> void:
	_count["missing"] = int(_count.get("missing", 0)) + 1
	if not _missing_reported.has(key):
		_missing_reported[key] = true
		push_warning("[EveAudio] 音源缺失（静默跳过）：%s" % key)


# ══════════════════════════════════════════════════════════════════
#  背景音乐
# ══════════════════════════════════════════════════════════════════

## 切 BGM。`which` = "prep" / "battle" / ""（停）。
##
## 交叉淡入：新曲在 idle player 上起播，两个 player 的音量在 MUSIC_FADE
## 秒内互换。**不要**直接 stop 再 play —— 那会有一个可听见的断口，
## 而准备↔战斗是每回合都发生的切换，断口会很烦。
func play_music(which: String) -> void:
	if which == _music_current:
		return
	# ★ 换曲 ⇒ 额外增益归零：鸭音是**上一首 / 上一场景**的状态，
	#   ⛔ 不归零会把牌桌的状态带进别的场景（不报错，只是音乐忽大忽小）。
	#   ⚠️ 归零放在 `which == _music_current` 那个早退之后 —— 同一首重新点播不该重置它。
	set_music_gain(0.0, 0.0)
	if which == "":
		_music_current = ""
		_music_fading = false
		_music_fade_t = 0.0
		# ⚠️ 两个 player 都要停：只停 active 的话，正在淡入的 idle 会留下一首
		#    「切了歌但还在响」的幽灵 BGM，且不报错（老 bug）。
		if _music_a != null:
			_music_a.stop()
		if _music_b != null:
			_music_b.stop()
		return
	var list: Array = _mus_bank.get(which, [])
	if list.is_empty():
		_note_missing(which)
		return
	var st: AudioStream = list[_rng.randi() % list.size()]
	# BGM 必须循环：准备段可能待 40 秒，而 EVE 的曲子只有 1~3 分钟，
	# 不 loop 的话放完就静音，玩家会以为游戏卡了。
	_set_loop(st, true)
	_music_idle.stream = st
	_music_idle.volume_db = -60.0
	_music_idle.play()
	# 淡入淡出交给 _process
	_music_fading = true
	_music_fade_t = 0.0
	_music_current = which
	_count["music"] += 1


var _music_fading := false
var _music_fade_t := 0.0


## ══════════════════════════════════════════════════════════════════
##  BGM 额外增益（鸭音）—— 公开接口
## ══════════════════════════════════════════════════════════════════

## 把正在播的 BGM 加/减 `db`（叠在设置窗的音乐音量滑杆**之上**），
## 用 `fade_sec` 秒平滑过渡（`0` = 立即生效）。
##
## ★ 典型用法（牌桌）：进场景 `set_music_gain(+5.0, 0.0)` → 空桌时比基准响 5 dB；
##   玩家第一次点按钮 `set_music_gain(0.0, 0.8)` → 平滑回到基准。
##
## ⚠️ 调用方**自己**负责只在需要时调一次（本函数不做"只降不升"之类的状态机）：
##    每次调用都是一次"再降一点"，连点按钮会把音量一路拖到听不见。
func set_music_gain(db: float, fade_sec: float = MUSIC_GAIN_FADE) -> void:
	_music_gain_from_db = _music_gain_db
	_music_gain_to_db = db
	_music_gain_t = 0.0
	_music_gain_fade = maxf(0.0001, fade_sec)
	if fade_sec <= 0.0001:
		_music_gain_db = db
	_apply_music_gain()


## 当前额外增益（dB）。验收用 + 排障用。
func music_gain_db() -> float:
	return _music_gain_db


## ⚠️ 落到 `AudioEffectAmplify` 上，⛔ 不动任何 bus volume（理由见字段顶注）。
func _apply_music_gain() -> void:
	if _music_gain_fx != null:
		_music_gain_fx.volume_db = _music_gain_db


## 每帧把增益往目标推一点。
func _tick_music_gain(delta: float) -> void:
	if is_equal_approx(_music_gain_db, _music_gain_to_db):
		return
	_music_gain_t += delta
	var k := clampf(_music_gain_t / _music_gain_fade, 0.0, 1.0)
	_music_gain_db = lerpf(_music_gain_from_db, _music_gain_to_db, k)
	if k >= 1.0:
		_music_gain_db = _music_gain_to_db
	_apply_music_gain()


## 在 Music 总线上找/建那个增益效果器（幂等）。
##
## ⚠️ 必须幂等：AudioServer 是**全局**的，同一个进程里第二、第三个 EveAudio 实例
##    （验收脚本一测一个实例）会看到前一个留下的效果器 ⇒ 直接复用，⛔ 别再叠一个
##    （叠两个 +5 dB 就变成 +10 dB，而且**不报错**）。
func _add_music_gain_effect() -> void:
	var idx := AudioServer.get_bus_index(BUS_MUSIC)
	if idx < 0:
		return
	for i in AudioServer.get_bus_effect_count(idx):
		var e := AudioServer.get_bus_effect(idx, i)
		if e is AudioEffectAmplify:
			_music_gain_fx = e as AudioEffectAmplify
			return
	_music_gain_fx = AudioEffectAmplify.new()
	AudioServer.add_bus_effect(idx, _music_gain_fx)


func _process(delta: float) -> void:
	_tick_music_gain(delta)
	if not _music_fading or _music_active == null:
		return
	_music_fade_t += delta
	var k := clampf(_music_fade_t / MUSIC_FADE, 0.0, 1.0)
	# 交叉：老曲 1→0，新曲 0→1
	_music_active.volume_db = linear_to_db(maxf(0.0001, 1.0 - k))
	_music_idle.volume_db = linear_to_db(maxf(0.0001, k))
	if k >= 1.0:
		_music_fading = false
		_music_active.stop()
		var t := _music_active
		_music_active = _music_idle
		_music_idle = t


# ══════════════════════════════════════════════════════════════════
#  内部工具
# ══════════════════════════════════════════════════════════════════

## 节流用的时间基准（秒）。
##
## ⚠️ 这是**模拟器时间**，不是墙钟时间。用墙钟的后果在快进/倍速下才会暴露：
##    无头验收一次 `debug_fast_forward_battle(12.0)` 在几百毫秒墙钟内跑完
##    12 秒战斗，墙钟节流于是把 12 秒里的上百次开火**压成 1~2 声** ——
##    不报错，只是「战斗听起来像没打」。玩家开倍速时遇到的是同一个 bug。
##    由战斗场景在每次开火/击毁回调里喂 `sim.elapsed`。
var _clock := 0.0


## 喂当前（模拟）时间。`_on_shot_fired` / `_on_unit_destroyed` 里调用。
func set_clock(seconds: float) -> void:
	_clock = seconds


## 节流：同一 key 在 window 秒内最多放 burst 声。返回 true = 应被吞掉。
##
## 令牌桶而不是「一刀切冷却」：桶里存最近几次播放的时间戳，
## 窗口外的自动出桶，桶满了才吞。
func _throttle(key: String, window: float, burst: int = 1) -> bool:
	# `_clock <= 0` 说明还没接过战斗时间（准备阶段 / 单元测试），退化到墙钟
	var now := _clock if _clock > 0.0 else Time.get_ticks_msec() / 1000.0
	var arr: Array = _recent.get(key, [])
	while not arr.is_empty() and now - float(arr[0]) >= window:
		arr.pop_front()
	if arr.size() >= burst:
		_count[key + "_throttled"] = int(_count.get(key + "_throttled", 0)) + 1
		return true
	arr.append(now)
	_recent[key] = arr
	return false


## 从 bank 里挑一个变体在池中轮转播放。返回 true = 播了。
##
## ⚠️ 选 player 用「最久未用优先」而不是简单轮转：
##    轮转在池满时会打断某个还没放完的音；
##    「找当前最闲的」让长音自然占住自己的 player。
func _play_from(bank: Dictionary, key: String, pool: Array[AudioStreamPlayer],
		pitch_min: float, pitch_max: float, jitter: bool,
		vol_db: float = 0.0) -> bool:
	var list: Array = bank.get(key, [])
	if list.is_empty():
		return false
	var p := _pick_player(pool)
	if p == null:
		return false
	# ★ 2026-10-31：逐次写 `volume_db`（含 0.0）。⛔ 不要写成「只有非 0 才设」——
	#   池里的 player 会被反复复用，残留的增益会让下一声（比如 phase_prep）莫名变大。
	p.volume_db = vol_db
	p.stream = list[_pick_variant(key, list.size())]
	# ⚠️ 独立 RNG：挑变体与音高抖动都走 _rng，不碰全局 randi()/randf_range，
	#    否则会让战斗 sim 的随机序列被音效打乱（验收用随机隔离测试守这条）。
	p.pitch_scale = _rng.randf_range(pitch_min, pitch_max) if jitter else 1.0
	p.play()
	return true


## 挑一个变体下标：**随机，但不与上一次相同**。
##
## ★ 2026-10-18 用户：「过和不要需要交替出现，用来增加趣味性」、
##   「避免出现连续两个"抢地主"听着很乏味」⇒ 同一个键连说两遍同一句最乏味。
##   ⇒ 「不要 / 过」放在同一个键下（`ddz_pass_01/02`）就**自动交替**，牌桌侧零代码。
##
## ⚠️ 只有 1 个变体时必然重复（那时无解，得靠调用方补音源）。
## ⚠️ 用「在剩下的 n-1 个里等概率抽」而不是「抽到重复就重抽」：
##    后者在 n=2 时会退化成近似死循环，且分布不平（会偏袒某一个）。
func _pick_variant(key: String, n: int) -> int:
	if n <= 1:
		return 0
	var last := int(_last_variant.get(key, -1))
	var i := 0
	if last < 0 or last >= n:
		i = _rng.randi() % n
	else:
		i = _rng.randi() % (n - 1)
		if i >= last:
			i += 1
	_last_variant[key] = i
	return i


func _pick_player(pool: Array[AudioStreamPlayer]) -> AudioStreamPlayer:
	if pool.is_empty():
		return null
	var best: AudioStreamPlayer = null
	var best_end := -INF
	for p in pool:
		if not p.playing:
			return p
		var st := p.stream
		if st == null:
			return p
		# end = 已播位置 - 时长：越接近 0 表示剩余时间越少。
		# ⚠️ 旧实现取「剩余最长」的，会把最忙的 player 抢来打断；
		#    这里取剩余最短（end 最大）的那个，打断代价最小。
		var end := p.get_playback_position() - float(st.get_length())
		if end > best_end:
			best_end = end
			best = p
	# 全都在响 —— 挑最接近结束的那个（打断的代价最小）
	return best


## 设循环。
##
## ⚠️ 属性名不统一：`AudioStreamOggVorbis` / `AudioStreamMP3` 用 `loop`，
##    而 `AudioStreamWAV` 用 `loop_mode`。写死其中一个，在另一种流上会
##    **静默失效不报错**（BGM 放一遍就停）。两种都试一遍最稳。
func _set_loop(st: AudioStream, on: bool) -> void:
	if st == null:
		return
	if "loop" in st:
		st.set("loop", on)
	if "loop_mode" in st:
		st.set("loop_mode",
				AudioStreamWAV.LOOP_FORWARD if on else AudioStreamWAV.LOOP_DISABLED)


## 验收 / 调试用：可断言的计数器快照。
func stats() -> Dictionary:
	var d := _count.duplicate()
	d["has_sfx"] = not _sfx_bank.is_empty()
	d["has_amb"] = not _amb_bank.is_empty()
	d["has_music"] = not _mus_bank.is_empty()
	d["music_current"] = _music_current
	return d


## 验收用：重开一局时清零计数（不清音源）
func reset_stats() -> void:
	for k in _count.keys():
		_count[k] = 0
	_recent.clear()
	_clock = 0.0


## 立即停掉一切（撤离 / 重开）
func stop_all() -> void:
	for p in _sfx_players:
		if p.playing:
			p.stop()
	for p in _boom_players:
		if p.playing:
			p.stop()
	for p in _amb_players:
		if p.playing:
			p.stop()
	for p in _cue_players:
		if p.playing:
			p.stop()
	if _music_a != null:
		_music_a.stop()
	if _music_b != null:
		_music_b.stop()
	_music_current = ""
	_music_fading = false
