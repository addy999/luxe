extends VBoxContainer
class_name Filmstrip

# Horizontal filmstrip under the Edit view (Lightroom-style): every photo in
# the current library location, click to open. Collapsible via the arrow
# button; collapsed, the strip keeps only the arrow row so Edit grows back.
#
# Data comes duck-typed from a source object (LibraryView implements these),
# so the strip mirrors the grid's visible list and reuses its texture/badge
# caches without owning any photo state:
#   filmstrip_count() -> int                   (VISIBLE-space count)
#   filmstrip_path(i) -> String                (VISIBLE-space path, "" if oob)
#   filmstrip_texture(path) -> Texture2D       (null if not decoded yet)
#   filmstrip_edited(path) -> bool
#   filmstrip_rejected(path) -> bool
#   request_thumb(vi: int) -> void            (VISIBLE-space; triggers a load)
#
# An undecoded tile shows its extension placeholder and calls
# source.request_thumb(vi) to trigger a load through the grid's own queue
# (same path the grid uses when scrolling); this reaches photos the grid
# itself isn't currently showing, since the strip scrolls independently.
# request_thumb is a no-op for RAW tiles: the background worker process is the
# sole RAW thumbnail producer, and the strip's own refresh_from_cache poll
# picks up the result once it lands on disk. Tiles fill in as thumbs arrive
# (thumb_ready / refresh_from_cache -> update_tile).
#
# Virtualization is the grid's technique at fixed tile size: a recycled pool
# of custom-draw Controls over a Content whose minimum width spans the full
# strip, so the ScrollContainer scrolls the whole list.

signal photo_selected(path: String)

# Fixed tile geometry (no zoom; the grid's zoom slider stays Library-only).
const TILE_WIDTH: float = 114.0
const TILE_HEIGHT: float = 76.0
const SEP: int = 6
const MARGIN: float = 8.0
# Extra tiles kept bound left/right of the viewport so a scroll tick reveals
# ready tiles instead of blanks.
const BUFFER_TILES: int = 8
const TOGGLE_ROW_HEIGHT: float = 18.0

# Duck-typed source (LibraryView). Null before bind_source.
var source: Object = null
# Strip contents shown when true; collapsed shows only the arrow row.
var open: bool = true: set = _set_open

var _selected_path: String = ""
var _arrow: Button
var _scroll: ScrollContainer
var _content: Control
var _strip_area: MarginContainer
var _pool: Array[FilmstripTile] = []   # recycled tiles, all children of _content

# Palette mirrors LibraryTile's in the theme files, re-derived on
# theme_changed. Declared at GDScript's zero default; never used
# uninitialized in the app (the theme always resolves) and headless tests
# never reach _draw().
var _color_tile: Color
var _color_tile_hover: Color
var _color_border: Color
var _color_accent: Color
var _color_caption: Color
var _color_edited_dot: Color
var _color_reject_mark: Color
# Backing for the whole strip (toggle row + scroll area). This node is a plain
# VBoxContainer with no panel, so without painting it the strip shows whatever
# sits behind it (the dark image canvas) in both themes.
var _color_strip_bg: Color


func _ready() -> void:
	if OS.get_cmdline_user_args().has("--thumb-worker"):
		return
	var theme_manager: Node = get_node_or_null("/root/ThemeManager")
	if theme_manager != null:
		theme_manager.theme_changed.connect(_on_theme_changed)
		_update_colors(theme_manager.is_dark)
	else:
		_update_colors(true)

	# Toggle row: a thin strip-wide button row so a click anywhere on it works,
	# not just on the small arrow glyph.
	var toggle_row := Button.new()
	toggle_row.name = "ToggleRow"
	toggle_row.custom_minimum_size = Vector2(0, TOGGLE_ROW_HEIGHT)
	toggle_row.focus_mode = Control.FOCUS_NONE
	toggle_row.flat = true
	toggle_row.text = "▼"
	toggle_row.tooltip_text = "Hide thumbnail strip"
	toggle_row.pressed.connect(_on_arrow_pressed)
	add_child(toggle_row)
	_arrow = toggle_row

	# A MarginContainer, NOT a plain Control: a bare Control never lays out its
	# children, so the ScrollContainer below would keep width 0 and clip every
	# tile (the strip renders as an empty grey box).
	_strip_area = MarginContainer.new()
	_strip_area.name = "StripArea"
	_strip_area.visible = false
	_strip_area.custom_minimum_size = Vector2(0, MARGIN * 2.0 + TILE_HEIGHT)
	_strip_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_strip_area)

	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_strip_area.add_child(_scroll)

	_content = Control.new()
	_content.name = "Content"
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.add_child(_content)

	_scroll.get_h_scroll_bar().value_changed.connect(_on_scrolled)
	# The strip relays out when resized, not just scrolled: it is built while
	# hidden (width 0) and only gets a real viewport size when Edit view shows it.
	_scroll.resized.connect(_relayout)
	_apply_open()


