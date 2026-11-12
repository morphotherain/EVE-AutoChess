extends Node
## Persistent UI voices: closing a window or changing scenes must not cut a cue.
## Gameplay supplies semantic events; generic button clicks are a same-frame fallback.


const CONFIG := "res://assets/audio/ui/selection.json"
const STORE := preload("res://scripts/core/eve_settings_store.gd")
const STAGE_SLOTS := ["round.prep", "round.tick", "round.urgent", "round.count3", "round.count2", "round.count1", "round.battle", "round.win", "round.lose", "round.damage", "economy.income", "run.victory", "run.defeat"]
const POOL_SIZE := 16

var _slots: Dictionary = {}
var _clips: Dictionary = {}
var _streams: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var _last_variant: Dictionary = {}
var _last_time: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _specific_frame := -1
var _dispatch_frame := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	var settings := STORE.load_all()
	for kind in ["sfx", "amb"]:
		var bus := "SFX" if kind == "sfx" else "Ambience"
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			var index := AudioServer.bus_count - 1
			AudioServer.set_bus_name(index, bus)
			AudioServer.set_bus_send(index, &"Master")
			var value := float(settings[kind])
			AudioServer.set_bus_volume_db(index, linear_to_db(maxf(.0001, value * value)))
	# Also covers starchess, which previously had no audio host/settings application.
	var master := float(settings["master"])
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(.0001, master * master)))
	AudioServer.set_bus_mute(0, bool(settings["muted"]))
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CONFIG))
	if not parsed is Dictionary:
		push_error("[UI audio] 无法读取音效选择配置：" + CONFIG)
		return
	_slots = parsed.get("slots", {})
	_clips = parsed.get("clips", {})
	for i in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.name = "UiVoice%d" % i
		add_child(player)
		_players.append(player)
	get_tree().node_added.connect(_on_node_added)
	_wire_subtree.call_deferred(get_tree().root)


func handles(slot_id: String) -> bool:
	return _slots.has(slot_id)


func play(slot_id: String) -> bool:
	# Even an explicitly empty/muted semantic slot suppresses generic click fallback.
	if slot_id != "ui.hover" and slot_id != "ui.click":
		_specific_frame = _dispatch_frame
	var slot: Dictionary = _slots.get(slot_id, {})
	if slot.get("status", "empty") != "assigned":
		return false
	var bus := "Ambience" if slot_id in STAGE_SLOTS else "SFX"
	if not _audible(bus):
		return false
	var now := Time.get_ticks_msec() * .001
	var interval := .08 if slot_id in ["ui.hover", "ui.slider"] else .025
	if now - float(_last_time.get(slot_id, -100.0)) < interval:
		return false
	var variants: Array = slot.get("clips", [])
	if variants.is_empty():
		return false
	var previous := int(_last_variant.get(slot_id, -1))
	var index := (previous + 1) % variants.size()
	if slot.get("mode", "random") == "random" and variants.size() > 1:
		index = _rng.randi_range(0, variants.size() - (2 if previous >= 0 else 1))
		if previous >= 0 and index >= previous:
			index += 1
	var clip_id: String = variants[index]
	var clip: Dictionary = _clips.get(clip_id, {})
	if not _streams.has(clip_id):
		var stream = load(String(clip.get("file", "")))
		if not stream is AudioStream:
			push_error("[UI audio] 音频加载失败：" + clip_id)
			return false
		_streams[clip_id] = stream
	var voice: AudioStreamPlayer = _players[0]
	for candidate in _players:
		if not candidate.playing:
			voice = candidate
			break
		if float(candidate.get_meta("started", 0.0)) < float(voice.get_meta("started", 0.0)):
			voice = candidate
	voice.stop()
	voice.bus = bus
	voice.stream = _streams[clip_id]
	voice.pitch_scale = 1.0
	voice.volume_db = float(slot.get("gain_db", 0.0)) + float(clip["playback_gain_db"])
	voice.set_meta("started", now)
	voice.play()
	_last_variant[slot_id] = index
	_last_time[slot_id] = now
	return true


func _audible(bus: String) -> bool:
	for name in [bus, "Master"]:
		var index := AudioServer.get_bus_index(name)
		if index >= 0 and (AudioServer.is_bus_mute(index) or AudioServer.get_bus_volume_db(index) <= -70.0):
			return false
	return true


func _on_node_added(node: Node) -> void:
	if node is BaseButton or node is TabBar or node is Slider or node is EveWindow:
		_wire_reference.call_deferred(weakref(node))


func _wire_reference(reference: WeakRef) -> void:
	var node = reference.get_ref()
	if node != null:
		_wire(node)


func _wire_subtree(node: Node) -> void:
	_wire(node)
	for child in node.get_children():
		_wire_subtree(child)


func _supported() -> bool:
	var scene := get_tree().current_scene
	return scene == null or not scene.scene_file_path.contains("doudizhu")


func _wire(node: Node) -> void:
	if not is_instance_valid(node) or node.has_meta("ui_audio_wired"):
		return
	node.set_meta("ui_audio_wired", true)
	if node is BaseButton:
		var button := node as BaseButton
		button.mouse_entered.connect(func():
			if _supported() and button.is_visible_in_tree() and not button.disabled:
				play("ui.hover"))
		button.focus_entered.connect(func():
			var keyboard := Input.is_action_pressed("ui_focus_next") or Input.is_action_pressed("ui_focus_prev") or Input.is_action_pressed("ui_up") or Input.is_action_pressed("ui_down") or Input.is_action_pressed("ui_left") or Input.is_action_pressed("ui_right")
			if _supported() and keyboard and button.is_visible_in_tree() and not button.disabled:
				play("ui.hover"))
		if button is OptionButton:
			button.item_selected.connect(func(_index: int): play("ui.tab"))
		else:
			button.pressed.connect(func(): _button_fallback.call_deferred(weakref(button), _dispatch_frame))
	elif node is TabBar:
		(node as TabBar).tab_changed.connect(func(_index: int): play("ui.tab"))
	elif node is Slider:
		var slider := node as Slider
		slider.drag_started.connect(func(): slider.set_meta("ui_audio_dragging", true); play("ui.slider"))
		slider.drag_ended.connect(func(_changed: bool): slider.set_meta("ui_audio_dragging", false))
		slider.value_changed.connect(func(_value: float):
			if bool(slider.get_meta("ui_audio_dragging", false)) or (slider.has_focus() and (Input.is_action_pressed("ui_left") or Input.is_action_pressed("ui_right"))):
				play("ui.slider"))
	elif node is EveWindow and (node as EveWindow).closable:
		var window := node as Control
		window.visibility_changed.connect(func():
			play("window.open" if window.is_visible_in_tree() else "window.close"))


func _button_fallback(reference: WeakRef, frame: int) -> void:
	if not _supported() or _specific_frame == frame:
		return
	var button = reference.get_ref()
	if button == null:
		return
	if button.has_meta("ui_audio_slot"):
		play(String(button.get_meta("ui_audio_slot")))
	elif button.toggle_mode:
		play("ui.toggle_on" if button.button_pressed else "ui.toggle_off")
	else:
		play("ui.click")


func _process(_delta: float) -> void:
	_dispatch_frame += 1


func _exit_tree() -> void:
	for voice in _players:
		voice.stop()
		voice.stream = null
	_streams.clear()
