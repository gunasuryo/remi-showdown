extends Node2D

# ─────────────────────────────────────────────
#  REMI SHOWDOWN — Face-down board (PLAN M2)
#
#  This file is PRESENTATION ONLY. Every rule lives in fd_rules.gd; the board
#  observes state, issues actions, and renders whatever comes back. If a rule
#  question can be answered here, it is in the wrong file.
#
#  Both phases live in this one scene rather than the two the plan sketched:
#  positioning happens every round, and splitting it out would mean marshalling
#  FDState through an autoload and rebuilding the match log on every round
#  transition. The rows and the log simply stay put and the phase swaps the
#  buttons under them.
# ─────────────────────────────────────────────

const CARD_VIEW: PackedScene = preload("res://Scene/FaceDown/fd_card_view.tscn")
const MODE_SELECT: String = "res://Scene/mode_select.tscn"
const LOBBY_SCENE: String = "res://Scene/lobby.tscn"

# Long enough to read the log line the AI just wrote (PRD §10).
const AI_DELAY: float = 0.7

const LOG_HEADER: String = "[color=#57606a]— Match log —[/color]"

# Pacing lives in FDRules.DAMAGE_SCALE, which new_match() already applies.
# It used to be re-declared here, which is how the board and the AI bench came
# to be running two different games.

const C_YOU: String = "#c8d0dc"
const C_FOE: String = "#ff8a80"

# Colour belongs to the SUIT, not to the role. The tags used to be hard-coded in
# the scene - player blue, enemy red - which was only ever right when the player
# happened to be Black. Online the server picks your seat, so half the time the
# board was telling a Red player they were the blue side.
#
# "Black" is drawn light: an actually-black label is unreadable on this
# background, so it reads as the cool/pale side against Red's warm one.
const C_SUIT_BLACK := Color(0.78, 0.85, 0.96)
const C_SUIT_RED := Color(0.94, 0.45, 0.42)

# Badge fills. Darker than the text colours so white-ish label text sits on them.
const C_BADGE_BLACK := Color(0.20, 0.30, 0.48)
const C_BADGE_RED := Color(0.52, 0.15, 0.15)
const C_BADGE_IDLE := Color(0.16, 0.17, 0.21)

func _suit_colour(side: int) -> Color:
	return C_SUIT_BLACK if side == FDState.BLACK else C_SUIT_RED

func _badge_fill(side: int) -> Color:
	return C_BADGE_BLACK if side == FDState.BLACK else C_BADGE_RED

# The match. Either FDLocalSession (AI, in-process) or FDRemoteSession (server).
# The board does not know or care which: it submits, and re-renders on `synced`.
var session: FDSession = null

# Mirrors of session.state / session.my_side, kept because the render code reads
# them on nearly every line and `session.state.` everywhere would be noise. They
# are refreshed on every sync and must never be written to by the board.
var state: FDState = null
var player_side: int = FDState.BLACK
var ai_side: int = FDState.RED

var rng := RandomNumberGenerator.new()
var blog: BattleLog = null

# The in-battle menu: audio settings, and the way out.
var _menu: GameMenu = null

# The board is rebuilt when the round or the board width changes. Tracked rather
# than driven by a round-start call, because in an online match nobody tells the
# client a round began - it just receives a snapshot that looks different.
var _shown_round: int = -1
var _shown_width: int = -1

# ── Positioning phase ────────────────────────
# The player's row is drafted here and only handed to the rules engine on Lock
# In, so a half-finished arrangement never reaches FDState.
var _draft: Array = []
var _swap_pick: int = -1

# ── Battle phase ─────────────────────────────
var _sel_id: int = FDCard.NONE
var _targeting: bool = false
# "attack" or "skill" - an attack now picks a lane too, so the board has to
# know which kind of target it is asking for.
var _targeting_kind: String = ""

var _enemy_views: Array = []
var _player_views: Array = []

# ─── Lifecycle ───────────────────────────────

func _ready() -> void:
	SafeArea.bind($UI/Root)
	# The battle is what has a soundtrack; the menus are quiet.
	Audio.play_music()
	_menu = GameMenu.new()
	_menu.build($UI/Root)
	_menu.exit_requested.connect(_on_exit_requested)
	rng.randomize()
	blog = BattleLog.new($UI/Root/LogPanel/LogScroll/LogText, $UI/Root/LogPanel/LogScroll, LOG_HEADER)

	session = FDRemoteSession.new() if GameState.opponent == GameState.Opponent.ONLINE 		else FDLocalSession.new()
	session.name = "Session"
	session.synced.connect(_on_synced)
	session.notice.connect(_say)
	session.finished.connect(_on_finished)
	if session is FDRemoteSession:
		session.room_ready.connect(_on_room_ready)
		session.connection_lost.connect(_on_connection_lost)
	add_child(session)

	_build_rosters()
	session.start()
	_adopt_state()
	_refresh()

