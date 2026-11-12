shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Native Serenity AR preserves albedo RGB and roughness alpha. The separate
// original glow map is sampled explicitly as RGB, never as a whole-hull overlay.
uniform sampler2D albedo_roughness : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D glow_tex : source_color, filter_linear_mipmap, repeat_enable;
void fragment() {
	vec4 ar = texture(albedo_roughness, UV);
	ALBEDO = ar.rgb;
	ROUGHNESS = clamp(ar.a, 0.22, 0.85);
	METALLIC = 0.62;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	EMISSION = texture(glow_tex, UV).rgb * 1.5;
}
