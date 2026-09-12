extends Card

# Joker — Trickster. Tricks an enemy; rallied, it tricks three lanes.
#
# What the skill DOES lives in FURules._do_skill. This subclass exists only
# to name the card and pull its three numbers off the shared stat table.

func set_stats():
	cardClassName = "Joker"
	maxHP = CardStats.hp_of(cardClassName, CardStats.FACE_UP)
	attack = CardStats.atk_of(cardClassName, CardStats.FACE_UP)
	skill = CardStats.skill_of(cardClassName, CardStats.FACE_UP)
