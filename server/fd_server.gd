extends SceneTree

# Authoritative match server for face-down mode.
#
#   godot --headless --path RemiShowdown --script res://server/fd_server.gd
#   godot --headless --path RemiShowdown --script res://server/fd_server.gd -- port=8910
#
# It is a normal Godot build with no window, so the same binary that runs the
# game runs the server, and it executes the SAME FDRules the client does. There
# is no second implementation of the rules to drift out of sync.
#
# WHAT IT GUARANTEES
#   * The only real FDState lives here. Clients hold redacted copies and cannot
#     see an unrevealed enemy row (FDNet.snapshot, proven in test/test_fd_net.gd).
#   * Every move is re-validated here by FDRules.resolve(), which already
#     returns {ok, error}. A client that lies about whose turn it is, or about
#     a card it does not own, is rejected and told why.
#   * A packet is untrusted input. Shape is checked by FDNet.valid_*, legality
#     by the rules, and anything malformed is dropped without disturbing the
#     match.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   No accounts, no persistence, no matchmaking. A room is a four-letter code
#   held in memory. If the process restarts, matches are gone - which is the
#   right trade for a game you play with friends, and keeps the server a single
#   file with no database.

const DEFAULT_PORT := 8910

# Rooms are addressed by a code a human reads aloud, so the alphabet excludes
# characters that get confused when spoken or typed: no O/0, I/1, S/5.
const CODE_ALPHABET := "ABCDEFGHJKLMNPQRTUVWXY2346789"
const CODE_LEN := 4

# A seat is held this long after its player drops, so a phone that loses Wi-Fi
# for a moment can rejoin the match rather than forfeit it.
const SEAT_HOLD_SECONDS := 180.0

# Bounds on untrusted input, so one peer cannot exhaust the server.
const MAX_ROOMS := 200
const MAX_PACKET_BYTES := 16384

var _peer: WebSocketMultiplayerPeer
var _rooms := {}        # code -> Room
var _by_peer := {}      # peer_id -> {"code": String, "side": int}
var _rng := RandomNumberGenerator.new()
var _uptime := 0.0

class Seat:
	var peer_id: int = 0
	var token: String = ""
	var dropped_at: float = -1.0

class Room:
	var code: String = ""
	var state: FDState = null
	var seats := {}          # side -> Seat
	var created_at: float = 0.0

	func occupied() -> int:
		var n := 0
		for side in seats:
			if seats[side] != null:
				n += 1
		return n

	func side_of_peer(pid: int) -> int:
		for side in seats:
			if seats[side] != null and seats[side].peer_id == pid:
				return int(side)
		return 0

func _initialize() -> void:
	_rng.randomize()
	var port := DEFAULT_PORT
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("port="):
			port = int(str(a).substr(5))

	_peer = WebSocketMultiplayerPeer.new()
	var err := _peer.create_server(port)
	if err != OK:
		push_error("fd_server: could not bind port %d (error %d)" % [port, err])
		quit(1)
		return
	_peer.peer_connected.connect(_on_connected)
	_peer.peer_disconnected.connect(_on_disconnected)
	print("fd_server: listening on %d  (protocol v%d)" % [port, FDNet.PROTOCOL_VERSION])

func _process(delta: float) -> bool:
	_uptime += delta
	_peer.poll()
	while _peer.get_available_packet_count() > 0:
		var from: int = _peer.get_packet_peer()
		var buf: PackedByteArray = _peer.get_packet()
		if buf.size() > MAX_PACKET_BYTES:
			_send(from, {"t": "error", "msg": "packet too large"})
			continue
		_handle(from, FDNet.from_bytes(buf))
	_expire_seats()
	return false

# ── Connection lifecycle ──────────────────────────────────────────────────

func _on_connected(id: int) -> void:
	print("fd_server: peer %d connected" % id)

func _on_disconnected(id: int) -> void:
	print("fd_server: peer %d disconnected" % id)
	var at = _by_peer.get(id)
	_by_peer.erase(id)
	if at == null:
		return
	var room: Room = _rooms.get(at.code)
	if room == null:
		return
	var seat: Seat = room.seats.get(at.side)
	if seat != null and seat.peer_id == id:
		# The seat is HELD, not freed: a dropped phone should be able to walk
		# back into the same match with the same token.
		seat.peer_id = 0
		seat.dropped_at = _uptime
	_broadcast(room, {"t": "peer", "event": "left", "side": at.side})

# A room whose seats have all been empty for long enough is collected, so an
# abandoned match does not pin memory for the life of the process.
func _expire_seats() -> void:
	var doomed: Array = []
	for code in _rooms:
		var room: Room = _rooms[code]
		var live := 0
		var held := 0
		for side in room.seats:
			var seat: Seat = room.seats[side]
			if seat == null:
				continue
			if seat.peer_id != 0:
				live += 1
			elif _uptime - seat.dropped_at < SEAT_HOLD_SECONDS:
				held += 1
		if live == 0 and held == 0 and _uptime - room.created_at > 5.0:
			doomed.append(code)
	for code in doomed:
		_rooms.erase(code)
		print("fd_server: room %s collected" % code)

