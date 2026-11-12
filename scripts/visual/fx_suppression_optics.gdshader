shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D detail_map : filter_linear_mipmap, repeat_enable;
uniform float age = 0.0;
uniform float power = 0.0;
uniform float strength = 0.35;
uniform float layer_weight = 1.0;
uniform bool screen_compensation = true;
uniform float seed = 0.0;
uniform float visibility = 1.0;

void fragment() {
	float x = (UV.y - 0.5) * 2.0;
	float ends = pow(max(sin(UV.x * 3.141593), 0.0), 0.65);
	float body = pow(max(0.0, 1.0 - x * x), 3.0);
	float core = exp(-x * x * 95.0);
	float detail = texture(detail_map, vec2(UV.x * 1.3 - age * 0.055 + seed, UV.y)).r;
	float glint = exp(-pow((UV.x - fract(age * 0.13 + seed)) * 17.0, 2.0));
	vec3 amber = vec3(1.0, 0.28, 0.025);
	vec3 gold = vec3(1.6, 0.91, 0.28);
	vec3 light = amber * body * (0.12 + detail * 0.13) + gold * core * (0.38 + glint * 0.65);
	ALBEDO = light * ends * visibility * power * layer_weight;
	ALPHA = 1.0;
}
