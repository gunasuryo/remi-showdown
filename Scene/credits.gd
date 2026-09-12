extends Node2D

# Asset attribution.
#
# This is not decoration: the packs used here are licensed, and the licences ask
# to be credited. Keeping the list in ONE place and pointing at it from the menu
# means it cannot quietly fall out of date the way a line in a README does.
#
# The URLs are shown as plain text rather than links. A phone browser opening
# mid-game is disruptive, and OS.shell_open on Android needs a permission this
# build does not otherwise want - so the address is there to be read and typed,
# not tapped.

const MODE_SELECT: String = "res://Scene/mode_select.tscn"

# Each entry: [heading, what it covers, where it came from].
# Kept as data rather than baked into the scene so adding a pack is one line.
const CREDITS := [
	[
		"Music",
		"memento — main theme",
		"uniquegear\nhttps://uniquegear.booth.pm/items/6808318",
	],
	[
		"Sound effects",
		"Card handling: deals, slides, shuffles",
		"Kenney — Casino Audio\nhttps://kenney.nl/assets/casino-audio",
	],
	[
		"",
		"Combat and interface: hits, shields, clicks",
		"Kenney — RPG Audio\nhttps://kenney.nl/assets/rpg-audio",
	],
]

const C_HEAD := Color(1.0, 0.84, 0.31)
const C_WHAT := Color(0.88, 0.91, 0.95)
const C_FROM := Color(0.62, 0.66, 0.74)

func _ready() -> void:
	SafeArea.bind($UI/Root)
	_build()

func _build() -> void:
	var list: VBoxContainer = $UI/Root/Scroll/List
	for child in list.get_children():
		child.queue_free()

	for entry in CREDITS:
		var heading: String = entry[0]
		if heading != "":
			if list.get_child_count() > 0:
				list.add_child(_spacer(18))
			list.add_child(_line(heading, 24, C_HEAD))
		list.add_child(_line(entry[1], 18, C_WHAT))
		list.add_child(_line(entry[2], 15, C_FROM))
		list.add_child(_spacer(10))

func _line(text: String, size: int, colour: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back_btn_pressed()

func _on_back_btn_pressed() -> void:
	get_tree().change_scene_to_file(MODE_SELECT)
