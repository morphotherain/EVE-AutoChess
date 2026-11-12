shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;

// Native EVE ubershader TWO-map REGULAR/MASK_TRANSFORM_OFF adapter. Formula
// and signed Fresnel branch were verified from DX11 shader disassembly.
// Original additive RGB is independent of texture/DiffuseColor alpha.
uniform sampler2D diffuse_1 : filter_linear_mipmap, repeat_enable;
uniform sampler2D diffuse_2 : filter_linear_mipmap, repeat_enable;
uniform sampler2D mask_map : filter_linear_mipmap, repeat_enable;
uniform vec4 transform_1 = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 transform_2 = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 scroll_1 = vec4(0.0);
uniform vec4 scroll_2 = vec4(0.0);
uniform vec4 tint = vec4(1.0);
uniform vec4 fresnel_factors = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec3 grade = vec3(1.0);
uniform float age = 0.0;
uniform float texture_time = 0.0;
uniform float power = 0.0;
uniform float strength = 0.35;
uniform float layer_weight = 1.0;
uniform float refresh = 0.0;
uniform float energy = 1.0;
uniform float brightness = 1.0;
// Local contrast adapts the original content, never the carrier silhouette.
uniform float content_black = 0.0;
uniform float content_gamma = 1.0;
uniform float surface_feather = 0.0;
uniform bool screen_compensation = true;
varying vec3 native_normal;
varying vec3 native_view;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Native VS uses world 3x3 directly, including negative/nonuniform scales.
	// It normalizes at vertices, not again after fragment interpolation.
	native_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
	native_view = normalize(CAMERA_POSITION_WORLD - world);
}

void fragment() {
	vec2 uv1 = UV * transform_1.zw + transform_1.xy + scroll_1.xy * texture_time + scroll_1.zw;
	vec2 uv2 = UV * transform_2.zw + transform_2.xy + scroll_2.xy * texture_time + scroll_2.zw;
	vec3 content = texture(diffuse_1, uv1).rgb * texture(diffuse_2, uv2).rgb *
		texture(mask_map, UV).rgb * tint.rgb;
	float native_peak = max(content.r, max(content.g, content.b));
	float remapped_peak = pow(max((native_peak - content_black) /
		max(1.0 - content_black, 0.001), 0.0), content_gamma);
	content *= remapped_peak / max(native_peak, 0.00001);
	float angle = clamp(dot(native_view, native_normal) - fresnel_factors.z, 0.0, 1.0);
	float fresnel = pow(max(1.0 - angle, 0.0), max(fresnel_factors.x, 0.0001));
	float gain = fresnel_factors.y >= 0.0 ? fresnel * fresnel_factors.y :
		(1.0 - min(fresnel, 1.0)) * (-fresnel_factors.y);
	// A small local edge treatment keeps the stretched closed carrier from
	// reading as a hard net bag. No additional geometry/line mask is created.
	float coverage = surface_feather > 0.0 ? smoothstep(0.0, surface_feather,
		abs(dot(native_view, native_normal))) : 1.0;
	float attenuation = mix(0.88, 1.0, clamp((strength - 0.25) / 0.20, 0.0, 1.0));
	ALBEDO = content * gain * grade * energy * power * layer_weight * attenuation * coverage;
	ALPHA = 1.0;
}