# ── Message dispatch ──────────────────────────────────────────────────────

func _handle(from: int, msg: Dictionary) -> void:
	if msg.is_empty():
		return
	match str(msg.get("t", "")):
		"create":
			_do_create(from, _prefer_of(msg))
		"join":
			_do_join(from, str(msg.get("code", "")).to_upper(),
				str(msg.get("token", "")), _prefer_of(msg))
		"place":
			_do_place(from, msg)
		"action":
			_do_action(from, msg)
		"leave":
			_do_leave(from)
		_:
			_send(from, {"t": "error", "msg": "unknown message"})

# The suit a client would LIKE. 0 means no preference. Untrusted input, so
# anything that is not a valid side is treated as no preference rather than
# being allowed to name a seat that does not exist.
func _prefer_of(msg: Dictionary) -> int:
	var want: int = int(msg.get("prefer", 0))
	return want if want == FDState.BLACK or want == FDState.RED else 0

func _do_create(from: int, prefer: int = 0) -> void:
	if _rooms.size() >= MAX_ROOMS:
		_send(from, {"t": "error", "msg": "server is full, try again shortly"})
		return
	_release(from)

	var room := Room.new()
	room.code = _new_code()
	room.created_at = _uptime
	# The creator gets whichever suit they asked for - they are first, so there
	# is nothing to arbitrate yet. Black still leads round 1, which is a measured
	# ~14 point DISADVANTAGE (see the README), so this is not a favour.
	var mine: int = prefer if prefer != 0 else FDState.BLACK
	var other: int = FDState.RED if mine == FDState.BLACK else FDState.BLACK
	room.seats[mine] = _new_seat(from)
	room.seats[other] = null
	_rooms[room.code] = room
	_by_peer[from] = {"code": room.code, "side": mine}

	_send(from, {
		"t": "room", "code": room.code, "side": mine,
		"token": room.seats[mine].token, "v": FDNet.PROTOCOL_VERSION,
		"got_preference": prefer == 0 or prefer == mine,
	})
	print("fd_server: room %s created by peer %d" % [room.code, from])

func _do_join(from: int, code: String, token: String, prefer: int = 0) -> void:
	var room: Room = _rooms.get(code)
	if room == null:
		_send(from, {"t": "error", "msg": "no room with that code"})
		return

	# A rejoin: the token proves this is the same player returning to a seat
	# that is being held for them.
	for side in room.seats:
		var seat: Seat = room.seats[side]
		if seat != null and token != "" and seat.token == token:
			seat.peer_id = from
			seat.dropped_at = -1.0
			_by_peer[from] = {"code": code, "side": int(side)}
			_send(from, {"t": "room", "code": code, "side": int(side),
				"token": token, "v": FDNet.PROTOCOL_VERSION, "rejoined": true})
			_broadcast(room, {"t": "peer", "event": "rejoined", "side": int(side)})
			_sync(room, [])
			print("fd_server: peer %d rejoined room %s" % [from, code])
			return

	# A seat is only free if nobody has ever taken it, or if the player who had
	# it dropped and their hold has since lapsed. A seat that is merely BEING
	# HELD is not free: treating peer_id == 0 as vacant let anyone who guessed
	# the room code walk into a dropped player's seat mid-match, which made the
	# hold - and the token - meaningless.
	# Which seats are actually available. A seat that is merely BEING HELD for a
	# dropped player is not one of them.
	var open_sides: Array = []
	var held := false
	for side in room.seats:
		var seat: Seat = room.seats[side]
		if seat == null:
			open_sides.append(int(side))
		elif seat.peer_id == 0:
			if _uptime - seat.dropped_at >= SEAT_HOLD_SECONDS:
				open_sides.append(int(side))
			else:
				held = true

	# Both players choose a suit independently, so they will sometimes choose
	# the same one. First in keeps it; the second is given the other rather than
	# being refused - a lost coin toss beats being bounced back to the lobby.
	var free_side := 0
	if prefer != 0 and prefer in open_sides:
		free_side = prefer
	elif not open_sides.is_empty():
		free_side = int(open_sides[0])
	if free_side == 0:
		if held:
			_send(from, {"t": "error",
				"msg": "that seat is held for a player who dropped - rejoin with your token"})
		else:
			_send(from, {"t": "error", "msg": "that room is full"})
		return

	_release(from)
	room.seats[free_side] = _new_seat(from)
	_by_peer[from] = {"code": code, "side": free_side}
	_send(from, {
		"t": "room", "code": code, "side": free_side,
		"token": room.seats[free_side].token, "v": FDNet.PROTOCOL_VERSION,
		# The client says which suit it asked for; this says whether it got it,
		# so the board can mention the swap instead of silently changing colour.
		"got_preference": prefer == 0 or prefer == free_side,
	})
	_broadcast(room, {"t": "peer", "event": "joined", "side": free_side})
	print("fd_server: peer %d joined room %s as side %d" % [from, code, free_side])

	if room.occupied() == 2 and room.state == null:
		room.state = FDRules.new_match(FDState.BLACK)
		print("fd_server: room %s match begins" % code)
		_sync(room, [])

