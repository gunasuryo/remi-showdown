extends RefCounted
class_name FDScorer

# The face-down scoring engine, shared by NORMAL (fd_ai.gd) and HARD
# (fd_hard_ai.gd). Like fd_rules.gd it touches no scene and no node, so whole
# matches run headless in test/bench_ai.gd and test/sweep_ai.gd.
#
# WHY SCORING AND NOT A PRIORITY LADDER
# The PRD 11 ladder ("emergency heal, then King rescue, then Jack snipe, then
# Joker trick, then rally setup, then attack") spends nearly every card's action
# on a skill. Against an opponent that simply attacks with everything it lost
# 400 matches out of 400: rallies and tricks produce no damage, and a card that
# heals is a card that did not remove an enemy action. Only damage removes enemy
# actions, and actions are the real currency here. So every legal action is
# priced in damage-equivalent points and the best one is played. The ladder's
# good instincts survive as scoring terms - a Queen still heals to deny a kill,
# a King still rallies a Jack when the maths works - but they now have to beat
# attacking rather than pre-empt it.
#
# WHY ONE FILE FOR BOTH DIFFICULTIES
# NORMAL and HARD used to be two 342-line files that were byte-identical below
# their weight blocks. They had drifted in the only way that mattered - NORMAL's
# weights were left on a stat table two retunes old - and every bug fix had to
# be made twice or not at all. The weights are now data, passed in as a
# dictionary, and the difficulty files hold nothing but their numbers.
#
# TWO TRICK BUGS, both found because a player reported beating HARD with a
# trick-heavy game that the simulated equivalent loses with. Worth remembering
# as a pattern: the scorer was not undervaluing tricks by a constant, it was
# blind to which target and which moment mattered.
#   1. The bonus for tricking applied to ["Queen", "Ace", "King"] and excluded
#      the Jack - the card that deals 62% of all damage in the game.
#   2. There was no timing model at all, so it spent tricks on cards that had
#      already acted, where the seal lapses before the victim's next turn.
# Modelling both took the trick from "never worth casting" to a term worth
# about 1.3 points, and the Joker from using its skill 8% of the time to 38%.
#
# HIDDEN INFORMATION: everything this file knows about enemy SLOTS comes from
# FDState.observe(), which only returns revealed ones, so it cannot cheat by
# construction. It also reads the enemy's living COUNT, which is public - board
# width is derived from it and every death is announced.

const NONE := FDCard.NONE

# What a trick is worth against a card that has already taken its turn this
# round: the seal lapses when the Joker next acts, so most of the value is gone.
const ACTED_DISCOUNT: float = 0.25

# Tearing a rally off a card, in the same units as _trick_threat().
const RALLY_STRIP_VALUE: float = 12.0

# Every weight the scorer understands, with the value used when a difficulty
# does not name it. Units are damage-equivalent points: 1.0 == removing one
# point of enemy HP.
const DEFAULTS := {
	# A kill removes one enemy action every round for the rest of the match.
	"kill": 0.0,
	# Breaking shield is HP the enemy has to spend a later action replacing,
	# but it is not HP off the board today.
	"shield_break": 0.5,
	# Granting shield. Rented, not owned: it is held up by the Ace that cast
	# it, lapses when that Ace acts again, and dies with it.
	"shield": 0.4,
	# Per point of HP restored.
	"heal": 0.0,
	# Flat bonus for lifting an ally back out of one-hit-kill range.
	"save": 20.0,
	# Learning what sits in an unknown lane has a little value of its own.
	"reveal": 1.5,
	# A trick only pays off if the target was going to use a skill.
	"trick": 0.0,
	# Multiplies _trick_threat(): how much the trick's value scales with how
	# dangerous the card being tricked actually is.
	"trick_threat": 0.0,
	# A rally is a bet on a future action; the King's own attack is certain.
	"rally_discount": 0.5,
	"self_rally": 4.0,
}

static func weights(overrides: Dictionary = {}) -> Dictionary:
	var w: Dictionary = DEFAULTS.duplicate()
	for k in overrides:
		w[k] = overrides[k]
	return w

# -- Placement -------------------------------------------------------------

