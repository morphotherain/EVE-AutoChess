shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
#include "res://scripts/visual/fx_screen_size.gdshaderinc"
#include "res://scripts/visual/fx_laser_power.gdshaderinc"

// Optical body of a pulse laser. Radiance is uniform along the path; animated
// detail is advected within the sheath rather than changing the beam's hue.
uniform vec3 point_a;
uniform vec3 point_b;
uniform float width = 0.7;
uniform float age = 0.0;
uniform float lifetime = 0.50;
uniform float delay = 0.0;
uniform float energy = 1.0;
uniform float core_fraction = 0.026;
uniform float filament_strength = 0.65;
uniform float miss_fraction = 1.0;
uniform vec4 tint : source_color = vec4(1.0, 0.8, 0.4, 1.0);
varying float beam_length;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), u.x), u.y);
}
float fbm(vec2 p) {
	return noise(p) * 0.57 + noise(p * 2.07 + 13.1) * 0.28 + noise(p * 4.19 + 7.3) * 0.15;
}
void vertex() {
	beam_length = length(point_b - point_a);
	vec3 axis = normalize(point_b - point_a);
	vec3 pos = mix(point_a, point_b, UV.y);
	vec3 side = cross(axis, normalize(INV_VIEW_MATRIX[3].xyz - pos));
	if (dot(side, side) < 0.00001) { side = INV_VIEW_MATRIX[0].xyz; }
	float pixel_scale = fx_pixel_scale(pos, width, VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE);
	float power = laser_power(age - delay);
	float tail_width = miss_fraction<0.999 ? mix(1.0,0.12,smoothstep(miss_fraction,1.0,UV.y)) : 1.0;
	pos += normalize(side) * (UV.x - 0.5) * width * pixel_scale * mix(0.18, 1.0, pow(power, 0.65)) * tail_width;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(pos, 1.0);
}
void fragment() {
	// [PITFALL] 禁用 discard（D3D12+Intel Arc 会设备丢失），改存活遮罩
	float alive = 1.0;
	float t = age - delay;
	if (t < 0.0 || t >= lifetime) { alive = 0.0; }
	float k = t / lifetime;
	float envelope = laser_power(t);
	if(miss_fraction<0.999) { envelope *= pow(1.0-smoothstep(miss_fraction,1.0,UV.y),1.4); }
	float x = (UV.x - 0.5) * 2.0;
	float s = UV.y * beam_length;
	float travel = s - t * 36.0;
	float fine = max(fwidth(x), 0.002);
	// Stable optical core plus a textured plasma sheath. Thin filaments are
	// independently displaced by coherent noise, without the old two hard rails.
	float core_radius = core_fraction + fine * 0.35;
	float core = 1.0 - smoothstep(core_radius, core_radius + fine * 1.4, abs(x));
	float turbulence = fbm(vec2(travel * 0.8, x * 18.0));
	float sheath = exp(-x * x * 32.0) * (0.40 + turbulence * 0.60);
	float envelope_edge = exp(-x * x * 8.0) * (0.25 + turbulence * 0.75);
	float threads = 0.0;
	for (int i = 0; i < 5; i++) {
		float n = float(i);
		float center = (n - 2.0) * 0.13 + (noise(vec2(travel * 0.65 + n * 3.7, n + 4.1)) - 0.5) * 0.09;
		float d = abs(x - center);
		float line = 1.0 - smoothstep(0.003, 0.003 + fine * 1.2, d);
		float gaps = smoothstep(0.24, 0.58, noise(vec2(travel * 2.4 + n * 5.3, n)));
		threads += line * gaps;
	}
	float tips = smoothstep(0.0, 0.055, s) * smoothstep(0.0, 0.055, beam_length - s);
	vec3 hot = vec3(1.9, 1.75, 1.35) * core;
	vec3 body = tint.rgb * (sheath * 0.60 + threads * filament_strength + envelope_edge * 0.08);
	ALBEDO = (hot + body) * envelope * tips * energy * alive;
	ALPHA = 1.0;
}
