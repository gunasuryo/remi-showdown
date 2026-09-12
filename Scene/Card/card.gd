extends Node2D
class_name Card

# A face-up board slot: art, health bars and the three buttons. PRESENTATION
# ONLY - every field below is a copy of what FUCard already holds, refreshed by
# table2.gd from the authoritative FUState after each action.
#
# This class used to BE the game. It held the rules (hit() did the shield and
# leak math), the subclasses held the skills (do_skill() applied them straight
# to other nodes), and both wrote the battle log by emitting from inside the
# card. That is why face-up mode could not be tested or networked: a rule and a
# Node2D were the same object. The rules now live in FURules, which references
# no scene at all.
#
# Nothing here may decide anything. If a method would answer "what happens
# next", it belongs in FURules.

@export var suit: int = 1  # 1 = Black, 2 = Red

var maxHP: int
var maxShield: int = CardStats.MAX_SHIELD_FACEUP
var HP: int
var attack: int
var skill: int
var shieldPoint: int = 0
var alive: bool = true

# Display mirrors of the matching FUCard flags - they drive the tint below and
# nothing else. What they MEAN is documented on FUCard, which is where they are
# actually set.
var rallied: bool = false
var doubleRally: bool = false
var tricked: bool = false

var suitName: String
var cardClassName: String

# Pushed down by FUStage while this card is NOT one of the two in the face-off.
# It rides on top of whatever tint update_stats() picks rather than replacing it,
# so a rallied card that is dimmed still reads as rallied when it lights back up.
var dim: float = 1.0:
	set(value):
		dim = value
		if is_node_ready():
			update_stats()

var battleBtnVisible: bool = false:
	set(value):
		battleBtnVisible = value
		if is_node_ready():
			$BattleButtons.visible = value

var targetBtnVisible: bool = false:
	set(value):
		targetBtnVisible = value
		if is_node_ready():
			$TargetButton.visible = value

signal attack_pressed(attack: int)
signal skill_pressed()
signal target_pressed(card: Card)

func _ready():
	set_stats()
	HP = maxHP
	$BattleButtons.visible = false
	$TargetButton.visible = false
	$HealthBar/HealthProgress.max_value = maxHP
	$ShieldBar/ShieldProgress.max_value = maxShield
	update_stats()
	if suit == 1:
		suitName = "Black"
		$Black.visible = true
		$Red.visible = false
	elif suit == 2:
		suitName = "Red"
		$Black.visible = false
		$Red.visible = true
		$HealthBar.position.y = -386
		$BattleButtons.position.y = 1150

# Overridden by the five subclasses, which is all they do now. Called by
# test/run_tests.gd without a scene tree, so it must not touch a node.
func set_stats():
	pass

# Copies one FUCard onto this node. The single point where authoritative state
# becomes something on screen.
#
# The three `seen_*` flags are what the VIEWER is entitled to know, and they are
# the whole reason this takes more than a card. Face-up mode hides a shield, a
# rally and a trick from the side that did not cause it, and a node that drew
# them straight off the FUCard would put every one of them on screen - the tint
# and the shield bar would simply announce what the rules went to the trouble of
# concealing. FUState.sees_* decides; this only draws.
func show_card(c: FUCard, seen_shield: bool, seen_rally: bool, seen_trick: bool) -> void:
	HP = c.hp
	maxHP = c.max_hp
	attack = c.atk
	skill = c.skill_value
	maxShield = c.max_shield
	alive = c.alive
	doubleRally = c.double_rally
	shieldPoint = c.shield if seen_shield else 0
	rallied = c.rallied and seen_rally
	tricked = c.tricked and seen_trick
	update_stats()

func update_stats():
	$HealthBar/HealthProgress.max_value = maxHP
	$HealthBar/HealthProgress.value = HP
	$HealthBar/HealthLabel.text = str(HP)
	$ShieldBar/ShieldProgress.max_value = maxShield
	$ShieldBar/ShieldProgress.value = shieldPoint
	$ShieldBar/ShieldLabel.text = str(shieldPoint)
	# A rally and a trick are no longer tints. They are the KING or the JOKER
	# standing behind this card - see set_marker() - because a colour has to be
	# learned and a face does not, and because two overlapping status colours on
	# one card were indistinguishable from a third colour.
	#
	# doubleRally keeps a tint: it is a property of the King itself rather than
	# something done TO a card, so there is no other card to stand behind it.
	var tint: Color
	if not alive:
		tint = Color(1, 1, 1, 0.3)
	elif doubleRally:
		tint = Color(0.6, 1.4, 0.6, 1)   # green tint = double rally ready
	else:
		tint = Color(1, 1, 1, 1)
	modulate = Color(tint.r * dim, tint.g * dim, tint.b * dim, tint.a)
	if _marker != null and _marker.visible:
		_marker.modulate = Color(
			marker_tint.r * dim, marker_tint.g * dim, marker_tint.b * dim, MARKER_ALPHA)

