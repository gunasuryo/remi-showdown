extends SceneTree

# Face-down behaviour analysis: what the AI actually DOES, not just whether it
# wins. bench_ai.gd counts wins; this counts decisions.
#
#   godot --headless --path RemiShowdown --script res://test/analyze_fd.gd
#   godot --headless --path RemiShowdown --script res://test/analyze_fd.gd -- rally
#
# Everything is attributed by reading the event stream FDRules.resolve returns,
# so the numbers are what the rules engine saw happen, not what the scorer
# intended. Events are attributed to the side of the card they happened TO,
# which matters for the trick counters: a rally being stripped is something the
# opponent's Joker did to us.
#
# The `rally` mode additionally runs the self-rally A/B - the same AI with the
# self-rally priced out of reach - which is the only honest way to answer
# whether arming rally+ is a strategy or a tax.

const MATCHES: int = 600
const GUARD: int = 8000

# Match seeds are SEED_BASE + index. Overridable so a result that looks too
# tidy can be re-run on a different sample rather than believed.
static var seed_base: int = 5000

# Spread enum values, for readable output.
const SPREAD_NAME := ["single", "three (rallied)"]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var mode: String = str(args[0]) if args.size() > 0 else "mix"
	if args.size() > 1:
		seed_base = int(str(args[1]))

	print("face-down analysis - %d matches per matchup, damage_scale %.1f, seeds %d+"
		% [MATCHES, FDRules.DAMAGE_SCALE, seed_base])

	if mode == "rally":
		_rally_ab()
		quit(0)
		return

	for opponent in ["blind", "ladder", "mirror"]:
		var r: Dictionary = _run(FDScorer.weights(FDHardAI.WEIGHTS), 0.0, opponent)
		print("")
		print("=========  HARD vs %s  =========" % opponent)
		_report(r)
	quit(0)

# ── The question: is arming rally+ worth two King actions? ────────────────

func _rally_ab() -> void:
	var base: Dictionary = FDScorer.weights(FDHardAI.WEIGHTS)

	# Sweeping the PRICE of a self-rally rather than just switching it off. If
	# arming rally+ is a real strategy the curve should have a peak somewhere
	# above zero; if it is a tax, win rate falls monotonically as the King is
	# paid more to do it. -1000 never arms; 0 arms only when nothing else
	# scores at all; the high end forces the gamble.
	var prices := [-1000.0, 0.0, 4.0, 10.0, 20.0, 40.0]

	for opponent in ["blind", "ladder", "mirror"]:
		print("")
		print("=========  self-rally price vs %s  =========" % opponent)
		print("  price     win      w/l      armed  rally+cast  rallied-sk  rounds")
		for price in prices:
			var w: Dictionary = base.duplicate()
			w["self_rally"] = price
			var r: Dictionary = _run(w, 0.0, opponent)
			print("  %-8s %5.1f%%  %4d/%-4d %6d %9d %12d %7d"
				% [str(price), _winrate(r), r.left, r.right, r.armed, r.rally_up_casts,
					r.spread[1], r.median])

		# Is the rally mechanic worth anything at all, as a floor?
		var no_rally: Dictionary = base.duplicate()
		no_rally["self_rally"] = -1000.0
		no_rally["rally_discount"] = 0.0
		var nr: Dictionary = _run(no_rally, 0.0, opponent)
		print("  %-8s %5.1f%%  %4d/%-4d %6d %9d %12d %7d   (King never rallies)"
			% ["none", _winrate(nr), nr.left, nr.right, nr.armed, nr.rally_up_casts,
				nr.spread[1], nr.median])

func _winrate(r: Dictionary) -> float:
	return 100.0 * r.left / max(1, r.left + r.right)

# ── Reporting ─────────────────────────────────────────────────────────────

func _report(r: Dictionary) -> void:
	var acts: int = r.attacks + r.skills
	print("  win %.1f%%   (%d matches, %d unfinished, median %d rounds)"
		% [_winrate(r), r.left + r.right + r.draw, r.stuck, r.median])
	print("")
	print("  ACTION MIX      %6d actions" % acts)
	print("    attack        %6d  (%4.1f%%)" % [r.attacks, _pct(r.attacks, acts)])
	print("    skill         %6d  (%4.1f%%)" % [r.skills, _pct(r.skills, acts)])

	print("")
	print("  PER CARD                attack        skill      skill share")
	for card_name in CardStats.ORDER:
		var a: int = int(r.card_attack.get(card_name, 0))
		var s: int = int(r.card_skill.get(card_name, 0))
		print("    %-8s        %8d     %8d        %5.1f%%"
			% [card_name, a, s, _pct(s, a + s)])

	print("")
	print("  SKILL SPREAD (what the skill actually covered)")
	for i in range(SPREAD_NAME.size()):
		print("    %-18s %6d  (%4.1f%% of skills)"
			% [SPREAD_NAME[i], r.spread[i], _pct(r.spread[i], r.skills)])

	print("")
	print("  RALLY LIFECYCLE")
	print("    self-rallies (rally+ armed)   %6d" % r.armed)
	print("    rallies granted, plain        %6d" % r.rally_plain)
	print("    rallies granted, upgraded     %6d" % r.rally_up)
	print("    rallies SPENT on a skill      %6d" % r.consumed)
	print("    rallies expired unused        %6d" % r.expired)
	print("    became last-rally (King died) %6d" % r.last_rally)
	print("    stripped by enemy Joker       %6d  (rally+ downgraded %d)"
		% [r.trick_strip, r.trick_down])

	print("")
	print("  WHAT RALLY+ BUYS")
	print("    rally+ casts                  %6d" % r.rally_up_casts)
	print("    allies rallied by them        %6d   (%.2f per cast)"
		% [r.rally_up, float(r.rally_up) / float(max(1, r.rally_up_casts))])
	print("    board width when rallying:    %s" % _dist(r.board_at_rally))

	var granted: int = r.rally_plain + r.rally_up
	print("")
	print("  CONVERSION")
	print("    granted rally -> spent        %5.1f%%   (%d of %d)"
		% [_pct(r.consumed, granted), r.consumed, granted])
	print("    self-rally -> rally+ cast     %5.1f%%   (%d of %d)"
		% [_pct(r.rally_up_casts, r.armed), r.rally_up_casts, r.armed])
	print("    King actions spent rallying   %5.1f%%   (%d of %d King actions)"
		% [_pct(r.armed + granted, r.card_attack.get("King", 0) + r.card_skill.get("King", 0)),
			r.armed + granted,
			int(r.card_attack.get("King", 0)) + int(r.card_skill.get("King", 0))])

