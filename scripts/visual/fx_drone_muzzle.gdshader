shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
#include "res://scripts/visual/fx_screen_size.gdshaderinc"

// Original EVE flash atlas and caustic flow; no generated/repainted textures.
uniform sampler2D flash_atlas : filter_linear, repeat_disable;
uniform sampler2D flow_map : filter_linear_mipmap, repeat_enable;
uniform float age = 0.0;
uniform float cycle_age = 0.0;
uniform float lifetime = 0.16;
uniform float energy = 1.0;
uniform float seed = 0.0;
uniform int layer = 0;
uniform bool billboard = true;
uniform vec3 firing_axis = vec3(1.0, 0.0, 0.0);

void vertex() {
	float size = length(MODEL_MATRIX[0].xyz);
	VERTEX *= fx_pixel_scale(MODEL_MATRIX[3].xyz, size, VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE);
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec2 direction = vec2(dot(firing_axis, right), dot(firing_axis, up));
	if (dot(direction, direction) > 0.001) {
		direction = normalize(direction);
		right = INV_VIEW_MATRIX[0].xyz * direction.x + INV_VIEW_MATRIX[1].xyz * direction.y;
		up = -INV_VIEW_MATRIX[0].xyz * direction.y + INV_VIEW_MATRIX[1].xyz * direction.x;
	}
	vec3 center = MODEL_MATRIX[3].xyz + firing_axis * size * 0.13;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(right * size, 0.0), vec4(up * size, 0.0),
		INV_VIEW_MATRIX[2] * size, vec4(center, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}
vec2 tile_uv(vec2 p, float frame) {
	return (clamp(p, vec2(0.008), vec2(0.992)) + vec2(mod(frame, 4.0), floor(frame / 4.0))) / 4.0;
}
void fragment() {
	if (age < 0.0 || age >= lifetime) { discard; }
	float k = clamp(age / lifetime, 0.0, 1.0);
	vec2 p = UV * 2.0 - 1.0;
	vec2 q = p - vec2(-0.30, 0.0);
	float outer_mask = 1.0 - smoothstep(0.78, 1.0, length(p));
	float hot = exp(-dot(q * vec2(12.0, 18.0), q * vec2(12.0, 18.0)));
	vec3 light = vec3(0.0);
	if (layer == 0) {
		vec2 atlas_p = vec2(clamp(q.x, 0.0, 1.0) * 0.62 + 0.18, q.y * 1.2 + 0.5);
		float frame = min(k * 11.0, 11.0);
		float f0 = floor(frame), f1 = min(f0 + 1.0, 15.0);
		vec3 a = texture(flash_atlas, tile_uv(atlas_p, f0)).rgb;
		vec3 b = texture(flash_atlas, tile_uv(atlas_p, f1)).rgb;
		vec3 texel = mix(a, b, fract(frame));
		float atlas_mask = max(texel.r, max(texel.g, texel.b));
		float flow = texture(flow_map, vec2(q.x * 1.7 - cycle_age * 4.0 + seed, q.y * 1.8)).r;
		float needle = exp(-q.y * q.y * 380.0) * exp(-max(q.x, 0.0) * 5.5) * smoothstep(-0.12, 0.0, q.x);
		float front = clamp(q.x, 0.0, 1.0);
		float wander = (flow - 0.5) * 0.055 * front;
		float lobe_width = mix(0.052, 0.028, front);
		float lobe_a = (q.y - 0.06 - front * 0.14 - wander) / lobe_width;
		float lobe_b = (q.y + 0.045 + front * 0.10 - wander) / lobe_width;
		float center_width = 0.055 + 0.09 * (1.0 - front);
		float center = q.y / center_width;
		float lobes = exp(-center * center) * 0.55 + (exp(-lobe_a*lobe_a) + exp(-lobe_b*lobe_b)) * 0.65;
		float envelope = smoothstep(-0.04, 0.05, q.x) * (1.0 - smoothstep(0.30, 0.75, q.x));
		// The original atlas breaks up flowing flame lobes, rather than being
		// stamped as a complete, flat explosion flower in front of the barrel.
		float petals = lobes * envelope * (0.20 + flow * 0.80) * (0.35 + atlas_mask * 0.65);
		vec3 petal_color = mix(vec3(0.36, 0.045, 1.1), vec3(1.0, 0.50, 1.5), clamp(petals, 0.0, 1.0) * (1.0-front*0.65));
		light = vec3(1.15, 1.05, 1.4) * (hot * 1.9 + needle * 0.35) +
			petal_color * petals * 1.10;
		light *= exp(-k * 5.0);
	} else if (layer == 1) {
		vec2 arc_p = q * vec2(0.88, 1.25);
		float angle = atan(arc_p.y, arc_p.x);
		float r = length(arc_p);
		float radius = mix(0.20, 0.67, 1.0 - exp(-k * 6.0));
		float delta = (r - radius) * 32.0;
		float arc = exp(-delta * delta);
		float cuts = pow(max(0.0, 0.5 + 0.5 * cos(angle * 3.0 + seed)), 5.0);
		float inner_delta = (r - radius * 0.83) * 44.0;
		light = vec3(0.22, 0.6, 1.7) * arc * cuts * 0.55 +
			vec3(0.8, 0.13, 1.3) * exp(-inner_delta * inner_delta) * cuts * 0.40;
		light *= (1.0 - smoothstep(0.05, 1.0, k));
	} else {
		float halo = exp(-dot(q * vec2(1.5, 2.0), q * vec2(1.5, 2.0)) * 3.5);
		float horizontal = exp(-q.y * q.y * 280.0) * exp(-abs(q.x) * 7.0);
		float vertical = exp(-q.x * q.x * 420.0) * exp(-abs(q.y) * 10.0);
		light = vec3(0.48, 0.09, 1.1) * halo * 0.16 + vec3(0.8, 0.65, 1.3) * (horizontal + vertical) * 0.18;
		light *= exp(-k * 4.0);
	}
	ALBEDO = light * energy * outer_mask;
	ALPHA = 1.0;
}
