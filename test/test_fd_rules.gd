extends RefCounted
class_name FDRulesTests

# M1 exit criteria — PLAN §7. Runs entirely headless: no scene, no window.
#   godot --headless --path RemiShowdown --script res://test/run_tests.gd

const BLACK := FDState.BLACK
const RED := FDState.RED

var results: Array = []

func _ok(cond: bool, name: String, detail: String = "") -> void:
	results.append({"pass": cond, "name": name, "detail": detail})

func _eq(got, want, name: String) -> void:
	_ok(got == want, name, "got %s, want %s" % [str(got), str(want)])

# ── Scaffolding ───────────────────────────────────────────────────────────

# Deterministic placement: living cards in creation order (Ace, Jack, Queen,
# King, Joker), then corpses. With a full team, slot index == that order.
func _ids(s: FDState, side: int) -> Array:
	var row: Array = []
	for c in s.living(side):
		row.append(c.id)
	for c in s.dead(side):
		if row.size() >= s.board_size:
			break
		row.append(c.id)
	return row

func _place_both(s: FDState) -> void:
	FDRules.commit_placement(s, BLACK, _ids(s, BLACK))
	FDRules.commit_placement(s, RED, _ids(s, RED))

func _match() -> FDState:
	var s := FDRules.new_match(BLACK)
	_place_both(s)
	return s

# Resolve one action without going through turn alternation, so a rule test is
# not also a turn-order test. Turn order gets its own tests (T19/T20).
func _act(s: FDState, side: int, card_name: String, kind: String, target_slot: int = -1) -> Dictionary:
	var c := s.find_by_name(side, card_name)
	if c == null:
		return {"ok": false, "error": "no %s" % card_name, "events": []}
	s.side_to_act = side
	return FDRules.resolve(s, side, {
		"card_id": c.id, "kind": kind,
		"target_slot": target_slot if target_slot >= 0 else s.slot_of(c),
	})

# A real round transition: burn every remaining action, let advance() roll the
# round over, then re-place identically so slot indices stay predictable.
func _next_round(s: FDState) -> void:
	for side in [BLACK, RED]:
		for c in s.living(side):
			s.acted[side][c.id] = true
	FDRules.advance(s)
	if s.is_over():
		return
	_place_both(s)

# ── Tests ─────────────────────────────────────────────────────────────────

func run_all() -> void:
	t01_king_rallies_jack()
	t02_rallied_skill_consumes()
	t03_king_acts_again_clears()
	t04_self_rally_arms_plus()
	t05_trick_peels_one_of_a_spread()
	t06_trick_strips_rally()
	t07_trick_nullifies()
	t08_joker_acts_again()
	t09_king_frees_nullified()
	t10_last_rally()
	t11_board_size()
	t12_decoy_whiff()
	t13_shield_replaces_never_stacks()
	t14_shield_always_leaks()
	t15_shield_is_tied_to_its_ace()
	t16_heal_clamps()
	t17_rallied_skill_covers_three()
	t18_reveals_reset()
	t19_alternation_and_skips()
	t20_initiative_alternates()
	t21_trick_halves_attack()
	t22_attack_reach()
	t24_buff_a_corpse()

func t01_king_rallies_jack() -> void:
	var s := _match()
	_act(s, BLACK, "King", "skill", 1)  # slot 1 = Jack
	var jack := s.find_by_name(BLACK, "Jack")
	var king := s.find_by_name(BLACK, "King")
	_ok(jack.rallied, "T1 Jack is rallied")
	_eq(jack.rally_king, king.id, "T1 rally tied to that King")
	# An unarmed King rallies ONE ally; the neighbours are untouched.
	_ok(not s.find_by_name(BLACK, "Ace").rallied, "T1 slot 0 not rallied")
	_ok(not s.find_by_name(BLACK, "Queen").rallied, "T1 slot 2 not rallied")

func t02_rallied_skill_consumes() -> void:
	var s := _match()
	_act(s, BLACK, "King", "skill", 1)
	_next_round(s)
	_act(s, BLACK, "Jack", "skill", 0)
	var jack := s.find_by_name(BLACK, "Jack")
	_ok(not jack.rallied, "T2 rally consumed by skill use")
	_eq(jack.rally_king, FDCard.NONE, "T2 rally source cleared")

