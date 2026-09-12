extends RefCounted
class_name FURules

# Face-up mode rules engine. PURE RULES — this file must never reference a
# scene, a node or a texture. That is the same hard rule fd_rules.gd follows,
# and it is what lets a whole face-up match run headless in the test suite.
#
# Everything here used to live inside table2.gd, interleaved with node
# manipulation: the rules read HP off a Node2D, wrote the battle log by
# emitting a signal from inside a card scene, and expired a shield by calling
# update_stats() on it. None of that could run without a scene tree, so the
# only way to test a face-up rule was to instantiate the whole board — which is
# why test/bench_faceup.gd loads table_2.tscn once per match and takes minutes
# to do what the face-down bench does in seconds.
#
# The board now observes state and issues actions; it holds no rules.

const BLACK := FUState.BLACK
const RED := FUState.RED
const NONE := FUCard.NONE

# ── Match setup ───────────────────────────────────────────────────────────

# Cards are created in CardStats.ORDER, which is also the opening slot order:
# Ace, Jack, Queen, King, Joker. table_2.tscn lists its card nodes in exactly
# that order, so the board's opening layout is unchanged by the move.
#
# `rng` decides only the coin flip. Face-up mode flips for who acts first
# specifically to avoid the face-down seat imbalance, where Black always leads
# round 1 and pays about 14 points of win rate for it.
static func new_match(player_side: int = BLACK, rng: RandomNumberGenerator = null) -> FUState:
	var state := FUState.new()
	state.player_side = player_side
	for side in [BLACK, RED]:
		for card_name in CardStats.ORDER:
			var c := FUCard.create(state.new_id(), side, card_name)
			state.cards.append(c)
			state.rows[side].append(c.id)
	if rng != null:
		state.first_suit = rng.randi_range(1, 2)
	else:
		var r := RandomNumberGenerator.new()
		r.randomize()
		state.first_suit = r.randi_range(1, 2)
	state.current_suit = state.first_suit
	state.current_slot = 0
	return state

# Opens the first turn. Split out of new_match so a test can pin first_suit
# before the match starts walking the slot order.
static func start(state: FUState) -> Array:
	var events: Array = [{"t": "match_start", "first": state.first_suit}]
	_start_turn(state, events)
	return events

# ── Turn flow ─────────────────────────────────────────────────────────────

# Finds the next card that actually has a turn, and runs the start-of-turn
# expiries on it.
#
# The search exists because the two rows can be different lengths: slot 3 may
# hold a card on one side and nothing on the other, and that half-turn is
# skipped silently rather than stalling the match. The iteration guard is the
# original's and stays: a bug that leaves both rows non-empty but every slot
# unclaimed would otherwise spin forever.
static func _start_turn(state: FUState, events: Array) -> void:
	if _settle_winner(state, events):
		return
	var max_slot := state.max_slot()
	if max_slot == 0:
		_settle_winner(state, events)
		return

	var found := false
	var iterations := 0
	while iterations < (max_slot * 2 + 2):
		iterations += 1
		if state.current_slot >= max_slot:
			state.current_slot = 0
		if state.living_count(state.current_suit) == 0:
			_settle_winner(state, events)
			return
		if state.current_slot < state.living_count(state.current_suit):
			found = true
			break
		_advance_turn(state)
		if state.current_slot >= max_slot:
			state.current_slot = 0

	if not found or state.current_slot >= state.living_count(state.current_suit):
		_settle_winner(state, events)
		return

	var actor := state.card_at(state.current_suit, state.current_slot)
	state.current_id = actor.id

	# NOTHING expires here. Every one of the three statuses is held up by the
	# card that applied it and ends when THAT card acts or dies - see
	# _release_own() and _post_process() - so the turn a status is standing on
	# is its caster's, never its carrier's.
	#
	# The shield used to be wiped right here, at the start of the shielded
	# card's own turn. That made it a one-round buff belonging to nobody: the
	# Ace could not maintain it, could not move it, and had no say in when it
	# ended.
	#
	# A trick has never been touched here, and unlike the old shield it emits
	# NOTHING at all. It used to announce itself at the top of its victim's
	# turn, back when it was a visible debuff. A trap that opens the turn by
	# saying "you are trapped" is not a trap, and that one event would have
	# leaked it into the battle log however carefully the board was redacted.

	events.append({
		"t": "turn", "card": actor.id, "side": actor.side, "slot": state.current_slot,
	})

