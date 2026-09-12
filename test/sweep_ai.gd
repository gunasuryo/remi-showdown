extends SceneTree

# Weight sweep for the face-down scorer.
#
#   godot --headless --path RemiShowdown --script res://test/sweep_ai.gd -- descend
#   godot --headless --path RemiShowdown --script res://test/sweep_ai.gd -- save
#   godot --headless --path RemiShowdown --script res://test/sweep_ai.gd -- blunder
#
# `descend` is the one that produces a weight set: coordinate descent, taking
# the best value for each term and CARRYING IT FORWARD into the next term.
# Sweeping every term against a fixed base does not converge here, because the
# terms interact strongly - raising rally_discount to 0.7 flipped the best
# `kill` from 0.0 to 10.0, and the two together shortened matches that either
# alone lengthened. A one-at-a-time table off a stale base reads as noise.
#
# One weight at a time, everything else held at the current HARD set, measured
# against a PANEL of three opponents:
#
#   blind  - pure attack, every card swings at its own lane. The policy that
#            beats every priority ladder. 50% here means "no better than never
#            using a skill at all".
#   ladder - FDLadderAI, the EASY tier: a skill-heavy priority order.
#   ref    - the currently shipped HARD weights, so a candidate has to beat
#            what is already in the game, not just beat a punchbag.
#
# The panel is not decoration. Against blind alone several terms cannot fire at
# all - blind never shields, so shield_break scores identically at 0.0 and 1.0,
# and it never uses a skill, so trick has nothing to deny. Tuning on blind by
# itself silently sets those terms to noise.
#
# READ THE `unfin` COLUMN. The win rate is computed over FINISHED matches, so a
# setting that stops matches ending scores brilliantly while breaking the game.
# Any row with a non-zero unfin is disqualified no matter how good it looks -
# this is how RALLY_DISCOUNT 0.75 once "measured" 86%.
#
# Sides swap every match so the round-1 leader advantage cancels out.

const MATCHES: int = 400
const GUARD: int = 8000

const PANEL := ["blind", "ladder", "ref"]

# Which weights to sweep and over what, when run with no argument.
const GRID := {
	"kill": [0.0, 6.0, 10.0, 16.0, 24.0],
	"shield": [0.0, 0.2, 0.4, 0.6, 0.9],
	"shield_break": [0.0, 0.35, 0.7, 1.0],
	"heal": [0.0, 0.15],
	"save": [16.0, 20.0, 24.0, 30.0],
	"reveal": [0.0, 1.5, 3.0],
	"trick": [0.0, 4.0, 8.0],
	"trick_threat": [0.0, 0.15, 0.3, 0.5, 0.8],
	"rally_discount": [0.5, 0.7, 0.85, 1.0],
	"self_rally": [0.0, 4.0, 10.0, 18.0],
}

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var base: Dictionary = FDScorer.weights(FDHardAI.WEIGHTS)

	print("sweep - %d matches per setting, damage_scale %.1f" % [MATCHES, FDRules.DAMAGE_SCALE])
	print("%-12s %s" % ["", _header()])
	_row("  as shipped", _panel(base, 0.0))

	if args.size() > 0 and str(args[0]) == "blunder":
		_sweep_blunder(base)
		quit(0)
		return

	if args.size() > 0 and str(args[0]) == "descend":
		_descend(base)
		quit(0)
		return

	var keys: Array = GRID.keys() if args.is_empty() else [str(args[0])]
	for key in keys:
		if not GRID.has(key):
			print("no grid for '%s'" % key)
			continue
		print("")
		print("%s  (currently %s)" % [key, str(base[key])])
		for v in GRID[key]:
			var w: Dictionary = base.duplicate()
			w[key] = float(v)
			_row("  %-6s" % str(v), _panel(w, 0.0))
	quit(0)

# Coordinate descent over GRID. Each term is swept against the best set found
# so far, and the winner is kept before moving to the next term. Two passes:
# the second catches terms whose best value changed once a later term moved.
#
# The objective is the panel MEAN, but a candidate is rejected outright if it
# leaves any match unfinished. That guard is not optional - the win rate is
# computed over finished matches only, so "never let the game end" scores as a
# perfect strategy.
func _descend(base: Dictionary) -> void:
	var best: Dictionary = base.duplicate()
	var best_score: float = _panel(best, 0.0).mean

	for pass_no in range(2):
		print("")
		print("=== pass %d ===" % (pass_no + 1))
		for key in GRID.keys():
			var improved_to = null
			for v in GRID[key]:
				if is_equal_approx(float(v), float(best[key])):
					continue
				var w: Dictionary = best.duplicate()
				w[key] = float(v)
				var p: Dictionary = _panel(w, 0.0)
				var tag: String = ""
				if p.unfin > 0:
					tag = "  REJECTED (unfinished)"
				elif p.mean > best_score:
					tag = "  <- best"
					best_score = p.mean
					improved_to = float(v)
					best = w
				_row("  %-6s %-8s" % [key, str(v)], p)
				if tag != "":
					print("      %s" % tag.strip_edges())
			if improved_to != null:
				print("    %s -> %s" % [key, str(improved_to)])
		print("")
		print("pass %d best: mean %.1f%%" % [pass_no + 1, best_score])
		_print_set(best)

