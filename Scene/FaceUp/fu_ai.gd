extends RefCounted
class_name FUAI

# Face-up mode AI. Pure, like FURules: it reads an FUState and returns an action
# dictionary, and it touches no scene. It used to live inside table2.gd, where
# it both scored moves AND executed them by calling do_skill() on card nodes,
# which is why it could only be measured by instantiating the whole board.
#
# Three brains, in one file because they share every scoring helper:
#
#   choose        the scorer, playing its best move       (NORMAL and HARD)
#   choose_ladder a fixed priority order                  (EASY)
#   choose_random uniform over the option list            (benchmark floor)
#
# Everything here reads numbers off the cards. Nothing compares them from
# memory - that is what broke the ladder when the stat table was retuned.
#
# ── It does not get to cheat ──────────────────────────────────────────────
#
# Three statuses are hidden from the side that did not cause them, so every
# read of one goes through FUState.sees_* rather than off the card. That means
# the AI plays into the same fog a player does:
#
#   - it cannot see an enemy shield until something of its own has hit it, so
#     it will happily throw a kill shot into 30 points of absorption;
#   - it cannot see an enemy rally, so it cannot pre-empt a spread;
#   - it cannot see a trick on its OWN cards, so it walks into them, loses the
#     turn, and only then knows.
#
# The last one is the point of the mechanic and it is why the scorer must not
# consult `tricked` on an ally anywhere. Reading it directly would not make the
# AI stronger so much as make the trick not exist.

# ── Weights ───────────────────────────────────────────────────────────────
#
# The scorer values every option in damage-equivalent points and plays the
# highest. It replaced a priority ladder — heal if anyone is hurt, shoot only
# for a guaranteed kill, rally whenever a rally target exists, otherwise attack
# — that lost 80 matches out of 80 to an opponent which did nothing but attack.
# Two reasons, both of which scoring fixes:
#
#  1. Only damage removes an enemy ACTION. A card that heals is a card that did
#     not shorten the enemy's turn, and dead cards are removed in this mode, so
#     every kill permanently narrows the board. Topping up a healthy ally turns
#     an action into hit points that were never going to be spent.
#  2. The ladder hard-coded "shoot is weaker than attack", which stopped being
#     true when the attack table was retuned.

# The weights are DATA, not constants, so test/sweep_faceup.gd can vary them.
# They were consts until the sweep existed, which is the same mistake fd_ai.gd
# made: a scorer whose numbers cannot be varied is a scorer nobody re-tunes,
# and these had already outlived four rule changes.
#
#   kill          A kill removes a card from the board for good - there are no
#                 decoys here, so a lead compounds and kills are worth more
#                 than in face-down.
#   shield_break  Damage that lands on a shield instead of HP. Worth something
#                 (the enemy no longer gets to absorb it) but less.
#   shield        A shield now stands until its Ace acts again rather than
#                 expiring on the carrier's turn, so it covers the carrier's own
#                 turn, can be moved, and can be topped back up.
#   heal          Healing a healthy card is close to worthless.
#   save          ...but pulling one back out of one-hit range earns its turn.
#   rally_discount  A rally is a bet on next turn; an attack is certain.
#   self_rally    Arming a double rally costs a whole turn for something two
#                 moves away.
#   trick         What a trap is worth. Hardest of the eight to price: it costs
#                 the victim an action, but ONLY if they reach for a skill, and
#                 the Joker gives the trap up the moment it acts again.
# Produced by coordinate descent in test/sweep_faceup.gd against the three
# opponent panel, at a measured panel mean of 84.1% (the previous set: 71.2%).
#
#   godot --headless --path RemiShowdown --script res://test/sweep_faceup.gd -- descend
#
# These answer one particular set of rules and one particular stat table.
# RE-SWEEP whenever CardStats.STATS_FACEUP, CardStats.SHIELD_LEAK or
# CardStats.TRICK_ATTACK_MULT moves - the previous set was derived before the
# attack lost its sideways reach, before shields became caster-held and before
# the trick became a trap, and by the end it was answering a game that no longer
# existed.
#
# Two of these are NOT what the descent returned, and the reasons matter:
#
#  - `shield` came back as 0.0. That is a TIE, not a finding: at the final set,
#    0.0, 0.15 and 0.35 all measure 84.1%, and the descent kept 0.0 only because
#    it was tried first and improvements need a strict >. Shipping it would have
#    stopped the AI ever shielding - a whole card's ability switched off - to buy
#    nothing measurable. Where the metric is indifferent, prefer the setting that
#    plays the game. Above 0.35 it does get worse, and 1.0 stalls 29 matches.
#  - `heal` and `kill` are both at values the grid could not disprove; see the
#    note on kill below.
#
# WATCH THE STALLS. Face-up has no round structure and no DAMAGE_SCALE, so an
# Ace renewing a shield behind a healing Queen can outrun the damage coming at
# it. `shield` at 1.0 measured 80.2% while leaving 29 matches of 600 unfinished.
const DEFAULTS := {
	# The clearest signal in the sweep, and the strongest term by far: at 0.0 the
	# scorer collapses to 29.5%. Kills compound here because a dead card leaves
	# the board for good - there are no decoys on this side.
	#
	# 90.0 won at the top of the original grid, which looked like it might be an
	# edge rather than an optimum. It is not: extending the grid to 130 and 180
	# measures identically to 90, so the curve flattens here. Anything at or
	# above 90 makes a lethal blow beat every alternative outright, and past
	# that the number cannot express anything more.
	"kill": 90.0,
	"shield_break": 0.5,
	"shield": 0.35,
	# 0.5, up from 0.1. Turning healing off entirely costs ~32 points, which is
	# the opposite of what the face-down scorer found - and the reason is the
	# rule change: a face-up shield now stands until its Ace moves, so a healed
	# card behind one actually keeps the HP.
	"heal": 0.5,
	"save": 14.0,
	"rally_discount": 0.75,
	"self_rally": 0.5,
	# 2.5, up from 0.35 - a sevenfold repricing, and the whole reason the trick
	# rule changed. While a trap only denied a skill it was worth nothing (0.0
	# and 0.35 measured identically, because the scorer mostly attacks and so
	# mostly never sprang one). Now that it also halves an attack it is worth
	# real points, and it is strongly opponent-dependent: against a skill-heavy
	# ladder it swings 65% -> 88%, against an attack-only opponent it costs
	# 96% -> 85%, because there is no skill there to deny. The panel is what
	# makes that visible; either opponent alone would set this term to noise in
	# the opposite direction.
	"trick": 2.5,
}

