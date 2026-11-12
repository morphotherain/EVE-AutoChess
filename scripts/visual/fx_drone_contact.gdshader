shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
#include "res://scripts/visual/fx_screen_size.gdshaderinc"

// Reuses EVE's original splash/optical-flow atlas, with a short violet release.
uniform sampler2D atlas : filter_linear, repeat_disable;
uniform sampler2D flow_atlas : filter_linear, repeat_disable;
uniform float age = 0.0;
uniform float delay = 0.0;
uniform float lifetime = 0.25;
uniform float rotation = 0.0;
uniform float energy = 2.4;
// Marker contract: this contact always faces the camera and follows the shield.
uniform bool billboard = true;
uniform vec3 firing_axis = vec3(0.0);
vec2 tile_uv(vec2 p, float frame) {
	return (clamp(p, vec2(0.008), vec2(0.992)) + vec2(mod(frame, 8.0), floor(frame / 8.0))) / 8.0;
}
void vertex() {
	float size = length(MODEL_MATRIX[0].xyz);
	VERTEX *= fx_pixel_scale(MODEL_MATRIX[3].xyz, size, VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE);
	float k = clamp((age - delay) / lifetime, 0.0, 1.0);
	VERTEX *= mix(0.32, 1.0, 1.0 - exp(-k * 10.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * size,
		INV_VIEW_MATRIX[1] * size, INV_VIEW_MATRIX[2] * size, MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}
void fragment() {
	float t = age - delay;
	if (t < 0.0 || t >= lifetime) { discard; }
	float k = t / lifetime;
	float c = cos(rotation), s = sin(rotation);
	vec2 p = mat2(vec2(c, s), vec2(-s, c)) * (UV - 0.5) + 0.5;
	if (any(lessThan(p, vec2(0.0))) || any(greaterThan(p, vec2(1.0)))) { discard; }
	float frame = k * 32.0;
	float f0 = floor(frame), f1 = min(f0 + 1.0, 63.0), blend = fract(frame);
	vec2 v0 = texture(flow_atlas, tile_uv(p, f0)).rg * 2.0 - 1.0;
	vec2 v1 = texture(flow_atlas, tile_uv(p, f1)).rg * 2.0 - 1.0;
	vec4 a = texture(atlas, tile_uv(p - v0 * blend * 0.025, f0));
	vec4 b = texture(atlas, tile_uv(p + v1 * (1.0 - blend) * 0.025, f1));
	vec4 texel = mix(a, b, blend);
	float heat = max(texel.r, max(texel.g, texel.b));
	float fade = (1.0 - smoothstep(0.35, 1.0, k)) * smoothstep(0.0, 0.006, t);
	vec3 color = mix(vec3(0.46, 0.10, 1.0), vec3(1.25, 1.0, 1.5), smoothstep(0.35, 0.9, heat));
	ALBEDO = color * heat * texel.a * fade * energy;
	ALPHA = 1.0;
}
