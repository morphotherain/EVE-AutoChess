shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
// Material adapter for Scourge's original cone, mirrored wave and halo meshes.
uniform sampler2D diffuse_1 : filter_linear_mipmap, repeat_enable;
uniform sampler2D diffuse_2 : filter_linear_mipmap, repeat_enable;
uniform sampler2D diffuse_3 : filter_linear_mipmap, repeat_enable;
uniform sampler2D mask_map : filter_linear_mipmap, repeat_enable;
uniform vec4 transform_1 = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 transform_2 = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 transform_3 = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 mask_transform = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 scroll_1 = vec4(0.0);
uniform vec4 scroll_2 = vec4(0.0);
uniform vec4 scroll_3 = vec4(0.0);
// Native effect constants are already linear HDR, not authored sRGB colors.
uniform vec4 tint = vec4(1.0);
uniform float age = 0.0;
uniform float source_time = 0.0;
uniform float brightness = 0.0;
uniform float reveal = 0.0;
uniform float energy = 1.0;

vec2 coordinates(vec2 uv, vec4 transform, vec4 scroll) {
	return uv * transform.zw + transform.xy + scroll.xy * source_time + scroll.zw;
}
void fragment() {
	vec3 a = texture(diffuse_1, coordinates(UV, transform_1, scroll_1)).rgb;
	vec3 b = texture(diffuse_2, coordinates(UV, transform_2, scroll_2)).rgb;
	vec3 c = texture(diffuse_3, coordinates(UV, transform_3, scroll_3) + vec2(0.0, reveal)).rgb;
	vec3 mask = texture(mask_map, UV * mask_transform.zw + mask_transform.xy).rgb;
	float facing = pow(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.35);
	vec3 detail = (a + b) * (0.12 + c * 1.8);
	ALBEDO = detail * mask * tint.rgb * tint.a * brightness * energy * mix(0.35, 1.0, facing);
	ALPHA = 1.0;
}
