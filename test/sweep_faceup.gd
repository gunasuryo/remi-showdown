extends SceneTree

# Weight sweep for the face-up scorer.
#
#   godot --headless --path RemiShowdown --script res://test/sweep_faceup.gd -- descend
#   godot --headless --path RemiShowdown --script res://test/sweep_faceup.gd -- <term>
#
# The face-down side has had test/sweep_ai.gd since its scorer was written.
# Face-up had nothing: test/bench_faceup.gd measures POLICIES against each
# other, which answers "is the scorer better than the ladder" and never "are
# these the right numbers". So the shipped weights were the first guess anyone
# made, and they then survived four rule changes that invalidated all of them -
# an attack that no longer reaches sideways, a shield that no longer expires on
# a clock, a trick that became a hidden trap costing a whole action, and three
# statuses the scorer can no longer see on the enemy.
#
# `descend` is the one that produces a weight set: coordinate descent, taking
# the best value for each term and CARRYING IT FORWARD into the next. Sweeping
# every term against a fixed base does not converge, because the terms interact.
#
# Measured against a PANEL of three opponents:
#
#   blind  - pure attack, every card swings at the lane it faces. The policy
#            that beat every priority ladder ever written for this game. 50%
#            here means "no better than never using a skill at all".
#   ladder - FUAI.choose_ladder, the EASY tier: a skill-heavy priority order.
#   ref    - the currently shipped weights, so a candidate has to beat what is
#            already in the game rather than just beat a punchbag.
#
# The panel is not decoration. Against blind alone several terms cannot fire:
# blind never shields, so `shield_break` scores identically at any value, and it
# never uses a skill, so `trick` has nothing to deny - a trap that is never
# sprung is worth exactly zero. Tuning on blind alone sets both to noise.
#
# READ THE `unfin` COLUMN. Win rate is computed over FINISHED matches, so a
# setting that stops matches ending scores brilliantly while breaking the game.
# Face-up is more exposed to this than face-down is: it has no round structure
# and no DAMAGE_SCALE, so an Ace renewing a shield behind a healing Queen is the
# standing way to make a match immortal. Rows over UNFIN_BUDGET are
# disqualified however good they look - and note the budget cannot be zero
# here, because the shipped set does not clear that bar either. See the const.
#
# EVERY ARRANGEMENT IS PLAYED TWICE, once with each side leading round 1.
#
# Leading is a real disadvantage in this game - about 10 points, measured, and
# symmetric between the colours (leaders 45.3%, followers 54.8%). The harness
# used to let a seeded coin flip decide the lead and trust it to average out
# over 800 matches. It does not: the blind-vs-blind control, which is two
# identical policies and must land on 50%, came out at 44.3%, because the flip
# gave `left` the lead slightly more often than not and each of those cost it
# ten points. Splitting that run showed leaders-who-were-left winning 39.9% and
# leaders-who-were-right winning 51.0% - the same policy, on the same board,
# eleven points apart on nothing but seat.
#
# Pairing removes it by construction rather than statistically: the identical
# row arrangement is played out under both leads, so whatever the lead is worth
# it is worth to both sides exactly once. The control then has to be 50%, and
# any deviation is a real harness bug rather than something to average away.
#
# The opening slot order is shuffled per match and is the ONLY thing sampled:
# FURules uses no RNG and neither does the scorer, so without it every match of
# a matchup is the same game replayed. Sides swap every match so the coin flip
# cancels out.

# Each is played twice, once under each lead, so this is 200 board states and
# 400 matches per opponent.
const MATCHES: int = 200
const GUARD: int = 2000

# Face-up stalls on its own, at a low rate, whatever the weights: it has no
# round structure and no DAMAGE_SCALE, so an Ace renewing a shield behind a
# healing Queen can outrun the damage coming at it. Measured at roughly 1 match
# in 130 across the panel at the shipped weights.
#
# So unlike test/sweep_ai.gd, which disqualifies any non-zero unfin, this has to
# allow a budget - a zero rule here rejects every row including the base, which
# is not a strict standard but a broken one. What is worth catching is a weight
# set that makes stalling COMMON, so the bar is set well above the noise floor
# and well below anything deliberate.
const UNFIN_BUDGET: int = 22   # out of 3 x 2 x MATCHES

# One decade either side of each shipped value, plus 0 where switching a term
# off is a meaningful question.
const GRID := {
	"kill": [0.0, 15.0, 30.0, 45.0, 60.0, 90.0, 130.0, 180.0],
	"shield_break": [0.0, 0.25, 0.5, 0.75, 1.0],
	"shield": [0.0, 0.15, 0.35, 0.6, 1.0],
	"heal": [0.0, 0.1, 0.25, 0.5],
	"save": [0.0, 7.0, 14.0, 25.0, 40.0],
	"rally_discount": [0.0, 0.25, 0.5, 0.75, 1.0],
	"self_rally": [0.0, 0.25, 0.5, 1.0],
	"trick": [0.0, 0.35, 1.0, 2.5, 5.0],
}

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var base: Dictionary = FUAI.weights()
	if args.is_empty():
		print("usage: -- descend   |   -- <term>")
		quit(0)
		return

	var what: String = str(args[0])
	print("face-up weight sweep - %d matches per opponent, panel of 3" % MATCHES)
	print("base: %s" % _fmt(base))
	print("")

	if what == "descend":
		_descend(base)
	elif GRID.has(what):
		_sweep_one(base, what)
	else:
		print("unknown term %s" % what)
	quit(0)

