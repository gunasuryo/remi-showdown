extends RefCounted
class_name FURulesTests

# Face-up rules engine. Runs entirely headless: no scene, no window.
#   godot --headless --path RemiShowdown --script res://test/run_tests.gd
#
# Every assertion here was previously untestable without instantiating
# table_2.tscn, which is the whole point of FURules existing.

const BLACK := FUState.BLACK
const RED := FUState.RED

var results: Array = []

func _ok(cond: bool, name: String, detail: String = "") -> void:
	results.append({"pass": cond, "name": name, "detail": detail})

func _eq(got, want, name: String) -> void:
	_ok(got == want, name, "got %s, want %s" % [str(got), str(want)])

# ── Scaffolding ───────────────────────────────────────────────────────────

# A started match with the coin flip pinned, so slot order is predictable.
# Opening rows are CardStats.ORDER: Ace 0, Jack 1, Queen 2, King 3, Joker 4.
func _match(first: int = BLACK) -> FUState:
	var s := FURules.new_match(BLACK)
	s.first_suit = first
	s.current_suit = first
	s.current_slot = 0
	FURules.start(s)
	return s

# Hand the turn to a named card without walking the turn order, so a rule test
# is not also a turn-order test. Turn order gets its own tests (F20-F23).
# Deliberately skips the start-of-turn expiry, which F10/F12 exercise directly.
func _turn(s: FUState, side: int, card_name: String) -> FUCard:
	var c := s.find_by_name(side, card_name)
	s.current_suit = side
	s.current_slot = s.slot_of(c)
	s.current_id = c.id
	return c

# Resolve one action for a named card.
func _act(s: FUState, side: int, card_name: String, kind: String, target_slot: int = -1) -> Dictionary:
	var c := _turn(s, side, card_name)
	var action := {"kind": kind}
	action["target_slot"] = target_slot if target_slot >= 0 else s.slot_of(c)
	return FURules.resolve(s, action)

func _kill(s: FUState, side: int, card_name: String) -> void:
	var c := s.find_by_name(side, card_name)
	c.hp = 0
	c.alive = false
	var kept: Array = []
	for id in s.rows[side]:
		if id != c.id:
			kept.append(id)
	s.rows[side] = kept

func _events_of(res: Dictionary, t: String) -> Array:
	var out: Array = []
	for e in res.events:
		if e.t == t:
			out.append(e)
	return out

func _has_event(res: Dictionary, t: String) -> bool:
	return not _events_of(res, t).is_empty()

# ── Tests ─────────────────────────────────────────────────────────────────

func run_all() -> void:
	_t_setup()
	_t_attack()
	_t_reach()
	_t_edge_takeover()
	_t_shield()
	_t_trick()
	_t_trick_vs_rally()
	_t_caster_holds()
	_t_hidden_status()
	_t_rally()
	_t_rally_no_stack()
	_t_double_rally()
	_t_skills()
	_t_death()
	_t_turn_order()
	_t_legal_actions()
	_t_winner()

# F1 — the board opens as five cards a side reading off the shared stat table.
func _t_setup() -> void:
	var s := _match()
	_eq(s.cards.size(), 10, "F1 ten cards exist")
	_eq(s.living_count(BLACK), 5, "F1 Black fields five")
	_eq(s.living_count(RED), 5, "F1 Red fields five")
	var names: Array = []
	for c in s.living(BLACK):
		names.append(c.card_name)
	_eq(names, CardStats.ORDER, "F1 opening slot order is CardStats.ORDER")
	var jack := s.find_by_name(BLACK, "Jack")
	_eq(jack.max_hp, CardStats.hp_of("Jack", CardStats.FACE_UP), "F1 HP comes from CardStats")
	_eq(jack.atk, CardStats.atk_of("Jack", CardStats.FACE_UP), "F1 attack comes from CardStats")
	_eq(jack.skill_value, CardStats.skill_of("Jack", CardStats.FACE_UP), "F1 skill comes from CardStats")
	_eq(jack.max_shield, CardStats.MAX_SHIELD_FACEUP, "F1 shield cap is the face-up one")

# F2 — a straight attack costs the target its full value off HP.
func _t_attack() -> void:
	var s := _match()
	var attacker := s.find_by_name(BLACK, "Jack")
	var victim := s.find_by_name(RED, "Jack")
	var res := _act(s, BLACK, "Jack", "attack", 1)
	_ok(res.ok, "F2 a straight attack resolves", str(res.error))
	_eq(victim.hp, victim.max_hp - attacker.atk, "F2 full damage lands head-on")
	var hits := _events_of(res, "hit")
	_eq(hits.size(), 1, "F2 one hit event")
	_eq(hits[0].verb, "attacks", "F2 the verb is 'attacks'")

