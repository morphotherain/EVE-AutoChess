shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
uniform float fill = 1.0;
uniform float trail = 1.0;
uniform float hit_pulse = 0.0;
uniform float break_pulse = 0.0;
uniform float hit_age = 10.0;
uniform float break_age = 10.0;
uniform float hit_strength = 1.0;
uniform bool frame_only = false;
uniform float opacity = 1.0;
uniform vec4 tint : source_color = vec4(0.3,0.7,1.0,1.0);
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0]*length(MODEL_MATRIX[0].xyz),
		INV_VIEW_MATRIX[1]*length(MODEL_MATRIX[1].xyz),
		INV_VIEW_MATRIX[2]*length(MODEL_MATRIX[2].xyz), MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX=mat3(MODELVIEW_MATRIX);
	VERTEX.y*=1.0+hit_pulse*0.08+break_pulse*0.12;
	// Damped local recoil in screen pixels: the camera and other bars stay put.
	float t=min(hit_age,1.0);
	float envelope=exp(-t*21.0)*smoothstep(0.0,0.012,t);
	float force=min(8.0,5.0*hit_strength+break_pulse*3.0);
	vec2 recoil=vec2(sin(t*88.0),-0.40*sin(t*113.0))*force*envelope;
	POSITION=PROJECTION_MATRIX*MODELVIEW_MATRIX*vec4(VERTEX,1.0);
	POSITION.xy+=recoil*2.0/VIEWPORT_SIZE*POSITION.w;
}
void fragment() {
	if(frame_only){
		vec2 q=abs(UV-0.5);
		float horizontal=step(0.47,q.y)*step(0.34,q.x);
		float vertical=step(0.489,q.x)*step(0.27,q.y);
		ALBEDO=tint.rgb*0.85;
		ALPHA=max(horizontal,vertical)*opacity;
	}else{
		float x=(UV.x-0.024)/0.952;
		float y=abs(UV.y-0.5);
		float aa=max(fwidth(UV.y),0.002);
		float bevel=max(0.0,y-0.15)*0.16;
		float ends=smoothstep(bevel,bevel+0.006,UV.x-0.014)*smoothstep(bevel,bevel+0.006,0.986-UV.x);
		float track=(1.0-smoothstep(0.235-aa,0.235+aa,y))*ends;
		float inner=1.0-smoothstep(0.192-aa,0.192+aa,y);
		float live=(1.0-step(fill,x))*step(0.0,x)*step(x,1.0);
		float lost=(1.0-step(trail,x))*(1.0-live)*step(0.0,x)*step(x,1.0);
		float cell=floor(x*14.0);
		float seed=fract(sin(cell*19.73+3.2)*43758.54);
		float crack=1.0-smoothstep(0.025,0.065,abs(fract(x*14.0+UV.y*0.24)-0.5));
		float fracture=smoothstep(0.025,0.13,break_age)*(1.0-smoothstep(0.50,0.60,break_age));
		float release=1.0-smoothstep(0.12+seed*0.12,0.34+seed*0.14,break_age);
		float broken=step(break_age,0.60);
		lost*=mix(1.0,release*(1.0-crack*fracture),broken);
		float tip=exp(-pow((x-fill)*85.0,2.0))*step(0.001,fill);
		float divisions=1.0-smoothstep(0.025,0.06,abs(fract(x*10.0)-0.5));
		float top=1.0-smoothstep(0.30,0.40,UV.y);
		float bottom=smoothstep(0.56,0.69,UV.y);
		vec3 metal=mix(tint.rgb*0.84,vec3(0.86,0.96,1.0),top*0.30);
		metal*=1.0-bottom*0.40-divisions*0.14;
		float flash=exp(-hit_age*32.0);
		vec3 afterimage=mix(tint.rgb,vec3(1.0,0.96,0.80),0.74);
		vec3 face=metal*live+afterimage*lost*(0.82+flash*0.5);
		face=mix(face,vec3(0.92,0.98,1.0),flash*(live+lost)*0.72);
		vec3 trough=vec3(0.016,0.026,0.039);
		face+=trough*max(0.0,1.0-live-lost);
		float halo=exp(-pow(y*4.6,2.0))*ends*step(x,max(fill,trail))*(hit_pulse+break_pulse*0.9);
		ALBEDO=mix(trough,face,inner)*track;
		EMISSION=(tint.rgb*halo*0.90+vec3(0.76,0.91,1.0)*tip*inner*hit_pulse*1.7)*opacity;
		ALPHA=clamp(track*0.94+halo*0.25,0.0,1.0)*opacity;
	}
}