# Everything the board draws comes from here. A local match calls it after each
# action; an online one calls it whenever the server says something changed.
func _on_synced(events: Array) -> void:
	var was_round: int = _shown_round
	_adopt_state()
	if state == null:
		_refresh()
		return

	if _shown_round != was_round and was_round != -1:
		blog.add("[color=#ffd54f]— Round %d — %s leads —[/color]"
			% [state.round_no, _side_name(state.leader)])

	_log_events(events)
	_play_feedback(events)
	_refresh()

# Picks up the session's state and re-lays the board if the round or the width
# moved. Also re-drafts, because a new round clears both rows.
func _adopt_state() -> void:
	state = session.state
	player_side = session.my_side
	ai_side = session.enemy_side()
	if state == null:
		return

	if state.round_no != _shown_round or state.board_size != _shown_width:
		_shown_round = state.round_no
		_shown_width = state.board_size
		_rebuild_rows()
		if _shown_round == 1 and blog != null:
			blog.add("[color=#aaaaaa]Face-down match — you play [b]%s[/b][/color]"
				% _side_name(player_side))

	# A round that is back in positioning needs a fresh draft, but only once:
	# re-drafting on every snapshot would throw away the arrangement the player
	# is in the middle of making.
	if state.phase == FDState.Phase.POSITIONING and not state.placed[player_side]:
		if _draft.size() != state.board_size:
			_sel_id = FDCard.NONE
			_targeting = false
			_targeting_kind = ""
			_swap_pick = -1
			_draft = FDRules.auto_place(state, player_side, rng)
	elif state.phase != FDState.Phase.POSITIONING:
		_draft = []

func _on_room_ready(code: String, side: int) -> void:
	blog.add("[color=#ffd54f]Room [b]%s[/b] — you play %s[/color]" % [code, _side_name(side)])
	# Seating changes what the header should say, and no snapshot arrives until
	# the second player turns up - so without this the board sat on "Connecting"
	# long after it had connected.
	_refresh()

func _on_connection_lost() -> void:
	_say(GameState.last_error if GameState.last_error != "" else "Connection lost.")
	await get_tree().create_timer(1.5).timeout
	get_tree().change_scene_to_file(LOBBY_SCENE)

# ─── Board layout ────────────────────────────

func _rebuild_rows() -> void:
	for row in [$UI/Root/EnemyRow, $UI/Root/PlayerRow]:
		for child in row.get_children():
			row.remove_child(child)
			child.queue_free()
	_enemy_views.clear()
	_player_views.clear()

	for i in range(state.board_size):
		var foe := CARD_VIEW.instantiate() as FDCardView
		foe.slot = i
		foe.pressed.connect(_on_enemy_slot_pressed)
		$UI/Root/EnemyRow.add_child(foe)
		_enemy_views.append(foe)

		var mine := CARD_VIEW.instantiate() as FDCardView
		mine.slot = i
		mine.pressed.connect(_on_player_slot_pressed)
		$UI/Root/PlayerRow.add_child(mine)
		_player_views.append(mine)

func _on_finished(w: int) -> void:
	var msg: String = "Draw"
	if w == player_side:
		msg = "You win!"
	elif w != 0 and w != 3:
		msg = "You lose"
	blog.add("[color=#ffd54f][b]— %s —[/b][/color]" % msg)
	$UI/Root/Over/V/Result.text = msg
	$UI/Root/Over/V/Sub.text = "Round %d · %s %d left · %s %d left" % [
		state.round_no,
		_side_name(player_side), state.living_count(player_side),
		_side_name(ai_side), state.living_count(ai_side),
	]
	$UI/Root/Over.visible = true
	_refresh()

# ─── Player input ────────────────────────────

func _on_player_slot_pressed(slot: int) -> void:
	if state.phase == FDState.Phase.POSITIONING:
		_swap(slot)
		return
	if not _my_turn():
		return

	if _targeting:
		var actor: FDCard = state.card_by_id(_sel_id)
		if actor != null and not FDRules.skill_targets_enemies(actor):
			_do_action("skill", slot)
		return

	var card: FDCard = state.card_at(player_side, slot)
	if card == null:
		return
	if not card.alive:
		_say("That slot holds one of your dead decoys.")
		return
	if state.has_acted(card):
		_say("%s has already acted this round." % card.card_name)
		return
	_sel_id = card.id
	_refresh()

