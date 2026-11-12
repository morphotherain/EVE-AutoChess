shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
#include "res://scripts/visual/fx_screen_size.gdshaderinc"

uniform float width = 0.08;
uniform float opacity = 1.0;
void vertex() {
	vec3 side = cross(NORMAL, normalize(INV_VIEW_MATRIX[3].xyz - VERTEX));
	if (dot(side, side) < 0.00001) { side = INV_VIEW_MATRIX[0].xyz; }
	float scale = fx_pixel_scale(VERTEX, width, VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE);
	float spread = mix(0.2, 1.0, clamp(UV.y, 0.0, 1.0));
	vec3 pos = VERTEX + normalize(side) * (UV.x - 0.5) * width * spread * scale;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(pos, 1.0);
}
void fragment() {
	float x = UV.x * 2.0 - 1.0;
	float recent = clamp(UV.y, 0.0, 1.0);
	float ends = smoothstep(0.0, 0.32, recent) * (1.0 - smoothstep(0.97, 1.0, recent));
	float core = exp(-x * x * 60.0);
	float edge = exp(-x * x * 5.5);
	vec3 light = vec3(0.6, 1.2, 1.8) * core * 0.90 + vec3(0.025, 0.35, 1.0) * edge * 0.38;
	ends *= smoothstep(0.40, 0.94, recent) * recent;
	ALBEDO = light * ends * opacity;
	ALPHA = 1.0;
}