func t03_king_acts_again_clears() -> void:
	var s := _match()
	_act(s, BLACK, "King", "skill", 1)
	_next_round(s)
	_act(s, BLACK, "King", "attack")
	var jack := s.find_by_name(BLACK, "Jack")
	_ok(not jack.rallied, "T3 King acting again clears its rally")

func t04_self_rally_arms_plus() -> void:
	var s := _match()
	_act(s, BLACK, "King", "skill", 3)  # slot 3 = King itself
	var king := s.find_by_name(BLACK, "King")
	_ok(king.king_plus, "T4 self-rally arms king_plus")
	_ok(not king.rallied, "T4 self-rally does not rally the King")

	# An armed King spends the arm to rally a three-lane spread of allies
	# rather than to widen one ally's skill.
	_next_round(s)
	_act(s, BLACK, "King", "skill", 1)   # centred on slot 1
	_ok(not king.king_plus, "T4 king_plus consumed")
	_ok(s.find_by_name(BLACK, "Ace").rallied, "T4 rally+ reaches slot 0")
	_ok(s.find_by_name(BLACK, "Jack").rallied, "T4 rally+ reaches slot 1")
	_ok(s.find_by_name(BLACK, "Queen").rallied, "T4 rally+ reaches slot 2")
	_ok(not s.find_by_name(BLACK, "Joker").rallied, "T4 ...and no further")

	# An armed rally+ is not peelable (see FDRules._do_trick). A trick on an
	# armed King seals its skill like any other card, but must NOT cost it the
	# arm - that fall-through is the whole reason arming is worth doing.
	var s5 := _match()
	var k5: FDCard = s5.find_by_name(BLACK, "King")
	var j5: FDCard = s5.find_by_name(RED, "Joker")
	k5.king_plus = true
	FDRules._do_trick(j5, k5, [])
	_ok(k5.king_plus, "T23 a trick does not disarm a King's armed rally+")
	_ok(k5.nullified, "T23 ...it seals the King's skill instead")
	k5.clear_nullify()
	_ok(k5.king_plus, "T23 ...and the arm survives the seal lifting")

func t05_trick_peels_one_of_a_spread() -> void:
	# rally+ hands the same ordinary rally to three allies. A Joker gets one
	# action, so it can only take one of them back.
	var s := _match()
	_act(s, BLACK, "King", "skill", 3)   # arm
	_next_round(s)
	_act(s, BLACK, "King", "skill", 1)   # rally+ across slots 0-2
	var ace := s.find_by_name(BLACK, "Ace")
	var jack := s.find_by_name(BLACK, "Jack")
	var queen := s.find_by_name(BLACK, "Queen")
	_ok(ace.rallied and jack.rallied and queen.rallied, "T5 setup: three allies rallied")

	_act(s, RED, "Joker", "skill", 1)    # trick Black slot 1
	_ok(not jack.rallied, "T5 the tricked ally loses its rally")
	_ok(not jack.nullified, "T5 ...and is not also sealed — the rally absorbed it")
	_ok(ace.rallied, "T5 the other two keep theirs")
	_ok(queen.rallied, "T5 the other two keep theirs")

func t06_trick_strips_rally() -> void:
	var s := _match()
	_act(s, BLACK, "King", "skill", 1)
	_act(s, RED, "Joker", "skill", 1)
	var jack := s.find_by_name(BLACK, "Jack")
	_ok(not jack.rallied, "T6 plain rally stripped by trick")
	_ok(not jack.nullified, "T6 not nullified — rally absorbed the trick")

func t07_trick_nullifies() -> void:
	var s := _match()
	_act(s, RED, "Joker", "skill", 1)
	var jack := s.find_by_name(BLACK, "Jack")
	_ok(jack.nullified, "T7 un-rallied target is nullified")

	s.side_to_act = BLACK
	var acts := FDRules.legal_actions(s, BLACK)
	var has_attack := false
	var has_skill := false
	for a in acts:
		if a.card_id == jack.id:
			if a.kind == "attack":
				has_attack = true
			else:
				has_skill = true
	_ok(has_attack, "T7 nullified card may still attack")
	_ok(not has_skill, "T7 nullified card has no legal skill")

	var r := _act(s, BLACK, "Jack", "skill", 0)
	_ok(not r.ok, "T7 resolve() rejects a nullified skill")

