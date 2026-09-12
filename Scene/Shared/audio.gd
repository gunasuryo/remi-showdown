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
	# Deliberately NOT starting the music here. The autoload owns the player and
	# the volume; WHEN a track plays is a decision about the game, and the menus
	# are supposed to be quiet. The boards call play_music() as they open and
	# mode_select calls stop_music() as it does - see the note on stop_music().

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

# Called by mode_select rather than by each board on the way out, because there
# are several ways to leave a match - the Menu button, the Android back gesture,
# and the game-over screen - and they all land here. Stopping on arrival at the
# hub covers every one of them, including any added later; stopping on departure
# would have to be remembered at each exit.
func stop_music() -> void:
	if _music != null:
		_music.stop()

func _on_music_finished() -> void:
	if _music != null and _music.stream != null:
		_music.play()

# ── SFX ───────────────────────────────────────────────────────────────────

# Cues are named for WHAT HAPPENED, never for a file. Call sites say
# `Audio.play_cue("attack")`, so re-cutting the audio is an edit to this table
# and nothing else - and a caller cannot quietly go on playing a sound that no
# longer suits the action it belongs to.
#
# Several entries list more than one file. Kenney numbers its variants for
# exactly this reason: the same sound on every attack of a forty-action match
# turns into a machine gun, and rotating three takes is the cheapest fix there
# is. _pick() chooses at random, and single-file cues get a small pitch wobble
# instead so they do not sound stamped out either.
const CASINO := "res://Asset/Audio/SFX/CasinoSFX/"
const RPG := "res://Asset/Audio/SFX/RPGSFX/"

const CUES := {
	# Combat. A plain attack is a blunt impact; a Jack's shoot travels, so it
	# gets the blade instead and reads as a different action with eyes shut.
	"attack": [RPG + "chop.ogg"],
	# The half-damage reach into a neighbouring lane. A softer, duller landing
	# than `attack`, so the two are distinguishable with eyes shut - which is the
	# only reason to have a separate cue for it at all. FACE-DOWN ONLY: face-up
	# locks an attack to the lane it faces, so nothing there can fire this.
	"attack_weak": [RPG + "bookPlace1.ogg", RPG + "bookPlace3.ogg"],
	"shoot": [RPG + "knifeSlice.ogg", RPG + "knifeSlice2.ogg"],
	"death": [CASINO + "card-place-1.ogg", CASINO + "card-place-2.ogg",
		CASINO + "card-place-3.ogg", CASINO + "card-place-4.ogg"],

	# Skills, each with its own texture so a player can tell what landed
	# without reading the log.
	"shield": [RPG + "metalLatch.ogg", RPG + "metalPot1.ogg"],
	"heal": [CASINO + "chips-stack-1.ogg", CASINO + "chips-stack-3.ogg",
		CASINO + "chips-stack-5.ogg"],
	# Cloth rather than a card flourish. The fan moved to positioning, where
	# a whole row really is being fanned out and the sound is literal.
	"rally": [RPG + "clothBelt2.ogg"],
	"trick": [RPG + "creak1.ogg", RPG + "creak2.ogg", RPG + "creak3.ogg"],
	"trick_sprung": [RPG + "dropLeather.ogg"],

	# A hidden status coming out. Deliberately not the same as the cast: the
	# cast is a secret being kept, the reveal is one being broken.
	"reveal": [CASINO + "card-slide-1.ogg", CASINO + "card-slide-4.ogg",
		CASINO + "card-slide-7.ogg"],

	# Structure. Face-down deals a fresh hidden row every round, so it has two
	# beats face-up has no equivalent for: committing an arrangement, and the
	# moment the rows go face down again.
	"lock_in": [CASINO + "card-fan-1.ogg"],
	"positioning": [CASINO + "card-fan-2.ogg"],
	"round": [CASINO + "card-shuffle.ogg"],
	"match_end": [CASINO + "chips-collide-1.ogg", CASINO + "chips-collide-3.ogg"],

	# UI. A chip going down for committing to an action - it is a bet - and a
	# lighter click for everything else.
	"commit": [CASINO + "chip-lay-1.ogg", CASINO + "chip-lay-2.ogg",
		CASINO + "chip-lay-3.ogg"],
	"click": [RPG + "metalClick.ogg"],
	"cancel": [CASINO + "card-shove-1.ogg", CASINO + "card-shove-3.ogg"],
	"book_open": [RPG + "bookOpen.ogg"],
	"book_close": [RPG + "bookClose.ogg"],
}

var _cue_cache := {}

# Plays one take of a named cue. Unknown names warn rather than fail silently:
# a mistyped cue is otherwise indistinguishable from a sound that is simply
# quiet, and the whole point of the table is that the names are checkable.
func play_cue(cue: String) -> void:
	if not CUES.has(cue):
		push_warning("Audio: no cue named %s" % cue)
		return
	var paths: Array = CUES[cue]
	if paths.is_empty():
		return
	var path: String = paths[randi() % paths.size()]
	if not _cue_cache.has(path):
		_cue_cache[path] = load(path)
	# One take gets a wobble so repeats are not identical; several takes are
	# already varied, so they are left alone.
	var pitch: float = 1.0 if paths.size() > 1 else randf_range(0.94, 1.06)
	play_sfx(_cue_cache[path], pitch)

# Round-robin over the voice pool.
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
