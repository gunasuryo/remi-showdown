extends SceneTree

# Is there a dominant strategy? A round-robin between deliberately lopsided
# playstyles, plus a per-card contribution breakdown.
#
#   godot --headless --path RemiShowdown --script res://test/strategy_fd.gd
#   godot --headless --path RemiShowdown --script res://test/strategy_fd.gd -- cards
#
# The archetypes are built by distorting the scorer's weights rather than by
# writing five separate AIs. That keeps them honest: each one still plays the
# best move it can see, it just values the game differently, so a win says
# "this way of valuing the board is stronger" rather than "this bot is better
# written". A game with no dominant strategy should show a round-robin where
# nothing beats everything and the tuned set wins by a sensible margin rather
# than a crushing one.
#
# `blind` (never uses a skill) is included because it is the strategy a new
# player actually plays, and because it beat every priority ladder ever written
# for this game.

const GUARD: int = 8000

# Overridable so a slow experiment (lower damage_scale means far longer
# matches) can trade sample size for finishing at all.
static var MATCHES: int = 400

# Each archetype is HARD's tuned set with a few terms pushed to an extreme.
# The comment on each says what a player following it would be doing.
static func archetypes() -> Dictionary:
	var tuned: Dictionary = FDScorer.weights(FDHardAI.WEIGHTS)

	# Swing with everything, never spend an action on a skill.
	var rusher: Dictionary = tuned.duplicate()
	rusher.merge({"shield": 0.0, "heal": 0.0, "save": 0.0, "trick": 0.0,
		"rally_discount": 0.0, "self_rally": -1000.0, "kill": 20.0}, true)

	# Keep everyone alive: shield, heal, deny kills. Damage is an afterthought.
	var turtle: Dictionary = tuned.duplicate()
	turtle.merge({"shield": 1.2, "heal": 0.6, "save": 60.0, "kill": 0.0,
		"trick": 0.0, "rally_discount": 0.0, "self_rally": -1000.0}, true)

	# Build the rally engine: the King feeds allies, they spend it on skills.
	var engine: Dictionary = tuned.duplicate()
	engine.merge({"rally_discount": 1.0, "self_rally": 10.0, "shield": 0.1,
		"heal": 0.0, "save": 8.0, "trick": 0.0}, true)

	# Deny the opponent's skills: trick everything, especially support.
	var saboteur: Dictionary = tuned.duplicate()
	saboteur.merge({"trick": 4.0, "trick_threat": 0.8, "rally_discount": 0.2,
		"self_rally": -1000.0, "shield": 0.1, "save": 8.0}, true)

	# The HARD set as it was BEFORE the retune, for checking whether a result
	# reported from a shipped build still holds against the current one.
	var oldhard: Dictionary = FDScorer.weights({
		"kill": 0.0, "shield_break": 0.5, "shield": 0.4, "heal": 0.0,
		"save": 20.0, "reveal": 1.5, "trick": 0.0, "trick_threat": 0.0,
		"rally_discount": 0.5, "self_rally": 4.0,
	})

	return {
		"tuned": tuned,
		"oldhard": oldhard,
		"rusher": rusher,
		"turtle": turtle,
		"engine": engine,
		"saboteur": saboteur,
	}

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if str(a).begins_with("n="):
			MATCHES = int(str(a).substr(2))
	if args.size() > 0 and str(args[0]) == "cards":
		_card_report()
		quit(0)
		return
	_round_robin()
	quit(0)

# ── Round robin ───────────────────────────────────────────────────────────

func _round_robin() -> void:
	var arch: Dictionary = archetypes()
	var names: Array = arch.keys()
	names.append("blind")

	print("strategy round-robin - %d matches per pairing, damage_scale %.1f"
		% [MATCHES, FDRules.DAMAGE_SCALE])
	print("row's win %% against column. 50%% means neither way of playing is better.")
	print("")

	var header: String = "%-10s" % ""
	for n in names:
		header += "%10s" % n
	print(header + "%10s" % "avg")

	var totals := {}
	for row in names:
		var line: String = "%-10s" % row
		var sum: float = 0.0
		var n: int = 0
		for col in names:
			if row == col:
				line += "%10s" % "-"
				continue
			var r: Dictionary = _run(_policy(arch, row), _policy(arch, col))
			var pct: float = 100.0 * r.left / max(1, r.left + r.right)
			line += "%9.1f%%" % pct
			sum += pct
			n += 1
		totals[row] = sum / max(1, n)
		print(line + "%9.1f%%" % totals[row])

	print("")
	print("A dominant strategy would be a row that beats every column above 60%.")

func _policy(arch: Dictionary, name: String):
	return arch.get(name, null)

# ── Per-card contribution ─────────────────────────────────────────────────

