shader_type spatial;
render_mode blend_add, unshaded, depth_draw_never, shadows_disabled, fog_disabled;

// A displaced sensor return of the ORIGINAL hull. No ship material is edited.
uniform sampler2D hull_map : source_color, filter_linear_mipmap, repeat_enable;
uniform mat4 mesh_to_field;
uniform float hull_span = 1.0;
uniform float age = 0.0;
uniform float seed = 0.0;
uniform float power = 0.0;
uniform float strength = 0.35;
uniform float layer_weight = 1.0;
uniform bool screen_compensation = true;
uniform bool echo = true;
uniform float return_weight = 1.0;
varying vec3 hull_point;

void vertex() {
	hull_point = (mesh_to_field * vec4(VERTEX, 1.0)).xyz / max(hull_span, 0.001);
}

void fragment() {
	// Broad slices move continuously across a return. The narrow leading edge
	// and fine scan lines have different scales; this is not a full-hull flash.
	float s = fract(hull_point.z * 1.75 + hull_point.x * 0.58 + hull_point.y * 0.21
		- age * 0.19 + seed);
	float band = smoothstep(0.015, 0.065, s) * (1.0 - smoothstep(0.27, 0.39, s));
	float line = exp(-pow((s - 0.072) * 100.0, 2.0));
	float scan_phase = hull_point.y * 62.0 + hull_point.z * 11.0 - age * 0.27;
	float scan = pow(max(0.0, sin(scan_phase * 6.283185)), 14.0);
	float aa = clamp(0.13 / max(fwidth(scan_phase), 0.13), 0.0, 1.0);
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 2.2);
	vec3 native_detail = texture(hull_map, UV).rgb;
	float plate = 0.55 + dot(native_detail, vec3(0.2126, 0.7152, 0.0722)) * 0.45;
	vec3 amber = vec3(1.0, 0.30, 0.035);
	vec3 gold = vec3(1.55, 0.88, 0.25);
	vec3 hot = vec3(2.0, 1.66, 0.92);
	float body = echo ? (0.05 + band * 0.25) : band * 0.035;
	float edge = echo ? rim * (0.13 + band * 0.78) : rim * band * 0.32;
	float readout = band * scan * aa * (0.15 + rim * 0.16);
	vec3 return_light = amber * body * plate + gold * (edge + readout) + hot * line * (echo ? 0.43 : 0.56);
	float gain = mix(0.86, 1.04, clamp((strength - 0.25) / 0.2, 0.0, 1.0));
	ALBEDO = return_light * power * layer_weight * return_weight * gain;
	ALPHA = 1.0;
}
