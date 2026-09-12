extends RefCounted
class_name FDRules

# Face-down mode rules engine. PURE RULES — this file must never reference a
# scene, a node or a texture (PLAN §3). Everything here is exercised headless by
# test/run_tests.gd; the board scene only observes state and issues actions.

const BLACK := FDState.BLACK
const RED := FDState.RED
const NONE := FDCard.NONE

# Lane spread produced by a rally (PLAN §2.3).
#
# There used to be a LINE spread (the whole board), granted by a King's rally+.
# It is gone: measured over 600 matches it bought at most two extra lanes,
# because the board is five wide at its widest and shrinks as cards die, and it
# cost the King an entire extra action to arm. rally+ now widens WHO gets
# rallied instead of how far one rally reaches - see _do_rally.
enum Spread { SINGLE, THREE }

# The pacing lever (PLAN §2.2), and the ONE place it is written down.
#
# It used to be declared separately in fd_table.gd and in test/bench_ai.gd, and
# the two drifted: the board shipped 1.0 while the bench swept at 2.0, so every
# AI weight in fd_ai.gd and fd_hard_ai.gd was tuned against a game with double
# damage and double shields. Both now read this constant. If a tuning run and
# the real game ever disagree again, it will not be because of this number.
const DAMAGE_SCALE: float = 1.0

# ── Match setup ───────────────────────────────────────────────────────────

static func new_match(player_side: int = BLACK) -> FDState:
	var state := FDState.new()
	state.player_side = player_side
	for side in [BLACK, RED]:
		for card_name in CardStats.ORDER:
			var c := FDCard.create(state.new_id(), side, card_name)
			state.cards.append(c)
	state.damage_scale = DAMAGE_SCALE
	state.round_no = 1
	begin_round(state)
	return state

# ── Rounds ────────────────────────────────────────────────────────────────

# PRD §7: the board is max(living, living) slots wide and the short side pads
# with its own corpses. Reveals and acted-lists reset here (PRD §8.2).
static func begin_round(state: FDState) -> void:
	if _settle_winner(state):
		return
	state.board_size = max(state.living_count(BLACK), state.living_count(RED))
	state.slots[BLACK] = []
	state.slots[RED] = []
	state.revealed[BLACK] = {}
	state.revealed[RED] = {}
	state.acted[BLACK] = {}
	state.acted[RED] = {}
	state.placed[BLACK] = false
	state.placed[RED] = false
	# Reveals and buff marks are both memory of what was watched this round, and
	# both are wiped here: after the row is rearranged, neither the identity nor
	# the buff of a face-down slot is known any more.
	for c in state.cards:
		c.clear_marks()
	# Initiative alternates every round; Black leads round 1 (PRD §3.2).
	state.leader = BLACK if state.round_no % 2 == 1 else RED
	state.side_to_act = state.leader
	state.phase = FDState.Phase.POSITIONING