func _on_enemy_slot_pressed(slot: int) -> void:
	if not _my_turn() or not _targeting:
		return
	var actor: FDCard = state.card_by_id(_sel_id)
	if actor == null:
		return
	if _targeting_kind == "attack":
		if slot in FDRules.attack_slots(state, state.slot_of(actor)):
			_do_action("attack", slot)
		else:
			_say("An attack only reaches its own lane or a neighbour.")
		return
	if FDRules.skill_targets_enemies(actor):
		_do_action("skill", slot)

# Tap two of your own slots to exchange them (PRD §10).
func _swap(slot: int) -> void:
	if state != null and state.placed[player_side]:
		_say("Locked in — waiting for your opponent.")
		return
	if _swap_pick == -1:
		_swap_pick = slot
	elif _swap_pick == slot:
		_swap_pick = -1
	else:
		var held = _draft[_swap_pick]
		_draft[_swap_pick] = _draft[slot]
		_draft[slot] = held
		_swap_pick = -1
	_refresh()

func _on_random_btn_pressed() -> void:
	if state == null or state.placed[player_side]:
		return
	_draft = FDRules.auto_place(state, player_side, rng)
	_swap_pick = -1
	_refresh()

func _on_lock_btn_pressed() -> void:
	if state == null or state.phase != FDState.Phase.POSITIONING:
		return
	if state.placed[player_side]:
		_say("Already locked in — waiting for your opponent.")
		return
	session.submit_placement(_draft)

func _on_attack_btn_pressed() -> void:
	var card: FDCard = state.card_by_id(_sel_id)
	if card == null:
		return
	# With a one-slot board there is nothing to choose, so skip the extra tap.
	var lanes: Array = FDRules.attack_slots(state, state.slot_of(card))
	if lanes.size() <= 1:
		_do_action("attack", state.slot_of(card))
		return
	_targeting = true
	_targeting_kind = "attack"
	_refresh()

func _on_skill_btn_pressed() -> void:
	var card: FDCard = state.card_by_id(_sel_id)
	if card == null:
		return
	if not card.can_use_skill():
		_say("%s is tricked — it can only attack." % card.card_name)
		return
	_targeting = true
	_targeting_kind = "skill"
	_refresh()

func _on_cancel_btn_pressed() -> void:
	_sel_id = FDCard.NONE
	_targeting = false
	_targeting_kind = ""
	_refresh()

# Android's Back gesture. It unwinds the same way Cancel and Close do rather
# than leaving the match outright, because the OS gesture is easy to trigger by
# accident at the edge of the screen and losing a round to it would be galling.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	# Unwind one layer at a time: an open panel closes, then targeting cancels,
	# and only a Back with nothing left to dismiss offers to leave.
	if $UI/Root/Confirm.visible:
		_on_stay_btn_pressed()
	elif $UI/Root/RulesPanel.visible:
		_on_close_rules_btn_pressed()
	elif _targeting:
		_on_cancel_btn_pressed()
	else:
		_on_menu_btn_pressed()

func _on_rules_btn_pressed() -> void:
	var showing: bool = not $UI/Root/RulesPanel.visible
	$UI/Root/RulesPanel.visible = showing
	Audio.play_cue("book_open" if showing else "book_close")

func _on_close_rules_btn_pressed() -> void:
	$UI/Root/RulesPanel.visible = false
	Audio.play_cue("book_close")

# Leaving is one tap from the board and cannot be undone - online it abandons a
# live match on someone else's screen - so it asks first. The Android Back
# gesture routes here too, and that one is easy to trigger by accident at the
# edge of a phone screen.
func _on_menu_btn_pressed() -> void:
	if state != null and state.phase == FDState.Phase.GAME_OVER:
		_leave_now()
		return
	# Opens the menu rather than the confirm. Leaving is still one of the things
	# in it, and still asks - see _on_exit_requested, which hands the asking to
	# this board's own panel because its wording knows about online matches.
	if _menu == null:
		_show_confirm()
		return
	Audio.play_cue("click")
	_menu.toggle()

func _on_exit_requested() -> void:
	_menu.hide_panel()
	_show_confirm()

func _show_confirm() -> void:
	var body: String = "Your progress in this match will be lost."
	if GameState.opponent == GameState.Opponent.ONLINE:
		body = "Your opponent is still in this room. Leaving abandons the match for both of you."
	$UI/Root/Confirm/M/V/Body.text = body
	$UI/Root/Confirm.visible = true

func _on_stay_btn_pressed() -> void:
	$UI/Root/Confirm.visible = false

func _on_leave_btn_pressed() -> void:
	_leave_now()

func _leave_now() -> void:
	if session != null:
		session.leave()
	get_tree().change_scene_to_file(MODE_SELECT)

