extends RefCounted
class_name GameMenu

# The in-battle menu: Audio, Exit Game, Resume.
#
# Both boards used to wire their Menu button straight at leaving. Face-down at
# least asked first; FACE-UP DID NOT - one tap on `< Menu` and the match was
# gone, with no confirmation and nothing to undo it. That is also why there was
# nowhere to change the volume mid-match: the only button on the board that
# could have opened anything went straight out of the door.
#
# So the button now opens a menu, and leaving is a choice inside it rather than
# the button's whole meaning.
#
# The confirm step lives here because face-up had none to reuse. Face-down keeps
# its own panel - it carries wording about abandoning an ONLINE opponent's match
# that a generic confirm has no way to know about - so it takes `exit_requested`
# and handles the asking itself. Boards that have nothing special to say use
# ask_confirm() and get a plain one.

signal exit_requested()
signal exit_confirmed()

const PANEL_W: float = 420.0

var _root: Control = null
var _panel: PanelContainer = null
var _choices: VBoxContainer = null
var _confirm: VBoxContainer = null
var _confirm_body: Label = null
var _audio: AudioPanel = null

func build(parent: Control) -> void:
	_root = parent

	# Its own AudioPanel, so a board gets the whole menu from one call.
	_audio = AudioPanel.new()
	_audio.build(parent)

	_panel = PanelContainer.new()
	_panel.name = "GameMenu"
	_panel.visible = false
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.custom_minimum_size = Vector2(PANEL_W, 0.0)
	# Stops a tap on the menu reaching the board underneath, where
	# table2._unhandled_input would read it as "skip the animation".
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.10, 0.13, 0.97)
	style.border_color = Color(0.35, 0.38, 0.45)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(22)
	_panel.add_theme_stylebox_override("panel", style)
	_root.add_child(_panel)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 12)
	_panel.add_child(stack)

	# ── The choices ─────────────────────────────────────────────────────
	_choices = VBoxContainer.new()
	_choices.add_theme_constant_override("separation", 12)
	stack.add_child(_choices)

	var title := Label.new()
	title.text = "Menu"
	title.add_theme_font_size_override("font_size", 26)
	_choices.add_child(title)

	_button(_choices, "Audio", func():
		Sound.cue("click")
		hide_panel()
		_audio.show_panel())
	_button(_choices, "Exit Game", func():
		Sound.cue("click")
		exit_requested.emit())
	_button(_choices, "Resume", func():
		Sound.cue("cancel")
		hide_panel())

	# ── The confirm, hidden until asked for ─────────────────────────────
	_confirm = VBoxContainer.new()
	_confirm.add_theme_constant_override("separation", 12)
	_confirm.visible = false
	stack.add_child(_confirm)

	var warn := Label.new()
	warn.text = "Leave the match?"
	warn.add_theme_font_size_override("font_size", 26)
	_confirm.add_child(warn)

	_confirm_body = Label.new()
	_confirm_body.add_theme_font_size_override("font_size", 17)
	_confirm_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_confirm_body.custom_minimum_size = Vector2(PANEL_W - 44.0, 0.0)
	_confirm.add_child(_confirm_body)

	_button(_confirm, "Leave", func():
		Sound.cue("click")
		exit_confirmed.emit())
	_button(_confirm, "Stay", func():
		Sound.cue("cancel")
		_show_choices())

func _button(box: VBoxContainer, text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0.0, 56.0)
	b.add_theme_font_size_override("font_size", 21)
	b.pressed.connect(on_press)
	box.add_child(b)
	return b

# ── Views ─────────────────────────────────────────────────────────────────

func _show_choices() -> void:
	if _choices != null:
		_choices.visible = true
	if _confirm != null:
		_confirm.visible = false

# Swaps the menu to its confirm step. `body` is what this particular exit costs.
func ask_confirm(body: String) -> void:
	if _confirm_body != null:
		_confirm_body.text = body
	if _choices != null:
		_choices.visible = false
	if _confirm != null:
		_confirm.visible = true
	show_panel()

func show_panel() -> void:
	if _panel != null:
		_panel.visible = true

func hide_panel() -> void:
	if _panel != null:
		_panel.visible = false
	_show_choices()

# True while the menu OR the volume sliders are up, which is what a board needs
# to know before it treats a click as gameplay.
func is_open() -> bool:
	return (_panel != null and _panel.visible) or (_audio != null and _audio.is_open())

func toggle() -> void:
	if is_open():
		hide_panel()
		if _audio != null:
			_audio.hide_panel()
	else:
		show_panel()
