extends SceneTree

# Suit preference and the tie the server has to settle.
#
#   1) godot --headless --path RemiShowdown --script res://server/fd_server.gd -- port=8920
#   2) godot --headless --path RemiShowdown --script res://test/test_fd_suit.gd -- port=8920
#
# Both players pick a suit independently, so they will sometimes pick the same
# one. The server gives it to whoever asked first and hands the other player the
# remaining suit - refusing the join instead would bounce someone back to the
# lobby over a coin toss.

const HOST := "127.0.0.1"
const TIMEOUT := 25.0

var port := 8920
var passed := 0
var failed := 0
var a: WebSocketMultiplayerPeer
var b: WebSocketMultiplayerPeer
var code := ""
var sent_create := false
var sent_join := false
var a_side := 0
var b_side := 0
var b_got_pref := true
var elapsed := 0.0
var done_at := -1.0

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
	print("suit preference, both asking for RED")
	a = WebSocketMultiplayerPeer.new(); a.create_client("ws://%s:%d" % [HOST, port])
	b = WebSocketMultiplayerPeer.new(); b.create_client("ws://%s:%d" % [HOST, port])

func _process(delta: float) -> bool:
	elapsed += delta
	if elapsed > TIMEOUT:
		_ok(false, "U9 finished in time", "timed out")
		return _finish()
	a.poll(); b.poll()
	if a.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and not sent_create:
		sent_create = true
		# A asks for RED first.
		_send(a, FDNet.encode_room("create", "", "", FDState.RED))
	_drain(a, "A"); _drain(b, "B")
	if done_at > 0.0 and elapsed > done_at:
		_checks()
		return _finish()
	return false

func _finish() -> bool:
	print("")
	print("%d assertions, %d failed" % [passed + failed, failed])
	quit(1 if failed > 0 else 0)
	return true

func _send(p, m) -> void:
	p.set_target_peer(MultiplayerPeer.TARGET_PEER_SERVER)
	p.put_packet(FDNet.to_bytes(m))

func _drain(p, who: String) -> void:
	while p.get_available_packet_count() > 0:
		var m: Dictionary = FDNet.from_bytes(p.get_packet())
		if str(m.get("t", "")) != "room":
			continue
		if who == "A":
			a_side = int(m.side)
			code = str(m.code)
			_ok(bool(m.get("got_preference", false)), "U1 the first player gets the suit they asked for")
			# B asks for RED too - the one A already has.
			if not sent_join:
				sent_join = true
				_send(b, FDNet.encode_room("join", code, "", FDState.RED))
		else:
			b_side = int(m.side)
			b_got_pref = bool(m.get("got_preference", true))
			done_at = elapsed + 0.3

func _checks() -> void:
	_ok(a_side == FDState.RED, "U1 ...which was RED", "got %d" % a_side)
	_ok(b_side == FDState.BLACK, "U2 the second player is given the other suit",
		"got %d" % b_side)
	_ok(a_side != b_side, "U2 the two players never share a suit")
	_ok(not b_got_pref, "U3 the second player is TOLD they did not get their pick")
