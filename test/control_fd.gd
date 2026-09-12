extends SceneTree

# Harness control. Two IDENTICAL policies must land near 50%; anything else is
# a bias in the measuring rig, not a fact about the AI.
#
#   godot --headless --path RemiShowdown --script res://test/control_fd.gd
#
# This exists because the mirror row in test/analyze_fd.gd read 44%, which is
# either a real second-player edge, a harness bug, or one unlucky seed set -
# and the three are indistinguishable from a single sample. Running the same
# control over several independent seed blocks separates them: a rig bias
# repeats on every block, noise does not.
#
# Each row also splits the result by which side `left` was sitting on. The
# round-1 leader alternates (Black leads odd rounds) and `left` alternates
# colour every match, so a genuine seat advantage shows up as a split between
# the two columns rather than as a shifted total.

const MATCHES: int = 600
const GUARD: int = 8000
const SEED_BLOCKS := [5000, 90000, 200000, 314159, 777000]

func _initialize() -> void:
	var w: Dictionary = FDScorer.weights(FDHardAI.WEIGHTS)
	print("harness control - HARD vs HARD, %d matches per block, damage_scale %.1f"
		% [MATCHES, FDRules.DAMAGE_SCALE])
	print("  a rig with no bias sits at 50.0%% in every column")
	print("")
	print("  seeds        overall   left-as-Black   left-as-Red   draws")

	var total_l := 0
	var total_r := 0
	var obw := 0
	var obl := 0
	var ebw := 0
	var ebl := 0
	for base in SEED_BLOCKS:
		var r: Dictionary = _run(w, base)
		print("  %-10d %6.1f%%      %6.1f%%        %6.1f%%    %5d" % [
			base, _pct(r.left, r.right),
			_pct(r.black_w, r.black_l), _pct(r.red_w, r.red_l), r.draw])
		total_l += int(r.left)
		total_r += int(r.right)
		obw += int(r.odd_bw); obl += int(r.odd_bl)
		ebw += int(r.even_bw); ebl += int(r.even_bl)
	print("")
	print("  pooled     %6.1f%%   (%d / %d over %d matches)"
		% [_pct(total_l, total_r), total_l, total_r, total_l + total_r])

	print("")
	print("  BLACK's win rate, split by how many rounds the match ran:")
	print("    ended on an ODD round  %5.1f%%   (Black led one time more)  n=%d"
		% [_pct(obw, obl), obw + obl])
	print("    ended on an EVEN round %5.1f%%   (both led equally)         n=%d"
		% [_pct(ebw, ebl), ebw + ebl])
	quit(0)

func _pct(a: int, b: int) -> float:
	return 100.0 * float(a) / float(max(1, a + b))

func _run(w: Dictionary, seed_base: int) -> Dictionary:
	var r := {"left": 0, "right": 0, "draw": 0,
		"black_w": 0, "black_l": 0, "red_w": 0, "red_l": 0,
		# Black leads odd rounds, Red even. In a match that ends on an ODD
		# round Black has led one more time than Red; on an even round they
		# have led equally. If leading is what costs, the gap lives here.
		"odd_bw": 0, "odd_bl": 0, "even_bw": 0, "even_bl": 0}

	for m in range(MATCHES):
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_base + m
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
			var action: Dictionary = FDScorer.choose_action(s, side, w, rng)
			if action.is_empty():
				break
			if not FDRules.resolve(s, side, action).ok:
				break
			FDRules.advance(s)

		if guard >= GUARD:
			continue
		var won := FDRules.winner(s)
		var black_won: bool = won == FDState.BLACK
		var black_lost: bool = won == FDState.RED
		if s.round_no % 2 == 1:
			if black_won: r.odd_bw += 1
			elif black_lost: r.odd_bl += 1
		else:
			if black_won: r.even_bw += 1
			elif black_lost: r.even_bl += 1
		if won == left:
			r.left += 1
			if left == FDState.BLACK: r.black_w += 1
			else: r.red_w += 1
		elif won == right:
			r.right += 1
			if left == FDState.BLACK: r.black_l += 1
			else: r.red_l += 1
		else:
			r.draw += 1
	return r
