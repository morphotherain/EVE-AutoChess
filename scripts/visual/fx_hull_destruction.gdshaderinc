uniform bool death_active = false;
uniform float age = 0.0;
uniform float death_seed = 0.0;
uniform vec3 death_center = vec3(0.0);
uniform vec3 death_extent = vec3(1.0);
varying vec3 death_local;

vec3 death_hash(vec3 p) {
	return fract(sin(vec3(dot(p, vec3(127.1,311.7,74.7)),
		dot(p, vec3(269.5,183.3,246.1)), dot(p, vec3(113.5,271.9,124.6)))) * 43758.5453);
}
float death_noise(vec3 p) {
	vec3 i = floor(p), f = fract(p);
	vec3 u = f*f*(3.0-2.0*f);
	return mix(mix(mix(death_hash(i).x, death_hash(i+vec3(1,0,0)).x,u.x),
		mix(death_hash(i+vec3(0,1,0)).x,death_hash(i+vec3(1,1,0)).x,u.x),u.y),
		mix(mix(death_hash(i+vec3(0,0,1)).x,death_hash(i+vec3(1,0,1)).x,u.x),
		mix(death_hash(i+vec3(0,1,1)).x,death_hash(i+vec3(1,1,1)).x,u.x),u.y),u.z);
}
vec2 death_cells(vec3 p) {
	vec3 cell = floor(p), f = fract(p);
	float first = 10.0, second = 10.0;
	for (int x=-1;x<=1;x++) for(int y=-1;y<=1;y++) for(int z=-1;z<=1;z++) {
		vec3 offset=vec3(float(x),float(y),float(z));
		vec3 d=offset+death_hash(cell+offset+death_seed)-f;
		float distance=dot(d,d);
		if(distance<first) { second=first; first=distance; }
		else if(distance<second) { second=distance; }
	}
	return vec2(sqrt(first),sqrt(second)-sqrt(first));
}