# Leader then follower at slot 0, leader then follower at slot 1, and so on —
# with the coin flip deciding which colour leads the first round rather than
# Black always being it.
#
# The lead then ALTERNATES every round. Acting second in a lane is worth
# something real: the follower already knows whether the card opposite is still
# standing, and whether it spent its turn on a skill. Handing that to the same
# colour for a whole match is the shape of the face-down seat imbalance, which
# is measured at about 14 points; swapping it each round means the advantage
# changes hands instead of compounding.
static func _advance_turn(state: FUState) -> void:
	if state.current_suit != state.first_suit:
		# The second suit of this slot just acted, so move along the board.
		state.current_slot += 1
		if state.current_slot >= state.max_slot():
			state.current_slot = 0
			state.round_no += 1
			state.first_suit = state.opponent(state.first_suit)
		state.current_suit = state.first_suit
	else:
		state.current_suit = state.opponent(state.first_suit)

# Ends the acting card's turn and opens the next one.
static func _end_turn(state: FUState, events: Array) -> void:
	# A trick is deliberately NOT expired here. It used to be spent by the turn
	# it ruined, which made sense when it ruined one - it halved that turn's
	# attack and took that turn's skill, so a one-turn life was the whole of it.
	#
	# It is a trap now: it waits, silently and without limit, for its victim to
	# reach for a skill. Expiring it on a clock would mean a trick that was
	# answered by doing nothing in particular, and it would also hand the
	# victim's side a way to detect one - a card that "waits out" a turn and
	# finds its skill working again has learned exactly what it was not
	# supposed to know.
	_remove_dead(state)
	if _settle_winner(state, events):
		return
	_advance_turn(state)
	_start_turn(state, events)

# A dead card leaves the board and its slot collapses — everything to the right
# shifts left. There are no decoys in this mode, which is why a kill here is
# worth more than in face-down: it permanently narrows the enemy's board.
static func _remove_dead(state: FUState) -> void:
	for side in [BLACK, RED]:
		var kept: Array = []
		for id in state.rows[side]:
			var c := state.card_by_id(id)
			if c != null and c.alive:
				kept.append(id)
		state.rows[side] = kept

# ── Legal actions ─────────────────────────────────────────────────────────

# Every action the card whose turn it is may take. The board builds its target
# buttons from this, the AI ranks it, and resolve() rejects anything not in it.
static func legal_actions(state: FUState) -> Array:
	var out: Array = []
	if state.is_over():
		return out
	var actor := state.current_card()
	if actor == null or not actor.alive:
		return out

	for slot in state.attack_slots(actor.side, state.current_slot):
		out.append({"kind": "attack", "target_slot": slot})

	# Deliberately NOT gated on the trick. The card own side does not know it is
	# tricked, so the skill has to stay on offer - walking into it and losing the
	# turn is the whole mechanic. resolve() springs the trap.
	if not actor.may_attempt_skill():
		return out
	# A skill needs someone to aim at; with the enemy row empty the match is
	# already decided, and the original guarded the same way.
	if state.enemies_of(actor.side).is_empty():
		return out

	if actor.card_name == "King" and actor.double_rally:
		# An ARMED King always spends the arm: it cannot choose to hand out a
		# single rally instead. The pair is picked freely, not adjacency-locked.
		for pair in _rally_pairs(state, actor):
			out.append({"kind": "double_rally", "target_slots": pair})
		return out

	var pool := state.skill_pool(actor)
	for i in range(pool.size()):
		out.append({"kind": "skill", "target_slot": i})
	return out

# Every unordered pair of distinct ally slots the armed King may rally, plus
# the single-slot fallback when only one ally is left. The King is never in its
# own pair: rallying itself is the arming action, not a target.
static func _rally_pairs(state: FUState, king: FUCard) -> Array:
	var slots: Array = []
	var allies := state.allies_of(king.side)
	for i in range(allies.size()):
		if allies[i].id != king.id:
			slots.append(i)
	var out: Array = []
	for i in range(slots.size()):
		for j in range(i + 1, slots.size()):
			out.append([slots[i], slots[j]])
	if out.is_empty() and not slots.is_empty():
		out.append([slots[0]])
	return out

# ── Resolve ───────────────────────────────────────────────────────────────

