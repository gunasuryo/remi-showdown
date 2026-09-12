extends FDSession
class_name FDRemoteSession

# Online play. Holds no authority at all: it posts actions to the server and
# renders whatever comes back.
#
# `state` here is a REDACTED FDState rebuilt from the server's snapshot. It is a
# real FDState - so the board's existing queries all work - but the enemy row
# carries FDCard.HIDDEN wherever the server withheld it, and enemy cards arrive
# without hp or shield until they are revealed. The client is not trusted with
# the opponent's row and is never sent it.
#
# Nothing here validates a move. The server re-runs FDRules on everything and
# answers with an error the board shows as a notice, which is the only way a
# client's opinion about legality can be made not to matter.

signal room_ready(code: String, side: int)
signal connection_lost()

const RECONNECT_DELAY: float = 2.0
const MAX_RECONNECTS: int = 5

# ── Resync ────────────────────────────────────────────────────────────────
#
# The socket staying up is not the same as the match staying in step. A state
# push that never arrives - dropped, mis-parsed, arriving while the board was
# mid-teardown - used to leave the client waiting for a move it had already been
# sent, with NO way to ask again: every push is a side effect of somebody doing
# something, so if nothing else happened, nothing else ever came.
#
# So the client now notices silence and asks. Two different silences matter, and
# only one of them is obvious:
#
#   * waiting on the opponent - the visible case.
#   * waiting on our OWN move to come back. This is the one that bites, because
#     locally it is still our turn until the sync lands, so anything keyed on
#     "is it my turn" sees nothing wrong at all and waits forever.
#
# A snapshot is absolute, so a resync is a complete repair rather than a patch:
# whatever comes back is the whole truth regardless of how far behind we were.
const RESYNC_SILENCE: float = 6.0     # quiet this long while waiting -> ask
const RESYNC_INTERVAL: float = 4.0    # and no more often than this
const MAX_RESYNCS: int = 6            # before admitting it is not working

var url: String = ""
var code: String = ""
var token: String = ""
# "create" makes a new room; "join" enters `code`.
var intent: String = "create"

var _peer: WebSocketMultiplayerPeer = null
var _greeted: bool = false
var _seated: bool = false
var _opponent_here: bool = false
var _retries: int = 0
var _retry_at: float = -1.0
var _clock: float = 0.0

# Resync bookkeeping.
var _last_seq: int = 0
var _quiet_since: float = 0.0     # when we last heard anything at all
var _asked_at: float = -1.0       # when we last asked for a resync
var _asks: int = 0
# When we sent a move and have not yet seen the board come back. -1 = nothing
# outstanding.
var _awaiting_since: float = -1.0

func start() -> void:
	url = GameState.server_url
	intent = GameState.room_action
	code = GameState.room_code.to_upper()
	token = GameState.seat_token
	_open()

func _open() -> void:
	_greeted = false
	_peer = WebSocketMultiplayerPeer.new()
	var err := _peer.create_client(url)
	if err != OK:
		GameState.last_error = "Could not reach %s" % url
		notice.emit(GameState.last_error)
		connection_lost.emit()

func is_waiting() -> bool:
	if not _seated:
		return true
	if not _opponent_here:
		return true
	return state != null and not is_my_turn()

func waiting_text() -> String:
	if not _seated:
		return "Connecting…"
	if not _opponent_here:
		return "Room  %s   ·   waiting for your friend to join" % code
	if state != null and state.phase == FDState.Phase.POSITIONING:
		return "Waiting for your opponent to lock in…"
	return "Opponent's turn…"

func submit_placement(row: Array) -> void:
	_awaiting_since = _clock
	_send(FDNet.encode_placement(row))

func submit_action(card_id: int, kind: String, target_slot: int) -> void:
	_awaiting_since = _clock
	_send(FDNet.encode_action(card_id, kind, target_slot))

func leave() -> void:
	if _peer != null and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_send({"t": "leave"})
		_peer.close()
	_peer = null

func _process(delta: float) -> void:
	_clock += delta
	if _peer == null:
		if _retry_at > 0.0 and _clock >= _retry_at:
			_retry_at = -1.0
			_open()
		return

	_peer.poll()
	var status := _peer.get_connection_status()

	if status == MultiplayerPeer.CONNECTION_CONNECTED and not _greeted:
		_greeted = true
		_retries = 0
		# A token means we have played here before and are asking for our seat
		# back rather than a new one.
		# GameState.player_suit is the suit picked on the way in. The server
		# treats it as a preference, not a claim - if the other player got there
		# first with the same one, we are given the other.
		if intent == "join" or token != "":
			_send(FDNet.encode_room("join", code, token, GameState.player_suit))
		else:
			_send(FDNet.encode_room("create", "", "", GameState.player_suit))

	while _peer != null and _peer.get_available_packet_count() > 0:
		_quiet_since = _clock
		_receive(FDNet.from_bytes(_peer.get_packet()))

	if status == MultiplayerPeer.CONNECTION_DISCONNECTED and _greeted:
		_dropped()
		return

	_check_resync()

