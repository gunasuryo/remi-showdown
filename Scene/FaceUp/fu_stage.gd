extends RefCounted
class_name FUStage

# The face-up presentation layer: the round card, the face-off framing, and the
# animation of everything FURules reports.
#
# It owns no rules and asks no questions. It is handed card nodes and an event
# list and it moves things about; every decision was made before it was called.
# That is the same split table2.gd keeps with FURules, one layer further out.
#
# Every method that takes time is a coroutine, and the board AWAITS it. So the
# whole animation layer can be turned off by never awaiting anything - see
# `enabled`, which the headless tests clear. With it off, every method here
# returns without reaching an `await`, and the board runs synchronously exactly
# as it did before any of this existed.

# ── Timings, in seconds. All of them are guesses that want a human eye. ───
const ROUND_CARD_HOLD: float = 0.9
const FACEOFF_IN: float = 0.35
const LUNGE_OUT: float = 0.16
const LUNGE_BACK: float = 0.20
const APPROACH: float = 0.30
const GHOST_IN: float = 0.25
const GHOST_HOLD: float = 0.45
const GHOST_OUT: float = 0.25

# How far a card leans when it attacks, in world units, and how far a targeting
# card travels toward what it is aiming at (a fraction of the gap, so it reads
# as "moving on it" without landing on top of it).
const LUNGE_DISTANCE: float = 260.0
const APPROACH_FRACTION: float = 0.55

# What a card outside the face-off is multiplied down to.
const DIM: float = 0.34

# The three casters, in the colour their status is written in everywhere else.
const SHIELD_TINT := Color(0.45, 0.78, 1.0)
const RALLY_TINT := Color(1.0, 0.84, 0.31)
const TRICK_TINT := Color(0.81, 0.58, 0.85)
const DAMAGE_TINT := Color(1.0, 0.36, 0.34)
const HEAL_TINT := Color(0.52, 0.85, 0.55)

var enabled: bool = true

# ── Skipping ──────────────────────────────────────────────────────────────
#
# A click on empty board fast-forwards the rest of the current action.
#
# It works by winding live tweens FORWARD, never by killing them. Tween.kill()
# does not emit `finished`, so every coroutine sitting on `await t.finished`
# would block for good - and because the board only takes input again when that
# chain reaches _offer_turn(), a killed tween is not a skipped animation, it is
# a hung game. Speeding one up ends it in a frame or two AND fires `finished`,
# so the chain unwinds on its own and the card lands where it was going.
#
# The damage numbers are deliberately NOT in `_live`: they are tweens on the
# Card itself, so skipping the movement leaves the feedback to play out. Being
# able to skip the choreography without losing what it told you is the whole
# point of the button.
const SKIP_SPEED: float = 24.0

var _skip: bool = false
var _live: Array[Tween] = []

var _board: Node = null          # table2, for get_tree() and the card views
var _ui: Control = null          # UI/Root
var _camera: Node = null

var _round_label: Label = null
var _menu: Control = null
var _attack_btn: Button = null
var _skill_btn: Button = null
var _cancel_btn: Button = null
var _focus: Array = []           # the cards currently lit

# What the player pressed. The stage does not act on any of them - it reports,
# and table2 turns the press into an action for FURules.
signal attack_chosen()
signal skill_chosen()
signal cancel_chosen()

func setup(board: Node, ui_root: Control, camera: Node) -> void:
	_board = board
	_ui = ui_root
	_camera = camera
	_build_labels()
	_build_menu()

# Built in code rather than added to table_2.tscn. The scene is shared with a
# working board and hand-editing a .tscn to add two labels is a good way to
# break the one thing that already works.
func _build_labels() -> void:
	_round_label = _make_banner(52)

func _make_banner(size: int) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.set_anchors_preset(Control.PRESET_CENTER_TOP)
	l.anchor_left = 0.0
	l.anchor_right = 1.0
	l.offset_top = 40.0
	l.offset_bottom = 130.0
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 8)
	l.offset_bottom = 220.0
	l.modulate.a = 0.0
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(l)
	return l

