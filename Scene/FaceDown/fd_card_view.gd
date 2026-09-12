extends PanelContainer
class_name FDCardView

# One board slot. Renders whatever the table hands it and knows nothing about
# the rules: the table decides what this viewer is allowed to see (for the enemy
# row that means FDState.observe(), never the FDCard itself), and this only
# draws it.

signal pressed(slot: int)

const ART_DIR := "res://Asset/"

# Shown instead of the art while a card is face down or dead.
const GLYPH_HIDDEN := "?"
const GLYPH_DEAD := "X"
const GLYPH_EMPTY := "-"

const C_HIDDEN_BG := Color(0.11, 0.13, 0.20)
const C_DEAD_BG   := Color(0.13, 0.13, 0.15)
const C_EMPTY_BG  := Color(0.09, 0.09, 0.11)
const C_ART_BG    := Color(0.06, 0.07, 0.09)

const C_BORDER   := Color(0.28, 0.31, 0.38)
const C_SELECTED := Color(1.00, 0.84, 0.31)
const C_TARGET   := Color(0.35, 0.80, 0.95)

# A gold outline alone is easy to lose among five cards of similar size, so the
# selected card also warms its background, turns its name and stats gold, and
# takes a caret. It used to fill a solid gold band behind the name - that band
# was part of the header block that covered the card face, and went with it.
const C_SELECTED_BG := Color(0.24, 0.20, 0.10)
const C_STAT := Color(0.82, 0.87, 0.94)
# A card that has spent its turn. Dimming alone was easy to miss across five
# cards, so the name also takes a tick.
const ACTED_MARK := "✓ "
const C_ACTED_TEXT := Color(0.55, 0.58, 0.64)
# The line art is pure white and fights the dark UI head-on at phone size.
const ART_TINT := Color(0.90, 0.92, 0.95)

# Buffs are public even on a face-down card, so a hidden slot can still show
# what was done to it. This is what makes spending an action on a dead decoy a
# bluff worth telling: a shielded corpse and a shielded survivor look identical.
const C_MARK_SHIELD := Color(0.40, 0.82, 1.00)
const C_MARK_RALLY := Color(1.00, 0.84, 0.31)
const C_MARK_TEND := Color(0.52, 0.85, 0.55)
const SELECT_MARK := "▸ "
const BORDER_SELECTED := 5
const BORDER_TARGET := 3
const BORDER_IDLE := 1

const C_TEXT  := Color(0.93, 0.95, 0.97)
const C_MUTED := Color(0.60, 0.64, 0.70)

# A revealed corpse still shows its face, just drained of colour.
const DEAD_TINT := Color(0.45, 0.45, 0.50, 1.0)

# The strip along the top of YOUR OWN cards: green while the enemy still
# cannot see the card, amber once acting or being hit has revealed it. It is
# the one thing about your row you cannot read off the card itself, since
# you always see your own faces.
const C_HIDDEN_FROM_FOE := Color(0.30, 0.62, 0.42)
const C_SEEN_BY_FOE := Color(0.95, 0.62, 0.20)

# Which slot on the board this view stands for. Set by the table before it is
# added to a row; it never changes for the life of the node.
var slot: int = -1

var _panel_sb: StyleBoxFlat = null
var _lunge_tween: Tween = null
# The lunge is an offset applied ON TOP of wherever the row has sorted this
# card, re-read every frame - not a tween from a position captured up front.
# A captured position is wrong exactly when it matters: on the frame a round
# begins the row has just been rebuilt and has not sorted yet, so every card
# still reads (0, 0), and a lunge started there parked the card at the far left
# of the row for the rest of the round. Re-reading also absorbs a re-sort that
# lands mid-lunge instead of fighting it.
var _lunge_offset: Vector2 = Vector2.ZERO
var _lunge_base: Vector2 = Vector2.ZERO
var _lunge_applied: Vector2 = Vector2.ZERO
var _lunging: bool = false
var _hp_bg_sb: StyleBoxFlat = null
var _hp_fill_sb: StyleBoxFlat = null

