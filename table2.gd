extends Node2D

# ─────────────────────────────────────────────
#  REMI SHOWDOWN — face-up board
#
#  PRESENTATION ONLY. This file renders an FUState, turns button presses into
#  action dictionaries, and writes the battle log from the events FURules hands
#  back. It decides nothing.
#
#  It used to be the whole mode: 948 lines holding the rules, the turn loop,
#  the AI and the node manipulation in one place, with card scenes applying
#  their own skills to each other. Nothing in it could run without a scene
#  tree, which is why face-up mode had no unit tests and could not be
#  networked. The rules are now in FURules, the AI in FUAI, and both are pure.
#
#  If a change here would alter what happens in a match rather than how it
#  looks, it belongs in FURules instead.
# ─────────────────────────────────────────────

var player_suit: int = FUState.BLACK

# The authoritative match. Everything on screen is derived from it.
var state: FUState = null

# card id -> the Card node drawing it.
var _views := {}

# Which target buttons are live, and what pressing each one submits.
# node -> action dictionary, ready to hand to FURules.resolve().
var _pending := {}

# An armed King picks two allies in two steps; this holds the first.
var _double_first: int = -1

# The presentation layer: the round card, the face-off framing, the animations.
# Clearing `animate` before _ready makes every one of its coroutines return
# without awaiting, which is how the headless tests run a match in no time -
# and it is the only difference between the tested board and the shipping one.
var animate: bool = true
var _stage: FUStage = null

# True while an animation is in flight. Every input handler returns early on it,
# so a second tap during a lunge cannot submit a second action.
var _busy: bool = false

# The round the banner last announced, so it goes up once per pass.
var _shown_round: int = 0

# The in-battle menu: audio settings, and the way out.
var _menu: GameMenu = null

# A beat before the AI moves, so its turn does not appear to happen in the same
# instant the player's did. It used to be a full second, which reads as thinking
# for the first few turns and as waiting for the rest of the match - and the
# animation that follows it is itself the pause that makes the move readable, so
# most of that second was dead air in front of a pause.
#
# bench and tests drive FURules directly and never see it.
const AI_DELAY: float = 0.25
var aiTimer: float = 0.0
var aiWaiting: bool = false

var rng := RandomNumberGenerator.new()

# What the HUD covers, so the camera fits the board into the rest of the screen
# rather than sliding cards under the log panel. Every control lives in one left
# column for this reason: an L-shaped HUD would have to be reserved as its
# bounding rectangle, and giving up the whole top strip for two short labels
# cost the board about a fifth of its height. Same convention as
# SafeArea.insets(): position is the top-left inset, size the bottom-right one.
const HUD_RESERVE := Rect2(Vector2(316.0, 0.0), Vector2(16.0, 0.0))

const MODE_SELECT_SCENE: String = "res://Scene/mode_select.tscn"

# The opening framing should already be correct on frame one; only the
# re-framings after a death are worth animating.
var _framed: bool = false

# The result line, published as state rather than left for a reader to scrape
# off a Label.
var winner_msg: String = ""

# ─── Log ─────────────────────────────────────
const LOG_MAX: int = 120                                        # entries kept before trimming
const LOG_PATH: String = "UI/Root/LogPanel/LogScroll/LogText"
const LOG_SCROLL_PATH: String = "UI/Root/LogPanel/LogScroll"
const LOG_HEADER: String = "[color=#57606a]— Battle log —[/color]"

# Owned by Scene/Shared/battle_log.gd, which both modes share.
var _battleLog: BattleLog = null

func _log(bbcode: String) -> void:
	if _battleLog != null:
		_battleLog.add(bbcode)

# ─── Lifecycle ───────────────────────────────

func _ready():
	SafeArea.bind($UI/Root)
	# The battle is what has a soundtrack; the menus are quiet.
	Audio.play_music()
	$Camera2D.reserve = HUD_RESERVE
	rng.randomize()
	player_suit = GameState.player_suit
	_battleLog = BattleLog.new(get_node(LOG_PATH), get_node(LOG_SCROLL_PATH), LOG_HEADER, LOG_MAX)

	state = FURules.new_match(player_suit, rng)
	_bind_views()

	_stage = FUStage.new()
	_stage.enabled = animate
	_stage.setup(self, $UI/Root, $Camera2D)
	_stage.attack_chosen.connect(func(): _on_attack(0))
	_stage.skill_chosen.connect(_on_skill)
	_stage.cancel_chosen.connect(_cancel_targeting)

	_menu = GameMenu.new()
	_menu.build($UI/Root)
	_menu.exit_requested.connect(_on_exit_requested)
	_menu.exit_confirmed.connect(_on_exit_confirmed)

	_render(FURules.start(state))

