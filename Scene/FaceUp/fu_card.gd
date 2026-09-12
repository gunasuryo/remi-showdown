extends RefCounted
class_name FUCard

# Face-up mode card DATA. Like FDCard, and for the same reason: this must be
# constructible and testable with no scene tree at all. The board scene renders
# one of these; it never owns one.
#
# It is deliberately NOT FDCard. The two modes agree on the stat table and on
# what a hit does, and disagree about almost everything else - a face-up shield
# is wiped at the start of its holder's own turn, a face-up trick is a hidden
# trap rather than a debuff, and rally+ here is `double_rally` on the King
# rather than FDCard's `king_plus`. Sharing one class would mean every field
# carrying a note about which mode reads it.
#
# ── Hidden status ─────────────────────────────────────────────────────────
#
# Face-up mode is no longer fully open. Cards, HP and positions are all still
# visible; three STATUSES are not. Each of the `*_seen` flags below means "both
# sides know about this now". Until one is set, the status is visible only to
# the side that CAUSED it:
#
#   shield  the Ace's own side sees it; the enemy does not, until it commits
#           an attack into the shielded card and the absorption gives it away.
#   rally   the King's own side sees it; the enemy does not, until the rallied
#           card uses a skill and it covers three lanes instead of one.
#   trick   the JOKER's side sees it - the victim's own side does not. That is
#           the inversion that makes the trick work: you find out you were
#           tricked by trying to use a skill and losing the turn.
#
# The flags are the memory of a status becoming public, not the status itself,
# so they are cleared alongside whatever they describe.

const NONE := -1

var id: int = NONE           # stable identity, survives death
var side: int = 1            # 1 = Black, 2 = Red
var card_name: String = ""   # "Ace" | "Jack" | "Queen" | "King" | "Joker"

var hp: int = 0
var max_hp: int = 0
var atk: int = 0
var skill_value: int = 0

# Shield is a point pool HELD UP BY ITS ACE. It lasts until that Ace acts again
# or dies - not on any clock of its own - so an Ace that stands still keeps
# shielding, and an Ace that does anything at all puts its shield down.
#
# It used to be wiped at the start of the SHIELDED card's own turn, which made
# it a one-round buff belonging to nobody. That version could not be moved, could
# not be maintained, and expired on a timer the Ace had no say in.
var shield: int = 0
var max_shield: int = CardStats.MAX_SHIELD_FACEUP
var shield_seen: bool = false   # the enemy has watched it absorb a hit
var shield_ace: int = NONE      # whose shield this is

var alive: bool = true

# Set by a King's rally on a chosen ally: that ally's next SKILL covers its
# target lane and both neighbours instead of one lane. Spent by using the
# skill; attacking does not take it away. A King setting a new rally clears the
# old one, so at most one ally is ever rallied.
#
# A rally is also armour against a trick - see skill_would_fail().
#
# It ends in one of three ways: the card spends it on a skill, the King that
# granted it acts again, or that King dies.
var rallied: bool = false
var rally_seen: bool = false    # the enemy has watched a skill spread
var rally_king: int = NONE      # whose rally this is

# King only, set by rallying itself: the next rally hands out two rallies
# instead of one. Consumed when it is used, not on a timer.
var double_rally: bool = false

