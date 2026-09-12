extends RefCounted
class_name FDAI

# NORMAL difficulty. All of the reasoning lives in fd_scorer.gd; this file sets
# the weights and the handicap.
#
# WHY THE HANDICAP AND NOT A SECOND WEIGHT SET
# NORMAL used to be its own 342-line copy of the scorer whose weights had
# simply been left on an older stat table. That is not a difficulty setting,
# it is a stale file: it was weaker only by accident, it got no better when
# HARD did, and nothing about it was tunable. Two retunes of card_stats.gd
# later it was scoring 61% where HARD scored 88%, and neither number had been
# chosen by anyone.
#
# NORMAL now runs HARD's scorer on HARD's weights and is held back by one
# explicit, measurable knob: how often it takes a move it can see is not the
# best one. That makes the gap a decision rather than a side effect, keeps
# NORMAL improving whenever HARD does, and means a player who beats NORMAL has
# beaten a real opponent having an off day rather than a mistuned one.
#
# The blunder is drawn from the RANKED action list, so a misplay is the second
# or third best move on the board - a Queen that heals when it should have
# swung, not a Queen that shields a corpse. Sampling the legal list instead
# looked like the AI had forgotten the rules.

# Same numbers HARD plays; see fd_hard_ai.gd for the sweep that produced them.
const WEIGHTS := FDHardAI.WEIGHTS

# Swept in test/sweep_ai.gd (`-- blunder`). The curve against the pure-attack
# policy, which is roughly what a player attacking with everything looks like:
#
#   rate   0.0    0.1    0.2    0.3    0.4    0.5    0.65   0.8    1.0
#   win   96.8%  93.0%  90.3%  84.0%  76.8%  69.8%  51.0%  38.8%  15.3%
#
# 0.5 puts NORMAL at ~70%: a player who just attacks wins about three matches
# in ten. HARD beats NORMAL roughly 86:14 at this setting, which is lopsided,
# but that head-to-head is an internal number - nobody plays it. The figure a
# player actually feels is the one against their own naive strategy, so that is
# the one this is tuned to.
const BLUNDER_RATE: float = 0.50
const BLUNDER_DEPTH: int = 3

static func place_slots(state: FDState, side: int, rng: RandomNumberGenerator = null) -> Array:
	return FDScorer.place_slots(state, side, rng)

static func choose_action(state: FDState, side: int, rng: RandomNumberGenerator = null) -> Dictionary:
	return FDScorer.choose_action(state, side, FDScorer.weights(WEIGHTS), rng,
		BLUNDER_RATE, BLUNDER_DEPTH)
