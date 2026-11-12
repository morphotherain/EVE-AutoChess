// Shared physical-looking power cycle. The long axis remains connected to the
// target while the cross-section/radiance spools up and then pinches shut.
float laser_power(float t) {
	return smoothstep(0.0, 0.055, t) * (1.0 - smoothstep(0.38, 0.54, t));
}
