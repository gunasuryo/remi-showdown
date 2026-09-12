extends Node

# The one thing that owns sound. Autoloaded as `Audio`.
#
# It is an AUTOLOAD and that is the whole point, not a convenience. An
# AudioStreamPlayer living in a scene is freed by change_scene_to_file(), so
# music placed on suit_select would stop dead on the way to mode_select and
# start again from the top on the way to the board. Every screen restarting the
# same track is the usual symptom of putting the player in the scene. An
# autoload is outside the scene being swapped, so the track just keeps playing.
#
# Volumes are applied to BUSES rather than to players. A player's volume_db only
# moves that one sound; a bus moves everything routed to it, including sounds
# that do not exist yet. The bus layout is default_bus_layout.tres: Master, with
# Music and SFX feeding into it.

const MUSIC_BUS := "Music"
const SFX_BUS := "SFX"

# Shares the file GameState already writes the server address into, so the game
# has one preferences file rather than one per subsystem.
const PREFS_PATH := "user://remi.cfg"

# Silence is a real setting, so the slider has to reach it. Below this the bus
# goes to actual -INF rather than a very quiet -40dB, because a fader that
# bottoms out at "nearly silent" is a fader that sounds broken.
const MIN_LINEAR := 0.001

const MUSIC_TRACK := "res://Asset/Audio/Music/memento_loop.ogg"

# 0.0 - 1.0, what the sliders show. The dB the bus actually takes is derived.
var music_volume: float = 0.7
var sfx_volume: float = 0.8

var _music: AudioStreamPlayer = null
var _sfx: Array[AudioStreamPlayer] = []
var _next_sfx: int = 0

# Enough voices that a few overlapping cues do not cut each other off. They are
# made once here rather than per sound: spawning a player per effect makes the
# node count jump around during a busy turn and every one of them has to be
# freed afterwards.
const SFX_VOICES: int = 8

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	_music = AudioStreamPlayer.new()
	_music.bus = MUSIC_BUS
	add_child(_music)
	# Restart on its own if the stream ever ends. A looping OGG never reaches
	# this, but an MP3 swapped in later, or an import that lost its Loop tick,
	# otherwise leaves the game silent for the rest of the session.
	_music.finished.connect(_on_music_finished)

	for i in range(SFX_VOICES):
		var p := AudioStreamPlayer.new()
		p.bus = SFX_BUS
		add_child(p)
		_sfx.append(p)

	load_prefs()
	play_music()

# ── Music ─────────────────────────────────────────────────────────────────

func play_music(path: String = MUSIC_TRACK) -> void:
	if _music == null:
		return
	var stream: AudioStream = load(path)
	if stream == null:
		push_warning("Audio: no music at %s" % path)
		return
	# Belt and braces over the import setting. Loop lives in the .import file
	# (the Loop tick in the import dock) and is false by default, so it is one
	# careless re-import away from a track that plays once and stops. Forcing it
	# here costs nothing and makes the behaviour a property of the game rather
	# than of a sidecar file.
	if stream is AudioStreamOggVorbis or stream is AudioStreamMP3:
		stream.loop = true
	_music.stream = stream
	_music.play()

func stop_music() -> void:
	if _music != null:
		_music.stop()

func _on_music_finished() -> void:
	if _music != null and _music.stream != null:
		_music.play()

# ── SFX ───────────────────────────────────────────────────────────────────

# Round-robin over the voice pool. Nothing calls this yet - there are no sound
# effects in the project - but the SFX bus and its slider are wired, so adding
# one is `Audio.play_sfx(preload(...))` and nothing else.
func play_sfx(stream: AudioStream, pitch: float = 1.0) -> void:
	if stream == null or _sfx.is_empty():
		return
	var p: AudioStreamPlayer = _sfx[_next_sfx]
	_next_sfx = (_next_sfx + 1) % _sfx.size()
	p.stream = stream
	p.pitch_scale = pitch
	p.play()

# ── Volume ────────────────────────────────────────────────────────────────

func set_music_volume(v: float) -> void:
	music_volume = clampf(v, 0.0, 1.0)
	_apply(MUSIC_BUS, music_volume)

func set_sfx_volume(v: float) -> void:
	sfx_volume = clampf(v, 0.0, 1.0)
	_apply(SFX_BUS, sfx_volume)

# A slider is linear and human hearing is not, so 0.5 on the slider has to mean
# "half as loud", not "half the dB". linear_to_db does that conversion; setting
# volume_db to the slider value directly is the classic way to get a control
# that does nothing for most of its travel and then drops off a cliff.
func _apply(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		push_warning("Audio: no bus named %s - is default_bus_layout.tres loaded?" % bus_name)
		return
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, MIN_LINEAR)))
	AudioServer.set_bus_mute(idx, linear <= MIN_LINEAR)

# ── Preferences ───────────────────────────────────────────────────────────

func load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) == OK:
		music_volume = float(cfg.get_value("audio", "music", music_volume))
		sfx_volume = float(cfg.get_value("audio", "sfx", sfx_volume))
	set_music_volume(music_volume)
	set_sfx_volume(sfx_volume)

func save_prefs() -> void:
	var cfg := ConfigFile.new()
	# Load first: this file is shared with GameState's server address, and
	# writing a fresh ConfigFile would drop whatever it had put there.
	cfg.load(PREFS_PATH)
	cfg.set_value("audio", "music", music_volume)
	cfg.set_value("audio", "sfx", sfx_volume)
	cfg.save(PREFS_PATH)
