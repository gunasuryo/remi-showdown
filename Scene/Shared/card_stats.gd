extends RefCounted
class_name CardStats

# The card numbers. ONE TABLE PER MODE, and they are allowed to disagree.
#
# This file used to hold a single table shared by both modes, on the argument
# that a copy would be wrong within a week. That argument was right about copies
# and wrong about these two games. Face-up and face-down no longer play the same
# cards in any sense the numbers can span: face-up hides three statuses, treats
# a trick as a trap that costs a whole action, locks an attack to the lane it
# faces and holds a buff until its caster moves; face-down reveals rows, keeps
# corpses as decoys, lets an attack reach a neighbour and runs on rounds. A
# single Jack cannot be balanced for both, and every attempt to tune one was
# quietly retuning the other.
#
# What replaced "there is only one table" is that NO ACCESSOR HAS A DEFAULT
# MODE. Every read names the game it is talking about:
#
#     CardStats.hp_of("Jack", CardStats.FACE_UP)
#
# A missing argument is a parse error, so a call site cannot silently read the
# wrong game the way it could silently read a stale copy. That is the failure
# this file still exists to prevent - only the shape of it has changed.
#
# Face-up reads FACEUP through Card.set_stats() and FUCard.create().
# Face-down reads FACEDOWN through FDCard.create() and FDNet.
#
# `rallied` is the PER-LANE value once a rally spreads the skill over three
# lanes. Reach is bought with power rather than being free: an unrallied Shoot
# is 20 into one lane, a rallied one 17 into each of three.
#
# It is a column here rather than a multiplier because these are chosen as
# absolute numbers - 17, 25 - and a shared ratio cannot hit both (30 x 0.85 is
# 26, not 25). One number per card, in the table that already owns every other
# number, beats arithmetic that has to be reverse-engineered.
#
# Omit `rallied` and the skill spreads at full value; the King and Joker have no
# numeric skill at all, so it means nothing for them. It is carried in BOTH
# tables, but only face-down reads it today - FURules spreads a rallied skill at
# full value. The face-up column is there so that wiring it up is a one-line
# change rather than a fresh round of tuning.

const FACE_UP := 0
const FACE_DOWN := 1

# ── Face-up ──────────────────────────────────────────────────────────────
# Untouched since the split: these are the numbers both modes shared, kept as
# the starting point rather than re-guessed. There is no face-up sweep harness
# to derive better ones with - test/bench_faceup.gd measures policies against
# each other, not stats - so tuning this table is still an open job.
const STATS_FACEUP := {
	"Ace":   {"hp": 60, "atk": 14, "skill": 30, "rallied": 25},  # skill = shield points granted
	"Jack":  {"hp": 45, "atk": 26, "skill": 20, "rallied": 17},  # skill = shoot damage
	"Queen": {"hp": 55, "atk": 14, "skill": 30},                 # skill = heal amount
	"King":  {"hp": 70, "atk": 20, "skill": 0},   # skill = rally, no numeric value
	"Joker": {"hp": 65, "atk": 16, "skill": 0},   # skill = trick, no numeric value
}

# ── Face-down ────────────────────────────────────────────────────────────
# Every note below was measured with test/strategy_fd.gd and test/bench_ai.gd,
# which are face-down harnesses. They describe THIS table and nothing about the
# one above - which is most of the reason the two are now separate files' worth
# of decisions rather than one.
const STATS_FACEDOWN := {
	"Ace":   {"hp": 60, "atk": 14, "skill": 30, "rallied": 25},  # skill = shield points granted
	"Jack":  {"hp": 45, "atk": 26, "skill": 20, "rallied": 17},  # skill = shoot damage
	"Queen": {"hp": 55, "atk": 14, "skill": 30},                 # skill = heal amount
	"King":  {"hp": 70, "atk": 20, "skill": 0},   # skill = rally, no numeric value
	"Joker": {"hp": 65, "atk": 16, "skill": 0},   # skill = trick, no numeric value
}

# These are FINAL numbers: what a card reads is what it deals. Face-down mode
# used to multiply damage and shields by a separate DAMAGE_SCALE of 2.0, which
# meant a card showing 10 attack hit for 20 - confusing to read, and it silently
# invalidated every tuned AI weight each time this table moved. That factor is
# folded in here and the scale now sits at 1.0.

# The Queen was 40hp - the lowest in the game - while also being the support
# card, which is backwards. She died first in 132 of 400 matches, a third of
# them, and a healer who dies first is a card you would rather not have been
# dealt.
#
# 55 was picked by isolating the two candidate fixes in test/strategy_fd.gd:
#
#   change              Queen died first   Queen dmg   Jack dmg
#   shipped (40hp/14)         132             5.2%       34.4%
#   hp 55 only                 52             6.2%       34.2%
#   atk 18 only               135             6.1%       36.6%
#
# HP is the fix; attack is not. Raising her attack left her dying just as fast
# and simply fed the Jack. Her damage share staying lowest is expected and fine:
# she spends three quarters of her turns healing, so "removed less HP" is what a
# support card looks like. What was unfair was being worst on every axis at once.
#
# Attack was left alone everywhere. It is 70% of all actions taken, so atk is
# the dominant stat, and every atk change tested rippled somewhere unintended -
# cutting the King to 17 pushed the Jack UP to 55% of all damage, because a
# weaker royal attack makes rallying relatively better and the King stops
# swinging to feed the Jack instead.

