shader_type spatial;
render_mode blend_add, unshaded, depth_draw_never, shadows_disabled, fog_disabled;

// A local-light pass over the ORIGINAL mesh/maps. Each craft owns its state;
// neither the comparison hulls nor the other ships share this animated pass.
uniform sampler2D glow_map : filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform mat4 craft_transform;
uniform float age = 0.0;
uniform float power = 0.0;
uniform float boost = 0.0;
uniform float shot_flash = 0.0;
uniform float seed = 0.0;
varying vec3 craft_position;

void vertex() {
	craft_position = (craft_transform * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec3 p = craft_position;
	vec3 original_glow = texture(glow_map, UV).rgb;
	float mask = max(original_glow.r, max(original_glow.g, original_glow.b));
	float rim = pow(1.0 - max(dot(normalize(NORMAL), normalize(VIEW)), 0.0), 3.6);
	float aft = smoothstep(-0.08, 0.23, p.z);
	float pulse_at = mix(0.30, -0.34, fract(age * 0.8 + seed));
	float pulse = exp(-pow((p.z - pulse_at) * 20.0, 2.0));
	float surface_detail = 0.55 + texture(normal_map, UV).g * 0.45;
	vec3 muzzle_delta = (p - vec3(0.0, 0.01, -0.26)) * vec3(5.0, 8.0, 4.0);
	float muzzle_light = exp(-dot(muzzle_delta, muzzle_delta));
	vec3 engine_light = mix(vec3(0.035, 0.55, 1.0), vec3(0.15, 0.85, 1.15), boost) *
		(aft * (0.09 + rim * 0.68) + mask * (0.65 + pulse * 3.2));
	vec3 gun_light = vec3(0.95, 0.35, 1.5) * muzzle_light *
		(0.22 + rim * 0.55 + mask) * shot_flash * 2.6;
	ALBEDO = (engine_light * power + gun_light) * surface_detail;
	ALPHA = 1.0;
}