static func weights(overrides: Dictionary = {}) -> Dictionary:
	var w: Dictionary = DEFAULTS.duplicate()
	for k in overrides:
		w[k] = overrides[k]
	return w

# ── Entry points ──────────────────────────────────────────────────────────

# The best move the scorer can see. Ties go to attacking, which is deliberate:
# an attack is the certain option, so a skill has to be strictly better to be
# worth the turn.
#
# Nothing here prices the buff the actor is about to put down by acting, and
# that is correct rather than an omission: FURules._release_own fires on ANY
# action, so an Ace loses its shield whether it attacks or re-shields, and a
# Joker loses its trap whether it attacks or re-traps. A cost every option pays
# equally cannot separate them. It does mean a card can never CHOOSE to hold a
# buff - holding one means not having a turn, and every card gets a turn.
static func choose(state: FUState, w: Dictionary = DEFAULTS) -> Dictionary:
	var actor := state.current_card()
	if actor == null:
		return {}

	var best := _best_attack(state, actor, w)
	var best_score: float = best.get("score", 0.0)
	best.erase("score")

	if not actor.may_attempt_skill() or state.enemies_of(actor.side).is_empty():
		return best

	var allies := state.allies_of(actor.side)
	var enemies := state.enemies_of(actor.side)

	# An ARMED King spends the arm or attacks; a single rally is not on offer.
	if actor.card_name == "King" and actor.double_rally:
		var pair := _best_rally_pair(state, actor, w)
		if not pair.is_empty():
			var pair_score := 0.0
			for slot in pair:
				pair_score += maxf(0.0, _rally_value(state, actor, allies[slot], w))
			if pair_score > best_score:
				return {"kind": "double_rally", "target_slots": pair}
		return best

	var pool := state.skill_pool(actor)
	for i in range(pool.size()):
		var score := _score_skill(state, actor, i, w)
		if score > best_score:
			best_score = score
			best = {"kind": "skill", "target_slot": i}
	return best

