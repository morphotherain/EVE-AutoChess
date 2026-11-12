shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;

// Native flare.fx adapter: authored gradient is sampled radially at (r,r).
// The original hierarchy performs modifier 1/100 alignment on the CPU.
// Do not replace RGB with alpha: several original maps have alpha = zero.
uniform sampler2D gradient_map : filter_linear, repeat_disable;
uniform vec4 tint = vec4(1.0);
uniform vec3 grade = vec3(1.0);
uniform float brightness = 1.0;
uniform float energy = 1.0;
uniform float age = 0.0;
uniform float texture_time = 0.0;
uniform float power = 0.0;
uniform float strength = 0.35;
uniform float layer_weight = 1.0;
uniform float refresh = 0.0;
uniform bool screen_compensation = true;

void fragment() {
	float radius = length((UV - 0.5) * 2.0);
	vec3 content = texture(gradient_map, vec2(radius)).rgb * tint.rgb;
	ALBEDO = content * max(brightness, 0.0) * grade * energy * power * layer_weight;
	ALPHA = 1.0;
}
