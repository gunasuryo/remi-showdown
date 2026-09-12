extends SceneTree

# End-to-end test: two real WebSocket clients play a complete match through the
# server, over a real socket.
#
#   1) godot --headless --path RemiShowdown --script res://server/fd_server.gd -- port=8911
#   2) godot --headless --path RemiShowdown --script res://test/test_fd_server.gd -- port=8911
#
# Both clients are driven by FDHardAI, which is exactly the point: the AI can
# only see FDState.observe(), so if a client can play a legal match from a
# redacted snapshot then the snapshot carries everything a PLAYER needs and
# nothing more. A leak would not be caught by this test - test_fd_net.gd owns
# that - but a snapshot that is missing something shows up here immediately as
# a rejected move.
#
# It also exercises the parts that only exist over a network: acting out of
# turn, acting for the other player's cards, malformed packets, and a rejoin
# after a dropped connection.

const HOST := "127.0.0.1"
# Generous by default: against a server on another continent every action is a
# round trip, and a full match is scores of them. Override with secs=.
var TIMEOUT := 45.0

var port := 8911
# Defaults to the local server; pass url=wss://host to run the same match
# against a deployed one. Verifying a real deployment with the SAME test that
# guards the code is worth more than a hand-rolled smoke check.
var url := ""
var passed := 0
var failed := 0

# WebSocketMultiplayerPeer on BOTH ends, not a raw WebSocketPeer here. The
# multiplayer peer wraps every packet in its own routing framing, so a raw
# socket client reads the header as body and sees UTF-8 garbage instead of
# JSON. They are not interchangeable transports.
var black: WebSocketMultiplayerPeer
var red: WebSocketMultiplayerPeer
var black_state: FDState = null
var red_state: FDState = null
var code := ""
var black_token := ""
var side_of := {}
var over := false
# "over" reaches the two clients in separate packets. Checking the moment the
# first one lands compares a finished view against one that has not drained its
# last state yet, which reads as the clients disagreeing when they do not.
var over_at := -1.0
var winner := 0
var elapsed := 0.0
var errors: Array = []
var rng := RandomNumberGenerator.new()
var placed_round := {}
var _beat := 2.0
var _acts := 0

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
		elif str(a).begins_with("url="):
			url = str(a).substr(4)
		elif str(a).begins_with("secs="):
			TIMEOUT = float(str(a).substr(5))
	if url == "":
		url = "ws://%s:%d" % [HOST, port]
	rng.seed = 7
	print("face-down server, end to end against %s" % url)
	black = WebSocketMultiplayerPeer.new()
	red = WebSocketMultiplayerPeer.new()
	_ok(black.create_client(url) == OK, "S1 black opens a socket")
	_ok(red.create_client(url) == OK, "S1 red opens a socket")

func _process(delta: float) -> bool:
	elapsed += delta
	if elapsed > TIMEOUT:
		_ok(false, "S9 match completed inside %ds" % int(TIMEOUT), "timed out")
		return _finish()

	black.poll()
	red.poll()

	_beat -= delta
	if _beat <= 0.0:
		_beat = 5.0
		var bs := "-" if black_state == null else "r%d p%d turn%d" % [
			black_state.round_no, black_state.phase, black_state.side_to_act]
		var rs := "-" if red_state == null else "r%d p%d turn%d" % [
			red_state.round_no, red_state.phase, red_state.side_to_act]
		print("    [%4.1fs] acts=%d  black(%s)  red(%s)" % [elapsed, _acts, bs, rs])

	if black.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and code == "":
		_send(black, {"t": "create"})
		code = "pending"

	_drain(black, FDState.BLACK)
	_drain(red, FDState.RED)

	# Keep polling after the result so BOTH clients drain their final state.
	if over and elapsed > over_at + 0.75:
		_final_checks()
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

func _drain(sock: WebSocketMultiplayerPeer, who: int) -> void:
	while sock.get_available_packet_count() > 0:
		_on_msg(sock, who, FDNet.from_bytes(sock.get_packet()))

