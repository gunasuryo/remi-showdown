extends RefCounted
class_name FDState

# Whole-match state for face-down mode. Pure data + queries; every mutation that
# implements a rule lives in FDRules (PLAN §3 separation rule).

enum Phase { POSITIONING, BATTLE, GAME_OVER }

const BLACK := 1
const RED := 2

var cards: Array[FDCard] = []      # all 10 — dead cards are NEVER removed (PRD §8.3)

# side -> Array[int] of card ids, length == board_size.
# Slot i on one side faces slot i on the other.
var slots := {BLACK: [], RED: []}

# side -> {slot_index: true}. "Slots of THIS side currently visible to the
# OPPONENT." Reset every positioning phase (PRD §8.2).
var revealed := {BLACK: {}, RED: {}}

# side -> {card_id: true}. Cards that have used their one action this round.
var acted := {BLACK: {}, RED: {}}

# side -> bool. Both must be true before the battle phase can start.
var placed := {BLACK: false, RED: false}

var round_no: int = 1
var leader: int = BLACK            # takes the round's first action; alternates
var side_to_act: int = BLACK
var board_size: int = 5
var phase: int = Phase.POSITIONING
var player_side: int = BLACK       # which side the human controls

# Every damage number passes through this (PLAN §2.2). It is the ONLY pacing
# lever — stats are never edited to tune match length.
var damage_scale: float = 1.0

# side -> Array of {"shielded","rallied","tended"}, one per slot. ONLY set on a
# redacted client state, where the enemy row holds FDCard.HIDDEN and there is no
# card to read the marks off. The authoritative state leaves it empty and reads
# the cards directly, so both sides of the wire produce identical observe()
# output - which test_fd_net.gd N2 asserts.
var hidden_marks := {BLACK: [], RED: []}

var _next_id: int = 0

func new_id() -> int:
	var v := _next_id
	_next_id += 1
	return v

# ── Lookups ───────────────────────────────────────────────────────────────

func card_by_id(id: int) -> FDCard:
	for c in cards:
		if c.id == id:
			return c
	return null

func team(side: int) -> Array[FDCard]:
	var out: Array[FDCard] = []
	for c in cards:
		if c.side == side:
			out.append(c)
	return out

func living(side: int) -> Array[FDCard]:
	var out: Array[FDCard] = []
	for c in cards:
		if c.side == side and c.alive:
			out.append(c)
	return out

func dead(side: int) -> Array[FDCard]:
	var out: Array[FDCard] = []
	for c in cards:
		if c.side == side and not c.alive:
			out.append(c)
	return out

func living_count(side: int) -> int:
	return living(side).size()

func find_by_name(side: int, card_name: String) -> FDCard:
	for c in cards:
		if c.side == side and c.card_name == card_name:
			return c
	return null

# ── Slots ─────────────────────────────────────────────────────────────────

# The card occupying a slot — may be a dead decoy, may be null if unplaced.
func card_at(side: int, slot: int) -> FDCard:
	var row: Array = slots[side]
	if slot < 0 or slot >= row.size():
		return null
	return card_by_id(row[slot])

func slot_of(card: FDCard) -> int:
	var row: Array = slots[card.side]
	return row.find(card.id)

func opponent(side: int) -> int:
	return RED if side == BLACK else BLACK

# ── Reveals ───────────────────────────────────────────────────────────────

# True when `slot` on `side` is currently visible to that side's opponent.
func is_revealed(side: int, slot: int) -> bool:
	return revealed[side].has(slot)

# What `viewer` is allowed to know about an enemy slot. The AI is handed this
# and nothing else (PLAN M3 hard constraint) so it cannot cheat by construction.
func observe(viewer: int, enemy_slot: int) -> Dictionary:
	var enemy := opponent(viewer)
	var row: Array = slots[enemy]
	# Read the slot id directly rather than through card_at(), so a redacted
	# snapshot can say "occupied, identity withheld" (FDCard.HIDDEN) without
	# that collapsing into "empty". On authoritative state every id is real and
	# this behaves exactly as it did before.
	if enemy_slot >= 0 and enemy_slot < row.size() and int(row[enemy_slot]) == FDCard.HIDDEN:
		return _face_down(enemy_slot, _mark_at(enemy, enemy_slot))
	var occupant := card_at(enemy, enemy_slot)
	if occupant == null:
		return {"slot": enemy_slot, "known": false, "empty": true}
	if not is_revealed(enemy, enemy_slot):
		# Face down, but not blank: a shield, a rally or a heal was applied in
		# the open, so the buff is public even though the card is not. That is
		# what makes buffing a dead decoy a bluff worth spending an action on.
		return _face_down(enemy_slot, occupant.buff_marks())
	return {
		"slot": enemy_slot,
		"known": true,
		"empty": false,
		"card_name": occupant.card_name,
		"alive": occupant.alive,
		"hp": occupant.hp,
		"max_hp": occupant.max_hp,
		"shield": occupant.shield,
		"rally": occupant.rally_label(),
		"tricked": occupant.nullified,
		# Public: acting is what reveals a card in the first place, so every
		# enemy that has acted this round is one the viewer watched act.
		"acted": has_acted(occupant),
	}

func _face_down(slot: int, marks: Dictionary) -> Dictionary:
	return {
		"slot": slot, "known": false, "empty": false,
		"shielded": bool(marks.get("shielded", false)),
		"rallied": bool(marks.get("rallied", false)),
		"tended": bool(marks.get("tended", false)),
	}

func _mark_at(side: int, slot: int) -> Dictionary:
	var row: Array = hidden_marks.get(side, [])
	return row[slot] if slot >= 0 and slot < row.size() else {}

func observe_row(viewer: int) -> Array:
	var out: Array = []
	for i in range(board_size):
		out.append(observe(viewer, i))
	return out

# ── Turn bookkeeping ──────────────────────────────────────────────────────

func has_acted(card: FDCard) -> bool:
	return acted[card.side].has(card.id)

func unacted(side: int) -> Array[FDCard]:
	var out: Array[FDCard] = []
	for c in living(side):
		if not acted[side].has(c.id):
			out.append(c)
	return out

func has_unacted(side: int) -> bool:
	return not unacted(side).is_empty()

func is_over() -> bool:
	return phase == Phase.GAME_OVER