func _on_again_btn_pressed() -> void:
	if GameState.opponent == GameState.Opponent.ONLINE:
		# The finished room is gone on the server; a rematch means a new one.
		if session != null:
			session.leave()
		GameState.room_code = ""
		GameState.seat_token = ""
		get_tree().change_scene_to_file(LOBBY_SCENE)
		return
	get_tree().reload_current_scene()

func _do_action(kind: String, target_slot: int) -> void:
	var acting: int = _sel_id
	# Cleared before submitting, not after: online the answer comes back a round
	# trip later, and leaving the card selected invites a second tap that the
	# server would only reject.
	_sel_id = FDCard.NONE
	_targeting = false
	_targeting_kind = ""
	_refresh()
	session.submit_action(acting, kind, target_slot)

func _my_turn() -> bool:
	return session != null and session.is_my_turn()

# ─── Rendering ───────────────────────────────

func _refresh() -> void:
	$UI/Root/SubHint.text = ""
	if state == null:
		# The room code is the whole interaction at this point - it is what the
		# player reads out to their friend - so it goes in the header, not the
		# log where it scrolls away.
		$UI/Root/Status.text = session.waiting_text() if session != null else "Loading…"
		$UI/Root/Hint.text = "Tell your friend the code, then wait here."
		$UI/Root/EnemyTag.text = ""
		$UI/Root/PlayerTag.text = ""
		_disable_actions()
		return
	_refresh_rows()
	_refresh_rosters()
	_refresh_status()
	_refresh_buttons()

func _refresh_rows() -> void:
	var positioning: bool = state.phase == FDState.Phase.POSITIONING
	var selected: FDCard = state.card_by_id(_sel_id)
	var sel_slot: int = state.slot_of(selected) if selected != null else -1
	var aim_at_enemies: bool = _targeting and selected != null and (
		_targeting_kind == "attack" or FDRules.skill_targets_enemies(selected))
	var reachable: Array = []
	if _targeting and _targeting_kind == "attack" and selected != null:
		reachable = FDRules.attack_slots(state, state.slot_of(selected))
	# What each lane would actually take from the action being aimed. Computed
	# from the same numbers the rules use, so the preview cannot promise damage
	# the resolve step will not deliver.
	var preview: Dictionary = _preview_damage(selected, reachable)

	for i in range(_player_views.size()):
		var card: FDCard = null
		if positioning:
			if i < _draft.size():
				card = state.card_by_id(_draft[i])
		else:
			card = state.card_at(player_side, i)
		var d: Dictionary = _own_view(card, i)
		d["selected"] = (_swap_pick == i) if positioning else (sel_slot == i)
		d["targetable"] = _targeting and not aim_at_enemies
		_player_views[i].render(d)

	for i in range(_enemy_views.size()):
		# Straight from observe(): the board cannot leak what the rules say is
		# hidden, because it is never handed anything else.
		var d: Dictionary = state.observe(player_side, i).duplicate()
		d["side"] = ai_side
		d["own"] = false
		d["acted"] = false
		d["selected"] = false
		d["targetable"] = _targeting and aim_at_enemies and (
			reachable.is_empty() or i in reachable)
		if d["targetable"] and preview.has(i):
			d["preview"] = str(preview[i])
		_enemy_views[i].render(d)

# slot -> damage, for whichever action is currently being aimed at the enemy
# row. Empty when we are not aiming at enemies.
func _preview_damage(actor: FDCard, reachable: Array) -> Dictionary:
	var out := {}
	if actor == null or not _targeting:
		return out
	if _targeting_kind == "attack":
		var slot: int = state.slot_of(actor)
		for lane in reachable:
			var dmg: int = FDRules.scaled(state, actor.attack_value())
			if lane != slot:
				dmg = max(1, int(round(dmg * CardStats.ADJACENT_MULT)))
			out[lane] = dmg
		return out
	# Jack is the only skill that puts a number on the enemy row; a trick has
	# no damage to preview.
	if actor.card_name == "Jack":
		# The preview must quote what the rules will actually deliver: a rallied
		# shot is half per lane, so a rallied Jack previews 10s, not 20s.
		var spread: int = FDRules.Spread.THREE if actor.has_rally() else FDRules.Spread.SINGLE
		var shot: int = FDRules.scaled(state,
			FDRules.skill_output(actor.card_name, actor.skill_value, spread))
		for lane in range(state.board_size):
			out[lane] = shot
	return out