func t08_joker_acts_again() -> void:
	var s := _match()
	_act(s, RED, "Joker", "skill", 1)  # nullify Black Jack
	var jack := s.find_by_name(BLACK, "Jack")
	var queen := s.find_by_name(BLACK, "Queen")
	_ok(jack.nullified, "T8 setup: Jack nullified")
	_next_round(s)
	_act(s, RED, "Joker", "skill", 2)  # same Joker, new target
	_ok(not jack.nullified, "T8 old nullify lifted when its Joker acted")
	_ok(queen.nullified, "T8 new target nullified in the same action")

func t09_king_frees_nullified() -> void:
	# Rally and trick are mirror images and each moves a card ONE rung:
	#   tricked <--trick-- regular <--trick-- rallied
	#   tricked --rally--> regular --rally--> rallied
	var s := _match()
	_act(s, RED, "Joker", "skill", 1)
	var jack := s.find_by_name(BLACK, "Jack")
	_ok(jack.nullified, "T9 setup: Jack nullified")

	_act(s, BLACK, "King", "skill", 1)
	_ok(not jack.nullified, "T9 King's rally clears the nullify")
	_ok(not jack.rallied, "T9 ...and that is ALL it does — freeing is one rung")
	_ok(jack.can_use_skill(), "T9 the freed ally has its skill back")

	# A second rally, on a card that is no longer tricked, buys the rally.
	_next_round(s)
	_act(s, BLACK, "King", "skill", 1)
	_ok(jack.rallied, "T9 a further rally then takes it to rallied")

func t10_last_rally() -> void:
	var s := _match()
	_act(s, BLACK, "King", "skill", 1)
	var jack := s.find_by_name(BLACK, "Jack")
	var bking := s.find_by_name(BLACK, "King")
	bking.hp = 1
	# Red King sits in slot 3 facing Black slot 3 — a lane-locked kill.
	_act(s, RED, "King", "attack")
	_ok(not bking.alive, "T10 setup: Black King is dead")
	_ok(jack.rally_last, "T10 orphaned rally becomes a last rally")
	_ok(jack.rallied, "T10 last rally is still an active rally")

	_next_round(s)
	_ok(jack.rally_last, "T10 last rally survives the round transition")
	_act(s, BLACK, "Jack", "skill", 0)
	_ok(not jack.rallied, "T10 last rally clears on skill use")
	_ok(not jack.rally_last, "T10 last-rally flag cleared too")

func t11_board_size() -> void:
	var s := _match()
	_eq(s.board_size, 5, "T11 full teams give N=5")

	# Kill three Black cards; Red still has five.
	for n in ["Ace", "Queen", "Joker"]:
		var c := s.find_by_name(BLACK, n)
		c.alive = false
		c.hp = 0
	s.round_no += 1
	FDRules.begin_round(s)
	_eq(s.board_size, 5, "T11 N = max(2, 5) = 5, short side pads with decoys")
	_place_both(s)
	_eq(s.slots[BLACK].size(), 5, "T11 short side still shows 5 slots")

	# Down to one apiece.
	for n in ["King"]:
		var c := s.find_by_name(BLACK, n)
		c.alive = false
		c.hp = 0
	for n in ["Ace", "Queen", "King", "Joker"]:
		var c := s.find_by_name(RED, n)
		c.alive = false
		c.hp = 0
	s.round_no += 1
	FDRules.begin_round(s)
	_eq(s.board_size, 1, "T11 1v1 collapses to a single slot")