# "5:120 4:80 3:12" - how often each board width was in play.
func _dist(d: Dictionary) -> String:
	var keys: Array = d.keys()
	keys.sort()
	keys.reverse()
	var parts: Array = []
	for k in keys:
		parts.append("%dw:%d" % [k, d[k]])
	return " ".join(parts) if not parts.is_empty() else "(none)"

func _pct(n, d) -> float:
	return 100.0 * float(n) / float(max(1, d))

# ── Match loop ────────────────────────────────────────────────────────────

func _run(w: Dictionary, blunder: float, opponent: String) -> Dictionary:
	var r := {
		"left": 0, "right": 0, "draw": 0, "stuck": 0, "median": 0,
		"attacks": 0, "skills": 0,
		"card_attack": {}, "card_skill": {},
		"spread": [0, 0],
		"armed": 0, "rally_plain": 0, "rally_up": 0, "rally_up_casts": 0,
		"consumed": 0, "expired": 0, "last_rally": 0,
		"trick_strip": 0, "trick_down": 0,
		"board_at_rally": {},
	}
	var lengths: Array = []

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
			var action: Dictionary
			if side == left:
				action = FDScorer.choose_action(s, side, w, rng, blunder, 3)
			else:
				action = _opponent_action(opponent, s, side, rng, w)
			if action.is_empty():
				break

			# Counted before resolve, so an action that whiffs still counts as
			# the action it was. The actor is looked up the same way.
			if side == left:
				var actor: FDCard = s.card_by_id(action.card_id)
				if action.kind == "attack":
					r.attacks += 1
					r.card_attack[actor.card_name] = int(r.card_attack.get(actor.card_name, 0)) + 1
				else:
					r.skills += 1
					r.card_skill[actor.card_name] = int(r.card_skill.get(actor.card_name, 0)) + 1

			var res := FDRules.resolve(s, side, action)
			if not res.ok:
				print("  ANALYZE ERROR: %s -> %s" % [action, res.error])
				break
			_tally(s, left, res.events, r)
			FDRules.advance(s)

		if guard >= GUARD:
			r.stuck += 1
			continue
		lengths.append(s.round_no)
		var won := FDRules.winner(s)
		if won == left:
			r.left += 1
		elif won == right:
			r.right += 1
		else:
			r.draw += 1

	lengths.sort()
	r.median = lengths[lengths.size() / 2] if not lengths.is_empty() else 0
	return r

# Attributes each event to the side of the card it happened to, and counts only
# the ones belonging to `left`.
func _tally(s: FDState, left: int, events: Array, r: Dictionary) -> void:
	# One rally+ cast emits one `rally` event PER ALLY it reaches, so counting
	# events would report a cast that hit three allies as three rally+ grants
	# and make the conversion off a single arm look like 300%.
	var counted_cast := false
	for ev in events:
		match ev.get("t", ""):
			"skill":
				if _side_of(s, ev.actor) == left:
					r.spread[int(ev.get("spread", 0))] += 1
			"king_plus_armed":
				if _side_of(s, ev.card) == left:
					r.armed += 1
			"rally":
				if _side_of(s, ev.actor) == left:
					r.board_at_rally[s.board_size] = int(r.board_at_rally.get(s.board_size, 0)) + 1
					if bool(ev.get("upgraded", false)):
						r.rally_up += 1
						if not counted_cast:
							counted_cast = true
							r.rally_up_casts += 1
					else:
						r.rally_plain += 1
			"rally_consumed":
				if _side_of(s, ev.card) == left:
					r.consumed += 1
			"rally_expired":
				if _side_of(s, ev.card) == left:
					r.expired += 1
			"last_rally":
				if _side_of(s, ev.card) == left:
					r.last_rally += 1
			"trick_strip_rally":
				if _side_of(s, ev.target) == left:
					r.trick_strip += 1
			"trick_downgrade":
				if _side_of(s, ev.target) == left:
					r.trick_down += 1

func _side_of(s: FDState, id: int) -> int:
	var c: FDCard = s.card_by_id(id)
	return c.side if c != null else -1

func _opponent_action(opponent: String, s: FDState, side: int,
		rng: RandomNumberGenerator, w: Dictionary) -> Dictionary:
	match opponent:
		"ladder":
			return FDLadderAI.choose_action(s, side, rng)
		"mirror":
			return FDScorer.choose_action(s, side, w, rng)
		_:
			var un: Array = s.unacted(side)
			if un.is_empty():
				return {}
			var c: FDCard = un[0]
			return {"card_id": c.id, "kind": "attack", "target_slot": s.slot_of(c)}