func _on_theme_changed(is_dark: bool) -> void:
	_update_colors(is_dark)
	for tile in _pool:
		tile.queue_redraw()


func _update_colors(_is_dark: bool) -> void:
	# root.theme is swapped on toggle, so the active Theme's "Filmstrip"
	# entries already reflect dark/light; is_dark is unused here.
	if has_theme_color("tile_bg", "Filmstrip"):
		_color_tile = get_theme_color("tile_bg", "Filmstrip")
	if has_theme_color("tile_hover", "Filmstrip"):
		_color_tile_hover = get_theme_color("tile_hover", "Filmstrip")
	if has_theme_color("border", "Filmstrip"):
		_color_border = get_theme_color("border", "Filmstrip")
	if has_theme_color("accent", "Filmstrip"):
		_color_accent = get_theme_color("accent", "Filmstrip")
	if has_theme_color("caption", "Filmstrip"):
		_color_caption = get_theme_color("caption", "Filmstrip")
	if has_theme_color("edited_dot", "Filmstrip"):
		_color_edited_dot = get_theme_color("edited_dot", "Filmstrip")
	if has_theme_color("reject_mark", "Filmstrip"):
		_color_reject_mark = get_theme_color("reject_mark", "Filmstrip")
	if has_theme_color("strip_bg", "Filmstrip"):
		_color_strip_bg = get_theme_color("strip_bg", "Filmstrip")
	queue_redraw()


# Paints the strip's own backing so it follows the active theme instead of
# showing the image canvas behind it.
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _color_strip_bg)


# --- Source binding / external refresh hooks (called by Main.gd) ---------------

# Sets the data source and rebuilds. Also resets the selected tile to the
# currently open photo (selected_path, "" = none).
func bind_source(src: Object, selected_path: String) -> void:
	source = src
	_selected_path = selected_path
	_relayout()


# Re-reads everything (count, paths, textures, badges). Cheap: pool reuse means
# this is O(visible tiles) redraws, no allocation.
func refresh() -> void:
	if source == null:
		return
	_relayout()


# Polled by Main's ThumbnailIndexer while the strip is visible: retries the
# on-disk cache for each visible untextured tile and paints it on a hit. The
# strip can't render RAW thumbs itself (the backend is busy with the edited
# photo), so this disk poll is its only fill path in Edit view.
func refresh_from_cache() -> void:
	if source == null or not open:
		return
	var rng: Vector2i = _visible_range()
	for idx in range(rng.x, rng.y + 1):
		var path: String = source.filmstrip_path(idx)
		if path != "" and source.filmstrip_texture(path) == null:
			if source.fill_path_from_cache(path):
				update_tile(path)


# Pushes one photo's fresh texture into whichever tile shows it (called from
# LibraryView.thumb_ready so tiles fill in as the grid decodes).
func update_tile(path: String) -> void:
	for tile in _pool:
		if tile.get_bound_path() == path:
			tile.set_texture(source.filmstrip_texture(path))


func set_selected(path: String) -> void:
	if _selected_path == path:
		return
	_selected_path = path
	for tile in _pool:
		tile.set_selected(tile.get_bound_path() == path)


# Scrolls the selected tile into view (open_photo / photo cycling).
func reveal_selected() -> void:
	if not open or source == null or _selected_path.is_empty():
		return
	var idx: int = -1
	for i in source.filmstrip_count():
		if source.filmstrip_path(i) == _selected_path:
			idx = i
			break
	if idx < 0:
		return
	var x0: float = MARGIN + idx * (TILE_WIDTH + SEP)
	var x1: float = x0 + TILE_WIDTH
	var vis_l: float = _scroll.scroll_horizontal
	var vis_r: float = vis_l + _scroll.size.x
	if x0 < vis_l:
		_scroll.scroll_horizontal = int(x0)
	elif x1 > vis_r:
		_scroll.scroll_horizontal = int(x1 - _scroll.size.x)