func t12_decoy_whiff() -> void:
	var s := _match()
	# Kill Red Ace, then re-place so the corpse sits in slot 0.
	var race := s.find_by_name(RED, "Ace")
	race.alive = false
	race.hp = 0
	s.round_no += 1
	FDRules.begin_round(s)
	var red_row: Array = [race.id]
	for c in s.living(RED):
		red_row.append(c.id)
	FDRules.commit_placement(s, RED, red_row)
	FDRules.commit_placement(s, BLACK, _ids(s, BLACK))

	var before := race.hp
	var r := _act(s, BLACK, "Ace", "attack")  # Black Ace in slot 0 hits the corpse
	_eq(race.hp, before, "T12 attacking a decoy deals no damage")
	_ok(s.is_revealed(RED, 0), "T12 decoy slot is revealed")
	var saw_decoy := false
	for e in r.events:
		if e.t == "decoy_hit":
			saw_decoy = true
	_ok(saw_decoy, "T12 decoy_hit event emitted")

func t13_shield_replaces_never_stacks() -> void:
	var s := _match()
	var ace := s.find_by_name(BLACK, "Ace")
	var grant: int = CardStats.skill_of("Ace", CardStats.FACE_DOWN)
	_act(s, BLACK, "Ace", "skill", s.slot_of(ace))  # shield self
	_eq(ace.shield, grant, "T13 one Ace use grants its full skill value")

	_next_round(s)
	_act(s, BLACK, "Ace", "skill", s.slot_of(ace))
	_eq(ace.shield, grant, "T13 a second use replaces the first, it does not stack")

	# Moving the shield to someone else strips it off the old holder.
	_next_round(s)
	var jack := s.find_by_name(BLACK, "Jack")
	_act(s, BLACK, "Ace", "skill", s.slot_of(jack))
	_eq(jack.shield, grant, "T13 shield moved to Jack")
	_eq(ace.shield, 0, "T13 ...and left the Ace")

func t14_shield_always_leaks() -> void:
	# A shield never fully stops a hit: a fraction always reaches HP, which is
	# what makes an unkillable defensive wall impossible.
	# The shield has to be comfortably larger than the hit for this case to be
	# about the LEAK rather than about the pool running dry - that is what the
	# "spent shield" case below is for. A hard-coded 15 stopped being large
	# enough the moment SHIELD_LEAK dropped to 0.10, so it is derived now.
	var c := FDCard.create(0, BLACK, "Jack")
	var leak: int = FDCard.leak_of(18)
	c.shield = 18 - leak + 3
	var pool: int = c.shield
	var res := c.take_hit(18)
	_ok(pool > 18 - leak, "T14 setup: shield outlasts the hit")
	_eq(res.absorbed, 18 - leak, "T14 shield absorbs everything except the leak")
	_eq(res.hp_lost, leak, "T14 the leak reaches HP")
	_eq(c.shield, pool - (18 - leak), "T14 shield spent down by what it absorbed")
	_eq(c.hp, 45 - leak, "T14 Jack lost exactly the leak")

	# Even a hit smaller than the rounding still costs at least one HP.
	var d := FDCard.create(1, BLACK, "King")
	d.shield = d.max_shield
	var tiny := d.take_hit(1)
	_eq(tiny.hp_lost, CardStats.SHIELD_LEAK_MIN, "T14 a 1-damage poke still costs 1 HP")
	_ok(d.shield == d.max_shield, "T14 ...and the shield absorbed none of it")

	# Once the shield runs out the rest lands normally.
	var e := FDCard.create(2, BLACK, "Queen")
	e.shield = 5
	var big := e.take_hit(26)
	_eq(big.absorbed, 5, "T14 a spent shield absorbs only what it had")
	_eq(big.hp_lost, 21, "T14 the remainder lands in full")

	# The property that matters: shields delay death, they cannot prevent it.
	var w := FDCard.create(3, BLACK, "King")
	var rounds := 0
	while w.alive and rounds < 500:
		rounds += 1
		w.shield = w.max_shield
		w.take_hit(14)
	_ok(not w.alive, "T14 a fully re-shielded card still dies under sustained fire")