# Styles are built per instance rather than declared in the .tscn: a StyleBox
# that lives in the scene file is SHARED between every instance of it, so
# selecting one card would outline all ten.
func _ensure_styles() -> void:
	if _panel_sb != null:
		return
	_panel_sb = StyleBoxFlat.new()
	_panel_sb.set_corner_radius_all(6)
	_panel_sb.set_content_margin_all(0)
	add_theme_stylebox_override("panel", _panel_sb)

	_hp_bg_sb = StyleBoxFlat.new()
	_hp_bg_sb.bg_color = Color(0.04, 0.05, 0.07, 0.85)
	_hp_bg_sb.set_corner_radius_all(3)
	_hp_fill_sb = StyleBoxFlat.new()
	_hp_fill_sb.set_corner_radius_all(3)
	var bar: ProgressBar = $M/V/Bot/BV/HPBar
	bar.add_theme_stylebox_override("background", _hp_bg_sb)
	bar.add_theme_stylebox_override("fill", _hp_fill_sb)

# Every card now has its own art. The Joker used to have none: both modes drew
# the King's texture upside down, which is why this took a `face` substitution
# and the renderer flipped the Joker vertically.
static func art_for(card_name: String, side: int) -> Texture2D:
	var suit: String = "Black" if side == FDState.BLACK else "Red"
	var path: String = "%s%s%s.png" % [ART_DIR, card_name, suit]
	if not ResourceLoader.exists(path):
		return null
	return load(path)

# `d` carries exactly what the table decided is visible:
#   slot, side, own, empty, known, alive, card_name, hp, max_hp, shield,
#   rally, tricked, acted, selected, targetable
func render(d: Dictionary) -> void:
	_ensure_styles()

	var art: TextureRect = $Art
	var slot_label: Label = $M/V/Bot/BV/SlotLabel
	var name_label: Label = $M/V/Bot/BV/NameLabel
	var glyph: Label = $M/V/Glyph
	var bar: ProgressBar = $M/V/Bot/BV/HPBar
	var hp_label: Label = $M/V/Bot/BV/HPLabel
	var shield_label: Label = $M/V/Bot/BV/ShieldLabel
	var stat_label: Label = $M/V/StatLabel
	var preview: Label = $Preview
	var rally_label: Label = $M/V/Bot/BV/RallyLabel
	var trick_label: Label = $M/V/Bot/BV/TrickLabel

	var own: bool = d.get("own", false)
	var side: int = int(d.get("side", FDState.BLACK))

	# Only your own row carries the strip. On the enemy row the face-down back
	# versus the artwork already says what you can and cannot see.
	var strip: ColorRect = $M/V/Expose
	var exposed: bool = d.get("exposed", false)
	strip.visible = own and not d.get("empty", false)
	strip.color = C_SEEN_BY_FOE if exposed else C_HIDDEN_FROM_FOE

	# Nothing is known about a face-down or empty slot, so no stat line either.
	stat_label.text = ""
	stat_label.visible = false

	# The damage this lane would take from the action being aimed right now.
	# Without it, choosing a lane is a guess about your own numbers rather than
	# a guess about the hidden card, which is the wrong thing to be unsure of.
	var pv: String = str(d.get("preview", ""))
	preview.visible = pv != ""
	preview.text = pv

	var tag: String = "slot %d" % (int(d.get("slot", slot)) + 1)
	if strip.visible:
		tag += " · seen" if exposed else " · hidden"
	slot_label.text = tag
	slot_label.add_theme_color_override("font_color",
		C_SEEN_BY_FOE if (strip.visible and exposed) else Color(0.6, 0.65, 0.72))

	var bg := C_EMPTY_BG
	var fg := C_TEXT
	var show_art := false

	if d.get("empty", false):
		glyph.text = GLYPH_EMPTY
		name_label.text = "empty"
		bg = C_EMPTY_BG
		fg = C_MUTED
		_set_stats_visible(false)
	elif not d.get("known", false):
		# Face-down: the viewer knows a card is there and nothing else, not even
		# whether it is still alive (PRD 8.2 / 8.3). No art, by definition -
		# there is no card back asset, so the drawn back stands in for one.
		glyph.text = GLYPH_HIDDEN
		name_label.text = "face down"
		bg = C_HIDDEN_BG
		fg = C_MUTED
		_set_stats_visible(false)
		_show_marks(d)
	elif not d.get("alive", true):
		glyph.text = GLYPH_DEAD
		name_label.text = "DEAD DECOY"
		bg = C_DEAD_BG
		fg = C_MUTED
		show_art = true
		_set_stats_visible(false)
	else:
		name_label.text = str(d.get("card_name", "?"))
		bg = C_ART_BG
		show_art = true
		_set_stats_visible(true)
		stat_label.text = stat_line(str(d.get("card_name", "")))
		stat_label.visible = stat_label.text != ""

		var hp: int = int(d.get("hp", 0))
		var max_hp: int = max(1, int(d.get("max_hp", 1)))
		bar.max_value = max_hp
		bar.value = hp
		hp_label.text = "%d / %d" % [hp, max_hp]
		_hp_fill_sb.bg_color = _hp_color(float(hp) / float(max_hp))

		var shield: int = int(d.get("shield", 0))
		shield_label.text = ("shield %d" % shield) if shield > 0 else ""

		# Two lines rather than one string: a King can hold an armed rally+ and
		# be tricked at the same time, and the two states want different colours.
		var rally: String = str(d.get("rally", ""))
		rally_label.text = rally
		rally_label.visible = rally != ""
		trick_label.visible = d.get("tricked", false)
		# A trick now costs the skill AND half the attack, so say so.
		trick_label.text = "TRICKED -50%"

	var texture: Texture2D = null
	if show_art:
		texture = art_for(str(d.get("card_name", "")), side)
	art.texture = texture
	art.visible = texture != null
	# A revealed corpse keeps its face but loses its colour; the glyph is only
	# needed when there is no art behind it to say what the slot holds.
	art.modulate = DEAD_TINT if not d.get("alive", true) else ART_TINT
	# The glyph stands in for the picture; when there is one, an empty spacer
	# takes its place so the stat block still sits on the bottom edge.
	glyph.visible = texture == null
	$M/V/Spacer.visible = texture != null

	glyph.add_theme_color_override("font_color", fg)
	name_label.add_theme_color_override("font_color", fg)
	_panel_sb.bg_color = bg

	# A card that has already acted this round is dimmed rather than hidden -
	# it still occupies its slot and can still be attacked.
	modulate = Color(1, 1, 1, 0.62) if d.get("acted", false) else Color(1, 1, 1, 1)

	var is_selected: bool = d.get("selected", false)
	var has_acted: bool = d.get("acted", false)
	if is_selected:
		_set_border(C_SELECTED, BORDER_SELECTED)
		_panel_sb.bg_color = C_SELECTED_BG
		# Name and stats go gold to match the border; both sit directly on the
		# art now, so they are tinted rather than reversed out of a fill.
		name_label.add_theme_color_override("font_color", C_SELECTED)
		stat_label.add_theme_color_override("font_color", C_SELECTED)
		name_label.text = SELECT_MARK + name_label.text
	else:
		stat_label.add_theme_color_override("font_color", C_STAT)
		if has_acted:
			name_label.text = ACTED_MARK + name_label.text
			name_label.add_theme_color_override("font_color", C_ACTED_TEXT)
		if d.get("targetable", false):
			_set_border(C_TARGET, BORDER_TARGET)
		else:
			_set_border(C_BORDER, BORDER_IDLE)

	# A selected card is never also dimmed for having acted: you can only
	# select one that still has its action.
	if is_selected:
		modulate = Color(1, 1, 1, 1)