func _card_report() -> void:
	var tuned: Dictionary = FDScorer.weights(FDHardAI.WEIGHTS)
	print("per-card contribution - %d matches, tuned vs tuned, damage_scale %.1f"
		% [MATCHES, FDRules.DAMAGE_SCALE])
	var r: Dictionary = _run(tuned, tuned, true)

	print("")
	print("  SKILL+ USAGE (a rallied skill, covering three lanes)")
	var total_plus: int = 0
	for k in r.plus_by_card:
		total_plus += int(r.plus_by_card[k])
	for card_name in CardStats.ORDER:
		var used: int = int(r.plus_by_card.get(card_name, 0))
		var plain: int = int(r.skill_by_card.get(card_name, 0))
		print("    %-6s+   %6d   (%4.1f%% of all skill+ casts, %4.1f%% of this card's skills)"
			% [FDCard.skill_word_for(card_name), used, _pct(used, total_plus), _pct(used, plain)])

	print("")
	print("  HP REMOVED, by the card that removed it")
	var total_dmg: int = 0
	for k in r.dmg_by_card:
		total_dmg += int(r.dmg_by_card[k])
	for card_name in CardStats.ORDER:
		print("    %-6s     %6d  (%4.1f%%)   kills %3d   wasted actions %4d"
			% [card_name, int(r.dmg_by_card.get(card_name, 0)),
				_pct(int(r.dmg_by_card.get(card_name, 0)), total_dmg),
				int(r.kills_by_card.get(card_name, 0)),
				int(r.waste_by_card.get(card_name, 0))])

	print("")
	print("  SURVIVAL (how often each card was still alive when the match ended)")
	for card_name in CardStats.ORDER:
		print("    %-6s     %5.1f%%   died first %4d times"
			% [card_name, _pct(int(r.alive_at_end.get(card_name, 0)), r.matches),
				int(r.died_first.get(card_name, 0))])

func _pct(n, d) -> float:
	return 100.0 * float(n) / float(max(1, d))

# ── Match loop ────────────────────────────────────────────────────────────

func _run(left_w, right_w, detail: bool = false) -> Dictionary:
	var r := {
		"left": 0, "right": 0, "draw": 0, "matches": 0,
		"plus_by_card": {}, "skill_by_card": {}, "dmg_by_card": {},
		"kills_by_card": {}, "waste_by_card": {},
		"alive_at_end": {}, "died_first": {},
	}

	for m in range(MATCHES):
		var rng := RandomNumberGenerator.new()
		rng.seed = 5000 + m
		var left: int = FDState.BLACK if m % 2 == 0 else FDState.RED
		var right: int = FDState.RED if left == FDState.BLACK else FDState.BLACK

		var s := FDRules.new_match(left)
		var guard := 0
		var first_dead: String = ""
		while not s.is_over() and guard < GUARD:
			guard += 1
			if s.phase == FDState.Phase.POSITIONING:
				FDRules.commit_placement(s, left, FDRules.auto_place(s, left, rng))
				FDRules.commit_placement(s, right, FDRules.auto_place(s, right, rng))
				continue
			var side: int = s.side_to_act
			var w = left_w if side == left else right_w
			var action: Dictionary = _act(w, s, side, rng)
			if action.is_empty():
				break
			var res := FDRules.resolve(s, side, action)
			if not res.ok:
				print("  STRATEGY ERROR: %s -> %s" % [action, res.error])
				break
			if detail:
				# Deaths are tracked on EVERY action, not just our own: a card
				# of ours almost always dies on the opponent's turn, so gating
				# this on `side == left` reported "died first: 0 times" for all
				# five cards and looked like a real result.
				if first_dead == "":
					for ev in res.events:
						if ev.get("t", "") == "death":
							var d: FDCard = s.card_by_id(ev.card)
							if d != null and d.side == left:
								first_dead = d.card_name
								break
				if side == left:
					_tally(s, left, action, res.events, r)
			FDRules.advance(s)

		if guard >= GUARD:
			continue
		r.matches += 1
		if detail:
			for c in s.team(left):
				if c.alive:
					r.alive_at_end[c.card_name] = int(r.alive_at_end.get(c.card_name, 0)) + 1
			if first_dead != "":
				r.died_first[first_dead] = int(r.died_first.get(first_dead, 0)) + 1
		var won := FDRules.winner(s)
		if won == left:
			r.left += 1
		elif won == right:
			r.right += 1
		else:
			r.draw += 1
	return r

func _tally(s: FDState, left: int, action: Dictionary, events: Array, r: Dictionary) -> void:
	var actor: FDCard = s.card_by_id(action.card_id)
	if action.kind == "skill":
		r.skill_by_card[actor.card_name] = int(r.skill_by_card.get(actor.card_name, 0)) + 1

	for ev in events:
		match ev.get("t", ""):
			"skill":
				if int(ev.get("spread", 0)) == FDRules.Spread.THREE and _side(s, ev.actor) == left:
					var nm: String = s.card_by_id(ev.actor).card_name
					r.plus_by_card[nm] = int(r.plus_by_card.get(nm, 0)) + 1
			"hit":
				if _side(s, ev.actor) == left:
					var a: String = s.card_by_id(ev.actor).card_name
					r.dmg_by_card[a] = int(r.dmg_by_card.get(a, 0)) + int(ev.hp_lost)
			"death":
				var d: FDCard = s.card_by_id(ev.card)
				if d != null and d.side != left:
					var k: String = actor.card_name
					r.kills_by_card[k] = int(r.kills_by_card.get(k, 0)) + 1
			# An action that hit a corpse or an empty slot: the decoy worked.
			"decoy_hit", "whiff":
				if _side(s, ev.get("actor", -1)) == left:
					var wname: String = actor.card_name
					r.waste_by_card[wname] = int(r.waste_by_card.get(wname, 0)) + 1

func _side(s: FDState, id: int) -> int:
	var c: FDCard = s.card_by_id(id)
	return c.side if c != null else -1

func _act(w, s: FDState, side: int, rng: RandomNumberGenerator) -> Dictionary:
	if w == null:
		var un: Array = s.unacted(side)
		if un.is_empty():
			return {}
		var c: FDCard = un[0]
		return {"card_id": c.id, "kind": "attack", "target_slot": s.slot_of(c)}
	return FDScorer.choose_action(s, side, w, rng)