# Applies one action, then ends the turn and opens the next one.
# Returns {"ok": bool, "error": String, "events": Array}.
#
# Events are the ONLY channel to the UI and the log — one entry per observable
# effect, so presentation never has to re-derive what happened. The battle log
# used to be written from inside the card scenes, which meant a rule and its
# log line were the same statement and neither could move without the other.
static func resolve(state: FUState, action: Dictionary) -> Dictionary:
	var events: Array = []
	if state.is_over():
		return {"ok": false, "error": "match is over", "events": events}
	var actor := state.current_card()
	if actor == null or not actor.alive:
		return {"ok": false, "error": "no card is acting", "events": events}

	# Validation runs BEFORE _release_own, so a rejected action costs nothing.
	# An action that is refused must not have quietly put the actor's shield
	# down on the way to being refused.
	var kind: String = action.get("kind", "attack")
	var lane: int = -1
	var target_slot: int = -1
	match kind:
		"attack":
			lane = action.get("target_slot", -1)
			if not lane in state.attack_slots(actor.side, state.current_slot):
				return {"ok": false, "error": "an attack may only hit the lane it faces", "events": events}
		"skill":
			if not actor.may_attempt_skill():
				return {"ok": false, "error": "a dead card cannot act", "events": events}
			if actor.card_name == "King" and actor.double_rally:
				return {"ok": false, "error": "an armed King must spend its double rally", "events": events}
			target_slot = action.get("target_slot", -1)
			if target_slot < 0 or target_slot >= state.skill_pool(actor).size():
				return {"ok": false, "error": "target slot out of range", "events": events}
		"double_rally":
			if not actor.may_attempt_skill():
				return {"ok": false, "error": "a dead card cannot act", "events": events}
			if actor.card_name != "King" or not actor.double_rally:
				return {"ok": false, "error": "no double rally is armed", "events": events}
			var bad := _check_double_rally(state, actor, action.get("target_slots", []))
			if not bad.is_empty():
				return {"ok": false, "error": bad, "events": events}
		_:
			return {"ok": false, "error": "unknown action %s" % kind, "events": events}

	# Acting AT ALL puts down whatever this card was holding up, before the
	# action itself runs. Doing it first is what lets one action move a status:
	# an Ace drops its old shield and raises a new one, a Joker frees an old
	# target and traps a new one, in a single turn.
	_release_own(state, actor, events)

	match kind:
		"attack":
			_do_attack(state, actor, lane, events)
		"skill":
			_do_skill(state, actor, target_slot, events)
		"double_rally":
			_do_double_rally(state, actor, action.get("target_slots", []), events)

	# A death anywhere may have orphaned a status, not just the actor's target.
	_post_process(state, events)
	_remove_dead(state)
	if _settle_winner(state, events):
		return {"ok": true, "error": "", "events": events}
	_end_turn(state, events)
	return {"ok": true, "error": "", "events": events}

# Everything `actor` is currently holding up goes down. This is the whole of
# the expiry rule: a status ends when its CASTER acts, never on a clock.
#
# It is deliberately blind to what the action turns out to be. An Ace that
# attacks drops its shield exactly as an Ace that re-shields does - "I acted"
# is the trigger, and a card that wants to keep a buff alive has to stand still
# and do nothing, which is the cost the buff is priced at.
static func _release_own(state: FUState, actor: FUCard, events: Array) -> void:
	match actor.card_name:
		"Ace":
			for c in state.cards:
				if c.shield > 0 and c.shield_ace == actor.id:
					events.append({
						"t": "shield_expired", "card": c.id, "amount": c.shield,
						"by": actor.id, "was_seen": c.shield_seen, "reason": "acted",
					})
					c.clear_shield()
		"King":
			for c in state.cards:
				if c.rallied and c.rally_king == actor.id:
					events.append({
						"t": "rally_expired", "card": c.id, "by": actor.id, "reason": "acted",
					})
					c.clear_rally()
		"Joker":
			for c in state.cards:
				if c.tricked and c.trick_joker == actor.id:
					events.append({
						"t": "trick_lifted", "card": c.id, "by": actor.id,
						"was_seen": c.trick_seen, "reason": "acted",
					})
					c.clear_trick()

# A status dies with the card holding it up. Run after every action, because a
# death anywhere - not only the actor's own target - can orphan one.
static func _post_process(state: FUState, events: Array) -> void:
	for c in state.cards:
		if c.shield > 0 and c.shield_ace != NONE:
			var ace := state.card_by_id(c.shield_ace)
			if ace == null or not ace.alive:
				events.append({
					"t": "shield_expired", "card": c.id, "amount": c.shield,
					"by": c.shield_ace, "was_seen": c.shield_seen, "reason": "died",
				})
				c.clear_shield()
		if c.rallied and c.rally_king != NONE:
			var king := state.card_by_id(c.rally_king)
			if king == null or not king.alive:
				events.append({
					"t": "rally_expired", "card": c.id, "by": c.rally_king, "reason": "died",
				})
				c.clear_rally()
		if c.tricked and c.trick_joker != NONE:
			var joker := state.card_by_id(c.trick_joker)
			if joker == null or not joker.alive:
				events.append({
					"t": "trick_lifted", "card": c.id, "by": c.trick_joker,
					"was_seen": c.trick_seen, "reason": "died",
				})
				c.clear_trick()

