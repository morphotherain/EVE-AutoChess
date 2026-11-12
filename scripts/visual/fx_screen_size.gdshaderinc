// Preserve a minimum readable footprint in the current viewport. Only the
// cross-section / sprite size changes; world anchors and flight paths do not.
uniform bool screen_compensation = true;
uniform float screen_max_scale = 12.0;
uniform float screen_min_px = 24.0;

float fx_pixel_scale(vec3 world_point, float world_size, mat4 view_matrix,
		mat4 projection_matrix, vec2 viewport_size) {
	if (!screen_compensation) { return 1.0; }
	float depth = abs((view_matrix * vec4(world_point, 1.0)).z);
	// Orthographic projections already encode world units in the projection.
	if (abs(projection_matrix[3][3]) > 0.5) { depth = 1.0; }
	float pixel_world = 2.0 * max(depth, 0.01) /
		max(abs(projection_matrix[1][1]) * viewport_size.y, 0.001);
	float far_weight = smoothstep(1.0 / 36.0, 1.0 / 18.0, pixel_world);
	float scale = clamp(pixel_world * screen_min_px / max(world_size, 0.0001),
		1.0, screen_max_scale);
	return mix(1.0, scale, far_weight);
}
