extends SceneTree

# Audio wiring, headless.
#
#   godot --headless --path RemiShowdown --script res://test/test_audio.gd
#
# Every failure this guards is SILENT. A missing bus, an import that lost its
# Loop tick, an autoload that was never registered, a signal wired to a node
# that does not exist - none of them crash. The game just runs without music, or
# with music that stops after one play, or with a panel that cannot be closed,
# and you find out by playing far enough to notice.
#
# Headless uses the dummy audio driver: nothing is audible, but the buses, the
# streams and the player states are all real.

var failures: Array = []
var checks: int = 0

func _ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures.append(what)

func _initialize() -> void:
	# Compiled before the autoloads register, so `Audio` is not an identifier
	# here the way it is inside a scene script.
	var audio: Node = root.get_node_or_null("/root/Audio")
	_ok(audio != null, "the Audio autoload is registered")
	if audio == null:
		_report()
		return

	# ── Buses ───────────────────────────────────────────────────────────
	# Volume is applied per bus, so a typo in a bus name is the difference
	# between a working slider and one that does nothing at all.
	for bus in ["Master", "Music", "SFX"]:
		_ok(AudioServer.get_bus_index(bus) >= 0, "bus %s exists" % bus)

	# ── The track ───────────────────────────────────────────────────────
	var stream: AudioStream = load(audio.MUSIC_TRACK)
	_ok(stream != null, "the music track loads: %s" % audio.MUSIC_TRACK)
	if stream != null:
		_ok(stream is AudioStreamOggVorbis or stream is AudioStreamMP3,
			"the track is a stream type that can loop")
		_ok(bool(stream.loop), "the track is set to loop")

	# ── It is actually playing ──────────────────────────────────────────
	var player: AudioStreamPlayer = null
	for child in audio.get_children():
		if child is AudioStreamPlayer and child.bus == "Music":
			player = child
			break
	_ok(player != null, "there is a music player on the Music bus")
	if player != null:
		_ok(player.playing, "music started on its own at boot")
		_ok(player.stream != null and bool(player.stream.loop),
			"the stream it is playing loops")

	# ── Volume maps the way a slider expects ────────────────────────────
	var idx := AudioServer.get_bus_index("Music")
	audio.set_music_volume(1.0)
	var loud := AudioServer.get_bus_volume_db(idx)
	audio.set_music_volume(0.5)
	var mid := AudioServer.get_bus_volume_db(idx)
	audio.set_music_volume(0.0)
	_ok(mid < loud, "a lower slider value is a lower bus volume")
	_ok(AudioServer.is_bus_mute(idx), "zero on the slider is actually silent")
	_ok(not is_equal_approx(mid, 0.5),
		"volume is converted to dB, not assigned raw")
	audio.set_music_volume(0.7)

	# ── The scenes that hang controls off all this ──────────────────────
	_scene("res://Scene/mode_select.tscn", [
		"UI/Root/AudioBtn",
	])
	# The connection to this button has been in the scene file for a while; the
	# button itself was never added, so the rules panel had no way to close.
	_scene("res://Scene/FaceDown/fd_table.tscn", [
		"UI/Root/RulesPanel",
		"UI/Root/RulesPanel/M/V/CloseRulesBtn",
	])
	_report()

# Instantiates a scene and checks the named nodes are really there. Loading it
# is also what surfaces a connection pointing at a node that does not exist.
func _scene(path: String, node_paths: Array) -> void:
	var packed: PackedScene = load(path)
	_ok(packed != null, "%s loads" % path)
	if packed == null:
		return
	var inst := packed.instantiate()
	for np in node_paths:
		_ok(inst.get_node_or_null(np) != null, "%s has %s" % [path.get_file(), np])
	inst.free()

func _report() -> void:
	print("")
	if failures.is_empty():
		print("AUDIO OK: %d checks" % checks)
	else:
		print("AUDIO FAIL:")
		for f in failures:
			print("  ", f)
	quit(1 if not failures.is_empty() else 0)
