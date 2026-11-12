shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
#include "res://scripts/visual/fx_screen_size.gdshaderinc"

// Nova heavy missile's 8x8 motion-particle maps, adapted to Godot.
// RGB is intensity, A is coverage; the companion RG map stores optical flow.
uniform sampler2D atlas : filter_linear, repeat_disable;
uniform sampler2D flow_atlas : filter_linear, repeat_disable;
uniform sampler2D color_ramp : source_color, filter_linear, repeat_disable;
uniform sampler2D heat_ramp : source_color, filter_linear, repeat_disable;
uniform float age = 0.0;
uniform float lifetime = 0.9;
uniform float delay = 0.0;
uniform float rotation = 0.0;
uniform float energy = 2.4;
uniform float density = 0.9;
uniform float temperature = 1.0;
uniform float first_frame = 0.0;
uniform float last_frame = 55.0;
uniform float growth = 1.0;

vec2 tile_uv(vec2 p, float frame) {
	return (clamp(p, vec2(0.008), vec2(0.992)) + vec2(mod(frame, 8.0), floor(frame / 8.0))) / 8.0;
}
void vertex() {
	float base_size = max(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	VERTEX *= fx_pixel_scale(MODEL_MATRIX[3].xyz, base_size, VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE);
	float k = clamp((age - delay) / lifetime, 0.0, 1.0);
	float expand = mix(0.34, growth, 1.0 - exp(-k * 12.0));
	VERTEX *= expand;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0].xyz),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1].xyz),
		INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2].xyz), MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}
void fragment() {
	float t = age - delay;
	if (t < 0.0 || t >= lifetime) { discard; }
	float k = t / lifetime;
	float c = cos(rotation), s = sin(rotation);
	vec2 p = mat2(vec2(c, s), vec2(-s, c)) * (UV - 0.5) + 0.5;
	if (any(lessThan(p, vec2(0.0))) || any(greaterThan(p, vec2(1.0)))) { discard; }
	float frame = mix(first_frame, last_frame, k);
	float f0 = floor(frame), f1 = min(f0 + 1.0, 63.0), blend = fract(frame);
	vec2 v0 = texture(flow_atlas, tile_uv(p, f0)).rg * 2.0 - 1.0;
	vec2 v1 = texture(flow_atlas, tile_uv(p, f1)).rg * 2.0 - 1.0;
	// Warp both samples towards the same intermediate instant before blending.
	vec4 a = texture(atlas, tile_uv(p - v0 * blend * 0.025, f0));
	vec4 b = texture(atlas, tile_uv(p + v1 * (1.0 - blend) * 0.025, f1));
	vec4 texel = mix(a, b, blend);
	// Retain fire in the rolling frames. Low-intensity regions are transparent
	// light, never dark smoke coverage over the ship.
	float heat = clamp(texel.r * temperature * mix(1.0, 2.2, k), 0.0, 1.0);
	// The orange ramp is symmetric; use its rising half so hotter texels stay
	// brighter. Sampling across both halves would turn a fireball into a rim.
	vec3 fire = texture(color_ramp, vec2(heat * 0.5, 0.5)).rgb;
	vec3 ember = texture(heat_ramp, vec2(heat, 0.5)).rgb;
	float envelope = smoothstep(0.0, 0.008, t) * (1.0 - smoothstep(0.55, 1.0, k));
	// A purely additive flame cannot darken a bright ship/background. Bound
	// each layer's radiance before salvos overlap, preserving orange detail.
	float coverage = texel.a * smoothstep(0.10, 0.30, heat) * density * envelope;
	vec3 radiance = fire * (0.25 + heat * 0.85) + ember * pow(heat, 2.0) * energy * 0.12;
	ALBEDO = radiance * coverage * 0.70;
	ALPHA = 1.0;
}