func _on_arrow_pressed() -> void:
	open = not open


func _set_open(value: bool) -> void:
	open = value
	if is_inside_tree():
		_apply_open()


func _apply_open() -> void:
	if _strip_area == null:
		return

	_strip_area.visible = open
	_arrow.text = "▲" if open else "▼"
	_arrow.tooltip_text = "Hide thumbnail strip" if open else "Show thumbnail strip"
	# Rebuild from scratch: a hidden (not freed) pool keeps stale bindings and
	# the scroll range goes stale while hidden; refresh() re-derives both.
	if open:
		_relayout()


func _on_scrolled(_value: float) -> void:
	_refresh_tiles()


# --- Virtualized layout --------------------------------------------------------

func _relayout() -> void:
	if source == null or _content == null:
		return
	var count: int = source.filmstrip_count() if open else 0
	var total_w: float = MARGIN * 2.0 + maxi(0, count) * TILE_WIDTH \
		+ maxi(0, count - 1) * SEP
	# Content's min width spans the full strip so the ScrollContainer scrolls
	# the whole list (same trick as the grid's min-height Content).
	_content.custom_minimum_size = Vector2(maxf(total_w, _scroll.size.x), TILE_HEIGHT)
	_content.size = _content.custom_minimum_size
	_refresh_tiles()


func _visible_range() -> Vector2i:
	var first: int = floori((_scroll.scroll_horizontal - MARGIN) / float(TILE_WIDTH + SEP)) - BUFFER_TILES
	var last: int = ceili((_scroll.scroll_horizontal + _scroll.size.x - MARGIN) / float(TILE_WIDTH + SEP)) + BUFFER_TILES
	return Vector2i(maxi(0, first), mini(source.filmstrip_count() - 1, last))


func _tile_x(i: int) -> float:
	return MARGIN + i * (TILE_WIDTH + SEP)


func _ensure_pool(needed: int) -> void:
	while _pool.size() < needed:
		var tile: FilmstripTile = FilmstripTile.new()
		tile.strip = self
		_content.add_child(tile)
		_pool.append(tile)
	for i in _pool.size():
		_pool[i].visible = i < needed


func _refresh_tiles() -> void:
	if source == null or not open or _content == null:
		for tile in _pool:
			tile.visible = false
		return
	var rng: Vector2i = _visible_range()
	_ensure_pool(maxi(0, rng.y - rng.x + 1))
	for i in _pool.size():
		var tile: FilmstripTile = _pool[i]
		if not tile.visible:
			continue
		var idx: int = rng.x + i
		var path: String = source.filmstrip_path(idx)
		tile.bind(idx, path)
		if path != "" and source.filmstrip_texture(path) == null:
			source.request_thumb(idx)


# Paths currently in the visible-range (plus buffer tiles), for the background
# worker's priority list. Empty when collapsed or unbound. Read-only, no side
# effects.
func get_visible_paths() -> PackedStringArray:
	if source == null or not open:
		return PackedStringArray()
	var rng: Vector2i = _visible_range()
	var result: PackedStringArray = PackedStringArray()
	for i in range(rng.x, rng.y + 1):
		var path: String = source.filmstrip_path(i)
		if path != "":
			result.append(path)
	return result


# --- Tile helpers (called by _Tile) ---------------------------------------------

func tile_texture(path: String) -> Texture2D:
	return source.filmstrip_texture(path) if source != null else null


func tile_edited(path: String) -> bool:
	return source.filmstrip_edited(path) if source != null else false


func tile_rejected(path: String) -> bool:
	return source.filmstrip_rejected(path) if source != null else false


func tile_clicked(index: int, path: String) -> void:
	set_selected(path)
	photo_selected.emit(path)


