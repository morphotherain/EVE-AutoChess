extends RefCounted
## Original imagegen numerals; one atlas draw per digit, no UI typeface for damage.
const ATLAS := preload("res://assets/ui/damage_digits/damage_digits.png")
const METRICS := preload("res://assets/ui/damage_digits/metrics.gd")

static func measure(value: String,height: float) -> float:
	var width:=0.0
	for index in range(value.length()):
		var character:=value[index]
		width+=(float(METRICS.GLYPHS[character].advance)/METRICS.CAP_HEIGHT if METRICS.GLYPHS.has(character) else 0.27)*height
	return width

static func paint(canvas:CanvasItem,value:String,at:Vector2,height:float,tint:Color,age:float) -> void:
	var cursor:=at.x
	for index in range(value.length()):
		var character:=value[index]
		if character==".":
			canvas.draw_circle(Vector2(cursor+height*0.09,at.y-height*0.07),height*0.045,tint,true)
			cursor+=height*0.27
			continue
		if not METRICS.GLYPHS.has(character): continue
		var glyph:Dictionary=METRICS.GLYPHS[character]
		var region:Rect2=glyph.rect
		var dt:=maxf(0.0,age-float(index)*0.012)
		var settling:=1.0-exp(-dt*32.0)
		var rise:float=(1.0-settling)*height*0.06
		var dimensions:=region.size*(height/METRICS.CAP_HEIGHT)
		canvas.draw_texture_rect_region(ATLAS,Rect2(Vector2(cursor,at.y-height-rise),dimensions),region,tint)
		cursor+=float(glyph.advance)*height/METRICS.CAP_HEIGHT
