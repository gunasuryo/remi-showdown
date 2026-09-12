extends RefCounted
class_name Sound

# How everything that is not a scene script reaches the Audio autoload.
#
# `Audio` is an autoload, and an autoload is not an identifier everywhere. The
# main-loop script of a `--script` run is compiled BEFORE autoloads register -
# and so is everything it pulls in, which includes every `class_name` script it
# names. test/test_fu_board.gd calls FUStage.cast_is_visible(), so fu_stage.gd
# is compiled in that window; the moment it said `Audio.play_cue(...)` the whole
# test stopped building with "Identifier not found: Audio".
#
# A scene script is safe - table2.gd has referred to GameState for as long as it
# has existed - because scenes load at runtime, long after the autoloads exist.
# It is the class_name scripts that cannot.
#
# So they come through here instead. Nothing below names the autoload at compile
# time: it is fetched from the tree by path, at the moment of use, and a missing
# one is simply silence rather than a crash. That also keeps the headless tests
# honest - they run with no audio driver and must not care.

# The autoload, or null if it is not up yet (a test harness, an early _init).
static func node() -> Node:
	var loop := Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return null
	return (loop as SceneTree).root.get_node_or_null("/root/Audio")

# Fire a named cue. Safe to call from anywhere, at any time.
static func cue(name: String) -> void:
	var a := node()
	if a != null:
		a.play_cue(name)