# "26 atk - Shoot 20". The numbers live in CardStats, so this cannot drift
# from what the card actually does.
static func stat_line(card_name: String) -> String:
	if not CardStats.has_card(card_name, CardStats.FACE_DOWN):
		return ""
	var atk: int = CardStats.atk_of(card_name, CardStats.FACE_DOWN)
	var skill: int = CardStats.skill_of(card_name, CardStats.FACE_DOWN)
	var word: String = FDCard.skill_word_for(card_name)
	if skill <= 0:
		return "%d atk  ·  %s" % [atk, word]
	return "%d atk  ·  %s %d" % [atk, word, skill]

# A short shove toward whatever this card is acting on, and back.
#
# The card sits in an HBoxContainer, which owns its position and reassigns it
# on every sort. That is survivable because a Tween writes an ABSOLUTE position
# each frame: a sort mid-flight costs one frame, not the animation. The return
# leg targets the position the container gave us, so the card always lands back
# where the layout wants it even if it re-sorted along the way.
#
# Any in-flight lunge is killed first - a card can be shoved twice in quick
# succession (a rallied skill resolves lane by lane), and two tweens fighting
# over `position` would leave it parked off-centre.
func lunge(offset: Vector2, out_time: float = 0.10) -> void:
	if _lunge_tween != null and _lunge_tween.is_valid():
		_lunge_tween.kill()
	# Give the sorted position back before measuring it again.
	position -= _lunge_offset
	_lunge_base = position
	_lunge_offset = Vector2.ZERO
	_lunge_applied = position
	_lunging = true

	_lunge_tween = create_tween()
	_lunge_tween.tween_method(_set_lunge_offset, Vector2.ZERO, offset, out_time) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# Slower coming back than going out, so it reads as a strike rather than a
	# twitch.
	_lunge_tween.tween_method(_set_lunge_offset, offset, Vector2.ZERO, out_time * 1.9) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	_lunge_tween.finished.connect(_end_lunge)

