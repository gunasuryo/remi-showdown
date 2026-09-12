extends SceneTree

# Face-up BOARD smoke test: drives the real table_2 scene, headless.
#
#   godot --headless --path RemiShowdown --script res://test/test_fu_board.gd
#
# FURules is covered by test/run_tests.gd without any scene at all. What this
# covers is the seam the rules engine left behind - that the board's node wiring
# still matches the engine.
#
# It plays three passes:
#
#   "ai"    both sides driven by the board's own AI. Setting player_suit to a
#           value that is neither Black nor Red is what does it: _offer_turn()
#           then never recognises a human turn.
#   "human" Black is played through the BUTTON HANDLERS - _on_attack(),
#           _on_skill() and _on_target() - exactly as a tapping player reaches
#           them. That path has no other coverage anywhere, and it is where the
#           target picker, the armed King's two-step pick and the single-lane
#           auto-resolve all live.
#   "anim"  the same AI-vs-AI match with the ANIMATION LAYER ON. The other two
#           passes clear table.animate, which makes every FUStage coroutine
#           return without awaiting - so they never touch the code the shipping
#           game actually runs. This pass does, at Engine.time_scale, and what
#           it is really checking is that the await chain always reaches
#           _offer_turn() again. An animation that never finishes is a board
#           that never takes another input, and it would look exactly like a
#           hang rather than like a bug.

# The colour tags FUCard.log_name() wraps a card name in. Used to spot a log
# line that names a card the player should not have been told about.
const BLACK_TAG: String = "[color=#dddddd]"
const RED_TAG: String = "[color=#ff8888]"

const MATCHES: int = 12
# The animated pass is slow even wound forward, so it runs few matches.
const ANIM_MATCHES: int = 3
const ANIM_TIME_SCALE: float = 60.0
const GUARD: int = 6000

# The main-loop script of a --script run is compiled BEFORE the autoloads are
# registered, so `GameState` is not a resolvable identifier here the way it is
# inside table2.gd. The node itself exists by the time _initialize runs.
var game_state: Node = null

var passes: Array = ["ai", "human", "anim"]
var mode: String = "ai"

var table: Node = null
var runs: int = 0
var steps: int = 0
var failures: Array = []
var wins := {}
var log_lines: int = 0
var human_actions := {}
var human_turns: int = 0
var cancels: int = 0
var skips: int = 0

func _initialize() -> void:
	game_state = root.get_node("/root/GameState")
	game_state.difficulty = 1   # NORMAL: the scorer, which is what ships
	mode = str(passes.pop_front())
	_enter_mode()
	_new_match()

func _matches() -> int:
	return ANIM_MATCHES if mode == "anim" else MATCHES

# Winding the clock forward rather than shortening the timings: the point is to
# exercise the real durations, and a tween honours time_scale.
func _enter_mode() -> void:
	Engine.time_scale = ANIM_TIME_SCALE if mode == "anim" else 1.0

func _new_match() -> void:
	if table != null and is_instance_valid(table):
		root.remove_child(table)
		table.free()
	game_state.player_suit = FUState.BLACK
	steps = 0
	table = load("res://Scene/Table/table_2.tscn").instantiate()
	# Set BEFORE add_child: _ready() builds the stage and reads this.
	table.animate = (mode == "anim")
	root.add_child(table)
	if mode == "ai" or mode == "anim":
		# Neither colour is the player, so the board drives both sides itself.
		table.player_suit = 0
		table._offer_turn()
		return
	# Black's King opens already armed. Reaching this state by playing for it
	# does not work reliably: the King self-rallies happily enough, but it sits
	# at slot 3 and is usually dead before its next turn comes round, so across
	# twelve matches the two-step picker was never once entered. An armed King
	# is a legal state, and starting in it is the only way to exercise the most
	# intricate path on the human side of the board.
	table.state.find_by_name(FUState.BLACK, "King").double_rally = true