# Picks one legal option uniformly, with no idea what any of them do. The floor
# the scorer is measured against in test/bench_faceup.gd.
#
# The option list collapses every attack lane into ONE entry and then aims it
# with _best_attack: which lane an attack hits has never been a random choice
# for any brain here, so a coin flip between "attack" and "use the skill" is
# what this is actually measuring.
static func choose_random(state: FUState, rng: RandomNumberGenerator,
		w: Dictionary = DEFAULTS) -> Dictionary:
	var actor := state.current_card()
	if actor == null:
		return {}
	var options: Array = [{"kind": "attack"}]
	if actor.may_attempt_skill() and not state.enemies_of(actor.side).is_empty():
		if actor.card_name == "King" and actor.double_rally:
			var pair := _best_rally_pair(state, actor, w)
			if not pair.is_empty():
				options.append({"kind": "double_rally", "target_slots": pair})
		else:
			for i in range(state.skill_pool(actor).size()):
				options.append({"kind": "skill", "target_slot": i})
	var pick: Dictionary = options[rng.randi_range(0, options.size() - 1)]
	if pick.kind == "attack":
		var aimed := _best_attack(state, actor, w)
		aimed.erase("score")
		return aimed
	return pick

# EASY — the original priority ladder. The first rung that applies wins and
# nothing is weighed against anything else. That is a coherent, readable game
# plan and a losing one, because a fixed order cannot notice that the skill it
# is about to use is worth less than the attack it gives up. Kept as the easy
# opponent for exactly that reason.
#
# _jack_target below still assumes "shoot is weaker than attack", which the
# retune made false. That stale assumption is left in deliberately: it is part
# of what makes this the easy brain.
static func choose_ladder(state: FUState, w: Dictionary = DEFAULTS) -> Dictionary:
	var actor := state.current_card()
	if actor == null:
		return {}
	var attack := _best_attack(state, actor, w)
	attack.erase("score")
	if not actor.may_attempt_skill() or state.enemies_of(actor.side).is_empty():
		return attack

	var allies := state.allies_of(actor.side)
	var enemies := state.enemies_of(actor.side)

	match actor.card_name:
		"Ace", "Queen":
			# Shield or heal the most-damaged ally, once it is under 60%.
			var hurt := _most_hurt(allies)
			if hurt != null and hurt.hp < hurt.max_hp * 0.6:
				return {"kind": "skill", "target_slot": allies.find(hurt)}
		"Jack":
			var shot := _jack_target(state, actor, enemies)
			if shot >= 0:
				return {"kind": "skill", "target_slot": shot}
		"King":
			if actor.double_rally:
				var pair := _ladder_rally_pair(allies, actor)
				if not pair.is_empty():
					return {"kind": "double_rally", "target_slots": pair}
			else:
				var target := _ladder_rally_target(allies, actor)
				if target >= 0:
					return {"kind": "skill", "target_slot": target}
		"Joker":
			# Trick the most dangerous un-tricked enemy.
			var mark := -1
			for i in range(enemies.size()):
				if enemies[i].tricked:
					continue
				if mark == -1 or enemies[i].atk > enemies[mark].atk:
					mark = i
			if mark >= 0:
				return {"kind": "skill", "target_slot": mark}
	return attack

# ── Attack ────────────────────────────────────────────────────────────────

# The attack, and what it is worth. There is nothing to choose any more - an
# attack hits the lane it faces - so this exists to price it against the skills,
# not to aim it. Every brain still routes through it, including the random one,
# because the SLOT is not a decision for any of them.
static func _best_attack(state: FUState, actor: FUCard, w: Dictionary) -> Dictionary:
	var lane := state.direct_slot(actor.side, state.current_slot)
	if lane < 0:
		return {"kind": "attack", "target_slot": -1, "score": 0.0}
	var target := state.card_at(state.opponent(actor.side), lane)
	return {
		"kind": "attack", "target_slot": lane,
		# attack_seen_by, not attack_value: a trap this side cannot see must not
		# quietly depress the score of its own attack.
		"score": _damage_value(state, actor.side,
			state.attack_seen_by(actor.side, actor), target, w),
	}

# ── Scoring ───────────────────────────────────────────────────────────────

