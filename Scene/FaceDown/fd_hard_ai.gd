extends RefCounted
class_name FDHardAI

# HARD difficulty. All of the reasoning lives in fd_scorer.gd; this file is the
# weight set and nothing else.
#
# Every number below came out of coordinate descent in test/sweep_ai.gd,
# measured against a three-opponent panel: the pure-attack policy, the EASY
# ladder, and the previously shipped set. 50% against pure-attack would mean
# "no better than never using a skill at all".
#
#   godot --headless --path RemiShowdown --script res://test/sweep_ai.gd -- descend
#
# These are answers to one particular set of numbers, not universal constants.
# RE-SWEEP whenever card_stats.gd, CardStats.SHIELD_LEAK or
# FDRules.DAMAGE_SCALE moves - each of those has already flipped the sign of a
# term at least once.
#
# THREE TRAPS, all of which have bitten this file before:
#
#  1. Watch the `unfinished` column, not just the win rate. It is computed over
#     FINISHED matches, so a setting that stops matches ending scores
#     brilliantly while breaking the game. `kill` at 0.0 currently leaves 16
#     matches in 1200 unresolved, with a 243-round outlier.
#  2. The terms interact. Raising rally_discount flipped the best `kill` from
#     0 to 10; halving the shield leak moved it back to 6. Sweeping each term
#     against a fixed base does not converge - use `descend`.
#  3. Tune against the panel, not one opponent. The pure-attack policy never
#     shields and never uses a skill, so `shield_break` and `trick` cannot fire
#     against it at all and get set to noise.
#
# Measured panel mean at these values: 83.0%.

# See the block comment on each term in fd_scorer.gd.
const WEIGHTS := {
	"kill": 6.0,
	"shield_break": 0.0,
	"shield": 0.4,
	"heal": 0.15,
	"save": 30.0,
	"reveal": 3.0,
	"trick": 4.0,
	"trick_threat": 0.5,
	"rally_discount": 0.7,
	"self_rally": 4.0,
}

static func place_slots(state: FDState, side: int, rng: RandomNumberGenerator = null) -> Array:
	return FDScorer.place_slots(state, side, rng)

static func choose_action(state: FDState, side: int, rng: RandomNumberGenerator = null) -> Dictionary:
	return FDScorer.choose_action(state, side, FDScorer.weights(WEIGHTS), rng)
