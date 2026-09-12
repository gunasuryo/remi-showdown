extends Node2D

# The online lobby: open a room, or walk into one.
#
# The server address is NOT something a player should have to type. The build
# ships pointed at GameState.DEFAULT_SERVER_URL, so the normal path is two taps:
# CREATE A ROOM, read the code out, done. The address is shown as one small line
# with a "change" button, and the editor only appears if that is pressed - kept
# because testing against a local server is worth one button.
#
# This screen deliberately does NOT connect. Connecting here would mean either
# holding a socket open across a scene change or building a second copy of the
# logic already in FDRemoteSession. It only collects address, create-or-join and
# code; the board reports anything that goes wrong by bouncing back here with
# GameState.last_error.

const MODE_SELECT: String = "res://Scene/mode_select.tscn"
const BOARD: String = "res://Scene/FaceDown/fd_table.tscn"

const C_BAD := Color(1, 0.45, 0.42)
const C_OK := Color(0.62, 0.72, 0.9)
const C_DIM := Color(0.5, 0.54, 0.6)

var _editing_server: bool = false

func _ready() -> void:
	SafeArea.bind($UI/Root)
	# A seat is still held somewhere: put its code in the box so getting back in
	# is one tap. Nobody memorises a room code they only ever read aloud once,
	# and JOIN with this code now carries the token that reclaims the seat.
	var can_rejoin: bool = GameState.seat_token != "" and GameState.room_code != ""
	$UI/Root/CodeEdit.text = GameState.room_code if can_rejoin else ""
	_show_server(false)

	# Coming back from a failed match: say why before they try again, and open
	# the address editor, since a wrong server is the likeliest cause.
	if GameState.last_error != "":
		_say(GameState.last_error, C_BAD)
		_show_server(true)
		GameState.last_error = ""
	elif can_rejoin:
		_say("Tap JOIN to return to room %s, or create a new one." % GameState.room_code, C_OK)
	else:
		_say("Create a room and read the code out, or type a friend's.", C_OK)

	$UI/Root/CodeEdit.text_submitted.connect(func(_t): _on_join_btn_pressed())

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back_btn_pressed()

func _say(msg: String, colour: Color) -> void:
	$UI/Root/Status.text = msg
	$UI/Root/Status.add_theme_color_override("font_color", colour)

# Collapsed: one dim line naming the host. Expanded: the editable field.
func _show_server(editing: bool) -> void:
	_editing_server = editing
	$UI/Root/ServerEdit.visible = editing
	$UI/Root/ServerLine.visible = not editing
	$UI/Root/ServerBtn.text = "done" if editing else "change"
	if editing:
		$UI/Root/ServerEdit.text = GameState.server_url
		$UI/Root/ServerEdit.grab_focus()
	else:
		# Strip the scheme: the player does not need to read "wss://" to know
		# which server they are on.
		var shown: String = GameState.server_url
		for prefix in ["wss://", "ws://"]:
			if shown.begins_with(prefix):
				shown = shown.substr(prefix.length())
		$UI/Root/ServerLine.text = "server: %s" % shown
		$UI/Root/ServerLine.add_theme_color_override("font_color", C_DIM)

func _on_server_btn_pressed() -> void:
	if _editing_server and not _commit_server():
		return
	_show_server(not _editing_server)

# Only called when the field is actually open; otherwise the stored address
# stands and there is nothing to validate.
func _commit_server() -> bool:
	var url: String = $UI/Root/ServerEdit.text.strip_edges()
	if url == "":
		_say("Enter a server address, or press done to keep the current one.", C_BAD)
		return false
	# A bare host is what people actually type. Default to wss:// - ws:// does
	# not work from Android at all (see GameState.DEFAULT_SERVER_URL).
	if not (url.begins_with("ws://") or url.begins_with("wss://")):
		url = "wss://" + url
	GameState.server_url = url
	GameState.save_prefs()
	return true

func _enter(action: String, code: String) -> void:
	if _editing_server and not _commit_server():
		return
	GameState.opponent = GameState.Opponent.ONLINE
	# The token is what buys a dropped player their own seat back, so it must
	# survive the trip through this screen when - and only when - they are
	# heading for the SAME room. Clearing it unconditionally is what made a host
	# unable to return to their own match: the board then asked to join as a
	# stranger, the server saw a seat that was not free, and answered "that room
	# is full" while the other player sat waiting for a move.
	#
	# Creating always means a fresh seat, and so does joining some other code.
	if action == "create" or code != GameState.room_code:
		GameState.seat_token = ""
	GameState.room_action = action
	GameState.room_code = code
	GameState.save_prefs()
	get_tree().change_scene_to_file(BOARD)

func _on_create_btn_pressed() -> void:
	_enter("create", "")

func _on_join_btn_pressed() -> void:
	var code: String = $UI/Root/CodeEdit.text.strip_edges().to_upper()
	if code.length() != 4:
		_say("A room code is four letters.", C_BAD)
		return
	_enter("join", code)

func _on_back_btn_pressed() -> void:
	GameState.opponent = GameState.Opponent.AI
	get_tree().change_scene_to_file(MODE_SELECT)
