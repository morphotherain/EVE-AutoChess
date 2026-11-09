# 星舰万象棋（Star Chess）

> 主菜单第一层第一项的独立玩法。**复用** EVE 工程的舰船立绘 / 船表 / 按钮皮肤 / 字体，
> 自身只携带玩法逻辑。详见本目录各文件头部注释。

## 落位

```
scripts/starchess/
  sc_context.gd      autoload：场景间传参（指挥官 / 种子）
  sc_ship_adapter.gd 船表翻译层：EveShipTable.ROWS -> 自走棋卡池
  sc_shop_card.gd    顶部商店大卡（复用 EveShipArtView 画真立绘）
  sc_lobby.gd        选指挥官（6 人环 / 60s / 可重复选）
  sc_battle.gd       对局主界面
  sc_over.gd         结算
scenes/starchess/   对应 .tscn
data/starchess/     指挥官表等；舰船数据**不在这里**（走 adapter 读 EVE 表）
```

## 与 EVE 主玩法的边界

- **共用的真源**：`scripts/data/eve_ship_table.gd`（52 艘）、`assets/ships/*.png`（立绘）、
  `scripts/ui/eve_button_theme.gd`（按钮）、`scripts/ui/eve_font.gd`（字体）
- **不复用的**：EVE 的战斗流程、存档（`EveRunStore`）、关卡难度表
  —— 那些是「守卫边境」的语义，星舰万象棋有自己的回合与商店

## 主菜单接入点（`scripts/eve_main_menu.gd`，共 3 处）

1. 常量：`STAR_CHESS_MODE_ID` / `STAR_CHESS_SCENE`
2. `_build_top_table()`：在 `EXTRA_MODES` 循环**之前** `out.append(...)`
   —— 插在前面才是第一项，`_modes` 的顺序就是左列渲染顺序
3. `target_scene_for_start()`：分支返回 `STAR_CHESS_SCENE`，放在 `tier_id` 之前

## 已验证

运行：`godot --headless --path . --quit-after 900 res://tools/verify_starchess.tscn`

**28 / 28 通过**。走的是**真实点击链路**（`card_pressed` / `pressed` 信号），
不是直接调 `_on_buy()` —— 后者只能证明函数能跑，证明不了信号接对了。

| 环节 | 断言 |
|---|---|
| 大厅 | 场景可实例化 / 倒计时在跑 / 点选生效 / **指挥官允许重复选** |
| 买卡 | 商店 4 张 / 扣 3 能量 / 进手牌 / **能量不足被拒绝** |
| 上阵 | 点手牌进上阵区 / 手牌减少 / **满员时拒绝** |
| 刷新 | 首次免费 / 免费次数扣减 / 第二次扣 1 |
| 升级 | 等级 +1 / 上阵上限 +1 |
| 合流 | 同名舰船 **+3 级** |
| 开战 | 回合推进 / 能量回复到 6 / 免费刷新重置 |

另：`tools/verify_menu.tscn` 主菜单自检 **63/63 通过**。

## 踩过的坑（改代码前先看）

1. **`get()` 拿到的 Array 是同一份引用**，不是副本。
   测试里 `var hand: Array = scene.get("_hand")` 之后 `hand.size()` 会跟着
   `_hand.remove_at()` 一起变 —— 比较前后数量必须**先存快照**。
2. **`_ready()` 期间 `root.add_child()` 会被拒绝**
   （`Parent node is busy setting up children`）。验收脚本必须先 `await process_frame`。
3. **自检里不要用 `_on_mode_pressed()` 切模式再切回**：自走棋默认展开，
   点它一次会折叠，后面的展开/收起断言会连锁失败。直接设 `_mode_idx` 再还原。
4. **价格不能放名称行**：卡窄，会挤到属性行上。现在挂在流派条右侧。

## 尚未实现

- 六流派的真实效果（用户说「等下弄」）
- 棋盘样式（占位，明确标注未实现）
- 战斗表现（当前是战力数值结算，非逐舰演出）
- 舰船技能文案（现按 role 生成，待独立技能表）
- 玩家淘汰 / 名次结算（结算场景是静态的）