# Each card node draws exactly one FUCard, matched by suit and class. The board
# never looks a card up any other way, so a node is only ever a view.
func _bind_views() -> void:
	_views.clear()
	for node in $CardsBlack.get_children() + $CardsRed.get_children():
		if not node is Card:
			continue
		var c := state.find_by_name(node.suit, node.cardClassName)
		if c != null:
			_views[c.id] = node

func _process(delta: float):
	if aiWaiting:
		aiTimer -= delta
		if aiTimer <= 0.0:
			aiWaiting = false
			_ai_act()

# ─── Rendering ───────────────────────────────

# The one path from a resolved action to the screen, in the order a viewer needs
# it: say what happened, SHOW what happened, settle the board to its new state,
# then frame the next pair and hand back control.
#
# The animation goes before _sync_cards() on purpose. Syncing drops the HP bar
# and frees the dead, so playing afterwards would animate a card lunging at a
# gap where its target used to be.
func _render(events: Array) -> void:
	_busy = true
	_hide_all_buttons()
	if _stage != null:
		_stage.hide_menu()
		_stage.hide_cancel()
		# Each action is skippable on its own; one click does not silence the
		# rest of the match.
		_stage.begin_sequence()
	for i in range(events.size()):
		_log_event(events, i)

	if _stage != null:
		# Open the board back up first when the action reaches outside the pair.
		# The face-off frames two cards and only two: a Jack shooting slot 4, a
		# Queen healing down the row, or an Ace revealed on someone else would
		# otherwise animate off the edge of a screen zoomed in on somebody else
		# entirely. A plain attack stays in the tight framing, which is the
		# whole reason the framing exists.
		if _reaches_outside(events):
			_stage.widen(_living_views())
		await _stage.play(events, _views, state, player_suit)

	_sync_cards()
	_layout()
	_update_ui()

	if state.is_over():
		_busy = false
		return

	if _stage != null:
		if state.round_no != _shown_round:
			_shown_round = state.round_no
			await _stage.round_card(state.round_no, _first_name())
		await _stage.faceoff(_faceoff_pair(), _living_views())

	_busy = false
	_offer_turn()

# Whether anything in `events` happens to a card outside the two in the
# face-off, and so needs the whole board on screen to be legible.
func _reaches_outside(events: Array) -> bool:
	var pair := _faceoff_pair()
	for e in events:
		for key in ["target", "card"]:
			if not e.has(key):
				continue
			var node = _views.get(int(e[key]))
			if node != null and is_instance_valid(node) and not pair.has(node):
				return true
		if e.has("targets"):
			for id in e.targets:
				var n = _views.get(int(id))
				if n != null and is_instance_valid(n) and not pair.has(n):
					return true
	return false

# The two cards standing opposite each other at the slot now being resolved -
# one of them if the shorter row has run out.
func _faceoff_pair() -> Array:
	var out: Array = []
	for side in [FUState.BLACK, FUState.RED]:
		var c := state.card_at(side, state.current_slot)
		if c == null:
			continue
		var node = _views.get(c.id)
		if node != null and is_instance_valid(node):
			out.append(node)
	return out

func _living_views() -> Array:
	var out: Array = []
	for side in [FUState.BLACK, FUState.RED]:
		for c in state.living(side):
			var node = _views.get(c.id)
			if node != null and is_instance_valid(node):
				out.append(node)
	return out

func _first_name() -> String:
	return "Black" if state.first_suit == FUState.BLACK else "Red"

func _sync_cards() -> void:
	for c in state.cards:
		var node = _views.get(c.id)
		if node == null or not is_instance_valid(node):
			continue
		node.show_card(c,
			state.sees_shield(player_suit, c),
			state.sees_rally(player_suit, c),
			state.sees_trick(player_suit, c))
		_set_marker(node, c)
		if not c.alive:
			_views.erase(c.id)
			node.queue_free()