func _fail(msg: String) -> void:
	failures.append("%s match %d: %s" % [mode, runs, msg])

func _process(_delta: float) -> bool:
	if table == null or not is_instance_valid(table):
		return true

	# Collapse the readability delay on the AI's turns.
	if table.aiWaiting:
		table.aiTimer = 0.0

	steps += 1
	if steps > GUARD:
		_fail("did not finish in %d frames" % GUARD)
		return _next()

	var s: FUState = table.state
	if s == null:
		_fail("board has no state")
		return _next()

	# Invariant, checked every frame: the board's view table and the engine's
	# board must agree about who is standing. A living card with no node would
	# be invisible; a freed node still bound would crash the next render.
	for c in s.cards:
		var bound: bool = table._views.has(c.id)
		if c.alive and not bound:
			_fail("living %s has no card node" % c.card_name)
			return _next()
		if bound and not is_instance_valid(table._views[c.id]):
			_fail("%s is bound to a freed node" % c.card_name)
			return _next()

	if not s.is_over():
		# Never reach in while the board is mid-animation: that is the state a
		# real player is locked out of, so the test has to respect it too.
		if table._busy:
			# ...except to do the one thing a player CAN do mid-animation.
			# Every other match of the animated pass hammers skip, because the
			# failure it guards against is specific and silent: Tween.kill()
			# never emits `finished`, so a skip implemented that way leaves the
			# await chain blocked for good and the board simply never accepts
			# another input. That reads as a hang, not as a bug, and the
			# unskipped matches either side of it would still pass.
			if mode == "anim" and runs % 2 == 1:
				table._stage.skip()
				skips += 1
			return false
		if mode == "human" and s.current_suit == table.player_suit:
			_play_human_turn(s)
		return false

	return _check_result(s)

# ── The human path ────────────────────────────────────────────────────────

# Reaches a move the way a player does: press Attack or Skill, then press a
# target button. Nothing here calls FURules directly, so a broken picker shows
# up as a match that never ends.
#
# Every other turn is forced onto the SKILL path rather than taking the
# scorer's pick. Left to itself the scorer attacks about 98% of the time, which
# left the target picker at three presses across twelve matches and the armed
# King's two-step pick at none - and that two-step is the most intricate thing
# on the human side of the board.
func _play_human_turn(s: FUState) -> void:
	human_turns += 1
	var want: Dictionary = FUAI.choose(s)
	var forced := _force_skill(s)
	# An armed King always spends the arm, whatever the parity. Black's King
	# acts once every five turns, so leaving it to the coin flip meant it kept
	# arming on an odd turn and then attacking on the even one that followed -
	# the two-step picker went unexercised entirely.
	if not forced.is_empty() and (human_turns % 2 == 1 or forced.kind == "double_rally"):
		want = forced
	if want.is_empty():
		_fail("the scorer offered the player nothing to do")
		return
	human_actions[want.kind] = int(human_actions.get(want.kind, 0)) + 1

	match want.kind:
		"attack":
			table._on_attack(0)
			# One reachable lane resolves on the spot; more than one opens the
			# picker. Both are correct, so only a stuck board is a failure.
			if not table._pending.is_empty():
				_press(int(want.target_slot))
		"skill":
			table._on_skill()
			if table._pending.is_empty():
				_fail("Skill offered no targets for %s" % s.current_card().card_name)
				return
			# Every third skill is opened, backed out of, and then taken for
			# real. A cancel that quietly spent the turn would be the worst kind
			# of bug to ship - a misclick costing a move - and it would not show
			# up as a crash or a stall, only as a match that went badly.
			if human_turns % 3 == 0:
				_cancel_and_reopen(s)
				if table._pending.is_empty():
					return
			_press(int(want.target_slot))
		"double_rally":
			table._on_skill()
			if table._pending.is_empty():
				_fail("an armed King offered no rally targets")
				return
			_press(int(want.target_slots[0]))
			if table._pending.is_empty():
				_fail("the King second pick never opened")
				return
			# _best_rally_pair may name only one ally; the picker still wants
			# two presses, so the second falls through to whatever is lit.
			_press(int(want.target_slots[1]) if want.target_slots.size() > 1 else -1)