# F3 — an attack hits the lane it faces and nothing else. There is no sideways
# reach in this mode any more; only a skill picks a target.
func _t_reach() -> void:
	var s := _match()
	_turn(s, BLACK, "Jack")                          # slot 1
	_eq(s.attack_slots(BLACK, 1), [1], "F3 an attack reaches exactly one lane")

	var neighbour := s.find_by_name(RED, "Queen")    # slot 2
	var sideways := _act(s, BLACK, "Jack", "attack", 2)
	_ok(not sideways.ok, "F3 a neighbouring lane is rejected")
	_eq(neighbour.hp, neighbour.max_hp, "F3 ...and the neighbour is untouched")

	var s2 := _match()
	var far := _act(s2, BLACK, "Jack", "attack", 3)  # slot 1 -> slot 3
	_ok(not far.ok, "F3 a two-lane reach is rejected too")
	_eq(s2.find_by_name(RED, "King").hp, CardStats.hp_of("King", CardStats.FACE_UP), "F3 ...and nothing was hit")

	# The Jack still reaches any slot it likes - with its SKILL, which is the
	# whole trade the card is built on.
	var s3 := _match()
	var far_target := s3.find_by_name(RED, "Joker")  # slot 4
	var shot := _act(s3, BLACK, "Jack", "skill", 4)
	_ok(shot.ok, "F3 a skill still picks any slot", str(shot.error))
	_ok(far_target.hp < far_target.max_hp, "F3 ...and lands there")

# F4 — when the enemy row is shorter, the edge card stands in for every slot
# past the end of it, so a card at slot 4 still has something to attack.
func _t_edge_takeover() -> void:
	var s := _match()
	for n in ["Ace", "Jack", "Queen"]:
		_kill(s, RED, n)
	# Red is down to King (slot 0) and Joker (slot 1).
	_eq(s.living_count(RED), 2, "F4 Red is down to two")
	var joker := _turn(s, BLACK, "Joker")            # Black slot 4
	_eq(s.slot_of(joker), 4, "F4 the attacker stands at slot 4")
	_eq(s.direct_slot(BLACK, 4), 1, "F4 it faces the last enemy")
	_eq(s.attack_slots(BLACK, 4), [1], "F4 reach clamps to the shortened row")
	var red_joker := s.find_by_name(RED, "Joker")
	var res := FURules.resolve(s, {"kind": "attack", "target_slot": 1})
	_ok(res.ok, "F4 the edge attack resolves", str(res.error))
	_eq(red_joker.hp, red_joker.max_hp - joker.atk, "F4 the edge card takes a full hit")