# Deal order — also the order cards are created in for a new match.
const ORDER := ["Ace", "Jack", "Queen", "King", "Joker"]

# Shield ceilings. Both now equal the Ace's grant, because in BOTH modes only
# ONE application can ever be live at a time, and for the same reason: the
# shield is tied to its Ace, and that Ace puts the old one down before it can
# raise a new one, so it never accumulates.
#
# Face-up used to differ - the shield was wiped at the start of the SHIELDED
# card's own turn, a one-round buff belonging to nobody. Both modes now run the
# caster-held rule, which means neither ceiling is reachable by stacking.
# A rally does NOT raise this. It triples the number of TARGETS - three allies
# at 30 each - it never stacks value on one card.
# A shield NEVER fully stops a hit: this fraction of every incoming blow
# bleeds straight through to HP, with a floor of 1. It is what makes a
# defensive wall impossible - shields delay death, they cannot prevent it,
# so damage per round has a floor and a match must end.
#
# Lowered from 0.20 to 0.10: at a fifth the leak was doing more than
# guaranteeing termination, it was making a 30-point shield worth barely two
# hits. At a tenth most attacks leak 1-3 instead of 3-5, so the Ace buys real
# time. This is the knob that keeps matches finite, so it can go down but it
# cannot go to zero - watch the `unfinished` column in test/sweep_ai.gd after
# touching it, and re-sweep the AI's `shield` weight, which prices exactly
# this.
# BOTH MODES. A tricked card keeps its turn but loses its skill and hits for
# this much of its attack: denial without a lost turn, so a trick cannot stall
# a match.
#
# Face-up went without it for a while, on the reasoning that a visible dent in a
# card's damage would announce a trap that is supposed to be hidden. It does
# announce it - but only once the victim has already committed the turn, which
# is the same bargain a hidden shield strikes with the attack that reveals it.
# Denying the skill alone made the face-up trick worth almost nothing, because
# the scorer mostly attacks and so mostly never sprang one.
const TRICK_ATTACK_MULT := 0.5

# FACE-DOWN ONLY. An attack there may hit its own lane or either neighbour, and
# a neighbour costs this much of the damage. It is what gives an attack a
# decision to make, and it is why a revealed decoy no longer wastes a whole
# turn.
#
# Face-up no longer reads it either: an attack there hits the lane it faces and
# nothing else. With no decoys on that side there was no wasted turn to dodge,
# so the reach was a free damage-shopping option on every turn and it drowned
# the skills - the scorer used one on 5% of its turns, against 9-12% now.
const ADJACENT_MULT := 0.5


const SHIELD_LEAK := 0.10
const SHIELD_LEAK_MIN := 1

const MAX_SHIELD_FACEUP := 30
const MAX_SHIELD_FACEDOWN := 30

# `mode` is FACE_UP or FACE_DOWN and is deliberately NOT optional. A default
# would let a call site read the wrong game by omission, which is the one
# mistake the split makes possible and the single table did not.
static func table_of(mode: int) -> Dictionary:
	match mode:
		FACE_UP: return STATS_FACEUP
		FACE_DOWN: return STATS_FACEDOWN
	# Spelled out rather than falling through to a default. An unrecognised mode
	# used to land on face-down silently, which is the same class of bug as an
	# optional argument: a caller gets a plausible table instead of a complaint.
	push_error("CardStats: unknown mode %d" % mode)
	return STATS_FACEDOWN

static func has_card(card_name: String, mode: int) -> bool:
	return table_of(mode).has(card_name)

static func hp_of(card_name: String, mode: int) -> int:
	return table_of(mode)[card_name]["hp"]

static func atk_of(card_name: String, mode: int) -> int:
	return table_of(mode)[card_name]["atk"]

static func skill_of(card_name: String, mode: int) -> int:
	return table_of(mode)[card_name]["skill"]

# What one lane gets when the skill is spread by a rally.
static func rallied_skill_of(card_name: String, mode: int) -> int:
	var st: Dictionary = table_of(mode)[card_name]
	return int(st.get("rallied", st["skill"]))

# How much of `damage` refuses to be absorbed by a shield. Never more than the
# hit itself, so a 1-damage poke still costs exactly 1 HP rather than being
# rounded up.
#
# It lives here, next to SHIELD_LEAK and SHIELD_LEAK_MIN, because both modes
# need it: FDCard.leak_of() delegates to it and FUCard.take_hit() calls it
# directly. It used to live on FDCard alone, which meant face-up mode reached
# across into the face-down card class for its own damage math.
static func leak_of(damage: int) -> int:
	if damage <= 0:
		return 0
	return min(damage, max(SHIELD_LEAK_MIN, int(round(damage * SHIELD_LEAK))))