# Living cards first, padded with corpses, then the row shuffled (PRD 8.1).
# A uniformly random row is the right answer against a lane-locked attacker:
# any pattern the opponent could learn would be worth more to them than to us,
# and reveals reset every round so there is no history to exploit either way.
static func place_slots(state: FDState, side: int, rng: RandomNumberGenerator = null) -> Array:
	return FDRules.auto_place(state, side, rng)

# -- Action choice ---------------------------------------------------------

# Returns {"card_id", "kind", "target_slot"}, or {} when the side is finished.
#
# `blunder` is the difficulty handicap: with that probability the chosen action
# is drawn from the next `blunder_depth` best instead of the best. It samples
# from the ranked list rather than from the legal list on purpose - a weaker
# opponent should look like it read the board and chose poorly, not like it
# forgot the rules.
static func choose_action(state: FDState, side: int, w: Dictionary,
		rng: RandomNumberGenerator = null,
		blunder: float = 0.0, blunder_depth: int = 3) -> Dictionary:
	var ranked: Array = rank_actions(state, side, w)
	if ranked.is_empty():
		return _fallback(state, side)

	var pick: int = 0
	if blunder > 0.0 and ranked.size() > 1:
		var roll: float = rng.randf() if rng != null else randf()
		if roll < blunder:
			var top: int = min(blunder_depth, ranked.size() - 1)
			pick = rng.randi_range(1, top) if rng != null else (randi() % top) + 1
	return ranked[pick]["action"]

# Every legal action this side could take, best first. Exposed so the sweep
# harness and the difficulty tiers can look at the ranking, not just the pick.
static func rank_actions(state: FDState, side: int, w: Dictionary) -> Array:
	var out: Array = []
	for c in state.unacted(side):
		var slot: int = state.slot_of(c)
		if slot == -1:
			continue

		var swing: Dictionary = best_attack(state, side, c, slot, w)
		out.append({
			"score": swing.score,
			"action": {"card_id": c.id, "kind": "attack", "target_slot": swing.lane},
		})

		if not c.can_use_skill():
			continue
		for target in range(state.board_size):
			out.append({
				"score": _score_skill(state, side, c, target, w),
				"action": {"card_id": c.id, "kind": "skill", "target_slot": target},
			})

	out.sort_custom(func(a, b): return a.score > b.score)
	return out

static func _fallback(state: FDState, side: int) -> Dictionary:
	for c in state.unacted(side):
		var slot: int = state.slot_of(c)
		if slot != -1:
			return {"card_id": c.id, "kind": "attack", "target_slot": slot}
	return {}

# -- Attack ----------------------------------------------------------------

# An attack may hit its own lane or either neighbour, the neighbours at a
# penalty. Returns the best of the three so the caller can both score it and
# know which lane to name.
static func best_attack(state: FDState, side: int, c: FDCard, slot: int, w: Dictionary) -> Dictionary:
	var best_score: float = -1.0e9
	var best_lane: int = slot
	for lane in FDRules.attack_slots(state, slot):
		var damage: int = _scaled(state, c.attack_value())
		if lane != slot:
			damage = max(1, int(round(damage * CardStats.ADJACENT_MULT)))
		var score: float = _lane_damage_value(state, side, lane, damage, w)
		if score > best_score:
			best_score = score
			best_lane = lane
	return {"score": best_score, "lane": best_lane}

# -- Skills ----------------------------------------------------------------

static func _score_skill(state: FDState, side: int, c: FDCard, target: int, w: Dictionary) -> float:
	match c.card_name:
		"Jack":
			return _score_shoot(state, side, c, target, w)
		"Ace":
			return _score_shield(state, side, c, target, w)
		"Queen":
			return _score_heal(state, side, c, target, w)
		"King":
			return _score_rally(state, side, c, target, w)
		"Joker":
			return _score_trick(state, side, c, target, w)
	return -1.0

# The one action in the game that picks its own target, which is what lets the
# AI finish off a revealed card that no lane happens to face.
static func _score_shoot(state: FDState, side: int, c: FDCard, target: int, w: Dictionary) -> float:
	var lanes: Array = _lanes(state, c, target)
	# A rallied shot covers three lanes for half each, so the scorer has to ask
	# the rules what one lane actually takes rather than assume the printed
	# value. FDRules.skill_output is the single authority for that.
	var spread: int = FDRules.Spread.SINGLE if lanes.size() <= 1 else FDRules.Spread.THREE
	var dmg: int = _scaled(state, FDRules.skill_output(c.card_name, c.skill_value, spread))
	var total: float = 0.0
	for lane in lanes:
		total += _lane_damage_value(state, side, lane, dmg, w)
	return total