# Backs out of the open target picker and checks the turn survived it, then
# opens the picker again so the caller can go through with the move.
func _cancel_and_reopen(s: FUState) -> void:
	var actor_before: int = s.current_id
	var round_before: int = s.round_no
	table._cancel_targeting()
	cancels += 1

	if not table._pending.is_empty():
		_fail("cancel left the target picker open")
		return
	if s.current_id != actor_before:
		_fail("cancel spent the turn - the actor moved on")
		return
	if s.round_no != round_before:
		_fail("cancel advanced the round")
		return
	if table._double_first != -1:
		_fail("cancel left a half-finished King pick behind")
		return

	# ...and the same action must still be available afterwards.
	table._on_skill()
	if table._pending.is_empty():
		_fail("the skill could not be re-opened after a cancel")

# A skill for this card if it has one, chosen to walk the King through arming a
# double rally and then spending it. Empty when the card has no skill to use.
func _force_skill(s: FUState) -> Dictionary:
	var actor := s.current_card()
	if actor == null or not actor.may_attempt_skill() or s.enemies_of(actor.side).is_empty():
		return {}
	var allies := s.allies_of(actor.side)
	if actor.card_name == "King":
		if actor.double_rally:
			var pair: Array = []
			for i in range(allies.size()):
				if allies[i].id != actor.id:
					pair.append(i)
				if pair.size() == 2:
					break
			return {"kind": "double_rally", "target_slots": pair} if not pair.is_empty() else {}
		# Self-rally: arms the double rally, so the two-step picker gets used
		# on this King's next turn.
		return {"kind": "skill", "target_slot": s.slot_of(actor)}
	return {"kind": "skill", "target_slot": 0}

# Presses the target button standing for `slot`, or any lit one when that slot
# is not on offer.
func _press(slot: int) -> void:
	var chosen = null
	for node in table._pending:
		if chosen == null:
			chosen = node
		if int(table._pending[node].get("target_slot", -1)) == slot:
			chosen = node
			break
	if chosen == null:
		_fail("no target button was lit")
		return
	if not chosen.targetBtnVisible:
		_fail("an armed action target button was never shown")
	table._on_target(chosen)

# ── Result ────────────────────────────────────────────────────────────────

func _check_result(s: FUState) -> bool:
	# The board result line must be the one the engine decided on.
	var expected: String = FURules.winner_text(FURules.winner(s))
	if table.winner_msg != expected:
		_fail("board says %s, engine says %s" % [table.winner_msg, expected])
	if not table.get_node("UI/Root/WinLabel").visible:
		_fail("the win label was never shown")

	# BattleLog's own line array is the whole match. Neither RichTextLabel
	# property is: `text` is never written back to by append_text() (the quirk
	# BattleLog exists to work around), and get_parsed_text() returns only what
	# has actually been laid out, which headless keeps to a screenful.
	var lines: PackedStringArray = table._battleLog._lines
	var whole: String = "|".join(lines)
	if not whole.contains(expected):
		_fail("the result never reached the battle log")
	# _submit() logs this whenever the board hands FURules an action it rejects,
	# which is the one thing a presentation layer must never manage to do.
	if whole.contains("refused:"):
		_fail("the board built an action the rules rejected")

	# ── The log must not leak what the board hides ──────────────────────
	#
	# Hiding a shield on the board while the log spells out "Red Ace shields Red
	# Queen" conceals nothing, and it is the exact failure face-down had to fix
	# twice. Card names carry their side's colour, so a leak is checkable: the
	# player is Black, so an application line naming a RED card is an enemy buff
	# the player was never entitled to, and a "tricks" line naming a BLACK card
	# is a trap being set on the player in full view.
	if mode == "human":
		for verb in ["shields ", "rallies "]:
			if whole.contains(verb + RED_TAG):
				_fail("the log leaked an enemy %s" % verb.strip_edges())
		if whole.contains("tricks " + BLACK_TAG):
			_fail("the log leaked a trick being set on the player")
	# ...and the BBCode has to actually parse, rather than reaching the player
	# as visible tags.
	if table.get_node(table.LOG_PATH).get_parsed_text().contains("[color="):
		_fail("BBCode reached the label unparsed")
	log_lines = maxi(log_lines, lines.size())
	wins[expected] = int(wins.get(expected, 0)) + 1
	return _next()

