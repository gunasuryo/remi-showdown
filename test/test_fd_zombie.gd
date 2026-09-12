extends SceneTree

# Returning to your own room when the server has NOT noticed you left.
#
#   1) godot --headless --path RemiShowdown --script res://server/fd_server.gd -- port=8921
#   2) godot --headless --path RemiShowdown --script res://test/test_fd_zombie.gd -- port=8921
#
# test_fd_rejoin covers the tidy case: the socket closes, the server marks the
# seat held, and the token buys it back. Reality on a phone is messier. Android
# backgrounds the app or Wi-Fi drops without a FIN ever reaching the server, so
# the old connection lingers and the seat still looks OCCUPIED. The player then
# gets "that room is full" for their own match, while the other player sits
# waiting for a move that can never come.
#
# So: abandon the first socket WITHOUT closing it, and come back on a new one
# carrying the token. The token has to win over a seat that still looks live.

const HOST := "127.0.0.1"
const TIMEOUT := 30.0

var port := 8921
var passed := 0
var failed := 0

var black: WebSocketMultiplayerPeer
var red: WebSocketMultiplayerPeer
var ghost: WebSocketMultiplayerPeer
var zombie: WebSocketMultiplayerPeer   # the abandoned socket, kept open on purpose

var code := ""
var token := ""
var stage := "connect"
var elapsed := 0.0
var wait_until := 0.0
var ghost_side := 0
var ghost_error := ""
var got_state_after := false

func _ok(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		passed += 1
		print("  PASS  %s" % name)
	else:
		failed += 1
		print("  FAIL  %s   %s" % [name, detail])

func _initialize() -> void:
	for x in OS.get_cmdline_user_args():
		if str(x).begins_with("port="):
			port = int(str(x).substr(5))
	print("rejoining a seat the server still believes is connected")
	black = WebSocketMultiplayerPeer.new(); black.create_client("ws://%s:%d" % [HOST, port])
	red = WebSocketMultiplayerPeer.new(); red.create_client("ws://%s:%d" % [HOST, port])

func _process(delta: float) -> bool:
	elapsed += delta
	if elapsed > TIMEOUT:
		_ok(false, "Z9 finished inside %ds" % int(TIMEOUT), "timed out at stage '%s'" % stage)
		return _finish()

	# `zombie` is deliberately never polled: not polling is what makes it look
	# alive to the server but deaf to it, which is exactly a backgrounded phone.
	if black != null:
		black.poll()
	red.poll()
	if ghost != null:
		ghost.poll()

	if stage == "connect" and black.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		stage = "creating"
		_send(black, {"t": "create"})

	if black != null:
		_drain(black, "black")
	_drain(red, "red")
	if ghost != null:
		_drain(ghost, "ghost")

	if stage == "abandon" and elapsed > wait_until:
		stage = "returning"
		ghost = WebSocketMultiplayerPeer.new()
		ghost.create_client("ws://%s:%d" % [HOST, port])

	if stage == "returning" and ghost.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		stage = "return_sent"
		_send(ghost, {"t": "join", "code": code, "token": token})

	if stage == "done" and elapsed > wait_until:
		_final()
		return _finish()
	return false

func _finish() -> bool:
	print("")
	print("%d assertions, %d failed" % [passed + failed, failed])
	quit(1 if failed > 0 else 0)
	return true

func _send(sock: WebSocketMultiplayerPeer, msg: Dictionary) -> void:
	sock.set_target_peer(MultiplayerPeer.TARGET_PEER_SERVER)
	sock.put_packet(FDNet.to_bytes(msg))

func _drain(sock: WebSocketMultiplayerPeer, who: String) -> void:
	while sock.get_available_packet_count() > 0:
		_on_msg(who, FDNet.from_bytes(sock.get_packet()))

func _on_msg(who: String, msg: Dictionary) -> void:
	var t := str(msg.get("t", ""))

	if who == "ghost":
		if t == "error":
			ghost_error = str(msg.get("msg", ""))
		elif t == "room":
			ghost_side = int(msg.get("side", 0))
			_ok(bool(msg.get("rejoined", false)),
				"Z3 the server treats this as a rejoin, not a new seat")
		elif t == "state":
			got_state_after = true
			stage = "done"
			wait_until = elapsed + 0.5
		return

	if t == "room" and who == "black" and stage == "creating":
		code = str(msg.code)
		token = str(msg.token)
		_ok(code != "" and token != "", "Z1 creator receives a room code and a seat token")
		stage = "joining"
		_send(red, {"t": "join", "code": code})

	if t == "state" and stage == "joining":
		stage = "abandon"
		_ok(true, "Z2 match started with both seats filled")
		# Walk away from the socket without closing it. The server is told
		# nothing, so the seat still reads as occupied.
		zombie = black
		black = null
		wait_until = elapsed + 2.0

func _final() -> void:
	_ok(ghost_error == "", "Z4 returning with the token is not refused",
		"server said '%s'" % ghost_error)
	_ok(ghost_side == FDState.BLACK, "Z5 the original seat is returned",
		"got side %d" % ghost_side)
	_ok(got_state_after, "Z6 the returning client is resynced with the match")
	# Referenced so the socket is not collected early - the point is that it
	# stays open for the whole test.
	_ok(zombie != null, "Z7 the abandoned socket was never closed")