# Nested class so the strip owns its tile type without a second file; the grid's
# LibraryItem stays untouched.
class FilmstripTile extends Control:
	var strip: Filmstrip = null
	var _index: int = -1
	var _path: String = ""
	var _texture: Texture2D = null
	var _selected: bool = false
	var _hovered: bool = false

	const _EDITED_DOT_RADIUS: float = 4.0
	const _EDITED_DOT_MARGIN: float = 5.0
	const _REJECT_MARK_RADIUS: float = 4.0
	const _REJECT_MARK_MARGIN: float = 5.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		custom_minimum_size = Vector2(Filmstrip.TILE_WIDTH, Filmstrip.TILE_HEIGHT)
		size = custom_minimum_size

	func bind(index: int, path: String) -> void:
		# No early-return on index/path: refresh() rebinds unchanged tiles too,
		# so a tile bound before its thumbnail decoded picks up the texture here.
		var tex: Texture2D = strip.tile_texture(path) if strip != null and path != "" else null
		var sel: bool = strip != null and strip._selected_path == path
		var changed: bool = _index != index or _path != path \
			or _texture != tex or _selected != sel
		_index = index
		_path = path
		_texture = tex
		_selected = sel
		position = Vector2(strip._tile_x(index), Filmstrip.MARGIN)
		if changed:
			queue_redraw()

	func set_texture(tex: Texture2D) -> void:
		_texture = tex
		queue_redraw()

	func set_selected(selected: bool) -> void:
		if _selected == selected:
			return
		_selected = selected
		queue_redraw()

	func get_bound_path() -> String:
		return _path

	func _on_theme_changed(_is_dark: bool) -> void:
		# The strip re-derives its palette and calls queue_redraw on the pool;
		# tiles only need their own redraw.
		queue_redraw()

	func _draw() -> void:
		if strip == null:
			return
		var thumb_rect := Rect2(Vector2.ZERO, size)
		var bg: Color = strip._color_tile_hover if (_selected or _hovered) else strip._color_tile
		draw_rect(thumb_rect, bg, true)

		var photo_path: String = _path
		if photo_path.is_empty():
			return

		if _texture != null:
			var tex_size: Vector2 = _texture.get_size()
			if tex_size.x > 0.0 and tex_size.y > 0.0:
				var fit: float = minf(thumb_rect.size.x / tex_size.x, thumb_rect.size.y / tex_size.y)
				var drawn: Vector2 = tex_size * fit
				var pos: Vector2 = thumb_rect.position + (thumb_rect.size - drawn) * 0.5
				draw_texture_rect(_texture, Rect2(pos, drawn), false)
		else:
			# Extension placeholder (same convention as the grid's RAW tile).
			var ext: String = photo_path.get_extension().to_upper()
			if not ext.is_empty():
				var font: Font = get_theme_font("font", "Label")
				var font_size: int = get_theme_font_size("font_size", "Label")
				var ts: Vector2 = font.get_string_size(ext, HORIZONTAL_ALIGNMENT_CENTER, -1.0, font_size)
				var tp: Vector2 = thumb_rect.position + (thumb_rect.size - ts) * 0.5
				tp.y += font.get_ascent(font_size)
				draw_string(font, tp, ext, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, strip._color_caption)

		# Accent frame last so the thumbnail cannot paint over it; unselected
		# tiles get no border at all (the gap between tiles is the separator).
		if _selected:
			draw_rect(Rect2(Vector2.ONE, size - Vector2(2.0, 2.0)),
				strip._color_accent, false, 2.0)

		# Badges mirror the grid: edited dot top-right, reject mark top-left.
		if strip.tile_edited(photo_path):
			var dc := Vector2(
				thumb_rect.end.x - _EDITED_DOT_MARGIN - _EDITED_DOT_RADIUS,
				thumb_rect.position.y + _EDITED_DOT_MARGIN + _EDITED_DOT_RADIUS)
			draw_circle(dc, _EDITED_DOT_RADIUS, strip._color_edited_dot)
		if strip.tile_rejected(photo_path):
			var rc := Vector2(
				thumb_rect.position.x + _REJECT_MARK_MARGIN + _REJECT_MARK_RADIUS,
				thumb_rect.position.y + _REJECT_MARK_MARGIN + _REJECT_MARK_RADIUS)
			draw_circle(rc, _REJECT_MARK_RADIUS, strip._color_reject_mark)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			strip.tile_clicked(_index, _path)
			accept_event()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_ENTER:
			_hovered = true
			queue_redraw()
		elif what == NOTIFICATION_MOUSE_EXIT:
			_hovered = false
			queue_redraw()