# The two choices, between the two cards facing each other rather than hanging
# off the acting card. During a face-off the acting card is one of two filling
# the screen, and a button pinned to it lands wherever that card happens to be.
#
# Built and shown regardless of `enabled`: it is instant, it never awaits, and
# the headless tests reach _on_attack()/_on_skill() directly, so leaving it out
# of the disabled path would only mean the shipping menu went untested.
func _build_menu() -> void:
	_menu = VBoxContainer.new()
	_menu.set_anchors_preset(Control.PRESET_CENTER)
	_menu.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_menu.grow_vertical = Control.GROW_DIRECTION_BOTH
	_menu.add_theme_constant_override("separation", 14)
	_menu.visible = false
	_ui.add_child(_menu)

	_attack_btn = _make_button("Attack")
	_skill_btn = _make_button("Skill")

	_attack_btn.pressed.connect(func(): Sound.cue("click"); attack_chosen.emit())
	_skill_btn.pressed.connect(func(): Sound.cue("click"); skill_chosen.emit())

	# Backing out of a target choice. Right-click does the same thing and is
	# quicker, but there is no right button on a phone, so the mechanic cannot
	# live on one - and a player who has opened the target picker by accident
	# should never be forced to spend the turn on it.
	#
	# It sits in the reserved HUD column, above < Menu. Anywhere over the board
	# is somewhere a card can be, and the whole point of the targeting view is
	# that every lane is visible.
	_cancel_btn = Button.new()
	_cancel_btn.text = "Cancel"
	_cancel_btn.add_theme_font_size_override("font_size", 21)
	_cancel_btn.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_cancel_btn.anchor_top = 1.0
	_cancel_btn.anchor_bottom = 1.0
	_cancel_btn.offset_left = 16.0
	_cancel_btn.offset_right = 300.0
	_cancel_btn.offset_top = -168.0
	_cancel_btn.offset_bottom = -96.0
	_cancel_btn.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_cancel_btn.visible = false
	_ui.add_child(_cancel_btn)
	_cancel_btn.pressed.connect(func(): Sound.cue("cancel"); cancel_chosen.emit())

func _make_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(240.0, 68.0)
	b.add_theme_font_size_override("font_size", 28)
	_menu.add_child(b)
	return b

# `skill_word` names what this card's skill actually is - Shield, Shoot, Heal,
# Rally, Trick - because a button reading "Skill" makes the player translate.
func show_menu(skill_word: String) -> void:
	if _menu == null:
		return
	_skill_btn.text = skill_word
	_menu.visible = true

func hide_menu() -> void:
	if _menu != null:
		_menu.visible = false

func show_cancel() -> void:
	if _cancel_btn != null:
		_cancel_btn.visible = true

func hide_cancel() -> void:
	if _cancel_btn != null:
		_cancel_btn.visible = false

func _tree() -> SceneTree:
	return _board.get_tree()

# Called by the board at the top of every action, so each one can be skipped on
# its own rather than a single click silencing the rest of the match.
func begin_sequence() -> void:
	_skip = false
	_live.clear()

func skip() -> void:
	if not enabled:
		return
	_skip = true
	for t in _live:
		if t.is_valid():
			t.set_speed_scale(SKIP_SPEED)

# Every wait in this file goes through here, so there is one place that knows
# what a skip does to an animation already in flight.
func _finish(t: Tween) -> void:
	if _skip:
		t.set_speed_scale(SKIP_SPEED)
	_live.append(t)
	await t.finished
	_live.erase(t)

# ── Round card ────────────────────────────────────────────────────────────

# "ROUND 3" over "Red goes first", held for a moment and gone.
#
# Who leads used to be a second banner that stayed up for the whole face-off,
# and it sat across the top of a board the camera had just zoomed in on - so it
# covered the very cards it was announcing. It belongs here instead: the lead
# now ALTERNATES per round, which makes it round-level information, and this
# card is the one thing on screen that is already round-level and already
# leaves. The persistent copy lives in the HUD column, where no card can be.
func round_card(n: int, leader: String) -> void:
	if not enabled or _round_label == null:
		return
	_round_label.text = "ROUND %d\n%s goes first" % [n, leader]
	Sound.cue("round")
	if _skip:
		_round_label.modulate.a = 0.0
		return
	var t := _tree().create_tween()
	t.tween_property(_round_label, "modulate:a", 1.0, 0.25)
	t.tween_interval(ROUND_CARD_HOLD)
	t.tween_property(_round_label, "modulate:a", 0.0, 0.25)
	await _finish(t)

# ── The face-off ──────────────────────────────────────────────────────────

# Brings the two cards that face each other at this slot forward - the camera
# frames just them, so they fill the screen - and pushes everything else down.
#
# The camera does the "closer to the screen" half on its own: BoardCamera.fit()
# already zooms to whatever set of cards it is given, which is how a 2v2 endgame
# stays legible. Handing it two cards is the same mechanism asked a narrower
# question.
func faceoff(pair: Array, all_cards: Array) -> void:
	if not enabled:
		return
	_focus = []
	for c in pair:
		if c != null and is_instance_valid(c):
			_focus.append(c)
	_apply_dim(all_cards)
	if _camera != null and not _focus.is_empty():
		_camera.fit(_focus, true)
		# Give the camera its glide before handing back, or the first frame of
		# whatever happens next plays while the board is still sliding.
		if not _skip:
			await _tree().create_timer(FACEOFF_IN).timeout