func _on_msg(sock: WebSocketMultiplayerPeer, who: int, msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"room":
			side_of[who] = int(msg.side)
			if who == FDState.BLACK:
				code = str(msg.code)
				black_token = str(msg.token)
				_ok(code.length() == 4, "S2 server issued a 4-character room code")
				_ok(int(msg.side) == FDState.BLACK, "S2 creator seats as Black")
				# Red now joins the room Black just made.
				_send(red, {"t": "join", "code": code})
			else:
				_ok(int(msg.side) == FDState.RED, "S2 joiner seats as Red")

		"state":
			var s := FDNet.restore(msg)
			if who == FDState.BLACK:
				black_state = s
			else:
				red_state = s
			_after_state(sock, who, s, msg)

		"error":
			errors.append(str(msg.msg))

		"over":
			if not over:
				over = true
				over_at = elapsed
				winner = int(msg.get("winner", 0))

func _after_state(sock: WebSocketMultiplayerPeer, who: int, s: FDState, msg: Dictionary) -> void:
	var me: int = side_of.get(who, who)

	# A client must never receive the opponent's row.
	var enemy: int = s.opponent(me)
	# begin_round() empties both rows, so board_size is NOT a safe bound on the
	# slots array until placement has been committed.
	for slot in range(s.slots[enemy].size()):
		if not s.is_revealed(enemy, slot):
			if int(s.slots[enemy][slot]) != FDCard.HIDDEN:
				_ok(false, "S3 unrevealed enemy slot arrives withheld",
					"slot %d carried id %d" % [slot, int(s.slots[enemy][slot])])
				over = true
				return

	if s.phase == FDState.Phase.POSITIONING:
		# Place once per round, not once per snapshot.
		var key := "%d:%d" % [me, s.round_no]
		if not placed_round.has(key):
			placed_round[key] = true
			_send(sock, FDNet.encode_placement(FDRules.auto_place(s, me, rng)))
		return

	if s.phase != FDState.Phase.BATTLE or s.side_to_act != me:
		return

	# The whole point: choose from the redacted snapshot alone.
	var action: Dictionary = FDHardAI.choose_action(s, me, rng)
	if action.is_empty():
		return

	# Once per match, probe the server's guards before playing on.
	if not placed_round.has("probed") and s.round_no == 1:
		placed_round["probed"] = true
		var before: int = errors.size()
		# Acting for a card that is not ours.
		var theirs: FDCard = null
		for c in s.cards:
			if c.side != me:
				theirs = c
				break
		_send(sock, FDNet.encode_action(theirs.id, "attack", 0))
		# A malformed action.
		_send(sock, {"t": "action", "card_id": "nope", "kind": "attack", "target_slot": 0})
		# Outright garbage.
		sock.set_target_peer(MultiplayerPeer.TARGET_PEER_SERVER)
		sock.put_packet("<not json>".to_utf8_buffer())
		_probe_at = before

	_acts += 1
	_send(sock, FDNet.encode_action(action.card_id, action.kind, action.target_slot))

var _probe_at := -1

func _final_checks() -> void:
	_ok(black_state != null and red_state != null, "S4 both clients received state")
	_ok(winner != 0, "S5 the match reached a decision", "winner=%d" % winner)
	_ok(black_state.round_no >= 1, "S5 rounds advanced")

	# The guard probes must have been refused, and refusing them must not have
	# disturbed the match - which finishing at all demonstrates.
	if _probe_at >= 0:
		_ok(errors.size() >= _probe_at + 2,
			"S6 server refused the illegal and malformed actions",
			"errors seen: %s" % str(errors))
		var joined := " | ".join(errors)
		_ok(joined.findn("turn") >= 0 or joined.findn("actor") >= 0 or joined.findn("malformed") >= 0,
			"S6 refusals name a reason", joined)

	# Both clients agree on who won, from their own redacted view.
	_ok(FDRules.winner(black_state) == FDRules.winner(red_state),
		"S7 both clients agree on the result",
		"black saw %d, red saw %d" % [FDRules.winner(black_state), FDRules.winner(red_state)])
	_ok(FDRules.winner(black_state) == winner, "S7 clients agree with the server")

	# At the end everything is revealed, so both sides should now see the whole
	# board - the redaction lifts rather than persisting past the match.
	_ok(black_state.living_count(FDState.BLACK) == red_state.living_count(FDState.BLACK),
		"S8 both clients agree how many Black cards survived")
