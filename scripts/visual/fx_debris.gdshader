shader_type spatial;
render_mode cull_disabled;
// [NOTE] 本 shader **仍然使用 discard**，与同目录其它特效不同 —— 这是有意的：
//   残骸是不透明实体，改成 alpha 混合会出现排序错误（碎片互相穿透/错叠），
//   视觉损失大于收益。实测 5 艘船被击毁（约 100 块残骸）在 D3D12 + Intel Arc
//   上不触发设备丢失（godotengine/godot#120857 的触发阈值需要更多实例）。
//   ⚠️ 若将来出现「大规模会战开打就黑屏」，第一个怀疑对象就是这里：
//      把下方两处 discard 换成 alive 遮罩 + 改 blend_mix 再验一次。
uniform float age = 0.0;
uniform float delay = 0.0;
uniform float lifetime = 2.0;
uniform float seed = 0.0;
void fragment() {
	float t = age-delay;
	if(t<0.0 || t>=lifetime) { discard; }
	float cool=exp(-t*3.5);
	float plates=step(0.78, fract(UV.x*4.0+UV.y*3.0+seed));
	ALBEDO=vec3(0.12,0.15,0.19);
	METALLIC=0.7;
	ROUGHNESS=0.65;
	EMISSION=vec3(1.0,0.24,0.035)*(0.12+plates)*cool*4.0;
	// Opaque fragments retire through a fine dissolve, avoiding alpha sorting.
	float dissolve=smoothstep(lifetime*0.65,lifetime,t);
	float grain=fract(sin(dot(floor(UV*40.0),vec2(12.9898,78.233))+seed)*43758.5453);
	if(grain<dissolve) { discard; }
}