# Back to the whole board: used whenever a targeting skill needs the player to
# see every lane again, and at the end of the pair's turn.
func widen(all_cards: Array) -> void:
	if not enabled:
		return
	_focus = []
	_apply_dim(all_cards)
	if _camera != null:
		_camera.fit(all_cards, true)

func _apply_dim(all_cards: Array) -> void:
	for c in all_cards:
		if c == null or not is_instance_valid(c):
			continue
		c.dim = 1.0 if (_focus.is_empty() or _focus.has(c)) else DIM

# ── Playing what happened ─────────────────────────────────────────────────

# Whether `viewer` is entitled to WATCH this cast land.
#
# The log had to learn this and so does the animation, for the same reason and
# separately: a caster rising behind a card gives the secret away exactly as a
# log line naming it does. A hidden status has two ways out and both are
# pictures of the same thing.
#
# So a cast is animated only for the side that already knows - the Ace's own
# side for a shield, the King's for a rally, and the JOKER's for a trick, which
# is the inverted one. Everyone else sees nothing until the reveal, which is
# where the ghost properly belongs and is never gated.
static func cast_is_visible(e: Dictionary, state: FUState, viewer: int, target_id: int) -> bool:
	var c := state.card_by_id(target_id)
	if c == null:
		return false
	match str(e.t):
		"shield": return state.sees_shield(viewer, c)
		"rally", "double_rally": return state.sees_rally(viewer, c)
		"trick": return state.sees_trick(viewer, c)
	return true

# Walks the event list and animates the parts of it that have a picture.
# `views` maps card id -> Card node; `state` resolves ids to cards.
#
# It deliberately animates a SUBSET. A rally expiring because its King moved is
# a real event and it belongs in the log, but a card for every bookkeeping step
# would turn one action into a slideshow.
func play(events: Array, views: Dictionary, state: FUState, viewer: int) -> void:
	if not enabled:
		return
	for e in events:
		match e.t:
			"hit":
				await _hit(e, views, state)
				_pop_hit(e, views)
			"death":
				Sound.cue("death")
			"game_over":
				Sound.cue("match_end")
			"heal":
				if int(e.amount) > 0:
					Sound.cue("heal")
					await _approach(e.actor, e.target, views)
					_pop(views, int(e.target), "+%d" % int(e.amount), HEAL_TINT)
			"shield":
				# The Ace steps out from behind the ally it is guarding - but
				# only where the shield itself is not a secret. The word rides
				# the SAME gate as the ghost, so there is one decision here and
				# not two that could drift apart.
				if cast_is_visible(e, state, viewer, int(e.target)):
					Sound.cue("shield")
					_pop(views, int(e.target), "SHIELDED", SHIELD_TINT)
					await _ghost(e.actor, e.target, views, SHIELD_TINT)
			"rally":
				if cast_is_visible(e, state, viewer, int(e.target)):
					Sound.cue("rally")
					_pop(views, int(e.target), "RALLIED", RALLY_TINT)
					await _ghost(e.actor, e.target, views, RALLY_TINT)
			"double_rally":
				for id in e.targets:
					if cast_is_visible(e, state, viewer, int(id)):
						Sound.cue("rally")
						_pop(views, int(id), "RALLIED", RALLY_TINT)
						await _ghost(e.actor, id, views, RALLY_TINT)
			"trick":
				# Visible when it is OUR trap being set; invisible when one is
				# being set on us, which is the whole of the mechanic.
				if cast_is_visible(e, state, viewer, int(e.target)):
					Sound.cue("trick")
					_pop(views, int(e.target), "TRICKED", TRICK_TINT)
					await _ghost(e.actor, e.target, views, TRICK_TINT)
			"reveal":
				# A hidden status coming out is the moment the caster is most
				# worth showing, because until now the other side had no idea it
				# was there. Never gated: the reveal IS the secret ending.
				Sound.cue("reveal")
				_pop(views, int(e.card), _reveal_word(str(e.what)), _reveal_tint(str(e.what)))
				await _reveal_caster(e, views, state)
			"trick_sprung":
				Sound.cue("trick_sprung")
				_pop(views, int(e.card), "TRICKED", TRICK_TINT)
				await _ghost(e.by, e.card, views, TRICK_TINT)
			"rally_breaks_trick":
				await _ghost(e.by, e.card, views, TRICK_TINT)

