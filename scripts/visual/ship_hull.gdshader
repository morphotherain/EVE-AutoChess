shader_type spatial;

// ═══════════════════════════════════════════════════════════════════════════
// EVE 自走棋 —— 舰船外壳材质（把 Blender 侧的配方搬进引擎）
// ═══════════════════════════════════════════════════════════════════════════
//
// 为什么需要它：
//   glTF **表达不了中间节点**。Blender 侧的金属度/粗糙度是由 `_s` 材质分区图
//   经 ColorRamp / MapRange 驱动的节点图，导出 glb 时只能退化成常量 + 一张
//   原始 MR 贴图。实测导入结果（tools/probe_ship_material.gd 打的）：
//       metallic_tex = `_s` 图 ch=BLUE   roughness_tex = `_s` 图 ch=GREEN
//       metallic = 1.0（因子）            roughness = 1.0（因子）
//   ⇒ 引擎里实际是 `metallic = spec` 原值 = 0.345 / 0.682 / 0.780，
//     而正确值是 0 / 0.80 / 0.95。
//     两个后果：**白甲板被当成 34.5% 金属**（发银灰）、**金饰只有 78% 金属度**
//     （该亮的地方不亮）。粗糙度同理偏大。
//
// 本着色器把那条 ramp 原样复现。数学在 ship_hull_ramp.gdshaderinc 里，
// 那份文件被探针 include 走同一份代码做数值比对。
//
// 四张官方图各自的位置（来自管线，`_s` 是分区图不是渐进高光）：
//   `_d` → ALBEDO      白甲 + 金饰已经画在图里，**不要再叠派系色**
//   `_n` → 法线        1024² 承载卷草纹 / 板缝 / 喷口，低模的立体感全靠它
//   `_s` → METALLIC / ROUGHNESS（本文件的主角）
//   `_e` → 自发光      大多数船近全黑，留槽备用（当前 glb 里没接，见文件尾注）
//
// ⚠️ 没有 `_s` 图**不要**套这个材质：uniform 缺省值是白 ⇒ ramp 饱和到 0.97，
//    整船变全金属。EveShipMaterial 有这道闸（见那边 apply() 的注释）。
//
// 变更清单（新建）：
//   - 四张图 + ramp 复现 Blender 的 metallic / roughness
//   - spec_gain / spec_bias 两个调参口，留给"按派系微调"（默认 = 忠实复刻）
//   - 自发光槽（has_emissive 默认 false）

// `_s` 是**单通道灰度图**（1024²、mode=L，实测 |R-G|=|G-B|=0），取 r 即可。
// 声明为数据而非颜色：不加 source_color —— 它本来就是线性数据。
uniform sampler2D spec_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D emissive_tex : hint_default_black, filter_linear_mipmap, repeat_enable;

// Blender 侧 Normal Map 节点 Strength = 1.25
uniform float normal_strength : hint_range(0.0, 4.0) = 1.25;

// Blender 侧 R_WHITE / R_GOLD（白甲板粗糙度上限 / 金饰下限）
uniform float r_white : hint_range(0.0, 1.0) = 0.62;
uniform float r_gold : hint_range(0.0, 1.0) = 0.18;

// 按派系微调的预留口：s' = clamp(spec * spec_gain + spec_bias)
//   默认 1.0 / 0.0 = 忠实复刻 Blender 那条 ramp，四派系一视同仁。
//   加达里(0.63~0.73) / 盖伦特(0.57~0.81) 的值档与艾玛(0.35~0.78) 不同，
//   要让四派系各自准确就得动这两个值 —— 那是重新设计，需要有依据再做。
uniform float spec_gain : hint_range(0.1, 4.0) = 1.0;
uniform float spec_bias : hint_range(-1.0, 1.0) = 0.0;

