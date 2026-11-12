shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
#include "res://scripts/visual/fx_screen_size.gdshaderinc"
uniform float width = 0.45;
uniform float opacity = 1.0;
uniform float age = 0.0;
uniform float lifetime = 99999.0;
void vertex() {
	vec3 side = cross(NORMAL, normalize(INV_VIEW_MATRIX[3].xyz - VERTEX));
	if (dot(side, side) < 0.00001) { side = INV_VIEW_MATRIX[0].xyz; }
	float pixel_scale = fx_pixel_scale(VERTEX, width, VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE);
	vec3 pos = VERTEX + normalize(side) * (UV.x - 0.5) * width * pixel_scale * mix(1.4, 0.35, UV.y);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(pos, 1.0);
}
void fragment() {
	float x = UV.x * 2.0 - 1.0;
	float fade = smoothstep(0.0, 0.75, UV.y);
	float halo = pow(max(0.0, 1.0 - x * x), 3.0);
	float thin = exp(-x * x * 45.0);
	float release = 1.0 - smoothstep(0.0, lifetime, age);
	ALBEDO = (vec3(0.08, 0.25, 0.72) * halo * 0.16 + vec3(0.25, 0.6, 1.0) * thin * 0.45) * fade * opacity * release;
	ALPHA = 1.0;
}