# F5 — a shield absorbs, but never all of it, and it is wiped at the start of
# the shielded card's own turn.
func _t_shield() -> void:
	var s := _match()
	var ace := s.find_by_name(BLACK, "Ace")
	var queen := s.find_by_name(BLACK, "Queen")
	var res := _act(s, BLACK, "Ace", "skill", 2)   # shield the Queen
	_ok(res.ok, "F5 the Ace shields an ally", str(res.error))
	_eq(queen.shield, min(ace.skill_value, queen.max_shield), "F5 the shield lands")

	# Read the hit off the EVENT rather than off the card afterwards: resolve()
	# ends the turn and opens the next, which may well be the Queen's own - and
	# her shield is gone by then, which is exactly the rule below.
	var attacker := s.find_by_name(RED, "Queen")   # slot 2, so this is head-on
	var leak := CardStats.leak_of(attacker.atk)
	var struck := _act(s, RED, "Queen", "attack", 2)
	_ok(struck.ok, "F5 the attack on a shielded card resolves", str(struck.error))
	var blow: Dictionary = _events_of(struck, "hit")[0]
	_ok(leak >= CardStats.SHIELD_LEAK_MIN, "F5 a shield never fully stops a hit")
	_eq(blow.hp_lost, leak, "F5 only the leak reaches HP")
	_eq(blow.absorbed, attacker.atk - leak, "F5 the shield absorbs the rest")

	# The shield belongs to its ACE. Nothing on a clock takes it away - the
	# carrier can take its own turn, and every other turn, and keep it.
	var s2 := _match()
	var held := s2.find_by_name(BLACK, "Queen")
	_act(s2, BLACK, "Ace", "skill", 2)
	var granted: int = held.shield
	_ok(granted > 0, "F5 the Queen is shielded")
	_act(s2, BLACK, "Queen", "attack", 2)
	_eq(held.shield, granted, "F5 the carrier taking its own turn does not lapse it")
	_act(s2, BLACK, "Joker", "attack", 4)
	_eq(held.shield, granted, "F5 nor does an ally acting")

	# The Ace acting is what puts it down - and an ATTACK counts, not just a
	# re-shield. Standing still is the price of keeping a shield up.
	var down := _act(s2, BLACK, "Ace", "attack", 0)
	_eq(held.shield, 0, "F5 the Ace acting puts its own shield down")
	var lapse := _events_of(down, "shield_expired")
	_eq(lapse.size(), 1, "F5 the lapse is reported")
	_eq(lapse[0].amount, granted, "F5 ...with what it was worth")
	_eq(lapse[0].reason, "acted", "F5 ...and why")

	# One action moves it: the old shield goes down before the new one goes up,
	# so re-shielding the SAME ally is a full top-up rather than a no-op.
	var s3 := _match()
	var ward := s3.find_by_name(BLACK, "Queen")
	_act(s3, BLACK, "Ace", "skill", 2)
	ward.shield = 4                            # worn down by hits
	var topped := _act(s3, BLACK, "Ace", "skill", 2)
	_eq(ward.shield, s3.find_by_name(BLACK, "Ace").skill_value,
		"F5 re-shielding the same ally is a full top-up")
	_ok(_has_event(topped, "shield_expired"), "F5 ...the old one came down first")

	# And it dies with its Ace.
	var s4 := _match()
	var orphan := s4.find_by_name(BLACK, "Queen")
	_act(s4, BLACK, "Ace", "skill", 2)
	_ok(orphan.shield > 0, "F5 the shield is up")
	var ace4 := s4.find_by_name(BLACK, "Ace")
	ace4.hp = 1
	var killed := _act(s4, RED, "Ace", "attack", 0)
	_ok(not ace4.alive, "F5 the Ace falls")
	_eq(orphan.shield, 0, "F5 the shield dies with the Ace holding it up")
	_eq(_events_of(killed, "shield_expired")[0].reason, "died", "F5 ...and says so")

# F6 — a trick is a HIDDEN TRAP. It does nothing until its victim reaches for a
# skill, and the victim cannot see it coming.
func _t_trick() -> void:
	var s := _match()
	var joker := s.find_by_name(BLACK, "Joker")
	var victim := s.find_by_name(RED, "Jack")
	var res := _act(s, BLACK, "Joker", "skill", 1)
	_ok(res.ok, "F6 the Joker tricks an enemy", str(res.error))
	_ok(victim.tricked, "F6 the target is tricked")
	_eq(victim.trick_joker, joker.id, "F6 the trap remembers whose it is")

	# Hidden from the victim's own side, visible to the side that set it.
	_ok(not s.sees_trick(RED, victim), "F6 the victim's side cannot see the trick")
	_ok(s.sees_trick(BLACK, victim), "F6 the Joker's side can")
	_ok(victim.may_attempt_skill(), "F6 the victim is still offered its skill")

	# Attacking bites: half damage, and the trap becomes public in the same
	# instant - a card swinging at half strength cannot hide it. The victim only
	# learns AFTER committing the turn, which is the same bargain a hidden
	# shield strikes with the blow that reveals it.
	var struck := s.find_by_name(BLACK, "Jack")
	var before: int = struck.hp
	var half: int = max(1, int(round(victim.atk * CardStats.TRICK_ATTACK_MULT)))
	var hit := _act(s, RED, "Jack", "attack", 1)
	_ok(hit.ok, "F6 a tricked card still gets its turn", str(hit.error))
	_eq(before - struck.hp, half, "F6 ...but hits for half")
	_ok(half < victim.atk, "F6 half is less than its full attack")
	_ok(s.sees_trick(RED, victim), "F6 the swing gives the trap away")
	_ok(_has_event(hit, "reveal"), "F6 ...and the reveal is reported")
	# Revealed is not spent. It still denies the skill.
	_ok(victim.tricked, "F6 attacking does not spring the trap")

	# Reaching for the skill is what springs it: the skill does not happen and
	# the turn is gone.
	var far := s.find_by_name(BLACK, "Joker")
	var untouched: int = far.hp
	var sprung := _act(s, RED, "Jack", "skill", 4)
	_ok(sprung.ok, "F6 the skill attempt is a legal move", str(sprung.error))
	_ok(_has_event(sprung, "trick_sprung"), "F6 the trap springs")
	_eq(_events_of(sprung, "hit").size(), 0, "F6 the skill does not happen")
	_eq(far.hp, untouched, "F6 ...and nothing is hit")
	_ok(not victim.tricked, "F6 the trap is spent")
	# There is no lingering "you were tricked" flag to check: springing the trap
	# consumes it outright. What the victim learns, it learns from the event.
	_eq(_events_of(sprung, "trick_sprung")[0].by, joker.id, "F6 ...and whose trap it was")

	# A second Joker action is needed to set another.
	var again := _act(s, RED, "Jack", "skill", 4)
	_ok(again.ok, "F6 the next skill goes through", str(again.error))
	_ok(far.hp < untouched, "F6 ...and lands")