static func _score_shield(state: FDState, side: int, c: FDCard, target: int, w: Dictionary) -> float:
	var total: float = 0.0
	var any := false
	var lanes: Array = _lanes(state, c, target)
	# A rallied shield spreads at a reduced value per ally, exactly like a
	# rallied shot; pricing it at the printed grant would over-value spreading.
	var spread: int = FDRules.Spread.SINGLE if lanes.size() <= 1 else FDRules.Spread.THREE
	var grant: int = FDRules.skill_output(c.card_name, c.skill_value, spread)
	for lane in lanes:
		var ally: FDCard = state.card_at(side, lane)
		if ally == null or not ally.alive:
			continue
		# An Ace drops the shields it is already holding up before granting a
		# new one (FDRules.resolve step 2b), so re-shielding an ally this Ace
		# already covers is worth only the top-up. Scoring the raw grant let
		# the Ace re-cast on the same full target for ever.
		var held: int = ally.shield if ally.shield_ace == c.id else 0
		var standing: int = ally.shield - held
		var gain: int = min(_scaled(state, grant),
			_scaled(state, ally.max_shield) - standing) - held
		if gain <= 0:
			continue
		any = true
		total += gain * w.shield
	return total if any else -1.0

static func _score_heal(state: FDState, side: int, c: FDCard, target: int, w: Dictionary) -> float:
	var total: float = 0.0
	var any := false
	var one_hit: int = _typical_enemy_hit(state, side)
	for lane in _lanes(state, c, target):
		var ally: FDCard = state.card_at(side, lane)
		if ally == null or not ally.alive:
			continue
		var gain: int = min(c.skill_value, ally.max_hp - ally.hp)
		if gain <= 0:
			continue
		any = true
		total += gain * w.heal
		# Topping up a healthy card is close to worthless - the HP was never
		# going to be spent. Lifting one back out of one-hit-kill range is the
		# only time a heal beats an attack.
		if ally.hp <= one_hit and ally.hp + gain > one_hit:
			total += w.save
	return total if any else -1.0

# A rally is released the moment its King acts again (PRD 9.7 step 1), and the
# King acts once per round - so a rally granted to a card that has ALREADY
# acted this round is dead before it can ever be spent. That single condition
# is most of what makes rallying worth anything.
static func _score_rally(state: FDState, side: int, king: FDCard, target: int, w: Dictionary) -> float:
	if king.king_plus:
		# Armed: this rally lands on every living ally in a three-lane spread,
		# so it is worth the sum of what each of them gains, not just one.
		var total: float = 0.0
		var any := false
		for lane in FDRules._lane_set(state, target, FDRules.Spread.THREE):
			var gain: float = _rally_gain(state, side, king, lane, w)
			if gain <= 0.0:
				continue
			any = true
			total += gain
		return (total * w.rally_discount) if any else -1.0

	if target >= 0 and target < state.board_size:
		var self_card: FDCard = state.card_at(side, target)
		if self_card != null and self_card.id == king.id:
			return w.self_rally

	var one: float = _rally_gain(state, side, king, target, w)
	return (one * w.rally_discount) if one > 0.0 else -1.0

# What rallying the ally in `lane` is worth, before the discount. A rally is
# released the moment its King acts again (PRD 9.7 step 1), and the King acts
# once per round - so a rally granted to a card that has ALREADY acted this
# round is dead before it can ever be spent. That single condition is most of
# what makes rallying worth anything.
static func _rally_gain(state: FDState, side: int, king: FDCard, lane: int, w: Dictionary) -> float:
	var ally: FDCard = state.card_at(side, lane)
	if ally == null or not ally.alive or ally.id == king.id:
		return 0.0

	# Freeing a tricked ally is now the whole action rather than a free extra
	# (FDRules._do_rally), so it has to be priced as one. It is worth exactly
	# what the trick took: half their attack plus the skill it sealed - the same
	# number _score_trick pays to inflict it, because the two are mirror images.
	#
	# Without this the scorer refused to free anyone at all: the old guard below
	# rejects every ally that cannot use its skill, which is precisely the set
	# of tricked allies.
	if ally.nullified:
		var freed: float = _trick_threat(ally.card_name)
		if state.has_acted(ally):
			freed *= ACTED_DISCOUNT
		return freed * w.trick_threat

	if state.has_acted(ally) or ally.has_rally() or not ally.can_use_skill():
		return 0.0

	# What the ally's skill gains from covering three lanes instead of one.
	var best_rallied: float = -1.0
	var best_single: float = -1.0
	for slot in range(state.board_size):
		best_rallied = max(best_rallied, _skill_value_with_spread(state, side, ally, slot, FDRules.Spread.THREE, w))
		best_single = max(best_single, _skill_value_with_spread(state, side, ally, slot, FDRules.Spread.SINGLE, w))
	if best_rallied <= 0.0:
		return 0.0
	return best_rallied - max(0.0, best_single)