# Parks the caster of a status behind the card carrying it: the King behind a
# rallied ally, the Joker behind a trapped enemy.
#
# This is the THIRD place a hidden status can escape, after the log and the
# animation, and it is the least obvious of the three because nothing here is
# written in words - a Joker quietly appearing behind the player's own Jack
# would give the trap away as completely as a sentence saying so. It asks
# FUState.sees_* the same question they do.
#
# A rally dies with its King and a trap with its Joker, so a marker that is
# showing always has a living caster to draw; the guard is for the frame between
# a death and the next sync.
func _set_marker(node: Card, c: FUCard) -> void:
	var caster_id: int = FUCard.NONE
	var tint: Color = Color(1, 1, 1, 1)
	if c.rallied and state.sees_rally(player_suit, c):
		caster_id = c.rally_king
		tint = FUStage.RALLY_TINT
	elif c.tricked and state.sees_trick(player_suit, c):
		caster_id = c.trick_joker
		tint = FUStage.TRICK_TINT
	var caster = _views.get(caster_id)
	if caster == null or not is_instance_valid(caster):
		node.clear_marker()
		return
	node.set_marker(caster.art_texture(), tint)

func _layout() -> void:
	var spacing: int = 800
	var startX: float = $CardStartMarker.position.x
	var blackY: float = $CardStartMarker.position.y
	var redY: float = $CardStartMarker.position.y + 1000.0
	var on_board: Array = []
	for side in [FUState.BLACK, FUState.RED]:
		var y: float = blackY if side == FUState.BLACK else redY
		var row := state.living(side)
		for i in range(row.size()):
			var node = _views.get(row[i].id)
			if node == null or not is_instance_valid(node):
				continue
			node.global_position.x = startX + i * spacing
			node.global_position.y = y
			on_board.append(node)
	# The board shrinks as cards die, so the framing is recomputed here rather
	# than once at startup. The first call snaps; later ones glide.
	$Camera2D.fit(on_board, _framed)
	_framed = true

func _update_ui() -> void:
	$UI/Root/PlayerLabel.text = "You: " + ("Black" if player_suit == FUState.BLACK else "Red")
	if state.is_over():
		return
	# Who leads is on the round card too, but that one fades. This is the copy
	# that stays available, and it lives in the reserved HUD column where the
	# camera guarantees no card can ever be underneath it.
	$UI/Root/TurnLabel.text = "R%d · slot %d — %s acts (%s leads)" % [
		state.round_no, state.current_slot,
		"Black" if state.current_suit == FUState.BLACK else "Red", _first_name()]
	var actor := state.current_card()
	if actor != null:
		# The tag is gated on what the player may see. Printing it off
		# actor.tricked would tell them about their own trap, which is the one
		# thing the trick depends on them not knowing.
		var tag: String = " [TRICKED]" if state.trick_seen_by(player_suit, actor) else ""
		$UI/Root/StatusLabel.text = "%s %s (slot %d)%s" % [
			"Black" if actor.side == FUState.BLACK else "Red", actor.card_name,
			state.current_slot, tag]

# ─── The battle log ──────────────────────────

# True when the player is not entitled to see what happened to `card_id`.
# `what` is "shield", "rally" or "trick".
func _hidden(card_id: int, what: String) -> bool:
	var c := state.card_by_id(card_id)
	if c == null:
		return false
	match what:
		"shield": return not state.sees_shield(player_suit, c)
		"rally": return not state.sees_rally(player_suit, c)
		"trick": return not state.sees_trick(player_suit, c)
	return false

# The three skills whose EFFECT is hidden. A Jack shooting or a Queen healing
# changes a number on screen, so there is nothing to conceal about either.
func _is_hidden_skill(card_name: String) -> bool:
	return card_name in ["Ace", "King", "Joker"]