# F6b — a rally is armour: it is spent breaking the trick, and the skill gets
# through covering ONE lane rather than three.
func _t_trick_vs_rally() -> void:
	var s := _match()
	var victim := s.find_by_name(RED, "Jack")
	_act(s, BLACK, "Joker", "skill", 1)      # trick Red's Jack
	_ok(victim.tricked, "F6b the Jack is tricked")
	_act(s, RED, "King", "skill", 1)         # Red's King rallies it
	_ok(victim.rallied, "F6b ...and rallied")

	var broke := _act(s, RED, "Jack", "skill", 2)
	_ok(broke.ok, "F6b the skill resolves", str(broke.error))
	_ok(_has_event(broke, "rally_breaks_trick"), "F6b the rally breaks the trick")
	_ok(not _has_event(broke, "trick_sprung"), "F6b ...so the turn is not wasted")
	_eq(_events_of(broke, "hit").size(), 1, "F6b the skill covers ONE lane, not three")
	_ok(not victim.tricked, "F6b the trick is gone")
	_ok(not victim.rallied, "F6b and the rally was the price")

	# Without a trick to break, the same rally spreads to three.
	var s2 := _match()
	s2.find_by_name(RED, "Jack").rallied = true
	var spread := _act(s2, RED, "Jack", "skill", 2)
	_eq(_events_of(spread, "hit").size(), 3, "F6b an unbroken rally still spreads to three")

# F16 — a rally and a trap belong to the card that made them, exactly as the
# shield does: each ends when its caster acts again or dies.
func _t_caster_holds() -> void:
	# ── Rally ───────────────────────────────────────────────────────────
	var s := _match()
	var ace := s.find_by_name(BLACK, "Ace")
	_act(s, BLACK, "King", "skill", 0)
	_ok(ace.rallied, "F16 the Ace is rallied")
	_eq(ace.rally_king, s.find_by_name(BLACK, "King").id, "F16 the rally knows its King")
	_act(s, BLACK, "Queen", "attack", 2)
	_ok(ace.rallied, "F16 someone else acting leaves it alone")
	var dropped := _act(s, BLACK, "King", "attack", 3)
	_ok(not ace.rallied, "F16 the King acting again takes the rally back")
	_eq(_events_of(dropped, "rally_expired")[0].reason, "acted", "F16 ...and says why")

	# ...and it dies with its King.
	var s2 := _match()
	var carrier := s2.find_by_name(BLACK, "Ace")
	_act(s2, BLACK, "King", "skill", 0)
	var king2 := s2.find_by_name(BLACK, "King")
	king2.hp = 1
	var slain := _act(s2, RED, "King", "attack", 3)
	_ok(not king2.alive, "F16 the King falls")
	_ok(not carrier.rallied, "F16 the rally dies with its King")
	_eq(_events_of(slain, "rally_expired")[0].reason, "died", "F16 ...and says why")

	# ── Trap ────────────────────────────────────────────────────────────
	var s3 := _match()
	var prey := s3.find_by_name(RED, "Jack")
	_act(s3, BLACK, "Joker", "skill", 1)
	_ok(prey.tricked, "F16 the trap is set")
	_act(s3, BLACK, "Queen", "attack", 2)
	_ok(prey.tricked, "F16 another card acting leaves it armed")

	# A Joker that acts gives up the trap it was holding - so keeping one armed
	# means standing still, and it can only ever hold one.
	var moved := _act(s3, BLACK, "Joker", "skill", 2)
	_ok(not prey.tricked, "F16 the Joker acting lifts its own trap")
	_ok(s3.find_by_name(RED, "Queen").tricked, "F16 ...and the same action sets a new one")
	_eq(_events_of(moved, "trick_lifted")[0].reason, "acted", "F16 ...saying why")

	# ...and the trap dies with its Joker.
	var s4 := _match()
	var caught := s4.find_by_name(RED, "Jack")
	_act(s4, BLACK, "Joker", "skill", 1)
	var joker4 := s4.find_by_name(BLACK, "Joker")
	joker4.hp = 1
	var felled := _act(s4, RED, "Joker", "attack", 4)
	_ok(not joker4.alive, "F16 the Joker falls")
	_ok(not caught.tricked, "F16 the trap dies with the Joker who set it")
	_eq(_events_of(felled, "trick_lifted")[0].reason, "died", "F16 ...and says why")