# ── Actions ───────────────────────────────────────────────────────────────

# Strictly lane-locked: an attack hits the card it faces, at full value, and has
# no target to choose. Only a skill picks.
static func _do_attack(state: FUState, actor: FUCard, lane: int, events: Array) -> void:
	var enemy_side := state.opponent(actor.side)
	var target := state.card_at(enemy_side, lane)
	if target == null:
		events.append({"t": "whiff", "actor": actor.id, "slot": lane, "reason": "empty"})
		return
	# Swinging at half strength is not something a victim can hide, so the trap
	# goes public here rather than pretending otherwise. It is NOT spent: it
	# still denies the skill, and it still ends only when it springs, when its
	# Joker moves, or when a rally breaks it. What the victim bought with this
	# turn is the knowledge, at the price of half a hit.
	if actor.tricked and not actor.trick_seen:
		actor.trick_seen = true
		events.append({"t": "reveal", "card": actor.id, "what": "trick"})
	_apply_hit(actor, target, actor.attack_value(), "attacks", events)

static func _do_skill(state: FUState, actor: FUCard, target_slot: int, events: Array) -> void:
	# -- The trap springs --------------------------------------------------
	# A tricked card finds out here and nowhere else. Attacking never told it,
	# and no label ever did.
	if actor.tricked:
		var joker: int = actor.trick_joker
		if actor.rallied:
			# A rally is armour. It is SPENT breaking the trick, so the skill
			# gets through but covers one lane rather than three - the Joker
			# traded its action for the King, which is the trade that keeps
			# both cards worth playing. A player who suspects a trick can push
			# a skill through anyway, at the price of the rally.
			actor.clear_rally()
			actor.clear_trick()
			events.append({"t": "rally_breaks_trick", "card": actor.id, "by": joker})
		else:
			actor.clear_trick()
			events.append({"t": "trick_sprung", "card": actor.id, "by": joker})
			# The turn is gone. That is the entire cost of a trick, and it is
			# only ever paid by a card that reached for a skill.
			return

	var pool := state.skill_pool(actor)
	var spread: bool = actor.rallied
	var lanes := state.lane_set(pool.size(), target_slot, spread)

	events.append({
		"t": "skill", "actor": actor.id, "name": actor.card_name,
		"slot": target_slot, "lanes": lanes, "spread": spread,
	})

	match actor.card_name:
		"Ace":
			for lane in lanes:
				var ally: FUCard = pool[lane]
				var gained := ally.add_shield(actor.skill_value)
				ally.shield_ace = actor.id
				ally.shield_seen = false
				events.append({"t": "shield", "actor": actor.id, "target": ally.id, "amount": gained})
		"Queen":
			for lane in lanes:
				var ally: FUCard = pool[lane]
				var healed := ally.heal(actor.skill_value)
				events.append({"t": "heal", "actor": actor.id, "target": ally.id, "amount": healed})
		"Jack":
			for lane in lanes:
				_apply_hit(actor, pool[lane], actor.skill_value, "shoots", events)
		"Joker":
			for lane in lanes:
				var foe: FUCard = pool[lane]
				# Re-tricking an already-tricked card is legal and wasted; the
				# trap is a flag, not a stack.
				foe.tricked = true
				foe.trick_seen = false
				foe.trick_joker = actor.id
				events.append({"t": "trick", "actor": actor.id, "target": foe.id})
		"King":
			# Rally is always single-target; a King never carries a rally of its
			# own, because rallying itself is the arming action instead.
			_do_rally(state, actor, pool[target_slot], events)

	# A rallied card spends the rally by USING a skill; nothing else removes it.
	# The King is exempt because it never carries one - rallying itself arms the
	# double rally rather than granting itself a spread.
	if spread and actor.card_name != "King":
		# Covering three lanes is what gives the rally away, so it goes public
		# in the same breath as it is spent.
		actor.rally_seen = true
		events.append({"t": "reveal", "card": actor.id, "what": "rally"})
		actor.clear_rally()
		events.append({"t": "rally_consumed", "card": actor.id})