func _print_set(w: Dictionary) -> void:
	var keys: Array = FDScorer.DEFAULTS.keys()
	keys.sort()
	for k in keys:
		print("    \"%s\": %s," % [k, str(w[k])])

# NORMAL's handicap: how often it takes a move it can see is not the best one.
func _sweep_blunder(base: Dictionary) -> void:
	print("")
	print("blunder rate (depth 3), HARD weights throughout")
	print("%-12s %s" % ["", _header()])
	for r in [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.65, 0.8, 1.0]:
		_row("  %-6s" % str(r), _panel(base, float(r)))

func _header() -> String:
	var parts: Array = []
	for o in PANEL:
		parts.append("%7s" % o)
	return "%s   mean   unfin  p95rnd  maxrnd" % " ".join(parts)

# A candidate is only better if it is better on the whole panel. `unfin` and
# `maxrnd` are summed and maxed across the panel, because a setting that stalls
# against ANY opponent is disqualified.
func _row(title: String, p: Dictionary) -> void:
	var parts: Array = []
	for o in PANEL:
		parts.append("%6.1f%%" % p.rates[o])
	print("%-12s %s  %5.1f%%  %5d  %6d  %6d" % [
		title, " ".join(parts), p.mean, p.unfin, p.p95, p.maxrnd])

func _panel(w: Dictionary, blunder: float) -> Dictionary:
	var rates := {}
	var total: float = 0.0
	var unfin: int = 0
	var maxrnd: int = 0
	var p95: int = 0
	for o in PANEL:
		var r: Dictionary = _run(w, blunder, o)
		var pct: float = 100.0 * r.left / max(1, r.left + r.right)
		rates[o] = pct
		total += pct
		unfin += int(r.stuck)
		maxrnd = max(maxrnd, int(r.max_rounds))
		p95 = max(p95, int(r.p95))
	return {"rates": rates, "mean": total / PANEL.size(), "unfin": unfin,
		"p95": p95, "maxrnd": maxrnd}

# `left` plays the scorer with `w` and `blunder`; `right` plays `opponent`.
func _run(w: Dictionary, blunder: float, opponent: String) -> Dictionary:
	var left_wins := 0
	var right_wins := 0
	var draws := 0
	var stuck := 0
	var lengths: Array = []

	for m in range(MATCHES):
		var rng := RandomNumberGenerator.new()
		rng.seed = 5000 + m
		var left: int = FDState.BLACK if m % 2 == 0 else FDState.RED
		var right: int = FDState.RED if left == FDState.BLACK else FDState.BLACK

		var s := FDRules.new_match(left)
		var guard := 0
		while not s.is_over() and guard < GUARD:
			guard += 1
			if s.phase == FDState.Phase.POSITIONING:
				FDRules.commit_placement(s, left, FDRules.auto_place(s, left, rng))
				FDRules.commit_placement(s, right, FDRules.auto_place(s, right, rng))
				continue
			var side: int = s.side_to_act
			var action: Dictionary
			if side == left:
				action = FDScorer.choose_action(s, side, w, rng, blunder, 3)
			else:
				action = _opponent_action(opponent, s, side, rng)
			if action.is_empty():
				break
			var res := FDRules.resolve(s, side, action)
			if not res.ok:
				print("  SWEEP ERROR: %s -> %s" % [action, res.error])
				break
			FDRules.advance(s)

		if guard >= GUARD:
			stuck += 1
			continue
		lengths.append(s.round_no)
		var won := FDRules.winner(s)
		if won == left:
			left_wins += 1
		elif won == right:
			right_wins += 1
		else:
			draws += 1

	lengths.sort()
	return {
		"left": left_wins, "right": right_wins, "draw": draws, "stuck": stuck,
		"median": lengths[lengths.size() / 2] if not lengths.is_empty() else 0,
		"p95": lengths[int(lengths.size() * 0.95)] if not lengths.is_empty() else 0,
		"max_rounds": lengths[-1] if not lengths.is_empty() else 0,
	}

func _opponent_action(opponent: String, s: FDState, side: int, rng: RandomNumberGenerator) -> Dictionary:
	match opponent:
		"ladder":
			return FDLadderAI.choose_action(s, side, rng)
		"ref":
			# The shipped HARD set, deliberately read from the file rather than
			# copied, so "better than what we have" stays true after a retune.
			return FDScorer.choose_action(s, side, FDScorer.weights(FDHardAI.WEIGHTS), rng)
		_:
			return _blind(s, side)

func _blind(s: FDState, side: int) -> Dictionary:
	var un: Array = s.unacted(side)
	if un.is_empty():
		return {}
	var c: FDCard = un[0]
	return {"card_id": c.id, "kind": "attack", "target_slot": s.slot_of(c)}
