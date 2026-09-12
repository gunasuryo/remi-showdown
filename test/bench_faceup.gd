extends SceneTree

# Face-up AI benchmark.
#
#   godot --headless --path RemiShowdown --script res://test/bench_faceup.gd
#
# Four policies, the same shape as the face-down bench:
#   blind  - never use a skill; every card attacks, aiming at the best lane it
#            can reach. This is the policy that was beating everything.
#   random - FUAI.choose_random: a coin flip between attacking and using the
#            skill, with no idea what either does.
#   ladder - FUAI.choose_ladder, the EASY difficulty: a fixed priority order.
#   scorer - FUAI.choose, what NORMAL and HARD both play.
#
# blind vs blind is the control - two identical policies must land near 50%, so
# a lopsided result there means the harness is biased rather than the AI. The
# scorer has to beat 50% against blind to be worth its skills.
#
# This used to drive the real table_2 scene, instantiating the whole board once
# per match at Engine.time_scale = 100 and taking minutes for 40 matches. It ran
# that way because the rules lived inside table2.gd and there was nothing else
# to drive. Now that FURules is pure, the same measurement is a headless loop
# and 800 matches cost less than the old 40 did.
#
# That old harness had also quietly stopped working: the "blind" policy called
# table._on_attack(), which - once an attack gained the choice of three lanes -
# stopped resolving immediately and instead put the board into "player_target"
# waiting for a click that a headless bench never makes. Every blind match ran
# to the stall guard, so the row that mattered most was measuring nothing.

# Each is played twice - once under each lead - so this is 800 board states and
# 1600 matches.
const MATCHES: int = 800
const GUARD: int = 3000

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		var p: String = str(args[0])
		print("face-up: %s, %d matches" % [p, MATCHES])
		_report("%-6s vs %-6s (control)" % [p, p], _run(p, p))
		_report("%-6s vs blind" % p, _run(p, "blind"))
		quit(0)
		return

	print("face-up benchmark - %d matches per matchup" % MATCHES)
	_report("blind  vs blind  (control)", _run("blind", "blind"))
	_report("scorer vs blind", _run("scorer", "blind"))
	_report("scorer vs ladder (EASY)", _run("scorer", "ladder"))
	_report("scorer vs random", _run("scorer", "random"))
	_report("ladder vs blind", _run("ladder", "blind"))
	_report("ladder vs random", _run("ladder", "random"))
	quit(0)

func _report(title: String, r: Dictionary) -> void:
	print("")
	print("%s" % title)
	print("  left won %d, right won %d, draws %d, unfinished %d  ->  left %.1f%%" % [
		r.left, r.right, r.draw, r.stuck, 100.0 * r.left / max(1, r.left + r.right)])
	print("  actions per match: median %d, max %d" % [r.median, r.max_actions])
	var total: int = 0
	for k in r.mix:
		total += int(r.mix[k])
	if total > 0:
		for k in r.mix:
			print("    %-14s %5d  (%2.0f%%)" % [k, r.mix[k], 100.0 * int(r.mix[k]) / total])

# `left` plays Black on even matches and Red on odd ones, so any residual seat
# edge cancels out over the run.
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
# The opening slot order is shuffled per match, and that is not decoration: it
# is the ONLY thing being sampled. FURules uses no RNG and none of these brains
# do either, so a match is a pure function of (who leads, how the rows are
# arranged). Without the shuffle every one of these 800 matches is a replay of
# the same two games, the median match length equals the maximum, and every row
# reads 100% or 0% - which is what the scene-driven bench was quietly doing.
#
# The shipped game always opens in CardStats.ORDER. These rows therefore
# measure how a policy does across arrangements, not how the one arrangement a
# player sees plays out.
func _shuffle_row(s: FUState, side: int, rng: RandomNumberGenerator) -> void:
	var row: Array = s.rows[side]
	for i in range(row.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = row[i]
		row[i] = row[j]
		row[j] = tmp


# One arrangement, drawn from the rng, ready to be replayed under either lead.
func _draw_rows(rng: RandomNumberGenerator) -> Array:
	var s := FURules.new_match(FUState.BLACK, rng)
	_shuffle_row(s, FUState.BLACK, rng)
	_shuffle_row(s, FUState.RED, rng)
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

func _run(left: String, right: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240906
	var out := {"left": 0, "right": 0, "draw": 0, "stuck": 0,
		"median": 0, "max_actions": 0, "mix": {}}
	var lengths: Array = []

	for m in range(MATCHES):
		var left_side: int = FUState.BLACK if m % 2 == 0 else FUState.RED
		var rows := _draw_rows(rng)
		for lead in [FUState.BLACK, FUState.RED]:
			var s := _deal(rows, lead)
			var acted := 0

			while not s.is_over() and acted < GUARD:
				acted += 1
				var actor := s.current_card()
				if actor == null:
					break
				var policy: String = left if actor.side == left_side else right
				var action := _decide(s, policy, rng)
				if action.is_empty():
					print("  BENCH ERROR: %s offered nothing" % policy)
					break
				var key: String = "%s:%s" % [policy, action.kind]
				out.mix[key] = int(out.mix.get(key, 0)) + 1
				var res := FURules.resolve(s, action)
				if not res.ok:
					print("  BENCH ERROR: %s -> %s (%s)" % [action, res.error, policy])
					break

			lengths.append(acted)
			out.max_actions = maxi(out.max_actions, acted)
			if acted >= GUARD or not s.is_over():
				out.stuck += 1
				continue
			var w := FURules.winner(s)
			if w == 3:
				out.draw += 1
			elif w == left_side:
				out.left += 1
			else:
				out.right += 1

	lengths.sort()
	out.median = lengths[lengths.size() / 2] if not lengths.is_empty() else 0
	return out

func _decide(s: FUState, policy: String, rng: RandomNumberGenerator) -> Dictionary:
	match policy:
		"scorer":
			return FUAI.choose(s)
		"ladder":
			return FUAI.choose_ladder(s)
		"random":
			return FUAI.choose_random(s, rng)
		"blind":
			# Attack, always - but still aimed. Which lane an attack hits has
			# never been a random choice for any brain here, so leaving it
			# unaimed would measure lane selection rather than skill use.
			var actor := s.current_card()
			var best := FUAI._best_attack(s, actor, FUAI.DEFAULTS)
			best.erase("score")
			return best
	return {}