func t15_shield_is_tied_to_its_ace() -> void:
	var grant: int = CardStats.skill_of("Ace", CardStats.FACE_DOWN)
	# A shield behaves like a trick, not like a permanent pool: it is held up by
	# the Ace that cast it, lapses when that Ace acts again, and dies with it.
	var s := _match()
	var ace := s.find_by_name(BLACK, "Ace")
	var jack := s.find_by_name(BLACK, "Jack")
	_act(s, BLACK, "Ace", "skill", s.slot_of(jack))
	_eq(jack.shield, grant, "T15 setup: Jack shielded")
	_eq(jack.shield_ace, ace.id, "T15 shield records its Ace")

	_next_round(s)
	_eq(jack.shield, grant, "T15 shield survives the round boundary itself")

	# The Ace acting again drops what it was holding up.
	_act(s, BLACK, "Ace", "attack", 0)
	_eq(jack.shield, 0, "T15 shield lapses when its Ace acts again")

	# And it dies with the Ace.
	var s2 := _match()
	var ace2 := s2.find_by_name(BLACK, "Ace")
	var queen2 := s2.find_by_name(BLACK, "Queen")
	_act(s2, BLACK, "Ace", "skill", s2.slot_of(queen2))
	_eq(queen2.shield, grant, "T15 setup: Queen shielded")
	ace2.hp = 1
	_act(s2, RED, "Jack", "skill", s2.slot_of(ace2))
	_eq(ace2.alive, false, "T15 setup: Ace killed")
	_eq(queen2.shield, 0, "T15 shield collapses when its Ace dies")

func t16_heal_clamps() -> void:
	var s := _match()
	var queen := s.find_by_name(BLACK, "Queen")
	queen.hp = 35
	_act(s, BLACK, "Queen", "skill", 2)  # heal self, +20
	# Read the ceiling off CardStats rather than writing it out. This line used
	# to say 40, which was the Queen's max HP when it was written; the moment
	# the stat table moved, a rule test started failing for having memorised a
	# number instead of checking a rule. That is the exact drift card_stats.gd
	# exists to prevent, and a test is not exempt from it.
	_eq(queen.hp, CardStats.hp_of("Queen", CardStats.FACE_DOWN), "T16 heal clamps at max_hp")

func t17_rallied_skill_covers_three() -> void:
	# A rally always buys the same thing: three lanes instead of one. There is
	# no wider version - the LINE spread was removed once it measured as worth
	# nothing against a board that is five wide at most and shrinking.
	var s := _match()
	_act(s, BLACK, "King", "skill", 1)   # plain rally onto Jack
	var jack := s.find_by_name(BLACK, "Jack")
	_ok(jack.rallied, "T17 setup: Jack is rallied")

	# Kill Red Ace so slot 0 is a decoy and the shot has something to waste.
	var race := s.find_by_name(RED, "Ace")
	race.alive = false
	race.hp = 0
	_next_round(s)
	var red_row: Array = [race.id]
	for c in s.living(RED):
		red_row.append(c.id)
	s.slots[RED] = red_row

	var hp_before := {}
	for c in s.living(RED):
		hp_before[c.id] = c.hp
	var r := _act(s, BLACK, "Jack", "skill", 1)

	var lanes_hit := 0
	for e in r.events:
		if e.t == "skill":
			lanes_hit = e.lanes.size()
	_eq(lanes_hit, 3, "T17 a rallied skill covers three lanes")
	_ok(lanes_hit < s.board_size, "T17 ...and not the whole board")

	# Reach is paid for with power: a rallied skill hits each of its three lanes
	# for the card's `rallied` value from CardStats, so spreading it is a real
	# choice rather than a free tripling.
	var full: int = CardStats.skill_of("Jack", CardStats.FACE_DOWN)
	var shot: int = FDRules.skill_output("Jack", full, FDRules.Spread.THREE)
	_ok(shot < full, "T17 a rallied shot hits for less than an unrallied one")
	_eq(shot, CardStats.rallied_skill_of("Jack", CardStats.FACE_DOWN), "T17 ...at the table's rallied value")
	for lane in [1, 2]:
		var hit: FDCard = s.card_at(RED, lane)
		if hit != null and hit.alive:
			_eq(hit.hp, hp_before[hit.id] - shot, "T17 %s took a reduced shoot hit" % hit.card_name)

	# An unrallied shot is untouched.
	_eq(FDRules.skill_output("Jack", full, FDRules.Spread.SINGLE), full,
		"T17 an unrallied shot still hits for the printed value")

	# The same rule now governs the Ace, which is what stops a rallied Shield
	# from being strictly the best thing to rally.
	var ace_full: int = CardStats.skill_of("Ace", CardStats.FACE_DOWN)
	_eq(FDRules.skill_output("Ace", ace_full, FDRules.Spread.SINGLE), ace_full,
		"T17 an unrallied shield still grants the printed value")
	_ok(FDRules.skill_output("Ace", ace_full, FDRules.Spread.THREE) < ace_full,
		"T17 a rallied shield grants less per ally")

	# A card with no `rallied` column spreads at full value.
	var q: int = CardStats.skill_of("Queen", CardStats.FACE_DOWN)
	_eq(FDRules.skill_output("Queen", q, FDRules.Spread.THREE), q,
		"T17 a card without a rallied value spreads unchanged")
	_eq(race.hp, 0, "T17 decoy lane absorbed its share harmlessly")

