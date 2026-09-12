extends RefCounted
class_name BattleLog

# The scrolling BBCode battle log, shared by both game modes (PLAN M2.5).
# Lifted verbatim from table2.gd — it already solved two quirks worth keeping:
#
#  1. RichTextLabel.append_text() does not write back into `text`, so `text`
#     always returns the stale scene value. Trimming has to work off a private
#     line array and re-render.
#  2. When the label sits inside a ScrollContainer, RichTextLabel.scroll_following
#     has no effect — the ScrollContainer must be pushed down by hand, one frame
#     later, after the new line has been laid out.

const DEFAULT_MAX: int = 120

var _lines: PackedStringArray = PackedStringArray()
var _max: int = DEFAULT_MAX
var _header: String = ""
var _rtl: RichTextLabel = null
var _scroll: ScrollContainer = null

func _init(rtl: RichTextLabel, scroll: ScrollContainer = null, header: String = "", max_lines: int = DEFAULT_MAX) -> void:
	_rtl = rtl
	_scroll = scroll
	_header = header
	_max = max_lines
	_render_all()

func add(bbcode: String) -> void:
	_lines.append(bbcode)
	var trimmed: bool = false
	if _lines.size() > _max:
		_lines = _lines.slice(_lines.size() - _max)
		trimmed = true

	if not _usable():
		return
	if trimmed:
		_render_all()
	else:
		_rtl.append_text("\n" + bbcode)
	_follow()

func clear() -> void:
	_lines = PackedStringArray()
	_render_all()

func _usable() -> bool:
	return _rtl != null and is_instance_valid(_rtl) and _rtl.is_inside_tree()

func _render_all() -> void:
	if not _usable():
		return
	_rtl.clear()
	var body: String = _header
	if _lines.size() > 0:
		if body != "":
			body += "\n"
		body += "\n".join(_lines)
	_rtl.append_text(body)
	_follow()

func _follow() -> void:
	if _scroll == null or not is_instance_valid(_scroll) or not _scroll.is_inside_tree():
		return
	await _scroll.get_tree().process_frame
	if is_instance_valid(_scroll):
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)