func _do_place(from: int, msg: Dictionary) -> void:
	var ctx := _context(from)
	if ctx.is_empty():
		return
	var room: Room = ctx.room
	var side: int = ctx.side
	if room.state == null:
		_send(from, {"t": "error", "msg": "the match has not started"})
		return
	if not FDNet.valid_placement(msg):
		_send(from, {"t": "error", "msg": "malformed placement"})
		return

	var row: Array = []
	for v in msg.get("slots", []):
		row.append(int(v))

	# The rules own the verdict: commit_placement checks length, ownership,
	# duplicates and that no living card was benched.
	var res: Dictionary = FDRules.commit_placement(room.state, side, row)
	if not res.ok:
		_send(from, {"t": "error", "msg": res.error})
		return
	# Each side is told the other has committed, but never WHAT was committed -
	# that only ever leaves here through a redacted snapshot.
	_broadcast(room, {"t": "peer", "event": "placed", "side": side})
	_sync(room, [])

func _do_action(from: int, msg: Dictionary) -> void:
	var ctx := _context(from)
	if ctx.is_empty():
		return
	var room: Room = ctx.room
	var side: int = ctx.side
	if room.state == null:
		_send(from, {"t": "error", "msg": "the match has not started"})
		return
	if not FDNet.valid_action(msg):
		_send(from, {"t": "error", "msg": "malformed action"})
		return
	# Turn order is checked here rather than left to the rules, so a client
	# cannot act out of turn even if the action would otherwise be legal.
	if room.state.side_to_act != side:
		_send(from, {"t": "error", "msg": "not your turn"})
		return

	var res: Dictionary = FDRules.resolve(room.state, side, FDNet.action_from(msg))
	if not res.ok:
		_send(from, {"t": "error", "msg": res.error})
		return

	var events: Array = res.events
	match FDRules.advance(room.state):
		"game_over":
			_sync(room, events)
			_broadcast(room, {"t": "over", "winner": FDRules.winner(room.state)})
		_:
			# "round_end" needs no special handling: advance() has already run
			# begin_round(), so the state is back in POSITIONING and both
			# clients will be asked to place again by the snapshot itself.
			_sync(room, events)

func _do_leave(from: int) -> void:
	_release(from)
	_send(from, {"t": "left"})

# ── Helpers ───────────────────────────────────────────────────────────────

# The room and side this peer is entitled to act for, or {} after telling them
# why not.
func _context(from: int) -> Dictionary:
	var at = _by_peer.get(from)
	if at == null:
		_send(from, {"t": "error", "msg": "you are not in a room"})
		return {}
	var room: Room = _rooms.get(at.code)
	if room == null:
		_send(from, {"t": "error", "msg": "that room is gone"})
		return {}
	if room.side_of_peer(from) != at.side:
		_send(from, {"t": "error", "msg": "seat mismatch"})
		return {}
	return {"room": room, "side": int(at.side)}

# Every client gets its OWN snapshot, built for its own side. There is no
# broadcast path for state, by construction - that is what stops a redaction
# bug from becoming a leak to the other player.
func _sync(room: Room, events: Array) -> void:
	if room.state == null:
		return
	for side in room.seats:
		var seat: Seat = room.seats[side]
		if seat == null or seat.peer_id == 0:
			continue
		var snap: Dictionary = FDNet.snapshot(room.state, int(side))
		# Redacted per viewer, exactly like the snapshot. Broadcasting the raw
		# array put every card id on both wires and undid the snapshot's work.
		snap["events"] = FDNet.redact_events(room.state, events, int(side))
		_send(seat.peer_id, snap)

func _broadcast(room: Room, msg: Dictionary) -> void:
	for side in room.seats:
		var seat: Seat = room.seats[side]
		if seat != null and seat.peer_id != 0:
			_send(seat.peer_id, msg)

func _send(to: int, msg: Dictionary) -> void:
	if to <= 0:
		return
	_peer.set_target_peer(to)
	_peer.put_packet(FDNet.to_bytes(msg))

func _release(from: int) -> void:
	var at = _by_peer.get(from)
	if at == null:
		return
	_by_peer.erase(from)
	var room: Room = _rooms.get(at.code)
	if room == null:
		return
	var seat: Seat = room.seats.get(at.side)
	if seat != null and seat.peer_id == from:
		room.seats[at.side] = null
	_broadcast(room, {"t": "peer", "event": "left", "side": at.side})

func _new_seat(pid: int) -> Seat:
	var s := Seat.new()
	s.peer_id = pid
	s.token = "%08x%08x" % [_rng.randi(), _rng.randi()]
	return s

func _new_code() -> String:
	for attempt in range(64):
		var code := ""
		for i in range(CODE_LEN):
			code += CODE_ALPHABET[_rng.randi_range(0, CODE_ALPHABET.length() - 1)]
		if not _rooms.has(code):
			return code
	# Astronomically unlikely with 29^4 codes and a 200-room cap, but a
	# collision loop that can spin forever is worse than a long code.
	return "%s%d" % [CODE_ALPHABET[_rng.randi_range(0, 28)], _rng.randi() % 100000]