func _next() -> bool:
	runs += 1
	if runs >= _matches():
		print("  %-5s pass: %d matches, %s" % [mode, _matches(), str(wins)])
		if mode == "human":
			print("         reached through the buttons: %s" % str(human_actions))
			print("         target picks backed out of and retaken: %d" % cancels)
		if mode == "anim":
			print("         animations fast-forwarded: %d" % skips)
		runs = 0
		wins = {}
		if passes.is_empty():
			return _finish()
		mode = str(passes.pop_front())
		_enter_mode()
	_new_match()
	return false

# ── Redaction ─────────────────────────────────────────────────────────────

# Feeds table2._log_event() one hand-built event at a time and reads back what
# reached the battle log.
#
# This is deliberately NOT left to a played match. It was, at first, and it
# proved nothing: the guard was a string search over whatever the AI happened to
# do, the scorer rarely reaches for a shield or a rally, and breaking the
# redaction outright still produced a clean run. A leak test that cannot fail is
# worse than no leak test, because it reads like coverage.
func _check_redaction() -> void:
	var t = load("res://Scene/Table/table_2.tscn").instantiate()
	t.animate = false
	root.add_child(t)
	t.player_suit = FUState.BLACK
	var s: FUState = t.state

	var red_queen := s.find_by_name(FUState.RED, "Queen")
	var red_ace := s.find_by_name(FUState.RED, "Ace")
	var red_king := s.find_by_name(FUState.RED, "King")
	var red_joker := s.find_by_name(FUState.RED, "Joker")
	var black_jack := s.find_by_name(FUState.BLACK, "Jack")
	var black_ace := s.find_by_name(FUState.BLACK, "Ace")
	var black_queen := s.find_by_name(FUState.BLACK, "Queen")

	# ── Must be hidden ──────────────────────────────────────────────────
	red_queen.shield = 30
	red_queen.shield_seen = false
	_redact(t, {"t": "shield", "actor": red_ace.id, "target": red_queen.id, "amount": 30},
		false, "an enemy shield")

	red_ace.rallied = true
	red_ace.rally_seen = false
	_redact(t, {"t": "rally", "actor": red_king.id, "target": red_ace.id},
		false, "an enemy rally")

	black_jack.tricked = true
	black_jack.trick_seen = false
	_redact(t, {"t": "trick", "actor": red_joker.id, "target": black_jack.id},
		false, "a trick set on the player")

	# An enemy skill whose effect is hidden is named but not explained.
	var header := _fed(t, {"t": "skill", "actor": red_ace.id, "name": "Ace",
		"slot": 0, "lanes": [0], "spread": false})
	if header == "":
		_fail("an enemy skill went completely unlogged")
	elif header.contains("Queen") or header.contains("slot"):
		_fail("the redacted skill header named its target: %s" % header)

	# ── Must be shown ───────────────────────────────────────────────────
	_redact(t, {"t": "shield", "actor": black_ace.id, "target": black_queen.id, "amount": 30},
		true, "the player's own shield")
	_redact(t, {"t": "trick", "actor": s.find_by_name(FUState.BLACK, "Joker").id,
		"target": red_queen.id}, true, "a trick the player set")

	# ...and once it is public, the same enemy shield is reported like any other.
	red_queen.shield_seen = true
	_redact(t, {"t": "shield", "actor": red_ace.id, "target": red_queen.id, "amount": 30},
		true, "an enemy shield after it was revealed")

	# A reveal is always public - it is the moment the secret stops being one.
	_redact(t, {"t": "reveal", "card": red_queen.id, "what": "shield"},
		true, "a reveal")

	# ── Statuses ENDING leak just as readily as statuses starting ───────
	#
	# "the trick on your Jack lifted" tells the player there was a trick on
	# their Jack. A trap described in the past tense is still the trap given
	# away, and it is the easiest of these to write by accident, because the
	# rules emit the lift whether or not anyone was ever entitled to see it.
	_redact(t, {"t": "trick_lifted", "card": black_jack.id, "by": red_joker.id,
		"was_seen": false, "reason": "acted"}, false, "a trap lifting off the player")
	_redact(t, {"t": "trick_lifted", "card": black_jack.id, "by": red_joker.id,
		"was_seen": true, "reason": "died"}, true, "a trap that had already sprung")
	_redact(t, {"t": "trick_lifted", "card": red_queen.id,
		"by": s.find_by_name(FUState.BLACK, "Joker").id,
		"was_seen": false, "reason": "acted"}, true, "the player's own trap lifting")

	# A live rally is only ever made public by being spent, so an enemy one
	# lapsing is a non-event the player was never told about in the first place.
	_redact(t, {"t": "rally_expired", "card": red_ace.id, "by": red_king.id,
		"reason": "acted"}, false, "an enemy rally lapsing")
	_redact(t, {"t": "rally_expired", "card": black_queen.id,
		"by": s.find_by_name(FUState.BLACK, "King").id,
		"reason": "died"}, true, "the player's own rally lapsing")

	# Same for a shield that went up and came down without ever being hit.
	_redact(t, {"t": "shield_expired", "card": s.find_by_name(FUState.RED, "King").id,
		"amount": 30, "by": red_ace.id, "was_seen": false, "reason": "acted"},
		false, "an enemy shield lapsing unseen")

	root.remove_child(t)
	t.free()
	_check_picture_redaction()

