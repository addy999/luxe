extends Control
class_name LibraryItem

# One grid tile in LibraryView: thumbnail/RAW placeholder + filename caption.
# Owns no photo-list state; LibraryView drives setup()/set_texture()/set_selected().

signal clicked(index: int, shift: bool, command: bool)
signal activated(index: int)
signal zoom_gestured(factor: float)

const THUMB_SIZE: float = 200.0
const CAPTION_HEIGHT: float = 28.0
const TILE_SIZE: Vector2 = Vector2(200.0, THUMB_SIZE + CAPTION_HEIGHT)
# Grid cell spacing (both axes) LibraryView uses alongside TILE_SIZE for layout.
const GROUP_SEP: int = 28

var _index: int = -1
var _photo: Dictionary = {}
var _texture: Texture2D = null
var _selected: bool = false
var _hovered: bool = false
var _edited: bool = false
var _rejected: bool = false
var _show_dim: bool = true   # when false (hide-rejected on), rejected tiles aren't filtered here; just skip the dim overlay
var _tile_scale: float = 1.0

# Edited-marker dot: yellow, drawn in the thumbnail's top-right corner.
const _EDITED_DOT_RADIUS: float = 5.0
const _EDITED_DOT_MARGIN: float = 8.0

# Rejected state: dim overlay over the thumbnail + red marker in the top-left
# corner (edited dot keeps the top-right).
const _REJECT_MARK_RADIUS: float = 5.0
const _REJECT_MARK_MARGIN: float = 8.0

# All drawing colors come from the active Theme's "LibraryTile" entries
# (main_theme.tres / light_theme.tres), pulled in on ready + theme_changed.
# Declared at GDScript's zero default; never used uninitialized in the app
# (the theme always resolves) and headless tests never reach _draw().
var _color_tile: Color
var _color_tile_hover: Color
var _color_border: Color
var _color_accent: Color
var _color_caption: Color
var _color_edited_dot: Color
var _color_reject_dim: Color
var _color_reject_mark: Color


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	# Respects a _tile_scale set via set_tile_scale() before this node entered
	# the tree; a bare `custom_minimum_size = TILE_SIZE` here would clobber it,
	# leaving the cell sized for scale 1.0 while _draw uses the real scale.
	_apply_tile_size()
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# Resolved by node path, not the ThemeManager identifier: autoloads are not
	# registered in --script mode, where a direct identifier fails to compile.
	var theme_manager: Node = get_node_or_null("/root/ThemeManager")
	if theme_manager != null:
		theme_manager.theme_changed.connect(_on_theme_changed)
		_update_colors(theme_manager.is_dark)
	else:
		_update_colors(true)


func _on_theme_changed(is_dark: bool) -> void:
	_update_colors(is_dark)
	queue_redraw()


func _update_colors(_is_dark: bool) -> void:
	# root.theme is swapped on toggle, so the active Theme's "LibraryTile"
	# entries already reflect dark/light; is_dark is unused here.
	if has_theme_color("tile_bg", "LibraryTile"):
		_color_tile = get_theme_color("tile_bg", "LibraryTile")
	if has_theme_color("tile_hover", "LibraryTile"):
		_color_tile_hover = get_theme_color("tile_hover", "LibraryTile")
	if has_theme_color("border", "LibraryTile"):
		_color_border = get_theme_color("border", "LibraryTile")
	if has_theme_color("accent", "LibraryTile"):
		_color_accent = get_theme_color("accent", "LibraryTile")
	if has_theme_color("caption", "LibraryTile"):
		_color_caption = get_theme_color("caption", "LibraryTile")
	if has_theme_color("edited_dot", "LibraryTile"):
		_color_edited_dot = get_theme_color("edited_dot", "LibraryTile")
	if has_theme_color("reject_dim", "LibraryTile"):
		_color_reject_dim = get_theme_color("reject_dim", "LibraryTile")
	if has_theme_color("reject_mark", "LibraryTile"):
		_color_reject_mark = get_theme_color("reject_mark", "LibraryTile")


func setup(index: int, photo: Dictionary) -> void:
	_index = index
	_photo = photo
	_texture = null
	_selected = false
	_edited = false
	_rejected = false
	queue_redraw()


func set_selected(selected: bool) -> void:
	if _selected == selected:
		return
	_selected = selected
	queue_redraw()


func set_texture(tex: Texture2D) -> void:
	_texture = tex
	queue_redraw()


func set_edited(edited: bool) -> void:
	if _edited == edited:
		return
	_edited = edited
	queue_redraw()


func set_rejected(rejected: bool) -> void:
	if _rejected == rejected:
		return
	_rejected = rejected
	queue_redraw()


func set_dim_enabled(enabled: bool) -> void:
	if _show_dim == enabled:
		return
	_show_dim = enabled
	queue_redraw()


func has_texture() -> bool:
	return _texture != null


func clear_texture() -> void:
	_texture = null
	queue_redraw()


func get_photo_index() -> int:
	return _index


# The master path of the photo currently bound to this tile ("" if unbound).
func get_bound_path() -> String:
	return _photo.get("path", "")


func set_tile_scale(scale: float) -> void:
	scale = clamp(scale, 0.5, 4.0)
	if is_equal_approx(scale, _tile_scale) and custom_minimum_size.x > 0.0:
		return
	_tile_scale = scale
	_apply_tile_size()
	queue_redraw()


