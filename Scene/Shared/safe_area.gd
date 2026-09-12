extends Node
class_name SafeArea

# Keeps UI clear of notches, punch-holes and gesture bars on Android.
#
# The project stretches with mode "canvas_items" / aspect "expand": the base
# 1280x720 is scaled to fit the short axis and the long axis simply gets wider,
# so on a 20:9 phone the viewport is roughly 1600x720 canvas units. Every scene
# therefore anchors its UI to a full-rect "Root" Control instead of hard-coding
# 1280, and Root's offsets are pulled inwards by whatever the display reports as
# unsafe. On desktop the safe area is the whole window, so the insets are zero
# and the editor layout is exactly what ships.
#
# DisplayServer reports the safe area in physical pixels; Root lives in canvas
# units, so both edges are divided by the live scale factor rather than by the
# 1280x720 the scene was drawn at.
#
# bind() parents one of these to the Root it maintains. That is what makes the
# size_changed connection safe across scene changes: the helper dies with the
# scene it belongs to, and Godot drops the connection with it. A static
# connection would outlive the freed Root and fire on a dangling reference.

# Never let a notch eat more than this much of the board, however the OS reports
# it — a bad inset should crop the UI a little, not fold it in half.
const MAX_INSET: float = 120.0

var _root: Control = null

# Insets `root` now, and again whenever the window changes size (rotation,
# split-screen, folding phones).
static func bind(root: Control) -> SafeArea:
	var helper := SafeArea.new()
	helper.name = "SafeAreaBinder"
	helper._root = root
	root.add_child(helper)
	return helper

func _ready() -> void:
	get_tree().root.size_changed.connect(_refresh)
	_refresh()

func _refresh() -> void:
	if not is_instance_valid(_root):
		return
	var inset := SafeArea.insets(_root)
	_root.offset_left = inset.position.x
	_root.offset_top = inset.position.y
	_root.offset_right = -inset.size.x
	_root.offset_bottom = -inset.size.y

# Returns a Rect2 abusing `position` as the top-left inset and `size` as the
# bottom-right one, both already converted to canvas units.
static func insets(node: Node) -> Rect2:
	var vp := node.get_viewport()
	if vp == null:
		return Rect2()

	var win: Vector2i = DisplayServer.window_get_size()
	var safe: Rect2i = DisplayServer.get_display_safe_area()
	# Desktop, and any platform that does not report one, hands back the whole
	# window (or an empty rect if the window is not mapped yet).
	if win.x <= 0 or win.y <= 0 or safe.size.x <= 0 or safe.size.y <= 0:
		return Rect2()

	var canvas: Vector2 = vp.get_visible_rect().size
	if canvas.x <= 0.0 or canvas.y <= 0.0:
		return Rect2()

	var scale := Vector2(float(win.x) / canvas.x, float(win.y) / canvas.y)
	if scale.x <= 0.0 or scale.y <= 0.0:
		return Rect2()

	var left := clampf(float(safe.position.x) / scale.x, 0.0, MAX_INSET)
	var top := clampf(float(safe.position.y) / scale.y, 0.0, MAX_INSET)
	var right := clampf(float(win.x - safe.end.x) / scale.x, 0.0, MAX_INSET)
	var bottom := clampf(float(win.y - safe.end.y) / scale.y, 0.0, MAX_INSET)
	return Rect2(Vector2(left, top), Vector2(right, bottom))