# F15 — who may know what. A shield and a rally are visible to the side that
# cast them and hidden from the enemy; a trick is the mirror image. Each becomes
# public at the moment it does something the other side can watch.
func _t_hidden_status() -> void:
	var s := _match()
	var queen := s.find_by_name(BLACK, "Queen")

	# ── Shield: hidden until an attack commits into it ──────────────────
	_act(s, BLACK, "Ace", "skill", 2)
	_ok(s.sees_shield(BLACK, queen), "F15 the shielding side sees its own shield")
	_ok(not s.sees_shield(RED, queen), "F15 the enemy does not")
	_eq(s.shield_seen_by(RED, queen), 0, "F15 ...it reads as no shield at all")
	_eq(s.shield_seen_by(BLACK, queen), queen.shield, "F15 ...but not to its owner")

	var strike := _act(s, RED, "Queen", "attack", 2)
	_ok(_has_event(strike, "reveal"), "F15 committing the attack reveals it")
	_eq(_events_of(strike, "reveal")[0].what, "shield", "F15 ...as a shield")
	_ok(s.sees_shield(RED, queen), "F15 now the enemy knows")
	_ok(queen.shield < queen.max_shield, "F15 and it absorbed the blow anyway")

	# A shoot commits just the same way.
	var s2 := _match()
	var mark := s2.find_by_name(BLACK, "Queen")
	_act(s2, BLACK, "Ace", "skill", 2)
	_ok(not s2.sees_shield(RED, mark), "F15 a fresh shield starts hidden")
	var shot := _act(s2, RED, "Jack", "skill", 2)
	# Read the reveal off the EVENT: resolve() ends the turn and opens the next,
	# which may be the shielded card own turn - and the shield, seen flag and
	# all, is gone by then.
	_ok(_has_event(shot, "reveal"), "F15 a shoot reveals it too")
	_eq(_events_of(shot, "reveal")[0].card, mark.id, "F15 ...the Jack found the Ace as well")

	# A shield that is never attacked goes down, when its Ace acts, without the
	# enemy ever having learned it was there.
	var s3 := _match()
	var quiet := s3.find_by_name(BLACK, "Queen")
	_act(s3, BLACK, "Ace", "skill", 2)
	_ok(quiet.shield > 0 and not quiet.shield_seen, "F15 an unseen shield is up")
	var lapse := _act(s3, BLACK, "Ace", "attack", 0)
	_eq(quiet.shield, 0, "F15 the Ace acting puts it down")
	_eq(_events_of(lapse, "shield_expired")[0].was_seen, false,
		"F15 the lapse says it was never public")

	# ── Rally: hidden until a skill covers three lanes ──────────────────
	var s4 := _match()
	var ace := s4.find_by_name(BLACK, "Ace")
	_act(s4, BLACK, "King", "skill", 0)
	_ok(s4.rally_seen_by(BLACK, ace), "F15 the rallying side sees its rally")
	_ok(not s4.rally_seen_by(RED, ace), "F15 the enemy does not")
	var wide := _act(s4, BLACK, "Ace", "skill", 2)
	_ok(_has_event(wide, "reveal"), "F15 spreading three ways reveals the rally")
	_eq(_events_of(wide, "reveal")[0].what, "rally", "F15 ...as a rally")

	# ── Trick: the mirror image ─────────────────────────────────────────
	var s5 := _match()
	var prey := s5.find_by_name(RED, "Queen")
	_act(s5, BLACK, "Joker", "skill", 2)
	_ok(s5.trick_seen_by(BLACK, prey), "F15 the Joker's side sees the trap it set")
	_ok(not s5.trick_seen_by(RED, prey), "F15 the victim's side is the one in the dark")

	# ...including in what the card appears to HIT for. A live trap halves the
	# attack, so reading the true value would let a side notice it was trapped
	# one move before a player in the same seat could - the scorer compares an
	# attack against a skill, and a quietly depressed attack routes around a
	# trap nobody is supposed to be able to see.
	_eq(prey.attack_value(), max(1, int(round(prey.atk * CardStats.TRICK_ATTACK_MULT))),
		"F15 the true attack is halved")
	_eq(s5.attack_seen_by(RED, prey), prey.atk,
		"F15 the victim's own side still reads it at full")
	_eq(s5.attack_seen_by(BLACK, prey), prey.attack_value(),
		"F15 the side that set the trap sees the real number")
	prey.trick_seen = true
	_eq(s5.attack_seen_by(RED, prey), prey.attack_value(),
		"F15 once sprung, both sides read the same number")

