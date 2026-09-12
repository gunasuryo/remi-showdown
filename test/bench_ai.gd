extends SceneTree

# Face-down AI benchmark.
#
#   godot --headless --path RemiShowdown --script res://test/bench_ai.gd
#
# Three policies:
#   blind  - never use a skill, every card attacks the lane it stands in.
#            This is the policy that was beating everything.
#   random - pick uniformly from the legal action list, knowing nothing.
#   ladder - FDLadderAI, the EASY difficulty: the PRD 11 priority order.
#   smart  - FDAI, the NORMAL difficulty: HARD's scorer and weights, held back
#            by an explicit blunder rate.
#   hard   - FDHardAI, the HARD difficulty: the scorer playing its best move.
#
# This file measures the tiers as they ship. To TUNE them, use
# test/sweep_ai.gd, which sweeps one weight at a time against a three-opponent
# panel; benching a single matchup is how several terms came to be set to noise.
#
# Sides are swapped every match so the round-1 leader advantage (Black always
# leads odd rounds) cancels out.
#
# blind vs blind is the control - two identical policies must land near 50%, so
# a lopsided result there means the harness is biased, not the AI. FDAI has to
# beat 50% against blind to be worth its skills.

const MATCHES: int = 800
const GUARD: int = 8000

# Read from the rules, never re-declared. This bench used to carry its own 2.0
# while the board shipped 1.0, which silently invalidated every weight tuned
# through it.
const SCALE: float = FDRules.DAMAGE_SCALE

func _initialize() -> void:
	# `-- <policy>` runs just that policy against blind plus its own control,
	# which is the tight loop for tuning. No argument runs the full matrix.
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		var p: String = str(args[0])
		print("face-down: %s, %d matches, damage_scale %.1f" % [p, MATCHES, SCALE])
		_report("%-6s vs %-6s (control)" % [p, p], _run(p, p))
		_report("%-6s vs blind" % p, _run(p, "blind"))
		quit(0)
		return

	print("face-down benchmark - %d matches per matchup, damage_scale %.1f" % [MATCHES, SCALE])
	_report("blind  vs blind  (control)", _run("blind", "blind"))
	_report("HARD   vs blind", _run("hard", "blind"))
	_report("NORMAL vs blind", _run("smart", "blind"))
	_report("HARD   vs NORMAL", _run("hard", "smart"))
	_report("NORMAL vs EASY   (ladder)", _run("smart", "ladder"))
	_report("EASY   vs random", _run("ladder", "random"))
	quit(0)

func _report(title: String, r: Dictionary) -> void:
	print("")
	print("%s" % title)
	print("  left won %d, right won %d, draws %d, unfinished %d  ->  left %.1f%%" % [
		r.left, r.right, r.draw, r.stuck, 100.0 * r.left / max(1, r.left + r.right)])
	print("  rounds: median %d, max %d" % [r.median, r.max_rounds])
	var keys: Array = r.mix.keys()
	if keys.is_empty():
		return
	keys.sort()
	var total: int = 0
	for k in keys:
		total += int(r.mix[k])
	for k in keys:
		print("    %-14s %5d  (%2.0f%%)" % [k, r.mix[k], 100.0 * int(r.mix[k]) / total])

func _run(left_policy: String, right_policy: String) -> Dictionary:
	var left_wins := 0
	var right_wins := 0
	var draws := 0
	var stuck := 0
	var lengths: Array = []
	var mix := {}

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
				FDRules.commit_placement(s, left, _place(left_policy, s, left, rng))
				FDRules.commit_placement(s, right, _place(right_policy, s, right, rng))
				continue
			var side: int = s.side_to_act
			var policy: String = left_policy if side == left else right_policy
			var action: Dictionary = _act(policy, s, side, rng)
			if action.is_empty():
				break
			if side == left:
				var actor: FDCard = s.card_by_id(action.card_id)
				var key: String = "%s %s" % [actor.card_name, action.kind]
				mix[key] = int(mix.get(key, 0)) + 1
			var res := FDRules.resolve(s, side, action)
			if not res.ok:
				print("  BENCH ERROR: %s -> %s" % [action, res.error])
				break
			FDRules.advance(s)

		if guard >= GUARD:
			stuck += 1
			continue
		lengths.append(s.round_no)
		var w := FDRules.winner(s)
		if w == left:
			left_wins += 1
		elif w == right:
			right_wins += 1
		else:
			draws += 1

	lengths.sort()
	return {
		"left": left_wins, "right": right_wins, "draw": draws, "stuck": stuck,
		"mix": mix,
		"median": lengths[lengths.size() / 2] if not lengths.is_empty() else 0,
		"max_rounds": lengths[-1] if not lengths.is_empty() else 0,
	}

func _place(policy: String, s: FDState, side: int, rng: RandomNumberGenerator) -> Array:
	if policy == "smart":
		return FDAI.place_slots(s, side, rng)
	if policy == "hard":
		return FDHardAI.place_slots(s, side, rng)
	return FDRules.auto_place(s, side, rng)

func _act(policy: String, s: FDState, side: int, rng: RandomNumberGenerator) -> Dictionary:
	if policy == "smart":
		return FDAI.choose_action(s, side, rng)
	if policy == "random":
		return FDRandomAI.choose_action(s, side, rng)
	if policy == "ladder":
		return FDLadderAI.choose_action(s, side, rng)
	if policy == "hard":
		return FDHardAI.choose_action(s, side, rng)
	var un: Array = s.unacted(side)
	if un.is_empty():
		return {}
	var c: FDCard = un[0]
	return {"card_id": c.id, "kind": "attack", "target_slot": s.slot_of(c)}
