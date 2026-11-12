shader_type spatial;
render_mode blend_add, unshaded, cull_back, depth_draw_never, fog_disabled, shadows_disabled;

uniform sampler2D turbulence : filter_linear_mipmap, repeat_enable;
uniform float age = 0.0;
uniform float seed = 0.0;
uniform float sheath = 0.0;
uniform float power = 1.0;
uniform float boost = 0.0;
varying float axial;

void vertex() {
	axial = 1.0 - UV.y;
	float throat = mix(0.48, 1.0, smoothstep(0.0, 0.14, axial));
	float taper = pow(max(1.0 - axial, 0.0), mix(0.78, 1.1, sheath));
	// The inner jet has pressure cells; the transparent outer skin rolls more
	// slowly, so two different shapes survive bloom instead of one blue rod.
	float cells = 1.0 - (0.15 + boost * 0.08) * (1.0 - cos(axial * 23.0 - 0.25 * sin(age * 9.0 + seed)));
	float roll = sin(UV.x * 18.8496 + axial * 9.0 - age * 8.0 + seed);
	VERTEX.xz *= throat * taper * mix(cells, 1.0 + roll * axial * 0.16, sheath);
}
void fragment() {
	float facing = pow(max(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0), 1.0);
	float noise = texture(turbulence, vec2(UV.x * 2.0 + seed, axial * 1.5 - age * 2.8)).r;
	float cells = pow(0.5 + 0.5 * cos(axial * 23.0 - 0.25 * sin(age * 9.0 + seed)), 5.0);
	float fade = pow(1.0 - smoothstep(0.13, 1.0, axial), 1.1);
	float throat = smoothstep(0.0, 0.025, axial);
	vec3 hot = mix(vec3(5.0, 6.2, 7.0), vec3(0.12, 2.7, 5.8), smoothstep(0.08 + boost * 0.10, 0.58 + boost * 0.12, axial));
	hot = mix(hot, vec3(0.025, 0.24, 1.7), smoothstep(0.55, 1.0, axial));
	float skin = smoothstep(0.24, 0.75, noise) * (0.65 + 0.35 * sin(UV.x * 25.13 + axial * 7.0 - age * 9.0));
	vec3 outer = mix(vec3(0.10, 1.4, 3.0), vec3(0.05, 0.10, 0.95), axial);
	outer = mix(outer, mix(vec3(0.25, 2.6, 4.3), vec3(0.08, 0.4, 1.8), axial), boost);
	vec3 core = hot * (0.42 + cells * (0.9 + boost * 0.28)) * (0.85 + noise * 0.2);
	ALBEDO = mix(core, outer * skin * (0.30 + boost * 0.22), sheath) * facing * fade * throat * power * (1.0 + boost * 0.40);
	ALPHA = 1.0;
}