# F7 — a rally widens the next SKILL to three lanes, is spent by using one, and
# survives an attack. Nothing else takes it away.
func _t_rally() -> void:
	var s := _match()
	var king := s.find_by_name(BLACK, "King")
	var ace := s.find_by_name(BLACK, "Ace")
	var res := _act(s, BLACK, "King", "skill", 0)   # rally the Ace
	_ok(res.ok, "F7 the King rallies an ally", str(res.error))
	_ok(ace.rallied, "F7 the ally is rallied")
	_ok(not king.rallied, "F7 the King carries no rally of its own")

	# Attacking does not spend it: no line of code has ever cleared a rally on
	# an attack, whatever table2.gd's comment claimed.
	_act(s, BLACK, "Ace", "attack", 0)
	_ok(ace.rallied, "F7 attacking does not spend the rally")

	var spread := _act(s, BLACK, "Ace", "skill", 2)   # shield slot 2 + neighbours
	_ok(spread.ok, "F7 the rallied skill resolves", str(spread.error))
	_eq(_events_of(spread, "shield").size(), 3, "F7 a rallied Ace shields three lanes")
	_ok(not ace.rallied, "F7 the rally is spent by using the skill")
	_ok(_has_event(spread, "rally_consumed"), "F7 the spend is reported")

	# Unrallied, the same skill covers one lane.
	var plain := _act(s, BLACK, "Ace", "skill", 2)
	_eq(_events_of(plain, "shield").size(), 1, "F7 an unrallied Ace shields one lane")

# F8 — rally does not stack: a new one replaces the old.
func _t_rally_no_stack() -> void:
	var s := _match()
	var ace := s.find_by_name(BLACK, "Ace")
	var queen := s.find_by_name(BLACK, "Queen")
	_act(s, BLACK, "King", "skill", 0)     # rally the Ace
	_ok(ace.rallied, "F8 the Ace is rallied")
	var res := _act(s, BLACK, "King", "skill", 2)   # rally the Queen instead
	_ok(queen.rallied, "F8 the Queen is rallied")
	_ok(not ace.rallied, "F8 the old rally is dropped")
	_ok(_has_event(res, "rally_expired"), "F8 the drop is reported")
	var rallied := 0
	for c in s.living(BLACK):
		if c.rallied:
			rallied += 1
	_eq(rallied, 1, "F8 at most one ally is ever rallied")

# F9 — a self-rally arms the double rally, which then hands out two.
func _t_double_rally() -> void:
	var s := _match()
	var king := s.find_by_name(BLACK, "King")
	var res := _act(s, BLACK, "King", "skill", 3)   # the King's own slot
	_ok(res.ok, "F9 the King rallies itself", str(res.error))
	_ok(king.double_rally, "F9 the double rally is armed")
	_ok(not king.rallied, "F9 a self-rally is an arm, not a rally")
	_ok(_has_event(res, "self_rally"), "F9 the arming is reported")

	# An armed King must spend the arm; a plain rally is no longer on offer.
	var single := _act(s, BLACK, "King", "skill", 0)
	_ok(not single.ok, "F9 an armed King cannot hand out a single rally")

	_turn(s, BLACK, "King")
	var pair := FURules.resolve(s, {"kind": "double_rally", "target_slots": [0, 2]})
	_ok(pair.ok, "F9 the double rally resolves", str(pair.error))
	_ok(s.find_by_name(BLACK, "Ace").rallied, "F9 the first target is rallied")
	_ok(s.find_by_name(BLACK, "Queen").rallied, "F9 the second target is rallied")
	_ok(not king.double_rally, "F9 the arm is spent")

	# The King is never in its own pair.
	_act(s, BLACK, "King", "skill", 3)
	_turn(s, BLACK, "King")
	var self_pick := FURules.resolve(s, {"kind": "double_rally", "target_slots": [3, 0]})
	_ok(not self_pick.ok, "F9 a King cannot rally itself as one of the pair")

