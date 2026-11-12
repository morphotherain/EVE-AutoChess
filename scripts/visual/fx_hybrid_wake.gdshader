shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
#include "res://scripts/visual/fx_screen_size.gdshaderinc"

// Scatter cropped pieces of the EVE electrical atlas across one continuous
// wake. An entire branch cluster is never stamped at regular path intervals.
uniform sampler2D atlas : filter_linear, repeat_disable;
uniform vec3 point_a;
uniform vec3 point_b;
uniform float width = 1.0;
uniform float effect_scale = 1.0;
uniform float age = 0.0;
uniform float propagation_time = 0.0;
uniform bool accelerating_front = false;
uniform float initial_speed = 0.8;
uniform float flight_acceleration = 120.0;
uniform float lifetime = 0.82;
uniform float delay = 0.018;
uniform float seed = 0.0;
uniform float energy = 1.2;
uniform vec4 tint : source_color = vec4(0.14, 1.0, 0.68, 1.0);
varying float path_length;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7)) + seed * 17.3) * 43758.5453);
}
vec2 tile_uv(vec2 p, float frame) {
	return (clamp(p, vec2(0.008), vec2(0.992)) + vec2(mod(frame, 8.0), floor(frame / 8.0))) / 8.0;
}
float fragment_field(vec2 p, float layer, float t) {
	vec2 grid = p / vec2(0.47 + layer * 0.13, 0.22 + layer * 0.025);
	// Stagger rows and warp the domain once in space, independent of time.
	grid.x += sin(grid.y * 2.3 + seed) * 0.34 + layer * 4.71;
	grid.y += sin(p.x * 2.6 + seed * 1.7) * 0.35 + layer * 2.13;
	vec2 cell = floor(grid);
	float choice = hash(cell + layer * 19.7);
	if (choice < 0.55 + layer * 0.15) { return 0.0; }
	vec2 q = fract(grid) - 0.5;
	q -= (vec2(hash(cell + 3.7), hash(cell + 8.1)) - 0.5) * 0.28;
	float edge = (1.0 - smoothstep(0.18, 0.48, abs(q.x))) *
		(1.0 - smoothstep(0.15, 0.47, abs(q.y)));
	float angle = hash(cell + 5.3) * 6.283185;
	float c = cos(angle), s = sin(angle);
	// A narrow crop severs the original coral-like clusters into short forks.
	vec2 crop = mat2(vec2(c, s), vec2(-s, c)) * (q * vec2(0.56, 0.24));
	crop += vec2(0.30 + hash(cell + 7.3) * 0.40, 0.30 + hash(cell + 9.9) * 0.40);
	float frame = mod(floor(hash(cell + 11.2) * 61.0) + t * 2.5, 64.0);
	float f0 = floor(frame), f1 = mod(f0 + 1.0, 64.0);
	float strand = mix(texture(atlas, tile_uv(crop, f0)).r,
		texture(atlas, tile_uv(crop, f1)).r, smoothstep(0.0, 1.0, fract(frame)));
	float cell_life = lifetime * mix(0.70, 1.0, hash(cell + 13.1));
	float fade = 1.0 - smoothstep(cell_life * 0.18, cell_life, t);
	return pow(strand, 2.4) * edge * fade * mix(0.60, 1.15, choice);
}
void vertex() {
	path_length = length(point_b - point_a);
	vec3 axis = normalize(point_b - point_a + vec3(0.00001));
	vec3 pos = mix(point_a, point_b, UV.y);
	vec3 side = cross(axis, normalize(INV_VIEW_MATRIX[3].xyz - pos));
	if (dot(side, side) < 0.00001) { side = INV_VIEW_MATRIX[0].xyz; }
	float pixel_scale = fx_pixel_scale(pos, width, VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE);
	pos += normalize(side) * (UV.x - 0.5) * width * pixel_scale;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(pos, 1.0);
}
void fragment() {
	float arrival = UV.y * propagation_time;
	if (accelerating_front) {
		float distance = UV.y * path_length;
		arrival = (sqrt(initial_speed * initial_speed + 2.0 * flight_acceleration * distance) - initial_speed) / flight_acceleration;
	}
	float t = age - delay - arrival;
	if (t < 0.0 || t >= lifetime) { discard; }
	vec2 p = vec2(UV.y * path_length, (UV.x - 0.5) * width) / effect_scale;
	// Advect the original fragments as one coherent wake. Exponential drag
	// reduces forward speed continuously; the source boundary empties rather
	// than wrapping the field and generating fresh electricity behind it.
	float drift_time = max(0.0, t - 0.055);
	float travel = 5.2 * (1.0 - exp(-4.5 * drift_time)) / 4.5;
	vec2 carried = p - vec2(travel, 0.0);
	float strands = fragment_field(carried, 0.0, t) + fragment_field(carried + vec2(0.19, 0.08), 1.0, t) * 0.30;
	strands *= smoothstep(0.0, 0.06, carried.x);
	float radial = exp(-pow(p.y / 0.24, 2.0) * 1.5) * (1.0 - smoothstep(0.32, 0.50, abs(p.y)));
	float ends = smoothstep(0.0, 0.025, UV.y) * (1.0 - smoothstep(0.975, 1.0, UV.y));
	float ignite = smoothstep(0.0, 0.015, t);
	ALBEDO = mix(tint.rgb, vec3(0.85, 1.0, 0.96), 0.50) * strands * radial * ends * ignite * energy * 3.0;
	ALPHA = 1.0;
}
