extends RefCounted
class_name EveIntroScript

## 「守卫边境」开场通讯 —— 游戏内唯一真源。
##
## ⚠️ 时间码与 `data/intro/时间轴.csv` **同源**（那份是给"离线出透明视频"用的）。
##    改开场 = 改这张表；如果想同步更新那份透明视频，把 CSV 也一起改。
##    格式：`时:分:秒:帧`，**30 fps**（帧 0~29）。视频长度 23.104 s（实测）。
##
## 三处「空」的语义（与 CSV 一致）：
##   · 台词留空  ⇒ 这一段不出对话框（片头）
##   · 结束 < 下一句切入 ⇒ 中间留纯画面空档
##   · 时间留空  ⇒ 这一段交给信标展开动画（末句）

const FPS := 30.0

## 背景视频（Godot 的 VideoStream 只认 .ogv / Ogg Theora，见 README 那条实测结论）
const VIDEO := "res://assets/video/intro_guard_border.ogv"
const VIDEO_LEN := 23.104                       ## 实测

## 末段：信标展开视频（飞船放出信标 → 传送门展开，16.63 s）
## ★ 2026-11-02：原来这一段的 3D 信标展开动画（EveCynoBeacon）换成实拍视频整段播放。
##   时间码全部相对**第一段视频结束点**。
const VIDEO2 := "res://assets/video/intro_beacon.ogv"
const VIDEO2_LEN := 16.63                       ## ffmpeg 实测时长
const VIDEO2_IN := 24.40                        ## 第二段开始（末句 t1≈24.27 播完之后）
const PROMPT_AT := VIDEO2_IN + VIDEO2_LEN + 0.20   ## 出「▶ 进入边境」的时刻（≈41.23）
## 「跳过对话」的落点：只差 RAMP 那么一点点就到提示 ⇒ 点一次就能进边境，
## 不再像以前那样「跳到末段后还要干等、再点一次」。
const SKIP_TO := VIDEO2_IN + VIDEO2_LEN - 0.15

## 逐字速度（字/秒）。窗口装不下时按窗口反推提速（不截断）。
const CPS := 18.0
const MIN_READ := 0.35                          ## 一句至少留这么多秒

## 说话人：呼号 → 立绘 + 语义色（沿用工程既有配色）
const SPEAKERS := {
	"队长": {"portrait": "res://assets/portraits/头像_队长.png", "color": Color(0.55, 0.78, 0.82)},
	"斥候": {"portrait": "res://assets/portraits/头像_斥候.png", "color": Color(0.35, 0.70, 0.90)},
	"玩家": {"portrait": "res://assets/portraits/头像_玩家.png", "color": Color(0.93, 0.96, 0.97)},
}

## 台词表：`[说话人, 台词, 切入, 结束]`
## 说话人留空 = 这一段不出框（片头）；结束留空 = 由末段常量接管。
const LINES := [
	["",     "",                                   "00:00:00:00", "00:00:02:18"],
	["玩家", "暂时未发现敌军踪迹，无异常。",           "00:00:02:19", "00:00:04:07"],
	["队长", "我还在守着空间站，我方舰队还在后方集结",   "00:00:04:08", "00:00:06:03"],
	["玩家", "现在这个星系只有我们几个了",             "00:00:06:04", "00:00:07:10"],
	["斥候", "隐身斥候报告",                         "00:00:07:12", "00:00:08:14"],
	["斥候", "星门另一侧有小股部队集结，大约 80 艘战列以下常规混编", "00:00:08:15", "00:00:11:10"],
	["队长", "才这么点，大概率是来拖慢我们节奏的，那就不可能全部进", "00:00:11:11", "00:00:13:17"],
	["玩家", "那怎么办，本星系守卫舰队就我还有作战能力了", "00:00:13:18", "00:00:15:07"],
	["队长", "你那艘破船也不够看，联盟标配的移动诱导没忘带了吧？", "00:00:15:08", "00:00:17:20"],
	["玩家", "不带被发现会被罚款的，来这也是为了挣点盒饭", "00:00:17:21", "00:00:19:12"],
	["队长", "带了就好，在几跳外我们舰队也在集结",       "00:00:19:13", "00:00:21:03"],
	["队长", "你点亮诱导他们就能跳进来，失效前守好信标我给你奖金！", "00:00:21:04", "00:00:23:02"],
	["玩家", "那为了星币，干了！",                    "",            ""],
]


## `时:分:秒:帧` → 秒。空串 → -1（表示"没填"）。
static func tc_to_sec(s: String) -> float:
	if s.strip_edges() == "":
		return -1.0
	var p := s.split(":")
	if p.size() != 4:
		push_warning("[开场] 时间码格式不对：'%s'（应为 时:分:秒:帧）" % s)
		return -1.0
	return (float(p[0].to_int()) * 3600.0 + float(p[1].to_int()) * 60.0
			+ float(p[2].to_int()) + float(p[3].to_int()) / FPS)


## 展开成运行时结构：`{who, text, t0, t1, cps, box}`
static func build() -> Array:
	var out: Array = []
	var prev_end := 0.0
	for row in LINES:
		var who := String(row[0])
		var text := String(row[1])
		var t0 := tc_to_sec(String(row[2]))
		var t1 := tc_to_sec(String(row[3]))
		var box := text != ""
		if t0 < 0.0:
			t0 = prev_end                                   # 末句：紧接上一句
		if t1 < 0.0:
			t1 = t0 + maxf(1.20, float(text.length()) / CPS + 0.35)
		var cps := CPS
		if box:
			var win := t1 - t0
			var need := float(text.length()) / CPS
			if need > win - MIN_READ:
				cps = float(text.length()) / maxf(win - MIN_READ, 0.20)
				push_warning("[开场] 第 %d 句窗口 %.2fs 装不下 %.2fs ⇒ 提速到 %.1f 字/秒"
						% [out.size() + 1, win, need, cps])
		out.append({"who": who, "text": text, "t0": t0, "t1": t1, "cps": cps, "box": box})
		prev_end = t1
	return out


## 开场总时长（不含玩家点「进入边境」的等待）—— 用于验收
static func total() -> float:
	var ls := build()
	return PROMPT_AT if ls.is_empty() else maxf(PROMPT_AT, float(ls[-1]["t1"]))