static func _score_trick(state: FDState, side: int, c: FDCard, target: int, w: Dictionary) -> float:
	var total: float = 0.0
	var any := false
	for lane in _lanes(state, c, target):
		var o: Dictionary = state.observe(side, lane)
		if not _is_live_target(o):
			continue

		var carries_rally: bool = str(o.get("rally", "")) != ""
		# Sealing a card that is already sealed does nothing. The one reason to
		# trick it anyway is to tear a rally off it, which is a separate layer.
		if bool(o.get("tricked", false)) and not carries_rally:
			continue

		any = true
		var threat: float = _trick_threat(str(o.card_name))

		# TIMING, which this scorer used to ignore entirely and which is most
		# of why tricking measured as worthless. The seal lifts when the Joker
		# acts again - once per round - so a trick on a card that has ALREADY
		# acted this round is spent covering a turn that has been and gone,
		# and the victim is free before its next one. Tricking a card that has
		# not acted yet denies it the turn it is about to take.
		#
		# `acted` is public: acting is what reveals a card in the first place,
		# so every enemy known to have acted is one we watched act. This is the
		# same guard _score_rally has always had on its own targets.
		if bool(o.get("acted", false)):
			threat *= ACTED_DISCOUNT

		# Stripping a rally is worth what the rally was worth to them.
		if carries_rally:
			threat += RALLY_STRIP_VALUE

		total += w.trick + threat * w.trick_threat
	return total if any else -1.0

# What tricking THIS card takes off the board, in damage-equivalent points.
#
# This used to be a flat bonus for hitting a "support" card - the list was
# ["Queen", "Ace", "King"], which excluded the Jack. That was exactly backwards.
# The Jack deals 62% of all damage in this game: tricking it halves the highest
# attack on the board AND removes the only free-targeting damage skill AND
# starves the rally engine, since 95% of all rallied skills are Shoot+. It was
# the single most valuable trick available and it scored lowest.
#
# The value is now derived rather than listed, so it cannot go stale the next
# time the stat table moves: half the attack is denied outright (a tricked card
# swings at TRICK_ATTACK_MULT), plus whatever its skill was worth.
static func _trick_threat(card_name: String) -> float:
	var atk: int = CardStats.atk_of(card_name, CardStats.FACE_DOWN)
	var tricked: int = max(1, int(round(atk * CardStats.TRICK_ATTACK_MULT)))
	var denied_atk: float = float(atk - tricked)

	# Skills with a number on them are worth roughly that number. The King and
	# the Joker have no numeric skill, so they are priced by what they enable:
	# a rally is the engine behind the Jack, a trick is worth what ours is.
	var skill: float = float(CardStats.skill_of(card_name, CardStats.FACE_DOWN))
	match card_name:
		"King":
			skill = 18.0
		"Joker":
			skill = 10.0
	return denied_atk + skill

# -- Valuation helpers -----------------------------------------------------

# What one hit of `dmg` into `lane` of the enemy row is worth, using only what
# observe() is willing to say about that lane.
static func _lane_damage_value(state: FDState, side: int, lane: int, dmg: int, w: Dictionary) -> float:
	var o: Dictionary = state.observe(side, lane)
	if o.get("empty", false):
		return 0.0
	if not o.get("known", false):
		return _unknown_lane_value(state, side, dmg, w)
	if not o.get("alive", false):
		return 0.0   # a decoy the AI can see: the action would be thrown away
	return _damage_value(dmg, int(o.get("shield", 0)), int(o.get("hp", 0)), w)

