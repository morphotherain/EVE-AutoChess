shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
// Godot screen-space adapter for Scourge halo B's original distortion pass.
uniform sampler2D screen_image : hint_screen_texture, filter_linear, repeat_disable;
uniform sampler2D normal_map : filter_linear_mipmap, repeat_enable;
uniform sampler2D mask_map : filter_linear_mipmap, repeat_enable;
uniform float source_time = 0.0;
uniform float strength = 0.0;
void fragment() {
	vec2 uv = UV * vec2(5.0, 0.1119) + vec2(0.05, -0.05) * source_time;
	vec2 displacement = texture(normal_map, uv).rg * 2.0 - 1.0;
	float mask = texture(mask_map, UV).r;
	float border = smoothstep(0.0, 0.12, UV.y) * (1.0 - smoothstep(0.78, 1.0, UV.y));
	float coverage = mask * border * strength;
	vec2 offset = displacement * 5.0 * coverage / VIEWPORT_SIZE;
	ALBEDO = texture(screen_image, clamp(SCREEN_UV + offset, vec2(0.001), vec2(0.999))).rgb;
	ALPHA = coverage * 0.30;
}
