extends SceneTree

# A dropped player must be able to walk back into the same match.
#
#   1) godot --headless --path RemiShowdown --script res://server/fd_server.gd -- port=8914
#   2) godot --headless --path RemiShowdown --script res://test/test_fd_rejoin.gd -- port=8914
#
# This matters more here than in most games: matches are played on phones, a
# phone loses Wi-Fi constantly, and a turn-based match has no reason to be lost
# to a ten-second network blip. The server holds a dropped seat for
# SEAT_HOLD_SECONDS and hands it back to whoever presents the seat token.
#
# The token is also the authorisation: without it a third party who guessed the
# four-letter room code could take the seat. R4 checks that.

const HOST := "127.0.0.1"
const TIMEOUT := 30.0

var port := 8914
var passed := 0
var failed := 0

var black: WebSocketMultiplayerPeer
var red: WebSocketMultiplayerPeer
var intruder: WebSocketMultiplayerPeer
var code := ""
var token := ""
var stage := "connect"
var elapsed := 0.0
var wait_until := 0.0
var rejoined_side := 0
var got_state_after := false
var intruder_refused := false
var rng := RandomNumberGenerator.new()
var _intruder_tried := false

func _ok(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		passed += 1
		print("  PASS  %s" % name)
	else:
		failed += 1
		print("  FAIL  %s   %s" % [name, detail])

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("port="):
			port = int(str(a).substr(5))
	rng.seed = 11
	print("face-down server, reconnection on port %d" % port)
	black = WebSocketMultiplayerPeer.new()
	red = WebSocketMultiplayerPeer.new()
	black.create_client("ws://%s:%d" % [HOST, port])
	red.create_client("ws://%s:%d" % [HOST, port])

func _process(delta: float) -> bool:
	elapsed += delta
	if elapsed > TIMEOUT:
		_ok(false, "R9 finished inside %ds" % int(TIMEOUT), "timed out at stage '%s'" % stage)
		return _finish()

	black.poll()
	red.poll()
	if intruder != null:
		intruder.poll()

	if stage == "connect" and black.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		stage = "creating"
		_send(black, {"t": "create"})

	_drain(black, "black")
	_drain(red, "red")
	if intruder != null:
		_drain(intruder, "intruder")

	if intruder != null and not _intruder_tried 			and intruder.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_intruder_tried = true
		_send(intruder, {"t": "join", "code": code})

	if stage == "dropped" and elapsed > wait_until:
		# Come back on a brand new socket, carrying only the seat token.
		stage = "rejoining"
		black = WebSocketMultiplayerPeer.new()
		black.create_client("ws://%s:%d" % [HOST, port])

	if stage == "rejoining" and black.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		stage = "rejoin_sent"
		_send(black, {"t": "join", "code": code, "token": token})

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

	if who == "intruder":
		if t == "error":
			intruder_refused = true
		elif t == "room":
			_ok(false, "R4 a tokenless stranger is refused the held seat",
				"stranger was seated as side %d" % int(msg.get("side", 0)))
		return

	if t == "room" and who == "black":
		if stage == "creating":
			code = str(msg.code)
			token = str(msg.token)
			_ok(code != "" and token != "", "R1 creator receives a room code and a seat token")
			stage = "joining"
			_send(red, {"t": "join", "code": code})
		elif stage == "rejoin_sent":
			rejoined_side = int(msg.get("side", 0))
			_ok(bool(msg.get("rejoined", false)), "R3 server acknowledges this as a rejoin")
			_ok(rejoined_side == FDState.BLACK, "R3 the same seat is returned",
				"got side %d" % rejoined_side)

	if t == "state":
		if stage == "joining":
			# Match is live. Drop Black by closing its socket outright.
			stage = "dropped"
			_ok(true, "R2 match started with both seats filled")
			black.close()
			# While the seat is held, a stranger with the code but no token
			# must not be able to take it.
			intruder = WebSocketMultiplayerPeer.new()
			intruder.create_client("ws://%s:%d" % [HOST, port])
			wait_until = elapsed + 2.5
		elif stage == "rejoin_sent":
			got_state_after = true
			stage = "done"
			wait_until = elapsed + 0.5

	if t == "peer" and str(msg.get("event", "")) == "joined" and stage == "joining":
		pass

func _final() -> void:
	_ok(got_state_after, "R3 the rejoined client is resynced with the match state")
	_ok(intruder_refused, "R4 a tokenless stranger is refused the held seat")
