shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled;
#include "res://scripts/visual/fx_screen_size.gdshaderinc"
uniform float kind = 0.0;
uniform float remaining = 1.0;
uniform float opacity = 1.0;
uniform vec2 offset = vec2(0.0);
float segment(vec2 p, vec2 a, vec2 b) {
	vec2 d = b - a;
	return length(p - a - d * clamp(dot(p - a, d) / dot(d, d), 0.0, 1.0));
}
void vertex() {
	float scale = fx_pixel_scale(MODEL_MATRIX[3].xyz, 0.32 * length(MODEL_MATRIX[0].xyz), VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0].xyz),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1].xyz),
		INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2].xyz), MODEL_MATRIX[3]);
	VERTEX.xy = (VERTEX.xy + offset) * scale;
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float aa = max(fwidth(p.x), fwidth(p.y));
	float d;
	if (kind < 0.5) {
		float wave = abs(p.y - sin(p.x * 10.0) * 0.13);
		d = max(wave - 0.055, abs(p.x) - 0.62);
		d = min(d, segment(p, vec2(-0.25, -0.58), vec2(0.0, -0.34)) - 0.055);
		d = min(d, segment(p, vec2(0.0, -0.34), vec2(0.25, -0.58)) - 0.055);
	} else {
		vec2 q = abs(p + vec2(sign(p.y) * 0.08, 0.0));
		d = min(max(abs(q.x - 0.51) - 0.045, q.y - 0.55), max(abs(q.y - 0.51) - 0.045, q.x - 0.55));
		d = max(d, 0.25 - min(q.x, q.y));
		d = min(d, segment(p, vec2(-0.29, 0.29), vec2(0.29, -0.29)) - 0.055);
	}
	float symbol = 1.0 - smoothstep(-aa, aa, d);
	float panel = 1.0 - smoothstep(0.84, 0.90, max(abs(p.x), abs(p.y)));
	float timer = (1.0 - smoothstep(0.035, 0.065, abs(p.y - 0.74))) * step(abs(p.x), 0.62);
	float fill = step(p.x, -0.62 + remaining * 1.24);
	vec3 tint = kind < 0.5 ? vec3(1.0, 0.68, 0.24) : vec3(0.61, 0.52, 1.0);
	ALBEDO = mix(vec3(0.012, 0.016, 0.035), tint, max(symbol, timer * (0.2 + fill * 0.7)));
	ALPHA = panel * opacity * 0.95;
}
