extends SceneTree

# Headless test entry point for the face-down rules engine.
#
#   godot --headless --path RemiShowdown --script res://test/run_tests.gd
#
# Exits 0 when every assertion passes, 1 otherwise, so it can gate a commit.

func _initialize() -> void:
	var failed := 0
	var total := 0

	# Both rules engines are pure and both run here. Face-up used to have no
	# entry in this list at all - its rules lived inside table2.gd, so the only
	# way to exercise one was to instantiate the board scene.
	for suite in [FDRulesTests.new(), FURulesTests.new()]:
		suite.run_all()
		for r in suite.results:
			total += 1
			if r.pass:
				print("  PASS  ", r.name)
			else:
				failed += 1
				print("  FAIL  ", r.name, "   (", r.detail, ")")

	print("")
	print("%d assertions, %d failed" % [total, failed])

	# A smoke match, so a rules change that deadlocks the turn loop or never
	# reaches a winner is caught here rather than in the UI at M2.
	var smoke := _smoke_match()
	print(smoke)
	if smoke.begins_with("SMOKE FAIL"):
		failed += 1

	# The real ladder AI must also drive a match to a winner without ever
	# proposing an illegal action (PRD 11 / PLAN M3).
	var ai := _ai_match()
	print(ai)
	if ai.begins_with("AI FAIL"):
		failed += 1

	# Face-up mode must be unaffected by the move to the shared stat table.
	var faceup := _faceup_regression()
	print(faceup)
	if faceup.begins_with("FACEUP FAIL"):
		failed += 1

	# Both stat tables have to be complete and correctly routed.
	var tables := _stat_tables()
	print(tables)
	if tables.begins_with("STATS FAIL"):
		failed += 1

	# The same smoke test the face-down engine gets: a full match driven by
	# random legal actions has to terminate and produce a winner.
	var fu_smoke := _faceup_smoke_match()
	print(fu_smoke)
	if fu_smoke.begins_with("FU SMOKE FAIL"):
		failed += 1

	quit(1 if failed > 0 else 0)

# Both stat tables, checked for the two things splitting them made possible.
#
# The first is completeness: there are two tables now, so a card can go missing
# from one of them, and a missing key is a crash at match setup rather than a
# wrong number.
#
# The second is routing, and it comes with an honest limitation. The two tables
# hold IDENTICAL numbers today - the split was structural, not a rebalance - so
# if table_of() had its modes crossed, nothing here could tell. Reference
# identity would have caught it, but GDScript copies a `const` container on
# every access, so is_same() is false even for a correct lookup.
#
# What this checks is therefore contents, and it is deliberately vacuous while
# the numbers coincide. It starts working the moment the tables diverge - which
# is exactly the moment a crossed lookup would start producing strange results
# that someone would otherwise spend a day attributing to their own tuning.
func _stat_tables() -> String:
	for mode in [CardStats.FACE_UP, CardStats.FACE_DOWN]:
		var label: String = "FACE_UP" if mode == CardStats.FACE_UP else "FACE_DOWN"
		var table: Dictionary = CardStats.table_of(mode)
		if table.size() != CardStats.ORDER.size():
			return "STATS FAIL: %s holds %d cards, ORDER names %d" % [
				label, table.size(), CardStats.ORDER.size()]
		for card_name in CardStats.ORDER:
			if not CardStats.has_card(card_name, mode):
				return "STATS FAIL: %s has no %s" % [label, card_name]
			for key in ["hp", "atk", "skill"]:
				if not table[card_name].has(key):
					return "STATS FAIL: %s %s has no %s" % [label, card_name, key]
			if CardStats.hp_of(card_name, mode) <= 0:
				return "STATS FAIL: %s %s has no HP" % [label, card_name]
			# A rallied value defaults to the unrallied one, so it is never
			# absent - only ever equal.
			if CardStats.rallied_skill_of(card_name, mode) <= 0 \
					and CardStats.skill_of(card_name, mode) > 0:
				return "STATS FAIL: %s %s spreads for nothing" % [label, card_name]

	if CardStats.table_of(CardStats.FACE_UP) != CardStats.STATS_FACEUP:
		return "STATS FAIL: FACE_UP is routed to the wrong table"
	if CardStats.table_of(CardStats.FACE_DOWN) != CardStats.STATS_FACEDOWN:
		return "STATS FAIL: FACE_DOWN is routed to the wrong table"
	var same: bool = CardStats.STATS_FACEUP == CardStats.STATS_FACEDOWN
	return "STATS OK: both tables complete%s" % (
		", and still holding identical numbers - the routing check above cannot"
		+ " fail until they diverge" if same else ", and they have diverged")

# A whole face-up match, headless, picking uniformly from legal_actions(). It
# catches a rules change that deadlocks the slot walk or never reaches a winner
# - which before FURules could only be caught by watching the board hang.
func _faceup_smoke_match() -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var worst := 0
	for trial in range(40):
		var s := FURules.new_match(FUState.BLACK, rng)
		FURules.start(s)
		var guard := 0
		while not s.is_over() and guard < 2000:
			guard += 1
			var options := FURules.legal_actions(s)
			if options.is_empty():
				return "FU SMOKE FAIL: no legal action at slot %d for side %d" % [
					s.current_slot, s.current_suit]
			var res := FURules.resolve(s, options[rng.randi_range(0, options.size() - 1)])
			if not res.ok:
				return "FU SMOKE FAIL: legal action rejected - %s" % res.error
		if guard >= 2000:
			return "FU SMOKE FAIL: match did not terminate in 2000 actions"
		if FURules.winner(s) == 0:
			return "FU SMOKE FAIL: match ended undecided"
		worst = maxi(worst, guard)
	return "FU SMOKE OK: 40 random matches all reached a winner (worst %d actions)" % worst