func _set_lunge_offset(v: Vector2) -> void:
	_lunge_offset = v

func _end_lunge() -> void:
	_lunging = false
	_lunge_offset = Vector2.ZERO
	position = _lunge_base

func _process(_delta: float) -> void:
	if not _lunging:
		return
	# Anything that moved us other than this lunge is the row re-sorting, and
	# the row is the authority on where the card lives - so adopt it.
	if position != _lunge_applied:
		_lunge_base = position
	_lunge_applied = _lunge_base + _lunge_offset
	position = _lunge_applied

# A number floating up off the card: damage taken, healing, shield absorbed.
# The board renders state; without this it never renders CHANGE, and every hit
# was a silent jump in a progress bar.
func pop(text: String, colour: Color) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 30)
	l.add_theme_color_override("font_color", colour)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 7)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.z_index = 10
	add_child(l)

	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(l, "position:y", -46.0, 0.85).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(l, "modulate:a", 0.0, 0.85).set_delay(0.25)
	t.chain().tween_callback(l.queue_free)

# A brief wash of colour over the whole card, so the eye is pulled to where the
# number is about to appear.
func flash(colour: Color) -> void:
	var r := ColorRect.new()
	r.color = colour
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.z_index = 9
	add_child(r)
	var t := create_tween()
	t.tween_property(r, "modulate:a", 0.0, 0.4)
	t.tween_callback(r.queue_free)

# The badge row on a face-down card. It says WHAT was done to the slot, never
# which card is standing in it - so a rallied corpse reads exactly like a
# rallied survivor, which is the point.
func _show_marks(d: Dictionary) -> void:
	var bits: Array = []
	if d.get("shielded", false):
		bits.append("[color=#66d1ff]SHIELDED[/color]")
	if d.get("rallied", false):
		bits.append("[color=#ffd54f]RALLIED[/color]")
	if d.get("tended", false):
		bits.append("[color=#85d98c]TENDED[/color]")
	if bits.is_empty():
		return

	# The stat block is hidden for an unknown card, so the badges borrow the
	# bottom band and the two status lines that already live there.
	var bot: PanelContainer = $M/V/Bot
	var rally_label: Label = $M/V/Bot/BV/RallyLabel
	bot.visible = true
	rally_label.visible = true
	# Plain Label, so the colour tags are stripped rather than rendered.
	rally_label.text = " · ".join(_plain(bits))
	rally_label.add_theme_color_override("font_color", _mark_colour(d))

func _plain(bits: Array) -> Array:
	var out: Array = []
	for b in bits:
		out.append(str(b).get_slice("]", 1).get_slice("[", 0))
	return out

# One colour for the row: whichever buff is most worth reacting to.
func _mark_colour(d: Dictionary) -> Color:
	if d.get("rallied", false):
		return C_MARK_RALLY
	if d.get("shielded", false):
		return C_MARK_SHIELD
	return C_MARK_TEND

func _set_stats_visible(on: bool) -> void:
	$M/V/Bot/BV/HPBar.visible = on
	$M/V/Bot/BV/HPLabel.visible = on
	$M/V/Bot/BV/ShieldLabel.visible = on
	# The two status lines hide themselves in render() when they have nothing
	# to say, so an idle card shows no empty rows.
	if not on:
		$M/V/Bot/BV/RallyLabel.visible = false
		$M/V/Bot/BV/TrickLabel.visible = false
	# The bottom band itself ALWAYS stays: it carries the slot number and the
	# hidden/seen state, which a face-down card needs more than a revealed one
	# does. Hiding the whole band when there were no stats to show took the slot
	# label with it and left the enemy row as five unlabelled rectangles.
	$M/V/Bot.visible = true

func _set_border(c: Color, width: int) -> void:
	_panel_sb.border_color = c
	_panel_sb.set_border_width_all(width)

func _hp_color(ratio: float) -> Color:
	if ratio > 0.5:
		return Color(0.42, 0.75, 0.44)
	if ratio > 0.25:
		return Color(0.95, 0.75, 0.30)
	return Color(0.88, 0.32, 0.30)

func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pressed.emit(slot)