# Events are the only channel from the rules to the log. The card scenes used
# to emit their own lines from inside do_skill(), which meant a rule and its
# log line were one statement and neither could move without the other.
#
# The log REDACTS, and it has to: hiding a shield on the board while the log
# says "Red Ace shields Red Queen" would conceal nothing at all. Face-down
# learned this the hard way - its rally line used to append the target skill
# word and named a face-down card on sight.
#
# What a redacted line still says is that an action happened, and which card
# took it. That much the player watched with their own eyes; it is the TARGET
# and the EFFECT that stay secret, which is exactly the shape of the bluff.
func _log_event(events: Array, i: int) -> void:
	var e: Dictionary = events[i]
	match e.t:
		"match_start":
			_log("[color=#aaaaaa]⚔ Battle start — [b]%s[/b] goes first[/color]"
				% ("Black" if e.first == FUState.BLACK else "Red"))
		"turn":
			_log("[color=#8b949e]▸ slot %d —[/color] %s" % [e.slot, _name(e.card)])
		"shield_expired":
			# A shield nobody ever saw lapses in silence.
			if e.was_seen or not _hidden(e.card, "shield"):
				_log("%s's shield [color=#4fc3f7](%d)[/color] comes down — %s" % [
					_name(e.card), e.amount,
					"its Ace acted" if e.reason == "acted" else "its Ace is down"])
		"rally_expired":
			# A live rally is never public - it only ever becomes visible by
			# being spent - so an enemy one lapses in silence.
			var lapsed := state.card_by_id(e.card)
			if lapsed != null and lapsed.side == player_suit:
				_log("%s's [color=#ffd54f]rally[/color] lapses — %s" % [
					_name(e.card),
					"its King moved" if e.reason == "acted" else "its King is down"])
		"trick_lifted":
			# The delicate one. Saying "the trick on your Jack lifted" tells the
			# player there WAS a trick on their Jack - the trap, described in the
			# past tense, is still the trap given away. So a lift is reported
			# only when the trap had already sprung, or when it was the player's
			# own trap on an enemy.
			var freed := state.card_by_id(e.card)
			if e.was_seen or (freed != null and freed.side != player_suit):
				_log("%s's [color=#ce93d8]trap[/color] on %s lifts — %s" % [
					_name(e.by), _name(e.card),
					"the Joker moved" if e.reason == "acted" else "the Joker is down"])
		"reveal":
			match e.what:
				"shield":
					_log("%s is [color=#4fc3f7]shielded[/color] — the Ace was standing in front of it"
						% _name(e.card))
				"rally":
					_log("%s was [color=#ffd54f]rallied[/color] all along [color=#ffd54f]★[/color]"
						% _name(e.card))
		"trick_sprung":
			_log("%s reaches for its skill — [color=#ce93d8]tricked[/color], and the turn is gone ✦"
				% _name(e.card))
		"rally_breaks_trick":
			_log("%s was [color=#ce93d8]tricked[/color], but the [color=#ffd54f]rally[/color] breaks it — skill goes through"
				% _name(e.card))
		"skill":
			# An enemy skill whose effect is hidden is logged as the bare fact
			# that it happened: the card is named, the target is not.
			if _is_hidden_skill(e.name) and state.card_by_id(e.actor).side != player_suit:
				_log("%s uses [color=#8b949e]%s[/color]" % [
					_name(e.actor), FUCard.skill_word_for(e.name)])
			elif e.spread:
				# Only a rallied skill needs a header; a single-lane one is fully
				# described by the effect line that follows it.
				_log("%s [color=#ffd54f](rallied)[/color] %s slot %d and its neighbours" % [
					_name(e.actor), _spread_verb(e.name), e.slot])
		"hit":
			var msg: String = "%s %s %s" % [_name(e.actor), e.verb, _name(e.target)]
			if e.absorbed > 0:
				msg += " — [color=#4fc3f7]%d shielded[/color], [color=#ef5350]%d dmg[/color]" % [
					e.absorbed, e.hp_lost]
			else:
				msg += " — [color=#ef5350]%d dmg[/color]" % e.hp_lost
			# A death always follows the blow that caused it, so the KO stays on
			# the same line it used to be on.
			if i + 1 < events.size() and events[i + 1].t == "death" \
					and events[i + 1].card == e.target:
				msg += " [color=#ffd54f][b]☠ KO![/b][/color]"
			_log(msg)
		"shield":
			if not _hidden(e.target, "shield"):
				_log("%s shields %s — [color=#4fc3f7]+%d shield[/color]" % [
					_name(e.actor), _name(e.target), e.amount])
		"heal":
			_log("%s heals %s — [color=#81c784]+%d HP[/color]" % [
				_name(e.actor), _name(e.target), e.amount])
		"rally":
			if not _hidden(e.target, "rally"):
				_log("%s rallies %s [color=#ffd54f]★[/color]" % [_name(e.actor), _name(e.target)])
		"self_rally":
			# Arming is public: the King spends a whole visible turn on itself.
			_log("%s self-rallies — [color=#81c784]double rally ready[/color]" % _name(e.card))
		"double_rally":
			# This action emits no "skill" header, so the redacted line is here.
			if state.card_by_id(e.actor).side != player_suit:
				_log("%s uses [color=#8b949e]Rally[/color] on two allies" % _name(e.actor))
			else:
				var second: String = _name(e.targets[1]) if e.targets.size() > 1 \
					else "[color=#8b949e]nobody[/color]"
				_log("%s [color=#81c784]double rally[/color] → %s and %s [color=#ffd54f]★[/color]" % [
					_name(e.actor), _name(e.targets[0]), second])
		"trick":
			# Visible when it is OUR trap; silent when it is being set on us.
			if not _hidden(e.target, "trick"):
				_log("%s tricks %s [color=#ce93d8]✦[/color]" % [_name(e.actor), _name(e.target)])
		"whiff":
			_log("%s [color=#8b949e]swings at an empty lane[/color]" % _name(e.actor))
		"game_over":
			_game_over(FURules.winner_text(e.outcome))
	# rally_cleared and rally_consumed are deliberately silent: the first is
	# bookkeeping the player never chose, and the second is already announced by
	# the "(rallied)" header on the skill that spent it.