func _own_view(card: FDCard, slot: int) -> Dictionary:
	if card == null:
		return {"slot": slot, "side": player_side, "own": true, "known": true, "empty": true, "acted": false, "exposed": false}
	return {
		"slot": slot, "side": player_side, "own": true, "known": true, "empty": false,
		"card_name": card.card_name, "alive": card.alive,
		"hp": card.hp, "max_hp": card.max_hp,
		"shield": card.shield,
		"rally": card.rally_label(), "tricked": card.nullified,
		"acted": state.phase == FDState.Phase.BATTLE and state.has_acted(card),
		"exposed": state.is_revealed(player_side, slot),
	}

func _refresh_status() -> void:
	var phase_text: String = "Game over"
	match state.phase:
		FDState.Phase.POSITIONING:
			phase_text = "Positioning"
		FDState.Phase.BATTLE:
			phase_text = "Your turn" if _my_turn() else "Enemy turn"
	$UI/Root/EnemyTag.add_theme_color_override("font_color", _suit_colour(ai_side))
	$UI/Root/PlayerTag.add_theme_color_override("font_color", _suit_colour(player_side))
	_refresh_badges()
	$UI/Root/EnemyTag.text = "%s — ENEMY  ·  %d of %d left" % [
		_side_name(ai_side).to_upper(), state.living_count(ai_side), CardStats.ORDER.size()]
	$UI/Root/PlayerTag.text = "%s — YOU  ·  %d of %d left" % [
		_side_name(player_side).to_upper(), state.living_count(player_side), CardStats.ORDER.size()]

	var status: String = "Round %d  ·  %s leads  ·  %d slots  ·  %s" % [
		state.round_no, _side_name(state.leader), state.board_size, phase_text,
	]
	# Nothing on the board said how close the round was to turning over.
	if state.phase == FDState.Phase.BATTLE:
		var mine_left: int = state.unacted(player_side).size()
		var foe_left: int = state.unacted(ai_side).size()
		status += "  ·  [you %d / enemy %d still to act]" % [mine_left, foe_left]
	# The room code stays on screen for the whole match, not just while waiting.
	# It is what a player reads out if their friend has to rejoin, and it used to
	# vanish the moment the match started.
	if session is FDRemoteSession and session.code != "":
		status += "   ·   room %s" % session.code
	$UI/Root/Status.text = status

	if state.phase == FDState.Phase.POSITIONING:
		$UI/Root/Hint.text = "Tap two of your slots to swap them. Your dead cards sit in the row as decoys — the enemy cannot tell them from the living."
	elif state.phase != FDState.Phase.BATTLE:
		$UI/Root/Hint.text = ""
	elif session != null and session.is_waiting():
		$UI/Root/Hint.text = session.waiting_text()
	elif _targeting:
		var actor: FDCard = state.card_by_id(_sel_id)
		if _targeting_kind == "attack":
			$UI/Root/Hint.text = "Attack — your own lane hits full, either neighbour hits for half."
		else:
			var row: String = "enemy" if (actor != null and FDRules.skill_targets_enemies(actor)) else "your"
			$UI/Root/Hint.text = "%s — pick a slot in the %s row." % [_skill_name(actor), row]
	elif _sel_id == FDCard.NONE:
		$UI/Root/Hint.text = "Tap one of your un-acted cards."
	else:
		var actor2: FDCard = state.card_by_id(_sel_id)
		var tricked: String = "  [color=#ca82d9](tricked: no skill, half damage)[/color]" if actor2.nullified else ""
		$UI/Root/Hint.text = "%s selected — Attack reaches slot %d or a neighbour, or use %s.%s" % [
			actor2.card_name, state.slot_of(actor2) + 1, _skill_name(actor2), tricked,
		]

# Nothing is playable until there is a match; without this the action buttons
# kept whatever state the scene shipped with and looked pressable while the
# board was still waiting for an opponent.
func _disable_actions() -> void:
	for n in ["RandomBtn", "LockBtn", "AttackBtn", "SkillBtn", "CancelBtn"]:
		var b: Button = $UI/Root/Actions.get_node_or_null(n)
		if b != null:
			b.disabled = true
			b.visible = n in ["AttackBtn", "SkillBtn", "CancelBtn"]