# The log is not the only way a secret gets out. A caster rising behind a card
# and a caster PARKED behind a card say the same thing a sentence would, and
# both were written after the log was, so both had to learn the rule separately.
#
# A fresh board: the log checks above leave their state deliberately mangled.
func _check_picture_redaction() -> void:
	var t = load("res://Scene/Table/table_2.tscn").instantiate()
	t.animate = false
	root.add_child(t)
	t.player_suit = FUState.BLACK
	var s: FUState = t.state

	var black_jack := s.find_by_name(FUState.BLACK, "Jack")
	var black_queen := s.find_by_name(FUState.BLACK, "Queen")
	var red_ace := s.find_by_name(FUState.RED, "Ace")
	var red_queen := s.find_by_name(FUState.RED, "Queen")
	var red_king := s.find_by_name(FUState.RED, "King")
	var red_joker := s.find_by_name(FUState.RED, "Joker")
	var black_king := s.find_by_name(FUState.BLACK, "King")
	var black_joker := s.find_by_name(FUState.BLACK, "Joker")

	# ── The animation: is this cast one the player may watch land? ──────
	red_queen.shield = 30
	red_queen.shield_seen = false
	_cast(s, {"t": "shield", "target": red_queen.id}, red_queen.id,
		false, "an enemy shield being cast")
	red_queen.shield_seen = true
	_cast(s, {"t": "shield", "target": red_queen.id}, red_queen.id,
		true, "an enemy shield already public")

	red_ace.rallied = true
	red_ace.rally_seen = false
	_cast(s, {"t": "rally", "target": red_ace.id}, red_ace.id,
		false, "an enemy rally being cast")

	black_jack.tricked = true
	black_jack.trick_seen = false
	black_jack.trick_joker = red_joker.id
	_cast(s, {"t": "trick", "target": black_jack.id}, black_jack.id,
		false, "a trap being set on the player")

	red_queen.tricked = true
	red_queen.trick_seen = false
	red_queen.trick_joker = black_joker.id
	_cast(s, {"t": "trick", "target": red_queen.id}, red_queen.id,
		true, "the player's own trap being set")

	# ── The marker: who is parked behind whom ───────────────────────────
	black_queen.rallied = true
	black_queen.rally_seen = false
	black_queen.rally_king = black_king.id
	t._sync_cards()

	_marker(t, black_jack, false, "a Joker behind the player's own trapped card")
	_marker(t, red_ace, false, "a King behind a secretly rallied enemy")
	_marker(t, black_queen, true, "a King behind the player's own rallied ally")
	_marker(t, red_queen, true, "a Joker behind an enemy the player trapped")

	# Springing the trap makes it public, and the marker may then stand.
	black_jack.trick_seen = true
	t._sync_cards()
	_marker(t, black_jack, true, "a Joker behind a trap that has sprung")

	# ── The aiming preview is a fourth way to read a hidden shield ──────
	#
	# It quotes what the blow would cost, so pricing it against the REAL shield
	# would turn it into an X-ray: hover a lane, read a smaller number than the
	# card's attack, and you have found the Ace without spending anything. It
	# has to promise the full number and let the blow under-deliver.
	var red_king2 := s.find_by_name(FUState.RED, "King")
	red_king2.shield = 30
	red_king2.shield_seen = false
	s.current_id = s.find_by_name(FUState.BLACK, "Jack").id
	var blind: Array = t._preview_for(red_king2)
	if str(blind[0]) != "-%d" % s.find_by_name(FUState.BLACK, "Jack").skill_value:
		_fail("the preview priced a hidden shield the player has not seen: %s" % str(blind[0]))

	# Once the shield is public the preview may - and should - account for it.
	red_king2.shield_seen = true
	var informed: Array = t._preview_for(red_king2)
	if str(informed[0]) == str(blind[0]):
		_fail("the preview ignored a shield the player HAS seen")

	root.remove_child(t)
	t.free()