# F10 — what each skill actually does, unrallied and rallied.
func _t_skills() -> void:
	var s := _match()
	# Queen heals, capped at max HP.
	var hurt := s.find_by_name(BLACK, "Ace")
	hurt.hp = 5
	var queen := s.find_by_name(BLACK, "Queen")
	_act(s, BLACK, "Queen", "skill", 0)
	_eq(hurt.hp, min(5 + queen.skill_value, hurt.max_hp), "F10 the Queen heals")
	var topped := _act(s, BLACK, "Queen", "skill", 0)
	_eq(_events_of(topped, "heal")[0].amount, hurt.max_hp - min(5 + queen.skill_value, hurt.max_hp),
		"F10 healing is capped at max HP")

	# Jack shoots any enemy slot, not just the one it faces.
	var far := s.find_by_name(RED, "Joker")           # slot 4, Jack is at slot 1
	var jack := s.find_by_name(BLACK, "Jack")
	var shot := _act(s, BLACK, "Jack", "skill", 4)
	_ok(shot.ok, "F10 the Jack shoots a slot it could never reach by attacking", str(shot.error))
	_eq(far.hp, far.max_hp - jack.skill_value, "F10 shoot deals its skill value")
	_eq(_events_of(shot, "hit")[0].verb, "shoots", "F10 the verb is 'shoots'")

	# A rallied Jack volleys three lanes; a rallied Joker tricks three.
	var s2 := _match()
	s2.find_by_name(BLACK, "Jack").rallied = true
	var volley := _act(s2, BLACK, "Jack", "skill", 2)
	_eq(_events_of(volley, "hit").size(), 3, "F10 a rallied Jack volleys three lanes")

	var s3 := _match()
	s3.find_by_name(BLACK, "Joker").rallied = true
	var mass := _act(s3, BLACK, "Joker", "skill", 2)
	_eq(_events_of(mass, "trick").size(), 3, "F10 a rallied Joker tricks three lanes")

	# Shield is capped, and the cap is the Ace's own grant.
	var s4 := _match()
	var ally := s4.find_by_name(BLACK, "Queen")
	ally.shield = ally.max_shield
	var capped := _act(s4, BLACK, "Ace", "skill", 2)
	_eq(_events_of(capped, "shield")[0].amount, 0, "F10 shield does not exceed its cap")

# F11 — a dead card leaves the board and the slots to its right shift left.
func _t_death() -> void:
	var s := _match()
	var victim := s.find_by_name(RED, "Queen")       # slot 2
	victim.hp = 1
	var res := _act(s, BLACK, "Queen", "attack", 2)
	_ok(res.ok, "F11 the killing blow resolves", str(res.error))
	_ok(not victim.alive, "F11 the target dies")
	_ok(_has_event(res, "death"), "F11 the death is reported")
	_eq(s.living_count(RED), 4, "F11 the board narrows")
	var names: Array = []
	for c in s.living(RED):
		names.append(c.card_name)
	_eq(names, ["Ace", "Jack", "King", "Joker"], "F11 the slot collapses and the row shifts left")
	_ok(s.card_by_id(victim.id) != null, "F11 the corpse still resolves for the log")