static func _score_skill(state: FUState, actor: FUCard, index: int, w: Dictionary) -> float:
	var pool := state.skill_pool(actor)
	var lanes := state.lane_set(pool.size(), index, actor.rallied)

	match actor.card_name:
		"Jack":
			var dmg := 0.0
			for lane in lanes:
				dmg += _damage_value(state, actor.side, actor.skill_value, pool[lane], w)
			return dmg
		"Queen":
			var healed := 0.0
			var any_heal := false
			var one_hit := _typical_hit(state.enemies_of(actor.side))
			for lane in lanes:
				var ally: FUCard = pool[lane]
				var gain: int = mini(actor.skill_value, ally.max_hp - ally.hp)
				if gain <= 0:
					continue
				any_heal = true
				healed += gain * float(w.heal)
				# Only pulling an ally back out of one-hit range earns the turn.
				if ally.hp <= one_hit and ally.hp + gain > one_hit:
					healed += float(w.save)
			return healed if any_heal else -1.0
		"Ace":
			var shielded := 0.0
			var any_shield := false
			for lane in lanes:
				var gain_s := _shield_gain(actor, pool[lane])
				if gain_s <= 0:
					continue
				any_shield = true
				shielded += gain_s * float(w.shield)
			return shielded if any_shield else -1.0
		"Joker":
			var denied := 0.0
			var any_trick := false
			for lane in lanes:
				var foe: FUCard = pool[lane]
				# An enemy trick is one of OUR traps, so this is a legal read -
				# it is exactly the knowledge the Joker side is entitled to, and
				# it stops the AI spending a turn re-arming a live trap.
				if state.trick_seen_by(actor.side, foe):
					continue
				any_trick = true
				denied += _skill_threat(foe) * float(w.trick)
			return denied if any_trick else -1.0
		"King":
			var target: FUCard = pool[index]
			if target.id == actor.id:
				# A self-rally arms the double rally for NEXT turn, so this
				# turn's attack is given up for something two moves away.
				return _best_rally_gain(state, actor, w) * float(w.self_rally)
			return _rally_value(state, actor, target, w)
	return -1.0

# What rallying `target` is worth: its next skill covers three lanes instead of
# one. Worth nothing if that card would rather attack than use its skill.
static func _rally_value(state: FUState, king: FUCard, target: FUCard, w: Dictionary) -> float:
	# `target.tricked` is deliberately NOT consulted. The target is an ally, and
	# a trick on an ally is the one thing this side cannot see - checking it here
	# would have the King quietly route around traps it has no way of knowing
	# about, which is the AI cheating in the most invisible way available.
	#
	# It also happens to be correct play: a rally is what BREAKS a trick, so
	# rallying a tricked ally is a good move made in ignorance.
	if target == null or target.id == king.id or target.rallied:
		return -1.0
	var pool := state.skill_pool(target)
	if pool.is_empty():
		return -1.0
	var best_single := 0.0
	var best_spread := 0.0
	for i in range(pool.size()):
		best_single = maxf(best_single, _hypothetical(state, target, pool, i, false, w))
		best_spread = maxf(best_spread, _hypothetical(state, target, pool, i, true, w))
	var gain := best_spread - best_single
	return gain * float(w.rally_discount) if gain > 0.0 else -1.0

static func _best_rally_gain(state: FUState, king: FUCard, w: Dictionary) -> float:
	var best := 0.0
	for ally in state.allies_of(king.side):
		best = maxf(best, _rally_value(state, king, ally, w))
	return best

# What `card` would get out of its skill aimed at `index`, with or without a
# rally. Mirrors _score_skill for a card that is not the one acting.
static func _hypothetical(state: FUState, card: FUCard, pool: Array[FUCard], index: int,
		spread: bool, w: Dictionary) -> float:
	var total := 0.0
	var lanes := state.lane_set(pool.size(), index, spread)
	match card.card_name:
		"Jack":
			for lane in lanes:
				total += _damage_value(state, card.side, card.skill_value, pool[lane], w)
		"Queen":
			for lane in lanes:
				total += mini(card.skill_value, pool[lane].max_hp - pool[lane].hp) * float(w.heal)
		"Ace":
			for lane in lanes:
				total += _shield_gain(card, pool[lane]) * float(w.shield)
		"Joker":
			for lane in lanes:
				if not state.trick_seen_by(card.side, pool[lane]):
					total += _skill_threat(pool[lane]) * float(w.trick)
		_:
			return 0.0
	return total

# The two ally slots worth rallying most, for an armed King. Never the King's
# own slot: rallying itself is the arming action, not a target.
static func _best_rally_pair(state: FUState, king: FUCard, w: Dictionary) -> Array:
	var allies := state.allies_of(king.side)
	var first := -1
	var second := -1
	var first_v := 0.0
	var second_v := 0.0
	# A single pass for the top two, rather than scoring every ally twice per
	# comparison inside a sort. Ties keep the lower slot, which is what a stable
	# sort would have done.
	for i in range(allies.size()):
		var v := _rally_value(state, king, allies[i], w)
		if v <= 0.0:
			continue
		if first == -1 or v > first_v:
			second = first
			second_v = first_v
			first = i
			first_v = v
		elif second == -1 or v > second_v:
			second = i
			second_v = v
	var out: Array = []
	if first >= 0:
		out.append(first)
	if second >= 0:
		out.append(second)
	return out