# ── Coordinate descent ────────────────────────────────────────────────────

func _descend(base: Dictionary) -> void:
	var best: Dictionary = base.duplicate()
	var best_score: float = _panel(best).mean
	print("start: mean %.1f%%" % best_score)

	for pass_no in range(2):
		print("")
		print("=== pass %d ===" % (pass_no + 1))
		for key in GRID.keys():
			var moved_to = null
			for v in GRID[key]:
				if is_equal_approx(float(v), float(best[key])):
					continue
				var w: Dictionary = best.duplicate()
				w[key] = float(v)
				var p: Dictionary = _panel(w)
				var tag: String = ""
				if p.unfin > UNFIN_BUDGET:
					tag = "REJECTED (stalls)"
				elif p.mean > best_score:
					tag = "<- best"
					best_score = p.mean
					moved_to = float(v)
					best = w
				_row("  %-14s %-6s" % [key, str(v)], p, tag)
			if moved_to != null:
				print("    %s -> %s" % [key, str(moved_to)])
		print("")
		print("pass %d best: mean %.1f%%" % [pass_no + 1, best_score])
		print("  %s" % _fmt(best))

	print("")
	print("FINAL  mean %.1f%%" % best_score)
	print(_as_gdscript(best))

func _sweep_one(base: Dictionary, key: String) -> void:
	for v in GRID[key]:
		var w: Dictionary = base.duplicate()
		w[key] = float(v)
		var p: Dictionary = _panel(w)
		_row("  %-14s %-6s" % [key, str(v)], p, "REJECTED (stalls)" if p.unfin > UNFIN_BUDGET else "")

# ── The panel ─────────────────────────────────────────────────────────────

func _panel(w: Dictionary) -> Dictionary:
	var out := {"blind": 0.0, "ladder": 0.0, "ref": 0.0, "unfin": 0, "mean": 0.0}
	for foe in ["blind", "ladder", "ref"]:
		var r: Dictionary = _run(w, foe)
		out[foe] = r.rate
		out.unfin += int(r.unfin)
	out.mean = (out.blind + out.ladder + out.ref) / 3.0
	return out

func _run(w: Dictionary, foe: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 8811
	var won := 0
	var lost := 0
	var unfin := 0
	var refw: Dictionary = FUAI.weights()

	for m in range(MATCHES):
		var side: int = FUState.BLACK if m % 2 == 0 else FUState.RED
		var rows := _draw_rows(rng)
		# Both leads, same board - see the note on pairing in the header.
		for lead in [FUState.BLACK, FUState.RED]:
			var s := _deal(rows, lead)

			var acted := 0
			while not s.is_over() and acted < GUARD:
				acted += 1
				var actor := s.current_card()
				if actor == null:
					break
				var action: Dictionary
				if actor.side == side:
					action = FUAI.choose(s, w)
				else:
					match foe:
						"blind":
							action = FUAI._best_attack(s, actor, refw)
							action.erase("score")
						"ladder":
							action = FUAI.choose_ladder(s, refw)
						_:
							action = FUAI.choose(s, refw)
				if action.is_empty():
					break
				var res := FURules.resolve(s, action)
				if not res.ok:
					print("  SWEEP ERROR: %s -> %s" % [action, res.error])
					break

			if acted >= GUARD or not s.is_over():
				unfin += 1
			elif FURules.winner(s) == side:
				won += 1
			else:
				lost += 1

	return {"rate": 100.0 * won / maxi(1, won + lost), "unfin": unfin}


# One arrangement, drawn from the rng, ready to be replayed under either lead.
func _draw_rows(rng: RandomNumberGenerator) -> Array:
	var s := FURules.new_match(FUState.BLACK, rng)
	_shuffle(s, FUState.BLACK, rng)
	_shuffle(s, FUState.RED, rng)
	return [s.rows[FUState.BLACK].duplicate(), s.rows[FUState.RED].duplicate()]

# The same arrangement, dealt again with `lead` acting first.
func _deal(rows: Array, lead: int) -> FUState:
	var s := FURules.new_match(FUState.BLACK)
	s.rows[FUState.BLACK] = rows[0].duplicate()
	s.rows[FUState.RED] = rows[1].duplicate()
	s.first_suit = lead
	s.current_suit = lead
	s.current_slot = 0
	FURules.start(s)
	return s

func _shuffle(s: FUState, side: int, rng: RandomNumberGenerator) -> void:
	var row: Array = s.rows[side]
	for i in range(row.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = row[i]
		row[i] = row[j]
		row[j] = tmp

# ── Output ────────────────────────────────────────────────────────────────

func _row(label: String, p: Dictionary, tag: String) -> void:
	print("%s blind %5.1f  ladder %5.1f  ref %5.1f  | mean %5.1f  unfin %2d  %s" % [
		label, p.blind, p.ladder, p.ref, p.mean, p.unfin, tag])

func _fmt(w: Dictionary) -> String:
	var bits: PackedStringArray = []
	for k in GRID.keys():
		bits.append("%s=%s" % [k, str(w[k])])
	return " ".join(bits)

func _as_gdscript(w: Dictionary) -> String:
	var out: String = "const DEFAULTS := {\n"
	for k in GRID.keys():
		out += "\t\"%s\": %s,\n" % [k, str(float(w[k]))]
	return out + "}"
