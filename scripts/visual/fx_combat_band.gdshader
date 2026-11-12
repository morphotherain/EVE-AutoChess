shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
#include "res://scripts/visual/fx_screen_size.gdshaderinc"
uniform vec3 point_a = vec3(0.0);
uniform vec3 point_b = vec3(0.0, 0.0, -10.0);
uniform vec2 bend = vec2(0.0);
uniform float width = 0.3;
uniform float age = 0.0;
uniform float propagation_time = 0.0;
uniform float lifetime = 0.18;
uniform float delay = 0.0;
uniform float seed = 0.0;
uniform int style = 0;
uniform vec4 tint : source_color = vec4(1.0, 0.55, 0.08, 1.0);
uniform float energy = 1.0;
uniform float strength = 1.0;
uniform float pattern_reference = 0.0;
uniform vec3 packet_core = vec3(1.0, 0.92, 0.65);
uniform bool finite_packet = false;
uniform float packet_speed = 24.0;
uniform float packet_length = 0.40;
varying float path_length;
uniform sampler2D beam_map : filter_linear, repeat_disable;
uniform sampler2D electric_map : filter_linear, repeat_enable;
uniform sampler2D pulse_map : filter_linear, repeat_enable;
void vertex() {
	path_length=length(point_b-point_a);
	vec3 axis = normalize(point_b - point_a + vec3(0.00001));
	vec3 ref = abs(axis.y) > 0.95 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
	vec3 lateral = normalize(cross(axis, ref));
	vec3 vertical = normalize(cross(lateral, axis));
	float u = UV.y;
	vec3 offset = lateral * bend.x + vertical * bend.y;
	vec3 pos = mix(point_a, point_b, u) + offset * 4.0 * u * (1.0 - u);
	vec3 tangent = normalize(point_b - point_a + offset * (4.0 - 8.0 * u));
	vec3 side = cross(tangent, normalize(INV_VIEW_MATRIX[3].xyz - pos));
	if (dot(side, side) < 0.00001) { side = INV_VIEW_MATRIX[0].xyz; }
	float pixel_scale = fx_pixel_scale(pos, width, VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE);
	pos += normalize(side) * (UV.x - 0.5) * width * pixel_scale;
	pos += MODEL_MATRIX[3].xyz;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(pos, 1.0);
}
void fragment() {
	float t = age - delay - UV.y * propagation_time;
	if (t < 0.0 || (style < 5 && t >= lifetime)) { discard; }
	float k = clamp(t / max(lifetime, 0.001), 0.0, 1.0);
	float x = (UV.x - 0.5) * 2.0;
	float ends = smoothstep(0.0, 0.012, UV.y) * (1.0 - smoothstep(0.985, 1.0, UV.y));
	float packet_u=UV.y;
	if(pattern_reference>0.001) {
		float distance=UV.y*path_length;
		float soft_tip=max(0.04,pattern_reference*0.012);
		ends=smoothstep(0.0,soft_tip,distance)*(1.0-smoothstep(path_length-soft_tip,path_length,distance));
		packet_u=distance/pattern_reference;
	}
	float core = exp(-x * x * 95.0);
	float sheath = pow(max(0.0, 1.0 - x * x), 4.0);
	float fade = 1.0 - smoothstep(0.20, 1.0, k);
	vec3 radiance = vec3(0.0);
	if (style == 0) {
		// The luminous body and broad scattering pass have separate geometry.
		float edge = exp(-pow((abs(x) - 0.46) * 12.0, 2.0));
		float flow = texture(pulse_map, vec2(UV.x, UV.y * 0.5 - t * 0.4)).r;
		radiance = vec3(1.0, 0.96, 0.79) * core * 1.8 + tint.rgb * (sheath * 0.42 + edge * (0.2 + flow * 0.16));
	} else if (style == 1) {
		fade = pow(1.0 - k, 1.25);
		radiance = vec3(0.82, 1.0, 0.95) * core * 2.1 + tint.rgb * sheath * 0.30;
	} else if (style == 2) {
		float packet = fract(packet_u * 7.0 - t * 12.0 + seed);
		float head = smoothstep(0.1, 0.22, packet) * (1.0 - smoothstep(0.38, 0.62, packet));
		float tail = smoothstep(0.05, 0.20, packet) * (1.0 - smoothstep(0.30, 0.85, packet));
		if (finite_packet) {
			float q = (t * packet_speed - UV.y * path_length) / packet_length;
			if (q < 0.0 || q > 1.0) { discard; }
			head = smoothstep(0.0, 0.12, q) * (1.0 - smoothstep(0.24, 0.85, q));
			tail = smoothstep(0.0, 0.10, q) * (1.0 - smoothstep(0.12, 1.0, q));
			fade = 1.0;
		}
		radiance = packet_core * core * head * 2.3 + tint.rgb * sheath * tail * 0.70;
		if (finite_packet) {
			float q = (t * packet_speed - UV.y * path_length) / packet_length;
			float flow = texture(pulse_map, vec2(UV.x, q * 0.7 - t * 3.0)).r;
			float flank_distance = (abs(x) - 0.52) * 17.0;
			float flanks = exp(-flank_distance * flank_distance);
			radiance += tint.rgb * flanks * head * (0.25 + flow * 0.65);
			float tip_distance = (q - 0.17) * 16.0;
			radiance += packet_core * core * exp(-tip_distance * tip_distance) * 1.3;
		}
	} else if (style == 3) {
		fade *= smoothstep(k - 0.20, k + 0.18, UV.y);
		float cells = texture(pulse_map, vec2(UV.x, UV.y * 0.8 - t * 0.3 + seed * 0.17)).r;
		radiance = vec3(0.75, 0.9, 1.0) * core * 1.2 + tint.rgb * sheath * (0.25 + cells * 0.35);
	} else {
		fade = strength;
		float segment = smoothstep(0.10, 0.30, fract(UV.y * 16.0 - t * 0.55 + seed));
		float field = texture(electric_map, vec2(UV.y * 2.0 - t * 0.12, UV.x)).g;
		radiance = tint.rgb * sheath * (segment * 0.65 + field * 0.35);
	}
	// Unshaded color is written directly, including HDR values.
	ALBEDO = radiance * energy * fade * ends;
	ALPHA = 1.0;
}
