shader_type spatial;
render_mode cull_disabled;
uniform float age = 0.0;
uniform float delay = 0.0;
uniform float lifetime = 2.0;
uniform float seed = 0.0;
void fragment() {
	float t = age-delay;
	if(t<0.0 || t>=lifetime) { discard; }
	float cool=exp(-t*3.5);
	float plates=step(0.78, fract(UV.x*4.0+UV.y*3.0+seed));
	ALBEDO=vec3(0.12,0.15,0.19);
	METALLIC=0.7;
	ROUGHNESS=0.65;
	EMISSION=vec3(1.0,0.24,0.035)*(0.12+plates)*cool*4.0;
	// Opaque fragments retire through a fine dissolve, avoiding alpha sorting.
	float dissolve=smoothstep(lifetime*0.65,lifetime,t);
	float grain=fract(sin(dot(floor(UV*40.0),vec2(12.9898,78.233))+seed)*43758.5453);
	if(grain<dissolve) { discard; }
}
