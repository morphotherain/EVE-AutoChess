extends Control

const FONT := preload("res://scripts/ui/eve_font.gd")
const TYPEFACE := preload("res://assets/fonts/NotoSansSC-Regular.ttf")
const DIGITS := preload("res://scripts/ui/eve_damage_glyphs.gd")
const LIFE := 0.85
const MAX_POPUPS := 48
const MAX_TEXT_W := 170.0
var _popups: Array[Dictionary] = []
var _lanes: Dictionary = {}
var paused := false
var playback_rate := 1.0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	texture_filter=CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

func active_count() -> int:
	return _popups.size()

func clear() -> void:
	_popups.clear()
	_lanes.clear()
	queue_redraw()

func set_timing(is_paused: bool,rate: float=1.0) -> void:
	paused=is_paused
	playback_rate=maxf(0.0,rate)

static func event_kind(event: Dictionary) -> StringName:
	var breaks:Array=event.get("breaks",[])
	if breaks.has(&"hull"): return &"kill"
	if breaks.has(&"armor"): return &"armor"
	if breaks.has(&"shield"): return &"shield"
	return &"pierce" if event.get("pierced",false) else &"hit"

func pop(screen_pos: Vector2,damage: float,quality: int,hit: bool,event: Dictionary={}) -> void:
	var kind:StringName=event_kind(event) if hit else &"miss"
	var target_id:int=event.get("target_id",-1)
	# Sum ordinary simultaneous damage only. Breaks and kills keep one true total.
	if kind==&"hit" and quality<5 and target_id>=0:
		for previous in _popups:
			if previous.target_id==target_id and previous.kind==&"hit" and previous.quality<5 and previous.t<0.075:
				previous.damage+=damage
				previous.count+=1
				previous.bump=0.0
				queue_redraw()
				return
	var milestones:Array[StringName]=[]
	for layer in [&"shield",&"armor",&"hull"]:
		if event.get("breaks",[]).has(layer): milestones.append(layer)
	var important:=not milestones.is_empty()
	while _popups.size()>=MAX_POPUPS:
		var discard:=0
		for i in range(_popups.size()):
			if _popups[i].milestones.is_empty():
				discard=i
				break
		_popups.remove_at(discard)
	var lane:int=_lanes.get(target_id,0)
	_lanes[target_id]=(lane+1)%3
	_popups.append({"pos":screen_pos,"t":0.0,"bump":0.0,"life":1.10 if kind==&"kill" else (0.98 if important else 0.70),
		"damage":damage,"count":1,"kind":kind,"quality":quality,"target_id":target_id,
		"target_visual":event.get("target_visual"),"milestones":milestones,
		"dx":float(lane-1)*(9.0 if important else 14.0)})
	queue_redraw()

func _process(delta: float) -> void:
	if paused or _popups.is_empty(): return
	var dt:=delta*playback_rate
	var camera:=get_viewport().get_camera_3d()
	for i in range(_popups.size()-1,-1,-1):
		var p:=_popups[i]
		p.t+=dt
		p.bump+=dt
		if p.t>=p.life:
			_popups.remove_at(i)
			continue
		var reference=p.target_visual
		var visual=reference.get_ref() if reference is WeakRef else null
		if is_instance_valid(visual) and camera!=null:
			p.pos=visual.feedback_screen_position(camera)
	queue_redraw()

func _number(value: float) -> String:
	return String.num(value,1) if value>0.0 and value<1.0 else str(int(round(value)))

