extends Camera2D
class_name BoardCamera

# Frames the whole face-up board, whatever the screen.
#
# The board is drawn in world units 800 apart and roughly 1100 tall per card,
# and it shrinks as cards die and the survivors re-pack. A fixed zoom therefore
# had to be set for the worst case (five a side) and wasted most of the screen
# for the rest of the match — on a phone that made the cards small enough to be
# a genuine reading problem. This measures what is actually on the table and
# picks the zoom that fills the viewport, so a 2v2 endgame is as legible as it
# would be on a monitor.
#
# The extent is measured off the live nodes rather than assumed from the 500x700
# art: the attack/skill buttons and the HP bar hang well outside the card, and
# they are exactly what gets clipped when the guess is wrong. It is measured per
# card, not once, because a red card mirrors both of them to the underside (see
# Card._ready) — sampling one black card and reusing its box cut ~300 units off
# the bottom of the board and hid a red player's own action buttons.

# Breathing room around the board, in world units.
const PAD: Vector2 = Vector2(220.0, 180.0)

# Cards are 500 wide, so past this the art starts showing its pixels.
const MAX_ZOOM: float = 0.55
const MIN_ZOOM: float = 0.05

# How fast the camera slides to a new framing. 0 snaps.
const EASE_SPEED: float = 6.0

# Screen space the HUD occupies, in the same left/top -> position,
# right/bottom -> size convention SafeArea uses. The board is fitted into what
# is left, so the log panel and the turn readout never sit on top of a card.
var reserve: Rect2 = Rect2()

var _target_zoom: Vector2 = Vector2.ONE
var _target_pos: Vector2 = Vector2.ZERO
var _settled: bool = true
var _last_cards: Array = []

func _ready() -> void:
	_target_zoom = zoom
	_target_pos = position
	get_tree().root.size_changed.connect(_on_viewport_resized)

func _on_viewport_resized() -> void:
	# The card set has not changed, only the space to put it in.
	_apply(_last_cards)

func _process(delta: float) -> void:
	if _settled:
		return
	var t: float = clampf(delta * EASE_SPEED, 0.0, 1.0)
	zoom = zoom.lerp(_target_zoom, t)
	position = position.lerp(_target_pos, t)
	if zoom.distance_to(_target_zoom) < 0.0005 and position.distance_to(_target_pos) < 1.0:
		zoom = _target_zoom
		position = _target_pos
		_settled = true

# Re-frames on `cards`, a list of live Node2D cards already moved into place.
# Safe to call every layout change; it is a no-op when nothing moved.
func fit(cards: Array, animate: bool = true) -> void:
	_last_cards = cards.duplicate()
	_apply(_last_cards)
	if not animate:
		zoom = _target_zoom
		position = _target_pos
		_settled = true

func _apply(cards: Array) -> void:
	var live: Array = []
	for c in cards:
		if c != null and is_instance_valid(c):
			live.append(c)
	if live.is_empty():
		return

	var board := Rect2()
	var have := false
	for c in live:
		var r: Rect2 = _bounds(c, c.global_transform)
		if r.size.x <= 0.0 and r.size.y <= 0.0:
			# Nothing measurable on this card; fall back to the art size so a
			# lone survivor still frames sensibly.
			r = Rect2(c.global_position + Vector2(-250, -350), Vector2(500, 700))
		board = r if not have else board.merge(r)
		have = true
	if not have:
		return
	board = board.grow_individual(PAD.x, PAD.y, PAD.x, PAD.y)

	var vp: Vector2 = get_viewport().get_visible_rect().size
	# Anything the notch or the HUD covers is not usable board.
	var safe: Rect2 = SafeArea.insets(self)
	var inset := Rect2(safe.position + reserve.position, safe.size + reserve.size)
	vp.x -= inset.position.x + inset.size.x
	vp.y -= inset.position.y + inset.size.y
	if vp.x <= 0.0 or vp.y <= 0.0 or board.size.x <= 0.0 or board.size.y <= 0.0:
		return

	var z: float = clampf(minf(vp.x / board.size.x, vp.y / board.size.y), MIN_ZOOM, MAX_ZOOM)
	var centre: Vector2 = board.get_center()
	# A one-sided inset shifts the usable centre away from the viewport centre:
	# reserving 300px on the left means the camera has to look 150px/zoom to the
	# left of the board's own centre for the board to sit in the free half.
	centre.x += (inset.size.x - inset.position.x) * 0.5 / z
	centre.y += (inset.size.y - inset.position.y) * 0.5 / z

	if is_equal_approx(z, _target_zoom.x) and centre.is_equal_approx(_target_pos):
		return
	_target_zoom = Vector2(z, z)
	_target_pos = centre
	_settled = false

# Bounding box of everything a node draws, in world space.
# Visibility is ignored on purpose: the attack and skill buttons are hidden for
# most of a turn, and letting them fall out of the box would make the board jump
# every time a card is selected.
func _bounds(node: Node, xform: Transform2D) -> Rect2:
	var r := Rect2()
	var has := false
	# The frame this node's children are laid out in, which is not always the
	# frame the node itself is measured in.
	var child_xform := xform

	if node is Sprite2D and node.texture != null:
		# Scale is already carried by the transform the caller composed, so the
		# texture size must not be scaled again here.
		var s: Vector2 = node.texture.get_size()
		var local := Rect2(-s * 0.5 if node.centered else Vector2.ZERO, s)
		local.position += node.offset
		r = xform * local
		has = true
	elif node is Control:
		r = xform * Rect2(node.position, node.size)
		has = true
		# A Control lays its children out from its own top-left corner, not
		# from its parent's origin. Missing this put the Joker's TRICK label -
		# a Label filling the skill button, which is itself a Control - a full
		# button offset away, and the board zoomed out to keep the phantom in
		# frame.
		child_xform = xform.translated_local(node.position)

	for child in node.get_children():
		var cx: Transform2D = child_xform
		if child is Node2D:
			cx = child_xform * Transform2D(child.rotation, child.scale, child.skew, child.position)
		var cr: Rect2 = _bounds(child, cx)
		if cr.size.x <= 0.0 and cr.size.y <= 0.0:
			continue
		r = cr if not has else r.merge(cr)
		has = true

	return r if has else Rect2()
