shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;

// Native target-painter / tractor content adapter. The meshes and their UVs
// come from the original effect trees, not a substitute procedural cylinder.
// 0 = regular ubershader, 1 = ubershadertwosided, 2 = texturecolor.
// The original twosided technique has equal shaders with opposing cull modes;
// cull_disabled draws each original front/back face once in this additive pass.
uniform int shader_mode = 0;
uniform sampler2D diffuse_1 : filter_linear_mipmap, repeat_enable;
uniform sampler2D diffuse_2 : filter_linear_mipmap, repeat_enable;
uniform sampler2D mask_map : filter_linear_mipmap, repeat_disable;
uniform vec4 transform_1 = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 transform_2 = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 scroll_1 = vec4(0.0);
uniform vec4 scroll_2 = vec4(0.0);
uniform vec4 texture_scaling = vec4(1.0);
uniform vec4 texture_translation = vec4(0.0);
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
uniform float content_black = 0.0;
uniform float content_gamma = 1.0;
// A restrained local readability floor follows the original mask and taper.
// It does not replace scrolling caustics or introduce a separate solid beam.
uniform float minimum_signal = 0.0;
uniform bool screen_compensation = true;
varying vec3 native_normal;
varying vec3 native_view;
varying vec2 native_uv1;
varying vec2 native_uv2;
varying float vertex_gain;

float signed_fresnel(vec3 view_direction, vec3 normal_direction) {
	float angle = clamp(dot(view_direction, normal_direction) - fresnel_factors.z, 0.0, 1.0);
	float f = pow(max(1.0 - angle, 0.0), max(fresnel_factors.x, 0.0001));
	return fresnel_factors.y >= 0.0 ? f * fresnel_factors.y :
		(1.0 - min(f, 1.0)) * (-fresnel_factors.y);
}

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Both original adapters transform normals with world 3x3 directly.
	native_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
	native_view = normalize(CAMERA_POSITION_WORLD - world);
	native_uv1 = UV * transform_1.zw + transform_1.xy + scroll_1.xy * texture_time + scroll_1.zw;
	native_uv2 = UV * transform_2.zw + transform_2.xy + scroll_2.xy * texture_time + scroll_2.zw;
	// Native twosided computes its Fresnel and scrolling UVs in VS; the
	// regular uber computes the Fresnel after normal/view interpolation.
	vertex_gain = signed_fresnel(native_view, native_normal);
}

void fragment() {
	vec4 radiance;
	if (shader_mode == 2) {
		// texturecolor is a real two-dimensional texture lookup, not a flare.
		vec2 uv = UV * texture_scaling.xy + texture_translation.xy;
		radiance = texture(diffuse_1, uv) * tint * max(brightness, 0.0);
	} else {
		vec2 uv1 = shader_mode == 1 ? native_uv1 : UV * transform_1.zw + transform_1.xy + scroll_1.xy * texture_time + scroll_1.zw;
		vec2 uv2 = shader_mode == 1 ? native_uv2 : UV * transform_2.zw + transform_2.xy + scroll_2.xy * texture_time + scroll_2.zw;
		vec4 moving = texture(diffuse_1, uv1) * texture(diffuse_2, uv2);
		float peak = max(moving.r, max(moving.g, moving.b));
		float mapped = pow(max((peak - content_black) / max(1.0 - content_black, 0.001), 0.0), content_gamma);
		moving.rgb *= mapped / max(peak, 0.00001);
		moving.rgb = max(moving.rgb, vec3(minimum_signal));
		radiance = moving * texture(mask_map, UV) * tint;
		float gain = shader_mode == 1 ? vertex_gain : signed_fresnel(native_view, native_normal);
		if (shader_mode == 1) {
			// Twosided multiplies all RGBA by Fresnel, unlike regular uber.
			radiance *= gain;
		} else {
			radiance.rgb *= gain;
		}
	}
	float attenuation = mix(0.86, 1.0, clamp((strength - 0.25) / 0.20, 0.0, 1.0));
	// Native additive RGB is independent of texture alpha (often zero).
	ALBEDO = radiance.rgb * grade * energy * power * layer_weight * attenuation;
	ALPHA = 1.0;
}
