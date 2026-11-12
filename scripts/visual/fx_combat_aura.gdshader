shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
#include "res://scripts/visual/fx_screen_size.gdshaderinc"
#include "res://scripts/visual/fx_laser_power.gdshaderinc"

// Low-density scattering is drawn separately from the luminous body.
uniform vec3 point_a;
uniform vec3 point_b;
uniform vec2 bend = vec2(0.0);
uniform float width = 2.5;
uniform float age = 0.0;
uniform float propagation_time = 0.0;
uniform float lifetime = 0.38;
uniform float delay = 0.0;
uniform float energy = 0.22;
uniform float hold_fraction = 0.15;
uniform float seed = 0.0;
uniform int style = 0;
uniform bool laser_cycle = false;
uniform float miss_fraction = 1.0;
uniform float pattern_reference = 0.0;
uniform bool finite_packet = false;
uniform float packet_speed = 24.0;
uniform float packet_length = 0.40;
uniform vec4 tint : source_color = vec4(1.0, 0.6, 0.15, 1.0);
varying float path_length;
varying float draw_width;
void vertex() {
	path_length = length(point_b - point_a);
	draw_width = width * fx_pixel_scale(mix(point_a, point_b, UV.y), width, VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE);
	// A short, distant beam keeps a readable core without a halo wider than
	// the engagement itself. Preserve the original near-view scattering.
	draw_width = max(width, min(draw_width, path_length * 0.75));
	if (laser_cycle) { draw_width *= mix(0.20, 1.0, pow(laser_power(age - delay), 0.65)); }
	float padding = draw_width * 0.5;
	float u = (UV.y * (path_length + padding * 2.0) - padding) / max(path_length, 0.001);
	vec3 axis = normalize(point_b - point_a + vec3(0.00001));
	vec3 ref = abs(axis.y) > 0.95 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
	vec3 side = normalize(cross(axis, ref));
	vec3 up = normalize(cross(side, axis));
	vec3 offset = side * bend.x + up * bend.y;
	float curved_u = clamp(u, 0.0, 1.0);
	vec3 pos = mix(point_a, point_b, u) + offset * 4.0 * curved_u * (1.0 - curved_u);
	vec3 tangent = normalize(point_b - point_a + offset * (4.0 - 8.0 * u));
	vec3 facing = cross(tangent, normalize(INV_VIEW_MATRIX[3].xyz - pos));
	if (dot(facing, facing) < 0.00001) { facing = INV_VIEW_MATRIX[0].xyz; }
	pos += normalize(facing) * (UV.x - 0.5) * draw_width;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(pos, 1.0);
}
void fragment() {
	float path_u = clamp((UV.y * (path_length + draw_width) - draw_width * 0.5) / max(path_length,0.001),0.0,1.0);
	float t = age - delay - path_u * propagation_time;
	if (t < 0.0 || t >= lifetime) { discard; }
	// A capsule-shaped optical footprint: every point ON the beam has exactly
	// the same cross-section. Rounded falloff begins OUTSIDE its endpoints.
	// This avoids a swollen middle and a half-energy pinch at either end.
	float across = (UV.x - 0.5) * draw_width;
	float along = UV.y * (path_length + draw_width) - draw_width * 0.5;
	float sigma = draw_width * 0.125;
	float outside = max(max(-along, along - path_length), 0.0);
	float wings = exp(-(across * across + outside * outside) / (2.0 * sigma * sigma));
	float envelope = exp(-max(0.0, t - lifetime * hold_fraction) * 6.0 / lifetime) *
		(1.0 - smoothstep(lifetime * 0.7, lifetime, t));
	if (laser_cycle) { envelope = pow(laser_power(t), 1.5); }
	if (laser_cycle && miss_fraction<0.999) {
		envelope *= pow(1.0-smoothstep(miss_fraction,1.0,along/max(path_length,0.001)),1.6);
	}
	if (style == 2) {
		if (finite_packet) {
			float q = (t * packet_speed - along) / packet_length;
			if (q < 0.0 || q > 1.0 || along < 0.0 || along > path_length) { discard; }
			wings *= smoothstep(0.0, 0.12, q) * (1.0 - smoothstep(0.20, 1.0, q));
			envelope = 1.0;
		} else {
			float packet_u=pattern_reference>0.001 ? along/pattern_reference : UV.y;
			float packet = fract(packet_u * 7.0 - t * 12.0 + seed);
			wings *= exp(-pow((packet - 0.45) * 4.0, 2.0));
		}
	}
	if (style == 3) {
		envelope *= smoothstep(t / lifetime - 0.20, t / lifetime + 0.18, UV.y);
	}
	// Unshaded color is written directly, including HDR values.
	ALBEDO = tint.rgb * wings * envelope * energy;
	ALPHA = 1.0;
}
