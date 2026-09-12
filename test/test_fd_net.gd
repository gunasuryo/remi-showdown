extends SceneTree

# Wire-format tests for networked play.
#
#   godot --headless --path RemiShowdown --script res://test/test_fd_net.gd
#
# The one that matters is N3: a snapshot must not contain the identity of any
# enemy card the viewer has not revealed. Everything else here is round-tripping;
# N3 is the reason the authoritative model was chosen over lockstep, and if it
# ever fails the game is cheatable by reading a packet.

var passed := 0
var failed := 0

func _ok(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		passed += 1
		print("  PASS  %s" % name)
	else:
		failed += 1
		print("  FAIL  %s   %s" % [name, detail])

func _eq(got, want, name: String) -> void:
	_ok(got == want, name, "got %s, want %s" % [str(got), str(want)])

func _initialize() -> void:
	print("face-down wire format")
	var rng := RandomNumberGenerator.new()
	rng.seed = 99

	# A match a few actions in, so some cards are revealed and some are not.
	var s := FDRules.new_match(FDState.BLACK)
	FDRules.commit_placement(s, FDState.BLACK, FDRules.auto_place(s, FDState.BLACK, rng))
	FDRules.commit_placement(s, FDState.RED, FDRules.auto_place(s, FDState.RED, rng))
	for i in range(3):
		var side: int = s.side_to_act
		var a: Dictionary = FDHardAI.choose_action(s, side, rng)
		FDRules.resolve(s, side, a)
		FDRules.advance(s)

	# The maximum-secrecy case: a round that has just started, where the whole
	# enemy row is hidden. This is the state redaction exists for, and testing
	# only a mid-round snapshot left four of five lanes already revealed.
	var fresh := FDRules.new_match(FDState.BLACK)
	FDRules.commit_placement(fresh, FDState.BLACK, FDRules.auto_place(fresh, FDState.BLACK, rng))
	FDRules.commit_placement(fresh, FDState.RED, FDRules.auto_place(fresh, FDState.RED, rng))

	n1_action_shape()
	n0_nothing_revealed(fresh)
	n2_round_trip(s)
	n3_no_secret_leaks(s)
	n4_hidden_reads_as_facedown(s)
	n5_hostile_input()
	n6_buffs_cross_the_wire(fresh)
	n7_events_are_redacted(fresh)
	n8_redaction_happens_before_advance()

	print("")
	print("%d assertions, %d failed" % [passed + failed, failed])
	quit(1 if failed > 0 else 0)

# With no reveals at all, the packet must not name a single enemy position.
func n0_nothing_revealed(s: FDState) -> void:
	var snap := FDNet.snapshot(s, FDState.BLACK)
	var wire := FDNet.restore(snap)

	var hidden := 0
	for slot in range(s.board_size):
		_eq(int(wire.slots[FDState.RED][slot]), FDCard.HIDDEN,
			"N0 enemy slot %d is withheld entirely" % slot)
		_eq(wire.observe(FDState.BLACK, slot).get("known", true), false,
			"N0 enemy slot %d reads as unknown" % slot)
		_eq(wire.observe(FDState.BLACK, slot).get("empty", true), false,
			"N0 enemy slot %d still reads as occupied" % slot)
		hidden += 1
	_eq(hidden, s.board_size, "N0 the whole enemy row was hidden")

	# No enemy hp anywhere: every RED card should carry only name and alive.
	for raw in snap.cards:
		if int(raw.side) == FDState.RED:
			_ok(not raw.has("hp"), "N0 enemy %s sends no hp" % str(raw.name))
			_ok(not raw.has("shield"), "N0 enemy %s sends no shield" % str(raw.name))

	# Our own row, by contrast, must be entirely present - the board draws it.
	for slot in range(s.board_size):
		_ok(wire.card_at(FDState.BLACK, slot) != null,
			"N0 own slot %d is fully present" % slot)

func n1_action_shape() -> void:
	var a := FDNet.encode_action(3, "skill", 2)
	_ok(FDNet.valid_action(a), "N1 a well-formed action validates")
	_eq(FDNet.action_from(a).card_id, 3, "N1 action survives encoding")
	_ok(not FDNet.valid_action({"t": "action", "kind": "dance", "card_id": 1, "target_slot": 0}),
		"N1 an unknown action kind is rejected")
	_ok(not FDNet.valid_action({"t": "chat"}), "N1 a non-action is rejected")
	_ok(FDNet.valid_placement(FDNet.encode_placement([1, 2, 3])), "N1 a placement validates")
	_ok(not FDNet.valid_placement({"t": "place", "slots": "nope"}), "N1 a bogus placement is rejected")

func n2_round_trip(s: FDState) -> void:
	var snap := FDNet.snapshot(s, FDState.BLACK)
	var c := FDNet.restore(FDNet.from_bytes(FDNet.to_bytes(snap)))
	_eq(c.round_no, s.round_no, "N2 round survives the wire")
	_eq(c.board_size, s.board_size, "N2 board size survives")
	_eq(c.side_to_act, s.side_to_act, "N2 turn survives")
	_eq(c.phase, s.phase, "N2 phase survives")
	_eq(c.living_count(FDState.BLACK), s.living_count(FDState.BLACK), "N2 own living count survives")
	# Public even though it is the opponent's: the roster shows it and every
	# death is announced.
	_eq(c.living_count(FDState.RED), s.living_count(FDState.RED), "N2 enemy living count survives")

	# The viewer's own row must come back exactly.
	for slot in range(s.board_size):
		var mine_real: FDCard = s.card_at(FDState.BLACK, slot)
		var mine_wire: FDCard = c.card_at(FDState.BLACK, slot)
		_ok(mine_real == null or (mine_wire != null and mine_wire.card_name == mine_real.card_name),
			"N2 own slot %d survives" % slot)
		if mine_real != null and mine_wire != null:
			_eq(mine_wire.hp, mine_real.hp, "N2 own slot %d hp survives" % slot)

	# And observe() must say the same thing on both sides of the wire.
	for slot in range(s.board_size):
		_eq(c.observe(FDState.BLACK, slot), s.observe(FDState.BLACK, slot),
			"N2 observe(slot %d) is identical after redaction" % slot)

func n3_no_secret_leaks(s: FDState) -> void:
	var raw: String = FDNet.to_bytes(FDNet.snapshot(s, FDState.BLACK)).get_string_from_utf8()

	# Every RED card standing in a slot Black has not revealed is a secret. Its
	# position must not be recoverable from the packet.
	var hidden_ids: Array = []
	for slot in range(s.board_size):
		if not s.is_revealed(FDState.RED, slot):
			var c: FDCard = s.card_at(FDState.RED, slot)
			if c != null:
				hidden_ids.append(c.id)
	_ok(hidden_ids.size() > 0, "N3 setup: at least one enemy card is still hidden")

	var wire := FDNet.restore(FDNet.from_bytes(raw.to_utf8_buffer()))
	for id in hidden_ids:
		# The id may legitimately appear - the roster needs the card - but it
		# must not be findable in the enemy ROW, which is the actual secret.
		_ok(not (id in wire.slots[FDState.RED]),
			"N3 hidden enemy id %d is not in the transmitted row" % id)

	# Nor may its situational detail be present: hp is the tell that would let a
	# cheat rank which lane is worth hitting.
	for id in hidden_ids:
		var c: FDCard = wire.card_by_id(id)
		if c == null:
			continue
		var real: FDCard = s.card_by_id(id)
		if real.hp != real.max_hp:
			_ok(c.hp != real.hp, "N3 wounded hidden enemy %d does not leak its hp" % id)

	# The redacted row must still be the right length, or the board would draw
	# the wrong number of lanes.
	_eq(wire.slots[FDState.RED].size(), s.slots[FDState.RED].size(),
		"N3 redacted row keeps its length")

func n4_hidden_reads_as_facedown(s: FDState) -> void:
	var wire := FDNet.restore(FDNet.snapshot(s, FDState.BLACK))
	for slot in range(s.board_size):
		var o: Dictionary = wire.observe(FDState.BLACK, slot)
		if s.is_revealed(FDState.RED, slot):
			continue
		var occupied: bool = s.card_at(FDState.RED, slot) != null
		# "Somebody is there but you cannot see who" must not collapse into
		# "that lane is empty" - the board draws those differently, and an
		# empty lane is a free action the player would take by mistake.
		_eq(o.get("empty", false), not occupied,
			"N4 hidden slot %d reads as occupied-but-unknown" % slot)
		_eq(o.get("known", true), false, "N4 hidden slot %d stays unknown" % slot)

func n5_hostile_input() -> void:
	_eq(FDNet.from_bytes("not json at all".to_utf8_buffer()), {}, "N5 garbage decodes to nothing")
	_eq(FDNet.from_bytes("[1,2,3]".to_utf8_buffer()), {}, "N5 a JSON array is not a message")
	_eq(FDNet.from_bytes(PackedByteArray()), {}, "N5 an empty packet decodes to nothing")
	# Shape-checking is all this layer promises; legality is resolve()'s job.
	_ok(not FDNet.valid_action({"t": "action", "card_id": "; DROP", "kind": "attack", "target_slot": 0}),
		"N5 a non-numeric card id is rejected")

# A buff on a face-down enemy must survive redaction - otherwise the bluff is
# invisible online and the mechanic only exists in single player.
func n6_buffs_cross_the_wire(s: FDState) -> void:
	var red_jack: FDCard = s.find_by_name(FDState.RED, "Jack")
	red_jack.mark_rallied = true
	red_jack.mark_tended = true
	var slot: int = s.slot_of(red_jack)
	_ok(not s.is_revealed(FDState.RED, slot), "N6 setup: the buffed card is face down")

	var wire := FDNet.restore(FDNet.from_bytes(FDNet.to_bytes(FDNet.snapshot(s, FDState.BLACK))))
	var o: Dictionary = wire.observe(FDState.BLACK, slot)
	_ok(o.get("rallied", false), "N6 the rally is visible through the wire")
	_ok(o.get("tended", false), "N6 the heal mark is visible through the wire")
	_eq(o.get("known", true), false, "N6 ...without revealing the card")
	_eq(o, s.observe(FDState.BLACK, slot), "N6 redacted and local views agree")

	# And the identity still must not be recoverable.
	_ok(int(wire.slots[FDState.RED][slot]) == FDCard.HIDDEN,
		"N6 the buffed slot is still withheld")

# The snapshot is only half the wire. Events name cards by id, and ids map to
# names through the public roster - so an unredacted event stream hands over
# exactly what the snapshot refused to send.
func n7_events_are_redacted(s: FDState) -> void:
	var king: FDCard = s.find_by_name(FDState.RED, "King")
	var jack: FDCard = s.find_by_name(FDState.RED, "Jack")
	var raw: Array = [
		{"t": "rally", "actor": king.id, "target": jack.id, "upgraded": false},
		{"t": "shield", "actor": king.id, "target": jack.id, "amount": 30},
	]
	_ok(not s.is_revealed(FDState.RED, s.slot_of(jack)), "N7 setup: the target is face down")

	var seen: Array = FDNet.redact_events(s, raw, FDState.BLACK)
	for e in seen:
		_eq(int(e.target), FDCard.HIDDEN, "N7 %s hides the face-down target" % str(e.t))
		_ok(int(e.actor) != jack.id, "N7 %s does not leak the target as the actor" % str(e.t))

	# Our own cards stay fully identified - we are entitled to our own row.
	var mine: FDCard = s.find_by_name(FDState.BLACK, "Queen")
	var ours: Array = FDNet.redact_events(s, [{"t": "heal", "actor": mine.id, "target": mine.id}], FDState.BLACK)
	_eq(int(ours[0].target), mine.id, "N7 our own cards are not redacted")

	# A revealed enemy is fair game, because we watched it act.
	var slot: int = s.slot_of(jack)
	s.revealed[FDState.RED][slot] = true
	var now: Array = FDNet.redact_events(s, raw, FDState.BLACK)
	_eq(int(now[0].target), jack.id, "N7 a revealed enemy keeps its identity")
	s.revealed[FDState.RED].erase(slot)

# WHEN the events are redacted matters as much as whether they are.
#
# The server used to call FDRules.advance() and only then redact, which is a
# whole round too late: advance() can roll the round over, and begin_round()
# empties both rows and clears every reveal. visible_id() then asks "is this
# card standing in a revealed slot?" of a board that no longer exists, gets -1
# back from slot_of() for everything, and hides the lot - so the player's log
# described the action they had just watched as happening to "a face-down card".
#
# A rallied Shoot is the likeliest way to hit it: three lanes at once, often the
# last action of a round, often several kills.
func n8_redaction_happens_before_advance() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var s := FDRules.new_match(FDState.BLACK)
	FDRules.commit_placement(s, FDState.BLACK, FDRules.auto_place(s, FDState.BLACK, rng))
	FDRules.commit_placement(s, FDState.RED, FDRules.auto_place(s, FDState.RED, rng))

	# Burn every action except one, so the next one ends the round.
	for side in [FDState.BLACK, FDState.RED]:
		for c in s.living(side):
			s.acted[side][c.id] = true
	var jack: FDCard = s.find_by_name(FDState.BLACK, "Jack")
	s.acted[FDState.BLACK].erase(jack.id)
	s.side_to_act = FDState.BLACK
	jack.rallied = true            # Shoot+, three lanes

	var res: Dictionary = FDRules.resolve(s, FDState.BLACK,
		{"card_id": jack.id, "kind": "skill", "target_slot": 2})
	_ok(res.ok, "N8 the rallied shoot resolves", str(res.error))

	# Redacted here, against the board it happened on.
	var before: Array = FDNet.redact_events(s, res.events, FDState.BLACK)

	_eq(FDRules.advance(s), "round_end", "N8 setting up a round rollover")
	_eq(s.slots[FDState.RED].size(), 0, "N8 begin_round has emptied the rows")

	# ...and what redacting afterwards would have produced.
	var after: Array = FDNet.redact_events(s, res.events, FDState.BLACK)

	var named_before := 0
	var named_after := 0
	for e in before:
		if e.has("target") and int(e.target) != FDCard.HIDDEN:
			named_before += 1
	for e in after:
		if e.has("target") and int(e.target) != FDCard.HIDDEN:
			named_after += 1

	# The shooter revealed what it hit, so the shooting side is entitled to know
	# what it shot. That is the whole point of redacting at the right moment.
	_ok(named_before > 0, "N8 redacting in time keeps the cards it just revealed")
	_ok(named_after < named_before,
		"N8 redacting after advance() would have hidden them (%d -> %d)"
		% [named_before, named_after])