func _name(id: int) -> String:
	var c := state.card_by_id(id)
	return c.log_name() if c != null else "[color=#8b949e]someone[/color]"

func _spread_verb(card_name: String) -> String:
	match card_name:
		"Ace": return "shields"
		"Jack": return "volleys"
		"Queen": return "heals"
		"Joker": return "tricks"
	return "acts on"

# ─── Whose turn it is ────────────────────────

func _offer_turn() -> void:
	_hide_all_buttons()
	_pending.clear()
	_double_first = -1
	if state.is_over():
		return
	if _stage != null:
		_stage.hide_cancel()
	if state.current_suit == player_suit:
		var actor := state.current_card()
		if actor != null and _stage != null:
			# The Skill button is ALWAYS offered, and named for what it does.
			# It used to be hidden on a tricked card, which told the player
			# about the trap before they could walk into it - the button was the
			# tell. Pressing it on a tricked card is now a legal move that loses
			# the turn, and that is the mechanic.
			_stage.show_menu(actor.skill_word())
	else:
		aiTimer = AI_DELAY
		aiWaiting = true

func _submit(action: Dictionary) -> void:
	var res := FURules.resolve(state, action)
	if not res.ok:
		# The board should never build an illegal action; if it does, say so in
		# the log rather than silently doing nothing.
		_log("[color=#ef5350]refused: %s[/color]" % res.error)
		_offer_turn()
		return
	_render(res.events)

# ─── Player input ────────────────────────────

# Clicks that land on nothing.
#
# _unhandled_input is exactly the right hook and not merely a convenient one: a
# Control that was pressed consumes the event before it arrives here, so a
# card's target button and the action menu are already excluded, and "empty
# board" needs no geometry test. What reaches this is a click on scenery.
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	# While the menu or the volume sliders are up, the board is not listening.
	# A click that misses a button there is a click on a dimmed-out game, not an
	# instruction to skip an animation.
	if _menu != null and _menu.is_open():
		return
	if event.button_index == MOUSE_BUTTON_RIGHT:
		# Right-click backs out of a target choice, and does nothing else ever.
		# A right-click that quietly did something during the AI's turn would be
		# a way to lose a match by fidgeting.
		if not _busy and not _pending.is_empty():
			get_viewport().set_input_as_handled()
			_cancel_targeting()
	elif event.button_index == MOUSE_BUTTON_LEFT:
		# Left-click on nothing fast-forwards the animation in flight. The
		# damage numbers are not part of what gets skipped - see FUStage.skip().
		if _busy and _stage != null:
			get_viewport().set_input_as_handled()
			_stage.skip()

# Puts the target picker away and gives the turn back, UNSPENT.
#
# The board has to come back to the face-off framing it left: _on_skill widened
# it to show every lane, and returning without narrowing again would leave the
# player looking at the whole board with a menu that belongs to two cards.
func _cancel_targeting() -> void:
	if _busy or _pending.is_empty():
		return
	_busy = true
	_hide_all_buttons()
	_pending.clear()
	_double_first = -1
	if _stage != null:
		_stage.hide_cancel()
		_stage.begin_sequence()
		await _stage.faceoff(_faceoff_pair(), _living_views())
	_busy = false
	_offer_turn()