# Living cards first, padded with corpses, then the whole row shuffled.
# Used by the AI (PRD §8.1) and by the player's Randomize button.
static func auto_place(state: FDState, side: int, rng: RandomNumberGenerator = null) -> Array:
	var row: Array = []
	for c in state.living(side):
		row.append(c.id)
	for c in state.dead(side):
		if row.size() >= state.board_size:
			break
		row.append(c.id)
	if rng != null:
		# Fisher-Yates against the supplied rng so tests stay deterministic.
		for i in range(row.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var tmp = row[i]
			row[i] = row[j]
			row[j] = tmp
	else:
		row.shuffle()
	return row

# Returns {"ok": bool, "error": String}.
static func commit_placement(state: FDState, side: int, slot_ids: Array) -> Dictionary:
	if state.phase != FDState.Phase.POSITIONING:
		return {"ok": false, "error": "not in positioning phase"}
	if slot_ids.size() != state.board_size:
		return {"ok": false, "error": "expected %d slots, got %d" % [state.board_size, slot_ids.size()]}

	var seen := {}
	for id in slot_ids:
		if seen.has(id):
			return {"ok": false, "error": "card %d placed twice" % id}
		seen[id] = true
		var c := state.card_by_id(id)
		if c == null or c.side != side:
			return {"ok": false, "error": "card %d is not on this side" % id}

	# Every living card must be on the board — you cannot bench a survivor.
	for c in state.living(side):
		if not seen.has(c.id):
			return {"ok": false, "error": "living %s left unplaced" % c.card_name}

	state.slots[side] = slot_ids.duplicate()
	state.placed[side] = true
	if state.placed[BLACK] and state.placed[RED]:
		state.phase = FDState.Phase.BATTLE
		state.side_to_act = state.leader
	return {"ok": true, "error": ""}

# ── Legal actions ─────────────────────────────────────────────────────────

# The lanes an attack from `from_slot` may reach: its own and either neighbour.
static func attack_slots(state: FDState, from_slot: int) -> Array:
	var out: Array = []
	for slot in range(from_slot - 1, from_slot + 2):
		if slot >= 0 and slot < state.board_size:
			out.append(slot)
	return out

# Which row a card's skill targets.
static func skill_targets_enemies(card: FDCard) -> bool:
	return card.card_name in ["Jack", "Joker"]

static func legal_actions(state: FDState, side: int) -> Array:
	var out: Array = []
	if state.phase != FDState.Phase.BATTLE or state.side_to_act != side:
		return out
	for c in state.unacted(side):
		# Attack is lane-locked — no target choice to make (PRD §5.1).
		out.append({"card_id": c.id, "kind": "attack", "target_slot": state.slot_of(c)})
		if c.can_use_skill():
			for slot in range(state.board_size):
				out.append({"card_id": c.id, "kind": "skill", "target_slot": slot})
	return out

# ── Resolve ───────────────────────────────────────────────────────────────

# Applies one action. Returns {"ok": bool, "error": String, "events": Array}.
# Events are the ONLY channel to the UI and the log — one entry per observable
# effect, so presentation never has to re-derive what happened.
static func resolve(state: FDState, side: int, action: Dictionary) -> Dictionary:
	var events: Array = []
	if state.phase != FDState.Phase.BATTLE:
		return {"ok": false, "error": "not in battle phase", "events": events}
	if state.side_to_act != side:
		return {"ok": false, "error": "not this side's turn", "events": events}

	var actor := state.card_by_id(action.get("card_id", NONE))
	if actor == null or actor.side != side:
		return {"ok": false, "error": "no such actor", "events": events}
	if not actor.alive:
		return {"ok": false, "error": "actor is dead", "events": events}
	if state.has_acted(actor):
		return {"ok": false, "error": "actor already acted", "events": events}

	var kind: String = action.get("kind", "attack")
	if kind == "skill" and not actor.can_use_skill():
		return {"ok": false, "error": "skill is nullified", "events": events}

	var actor_slot := state.slot_of(actor)
	if actor_slot == -1:
		return {"ok": false, "error": "actor is not on the board", "events": events}

	# Captured before step 4, which may hand out rallies of its own.
	var was_rallied: bool = actor.has_rally()
	var spread := Spread.THREE if was_rallied else Spread.SINGLE

	# ── PRD §9.7 step 1 — a King acting first releases the rally it granted.
	# Last-rallies are exempt: their King is dead, so nothing can release them
	# but the buffed card's own skill.
	if actor.card_name == "King":
		for c in state.cards:
			if c.rally_king == actor.id and c.rallied and not c.rally_last:
				c.clear_rally()
				events.append({"t": "rally_expired", "card": c.id, "by": actor.id})

	# ── PRD §9.7 step 2 — a Joker acting first releases its own nullifies, so
	# it can free an old target and trick a new one in the same action.
	if actor.card_name == "Joker":
		for c in state.cards:
			if c.nullified and c.joker_link == actor.id:
				c.clear_nullify()
				events.append({"t": "nullify_lifted", "card": c.id, "by": actor.id})

	# ── step 2b — an Ace acting first drops the shields it is holding up, so a
	# shield can be moved from one ally to another in a single action.
	if actor.card_name == "Ace":
		for c in state.cards:
			if c.shield > 0 and c.shield_ace == actor.id:
				var dropped: int = c.shield
				c.clear_shield()
				events.append({"t": "shield_expired", "card": c.id, "by": actor.id, "amount": dropped})

	# ── step 3 — acting always reveals you.
	_reveal(state, actor.side, actor_slot, events)

	# ── step 4 — the action itself.
	if kind == "attack":
		var lane: int = action.get("target_slot", actor_slot)
		if not lane in attack_slots(state, actor_slot):
			return {"ok": false, "error": "attack must hit its own lane or a neighbour", "events": events}
		_do_attack(state, actor, actor_slot, lane, events)
	else:
		var target_slot: int = action.get("target_slot", actor_slot)
		if target_slot < 0 or target_slot >= state.board_size:
			return {"ok": false, "error": "target slot out of range", "events": events}
		_do_skill(state, actor, target_slot, spread, events)

	# ── step 5 — a rallied card that used a skill spends the rally. Attacking
	# does not spend it (PRD §9.1); the King never carries one.
	if kind == "skill" and was_rallied and actor.card_name != "King":
		actor.clear_rally()
		events.append({"t": "rally_consumed", "card": actor.id})

	# ── step 6 — deaths this action may have freed nullifies or orphaned rallies.
	_post_process(state, events)

	state.acted[side][actor.id] = true
	return {"ok": true, "error": "", "events": events}

# ── Actions ───────────────────────────────────────────────────────────────

# Lane-locked: hits whatever sits in the SAME slot index across the board,
# which under hidden placement is always a guess (PRD §5.1).
static func _do_attack(state: FDState, actor: FDCard, actor_slot: int, lane: int, events: Array) -> void:
	var enemy_side := state.opponent(actor.side)
	var target := state.card_at(enemy_side, lane)
	_reveal(state, enemy_side, lane, events)

	var damage: int = actor.attack_value()
	var reached: bool = lane != actor_slot
	if reached:
		damage = max(1, int(round(damage * CardStats.ADJACENT_MULT)))

	if target == null:
		events.append({"t": "whiff", "actor": actor.id, "slot": lane, "reason": "empty"})
		return
	if not target.alive:
		# The decoy did its job: the action is spent for nothing (PRD 8.3).
		events.append({"t": "decoy_hit", "actor": actor.id, "target": target.id, "slot": lane})
		return
	_apply_hit(state, actor, target, damage, "reaches across at" if reached else "attacks", events)

static func _do_skill(state: FDState, actor: FDCard, target_slot: int, spread: int, events: Array) -> void:
	var lanes := _lane_set(state, target_slot, spread)
	events.append({
		"t": "skill", "actor": actor.id, "name": actor.card_name,
		"slot": target_slot, "lanes": lanes, "spread": spread,
	})
	match actor.card_name:
		"Ace":
			for lane in lanes:
				var ally := state.card_at(actor.side, lane)
				if ally == null:
					continue
				# Deliberately NOT skipping corpses. Shielding a dead decoy
				# achieves nothing mechanically - a decoy absorbs an attack
				# whole and never takes damage - but the enemy sees a shield
				# appear on a face-down slot and has to decide whether it is
				# guarding something. Spending a real action on a lie is the
				# price of telling it.
				if not ally.alive:
					ally.shield_ace = actor.id
					ally.mark_shielded = true
					events.append({"t": "shield", "actor": actor.id, "target": ally.id, "amount": 0})
					continue
				ally.mark_shielded = true
				# Shield rides the same pacing lever as damage: at scale 2 a hit
				# lands for double, so a flat 15 shield would quietly be worth
				# half what the stat table says.
				var gained := ally.add_shield(
					scaled(state, skill_output(actor.card_name, actor.skill_value, spread)),
					scaled(state, ally.max_shield))
				ally.shield_ace = actor.id
				events.append({"t": "shield", "actor": actor.id, "target": ally.id, "amount": gained})
		"Queen":
			for lane in lanes:
				var ally := state.card_at(actor.side, lane)
				if ally == null:
					continue
				# Same bluff as the Ace: a corpse can be tended for nothing.
				if not ally.alive:
					ally.mark_tended = true
					events.append({"t": "heal", "actor": actor.id, "target": ally.id, "amount": 0})
					continue
				ally.mark_tended = true
				var healed := ally.heal(actor.skill_value)
				events.append({"t": "heal", "actor": actor.id, "target": ally.id, "amount": healed})
		"Jack":
			var enemy_side := state.opponent(actor.side)
			var shot: int = skill_output(actor.card_name, actor.skill_value, spread)
			for lane in lanes:
				_reveal(state, enemy_side, lane, events)
				var enemy := state.card_at(enemy_side, lane)
				if enemy == null:
					continue
				if not enemy.alive:
					events.append({"t": "decoy_hit", "actor": actor.id, "target": enemy.id, "slot": lane})
					continue
				_apply_hit(state, actor, enemy, shot, "shoots", events)
		"King":
			# Rally is always single-target: nothing can rally the King itself,
			# so a King never carries a spread.
			_do_rally(state, actor, target_slot, events)
		"Joker":
			var foe_side := state.opponent(actor.side)
			for lane in lanes:
				_reveal(state, foe_side, lane, events)
				var foe := state.card_at(foe_side, lane)
				if foe == null:
					continue
				if not foe.alive:
					events.append({"t": "decoy_hit", "actor": actor.id, "target": foe.id, "slot": lane})
					continue
				_do_trick(actor, foe, events)

# PRD §9.1-9.2 and §9.5.
#
# A plain rally lands on one ally. An ARMED King (rally+, set by rallying
# itself) spends the arm to rally three consecutive allies instead - the same
# ordinary rally, just handed to three cards at once. That is what rally+ buys:
# three future skills covering three lanes each, rather than one skill covering
# a slightly wider strip of a board that is shrinking anyway.
#
# The King is skipped if it falls inside its own spread: a King never carries a
# rally, because rallying itself is the arming action.
static func _do_rally(state: FDState, king: FDCard, target_slot: int, events: Array) -> void:
	var target := state.card_at(king.side, target_slot)
	# Only an EMPTY slot is refused. A corpse is a legal target: rallying one
	# does nothing but shows, which is the bluff. This guard used to reject dead
	# targets too, which silently made the rally half of the mechanic dead code
	# even after the loop below learned to handle them.
	if target == null:
		events.append({"t": "whiff", "actor": king.id, "slot": target_slot, "reason": "no living ally"})
		return

	if target.id == king.id:
		# Self-rally arms rally+ instead of rallying the King (PRD §9.2).
		king.king_plus = true
		events.append({"t": "king_plus_armed", "card": king.id})
		return

	var upgraded: bool = king.king_plus
	if upgraded:
		king.king_plus = false
	var lanes := _lane_set(state, target_slot, Spread.THREE if upgraded else Spread.SINGLE)

	var granted: Array = []
	for lane in lanes:
		var ally := state.card_at(king.side, lane)
		if ally == null or ally.id == king.id:
			continue
		# A rally on a dead decoy is inert - a corpse never acts - but it shows,
		# and a slot that looks worth rallying is a slot worth attacking.
		if not ally.alive:
			ally.rallied = true
			ally.rally_king = king.id
			ally.mark_rallied = true
			granted.append(ally.id)
			events.append({"t": "rally", "actor": king.id, "target": ally.id, "upgraded": upgraded})
			continue

		# A King's rally is the only thing that frees a nullified ally (PRD §9.5),
		# and freeing them is ALL it does to them. The two abilities are mirror
		# images climbing the same ladder one rung per action:
		#
		#     tricked  <--trick--  regular  <--trick--  rallied
		#     tricked  --rally-->  regular  --rally-->  rallied
		#
		# It used to clear the trick AND rally in one action, which made a rally
		# on a tricked ally worth two of the Joker's and meant a trick could be
		# answered at no cost.
		if ally.nullified:
			ally.clear_nullify()
			granted.append(ally.id)
			events.append({"t": "nullify_cleared_by_king", "card": ally.id, "by": king.id})
			continue

		ally.rallied = true
		ally.rally_last = false
		ally.rally_king = king.id
		ally.mark_rallied = true
		granted.append(ally.id)
		events.append({
			"t": "rally", "actor": king.id, "target": ally.id,
			"upgraded": upgraded,
		})

	if granted.is_empty():
		events.append({"t": "whiff", "actor": king.id, "slot": target_slot, "reason": "no living ally"})

# PRD §9.3 — trick peels exactly ONE layer. Rally is armour against tricks: a
# rally must be stripped before a later trick can nullify.
#
# A King's OWN armed rally+ (king_plus) is deliberately NOT peelable. It used to
# be a rung on this ladder, which made arming it a losing move on its own terms:
# one King action to arm, and one Joker action to erase it before it ever paid
# out. The Joker has to let the rally be granted and tear it off one of the
# allies that received it.
#
# A trick on an armed King therefore falls through to nullify: the King loses
# its skill until the Joker acts again or dies, exactly like any other card,
# but the arm survives the seal and is still there when it lifts. The trick
# delays the rally+; it can no longer cancel it.
static func _do_trick(joker: FDCard, target: FDCard, events: Array) -> void:
	if target.rallied or target.rally_last:
		target.clear_rally()
		events.append({"t": "trick_strip_rally", "actor": joker.id, "target": target.id})
	else:
		target.nullified = true
		target.joker_link = joker.id
		events.append({"t": "nullify", "actor": joker.id, "target": target.id})

# What ONE lane gets from a skill at this spread. A rallied skill reaches three
# lanes but each of them gets the card's `rallied` value from CardStats instead
# of its printed one.
#
# Public because three places need the same answer: the resolve step above, the
# AI's valuation in fd_scorer.gd, and the lane preview the board draws while you
# are choosing a target. A preview that promised 20 and delivered 17 would be
# worse than no preview at all.
static func skill_output(card_name: String, raw: int, spread: int) -> int:
	if spread == Spread.SINGLE:
		return raw
	return CardStats.rallied_skill_of(card_name, CardStats.FACE_DOWN)

# ── Shared helpers ────────────────────────────────────────────────────────

static func _lane_set(state: FDState, center: int, spread: int) -> Array:
	var out: Array = []
	match spread:
		Spread.THREE:
			for i in range(center - 1, center + 2):
				if i >= 0 and i < state.board_size:
					out.append(i)
		_:
			if center >= 0 and center < state.board_size:
				out.append(center)
	return out

# The single funnel every scaled number passes through, so damage_scale is the
# only pacing lever anyone ever has to touch (PLAN §2.2). Damage and shield
# both ride it; healing deliberately does NOT - see PLAN §2.2.
static func scaled(state: FDState, raw: int) -> int:
	return max(0, int(round(raw * state.damage_scale)))

static func _apply_hit(state: FDState, actor: FDCard, target: FDCard, raw: int, verb: String, events: Array) -> void:
	var dmg: int = scaled(state, raw)
	var res := target.take_hit(dmg)
	events.append({
		"t": "hit", "actor": actor.id, "target": target.id, "verb": verb,
		"damage": dmg, "absorbed": res.absorbed, "hp_lost": res.hp_lost,
	})
	if res.died:
		events.append({"t": "death", "card": target.id})

static func _reveal(state: FDState, side: int, slot: int, events: Array) -> void:
	if slot < 0 or slot >= state.board_size:
		return
	if state.revealed[side].has(slot):
		return
	state.revealed[side][slot] = true
	events.append({"t": "reveal", "side": side, "slot": slot})

# PRD §9.7 step 6. Run after every action because a death anywhere — not just
# the actor's target — can free a nullify or orphan a rally.
static func _post_process(state: FDState, events: Array) -> void:
	for c in state.cards:
		# A Joker's trick dies with the Joker (PRD §9.4).
		if c.nullified and c.joker_link != NONE:
			var joker := state.card_by_id(c.joker_link)
			if joker == null or not joker.alive:
				c.clear_nullify()
				events.append({"t": "nullify_lifted", "card": c.id, "by": NONE})
		# A shield dies with the Ace holding it up (same shape as PRD 9.4).
		if c.shield > 0 and c.shield_ace != NONE:
			var ace := state.card_by_id(c.shield_ace)
			if ace == null or not ace.alive:
				var lost: int = c.shield
				c.clear_shield()
				events.append({"t": "shield_lost", "card": c.id, "amount": lost})
		# A rally whose King died loses its "King acts again" expiry and becomes
		# a last rally: it now survives round transitions (PRD §9.6).
		if c.rallied and not c.rally_last and c.rally_king != NONE:
			var king := state.card_by_id(c.rally_king)
			if king == null or not king.alive:
				c.rally_last = true
				events.append({"t": "last_rally", "card": c.id})

# ── Turn flow ─────────────────────────────────────────────────────────────

# Strict alternation, with skips when one side runs out (PRD §3.2).
# Returns "continue" | "round_end" | "game_over".
static func advance(state: FDState) -> String:
	if _settle_winner(state):
		return "game_over"
	var other := state.opponent(state.side_to_act)
	if state.has_unacted(other):
		state.side_to_act = other
		return "continue"
	if state.has_unacted(state.side_to_act):
		# The other side is exhausted; this one keeps taking consecutive actions.
		return "continue"
	state.round_no += 1
	begin_round(state)
	return "game_over" if state.is_over() else "round_end"

# 0 = undecided, 1 = Black, 2 = Red, 3 = draw.
static func winner(state: FDState) -> int:
	var b := state.living_count(BLACK)
	var r := state.living_count(RED)
	if b == 0 and r == 0:
		return 3
	if b == 0:
		return RED
	if r == 0:
		return BLACK
	return 0

static func _settle_winner(state: FDState) -> bool:
	if winner(state) != 0:
		state.phase = FDState.Phase.GAME_OVER
		return true
	return false