func _apply_tile_size() -> void:
	custom_minimum_size = Vector2(
		TILE_SIZE.x * _tile_scale, THUMB_SIZE * _tile_scale + CAPTION_HEIGHT)


func _draw() -> void:
	var thumb_rect := Rect2(Vector2.ZERO, Vector2(size.x, THUMB_SIZE * _tile_scale))
	var bg_color: Color = _color_tile_hover if (_selected or _hovered) else _color_tile
	draw_rect(Rect2(Vector2.ZERO, size), bg_color, true)

	if _selected:
		draw_rect(Rect2(Vector2.ONE, size - Vector2(2.0, 2.0)), _color_accent, false, 2.0)
	else:
		draw_rect(Rect2(Vector2.ZERO, size), _color_border, false, 1.0)

	if _texture != null:
		_draw_letterboxed(thumb_rect)
	else:
		_draw_raw_placeholder(thumb_rect)

	if _rejected and _show_dim:
		draw_rect(thumb_rect, _color_reject_dim, true)
	if _rejected:
		var mark_center := Vector2(
			thumb_rect.position.x + _REJECT_MARK_MARGIN + _REJECT_MARK_RADIUS,
			thumb_rect.position.y + _REJECT_MARK_MARGIN + _REJECT_MARK_RADIUS)
		draw_circle(mark_center, _REJECT_MARK_RADIUS, _color_reject_mark)

	if _edited:
		var dot_center := Vector2(
			thumb_rect.end.x - _EDITED_DOT_MARGIN - _EDITED_DOT_RADIUS,
			thumb_rect.position.y + _EDITED_DOT_MARGIN + _EDITED_DOT_RADIUS)
		draw_circle(dot_center, _EDITED_DOT_RADIUS, _color_edited_dot)

	_draw_caption()


# Letterbox: scale to fit thumb_rect keeping aspect, center both axes.
func _draw_letterboxed(thumb_rect: Rect2) -> void:
	var tex_size: Vector2 = _texture.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return
	var fit_scale: float = min(thumb_rect.size.x / tex_size.x, thumb_rect.size.y / tex_size.y)
	var drawn_size: Vector2 = tex_size * fit_scale
	var drawn_pos: Vector2 = thumb_rect.position + (thumb_rect.size - drawn_size) * 0.5
	draw_texture_rect(_texture, Rect2(drawn_pos, drawn_size), false)


func _draw_raw_placeholder(thumb_rect: Rect2) -> void:
	var inset_rect: Rect2 = thumb_rect.grow(-8.0)
	draw_rect(inset_rect, _color_border, true)

	var ext: String = (_photo.get("name", "") as String).get_extension().to_upper()
	if ext.is_empty():
		return
	var font: Font = get_theme_font("font", "Label")
	var font_size: int = get_theme_font_size("font_size", "Label")
	var text_size: Vector2 = font.get_string_size(ext, HORIZONTAL_ALIGNMENT_CENTER, -1.0, font_size)
	var text_pos: Vector2 = thumb_rect.position + (thumb_rect.size - text_size) * 0.5
	text_pos.y += font.get_ascent(font_size)
	draw_string(font, text_pos, ext, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, _color_caption)


func _draw_caption() -> void:
	var name: String = _photo.get("name", "") as String
	if name.is_empty():
		return
	var font: Font = get_theme_font("font", "Label")
	var font_size: int = get_theme_font_size("font_size", "Label")
	var caption_rect := Rect2(Vector2(4.0, size.y - CAPTION_HEIGHT), Vector2(size.x - 8.0, CAPTION_HEIGHT))
	var truncated: String = _truncate_to_width(name, font, font_size, caption_rect.size.x)
	var baseline_y: float = caption_rect.position.y + (CAPTION_HEIGHT + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	draw_string(font, Vector2(caption_rect.position.x, baseline_y), truncated,
		HORIZONTAL_ALIGNMENT_LEFT, caption_rect.size.x, font_size, _color_caption)


# Appends an ellipsis once the string no longer fits max_width.
func _truncate_to_width(text: String, font: Font, font_size: int, max_width: float) -> String:
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x <= max_width:
		return text
	var ellipsis: String = "…"
	var lo: int = 0
	var hi: int = text.length()
	while lo < hi:
		var mid: int = (lo + hi + 1) / 2
		var candidate: String = text.substr(0, mid) + ellipsis
		if font.get_string_size(candidate, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x <= max_width:
			lo = mid
		else:
			hi = mid - 1
	return text.substr(0, lo) + ellipsis


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if mb.double_click:
				activated.emit(_index)
			else:
				clicked.emit(_index, mb.shift_pressed, mb.is_command_or_control_pressed())
			accept_event()
			return
		# Cmd-wheel zooms; plain wheel is left unhandled so the ScrollContainer
		# ancestor still receives it for scrolling.
		if mb.is_command_or_control_pressed():
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				zoom_gestured.emit(1.1)
				accept_event()
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				zoom_gestured.emit(1.0 / 1.1)
				accept_event()
		return

	if event is InputEventMagnifyGesture:
		zoom_gestured.emit(event.factor)
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER:
		_hovered = true
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT:
		_hovered = false
		queue_redraw()