func _on_attack(_atk: int):
	if _busy or state.is_over() or state.current_suit != player_suit:
		return
	if _stage != null:
		_stage.hide_menu()
	var lanes: Array = []
	for a in FURules.legal_actions(state):
		if a.kind == "attack":
			lanes.append(a)
	if lanes.is_empty():
		return
	# An attack hits the lane it faces and has no target to choose, so it always
	# resolves on the press. The picker is reached only by a skill now.
	_submit(lanes[0])

func _on_skill():
	if _busy or state.is_over() or state.current_suit != player_suit:
		return
	var actor := state.current_card()
	if actor == null or not actor.may_attempt_skill():
		return
	# Every skill in this mode picks a target, so the board opens back up: the
	# player cannot choose a lane they cannot see.
	if _stage != null:
		_stage.hide_menu()
		_stage.widen(_living_views())

	if actor.card_name == "King" and actor.double_rally:
		$UI/Root/StatusLabel.text = "King: pick 1st rally target"
		var allies := state.allies_of(player_suit)
		for i in range(allies.size()):
			if allies[i].id != actor.id:
				_arm(allies[i].id, {"kind": "double_rally_pick", "target_slot": i})
		if _stage != null and not _pending.is_empty():
			_stage.show_cancel()
		return

	var pool := state.skill_pool(actor)
	for i in range(pool.size()):
		_arm(pool[i].id, {"kind": "skill", "target_slot": i})
	if _stage != null and not _pending.is_empty():
		_stage.show_cancel()

# Lights up one card's target button and records what pressing it submits,
# with what that press would do to it.
func _arm(card_id: int, action: Dictionary) -> void:
	var node = _views.get(card_id)
	if node == null or not is_instance_valid(node):
		return
	node.targetBtnVisible = true
	_pending[node] = action
	var c := state.card_by_id(card_id)
	if c != null:
		var pv := _preview_for(c)
		if pv[0] != "":
			node.show_preview(pv[0], pv[1])

# What the acting card's skill would do to `c`, as [text, colour].
#
# Priced against the shield the PLAYER HAS SEEN, not the real one:
# state.shield_seen_by() returns zero for a shield nobody has hit yet, so a
# preview over a hidden shield promises the full number and the blow then
# under-delivers. That is the hidden shield paying off, not the preview lying -
# quoting the true figure would make the preview a way to X-ray the board.
func _preview_for(c: FUCard) -> Array:
	var actor := state.current_card()
	if actor == null:
		return ["", Color.WHITE]
	match actor.card_name:
		"Jack":
			var seen: int = state.shield_seen_by(player_suit, c)
			var to_hp: int = min(max(0, actor.skill_value - seen), c.hp)
			return ["-%d" % to_hp, FUStage.DAMAGE_TINT]
		"Queen":
			return ["+%d" % min(actor.skill_value, c.max_hp - c.hp), FUStage.HEAL_TINT]
		"Ace":
			return ["+%d" % min(actor.skill_value, c.max_shield), FUStage.SHIELD_TINT]
		"King":
			return ["RALLY", FUStage.RALLY_TINT]
		"Joker":
			return ["TRICK", FUStage.TRICK_TINT]
	return ["", Color.WHITE]

func _on_target(card: Card):
	if _busy or not _pending.has(card):
		return
	var action: Dictionary = _pending[card]

	# An armed King picks two allies, in two steps.
	if action.kind == "double_rally_pick":
		if _double_first == -1:
			_double_first = action.target_slot
			_hide_all_buttons()
			_pending.clear()
			$UI/Root/StatusLabel.text = "King: pick 2nd rally target"
			var actor := state.current_card()
			var allies := state.allies_of(player_suit)
			for i in range(allies.size()):
				if allies[i].id != actor.id and i != _double_first:
					_arm(allies[i].id, {"kind": "double_rally_pick", "target_slot": i})
			return
		_hide_all_buttons()
		_submit({"kind": "double_rally", "target_slots": [_double_first, action.target_slot]})
		return

	_hide_all_buttons()
	# The chip going down: this press is what spends the turn.
	Audio.play_cue("commit")
	_submit(action)