# The face of this card, for FUStage to clone when a caster has to appear next
# to someone it is acting on. Only one of the two sprites is ever visible - see
# _ready() - so this returns whichever one is showing.
func art_texture() -> Texture2D:
	return $Black.texture if suit == 1 else $Red.texture

# ─── The caster marker ───────────────────────────────────────────────────
#
# The card that is holding a status on this one, parked behind it for as long as
# it lasts: the King behind a rallied ally, the Joker behind a trapped enemy.
# It replaces the gold and pink tints, which had two problems - a colour has to
# be learned before it means anything, and the card could only ever wear one of
# them at a time even when it carried both.
#
# It is offset to the upper LEFT so it does not sit under FUStage's transient
# ghost, which rises centrally on the same z_index: the marker says "this is
# still true", the ghost says "this just happened", and they have to be able to
# appear together.
#
# WHAT IT MUST NOT DO is show a status the viewer is not entitled to see. It
# takes no view of that itself - table2._sync_cards passes a texture only when
# FUState.sees_* allows one, exactly as it decides what the log may print.
const MARKER_OFFSET := Vector2(-210.0, -250.0)
const MARKER_SCALE := Vector2(0.46, 0.46)
const MARKER_ALPHA: float = 0.92

var marker_tint: Color = Color(1, 1, 1, 1)
var _marker: Sprite2D = null

func set_marker(tex: Texture2D, tint: Color) -> void:
	if tex == null:
		clear_marker()
		return
	if _marker == null:
		_marker = Sprite2D.new()
		_marker.z_index = -1
		_marker.scale = MARKER_SCALE
		_marker.position = MARKER_OFFSET
		add_child(_marker)
	_marker.texture = tex
	_marker.visible = true
	marker_tint = tint
	update_stats()

func clear_marker() -> void:
	if _marker != null:
		_marker.visible = false

func has_marker() -> bool:
	return _marker != null and _marker.visible

# ─── Floating text ───────────────────────────────────────────────────────
#
# A number rising off the card: -12 for a hit, +30 for a heal, or the name of a
# status that has just landed. The board renders STATE; without this it never
# renders CHANGE, and every hit is a silent jump in a progress bar.
#
# The same idea as FDCardView.pop(), rebuilt for a Node2D: that one is a Control
# and lays itself out with anchors, which do not exist here.
const POP_RISE: float = 190.0
const POP_TIME: float = 0.85

func pop(text: String, colour: Color, offset: Vector2 = Vector2.ZERO) -> void:
	if not is_node_ready():
		return
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 96)
	l.add_theme_color_override("font_color", colour)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 14)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.size = Vector2(500.0, 120.0)
	l.position = Vector2(-250.0, -260.0) + offset
	l.z_index = 20
	add_child(l)

	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(l, "position:y", l.position.y - POP_RISE, POP_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(l, "modulate:a", 0.0, POP_TIME).set_delay(0.25)
	t.chain().tween_callback(l.queue_free)

# ─── Aiming preview ──────────────────────────────────────────────────────
#
# What this card would take from the action being aimed right now, shown while
# the target buttons are up. Without it, picking a target is a guess about your
# own numbers rather than a decision about theirs.
#
# It quotes what the player CAN know: the caller prices it against the shield
# the viewer has actually seen, so a hidden shield still eats the difference
# when the blow lands. That is the bluff working, not the preview lying.
var _preview: Label = null

func show_preview(text: String, colour: Color) -> void:
	if _preview == null:
		_preview = Label.new()
		_preview.add_theme_font_size_override("font_size", 84)
		_preview.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		_preview.add_theme_constant_override("outline_size", 12)
		_preview.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_preview.size = Vector2(500.0, 110.0)
		_preview.position = Vector2(-250.0, -120.0)
		_preview.z_index = 19
		add_child(_preview)
	_preview.text = text
	_preview.add_theme_color_override("font_color", colour)
	_preview.visible = true

func clear_preview() -> void:
	if _preview != null:
		_preview.visible = false

func _on_attack_btn_pressed():
	battleBtnVisible = false
	attack_pressed.emit(attack)

func _on_skill_btn_pressed():
	battleBtnVisible = false
	skill_pressed.emit()

func _on_target_button_pressed():
	target_pressed.emit(self)
