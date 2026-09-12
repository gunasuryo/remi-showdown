extends Node

# The board's action buttons, driven through the states an ONLINE match passes
# through.
#
#   godot --headless --path RemiShowdown res://test/test_board_buttons.tscn
#
# Run as a SCENE, not --script: it needs the GameState autoload, and autoloads
# are not registered for a --script MainLoop.
#
# This exists because of a bug that only online play could hit. While the board
# waits for an opponent it has no state, so _disable_actions() turns every
# action button off. _refresh_buttons() then set `visible` on Randomize and Lock
# In but never `disabled` - so once the board had waited, the two buttons the
# positioning phase is made of were visible and permanently dead.
#
# A local match never reaches that path: FDLocalSession has state immediately.
# So the suites passed, and the only way to see it was to press the button,
# which no test did - the earlier end-to-end tests all called the handler
# directly and skipped the disabled flag entirely.
#
# Hence the rule this file enforces: after any sequence of refreshes, a button
# that is VISIBLE and whose action is legal must not be DISABLED.

const BOARD := "res://Scene/FaceDown/fd_table.tscn"

var passed := 0
var failed := 0

func _ok(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL  %s   %s" % [name, detail])

func _ready() -> void:
	print("board action buttons")
	# A local match, so no server is needed; the states are the same ones an
	# online board moves through.
	GameState.opponent = GameState.Opponent.AI
	GameState.player_suit = FDState.BLACK

	var board: Node = (load(BOARD) as PackedScene).instantiate()
	add_child(board)

	# 1. The waiting state an online board starts in: no state at all.
	board.state = null
	board._refresh()
	_ok(board.get_node("UI/Root/Actions/LockBtn").disabled,
		"B1 Lock In is disabled while the board has no state")

	# 2. State arrives, positioning begins. This is the transition that was
	#    broken: the buttons must come back to life.
	var s := FDRules.new_match(FDState.BLACK)
	board.state = s
	board.player_side = FDState.BLACK
	board.ai_side = FDState.RED
	board._draft = FDRules.auto_place(s, FDState.BLACK, null)
	board._refresh()

	var lock: Button = board.get_node("UI/Root/Actions/LockBtn")
	var rand: Button = board.get_node("UI/Root/Actions/RandomBtn")
	_ok(lock.visible, "B2 Lock In is visible in positioning")
	_ok(not lock.disabled, "B2 Lock In is ENABLED in positioning", "still disabled after waiting")
	_ok(rand.visible, "B2 Randomize is visible in positioning")
	_ok(not rand.disabled, "B2 Randomize is ENABLED in positioning", "still disabled after waiting")

	# 3. Once this side has locked in there is nothing left to press.
	s.placed[FDState.BLACK] = true
	board._refresh()
	_ok(lock.disabled, "B3 Lock In is disabled once this side has locked in")

	# 4. Battle: the positioning buttons go away, the action buttons appear.
	FDRules.commit_placement(s, FDState.BLACK, FDRules.auto_place(s, FDState.BLACK, null))
	FDRules.commit_placement(s, FDState.RED, FDRules.auto_place(s, FDState.RED, null))
	board._draft = []
	board._refresh()
	_ok(not lock.visible, "B4 Lock In is hidden in battle")
	_ok(board.get_node("UI/Root/Actions/AttackBtn").visible, "B4 Attack is visible in battle")

	# 5. The general rule, checked over the whole cycle: nothing that is on
	#    screen and legal may be left disabled.
	board.state = null
	board._refresh()
	board.state = s
	board._refresh()
	for n in ["AttackBtn", "SkillBtn", "CancelBtn", "RulesBtn", "MenuBtn"]:
		var b: Button = board.get_node_or_null("UI/Root/Actions/" + n)
		if b != null and b.visible and n in ["RulesBtn", "MenuBtn"]:
			# These two are always legal - they are the way out of the screen.
			_ok(not b.disabled, "B5 %s is never disabled" % n)

	board.free()
	print("%d assertions, %d failed" % [passed + failed, failed])
	get_tree().quit(1 if failed > 0 else 0)
