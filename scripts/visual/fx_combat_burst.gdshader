shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
#include "res://scripts/visual/fx_screen_size.gdshaderinc"
#include "res://scripts/visual/fx_laser_power.gdshaderinc"

uniform float age = 0.0;
uniform float lifetime = 0.3;
uniform float delay = 0.0;
uniform float seed = 0.0;
uniform float energy = 3.0;
uniform float hold_fraction = 0.10;
uniform float strength = 1.0;
uniform int shape = 0; // halo, ring, muzzle, impact, grid, status ring
uniform bool billboard = true;
uniform vec3 firing_axis = vec3(0.0);
uniform vec4 tint : source_color = vec4(1.0, 0.6, 0.15, 1.0);
uniform float remaining = 1.0;
uniform bool laser_cycle = false;
uniform bool charge_cycle = false;
uniform bool compact_muzzle = false;
uniform sampler2D electric_map : filter_linear, repeat_enable;

void vertex() {
	float base_size = max(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	VERTEX *= fx_pixel_scale(MODEL_MATRIX[3].xyz, base_size, VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE);
	if (charge_cycle) { VERTEX *= mix(0.22,1.0,pow(clamp((age-delay)/lifetime,0.0,1.0),1.5)); }
	if (laser_cycle) { VERTEX *= mix(0.35, 1.0, pow(laser_power(age - delay), 0.55)); }
	if (billboard) {
		vec3 right = INV_VIEW_MATRIX[0].xyz;
		vec3 up = INV_VIEW_MATRIX[1].xyz;
		if (dot(firing_axis, firing_axis) > 0.01) {
			vec2 projected = vec2(dot(firing_axis, right), dot(firing_axis, up));
			if (dot(projected, projected) > 0.001) {
				projected = normalize(projected);
				right = INV_VIEW_MATRIX[0].xyz * projected.x + INV_VIEW_MATRIX[1].xyz * projected.y;
				up = -INV_VIEW_MATRIX[0].xyz * projected.y + INV_VIEW_MATRIX[1].xyz * projected.x;
			}
		}
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4(right, 0.0) * length(MODEL_MATRIX[0].xyz),
			vec4(up, 0.0) * length(MODEL_MATRIX[1].xyz),
			INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2].xyz),
			MODEL_MATRIX[3]);
		MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	}
}

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), u.x), u.y);
}

void fragment() {
	float t = age - delay;
	if (t < 0.0 || (shape < 4 && t >= lifetime)) { discard; }
	float k = clamp(t / max(lifetime, 0.001), 0.0, 1.0);
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float angle = atan(p.y, p.x);
	float fade = shape >= 4 ? strength : (1.0 - smoothstep(hold_fraction, 1.0, k));
	if (laser_cycle) { fade = laser_power(t); }
	if (charge_cycle) { fade = smoothstep(0.0,0.12,k)*pow(k,1.4)*(1.0-smoothstep(0.96,1.0,k)); }
	float core = exp(-r * r * 100.0);
	float halo = exp(-r * r * 4.8);
	float mask = 1.0 - smoothstep(0.85, 1.0, r);
	vec3 c = tint.rgb;
	vec3 radiance = vec3(0.0);
	if (shape == 0) {
		radiance = vec3(1.0, 0.96, 0.86) * core * 0.8 + c * halo * 0.22;
	} else if (shape == 1) {
		float radius = mix(0.18, 0.84, 1.0 - pow(1.0 - k, 3.0));
		float ring_distance = (r - radius) * 38.0;
		float ring = exp(-ring_distance * ring_distance);
		float cuts = smoothstep(0.18, 0.5, noise(vec2(angle * 6.0 + seed, seed)));
		radiance = c * ring * cuts * 0.65;
	} else if (shape == 2) {
		// Advected, irregular hot gas, aligned with the firing direction.
		vec2 q = vec2(p.x * 1.2, p.y * 2.7);
		float turbulence = noise(q * 4.0 + vec2(-t * 13.0, seed)) * 0.65 + noise(q * 10.0 + seed) * 0.35;
		float body = exp(-dot(q, q) * 3.3);
		float gas = smoothstep(k * 0.65, k * 0.65 + 0.38, body * (0.65 + turbulence));
		// Signed offsets must be squared directly: pow(negative, 2) is
		// undefined on GPU backends and can leak through the zero edge mask.
		float tongue_distance = (p.y + (turbulence - 0.5) * 0.22) * 11.0;
		float tongue = exp(-tongue_distance * tongue_distance) * exp(-abs(p.x) * 3.0);
		radiance = vec3(1.0, 0.92, 0.72) * (core * 1.8 + tongue * 0.55) + c * gas * 0.65;
		if (compact_muzzle) {
			// Small strikecraft expose both sides of a main-cannon-size flash.
			// Keep its hot front lobe; discard the faint, cool side wisps that
			// would otherwise form broad grey strips behind the tiny hull.
			float hot = core * 1.8 + tongue * tongue * 0.72;
			radiance = vec3(1.0, 0.84, 1.2) * hot + c * gas * 0.85;
			float brightness = max(radiance.r, max(radiance.g, radiance.b));
			radiance *= smoothstep(0.035, 0.16, brightness) * smoothstep(-0.5, -0.12, p.x);
		}
	} else if (shape == 3) {
		float cell = noise(p * 6.0 - t * 3.0 + seed) * 0.7 + noise(p * 15.0 + seed) * 0.3;
		float cloud = exp(-r * r * mix(22.0, 4.0, k));
		float dissolve = smoothstep(k * 0.70, k * 0.70 + 0.30, cell * cloud);
		radiance = vec3(1.0, 0.97, 0.86) * core * pow(1.0 - k, 3.0) * 2.0 + c * (dissolve * 0.7 + halo * 0.12);
	} else if (shape == 4) {
		float grid = pow(max(abs(sin(p.x * 27.0 + t * 1.3)),
			abs(sin(p.y * 23.0 - t * 1.5))), 22.0);
		float radial_distance = (r - 0.57) * 10.0;
		float radial = exp(-radial_distance * radial_distance);
		float scan = pow(max(0.0, cos(p.y * 7.0 - t * 4.0)), 8.0);
		radiance = c * (grid * 0.30 + radial * 0.45 + scan * grid * 0.6) * halo;
	} else {
		float radius = 0.72;
		float ring_distance = (r - radius) * 42.0;
		float ring = exp(-ring_distance * ring_distance);
		float seg = step(0.28, fract((angle + 3.141592) / 6.283185 * 12.0));
		float arc = step((angle + 3.141592) / 6.283185, remaining);
		float inner_distance = (r - 0.54) * 33.0;
		float inner = exp(-inner_distance * inner_distance) * 0.25;
		radiance = c * (ring * seg * (0.10 + arc) + inner) *
			(0.8 + 0.2 * sin(t * 5.0));
	}
	// Unshaded color is written directly, including HDR values.
	ALBEDO = radiance * energy * fade * mask;
	ALPHA = 1.0;
}
