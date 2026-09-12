extends RefCounted
class_name FDLadderAI

# The EASY face-down opponent: the PRD 11 priority ladder, exactly as first
# written - emergency heal, King rescue, Jack snipe, Joker trick, rally setup,
# lane attack, fallback. The first rung that applies wins; nothing is compared
# against anything else.
#
# It is kept because it is the RIGHT SHAPE for an easy opponent. It plays a
# coherent, readable game - it heals hurt allies, snipes the enemy Queen, frees
# nullified friends - it just plays it badly, because a fixed priority order
# cannot notice that the skill it is about to use is worth less than the attack
# it is giving up. That reads as a beatable opponent rather than a broken one,
# which is more than can be said for picking at random.
#
# Same hidden-information guarantee as FDAI: enemy slots are only ever read
# through FDState.observe().

const NONE := FDCard.NONE

# Living cards first, padded with corpses, then the row shuffled (PRD 8.1).
static func place_slots(state: FDState, side: int, rng: RandomNumberGenerator = null) -> Array:
	return FDRules.auto_place(state, side, rng)

static func choose_action(state: FDState, side: int, rng: RandomNumberGenerator = null) -> Dictionary:
	var mine: Array = state.unacted(side)
	if mine.is_empty():
		return {}
	var view: Array = state.observe_row(side)

	var a: Dictionary = _emergency_heal(state, side, mine)
	if not a.is_empty():
		return a
	a = _king_rescue(state, side, mine)
	if not a.is_empty():
		return a
	a = _jack_snipe(mine, view, rng)
	if not a.is_empty():
		return a
	a = _joker_trick(mine, view, rng)
	if not a.is_empty():
		return a
	a = _rally_setup(state, side, mine, rng)
	if not a.is_empty():
		return a
	a = _lane_attack(state, mine, view)
	if not a.is_empty():
		return a
	return _fallback(state, mine)

# -- 1. Emergency heal -----------------------------------------------------

static func _emergency_heal(state: FDState, side: int, mine: Array) -> Dictionary:
	var queen := _unacted(mine, "Queen")
	if queen == null or not queen.can_use_skill():
		return {}
	var worst: FDCard = null
	for c in state.living(side):
		if state.slot_of(c) == -1 or c.hp >= c.max_hp:
			continue
		if float(c.hp) / float(c.max_hp) > 0.4:
			continue
		if worst == null or c.hp < worst.hp:
			worst = c
	if worst == null:
		return {}
	return _skill(queen, state.slot_of(worst))

# -- 2. King rescue --------------------------------------------------------

static func _king_rescue(state: FDState, side: int, mine: Array) -> Dictionary:
	var king := _unacted(mine, "King")
	if king == null or not king.can_use_skill():
		return {}
	for want in ["Jack", "Queen", "Joker", "Ace"]:
		for c in state.living(side):
			if c.card_name == want and c.nullified and state.slot_of(c) != -1:
				return _skill(king, state.slot_of(c))
	return {}

# -- 3. Jack snipe ---------------------------------------------------------

static func _jack_snipe(mine: Array, view: Array, rng: RandomNumberGenerator) -> Dictionary:
	var jack := _unacted(mine, "Jack")
	if jack == null or not jack.can_use_skill():
		return {}
	var slot := _best_known_enemy(view, ["Queen"])
	if slot == -1:
		slot = _probe(view, rng)
	if slot == -1:
		return {}
	return _skill(jack, slot)

# -- 4. Joker trick --------------------------------------------------------

static func _joker_trick(mine: Array, view: Array, rng: RandomNumberGenerator) -> Dictionary:
	var joker := _unacted(mine, "Joker")
	if joker == null or not joker.can_use_skill():
		return {}
	var slot := -1
	for want in ["Queen", "Ace", "Jack"]:
		for o in view:
			if _is_live_target(o) and o.card_name == want:
				slot = o.slot
				break
		if slot != -1:
			break
	if slot == -1:
		slot = _probe(view, rng)
	if slot == -1:
		return {}
	return _skill(joker, slot)