# Prices one hit using the SAME arithmetic FDCard.take_hit applies, leak and
# all. The old model treated shield as flat absorption, which got two things
# wrong: it over-valued hitting a shielded card, since a fixed share of every blow
# reaches HP and shield never absorbs the whole hit; and it could not see a
# kill through a shield at all - a card on 3 HP behind a 30 shield dies to a
# big enough hit purely on leak, and the AI scored that as a non-event.
static func _damage_value(dmg: int, shield: int, hp: int, w: Dictionary) -> float:
	if dmg <= 0:
		return 0.0
	var absorbed: int = min(shield, dmg - FDCard.leak_of(dmg))
	var hp_lost: int = min(dmg - absorbed, hp)
	var value: float = absorbed * w.shield_break + hp_lost * 1.0
	if hp_lost >= hp:
		value += w.kill
	return value

# An unrevealed lane is worth the chance it holds something living. The AI
# knows how many enemies are alive and how many it has already revealed, so the
# odds on the rest follow without ever looking at a card.
static func _unknown_lane_value(state: FDState, side: int, dmg: int, w: Dictionary) -> float:
	var unknown: int = 0
	var known_living: int = 0
	for o in state.observe_row(side):
		if o.get("empty", false):
			continue
		if o.get("known", false):
			if o.get("alive", false):
				known_living += 1
		else:
			unknown += 1
	if unknown == 0:
		return 0.0
	var hidden_living: int = max(0, state.living_count(state.opponent(side)) - known_living)
	var odds: float = clampf(float(hidden_living) / float(unknown), 0.0, 1.0)
	return odds * float(dmg) + w.reveal

# The value `ally` would get out of its skill aimed at `slot` with `spread`.
# Used only to price a rally, so it deliberately reuses the same scorers.
static func _skill_value_with_spread(state: FDState, side: int, ally: FDCard, slot: int, spread: int, w: Dictionary) -> float:
	var lanes: Array = FDRules._lane_set(state, slot, spread)
	var total: float = 0.0
	match ally.card_name:
		"Jack":
			# Same correction where a rally is being PRICED: the gain from
			# rallying a Jack is three half-strength lanes, not three full ones.
			var dmg: int = _scaled(state, FDRules.skill_output(ally.card_name, ally.skill_value, spread))
			for lane in lanes:
				total += _lane_damage_value(state, side, lane, dmg, w)
		"Queen":
			for lane in lanes:
				var a: FDCard = state.card_at(side, lane)
				if a != null and a.alive:
					total += min(ally.skill_value, a.max_hp - a.hp) * w.heal
		"Ace":
			for lane in lanes:
				var b: FDCard = state.card_at(side, lane)
				if b != null and b.alive:
					total += min(_scaled(state, ally.skill_value),
						_scaled(state, b.max_shield) - b.shield) * w.shield
		"Joker":
			for lane in lanes:
				if _is_live_target(state.observe(side, lane)):
					total += w.trick
		_:
			return 0.0
	return total

# Which lanes a card's skill covers right now, honouring any rally it carries.
# FDRules._lane_set stays the authority so the two cannot drift apart.
static func _lanes(state: FDState, c: FDCard, center: int) -> Array:
	var spread: int = FDRules.Spread.THREE if c.has_rally() else FDRules.Spread.SINGLE
	# A King never carries a rally; what widens ITS rally is its own armed
	# rally+, which is handled in _score_rally.
	if c.card_name == "King":
		spread = FDRules.Spread.SINGLE
	return FDRules._lane_set(state, center, spread)

# Roughly what one hit from the enemy lands for, used to judge whether an ally
# is one hit from dying. Averages the enemy's LIVING cards only: once the
# hardest hitters are dead the survivors threaten less, and averaging the whole
# stat table kept the Queen panic-healing against a board that could no longer
# reach her. Card attack values are public, so this leaks nothing.
static func _typical_enemy_hit(state: FDState, side: int) -> int:
	var total: int = 0
	var n: int = 0
	for c in state.living(state.opponent(side)):
		total += c.attack_value()
		n += 1
	if n == 0:
		return 0
	return _scaled(state, int(round(float(total) / float(n))))

static func _scaled(state: FDState, raw: int) -> int:
	return max(0, int(round(raw * state.damage_scale)))

static func _is_live_target(o: Dictionary) -> bool:
	return not o.get("empty", false) and o.get("known", false) and o.get("alive", false)
