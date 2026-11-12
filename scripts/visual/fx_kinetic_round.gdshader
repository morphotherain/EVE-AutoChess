shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
#include "res://scripts/visual/fx_screen_size.gdshaderinc"
uniform vec3 point_a;
uniform vec3 point_b;
uniform float width = 0.24;
uniform float round_length = 0.9;
uniform float speed = 48.0;
uniform float age = 0.0;
uniform float delay = 0.0;
uniform float lifetime = 0.5;
uniform float energy = 2.0;
uniform vec4 tint : source_color = vec4(1.0,0.24,0.035,1.0);
varying float along;
varying float span;
void vertex() {
	span = length(point_b-point_a);
	vec3 axis = normalize(point_b-point_a+vec3(0.00001));
	along = (age-delay)*speed - UV.y*round_length;
	vec3 pos = point_a + axis*along;
	vec3 side = cross(axis,normalize(INV_VIEW_MATRIX[3].xyz-pos));
	if(dot(side,side)<0.00001){side=INV_VIEW_MATRIX[0].xyz;}
	float display = fx_pixel_scale(pos,width,VIEW_MATRIX,PROJECTION_MATRIX,VIEWPORT_SIZE);
	pos += normalize(side)*(UV.x-0.5)*width*4.0*display;
	POSITION=PROJECTION_MATRIX*VIEW_MATRIX*vec4(pos,1.0);
}
void fragment() {
	if(age<delay || age-delay>lifetime || along<0.0 || along>span){discard;}
	float q=clamp(UV.y,0.0,1.0);
	float x=(UV.x-0.5)*4.0;
	// A blunt penetrator with a broad shoulder, shaded flanks and separated
	// hot ribs; its finite silhouette travels, rather than scrolling a line.
	float radius=mix(0.12,0.50,smoothstep(0.0,0.15,q))*(1.0-smoothstep(0.25,0.86,q));
	float cross_section=1.0-smoothstep(radius*0.65,radius+0.025,abs(x));
	float nose=exp(-pow((q-0.11)*15.0,2.0));
	float ribs=exp(-pow((abs(x)-radius*0.72)*38.0,2.0));
	float body=cross_section*(1.0-smoothstep(0.38,0.85,q));
	float white_core=exp(-x*x*150.0)*nose;
	float halo=exp(-x*x*3.5)*pow(max(0.0,1.0-q),2.0)*0.22;
	float hot_tail=exp(-x*x*75.0)*smoothstep(0.2,0.35,q)*(1.0-smoothstep(0.45,1.0,q));
	ALBEDO=(tint.rgb*(body*0.8+ribs*body*1.8+halo+hot_tail*0.55)+vec3(1.0,0.94,0.69)*(white_core*2.8+body*nose*0.5))*energy;
	ALPHA=1.0;
}