static func _do_rally(state: FUState, king: FUCard, target: FUCard, events: Array) -> void:
	if target.id == king.id:
		# Self-rally arms the double rally instead of rallying the King.
		king.double_rally = true
		events.append({"t": "self_rally", "card": king.id})
		return
	# No need to clear the previous rally here: _release_own already dropped
	# every rally this King was holding, before the action began. That is also
	# what keeps the no-stacking rule true for BOTH the player and the AI
	# without either caller having to remember it.
	target.rallied = true
	target.rally_seen = false
	target.rally_king = king.id
	events.append({"t": "rally", "actor": king.id, "target": target.id})

# The allies an armed King's pair actually resolves to, in order and without
# duplicates. Split out of _do_double_rally so resolve() can VALIDATE the action
# before _release_own drops anything: a refused double rally must not have cost
# the King the rallies it was already holding on the way to being refused.
static func _double_rally_picks(state: FUState, king: FUCard, target_slots: Array) -> Array[FUCard]:
	var allies := state.allies_of(king.side)
	var picked: Array[FUCard] = []
	for raw in target_slots:
		var slot := int(raw)
		if slot < 0 or slot >= allies.size():
			return []
		var ally: FUCard = allies[slot]
		if ally.id == king.id:
			return []
		if not picked.has(ally):
			picked.append(ally)
	return picked

# "" when the pair is legal, otherwise why it is not. Mutates nothing.
static func _check_double_rally(state: FUState, king: FUCard, target_slots: Array) -> String:
	var allies := state.allies_of(king.side)
	for raw in target_slots:
		var slot := int(raw)
		if slot < 0 or slot >= allies.size():
			return "target slot out of range"
		if allies[slot].id == king.id:
			return "a King cannot rally itself as one of the pair"
	if _double_rally_picks(state, king, target_slots).is_empty():
		return "no rally target given"
	return ""

# Rally does not stack: at most one ally on a side carries one, or two for the
# single action an armed King spends. Nothing here has to enforce that any more,
# because _release_own has already put down every rally this King was holding.
#
# Clearing the old rally used to be the CALLER's job, and only some callers did
# it: the AI cleared before every King skill and the human's path did not, so a
# player could hold two rallied allies at once and the AI could not. Making it a
# property of the King acting - rather than a courtesy each caller had to
# remember - is what put both back on the same rule.
static func _do_double_rally(state: FUState, king: FUCard, target_slots: Array, events: Array) -> void:
	var ids: Array = []
	for ally in _double_rally_picks(state, king, target_slots):
		ally.rallied = true
		ally.rally_seen = false
		ally.rally_king = king.id
		ids.append(ally.id)
	king.double_rally = false
	events.append({"t": "double_rally", "actor": king.id, "targets": ids})

# ── Shared helpers ────────────────────────────────────────────────────────

# Every point of damage in the mode funnels through here, which is why the
# shield reveal lives here rather than in _do_attack: a Jack shoot commits to a
# card just as an attack does, and finds the same Ace standing in front of it.
static func _apply_hit(actor: FUCard, target: FUCard, damage: int, verb: String, events: Array) -> void:
	if target.shield > 0 and not target.shield_seen:
		# The attacker is already committed - the reveal is what it BOUGHT, not
		# a warning it gets to act on.
		target.shield_seen = true
		events.append({"t": "reveal", "card": target.id, "what": "shield"})
	var res := target.take_hit(damage)
	events.append({
		"t": "hit", "actor": actor.id, "target": target.id, "verb": verb,
		"damage": damage, "absorbed": res.absorbed, "hp_lost": res.hp_lost,
	})
	if res.died:
		events.append({"t": "death", "card": target.id})

# ── Outcome ───────────────────────────────────────────────────────────────

# 0 = undecided, 1 = Black, 2 = Red, 3 = draw.
static func winner(state: FUState) -> int:
	var b := state.living_count(BLACK)
	var r := state.living_count(RED)
	if b == 0 and r == 0:
		return 3
	if b == 0:
		return RED
	if r == 0:
		return BLACK
	return 0

static func winner_text(outcome: int) -> String:
	match outcome:
		BLACK: return "Black wins!"
		RED: return "Red wins!"
		3: return "Draw!"
	return ""

static func _settle_winner(state: FUState, events: Array) -> bool:
	if state.is_over():
		return true
	var w := winner(state)
	if w == 0:
		return false
	state.phase = FUState.Phase.GAME_OVER
	state.outcome = w
	state.current_id = NONE
	events.append({"t": "game_over", "outcome": w})
	return true