func t18_reveals_reset() -> void:
	var s := _match()
	_act(s, BLACK, "Ace", "attack")
	_ok(s.is_revealed(BLACK, 0), "T18 acting reveals the actor")
	_ok(s.is_revealed(RED, 0), "T18 being attacked reveals the target")
	_next_round(s)
	_ok(not s.is_revealed(BLACK, 0), "T18 reveals reset next positioning phase")
	_ok(not s.is_revealed(RED, 0), "T18 ...on both sides")

func t19_alternation_and_skips() -> void:
	var s := _match()
	_eq(s.side_to_act, BLACK, "T19 leader acts first in round 1")
	FDRules.resolve(s, BLACK, {"card_id": s.find_by_name(BLACK, "Ace").id, "kind": "attack"})
	FDRules.advance(s)
	_eq(s.side_to_act, RED, "T19 strict alternation")

	# Exhaust Red, leave Black with cards: Black must keep acting consecutively.
	for c in s.living(RED):
		s.acted[RED][c.id] = true
	s.side_to_act = BLACK
	FDRules.resolve(s, BLACK, {"card_id": s.find_by_name(BLACK, "Jack").id, "kind": "attack"})
	var status := FDRules.advance(s)
	_eq(status, "continue", "T19 round continues while one side has cards")
	_eq(s.side_to_act, BLACK, "T19 exhausted side is skipped")

func t20_initiative_alternates() -> void:
	var s := _match()
	_eq(s.leader, BLACK, "T20 Black leads round 1")
	_next_round(s)
	_eq(s.round_no, 2, "T20 round advanced")
	_eq(s.leader, RED, "T20 Red leads round 2")
	_next_round(s)
	_eq(s.leader, BLACK, "T20 Black leads round 3")

func t21_trick_halves_attack() -> void:
	# A trick costs the skill AND half the attack, but never the turn itself.
	var s := _match()
	var joker := s.find_by_name(RED, "Joker")
	var king := s.find_by_name(BLACK, "King")
	var full: int = king.attack_value()
	_eq(full, CardStats.atk_of("King", CardStats.FACE_DOWN), "T21 an untricked King swings for its full attack")
	_ok(king.can_use_skill(), "T21 ...and can use its skill")

	_act(s, RED, "Joker", "skill", s.slot_of(king))
	_ok(king.nullified, "T21 setup: King is tricked")
	_eq(king.attack_value(), max(1, int(round(full * CardStats.TRICK_ATTACK_MULT))),
		"T21 a tricked card hits for half")
	_ok(not king.can_use_skill(), "T21 ...and loses its skill")

	# It still gets to act - denying a whole turn is what would stall a match.
	var before := s.card_at(RED, s.slot_of(king))
	var hp_before: int = before.hp if before != null and before.alive else -1
	var r := _act(s, BLACK, "King", "attack", s.slot_of(king))
	_ok(r.ok, "T21 a tricked card can still attack")
	if hp_before > 0:
		_ok(before.hp < hp_before, "T21 ...and its weakened hit still lands")