# F12 — slot by slot, the coin-flip winner first in each pair.
func _t_turn_order() -> void:
	var s := _match(BLACK)
	var seen: Array = []
	for i in range(6):
		var actor := s.current_card()
		seen.append("%s %s@%d" % ["B" if actor.side == BLACK else "R", actor.card_name, s.current_slot])
		FURules.resolve(s, {"kind": "attack", "target_slot": s.direct_slot(actor.side, s.current_slot)})
	_eq(seen, [
		"B Ace@0", "R Ace@0", "B Jack@1", "R Jack@1", "B Queen@2", "R Queen@2",
	], "F12 slot by slot, Black first on a Black flip")

	# The coin flip is the whole reason face-up has no seat imbalance.
	var s2 := _match(RED)
	_eq(s2.current_card().side, RED, "F12 a Red flip gives Red the opening action")

	# ...and the lead alternates, so it never compounds. Walk a whole round of
	# a five-a-side board - ten half-turns - and the other colour opens.
	var s4 := _match(BLACK)
	_eq(s4.round_no, 1, "F12 the match opens on round 1")
	for i in range(10):
		if s4.is_over():
			break
		FURules.resolve(s4, {"kind": "attack",
			"target_slot": s4.direct_slot(s4.current_suit, s4.current_slot)})
	_eq(s4.round_no, 2, "F12 ten half-turns is one full round")
	_eq(s4.first_suit, RED, "F12 the lead passes to the other colour")
	_eq(s4.current_card().side, RED, "F12 ...and Red opens round 2")

	# A side with more survivors keeps acting with its extra cards: the short
	# side's missing half-turns are skipped rather than stalling the match.
	var s3 := _match(BLACK)
	for n in ["Ace", "Jack", "Queen", "King"]:
		_kill(s3, RED, n)
	s3.current_slot = 0
	s3.current_suit = BLACK
	var opening: Array = []
	FURules._start_turn(s3, opening)
	var sides: Array = []
	for i in range(5):
		if s3.is_over():
			break
		sides.append(s3.current_card().side)
		FURules.resolve(s3, {"kind": "attack",
			"target_slot": s3.direct_slot(s3.current_suit, s3.current_slot)})
	_ok(sides.count(BLACK) > sides.count(RED), "F12 the longer row gets the extra half-turns")

# F13 — the action list is what the board and the AI both read.
func _t_legal_actions() -> void:
	var s := _match()
	_turn(s, BLACK, "Jack")
	var acts := FURules.legal_actions(s)
	var attacks: Array = []
	var skills: Array = []
	for a in acts:
		if a.kind == "attack":
			attacks.append(a.target_slot)
		elif a.kind == "skill":
			skills.append(a.target_slot)
	_eq(attacks, [1], "F13 an attack offers exactly the lane it faces")
	_eq(skills, [0, 1, 2, 3, 4], "F13 the Jack may shoot any enemy slot")

	# A tricked card is offered EVERYTHING, unchanged. Trimming the list here
	# would tell its owner about the trap before they could walk into it - the
	# missing button would be the tell.
	s.find_by_name(BLACK, "Jack").tricked = true
	var limited := FURules.legal_actions(s)
	_eq(limited.size(), acts.size(), "F13 a tricked card is offered the same actions")

	# An armed King is offered double rallies instead of single ones.
	var s2 := _match()
	s2.find_by_name(BLACK, "King").double_rally = true
	_turn(s2, BLACK, "King")
	var kinds := {}
	for a in FURules.legal_actions(s2):
		kinds[a.kind] = true
	_ok(kinds.has("double_rally"), "F13 an armed King is offered double rallies")
	_ok(not kinds.has("skill"), "F13 ...and no single rally")

	# Every offered action must be accepted by resolve().
	var s3 := _match()
	for a in FURules.legal_actions(s3):
		var probe := _match()
		probe.first_suit = s3.first_suit
		probe.current_suit = s3.current_suit
		probe.current_slot = s3.current_slot
		probe.current_id = s3.current_id
		var r := FURules.resolve(probe, a)
		_ok(r.ok, "F13 legal_actions offers only actions resolve() accepts", str(a) + " " + str(r.error))

# F14 — wiping a side ends the match.
func _t_winner() -> void:
	var s := _match()
	_eq(FURules.winner(s), 0, "F14 a full board is undecided")
	for n in ["Ace", "Jack", "Queen", "King"]:
		_kill(s, RED, n)
	_eq(FURules.winner(s), 0, "F14 one survivor is still undecided")
	var last := s.find_by_name(RED, "Joker")
	last.hp = 1
	last.shield = 0
	# Red's Joker has collapsed to slot 0, so Black's Ace faces it head-on.
	var res := _act(s, BLACK, "Ace", "attack", 0)
	_ok(res.ok, "F14 the last blow resolves", str(res.error))
	_eq(FURules.winner(s), BLACK, "F14 wiping a side wins the match")
	_ok(s.is_over(), "F14 the match is over")
	_eq(s.outcome, BLACK, "F14 the outcome is recorded on the state")
	_ok(_has_event(res, "game_over"), "F14 the result is reported")
	_eq(FURules.winner_text(BLACK), "Black wins!", "F14 the result line reads as before")
	_ok(FURules.resolve(s, {"kind": "attack", "target_slot": 0}).ok == false,
		"F14 nothing resolves after the match ends")
