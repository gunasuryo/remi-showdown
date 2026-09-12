extends Node2D

# Suit is picked AFTER the mode, so this screen knows where it is sending the
# player and can say what the choice actually means.
#
# Online it is a PREFERENCE, not a claim: both players choose independently, so
# they will sometimes choose the same suit. The server gives it to whoever asked
# first and hands the other player the remaining one - see fd_server._do_join.
# Losing a coin toss beats being bounced back to the lobby with "that suit is
# taken", which is what refusing would mean.

const MODE_SELECT: String = "res://Scene/mode_select.tscn"
const LOBBY_SCENE: String = "res://Scene/lobby.tscn"
const FACE_UP_SCENE: String = "res://Scene/Table/table_2.tscn"
const FACE_DOWN_SCENE: String = "res://Scene/FaceDown/fd_table.tscn"

func _ready() -> void:
	SafeArea.bind($UI/Root)
	var online: bool = GameState.opponent == GameState.Opponent.ONLINE
	$UI/Root/ChooseLabel.text = "Which side would you rather play?" if online 		else "Choose your side:"
	$UI/Root/RulesLabel.text = _blurb(online)

func _blurb(online: bool) -> String:
	if online:
		return "Your friend picks too. If you both want the same side, whoever asked first keeps it and you get the other — the match starts either way.

Black always leads the first round, which is a disadvantage: acting first means revealing first."
	return "Each turn, choose Attack (slot-locked) or Skill (special ability).
Ace: Shield ally  |  Jack: Shoot any enemy  |  Queen: Heal ally  |  King: Rally ally  |  Joker: Trick enemy
Rallied cards hit 3 targets with their next skill. Tricked cards can only attack.
First team to wipe out the enemy wins!"

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_back()

func _back() -> void:
	GameState.opponent = GameState.Opponent.AI
	get_tree().change_scene_to_file(MODE_SELECT)

func _pick(suit: int) -> void:
	GameState.player_suit = suit
	if GameState.opponent == GameState.Opponent.ONLINE:
		# The lobby opens the room; the suit rides along as a preference.
		get_tree().change_scene_to_file(LOBBY_SCENE)
	elif GameState.mode == GameState.Mode.FACE_UP:
		get_tree().change_scene_to_file(FACE_UP_SCENE)
	else:
		get_tree().change_scene_to_file(FACE_DOWN_SCENE)

func _on_black_btn_pressed() -> void:
	_pick(1)

func _on_red_btn_pressed() -> void:
	_pick(2)
