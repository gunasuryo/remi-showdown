extends SceneTree

# The in-game rules sheet is content, and content has silently vanished from
# fd_table.tscn twice: once losing the whole rally/trick rewrite, once truncating
# every section after the Jack. Both times the edit "succeeded" and nothing
# noticed until a human opened the panel.
#
# Nothing else tests text, so this does. It checks the panel still has all its
# sections, and - more usefully - that the numbers printed on it match
# CardStats, so tuning a stat without updating the sheet is a failing test
# rather than a player reading the wrong rules.
#
#   godot --headless --path RemiShowdown --script res://test/test_rules_panel.gd

const SCENE := "res://Scene/FaceDown/fd_table.tscn"

var passed := 0
var failed := 0

func _ok(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL  %s   %s" % [name, detail])

func _initialize() -> void:
	print("rules panel")
	var body := _body_text()
	_ok(body != "", "P1 the rules body is present and non-empty")
	_ok(body.length() > 2000, "P1 ...and has not been truncated",
		"only %d chars" % body.length())

	for heading in ["The cards", "Each round", "Acting", "Hidden information",
			"Rally (King)", "Trick (Joker)", "Buffs are public", "Status on a card"]:
		_ok(body.find(heading) >= 0, "P2 section present: %s" % heading)

	# Every card's printed line must match the stat table it is describing.
	for card_name in CardStats.ORDER:
		var line := "%s %dhp / %datk" % [card_name,
			CardStats.hp_of(card_name, CardStats.FACE_DOWN), CardStats.atk_of(card_name, CardStats.FACE_DOWN)]
		_ok(body.find(line) >= 0, "P3 stat line matches CardStats: %s" % line)

	# The two rallied values are quoted in prose, so they drift silently.
	_ok(body.find("for %d each" % CardStats.rallied_skill_of("Ace", CardStats.FACE_DOWN)) >= 0,
		"P4 the rallied shield value on the sheet matches CardStats")
	_ok(body.find("for %d each" % CardStats.rallied_skill_of("Jack", CardStats.FACE_DOWN)) >= 0,
		"P4 the rallied shoot value on the sheet matches CardStats")
	_ok(body.find("%d%% of every blow" % int(round(CardStats.SHIELD_LEAK * 100.0))) >= 0,
		"P4 the shield leak on the sheet matches CardStats")

	# Claims the rules no longer make. Each of these was true once and is not
	# now, and each survived in the sheet after the rule changed.
	for stale in ["hit the whole line", "rally+ down to rally",
			"a King's rally frees it too", "20% of every blow"]:
		_ok(body.find(stale) < 0, "P5 stale claim is gone: \"%s\"" % stale)

	print("%d assertions, %d failed" % [passed + failed, failed])
	quit(1 if failed > 0 else 0)

# Reads the panel text out of the scene rather than the file, so it tests what
# actually ships rather than what the .tscn happens to look like.
func _body_text() -> String:
	var packed: PackedScene = load(SCENE)
	if packed == null:
		return ""
	var root: Node = packed.instantiate()
	var node: RichTextLabel = root.get_node_or_null(
		"UI/Root/RulesPanel/M/V/Scroll/Body") as RichTextLabel
	var out: String = node.text if node != null else ""
	root.free()
	return out