// ═══════════════════════════════════════════════════════════════════════════
// 舰船亮度补偿（2026-09-21）
// ═══════════════════════════════════════════════════════════════════════════
//
// 实测：备战席态船体掩膜 p50 = 32/255，而同帧星云背景 p50 = 130/255
//       ⇒ 船/背景 = 0.249 —— 船比背景暗 4 倍。
// 根因不是「灯不够亮」，而是**金属度太高 + albedo 太暗**：
//   · 本 ramp 按艾玛值档标定，加达里实测 spec 0.631/0.678/0.725
//     ⇒ 整船金属度 0.63/0.79/0.87 —— **加达里没有一处是 0 金属**；
//   · 金属的镜面 F0 = ALBEDO ⇒ **深色金属 = 深色镜子**，
//     反射到的星云再亮，也被自己的深色 albedo 乘掉。
//   实测敏感度（同机位同船，只拧一个旋钮）：
//     head 0.40→2.00 ⇒ p50 ×1.46   ·   sky 0.86→2.00 ⇒ ×1.42
//     sun  0.95→2.00 ⇒ ×1.16       ·   amb 0.50→4.00 ⇒ ×1.00（**无效**）
//   即：**纯靠灯光，p50 最多也就到 47**，永远追不上背景的 130。
//
// 所以这里给一个「船壳提亮」口。两条曲线各有分工，**默认都是恒等**：
//   · albedo_gain —— 线性增益。等比抬全部，会先烧掉已经很亮的白漆。
//   · albedo_lift —— 伽马提亮 `pow(c, 1/lift)`。**暗部抬得多、亮部抬得少**
//     （lift=2 时 c=0.05→0.22 抬 4.4x，c=0.70→0.84 只抬 1.2x），
//     这正是「深色船壳需要细节、白漆不该爆」要的形状。
//
// ⚠️ 它抬的是 ALBEDO，而金属的 F0 = ALBEDO ⇒ 顺带把镜面反射一起抬亮，
//    「船壳提亮」和「金属更亮」是同一刀，不需要再动 roughness。
// ⚠️ 这是**有意的偏离**（Blender 侧是忠实复刻，没有这一步）。
//    口径：ramp 的数学（金属度/粗糙度分区）继续忠实复刻，
//    抬亮只作用在 albedo 上，属于"打光补偿"而非"改材质配方"。
uniform float albedo_gain : hint_range(0.2, 4.0) = 1.0;
uniform float albedo_lift : hint_range(1.0, 4.0) = 1.0;

uniform bool has_emissive = false;
uniform vec3 emissive_color : source_color = vec3(1.0);
uniform float emissive_energy : hint_range(0.0, 8.0) = 1.0;

#include "res://scripts/visual/ship_hull_ramp.gdshaderinc"
#include "res://scripts/visual/fx_hull_destruction.gdshaderinc"

void vertex() {
	death_local = (VERTEX - death_center) / max(death_extent, vec3(0.001));
}

void fragment() {
	float spec = clamp(texture(spec_tex, UV).r * spec_gain + spec_bias, 0.0, 1.0);

	vec3 alb = texture(albedo_tex, UV).rgb;
	// 恒等快路径：两个参数都是默认值时**逐位等于原实现**，
	// 否则 pow() 的浮点误差会让「没调过」的船也轻微变色。
	if (albedo_lift > 1.0005 || albedo_gain != 1.0) {
		alb = pow(alb, vec3(1.0 / max(albedo_lift, 0.0001))) * albedo_gain;
	}
	ALBEDO = alb;
	METALLIC = eve_metal_ramp(spec);
	ROUGHNESS = eve_roughness(spec, r_white, r_gold);

	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = normal_strength;

	// `_e` 目前没进 glb（管线没接自发光），这里留槽：
	// 将来把 _e 接上之后，EveShipMaterial 会自动把 has_emissive 打开。
	if (has_emissive) {
		EMISSION = texture(emissive_tex, UV).rgb * emissive_color * emissive_energy;
	}
	if (death_active) {
		vec3 p = death_local * 5.0 + vec3(death_seed);
		vec2 cells = death_cells(p * 1.8);
		float noise = death_noise(p * 2.0) * 0.67 + death_noise(p * 5.1) * 0.33;
		float heat = smoothstep(0.10, 0.36, age);
		float dissolve = smoothstep(0.34, 1.30, age);
		float threshold = mix(-0.08, 1.08, dissolve);
		if (noise < threshold) { discard; }
		float cracks = exp(-pow(cells.y * 32.0, 2.0));
		float edge = (1.0 - smoothstep(0.0, 0.075, noise - threshold)) * step(0.01, dissolve);
		float hot = (cracks * 0.65 + edge * 1.5) * heat;
		ALBEDO *= mix(1.0, 0.24, heat);
		EMISSION += vec3(1.0, 0.18, 0.025) * hot * 3.0 + vec3(1.0,0.68,0.20) * pow(hot,3.0) * 1.2;
	}
}