func t22_attack_reach() -> void:
	# An attack reaches its own lane at full damage or a neighbour for half,
	# and cannot reach further than that.
	var s := _match()
	var jack := s.find_by_name(BLACK, "Jack")
	var here: int = s.slot_of(jack)
	var lanes: Array = FDRules.attack_slots(s, here)
	_ok(here in lanes, "T22 an attack always reaches its own lane")
	for l in lanes:
		_ok(abs(l - here) <= 1, "T22 reach never exceeds one lane")

	var far: int = -1
	for i in range(s.board_size):
		if abs(i - here) > 1:
			far = i
			break
	if far != -1:
		var bad := _act(s, BLACK, "Jack", "attack", far)
		_ok(not bad.ok, "T22 a two-lane reach is rejected")

	# Same target, straight ahead versus from the side.
	var s2 := _match()
	var j2 := s2.find_by_name(BLACK, "Jack")
	var slot: int = s2.slot_of(j2)
	var straight := s2.card_at(RED, slot)
	var hp0: int = straight.hp
	_act(s2, BLACK, "Jack", "attack", slot)
	var full_hit: int = hp0 - straight.hp

	var side_slot: int = -1
	for l in FDRules.attack_slots(s2, slot):
		if l != slot:
			side_slot = l
			break
	if side_slot != -1:
		var s3 := _match()
		var j3 := s3.find_by_name(BLACK, "Jack")
		var victim := s3.card_at(RED, side_slot)
		var hp1: int = victim.hp
		_act(s3, BLACK, "Jack", "attack", side_slot)
		var side_hit: int = hp1 - victim.hp
		_ok(side_hit < full_hit, "T22 a sideways hit lands for less than a straight one")

func t24_buff_a_corpse() -> void:
	# Support skills may be spent on a dead decoy. Nothing happens mechanically;
	# what it buys is that the enemy SEES a buff appear on a face-down slot and
	# cannot tell it from a real one. That is the whole bluff.
	var s := _match()
	var jack := s.find_by_name(BLACK, "Jack")
	jack.alive = false
	jack.hp = 0

	# The corpse moves: _place_both puts the living first and pads with the
	# dead, so its slot has to be looked up rather than assumed.
	_act(s, BLACK, "Ace", "skill", s.slot_of(jack))
	_ok(jack.shield == 0, "T24 shielding a corpse grants no actual shield")
	_ok(jack.shield_ace != FDCard.NONE, "T24 ...but the slot is marked")

	_next_round(s)
	_act(s, BLACK, "Queen", "skill", s.slot_of(jack))
	_ok(jack.mark_tended, "T24 a corpse can be tended")
	_eq(jack.hp, 0, "T24 ...and stays dead")

	_next_round(s)
	_act(s, BLACK, "King", "skill", s.slot_of(jack))
	_ok(jack.rallied, "T24 a corpse can be rallied")

	# What Red sees: a face-down slot carrying buffs, with no way to tell that
	# the card behind it is a corpse.
	var o: Dictionary = s.observe(RED, s.slot_of(jack))
	_ok(not o.get("known", true), "T24 the bluffed slot is still face down to Red")
	_ok(o.get("rallied", false), "T24 Red sees the rally on it")
	_ok(not o.has("alive"), "T24 Red is not told whether it is alive")

	# A living, unbuffed slot must look different, or the mark says nothing.
	var ace := s.find_by_name(BLACK, "Ace")
	var live: Dictionary = s.observe(RED, s.slot_of(ace))
	_ok(not live.get("rallied", false), "T24 an unbuffed slot carries no mark")

	# The distinction that matters: the RALLY carries over rounds, the MEMORY of
	# having seen it does not. Otherwise the mark would follow the card into
	# whatever slot it moved to and quietly report its new position, which is
	# precisely what repositioning is supposed to hide.
	var before: int = s.slot_of(jack)
	_ok(s.observe(RED, before).get("rallied", false), "T24 the mark shows this round")

	_next_round(s)
	_ok(jack.rallied, "T24 the rally itself survives the round")
	_ok(not jack.mark_tended, "T24 the tended mark is wiped")
	_ok(not jack.mark_rallied, "T24 the rallied mark is wiped")
	for slot in range(s.board_size):
		var seen: Dictionary = s.observe(RED, slot)
		if seen.get("known", false):
			continue
		_ok(not seen.get("rallied", false),
			"T24 no face-down slot advertises a buff after repositioning (slot %d)" % slot)