# Set by a Joker's trick, and hidden from the card's own side. It is a TRAP,
# not a debuff: it does nothing at all until the victim tries to use a skill,
# at which point the skill fails, the turn is spent, and the trick is sprung
# and gone. A tricked card that attacks instead is entirely unaffected and the
# trap stays armed - which is what lets it stay hidden. It has no expiry.
#
# It halves the victim's attack as well, exactly as face-down's does.
#
# That was taken out when the trap went hidden, on the grounds that an owner
# watching their Jack hit for 13 instead of 26 has been told about the trick as
# surely as a label would tell them. True - but it is the wrong conclusion, and
# the board already had the right one. A hidden SHIELD is given away by the blow
# that lands on it, and that is not a leak because the attacker has already
# committed. A trap works the same way: whichever action the victim commits, the
# cost lands and the trap becomes public in the same instant. What the victim
# never gets is a chance to see it and choose differently.
#
# So the trap now bites whatever you do, which is what makes it worth an action
# at all. Denying only a skill made it nearly worthless - the scorer attacks on
# most turns, so most traps were simply never sprung, and the sweep priced
# `trick` at 0.0 and 0.35 identically.
#
# Like the shield and the rally, it is held up by the card that set it: it ends
# when it springs, when that Joker acts again, or when that Joker dies. So a
# Joker maintains at most ONE trap, and keeping it armed means standing still.
var tricked: bool = false
var trick_seen: bool = false    # the victim has sprung it
var trick_joker: int = NONE     # whose trap it is, for the log

static func create(p_id: int, p_side: int, p_name: String) -> FUCard:
	var c := FUCard.new()
	c.id = p_id
	c.side = p_side
	c.card_name = p_name
	c.max_hp = CardStats.hp_of(p_name, CardStats.FACE_UP)
	c.hp = c.max_hp
	c.atk = CardStats.atk_of(p_name, CardStats.FACE_UP)
	c.skill_value = CardStats.skill_of(p_name, CardStats.FACE_UP)
	return c

# What this card actually hits for. A live trap takes half of it.
#
# NOTE this reads `tricked` directly, so it is the TRUE number and not what any
# particular side believes. The AI must not price its attacks off it - see
# FUState.attack_seen_by(), which is what the scorer reads.
func attack_value() -> int:
	if tricked:
		return maxi(1, int(round(atk * CardStats.TRICK_ATTACK_MULT)))
	return atk

# Whether this card may ATTEMPT a skill. A tricked card may: it does not know,
# and finding out costs it the turn. This is the question the UI and the AI ask,
# so it must not consult `tricked` - that would hand the secret to both.
func may_attempt_skill() -> bool:
	return alive

# Whether that attempt is about to fail. Rules-internal, and the one place the
# trick and the rally meet: a rally is spent breaking the trick instead of
# widening the skill, so a rallied card gets its skill through - once.
func skill_would_fail() -> bool:
	return tricked and not rallied

func clear_trick() -> void:
	tricked = false
	trick_seen = false
	trick_joker = NONE

func clear_rally() -> void:
	rallied = false
	rally_seen = false
	rally_king = NONE

func clear_shield() -> void:
	shield = 0
	shield_seen = false
	shield_ace = NONE

# Absorb through the shield pool first, then HP. Identical math to
# FDCard.take_hit() - both funnel through CardStats.leak_of() so the two modes
# cannot disagree about what a hit does.
# Returns {"absorbed": int, "hp_lost": int, "died": bool}.
func take_hit(damage: int) -> Dictionary:
	var hp_before: int = hp
	var absorbed: int = 0
	if damage > 0:
		absorbed = min(shield, damage - CardStats.leak_of(damage))
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

func heal(amount: int) -> int:
	var before: int = hp
	hp = min(hp + amount, max_hp)
	return hp - before

func add_shield(amount: int) -> int:
	var before: int = shield
	shield = min(shield + amount, max_shield)
	return shield - before

# What this card's skill is CALLED. Same single source as FDCard.skill_word_for.
static func skill_word_for(p_name: String) -> String:
	return FDCard.skill_word_for(p_name)

func skill_word() -> String:
	return skill_word_for(card_name)

# Whether this card's skill aims at the enemy row or its own.
func targets_enemies() -> bool:
	return card_name in ["Jack", "Joker"]

# Coloured "Black Jack" / "Red Queen" tag for use inside log messages. It lives
# here rather than on the Card node because the battle log is now written from
# events by the board, and an event names a card by id - which still has to
# resolve to a name after the node for it has been freed.
func log_name() -> String:
	var col: String = "#dddddd" if side == 1 else "#ff8888"
	return "[color=%s][b]%s %s[/b][/color]" % [col, "Black" if side == 1 else "Red", card_name]
