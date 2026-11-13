shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;

// Three soft axial ribbons replace the opaque-looking cylindrical skin.
// Local +Z points behind the missile. UV.y explicitly runs nozzle -> plume tip.
uniform sampler2D turbulence : filter_linear_mipmap, repeat_enable;
uniform float age = 0.0;
uniform float seed = 0.0;
uniform float sheath = 0.0; // 0 pressure, 1 outer, 2 visible core, 3 auxiliary, 4 optical HDR glow
uniform float power = 0.0;
uniform float brightness = 0.0;
uniform float nozzle_z = 0.1008;
void vertex() {
	float drive = smoothstep(0.0, 1.9, power);
	float jet_length = mix(0.52, 1.04, drive);
	float jet_width = mix(0.090, 0.125, drive);
	if (sheath > 0.5 && sheath < 1.5) {
		jet_length *= 1.16;
		jet_width *= 2.1;
	}
	if ((sheath > 1.5 && sheath < 2.5) || sheath > 3.5) {
		jet_length *= 0.62;
		jet_width *= 0.22;
	}
	if (sheath > 2.5 && sheath < 3.5) {
		jet_length *= 0.44;
		jet_width *= 0.48;
	}
	vec3 nozzle = (MODEL_MATRIX * vec4(0.0, 0.0, nozzle_z, 1.0)).xyz;
	vec3 axis = normalize(MODEL_MATRIX[2].xyz);
	float object_scale = length(MODEL_MATRIX[2].xyz);
	vec3 center = nozzle + axis * UV.y * jet_length * object_scale;
	vec3 side = cross(axis, normalize(INV_VIEW_MATRIX[3].xyz - center));
	if (dot(side, side) < 0.00001) { side = INV_VIEW_MATRIX[0].xyz; }
	vec3 p = center + normalize(side) * (UV.x * 2.0 - 1.0) * jet_width * object_scale;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(p, 1.0);
}
void fragment() {
	// [PITFALL] 禁用 discard（D3D12+Intel Arc 会设备丢失）。
	//   本材质是 blend_add，radiance 里已乘 pow(power,0.72)，power≈0 时本就是 0。
	float alive = power <= 0.0001 ? 0.0 : 1.0;
	float u = UV.y;
	float x = UV.x * 2.0 - 1.0;
	float n = texture(turbulence, vec2(u * 2.6 - age * 1.9, x * 1.1 + seed)).r;
	float fine = texture(turbulence, vec2(u * 6.8 - age * 4.2, x * 2.5 + seed * 0.37)).r;
	float throat = smoothstep(0.0, 0.022, u);
	float end_fade = 1.0 - smoothstep(0.38, 1.0, u);
	// A narrow throat opens once, then converges through a few pressure cells.
	float chamber = mix(0.24, 0.72, smoothstep(0.0, 0.11, u));
	float phase = u * 4.15 + 0.035 * sin(age * 5.0 + seed);
	float cell = abs(fract(phase) - 0.5) * 2.0;
	float radius = chamber * pow(max(1.0 - u, 0.001), 0.78) * (0.80 + 0.20 * cell);
	float r = x / max(radius, 0.015);
	float body = exp(-r * r * 3.2);
	float diamond = 1.0 - smoothstep(0.28, 0.64, cell * 0.70 + abs(r) * 0.36);
	vec3 light;
	if (sheath < 0.5) {
		vec3 thermal = mix(vec3(0.65, 1.75, 2.7), vec3(0.035, 0.30, 1.0), smoothstep(0.03, 0.85, u));
		light = thermal * body * (0.30 + n * 0.22);
		light += vec3(1.1, 1.9, 2.2) * diamond * body * (1.0 - u) * 0.55;
		light *= end_fade;
	} else if (sheath < 1.5) {
		// Break up the broad layer so it reads as flowing gas, without a hard
		// rim, a uniform blue sleeve or a decorative curling envelope.
		float outer_radius = (0.22 + 0.44 * smoothstep(0.0, 0.20, u)) * pow(1.0 - u, 0.72);
		float soft = exp(-x * x / max(outer_radius * outer_radius, 0.0001) * 3.0);
		float flow = smoothstep(0.24, 0.76, n * 0.72 + fine * 0.28);
		float filaments = 0.45 + 0.55 * pow(max(0.0, sin(x * 20.0 + u * 7.0 - age * 9.0 + seed)), 3.0);
		light = mix(vec3(0.035, 0.65, 1.5), vec3(0.018, 0.075, 0.48), u) * soft * flow * filaments * 0.38;
		light += vec3(0.10, 0.55, 1.0) * exp(-x * x * 16.0 - u * u * 45.0) * 0.30;
		light *= 1.0 - smoothstep(0.25, 1.0, u);
	} else if (sheath < 2.5 || sheath > 3.5) {
		float core_radius = mix(0.70, 0.32, u) * pow(1.0 - u, 0.9);
		float core = exp(-x * x / max(core_radius * core_radius, 0.0001) * 5.0);
		vec3 heat = mix(vec3(13.0, 16.0, 18.0), vec3(0.45, 2.6, 4.3), smoothstep(0.12, 0.85, u));
		light = heat * core * (0.70 + fine * 0.12) * (1.0 - smoothstep(0.25, 1.0, u));
	} else {
		float core = exp(-r * r * 13.0);
		vec3 thermal = mix(vec3(0.50, 2.4, 4.2), vec3(0.035, 0.30, 1.0), u);
		light = thermal * body * (0.65 + n * 0.30);
		light += mix(vec3(4.0, 6.0, 7.5), vec3(0.10, 0.65, 1.8), u) * core * (0.70 + fine * 0.15);
		light *= end_fade;
	}
	// This renderer's unshaded path reads radiance from ALBEDO and ignores
	// EMISSION. Preserve the narrow HDR peak for bloom without widening it.
	// Raise optical glow through HDR radiance; main-jet dimensions stay fixed.
	float radiance_gain = sheath < 2.5 || sheath > 3.5 ? 1.35 : 1.0;
	vec3 radiance = light * throat * pow(power, 0.72) * radiance_gain * alive;
	if (sheath > 1.5 && sheath < 2.5) {
		// Ordinary visible flame responds immediately with engine power.
		ALBEDO = min(radiance, vec3(1.0));
	} else if (sheath > 3.5) {
		// Splitting the surplus, instead of dimming every flame, preserves
		// the established main/auxiliary jets while only bloom grows slowly.
		ALBEDO = max(radiance - vec3(1.0), vec3(0.0)) * brightness;
	} else {
		ALBEDO = radiance;
	}
	ALPHA = 1.0;
}