# ─── Button Visibility ───────────────────────

func _hide_all_buttons():
	for node in _views.values():
		if is_instance_valid(node):
			node.battleBtnVisible = false
			node.targetBtnVisible = false
			node.clear_preview()

# ─── Navigation ──────────────────────────────

# The Menu button opens the MENU. It used to change scene on the spot: one tap
# on `< Menu` ended the match, with no confirmation and nothing to undo it, and
# the Android back gesture routed into the same call - which is easy to trigger
# by accident at the edge of a phone screen. Face-down had asked first for a
# long time; this side never did.
func _on_menu_btn_pressed() -> void:
	if _menu == null:
		get_tree().change_scene_to_file(MODE_SELECT_SCENE)
		return
	Audio.play_cue("click")
	_menu.toggle()

func _on_exit_requested() -> void:
	_menu.ask_confirm("Your progress in this match will be lost.")

func _on_exit_confirmed() -> void:
	get_tree().change_scene_to_file(MODE_SELECT_SCENE)

# Android's Back gesture, which would otherwise close the app outright.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_menu_btn_pressed()

# ─── Game over ───────────────────────────────

func _game_over(msg: String):
	winner_msg = msg
	$UI/Root/StatusLabel.text = msg
	$UI/Root/WinLabel.text = msg
	$UI/Root/WinLabel.visible = true
	_log("[color=#ffd54f][b]— %s —[/b][/color]" % msg)

# ─── AI ──────────────────────────────────────

# Every difficulty reads its move out of FUAI, which knows nothing about this
# scene. EASY plays the priority ladder; NORMAL and HARD both play the scorer,
# which is a real gap rather than an oversight - face-up has no second weight
# set and no blunder rate, so the two top tiers are the same opponent.
func _ai_act():
	if state.is_over() or state.current_suit == player_suit:
		return
	var action: Dictionary
	if GameState.difficulty == GameState.Difficulty.EASY:
		action = FUAI.choose_ladder(state)
	else:
		action = FUAI.choose(state)
	if action.is_empty():
		return
	_submit(action)

# ─── Signal Routing ──────────────────────────

func _on_black_ace_attack_pressed(atk: int):   _on_attack(atk)
func _on_black_jack_attack_pressed(atk: int):  _on_attack(atk)
func _on_black_queen_attack_pressed(atk: int): _on_attack(atk)
func _on_black_king_attack_pressed(atk: int):   _on_attack(atk)
func _on_black_joker_attack_pressed(atk: int):  _on_attack(atk)
func _on_red_ace_attack_pressed(atk: int):      _on_attack(atk)
func _on_red_jack_attack_pressed(atk: int):     _on_attack(atk)
func _on_red_queen_attack_pressed(atk: int):    _on_attack(atk)
func _on_red_king_attack_pressed(atk: int):     _on_attack(atk)
func _on_red_joker_attack_pressed(atk: int):    _on_attack(atk)

func _on_black_ace_skill_pressed():    _on_skill()
func _on_black_jack_skill_pressed():   _on_skill()
func _on_black_queen_skill_pressed():  _on_skill()
func _on_black_king_skill_pressed():   _on_skill()
func _on_black_joker_skill_pressed():  _on_skill()
func _on_red_ace_skill_pressed():      _on_skill()
func _on_red_jack_skill_pressed():     _on_skill()
func _on_red_queen_skill_pressed():    _on_skill()
func _on_red_king_skill_pressed():     _on_skill()
func _on_red_joker_skill_pressed():    _on_skill()

func _on_black_ace_target_pressed(card: Card):    _on_target(card)
func _on_black_jack_target_pressed(card: Card):   _on_target(card)
func _on_black_queen_target_pressed(card: Card):  _on_target(card)
func _on_black_king_target_pressed(card: Card):   _on_target(card)
func _on_black_joker_target_pressed(card: Card):  _on_target(card)
func _on_red_ace_target_pressed(card: Card):      _on_target(card)
func _on_red_jack_target_pressed(card: Card):     _on_target(card)
func _on_red_queen_target_pressed(card: Card):    _on_target(card)
func _on_red_king_target_pressed(card: Card):     _on_target(card)
func _on_red_joker_target_pressed(card: Card):    _on_target(card)
