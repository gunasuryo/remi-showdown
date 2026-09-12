extends RefCounted
class_name FUState

# Whole-match state for face-up mode. Pure data + queries; every mutation that
# implements a rule lives in FURules, the same separation the face-down side
# keeps between FDState and FDRules.

enum Phase { BATTLE, GAME_OVER }

const BLACK := 1
const RED := 2

# All ten cards. Dead ones stay in this array so an id always resolves to a
# name for the log, but they are removed from `rows` - unlike face-down, this
# mode has no decoys and a corpse leaves the board.
var cards: Array[FUCard] = []

# side -> Array[int] of card ids, living only, in slot order. THE board.
# When a card dies its slot collapses and everything to its right shifts left,
# which is why slot indices are never stored on a card.
var rows := {BLACK: [], RED: []}

# Which suit acts first in each slot pair, for the round now being played.
# It ALTERNATES: whoever led this round follows the next one.
#
# The coin flip still matters and is still the reason this mode has no seat
# imbalance - it decides who leads round ONE, which is the advantage face-down
# hands to Black unconditionally and pays about 14 points of win rate for. What
# the alternation adds is that the edge does not then compound: over a match of
# any length both colours lead about half the rounds.
var first_suit: int = BLACK

# One full pass of the slot walk. Face-up has no rounds in any RULES sense -
# nothing expires on one and nothing resets - so this counts purely so the board
# can put a "ROUND N" card up between passes. It is deliberately here rather
# than in the board: the board cannot spot a wrap reliably, because _start_turn
# skips slots that only one side can fill.
var round_no: int = 1

var current_slot: int = 0
var current_suit: int = BLACK
var current_id: int = FUCard.NONE   # the card whose turn it is

var phase: int = Phase.BATTLE
var player_side: int = BLACK        # which side the human controls

# 0 = undecided, 1 = Black, 2 = Red, 3 = draw. Written by FURules only.
var outcome: int = 0

var _next_id: int = 0

func new_id() -> int:
	var v := _next_id
	_next_id += 1
	return v

# ── Lookups ───────────────────────────────────────────────────────────────

func card_by_id(id: int) -> FUCard:
	for c in cards:
		if c.id == id:
			return c
	return null

func find_by_name(side: int, card_name: String) -> FUCard:
	for c in cards:
		if c.side == side and c.card_name == card_name:
			return c
	return null

func opponent(side: int) -> int:
	return RED if side == BLACK else BLACK

# ── The board ─────────────────────────────────────────────────────────────

# Living cards of `side` in slot order.
func living(side: int) -> Array[FUCard]:
	var out: Array[FUCard] = []
	for id in rows[side]:
		var c := card_by_id(id)
		if c != null:
			out.append(c)
	return out

func living_count(side: int) -> int:
	return rows[side].size()

func card_at(side: int, slot: int) -> FUCard:
	var row: Array = rows[side]
	if slot < 0 or slot >= row.size():
		return null
	return card_by_id(row[slot])

func slot_of(card: FUCard) -> int:
	if card == null:
		return -1
	return rows[card.side].find(card.id)

func allies_of(side: int) -> Array[FUCard]:
	return living(side)

func enemies_of(side: int) -> Array[FUCard]:
	return living(opponent(side))

# The widest the board currently is. Turn order walks slots up to this, so a
# side with more survivors still gets to act with its extra cards.
func max_slot() -> int:
	return max(rows[BLACK].size(), rows[RED].size())

func current_card() -> FUCard:
	return card_by_id(current_id)

# ── Reach ─────────────────────────────────────────────────────────────────

# The enemy slot an attack from `from_slot` hits head-on. When the enemy row is
# SHORTER than the attacker's slot index the edge card takes over: the last
# enemy stands in for every slot past the end of its row, so a card at slot 4
# facing two survivors still has something to hit.
func direct_slot(attacker_side: int, from_slot: int) -> int:
	var enemies: Array = rows[opponent(attacker_side)]
	if enemies.is_empty():
		return -1
	return min(from_slot, enemies.size() - 1)

# The enemy slots an attack from `from_slot` may reach - in this mode, exactly
# the one it faces and nothing else. A regular attack is strictly lane-locked
# here; only a skill picks a target.
#
# It used to reach either neighbour for CardStats.ADJACENT_MULT of the damage,
# which gave a plain attack a decision to make. That belongs to face-down,
# where a lane may hold a corpse and spending a whole turn on one is the thing
# worth avoiding. Face-up has no decoys - every lane holds a living card or no
# card - so the side-reach was a free damage-shopping option on every single
# turn, and it drowned the skills: the scorer attacked on 98% of its turns.
# ADJACENT_MULT is now read by face-down alone.
func attack_slots(attacker_side: int, from_slot: int) -> Array:
	var idx := direct_slot(attacker_side, from_slot)
	return [] if idx < 0 else [idx]

# The row a card's skill picks its target out of.
func skill_pool(card: FUCard) -> Array[FUCard]:
	return enemies_of(card.side) if card.targets_enemies() else allies_of(card.side)

# A target slot and, when a rally is in play, its two neighbours.
func lane_set(pool_size: int, center: int, spread: bool) -> Array:
	var out: Array = []
	if not spread:
		if center >= 0 and center < pool_size:
			out.append(center)
		return out
	for i in range(center - 1, center + 2):
		if i >= 0 and i < pool_size:
			out.append(i)
	return out

# ── Who may know what ─────────────────────────────────────────────────────
#
# Cards, HP and positions are open. Three statuses are not, and each is visible
# to the side that CAUSED it until the moment it becomes public. Everything the
# AI reads about a status goes through these, so it cannot cheat by
# construction - the same rule FDState.observe() enforces for face-down.
#
# The trick inverts: it is applied BY the opponent, so the opponent is the side
# that already knows, and the card's OWN side is the one kept in the dark.

func sees_shield(viewer: int, c: FUCard) -> bool:
	return c.side == viewer or c.shield_seen

func sees_rally(viewer: int, c: FUCard) -> bool:
	return c.side == viewer or c.rally_seen

func sees_trick(viewer: int, c: FUCard) -> bool:
	return c.side != viewer or c.trick_seen

# The shield `viewer` is entitled to plan around. An unseen enemy shield reads
# as zero, so an attack aimed at it is aimed in ignorance - which is the point.
func shield_seen_by(viewer: int, c: FUCard) -> int:
	return c.shield if sees_shield(viewer, c) else 0

# What `viewer` believes `c` will hit for. A trap it cannot see is a trap it
# cannot price, so the attack reads at full value right up until it lands.
#
# Without this the halved attack would leak straight into the scorer: FUAI reads
# an attack's worth to compare it against a skill, and FUCard.attack_value()
# returns the true - halved - number. The AI would quietly know it was trapped
# one move before the player in the same position could, and would route around
# the trap it is not supposed to be able to see.
func attack_seen_by(viewer: int, c: FUCard) -> int:
	return c.attack_value() if sees_trick(viewer, c) else c.atk

func rally_seen_by(viewer: int, c: FUCard) -> bool:
	return c.rallied and sees_rally(viewer, c)

func trick_seen_by(viewer: int, c: FUCard) -> bool:
	return c.tricked and sees_trick(viewer, c)

func is_over() -> bool:
	return phase == Phase.GAME_OVER
