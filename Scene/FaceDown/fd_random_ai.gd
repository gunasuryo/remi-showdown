extends RefCounted
class_name FDRandomAI

# Pure-random face-down opponent: it enumerates every legal action and picks
# one uniformly, with no idea what any of them do. Attack or skill, ally or
# enemy, which slot - all one flat coin flip.
#
# It exists mainly as a floor to measure FDAI against (test/bench_ai.gd). A
# scoring AI that cannot comfortably beat random is not scoring anything
# useful, and random is a more honest floor than the pure-attack policy, which
# turned out to be a genuinely strong strategy rather than a weak one.
#
# Note the option list is naturally skill-heavy: each card contributes one
# attack but one skill option PER SLOT, so a uniform pick over the list uses
# skills far more often than attacks. That is what "pick one of the options at
# random" means here, and it is a large part of why this policy is weak.

# Placement is already a uniform shuffle, so random and scoring share it.
static func place_slots(state: FDState, side: int, rng: RandomNumberGenerator = null) -> Array:
	return FDRules.auto_place(state, side, rng)

static func choose_action(state: FDState, side: int, rng: RandomNumberGenerator = null) -> Dictionary:
	var options: Array = FDRules.legal_actions(state, side)
	if options.is_empty():
		return {}
	var pick: int = rng.randi_range(0, options.size() - 1) if rng != null else randi() % options.size()
	return options[pick]
