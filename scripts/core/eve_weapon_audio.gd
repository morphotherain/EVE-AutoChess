extends Node
## User-selected short-release voices. Hull cost is the canonical tonnage tier.
const DIRECTORY := "res://assets/audio/weapons/"
const VARIANTS := {&"laser": 1, &"hybrid": 1, &"proj": 1, &"missile": 1, &"missile_hit": 2, &"missile_flight": 1}
# Common per-round headroom leaves the 2/3/4-round power difference intact.
const FIRE_GAIN_DB := {&"laser": -8.0, &"hybrid": -8.0, &"proj": -8.0, &"missile": -18.0, &"missile_hit": -10.0}
const ENGINE_GAIN_DB := -19.0
var _cache: Dictionary = {}
var _voices: Array[AudioStreamPlayer] = []
var _engines: Array[AudioStreamPlayer] = []
var _cursor := 0
var _charge_sources: Dictionary = {}
var _charges: Dictionary = {}
var played := {"laser": 0, "hybrid": 0, "proj": 0, "missile": 0, "missile_hit": 0}

static func size_for(tier: int) -> String:
	return "small" if tier <= 2 else ("medium" if tier == 3 else "large")

func _ready() -> void:
	var bank = JSON.parse_string(FileAccess.get_file_as_string(DIRECTORY + "sources.json"))
	if bank is Dictionary:
		_charge_sources = bank.get("charges", {})
	for i in range(40):
		var voice := AudioStreamPlayer.new()
		voice.bus = &"SFX" if AudioServer.get_bus_index(&"SFX") >= 0 else &"Master"
		add_child(voice)
		_voices.append(voice)


## Read the existing cooldown; this never delays attacks or changes combat rules.
func sync_charges(ships: Array[EveShip], active: bool) -> void:
	var wanted := {}
	var by_id := {}
	for ship in ships: by_id[ship.id] = ship
	if active:
		for ship in ships:
			var key := "%s.%s" % [ship.weapon_id, size_for(ship.cost)]
			if not _charge_sources.has(key): continue
			var target: EveShip = by_id.get(ship.target_id)
			var cue: Dictionary = _charge_sources[key]
			if not ship.alive or not ship.locked or target == null or not target.alive: continue
			if ship.jam_disabled > 0.0 or (ship.cap_max > 0.0 and ship.cap_dry): continue
			if ship.weapon_timer <= 0.0 or ship.weapon_timer > float(cue.duration): continue
			wanted[ship.id] = true
			if _charges.has(ship.id) and int(_charges[ship.id].target_id) != ship.target_id:
				stop_charge(ship.id)
			if _charges.has(ship.id): continue
			var voice := AudioStreamPlayer.new()
			voice.stream = load(String(cue.file)) as AudioStreamWAV
			voice.bus = &"SFX" if AudioServer.get_bus_index(&"SFX") >= 0 else &"Master"
			voice.volume_db = float(FIRE_GAIN_DB.get(ship.weapon_id, 0.0))
			add_child(voice)
			_charges[ship.id] = {"voice": voice, "target_id": ship.target_id}
			voice.play(maxf(0.0, float(cue.duration) - ship.weapon_timer))
	for id in _charges.keys():
		if not wanted.has(id): stop_charge(int(id))


func stop_charge(source_id: int) -> void:
	if not _charges.has(source_id): return
	var voice: AudioStreamPlayer = _charges[source_id].voice
	voice.stop()
	voice.queue_free()
	_charges.erase(source_id)

func _stream(family: StringName, tier: int, seed_value: int, looped := false) -> AudioStream:
	var variant := posmod(seed_value, int(VARIANTS.get(family, 1))) + 1
	var key := "%s_%s_%02d" % [family, size_for(tier), variant]
	if looped: key += "_loop"
	if _cache.has(key): return _cache[key]
	var file := "%s%s_%s_%02d.wav" % [DIRECTORY, family, size_for(tier), variant]
	var stream := load(file) as AudioStreamWAV
	if stream == null: return null
	if looped:
		stream = stream.duplicate() as AudioStreamWAV
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = int(stream.get_length() * stream.mix_rate)
	_cache[key] = stream
	return stream

func fire(family: StringName, tier: int, seed_value: int) -> void:
	if _voices.is_empty(): return
	var stream := _stream(family, tier, seed_value)
	if stream == null: return
	var voice: AudioStreamPlayer = null
	for candidate in _voices:
		if not candidate.playing:
			voice = candidate
			break
	if voice == null:
		voice = _voices[_cursor % _voices.size()]
		_cursor += 1
	voice.stream = stream
	voice.volume_db = float(FIRE_GAIN_DB.get(family, 0.0))
	voice.pitch_scale = 1.0
	voice.play()
	played[String(family)] = int(played.get(String(family), 0)) + 1

func start_engine(tier: int, seed_value: int) -> AudioStreamPlayer:
	if _engines.size() >= 18: return null
	var voice := AudioStreamPlayer.new()
	voice.stream = _stream(&"missile_flight", tier, seed_value, true)
	voice.bus = &"SFX" if AudioServer.get_bus_index(&"SFX") >= 0 else &"Master"
	voice.volume_db = ENGINE_GAIN_DB
	add_child(voice)
	_engines.append(voice)
	voice.play()
	return voice

func stop_engine(voice: AudioStreamPlayer) -> void:
	if not is_instance_valid(voice): return
	voice.stop()
	_engines.erase(voice)
	voice.queue_free()

func set_timing(is_paused: bool, rate: float) -> void:
	for voice in _voices + _engines:
		voice.stream_paused = is_paused
		voice.pitch_scale = maxf(.05, rate)
	for charge in _charges.values():
		charge.voice.stream_paused = is_paused
		charge.voice.pitch_scale = maxf(.05, rate)

func clear() -> void:
	for id in _charges.keys(): stop_charge(int(id))
	for voice in _voices: voice.stop()
	for voice in _engines: voice.queue_free()
	_engines.clear()