func _refresh_buttons() -> void:
	var positioning: bool = state.phase == FDState.Phase.POSITIONING
	var mine: bool = _my_turn()
	var selected: FDCard = state.card_by_id(_sel_id)

	# Both of these must set `disabled` explicitly, not just `visible`.
	# _disable_actions() turns every action button off while the board waits for
	# an opponent, and setting only `visible` here left Randomize and Lock In
	# visible but permanently dead - the two buttons the positioning phase is
	# made of. It never showed up in a local match, because there `state` is
	# available immediately and the waiting path never runs.
	var locked_in: bool = positioning and state.placed.get(player_side, false)
	$UI/Root/Actions/RandomBtn.visible = positioning
	$UI/Root/Actions/RandomBtn.disabled = not positioning or locked_in
	$UI/Root/Actions/LockBtn.visible = positioning
	$UI/Root/Actions/LockBtn.disabled = not positioning or locked_in
	$UI/Root/Actions/AttackBtn.visible = not positioning
	$UI/Root/Actions/SkillBtn.visible = not positioning
	$UI/Root/Actions/CancelBtn.visible = not positioning

	$UI/Root/Actions/AttackBtn.disabled = not (mine and selected != null and not _targeting)
	$UI/Root/Actions/SkillBtn.disabled = not (mine and selected != null and selected.can_use_skill() and not _targeting)
	$UI/Root/Actions/CancelBtn.disabled = not (mine and (selected != null or _targeting))

	# "Skill" is not a word the player has to translate: the button says Shield,
	# Shoot, Heal, Rally or Trick, and gains a "+" while the card is rallied and
	# the skill will cover three lanes.
	$UI/Root/Actions/SkillBtn.text = _skill_name(selected)

func _say(msg: String) -> void:
	$UI/Root/SubHint.text = msg

# --- Roster tracker -------------------------
#
# Which of the five cards each side still has. This leaks nothing hidden: an
# enemy card can only ever be damaged by YOU, and both _do_attack and Jack's
# shoot reveal a slot BEFORE they hit it, so every enemy death happens on a
# slot you were already looking at. The tracker only saves you scrolling the
# log to remember what you already saw.
#
# It deliberately says nothing about WHERE a living card is - that is the part
# you are supposed to be guessing at.

const ROSTER_FONT_SIZE: int = 12
const C_ROSTER_DEAD_BG := Color(0.10, 0.10, 0.12)
const C_ROSTER_DEAD_FG := Color(0.42, 0.45, 0.50)
const C_ROSTER_YOU_BG := Color(0.16, 0.20, 0.30)
const C_ROSTER_YOU_FG := Color(0.72, 0.82, 0.98)
const C_ROSTER_FOE_BG := Color(0.28, 0.12, 0.15)
const C_ROSTER_FOE_FG := Color(1.0, 0.62, 0.58)

# One StyleBoxFlat per badge. A stylebox declared in the scene is a single
# shared resource, so recolouring one badge would recolour both.
func _badge_style(node: PanelContainer) -> StyleBoxFlat:
	var sb: StyleBoxFlat = node.get_theme_stylebox("panel") as StyleBoxFlat
	if sb == null or not sb.has_meta("own"):
		sb = StyleBoxFlat.new()
		sb.set_corner_radius_all(5)
		sb.content_margin_left = 10.0
		sb.content_margin_right = 10.0
		sb.content_margin_top = 2.0
		sb.content_margin_bottom = 2.0
		sb.set_meta("own", true)
		node.add_theme_stylebox_override("panel", sb)
	return sb

# Which suit is on the clock, shown on the row of whoever it is. The badge is
# filled with that suit's colour; the other side's is blank.
func _refresh_badges() -> void:
	var battle: bool = state.phase == FDState.Phase.BATTLE
	var acting: int = state.side_to_act
	for spec in [[$UI/Root/TurnBadge, player_side, true], [$UI/Root/EnemyBadge, ai_side, false]]:
		var node: PanelContainer = spec[0]
		var side: int = spec[1]
		var own: bool = spec[2]
		var label: Label = node.get_node("L")
		var lit: bool = battle and acting == side
		var sb := _badge_style(node)
		sb.bg_color = _badge_fill(side) if lit else C_BADGE_IDLE
		node.visible = lit
		label.text = ("YOUR TURN!" if own else "THEIR TURN") if lit else ""
		label.add_theme_color_override("font_color", Color(1, 1, 1))

func _build_rosters() -> void:
	for row in [$UI/Root/EnemyRoster, $UI/Root/PlayerRoster]:
		for child in row.get_children():
			row.remove_child(child)
			child.queue_free()
		for card_name in CardStats.ORDER:
			row.add_child(_make_chip(card_name))

func _make_chip(card_name: String) -> PanelContainer:
	var chip := PanelContainer.new()
	# Per instance, so one card dying does not restyle the whole roster.
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 7.0
	sb.content_margin_right = 7.0
	sb.content_margin_top = 2.0
	sb.content_margin_bottom = 2.0
	chip.add_theme_stylebox_override("panel", sb)

	# RichTextLabel rather than Label purely so a dead card can be struck
	# through; a 50% fade alone did not read as "this one is gone".
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.add_theme_font_size_override("normal_font_size", ROSTER_FONT_SIZE)
	label.text = card_name
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(label)
	return chip

func _refresh_rosters() -> void:
	_paint_roster($UI/Root/PlayerRoster, player_side, true)
	_paint_roster($UI/Root/EnemyRoster, ai_side, false)