# Shield is stripped before HP, and only the HP actually removed counts full
# price. Breaking a shield is worth something - damage the enemy no longer gets
# to absorb - but less.
#
# `viewer` is what keeps this honest: it prices the hit against the shield the
# viewer KNOWS about, which for an unrevealed enemy shield is none of it. The
# AI therefore reads a shielded card as a clean kill, commits, and finds the
# Ace. That is not a flaw in the valuation - it is the hidden shield working,
# and a player reading the same board is wrong in exactly the same way.
static func _damage_value(state: FUState, viewer: int, damage: int, target: FUCard,
		w: Dictionary) -> float:
	if target == null or not target.alive:
		return 0.0
	var apparent: int = state.shield_seen_by(viewer, target)
	var to_shield: int = mini(damage, apparent)
	var to_hp: int = mini(maxi(0, damage - apparent), target.hp)
	var value: float = to_shield * float(w.shield_break) + to_hp * 1.0
	if damage >= apparent + target.hp:
		value += float(w.kill)
	return value

# What shielding `ally` would actually add, given that the Ace puts down its own
# shield before it acts.
#
# Reading ally.shield straight would price a top-up at zero and refuse it: an
# Ace holding a full 30 on an ally would see "no room" and never renew it, right
# up until the shield was chipped away. The shield it is holding is already
# spoken for - it comes down either way - so what the action buys is the whole
# grant, not the difference.
static func _shield_gain(ace: FUCard, ally: FUCard) -> int:
	var standing: int = 0 if ally.shield_ace == ace.id else ally.shield
	return mini(ace.skill_value, ally.max_shield - standing)

# Roughly what a trap takes off `card`. Two things now, not one: the half of its
# attack that stops landing, plus whatever its skill was worth, because reaching
# for that skill is what costs it the turn.
#
# The King and the Joker have no numeric skill, so for them the denial is only
# the attack - which is also why a trap on one of those is worth measurably less
# than a trap on a Jack.
static func _skill_threat(card: FUCard) -> float:
	var lost_attack: float = card.atk * (1.0 - CardStats.TRICK_ATTACK_MULT)
	if card.card_name in ["Jack", "Queen", "Ace"]:
		return lost_attack + float(card.skill_value)
	return lost_attack

static func _typical_hit(enemies: Array[FUCard]) -> int:
	if enemies.is_empty():
		return 0
	var total := 0
	for e in enemies:
		total += e.atk
	return int(round(float(total) / enemies.size()))

# ── Ladder helpers ────────────────────────────────────────────────────────

static func _most_hurt(cards: Array[FUCard]) -> FUCard:
	if cards.is_empty():
		return null
	var best: FUCard = cards[0]
	for c in cards:
		if (c.max_hp - c.hp) > (best.max_hp - best.hp):
			best = c
	return best

# Shoot only for a kill on an enemy the lane-locked attack cannot reach. This
# is the stale rung: it assumes shoot is the weaker option, which the retune
# made false.
static func _jack_target(state: FUState, actor: FUCard, enemies: Array[FUCard]) -> int:
	var direct := state.direct_slot(actor.side, state.current_slot)
	for i in range(enemies.size()):
		if i != direct and enemies[i].hp <= actor.skill_value:
			return i
	return -1

# Priority order, King excluded — it cannot rally itself as a target.
static func _ladder_rally_target(allies: Array[FUCard], king: FUCard) -> int:
	for priority in ["Jack", "Ace", "Queen", "Joker"]:
		for i in range(allies.size()):
			if allies[i].card_name == priority and not allies[i].rallied and allies[i].id != king.id:
				return i
	return -1

static func _ladder_rally_pair(allies: Array[FUCard], king: FUCard) -> Array:
	var out: Array = []
	for priority in ["Jack", "Ace", "Queen", "Joker"]:
		for i in range(allies.size()):
			if allies[i].card_name == priority and not allies[i].rallied \
					and allies[i].id != king.id and not out.has(i):
				out.append(i)
				if out.size() == 2:
					return out
	return out