# -- 5. King rally setup ---------------------------------------------------

static func _rally_setup(state: FDState, side: int, mine: Array, rng: RandomNumberGenerator) -> Dictionary:
	if state.living_count(side) < 3:
		return {}
	var king := _unacted(mine, "King")
	if king == null or not king.can_use_skill():
		return {}
	var king_slot := state.slot_of(king)
	if king_slot == -1:
		return {}

	if king.king_plus:
		var carrier := _carrier(state, side, king, ["Jack", "Queen"])
		if carrier != null:
			return _skill(king, state.slot_of(carrier))

	var anyone_rallied := false
	for c in state.living(side):
		if c.has_rally():
			anyone_rallied = true
			break
	if not anyone_rallied and _chance(rng, 0.35):
		return _skill(king, king_slot)  # self-rally arms rally+ (PRD 9.2)

	var target := _carrier(state, side, king, ["Jack", "Queen", "Ace", "Joker"])
	if target == null:
		return {}
	return _skill(king, state.slot_of(target))

# -- 6. Lane-locked attack -------------------------------------------------
# EASY never uses the new adjacent option - it only ever swings straight
# ahead. Giving away that choice is part of what makes it the easy brain.

static func _lane_attack(state: FDState, mine: Array, view: Array) -> Dictionary:
	var best: FDCard = null
	var best_slot := -1
	var best_score := -99999
	for c in mine:
		var slot := state.slot_of(c)
		if slot < 0 or slot >= view.size():
			continue
		var score := _lane_score(view[slot], c)
		if score > best_score:
			best_score = score
			best = c
			best_slot = slot
	if best == null:
		return {}
	return {"card_id": best.id, "kind": "attack", "target_slot": best_slot}

static func _lane_score(o: Dictionary, attacker: FDCard) -> int:
	if o.get("empty", false):
		return -50
	if not o.get("known", false):
		return 10
	if not o.get("alive", false):
		return -100
	var score := 50
	if o.get("card_name", "") == "Queen":
		score += 25
	if int(o.get("hp", 0)) <= attacker.atk:
		score += 40
	return score

# -- 7. Fallback -----------------------------------------------------------

static func _fallback(state: FDState, mine: Array) -> Dictionary:
	for c in mine:
		var slot := state.slot_of(c)
		if slot != -1:
			return {"card_id": c.id, "kind": "attack", "target_slot": slot}
	return {}

# -- Helpers ---------------------------------------------------------------

static func _skill(actor: FDCard, target_slot: int) -> Dictionary:
	return {"card_id": actor.id, "kind": "skill", "target_slot": target_slot}

static func _unacted(mine: Array, want: String) -> FDCard:
	for c in mine:
		if c.card_name == want:
			return c
	return null

static func _carrier(state: FDState, side: int, king: FDCard, wants: Array) -> FDCard:
	for want in wants:
		for c in state.living(side):
			if c.card_name != want or c.id == king.id:
				continue
			if c.has_rally() or state.slot_of(c) == -1:
				continue
			return c
	return null

static func _best_known_enemy(view: Array, prefer: Array) -> int:
	var slot := -1
	var best := 99999
	for o in view:
		if not _is_live_target(o):
			continue
		var rank: int = int(o.hp)
		if o.card_name in prefer:
			rank -= 1000
		if rank < best:
			best = rank
			slot = o.slot
	return slot

static func _is_live_target(o: Dictionary) -> bool:
	return not o.get("empty", false) and o.get("known", false) and o.get("alive", false)

static func _probe(view: Array, rng: RandomNumberGenerator) -> int:
	var options: Array = []
	for o in view:
		if not o.get("empty", false) and not o.get("known", false):
			options.append(o.slot)
	if options.is_empty():
		return -1
	if rng == null:
		return options[randi() % options.size()]
	return options[rng.randi_range(0, options.size() - 1)]

static func _chance(rng: RandomNumberGenerator, p: float) -> bool:
	if rng == null:
		return randf() < p
	return rng.randf() < p
