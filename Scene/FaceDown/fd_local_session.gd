extends FDSession
class_name FDLocalSession

# Single player. Holds the authoritative FDState in-process and plays the AI
# opponent against it.
#
# This is the behaviour fd_table.gd used to implement itself, moved wholesale so
# that the board has exactly one way of running a match. Nothing here is new -
# the AI delay, the blind placement, the round transition - it has only stopped
# being tangled up with the rendering.

# Long enough to read the log line the AI just wrote (PRD §10).
const AI_DELAY: float = 0.7

var rng := RandomNumberGenerator.new()

var _ai_queued: bool = false
var _ai_wait: float = 0.0

func start() -> void:
	rng.randomize()
	my_side = GameState.player_suit
	state = FDRules.new_match(my_side)
	_place_ai()
	synced.emit([])

func is_waiting() -> bool:
	return _ai_queued

func waiting_text() -> String:
	return "Enemy is choosing…"

func submit_placement(row: Array) -> void:
	var res: Dictionary = FDRules.commit_placement(state, my_side, row)
	if not res.ok:
		notice.emit(res.error)
		return
	synced.emit([])
	_queue_ai_if_theirs()

func submit_action(card_id: int, kind: String, target_slot: int) -> void:
	if not is_my_turn():
		return
	var res: Dictionary = FDRules.resolve(state, my_side, {
		"card_id": card_id, "kind": kind, "target_slot": target_slot,
	})
	if not res.ok:
		notice.emit(res.error)
		return
	_advance(res.events)

func _process(delta: float) -> void:
	if not _ai_queued:
		return
	_ai_wait -= delta
	if _ai_wait > 0.0:
		return
	_ai_queued = false
	_ai_step()

# ── Internals ─────────────────────────────────────────────────────────────

# The AI commits blind, before the player arranges - it never sees the draft.
func _place_ai() -> void:
	var res: Dictionary = FDRules.commit_placement(
		state, enemy_side(), FDRules.auto_place(state, enemy_side(), rng))
	if not res.ok:
		push_error("face-down: AI placement rejected — %s" % res.error)

func _advance(events: Array) -> void:
	match FDRules.advance(state):
		"game_over":
			synced.emit(events)
			finished.emit(FDRules.winner(state))
		"round_end":
			# advance() has already run begin_round(), so the board is back in
			# POSITIONING with both rows cleared; the AI re-commits immediately
			# and the player is asked to arrange again.
			_place_ai()
			synced.emit(events)
		_:
			synced.emit(events)
			_queue_ai_if_theirs()

func _queue_ai_if_theirs() -> void:
	if state.phase == FDState.Phase.BATTLE and state.side_to_act == enemy_side():
		_ai_queued = true
		_ai_wait = AI_DELAY

func _ai_step() -> void:
	if state.phase != FDState.Phase.BATTLE or state.side_to_act != enemy_side():
		synced.emit([])
		return
	var action: Dictionary = _ai_choose()
	if action.is_empty():
		# The engine says this side still has an un-acted card, so this should
		# be unreachable; skipping the turn beats hanging the board on it.
		push_error("face-down: AI produced no action")
		_advance([])
		return
	var res: Dictionary = FDRules.resolve(state, enemy_side(), action)
	if not res.ok:
		push_error("face-down: AI action rejected — %s" % res.error)
		_advance([])
		return
	_advance(res.events)

func _ai_choose() -> Dictionary:
	match GameState.difficulty:
		GameState.Difficulty.EASY:
			return FDLadderAI.choose_action(state, enemy_side(), rng)
		GameState.Difficulty.HARD:
			return FDHardAI.choose_action(state, enemy_side(), rng)
	return FDAI.choose_action(state, enemy_side(), rng)