# What a blow actually cost, on the card that took it. Shield and HP are two
# separate numbers because they are two separate pools, and a hit that vanishes
# entirely into a shield would otherwise pop "-0".
func _pop_hit(e: Dictionary, views: Dictionary) -> void:
	if int(e.absorbed) > 0:
		_pop(views, int(e.target), "-%d" % int(e.absorbed), SHIELD_TINT,
			Vector2(-150.0, 0.0))
	if int(e.hp_lost) > 0:
		_pop(views, int(e.target), "-%d" % int(e.hp_lost), DAMAGE_TINT)

func _pop(views: Dictionary, card_id: int, text: String, tint: Color,
		offset: Vector2 = Vector2.ZERO) -> void:
	var node = views.get(card_id)
	if node != null and is_instance_valid(node):
		node.pop(text, tint, offset)

# A Jack's shoot travels; a plain attack leans in where it stands.
func _hit(e: Dictionary, views: Dictionary, state: FUState) -> void:
	if str(e.verb) == "shoots":
		Sound.cue("shoot")
		await _approach(e.actor, e.target, views)
	else:
		Sound.cue("attack")
		await _lunge(e.actor, e.target, views)

# The caster behind a status that has just gone public.
func _reveal_caster(e: Dictionary, views: Dictionary, state: FUState) -> void:
	var carrier := state.card_by_id(int(e.card))
	if carrier == null:
		return
	match str(e.what):
		"shield":
			await _ghost(carrier.shield_ace, carrier.id, views, SHIELD_TINT)
		"rally":
			await _ghost(carrier.rally_king, carrier.id, views, RALLY_TINT)
		"trick":
			await _ghost(carrier.trick_joker, carrier.id, views, TRICK_TINT)

static func _reveal_word(what: String) -> String:
	match what:
		"shield": return "SHIELDED"
		"rally": return "RALLIED"
	return "TRICKED"

static func _reveal_tint(what: String) -> Color:
	match what:
		"shield": return SHIELD_TINT
		"rally": return RALLY_TINT
	return TRICK_TINT

# ── The three moves ───────────────────────────────────────────────────────

# A lean toward the target and back: the whole of a plain attack.
func _lunge(actor_id: int, target_id: int, views: Dictionary) -> void:
	var a = views.get(actor_id)
	var b = views.get(target_id)
	if not _both_live(a, b):
		return
	if _skip:
		return
	var home: Vector2 = a.global_position
	var toward: Vector2 = (b.global_position - home).normalized() * LUNGE_DISTANCE
	var t := _tree().create_tween()
	t.tween_property(a, "global_position", home + toward, LUNGE_OUT) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	t.tween_property(a, "global_position", home, LUNGE_BACK) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await _finish(t)

# Travelling most of the way to something in another lane, and back. This is
# what a shoot and a heal look like: the card leaves its slot.
func _approach(actor_id: int, target_id: int, views: Dictionary) -> void:
	var a = views.get(actor_id)
	var b = views.get(target_id)
	if not _both_live(a, b):
		return
	if _skip:
		return
	var home: Vector2 = a.global_position
	var out: Vector2 = home.lerp(b.global_position, APPROACH_FRACTION)
	var t := _tree().create_tween()
	t.tween_property(a, "global_position", out, APPROACH) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(a, "global_position", home, APPROACH) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await _finish(t)

# A copy of the caster's face, rising behind the card it is acting on: the Ace
# that turns out to have been shielding, the King behind a rallied ally, the
# Joker behind the card whose trap has just gone off.
#
# It is a clone rather than the caster itself, because the caster is somewhere
# else on the board and is very often the card whose turn it currently is - and
# because a shield can be revealed by an Ace that has since died, whose node is
# already freed.
func _ghost(caster_id: int, target_id: int, views: Dictionary, tint: Color) -> void:
	if _skip:
		return
	var target = views.get(target_id)
	if target == null or not is_instance_valid(target):
		return
	var caster = views.get(caster_id)
	if caster == null or not is_instance_valid(caster):
		return
	var art: Texture2D = caster.art_texture()
	if art == null:
		return

	var ghost := Sprite2D.new()
	ghost.texture = art
	ghost.z_index = -1                       # behind the card it belongs to
	ghost.modulate = Color(tint.r, tint.g, tint.b, 0.0)
	ghost.scale = Vector2(0.8, 0.8)
	target.add_child(ghost)
	ghost.position = Vector2(0.0, -140.0)

	var t := _tree().create_tween()
	t.tween_property(ghost, "modulate:a", 0.9, GHOST_IN)
	t.parallel().tween_property(ghost, "position", Vector2(0.0, -300.0), GHOST_IN) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_interval(GHOST_HOLD)
	t.tween_property(ghost, "modulate:a", 0.0, GHOST_OUT)
	await _finish(t)
	if is_instance_valid(ghost):
		ghost.queue_free()

func _both_live(a, b) -> bool:
	return a != null and b != null and is_instance_valid(a) and is_instance_valid(b)
