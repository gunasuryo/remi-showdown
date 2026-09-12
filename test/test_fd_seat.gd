extends Node

# The client half of "let me back into my own room".
#
#   godot --headless --path RemiShowdown res://test/test_fd_seat.tscn
#
# The server will hand a seat back to whoever presents its token, even when the
# old connection is still hanging around (test_fd_zombie). None of that helps if
# the client throws the token away before asking - which is what the lobby used
# to do on every create AND every join, so a host who dropped could never get
# back in and was told "that room is full" about their own match.
#
# Every assertion below runs in one frame: _enter() ends in change_scene_to_file,
# which would tear this test down at the end of the frame it lands in.

const LOBBY: String = "res://Scene/lobby.tscn"

var passed := 0
var failed := 0

func _ok(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		passed += 1
		print("  PASS  %s" % name)
	else:
		failed += 1
		print("  FAIL  %s   %s" % [name, detail])

func _ready() -> void:
	print("seat token survives the lobby")

	# --- the lobby's decision to keep or drop the token --------------------
	var lobby = (load(LOBBY) as PackedScene).instantiate()
	add_child(lobby)

	GameState.room_code = "ABCD"
	GameState.seat_token = "deadbeef"
	lobby._enter("join", "ABCD")
	_ok(GameState.seat_token == "deadbeef",
		"T1 rejoining the same room keeps the token",
		"token became '%s'" % GameState.seat_token)

	GameState.room_code = "ABCD"
	GameState.seat_token = "deadbeef"
	lobby._enter("join", "WXYZ")
	_ok(GameState.seat_token == "",
		"T2 joining a different room drops the token",
		"token stayed '%s'" % GameState.seat_token)

	GameState.room_code = "ABCD"
	GameState.seat_token = "deadbeef"
	lobby._enter("create", "")
	_ok(GameState.seat_token == "",
		"T3 creating a room drops the token",
		"token stayed '%s'" % GameState.seat_token)

	# --- surviving the process ---------------------------------------------
	# Android kills a backgrounded app whenever it likes; a token that only
	# lived in RAM went with it.
	GameState.room_code = "QRST"
	GameState.seat_token = "0123456789abcdef"
	GameState.save_prefs()
	GameState.room_code = ""
	GameState.seat_token = ""
	GameState.load_prefs()
	_ok(GameState.seat_token == "0123456789abcdef",
		"T4 the token is restored from disk",
		"got '%s'" % GameState.seat_token)
	_ok(GameState.room_code == "QRST",
		"T5 the room code is restored from disk",
		"got '%s'" % GameState.room_code)

	# --- the lobby offers it back ------------------------------------------
	var l2 = (load(LOBBY) as PackedScene).instantiate()
	add_child(l2)
	_ok(l2.get_node("UI/Root/CodeEdit").text == "QRST",
		"T6 the lobby pre-fills the held room's code",
		"field read '%s'" % l2.get_node("UI/Root/CodeEdit").text)

	# Leave no seat behind for the next run or the next match.
	GameState.room_code = ""
	GameState.seat_token = ""
	GameState.save_prefs()

	print("")
	print("%d assertions, %d failed" % [passed + failed, failed])
	get_tree().quit(1 if failed > 0 else 0)
