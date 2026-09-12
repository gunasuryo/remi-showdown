extends RefCounted
class_name AudioPanel

# The volume sliders, as an overlay any screen can put up.
#
# Built in code rather than added to each .tscn, for the same reason FUStage
# builds its banners that way: there are four screens that could reasonably want
# it, and hand-editing four scene files to keep four copies of the same panel in
# sync is how they drift apart. Attach it to a Control, get a button.
#
# It writes straight through to the Audio autoload on every drag, so the change
# is audible while the slider is moving - a volume control you have to confirm
# before you can hear it is a volume control you have to set twice. Saving is
# deferred to release, because writing user://remi.cfg on every pixel of drag
# would be a file write per frame.

const PANEL_W: float = 460.0
const PANEL_H: float = 260.0

var _root: Control = null
var _panel: PanelContainer = null

func _ready_panel(parent: Control) -> void:
	_root = parent

# Builds the overlay (hidden) and returns it, so the caller can show it.
func build(parent: Control) -> void:
	_root = parent

	_panel = PanelContainer.new()
	_panel.name = "AudioPanel"
	_panel.visible = false
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.custom_minimum_size = Vector2(PANEL_W, PANEL_H)
	# Eat clicks so a tap on the panel does not fall through to the board
	# underneath, where table2._unhandled_input would read it as "skip".
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.10, 0.13, 0.97)
	style.border_color = Color(0.35, 0.38, 0.45)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(22)
	_panel.add_theme_stylebox_override("panel", style)
	_root.add_child(_panel)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	_panel.add_child(v)

	var title := Label.new()
	title.text = "Audio"
	title.add_theme_font_size_override("font_size", 26)
	v.add_child(title)

	_add_slider(v, "Music", Audio.music_volume, Audio.set_music_volume)
	_add_slider(v, "Sound", Audio.sfx_volume, Audio.set_sfx_volume)

	var close := Button.new()
	close.text = "Close"
	close.custom_minimum_size = Vector2(0.0, 52.0)
	close.add_theme_font_size_override("font_size", 20)
	close.pressed.connect(hide_panel)
	v.add_child(close)

func _add_slider(box: VBoxContainer, label_text: String, initial: float,
		apply: Callable) -> void:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)

	var caption := Label.new()
	caption.add_theme_font_size_override("font_size", 18)
	caption.text = "%s   %d%%" % [label_text, int(round(initial * 100.0))]
	row.add_child(caption)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = initial
	slider.custom_minimum_size = Vector2(0.0, 34.0)
	row.add_child(slider)

	slider.value_changed.connect(func(value: float):
		apply.call(value)
		caption.text = "%s   %d%%" % [label_text, int(round(value * 100.0))])
	# One write when the drag ends, not one per frame while it moves.
	slider.drag_ended.connect(func(_changed: bool): Audio.save_prefs())

func show_panel() -> void:
	if _panel != null:
		_panel.visible = true

func hide_panel() -> void:
	if _panel != null:
		_panel.visible = false
		Audio.save_prefs()

func is_open() -> bool:
	return _panel != null and _panel.visible

func toggle() -> void:
	if is_open():
		hide_panel()
	else:
		show_panel()
