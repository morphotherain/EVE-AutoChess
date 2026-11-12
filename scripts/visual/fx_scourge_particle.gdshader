shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
// INSTANCE_CUSTOM: delay, lifetime, rotation, per-particle intensity.
uniform sampler2D atlas : filter_linear, repeat_disable;
uniform sampler2D flow_atlas : filter_linear, repeat_disable;
uniform sampler2D color_ramp : source_color, filter_linear, repeat_disable;
uniform sampler2D heat_ramp : source_color, filter_linear, repeat_disable;
uniform sampler2D layer_1 : filter_linear_mipmap, repeat_enable;
uniform sampler2D layer_2 : filter_linear_mipmap, repeat_enable;
uniform float age = 0.0;
uniform float atlas_grid = 4.0;
uniform float kind = 0.0; // 0: motion-vector flash; 1: caustic wisps; 2: headed jets; 3: flare
uniform float energy = 1.0;
uniform float speed = 1.0;
uniform vec3 tint : source_color = vec3(0.5, 1.0, 0.95);
uniform vec3 grade = vec3(1.0);
varying vec4 particle;
varying float t;
varying float k;

void vertex() {
	particle = INSTANCE_CUSTOM;
	t = age - particle.x;
	k = clamp(t / max(particle.y, 0.001), 0.0, 1.0);
	vec3 center = MODEL_MATRIX[3].xyz;
	vec3 velocity = MODEL_MATRIX[2].xyz;
	float travel = (1.0 - exp(-4.0 * max(t, 0.0))) / 4.0;
	center += velocity * travel * speed;
	float sx = length(MODEL_MATRIX[0].xyz), sy = length(MODEL_MATRIX[1].xyz);
	float expand = mix(0.25, 1.0, 1.0 - exp(-k * 10.0));
	if (kind > 1.5) { expand = 1.0; }
	vec2 v = VERTEX.xy;
	if (kind > 1.5 && kind < 2.5) {
		vec2 projected = (VIEW_MATRIX * vec4(velocity, 0.0)).xy;
		if (length(projected) > 0.001) {
			vec2 along = normalize(projected);
			v = vec2(along.y, -along.x) * v.x * sx + along * v.y * sy;
		} else { v *= vec2(sx, sy); }
	} else {
		float c = cos(particle.z), s = sin(particle.z);
		v = mat2(vec2(c, s), vec2(-s, c)) * (v * vec2(sx, sy));
	}
	vec3 pos = (VIEW_MATRIX * vec4(center, 1.0)).xyz + vec3(v * expand, 0.0);
	POSITION = PROJECTION_MATRIX * vec4(pos, 1.0);
}
vec2 tile(vec2 p, float frame) {
	return (clamp(p, vec2(0.006), vec2(0.994)) + vec2(mod(frame, atlas_grid), floor(frame / atlas_grid))) / atlas_grid;
}
void fragment() {
	// [PITFALL] 禁用 discard（D3D12+Intel Arc 会设备丢失），改存活遮罩
	float alive = 1.0;
	if (t < 0.0 || t >= particle.y) { alive = 0.0; }
	float envelope = smoothstep(0.0, 0.012, t) * (1.0 - smoothstep(0.35, 1.0, k));
	vec3 light = vec3(0.0);
	if (kind < 0.5) {
		float frame = min((atlas_grid * atlas_grid - 1.001) * k, atlas_grid * atlas_grid - 1.001);
		float f = floor(frame), blend = fract(frame);
		vec2 v0 = texture(flow_atlas, tile(UV, f)).rg * 2.0 - 1.0;
		vec2 v1 = texture(flow_atlas, tile(UV, f + 1.0)).rg * 2.0 - 1.0;
		vec4 a = texture(atlas, tile(UV - v0 * blend * 0.025, f));
		vec4 b = texture(atlas, tile(UV + v1 * (1.0 - blend) * 0.025, f + 1.0));
		vec4 texel = mix(a, b, blend);
		float heat = clamp(max(max(texel.r, texel.g), texel.b), 0.0, 1.0);
		vec3 base = texture(color_ramp, vec2(heat, 0.5)).rgb;
		vec3 hot = texture(heat_ramp, vec2(heat, 0.5)).rgb;
		light = (base * heat * 1.5 + hot * heat * heat * 1.4) * texel.a;
	} else if (kind < 1.5) {
		vec4 puff = texture(atlas, UV);
		vec3 a = texture(layer_1, UV * vec2(0.5, 2.5) + age * vec2(0.15)).rgb;
		vec3 b = texture(layer_2, UV * vec2(0.5, 1.0) - age * vec2(0.15)).rgb;
		float pattern = dot(a + b, vec3(0.333));
		float mask = puff.a * max(max(puff.r, puff.g), puff.b);
		light = tint * pattern * mask * 3.0;
	} else if (kind < 2.5) {
		vec2 p = UV * 2.0 - 1.0;
		float head = exp(-p.x * p.x * 32.0 - pow((p.y - 0.45) * 4.0, 2.0));
		float tail = exp(-p.x * p.x * 65.0) * smoothstep(-1.0, 0.5, p.y) * (1.0 - smoothstep(0.5, 1.0, p.y));
		light = tint * tail * 0.8 + vec3(1.2, 1.7, 1.8) * head;
	} else {
		vec2 p = UV * 2.0 - 1.0;
		float r2 = dot(p, p);
		light = tint * (exp(-r2 * 5.0) * 0.5 + exp(-r2 * 36.0) * 2.0);
	}
	ALBEDO = light * grade * envelope * energy * particle.w * alive;
	ALPHA = 1.0;
}
