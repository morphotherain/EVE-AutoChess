shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
#include "res://scripts/visual/fx_screen_size.gdshaderinc"

varying float life;
varying float energy;
void vertex() {
	life = INSTANCE_CUSTOM.x;
	energy = INSTANCE_CUSTOM.y;
	vec3 center = MODEL_MATRIX[3].xyz;
	vec3 axis = normalize(MODEL_MATRIX[2].xyz);
	vec3 side = cross(axis, normalize(INV_VIEW_MATRIX[3].xyz - center));
	if (dot(side, side) < 0.00001) { side = INV_VIEW_MATRIX[0].xyz; }
	float width = length(MODEL_MATRIX[0].xyz);
	float scale = fx_pixel_scale(center, width, VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE);
	vec3 pos = center + normalize(side) * VERTEX.x * width * scale +
		axis * VERTEX.y * length(MODEL_MATRIX[1].xyz);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(pos, 1.0);
}
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float core = exp(-p.x * p.x * 20.0) * pow(max(1.0 - p.y * p.y, 0.0), 2.0);
	float fade = smoothstep(0.0, 0.12, life) * pow(max(1.0 - life, 0.0), 1.8);
	ALBEDO = mix(vec3(0.55, 1.4, 2.0), vec3(0.07, 0.25, 1.0), life) * core * fade * energy;
	ALPHA = 1.0;
}