func _cast(s: FUState, ev: Dictionary, target_id: int, want_shown: bool, what: String) -> void:
	var shown: bool = FUStage.cast_is_visible(ev, s, FUState.BLACK, target_id)
	if want_shown and not shown:
		_fail("the animation hid %s, which the player may see" % what)
	elif not want_shown and shown:
		_fail("the animation would have SHOWN %s" % what)

func _marker(t, c: FUCard, want_shown: bool, what: String) -> void:
	var node = t._views.get(c.id)
	if node == null or not is_instance_valid(node):
		_fail("no node for %s" % c.card_name)
		return
	if want_shown and not node.has_marker():
		_fail("no marker for %s, which the player may see" % what)
	elif not want_shown and node.has_marker():
		_fail("the board PARKED %s where the player could see it" % what)

# Returns the line `ev` produced, or "" when it was redacted away.
func _fed(t, ev: Dictionary) -> String:
	var before: int = t._battleLog._lines.size()
	t._log_event([ev], 0)
	var lines: PackedStringArray = t._battleLog._lines
	return "" if lines.size() == before else lines[lines.size() - 1]

func _redact(t, ev: Dictionary, want_shown: bool, what: String) -> void:
	var line := _fed(t, ev)
	if want_shown and line == "":
		_fail("the log hid %s, which the player is entitled to see" % what)
	elif not want_shown and line != "":
		_fail("the log LEAKED %s: %s" % [what, line])

func _finish() -> bool:
	Engine.time_scale = 1.0
	_check_redaction()
	print("")
	if failures.is_empty():
		print("FU BOARD OK: table_2.tscn played by AI and through the button handlers, longest log %d lines" % log_lines)
	else:
		print("FU BOARD FAIL:")
		for f in failures:
			print("  ", f)
	quit(1 if not failures.is_empty() else 0)
	return true