# The five face-up card scenes must report exactly what the FACE-UP table holds.
#
# This began life as a frozen-literal check proving the move to a shared stat
# table changed no numbers. The tables are separate again now, and the invariant
# has narrowed accordingly: it is no longer "the two modes agree" - they are
# meant not to - it is that the card SCENES agree with the table they claim to
# read. A scene that quietly went back to its own literals would be invisible
# otherwise, because nothing else instantiates them.
func _faceup_regression() -> String:
	var scenes := {
		"res://Scene/Card/ace.tscn": "Ace",
		"res://Scene/Card/jack.tscn": "Jack",
		"res://Scene/Card/queen.tscn": "Queen",
		"res://Scene/Card/king.tscn": "King",
		"res://Scene/Card/joker.tscn": "Joker",
	}
	for path in scenes:
		var want_name: String = scenes[path]
		var packed: PackedScene = load(path)
		if packed == null:
			return "FACEUP FAIL: cannot load %s" % path
		var inst = packed.instantiate()
		inst.set_stats()  # _ready() needs the tree; the stat wiring does not
		var ok: bool = inst.cardClassName == want_name 			and inst.maxHP == CardStats.hp_of(want_name, CardStats.FACE_UP) 			and inst.attack == CardStats.atk_of(want_name, CardStats.FACE_UP) 			and inst.skill == CardStats.skill_of(want_name, CardStats.FACE_UP)
		if not ok:
			var got := "%s %d/%d/%d" % [inst.cardClassName, inst.maxHP, inst.attack, inst.skill]
			var expected := "%s %d/%d/%d" % [
				want_name, CardStats.hp_of(want_name, CardStats.FACE_UP),
				CardStats.atk_of(want_name, CardStats.FACE_UP), CardStats.skill_of(want_name, CardStats.FACE_UP),
			]
			inst.free()
			return "FACEUP FAIL: %s reports %s, CardStats says %s" % [path, got, expected]
		if inst.maxShield != CardStats.MAX_SHIELD_FACEUP:
			inst.free()
			return "FACEUP FAIL: %s maxShield changed" % path
		inst.free()
	return "FACEUP OK: all five cards match CardStats"

# Plays a full AI-vs-AI match with a trivial always-attack policy and a fixed
# seed. Only checks that a match terminates and produces a winner.
func _smoke_match() -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var s := FDRules.new_match(FDState.BLACK)
	var guard := 0

	while not s.is_over() and guard < 2000:
		guard += 1
		if s.phase == FDState.Phase.POSITIONING:
			FDRules.commit_placement(s, FDState.BLACK, FDRules.auto_place(s, FDState.BLACK, rng))
			FDRules.commit_placement(s, FDState.RED, FDRules.auto_place(s, FDState.RED, rng))
			continue
		var options := FDRules.legal_actions(s, s.side_to_act)
		if options.is_empty():
			return "SMOKE FAIL: no legal action for side %d in round %d" % [s.side_to_act, s.round_no]
		var attacks: Array = []
		for a in options:
			if a.kind == "attack":
				attacks.append(a)
		var pick = attacks[rng.randi_range(0, attacks.size() - 1)]
		var res := FDRules.resolve(s, s.side_to_act, pick)
		if not res.ok:
			return "SMOKE FAIL: %s" % res.error
		FDRules.advance(s)

	if guard >= 2000:
		return "SMOKE FAIL: match did not terminate in 2000 steps"
	var w := FDRules.winner(s)
	return "SMOKE OK: winner=%d after %d rounds" % [w, s.round_no]

# FDAI against itself, seeded. Catches an AI that stalls, cheats its way into an
# illegal action, or never finishes a match. Runs headless: fd_ai.gd, like the
# rules engine, touches no scene.
func _ai_match() -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = 987654
	var s := FDRules.new_match(FDState.BLACK)
	var guard := 0
	var actions := 0
	var skills := 0

	while not s.is_over() and guard < 4000:
		guard += 1
		if s.phase == FDState.Phase.POSITIONING:
			for side in [FDState.BLACK, FDState.RED]:
				var placed := FDRules.commit_placement(s, side, FDAI.place_slots(s, side, rng))
				if not placed.ok:
					return "AI FAIL: placement rejected - %s" % placed.error
			continue
		var side_now: int = s.side_to_act
		var action := FDAI.choose_action(s, side_now, rng)
		if action.is_empty():
			return "AI FAIL: no action offered for side %d in round %d" % [side_now, s.round_no]
		var res := FDRules.resolve(s, side_now, action)
		if not res.ok:
			return "AI FAIL: illegal action %s - %s" % [action, res.error]
		actions += 1
		if action.kind == "skill":
			skills += 1
		FDRules.advance(s)

	if guard >= 4000:
		return "AI FAIL: match did not terminate in 4000 steps"
	if skills == 0:
		return "AI FAIL: never used a skill in %d actions" % actions
	return "AI OK: winner=%d after %d rounds, %d actions (%d skills)" % [
		FDRules.winner(s), s.round_no, actions, skills,
	]
