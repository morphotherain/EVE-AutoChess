shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
#include "res://scripts/visual/fx_screen_size.gdshaderinc"

// Finite glints left by a switched-off laser. Evaluate the same source seeds
// at advected coordinates: no scrolling noise, wraparound or new emitters.
uniform vec3 point_a;
uniform vec3 point_b;
uniform float width = 0.50;
uniform float effect_scale = 1.0;
uniform float age = 0.0;
uniform float lifetime = 0.44;
uniform float delay = 0.54;
uniform float seed = 0.0;
uniform float miss_fraction = 1.0;
uniform vec4 tint : source_color = vec4(1.0, 0.8, 0.38, 1.0);
varying float path_length;

float hash(float p) {
	return fract(sin(p * 127.1 + seed * 17.3) * 43758.5453);
}
vec3 glints(vec2 p, float layer, float t, vec2 footprint) {
	float drag = 5.0;
	float speed = 4.8 + layer * 1.1;
	float velocity = speed * exp(-drag * t);
	float travel = (speed - velocity) / drag;
	float spacing = 0.57 + layer * 0.12;
	float origin_cell = floor((p.x - travel) / spacing);
	vec3 light = vec3(0.0);
	for (int i = -1; i <= 1; i++) {
		float cell = origin_cell + float(i);
		float id = cell + layer * 317.7;
		float x0 = (cell + 0.18 + hash(id) * 0.64) * spacing;
		// The switched-off beam already leaves a source-to-distance falloff.
		// Attach it to each glint's birth position so forward drift cannot
		// brighten or regenerate it. Misses use the original engagement span.
		float origin_fraction = x0 / max(path_length * miss_fraction / effect_scale, 0.001);
		if (x0 < 0.04 || origin_fraction >= 0.98 || hash(id + 1.7) < 0.25 + layer * 0.22) {
			continue;
		}
		float distance_fade = pow(max(0.0, 1.0 - origin_fraction), 1.25) *
			(1.0 - smoothstep(0.72, 0.98, origin_fraction));
		float cell_life = lifetime * mix(0.58, 1.0, hash(id + 2.3));
		float fade = 1.0 - smoothstep(0.025, cell_life, t);
		float y0 = (hash(id + 4.9) - 0.5) * (0.14 + layer * 0.15);
		vec2 d = p - vec2(x0 + travel, y0);
		// Cover at least a pixel in both directions in a distant camera. The
		// source positions and their spacing still use real path distances.
		vec2 core_radius = max(vec2(0.023, 0.010), footprint * 0.65);
		vec2 halo_radius = max(vec2(0.068, 0.036), footprint * 1.1);
		float core = exp(-dot(d / core_radius, d / core_radius) * 1.4);
		float halo = exp(-dot(d / halo_radius, d / halo_radius) * 1.5);
		// A short rear streak contracts as each packet slows down.
		float stretch = max(mix(0.026, 0.14, velocity / speed), footprint.x * 0.7);
		float streak = exp(-pow(d.y / max(0.016, footprint.y * 0.7), 2.0) * 1.6) *
			exp(-abs(d.x) / stretch * 2.0) * (1.0 - smoothstep(0.0, 0.025, d.x));
		float brightness = mix(0.65, 1.3, hash(id + 8.2)) * distance_fade * fade;
		light += (vec3(1.8, 1.65, 1.28) * core + tint.rgb * (halo * 0.65 + streak * 0.75)) * brightness;
	}
	return light;
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
	float t = age - delay;
	if (t < 0.0 || t >= lifetime) { discard; }
	vec2 p = vec2(UV.y * path_length, (UV.x - 0.5) * width) / effect_scale;
	vec2 footprint = fwidth(p);
	vec3 light = glints(p, 0.0, t, footprint) + glints(p, 1.0, t, footprint) * 0.42;
	float ends = smoothstep(0.0, 0.04, p.x) * smoothstep(0.0, 0.06, path_length / effect_scale - p.x);
	float fade = smoothstep(0.0, 0.018, t);
	if (miss_fraction < 0.999) { fade *= 1.0 - smoothstep(miss_fraction, 1.0, UV.y); }
	ALBEDO = light * ends * fade;
	ALPHA = 1.0;
}
