extends SceneTree

# A client that has lost track must be able to ask for the board again.
#
#   1) godot --headless --path RemiShowdown --script res://server/fd_server.gd -- port=8916
#   2) godot --headless --path RemiShowdown --script res://test/test_fd_resync.gd -- port=8916
#
# Before this existed there was no way back from a single lost packet. Every
# state push is a SIDE EFFECT of somebody doing something - joining, placing,
# acting - so a client that missed one simply waited, forever, for a move it had
# already been sent. The socket stayed up the whole time, so nothing looked
# broken; the match was just over for that player.
#
# Two properties matter and both are checked here:
#
#   * a resync returns the CURRENT board, complete. Snapshots are absolute
#     rather than deltas, so one reply is a full repair however far behind the
#     client had fallen.
#   * a resync does NOT advance the sequence. It is not a new step, and if it
#     looked like one the OTHER client would conclude it had missed something.

const HOST := "127.0.0.1"
const TIMEOUT := 30.0

var port := 8916
var passed := 0
var failed := 0

var black: WebSocketMultiplayerPeer
var red: WebSocketMultiplayerPeer
var code := ""
var stage := "connect"
var elapsed := 0.0
var wait_until := 0.0

# What the last ordinary push looked like, to compare the resync against.
var last_seq := -1
var last_slots: Array = []
var resync_seq := -1
var resync_slots: Array = []
var resync_had_events := true
var resync_flagged := false
var red_seq_after := -1
var red_pushes_after := 0
var watching_red := false

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
	print("face-down server, resync on port %d" % port)
	black = WebSocketMultiplayerPeer.new()
	red = WebSocketMultiplayerPeer.new()
	black.create_client("ws://%s:%d" % [HOST, port])
	red.create_client("ws://%s:%d" % [HOST, port])

func _process(delta: float) -> bool:
	elapsed += delta
	if elapsed > TIMEOUT:
		_ok(false, "Y9 finished inside %ds" % int(TIMEOUT), "timed out at stage '%s'" % stage)
		return _finish()

	black.poll()
	red.poll()

	if stage == "connect" and black.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		stage = "creating"
		_send(black, {"t": "create"})

	_drain(black, "black")
	_drain(red, "red")

	if stage == "settle" and elapsed > wait_until:
		# The board is live and quiet. Ask for it again without anything having
		# happened, which is exactly the situation a stuck client is in.
		stage = "asked"
		watching_red = true
		red_pushes_after = 0
		_send(black, {"t": "resync"})
		wait_until = elapsed + 2.0

	if stage == "asked" and elapsed > wait_until:
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

	if t == "room" and who == "black" and stage == "creating":
		code = str(msg.code)
		stage = "joining"
		_send(red, {"t": "join", "code": code})
		return

	if t != "state":
		return

	if who == "red":
		if watching_red:
			red_pushes_after += 1
			red_seq_after = int(msg.get("seq", -1))
		return

	# Black's own pushes.
	if stage == "joining":
		stage = "settle"
		wait_until = elapsed + 1.0
		_ok(int(msg.get("seq", -1)) > 0, "Y1 an ordinary push carries a sequence number")

	if stage == "asked":
		resync_flagged = bool(msg.get("resync", false))
		resync_seq = int(msg.get("seq", -1))
		resync_slots = msg.get("slots", {}).get(str(FDState.BLACK), []).duplicate()
		resync_had_events = not (msg.get("events", []) as Array).is_empty()
	else:
		last_seq = int(msg.get("seq", -1))
		last_slots = msg.get("slots", {}).get(str(FDState.BLACK), []).duplicate()

func _final() -> void:
	_ok(resync_seq != -1, "Y2 asking for a resync gets the board back")
	if resync_seq == -1:
		return
	_ok(resync_flagged, "Y3 the reply is marked as a resync")
	_ok(not resync_had_events,
		"Y4 it carries no events - it is the board, not a story about it")
	_ok(resync_seq == last_seq,
		"Y5 it does NOT advance the sequence",
		"resync seq %d, last ordinary push %d" % [resync_seq, last_seq])
	_ok(resync_slots == last_slots,
		"Y6 the board it returns is the one we already had",
		"%s vs %s" % [str(resync_slots), str(last_slots)])

	# The other seat must not be disturbed. A resync is a private repair; if it
	# were broadcast, one player's bad connection would spam the other, and a
	# bumped sequence would make THEM think they had fallen behind.
	_ok(red_pushes_after == 0,
		"Y7 the opponent is not pushed anything by our resync",
		"red received %d pushes" % red_pushes_after)