# Notices that nothing has arrived for a while when something should have, and
# asks the server for the board again.
func _check_resync() -> void:
	if not _seated or state == null or _asks >= MAX_RESYNCS:
		return
	# Asking down a socket that is not up would only make _send() complain, once
	# every RESYNC_INTERVAL, for as long as the drop lasted. Reconnecting is
	# _dropped()'s job and it has its own retry budget.
	if _peer == null or _peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	# Something is owed to us if we are waiting on the opponent, or if we sent a
	# move that has not come back. The second is the one a turn check misses.
	var owed: bool = _awaiting_since >= 0.0 or (_opponent_here and is_waiting())
	if not owed:
		return
	if _clock - _quiet_since < RESYNC_SILENCE:
		return
	if _asked_at >= 0.0 and _clock - _asked_at < RESYNC_INTERVAL:
		return

	_asked_at = _clock
	_asks += 1
	if _asks == MAX_RESYNCS:
		notice.emit("Still out of step with the server — try leaving and rejoining.")
	_send({"t": "resync"})

# A dropped socket is not the end of the match: the server holds the seat, and
# the token buys it back. Only give up after several failures.
func _dropped() -> void:
	_peer = null
	_greeted = false
	_seated = false
	# The rejoin brings its own snapshot, so start the sequence over rather than
	# reporting a gap for every push that happened while the socket was down.
	_last_seq = 0
	_asks = 0
	_asked_at = -1.0
	_quiet_since = _clock
	_awaiting_since = -1.0
	if _retries >= MAX_RECONNECTS:
		GameState.last_error = "Lost the connection to the server."
		notice.emit(GameState.last_error)
		connection_lost.emit()
		return
	_retries += 1
	_retry_at = _clock + RECONNECT_DELAY
	notice.emit("Reconnecting… (%d/%d)" % [_retries, MAX_RECONNECTS])

func _receive(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"room":
			code = str(msg.get("code", code))
			token = str(msg.get("token", token))
			my_side = int(msg.get("side", FDState.BLACK))
			_seated = true
			# Remembered so a rejoin after the app is backgrounded still knows
			# which seat to ask for.
			GameState.room_code = code
			GameState.seat_token = token
			GameState.player_suit = my_side
			# To disk, not just to memory: Android kills a backgrounded app
			# whenever it likes, and a token that only lived in RAM died with
			# it - leaving the player locked out of a match still waiting on
			# them. This is the only moment the token is known.
			GameState.save_prefs()
			room_ready.emit(code, my_side)
			if bool(msg.get("rejoined", false)):
				notice.emit("Rejoined room %s" % code)
			elif not bool(msg.get("got_preference", true)):
				notice.emit("Your friend took that suit first — you are %s."
					% ("Black" if my_side == FDState.BLACK else "Red"))

		"state":
			state = FDNet.restore(msg)
			# A state at all means both seats are filled - the server does not
			# start a match otherwise.
			_opponent_here = true

			# Whatever we were owed has arrived.
			_awaiting_since = -1.0
			_asks = 0
			_asked_at = -1.0

			# A sequence gap means a push went missing. The BOARD is fine -
			# snapshots are absolute, so this one supersedes whatever we lost -
			# but the events for the missing step are gone for good, and playing
			# the ones we did get would narrate half a turn. Drop them and let
			# the board redraw from state alone.
			var seq: int = int(msg.get("seq", 0))
			var events: Array = msg.get("events", [])
			var resynced: bool = bool(msg.get("resync", false))
			if seq > 0 and _last_seq > 0 and seq > _last_seq + 1 and not resynced:
				notice.emit("Caught up with the match.")
				events = []
			if seq > 0:
				_last_seq = seq
			# A resync carries no events by design: it is the board, not a story
			# about how it got there.
			synced.emit([] if resynced else events)

		"waiting":
			# Seated, but the match has not begun. Stop asking on a timer.
			_asks = MAX_RESYNCS
			_awaiting_since = -1.0

		"peer":
			match str(msg.get("event", "")):
				"joined":
					_opponent_here = true
					notice.emit("Your opponent joined.")
				"rejoined":
					_opponent_here = true
					notice.emit("Your opponent reconnected.")
				"left":
					_opponent_here = false
					notice.emit("Your opponent dropped — their seat is held.")
				"placed":
					notice.emit("Opponent locked in.")
			synced.emit([])

		"over":
			finished.emit(int(msg.get("winner", 0)))

		"error":
			var text := str(msg.get("msg", "Server refused that."))
			notice.emit(text)
			# An error BEFORE we have a seat is fatal - a bad room code, a full
			# room - and there is nothing to play. Afterwards it is just a
			# rejected move, and the match carries on.
			if not _seated:
				GameState.last_error = text
				connection_lost.emit()

func _send(msg: Dictionary) -> void:
	if _peer == null or _peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		notice.emit("Not connected.")
		return
	_peer.set_target_peer(MultiplayerPeer.TARGET_PEER_SERVER)
	_peer.put_packet(FDNet.to_bytes(msg))