func _paint_roster(row: HBoxContainer, side: int, own: bool) -> void:
	for i in range(row.get_child_count()):
		if i >= CardStats.ORDER.size():
			break
		var chip: PanelContainer = row.get_child(i)
		var label: RichTextLabel = chip.get_child(0)
		var card: FDCard = state.find_by_name(side, CardStats.ORDER[i])
		var alive: bool = card != null and card.alive

		var sb: StyleBoxFlat = chip.get_theme_stylebox("panel")
		if alive:
			sb.bg_color = C_ROSTER_YOU_BG if own else C_ROSTER_FOE_BG
			label.add_theme_color_override("default_color", C_ROSTER_YOU_FG if own else C_ROSTER_FOE_FG)
			label.text = CardStats.ORDER[i]
		else:
			sb.bg_color = C_ROSTER_DEAD_BG
			label.add_theme_color_override("default_color", C_ROSTER_DEAD_FG)
			label.text = "[s]%s[/s]" % CardStats.ORDER[i]
		chip.modulate = Color(1, 1, 1, 1) if alive else Color(1, 1, 1, 0.5)

# ─── Log ─────────────────────────────────────

# Colours for the numbers that float off a card. Damage reads red, healing
# green, shield blue - the same language the log already uses.
const C_POP_HIT := Color(1.0, 0.42, 0.38)
const C_POP_ABSORB := Color(0.45, 0.78, 1.0)
const C_POP_HEAL := Color(0.52, 0.85, 0.55)
const C_POP_SHIELD := Color(0.45, 0.78, 1.0)
const C_FLASH_HIT := Color(1.0, 0.25, 0.2, 0.5)
const C_FLASH_GOOD := Color(0.4, 1.0, 0.5, 0.35)

# The board used to render only state, so a hit was a silent jump in a health
# bar and everything you learned came from reading the log. This replays the
# same event stream as a burst of numbers over the cards involved.
func _play_feedback(events: Array) -> void:
	for ev in events:
		match ev.get("t", ""):
			"hit":
				var v: FDCardView = _view_of(int(ev.target))
				if v == null:
					continue
				if int(ev.hp_lost) > 0:
					v.pop("-%d" % int(ev.hp_lost), C_POP_HIT)
					v.flash(C_FLASH_HIT)
				elif int(ev.absorbed) > 0:
					v.pop("-%d" % int(ev.absorbed), C_POP_ABSORB)
			"heal":
				var vh: FDCardView = _view_of(int(ev.target))
				if vh != null:
					vh.pop("+%d" % int(ev.amount), C_POP_HEAL)
					vh.flash(C_FLASH_GOOD)
			"shield":
				var vs: FDCardView = _view_of(int(ev.target))
				if vs != null:
					vs.pop("+%d" % int(ev.amount), C_POP_SHIELD)

# The view standing over a card right now, or null when that card is not on
# the board or is hidden inside the enemy row.
func _view_of(card_id: int) -> FDCardView:
	var c: FDCard = state.card_by_id(card_id)
	if c == null:
		return null
	var slot: int = state.slot_of(c)
	if slot == -1:
		return null
	var row: Array = _player_views if c.side == player_side else _enemy_views
	if slot >= row.size():
		return null
	return row[slot]

func _log_events(events: Array) -> void:
	for ev in events:
		var line: String = _describe(ev)
		if line != "":
			blog.add(line)

