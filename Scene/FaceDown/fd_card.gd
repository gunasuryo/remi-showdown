extends RefCounted
class_name FDCard

# Face-down mode card DATA. Deliberately not a Node2D and deliberately not the
# existing `Card` class: this must be constructible and testable with no scene
# tree at all (PLAN D3). The board scene renders one of these; it never owns one.

const NONE := -1

# A slot that holds a card whose identity the viewer is not entitled to know.
# It only ever appears in a REDACTED snapshot sent to a networked client - the
# authoritative state always has real ids. It exists so that "nobody is here"
# and "somebody is here and you cannot see who" are different values, rather
# than the client being sent a plausible lie it might later render.
const HIDDEN := -2

var id: int = NONE           # stable identity, survives death — slots store ids
var side: int = 1            # 1 = Black, 2 = Red
var card_name: String = ""   # "Ace" | "Jack" | "Queen" | "King" | "Joker"

var hp: int = 0
var max_hp: int = 0
var atk: int = 0
var skill_value: int = 0

# Shield is a POINT POOL, not PRD tokens (PLAN §2.1). It never expires in this
# mode — the face-up start-of-turn wipe must not be ported over.
var shield: int = 0
var max_shield: int = CardStats.MAX_SHIELD_FACEDOWN
var shield_ace: int = NONE   # id of the Ace holding this shield up

var alive: bool = true

# What an opponent WATCHED happen to this card this round. These are not the
# buffs themselves - a shield and a rally both outlive the round - they are the
# memory of seeing one applied, and FDRules.begin_round wipes them along with
# the reveals.
#
# They have to be transient, because the row is rearranged between rounds. A
# mark drawn from lasting state would reappear on whatever slot the card moved
# to, quietly announcing its new position every round - the exact opposite of
# what repositioning is for.
var mark_shielded: bool = false
var mark_rallied: bool = false
var mark_tended: bool = false

# ── Rally state (PLAN §2.3) ───────────────────────────────────────────────
# A rally always does the same thing to the card that receives it: its next
# skill covers three lanes instead of one. There is no stronger version of it.
#
# rally+ is a property of the KING, not of the card it rallies. An armed King
# rallies three allies at once instead of one. It used to instead upgrade a
# single ally's skill from three lanes to the whole board, which measured as
# worth nothing: the board is at most five wide and shrinks as cards die, so
# the upgrade bought at most two extra lanes - and it cost the King a whole
# separate action to arm. Three rallied allies is three future skills; one
# slightly wider skill was one.
var rallied: bool = false          # next skill hits 3 lanes
var rally_king: int = NONE         # id of the King that granted it
var rally_last: bool = false       # granting King died — survives across rounds
var king_plus: bool = false        # King only: rally+ armed by a self-rally

# ── Trick state (PLAN §2.4) ───────────────────────────────────────────────
var nullified: bool = false
var joker_link: int = NONE         # id of the Joker whose trick is holding it

static func create(p_id: int, p_side: int, p_name: String) -> FDCard:
	var c := FDCard.new()
	c.id = p_id
	c.side = p_side
	c.card_name = p_name
	c.max_hp = CardStats.hp_of(p_name, CardStats.FACE_DOWN)
	c.hp = c.max_hp
	c.atk = CardStats.atk_of(p_name, CardStats.FACE_DOWN)
	c.skill_value = CardStats.skill_of(p_name, CardStats.FACE_DOWN)
	return c

func has_rally() -> bool:
	return rallied or rally_last

func clear_rally() -> void:
	rallied = false
	rally_last = false
	rally_king = NONE

func clear_nullify() -> void:
	nullified = false
	joker_link = NONE

# What an opponent may see about this card even while it is face down. Buffs are
# public: the action that applied one was taken in the open.
func buff_marks() -> Dictionary:
	return {"shielded": mark_shielded, "rallied": mark_rallied, "tended": mark_tended}

func clear_marks() -> void:
	mark_shielded = false
	mark_rallied = false
	mark_tended = false

func clear_shield() -> void:
	shield = 0
	shield_ace = NONE

# A trick costs the skill AND half the attack, but never the turn itself -
# denying a whole action is what would let two Jokers stall a match.
func attack_value() -> int:
	if nullified:
		return max(1, int(round(atk * CardStats.TRICK_ATTACK_MULT)))
	return atk

func can_use_skill() -> bool:
	return alive and not nullified

# Absorb through the shield pool first, then HP. Mirrors Card.hit()'s math so
# the two modes cannot disagree about what a hit does.
# Returns {"absorbed": int, "hp_lost": int, "died": bool}.
func take_hit(damage: int) -> Dictionary:
	var hp_before: int = hp
	var absorbed: int = 0
	if damage > 0:
		absorbed = min(shield, damage - leak_of(damage))
		shield -= absorbed
	var remaining: int = damage - absorbed
	hp -= remaining
	var died := false
	if hp <= 0:
		hp = 0
		if alive:
			died = true
		alive = false
	return {"absorbed": absorbed, "hp_lost": hp_before - hp, "died": died}

# Kept as the name the face-down side calls; the formula itself lives on
# CardStats next to the constants it reads, so face-up mode does not have to
# reach into this class for it.
static func leak_of(damage: int) -> int:
	return CardStats.leak_of(damage)

func heal(amount: int) -> int:
	var before: int = hp
	hp = min(hp + amount, max_hp)
	return hp - before

# `cap` lets the rules pass a ceiling in the same units as the granted
# amount; both are scaled by damage_scale, while max_shield is the raw one.
func add_shield(amount: int, cap: int = -1) -> int:
	var ceiling: int = max_shield if cap < 0 else cap
	var before: int = shield
	shield = min(shield + amount, ceiling)
	return shield - before

# What this card's skill is CALLED. The single source for it: the board writes
# it on the action button, the log uses it, and a rallied card advertises it
# with a "+". A player should never have to translate "skill" into "shield".
static func skill_word_for(p_name: String) -> String:
	match p_name:
		"Ace": return "Shield"
		"Jack": return "Shoot"
		"Queen": return "Heal"
		"King": return "Rally"
		"Joker": return "Trick"
	return "Skill"

func skill_word() -> String:
	return skill_word_for(card_name)

# The rally state spelled out for the UI. These read as words rather than the
# PRD 10 shorthand (R / R+ / R! / K+): there is room on a card for "SHOOT+",
# and a player should not have to learn a key to read the board.
#
# A rallied card is labelled by its own skill - SHOOT+, SHIELD+, HEAL+ - rather
# than by a generic "RALLIED", because what the rally actually changes is that
# card's skill, and naming it says which one. RALLY+ belongs to the King alone
# and means "the next rally I grant hits three allies".
#
# Trick state is `nullified` and is rendered separately, because a King can
# hold an armed rally+ AND be tricked at once.
func rally_label() -> String:
	if rally_last:
		return "%s+ (LAST)" % skill_word().to_upper()
	if rallied:
		return "%s+" % skill_word().to_upper()
	if king_plus:
		return "RALLY+ READY"
	return ""
