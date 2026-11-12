shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

// Native EVE motion-vector flame frames supply the volume detail. Keep only
// the hot rolling frames; the late smoke frames never enter this composition.
uniform sampler2D atlas : filter_linear, repeat_disable;
uniform sampler2D flow_atlas : filter_linear, repeat_disable;
uniform float age = 0.0;
uniform float seed = 0.0;
uniform float delay = 0.075;
uniform float lifetime = 0.55;
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0].xyz),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1].xyz),
		INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2].xyz), MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}
vec2 tile(vec2 p, float frame) {
	return (clamp(p, vec2(0.008), vec2(0.992)) + vec2(mod(frame, 8.0), floor(frame / 8.0))) / 8.0;
}
void fragment() {
	float t = age - delay;
	if (t < 0.0 || t >= lifetime) { discard; }
	float k = t / lifetime;
	float c = cos(seed), s = sin(seed);
	vec2 p = mat2(vec2(c, s), vec2(-s, c)) * (UV - 0.5) + 0.5;
	if (any(lessThan(p, vec2(0.0))) || any(greaterThan(p, vec2(1.0)))) { discard; }
	float frame = mix(3.0, 18.0, k);
	float f = floor(frame), blend = fract(frame);
	vec2 v0 = texture(flow_atlas, tile(p, f)).rg * 2.0 - 1.0;
	vec2 v1 = texture(flow_atlas, tile(p, f + 1.0)).rg * 2.0 - 1.0;
	vec4 a = texture(atlas, tile(p - v0 * blend * 0.025, f));
	vec4 b = texture(atlas, tile(p + v1 * (1.0 - blend) * 0.025, f + 1.0));
	vec4 flame = mix(a, b, blend);
	float heat = clamp(flame.r, 0.0, 1.0);
	float coverage = flame.a * smoothstep(0.12, 0.36, heat);
	vec3 light = mix(vec3(0.025, 0.13, 0.50), vec3(0.95, 0.48, 0.07), smoothstep(0.15, 0.85, heat));
	light = mix(light, vec3(1.1, 1.05, 0.70), smoothstep(0.92, 1.0, heat));
	float envelope = smoothstep(0.0, 0.018, t) * (1.0 - smoothstep(0.18, 0.85, k));
	ALBEDO = light * pow(heat, 1.6) * coverage * envelope * 0.60;
	ALPHA = 1.0;
}
