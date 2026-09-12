extends Node2D

# Game mode and opponent picker. Sits between suit_select and the board
# scenes (PLAN §3 flow: suit_select → mode_select → table_2 | fd_table).
#
# The difficulty chosen here applies to BOTH modes - each board reads
# GameState.difficulty when it picks the opponent's brain.

const FACE_UP_SCENE: String = "res://Scene/Table/table_2.tscn"
const FACE_DOWN_SCENE: String = "res://Scene/FaceDown/fd_table.tscn"
const SUIT_SELECT_SCENE: String = "res://Scene/suit_select.tscn"
const LOBBY_SCENE: String = "res://Scene/lobby.tscn"
const SUIT_SCENE: String = "res://Scene/suit_select.tscn"

# The pressed state alone is a subtle shade change, so the active choice
# also gets the accent colour used for highlights elsewhere.
const C_ACTIVE := Color(1, 0.84, 0.31)
const C_IDLE := Color(0.78, 0.82, 0.88)

const DIFF_BLURB := {
	GameState.Difficulty.EASY: "Follows a fixed priority order - heal whoever is hurt, snipe, trick, rally, otherwise attack. Readable once you spot the pattern, and it cannot tell when the skill it is about to use is worth less than the attack it gives up.",
	GameState.Difficulty.NORMAL: "The full scorer, but it misplays on purpose: about half its turns it takes the second or third best move instead of the best. Beats a player who only attacks about 7 times in 10.",
	GameState.Difficulty.HARD: "The same scorer playing its best move every time, on weights tuned against three different opponents. It rallies its Jack, shields to deny kills, and heals only to stop one. Beats a pure attacker 97 times in 100.",
}

# The volume sliders, built over this screen on demand. mode_select is the hub
# both boards return to, which makes it the one screen a player can always get
# back to in order to turn the music down.
var _audio_panel: AudioPanel = null

func _ready() -> void:
	SafeArea.bind($UI/Root)
	_audio_panel = AudioPanel.new()
	_audio_panel.build($UI/Root)
	# Arriving here means we are not in an online match; the board reads this to
	# decide which session to build.
	GameState.opponent = GameState.Opponent.AI

	# Suit is chosen on the NEXT screen now, so this line can no longer report
	# it - it used to read "Playing as: BLACK" before the player had picked.
	$UI/Root/SuitLabel.text = "Pick a mode, then your side."

	# Kept as a guard rather than a hard-coded true: if the face-down board is
	# ever moved or removed, the button greys out instead of dead-ending.
	var fd_ready: bool = ResourceLoader.exists(FACE_DOWN_SCENE)
	$UI/Root/FaceDownBtn.disabled = not fd_ready
	$UI/Root/FaceDownSoon.visible = not fd_ready

	# Reflect whatever is already set rather than forcing a default, so the
	# choice survives going Back and coming in again.
	_show_difficulty()

# Android has no Escape key: the system Back gesture arrives as this
# notification, and without handling it Godot quits the app outright rather
# than stepping back through the menus.
# The first screen now, so Back means leaving the game. The project does not
# quit on the notification by itself - the board scenes have to intercept it -
# so this is the one place that has to do it explicitly.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		get_tree().quit()

func _on_easy_btn_pressed() -> void:
	GameState.difficulty = GameState.Difficulty.EASY
	_show_difficulty()

func _on_normal_btn_pressed() -> void:
	GameState.difficulty = GameState.Difficulty.NORMAL
	_show_difficulty()

func _on_hard_btn_pressed() -> void:
	GameState.difficulty = GameState.Difficulty.HARD
	_show_difficulty()

func _show_difficulty() -> void:
	var picked: int = GameState.difficulty
	var buttons := {
		GameState.Difficulty.EASY: $UI/Root/Difficulty/EasyBtn,
		GameState.Difficulty.NORMAL: $UI/Root/Difficulty/NormalBtn,
		GameState.Difficulty.HARD: $UI/Root/Difficulty/HardBtn,
	}
	for level in buttons:
		var btn: Button = buttons[level]
		btn.button_pressed = level == picked
		btn.add_theme_color_override("font_color", C_ACTIVE if level == picked else C_IDLE)
	$UI/Root/DiffDesc.text = DIFF_BLURB.get(picked, "")

# Online is face-down only and the server assigns the seat, so neither the mode
# nor the suit picked on the way here applies to it.
# Mode is chosen here, suit on the next screen. Online picks a suit too - the
# server treats it as a preference and settles ties.
func _on_online_btn_pressed() -> void:
	GameState.mode = GameState.Mode.FACE_DOWN
	GameState.opponent = GameState.Opponent.ONLINE
	get_tree().change_scene_to_file(SUIT_SCENE)

func _on_face_up_btn_pressed() -> void:
	GameState.mode = GameState.Mode.FACE_UP
	get_tree().change_scene_to_file(SUIT_SCENE)

func _on_face_down_btn_pressed() -> void:
	GameState.mode = GameState.Mode.FACE_DOWN
	get_tree().change_scene_to_file(SUIT_SCENE)

func _on_audio_btn_pressed() -> void:
	_audio_panel.toggle()

func _on_back_btn_pressed() -> void:
	get_tree().quit()