# One line per observable effect. Reveal events are deliberately silent: the
# board already shows them, and a line per reveal doubles the log for nothing.
func _describe(ev: Dictionary) -> String:
	match ev.t:
		"hit":
			var soak: String = ""
			if ev.absorbed > 0:
				soak = " [color=#4fc3f7](%d absorbed)[/color]" % ev.absorbed
			return "%s %s %s for [color=#ef5350]%d[/color]%s" % [
				_nm(ev.actor), ev.verb, _nm(ev.target), ev.damage, soak,
			]
		"death":
			return "%s [color=#ef5350]is destroyed[/color]" % _nm(ev.card)
		"heal":
			return "%s heals %s [color=#81c784](+%d)[/color]" % [_nm(ev.actor), _nm(ev.target), ev.amount]
		"shield":
			return "%s shields %s [color=#4fc3f7](+%d)[/color]" % [_nm(ev.actor), _nm(ev.target), ev.amount]
		"skill":
			var reach: String = ""
			if ev.spread == FDRules.Spread.THREE:
				reach = " [color=#ffd54f](3 lanes)[/color]"
			return "[color=#8b949e]▸[/color] %s uses [b]%s[/b] on slot %d%s" % [
				_nm(ev.actor), _skill_word(ev.name), int(ev.slot) + 1, reach,
			]
		"rally":
			var kind: String = "rally+" if ev.upgraded else "rally"
			# The skill word is only appended when the target is already
			# revealed. _nm() redacts, but this suffix used to resolve the name
			# directly and announce "(SHOOT+)" for a face-down card - which
			# would tell the enemy exactly which card was rallied, and make a
			# bluff on a corpse transparent the moment they read the log.
			var suffix := ""
			if _is_revealed_card(ev.target):
				suffix = " [color=#8b949e](%s+)[/color]" % FDCard.skill_word_for(
					_card_name_of(ev.target)).to_upper()
			return "%s grants [color=#ffd54f]%s[/color] to %s%s" % [
				_nm(ev.actor), kind, _nm(ev.target), suffix]
		"king_plus_armed":
			return "%s arms [color=#ffd54f]rally+[/color]" % _nm(ev.card)
		"whiff":
			return "[color=#8b949e]%s finds nothing in slot %d[/color]" % [_nm(ev.actor), int(ev.slot) + 1]
		"shield_expired":
			return "[color=#8b949e]%s's shield fades — its Ace acted again[/color]" % _nm(ev.card)
		"shield_lost":
			return "%s's shield [color=#ef5350]collapses[/color] — the Ace holding it is gone" % _nm(ev.card)
		"rally_expired":
			return "[color=#8b949e]%s's rally lapses — its King acted again[/color]" % _nm(ev.card)
		"rally_consumed":
			return "[color=#8b949e]%s spends its rally[/color]" % _nm(ev.card)
		"last_rally":
			return "%s holds a [color=#ffd54f]last rally[/color] — its King is gone" % _nm(ev.card)
		"nullify":
			return "%s [color=#ba68c8]tricks[/color] %s — skill sealed" % [_nm(ev.actor), _nm(ev.target)]
		"nullify_lifted":
			return "[color=#8b949e]%s shakes off the trick[/color]" % _nm(ev.card)
		"nullify_cleared_by_king":
			return "%s [color=#81c784]frees[/color] %s from the trick" % [_nm(ev.by), _nm(ev.card)]
		"trick_downgrade":
			return "%s strips %s's rally+ down to a rally" % [_nm(ev.actor), _nm(ev.target)]
		"trick_strip_rally":
			return "%s tears the rally off %s" % [_nm(ev.actor), _nm(ev.target)]
		"decoy_hit":
			return "%s hits a [color=#8b949e]DEAD DECOY[/color] in slot %d — wasted" % [_nm(ev.actor), int(ev.slot) + 1]
		"whiff":
			return "[color=#8b949e]%s finds nothing in slot %d[/color]" % [_nm(ev.actor), int(ev.slot) + 1]
	return ""

# Naming a card in the log has to respect hidden information: an enemy healed
# or rallied by its own side was never revealed, and printing its name here
# would leak what the board correctly hides.
func _nm(id: int) -> String:
	# An id the server withheld (FDCard.HIDDEN) reads the same as a card we can
	# see but cannot identify - the log must not distinguish them.
	if id == FDCard.HIDDEN:
		return "[color=%s]a face-down card[/color]" % C_FOE
	var card: FDCard = state.card_by_id(id)
	if card == null:
		return "?"
	if card.side == player_side:
		return "[color=%s]%s[/color]" % [C_YOU, card.card_name]
	var slot: int = state.slot_of(card)
	if slot == -1 or not state.is_revealed(card.side, slot):
		return "[color=%s]a face-down card[/color]" % C_FOE
	return "[color=%s]enemy %s[/color]" % [C_FOE, card.card_name]

func _skill_word(card_name: String) -> String:
	return FDCard.skill_word_for(card_name)

# What to call this card's skill on a button or in a hint: its own word, plus
# a "+" while a rally is making it cover three lanes. One helper so the button,
# the hint and the card itself can never disagree about the name.
func _skill_name(card: FDCard) -> String:
	if card == null:
		return "Skill"
	return card.skill_word() + ("+" if card.has_rally() else "")

# True when the viewer is entitled to know which card this is: their own, or an
# enemy standing in a slot they have revealed.
func _is_revealed_card(id: int) -> bool:
	var c: FDCard = state.card_by_id(id)
	if c == null:
		return false
	if c.side == player_side:
		return true
	var slot: int = state.slot_of(c)
	return slot != -1 and state.is_revealed(c.side, slot)

func _card_name_of(id: int) -> String:
	var c: FDCard = state.card_by_id(id)
	return c.card_name if c != null else ""

func _side_name(side: int) -> String:
	return "Black" if side == FDState.BLACK else "Red"