func _draw() -> void:
	for p in _popups:
		var important:bool=not p.milestones.is_empty()
		var tint:=Color(0.88,0.96,1.0)
		if p.kind==&"shield": tint=Color(0.44,0.88,1.0)
		elif p.kind==&"armor": tint=Color(1.0,0.78,0.32)
		elif p.kind==&"kill": tint=Color(1.0,0.45,0.19)
		elif p.quality>=5: tint=Color(1.0,0.87,0.48)
		var text:String="miss" if p.kind==&"miss" else _number(p.damage)
		var fs:=float(FONT.s(32 if important else (28 if p.quality>=5 else 23)))
		var width:=DIGITS.measure(text,fs)
		if width>MAX_TEXT_W:
			fs*=MAX_TEXT_W/width
			width=MAX_TEXT_W
		var alpha:float=1.0-smoothstep(p.life*0.62,p.life,p.t)
		var rise:float=6.0*(1.0-exp(-p.t*24.0))+smoothstep(0.12,p.life,p.t)*(38.0 if important else 27.0)
		var punch:float=1.0+(0.23 if important else 0.12)*sin(PI*clampf(p.bump/0.15,0.0,1.0))
		var icon_width:float=float(p.milestones.size())*22.0
		var at:Vector2=p.pos+Vector2(p.dx,-rise)
		draw_set_transform(at,0.0,Vector2.ONE*punch)
		var start:=Vector2(-(width+icon_width)*0.5,0)
		if p.kind==&"miss":
			TYPEFACE.draw_string(get_canvas_item(),start,text,HORIZONTAL_ALIGNMENT_LEFT,-1,int(fs*0.65),Color(tint.r,tint.g,tint.b,alpha))
		else:
			DIGITS.paint(self,text,start+Vector2(icon_width,0),fs,Color(tint.r,tint.g,tint.b,alpha),p.bump)
		for i in range(p.milestones.size()):
			_symbol(p.milestones[i],start+Vector2(10.0+float(i)*22.0,-fs*0.48),p.t-float(i)*0.035,alpha)
		draw_set_transform(Vector2.ZERO)

func _symbol(kind: StringName,at: Vector2,t: float,alpha: float) -> void:
	if t<0.0: return
	var split:=smoothstep(0.03,0.20,t)
	var tint:=Color(0.30,0.77,1.0,alpha)
	if kind==&"shield":
		for side in [-1.0,1.0]:
			var offset:=at+Vector2(side*split*3.5,split*1.5)
			var points:=PackedVector2Array([Vector2(0,-9),Vector2(side*7,-6),Vector2(side*6,2),Vector2(0,9),Vector2(side,-1),Vector2(0,-9)])
			for i in range(points.size()): points[i]+=offset
			draw_colored_polygon(points,Color(tint.r,tint.g,tint.b,alpha*0.12))
			draw_polyline(points,tint,1.7,true)
		draw_line(at+Vector2(-1,-4),at+Vector2(2,1),Color(0.9,1,1,alpha*(1.0-split)),1.5,true)
	elif kind==&"armor":
		tint=Color(1.0,0.72,0.24,alpha)
		var parts=[PackedVector2Array([Vector2(-7,-7),Vector2(0,-9),Vector2(-1,0),Vector2(-7,3)]),
			PackedVector2Array([Vector2(1,-9),Vector2(7,-6),Vector2(7,1),Vector2(0,0)]),
			PackedVector2Array([Vector2(-6,4),Vector2(0,1),Vector2(6,3),Vector2(0,9)])]
		for i in range(parts.size()):
			var points:PackedVector2Array=parts[i]
			var shift:Vector2=[Vector2(-3,-1),Vector2(3,-1),Vector2(0,3)][i]*split
			for j in range(points.size()): points[j]+=at+shift
			draw_colored_polygon(points,Color(tint.r,tint.g,tint.b,alpha*0.30))
			points.append(points[0])
			draw_polyline(points,tint,1.4,true)
	else:
		tint=Color(1.0,0.43,0.19,alpha)
		var diamond:=PackedVector2Array([at+Vector2(0,-7),at+Vector2(5,0),at+Vector2(0,7),at+Vector2(-5,0),at+Vector2(0,-7)])
		draw_polyline(diamond,tint,2.0,true)
		for i in range(4):
			var direction:=Vector2.from_angle(float(i)*PI*0.5+PI*0.25)
			draw_line(at+direction*(8.0+split*2.0),at+direction*(11.0+split*4.0),tint,1.5,true)
