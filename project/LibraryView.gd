extends HBoxContainer
class_name LibraryView

# Library photo-browsing view: a sidebar of scan locations and a virtualized
# thumbnail grid for the selected location. Main.gd instances this scene and
# listens for photo_activated to switch into the editor.
#
# Virtualization: instead of one Control per photo (thousands of nodes + a
# texture cap that thrashed on scroll), a small recycled tile pool covers only
# the visible rows plus a buffer. Tiles are children of `Content`, a plain
# Control whose minimum height equals the full virtual grid so the
# ScrollContainer still scrolls the whole list. Decoded textures live in a
# path-keyed LRU (`_tex_cache`) that outlives tile recycling, so scrolling
# back over recently-seen photos is instant with no re-decode.

signal photo_activated(path: String)
# Mirrors the sidebar CountLabel text; Main.gd routes this to a bottom-bar label.
signal status_changed(status: String)
signal add_location_requested()
# Multiplicative zoom request (centered on 1.0), same convention as Main.gd's
# _zoom_by_factor. Emitted by pinch/Cmd-wheel gestures over tiles or empty grid area.
signal zoom_requested(factor: float)
# The cursor photo's reject flag changed (toggled, cursor moved, or filter
# remapped) so the TopBar reject control can mirror it.
signal cursor_reject_state(rejected: bool)
# A reject flag was toggled; Main invalidates anything derived from it.
signal reject_toggled(path: String, rejected: bool)
# Photo list, badges, or textures changed in any way the filmstrip cares about
# (rescan, filter toggle, reject toggle, thumb decoded).
signal photos_changed()
# The saved library location set changed (added or removed); Main.gd re-targets
# the background thumbnail worker at the new root set.
signal locations_changed()

const LibraryItemScript := preload("res://LibraryItem.gd")

const THUMB_WORKERS: int = 2
# Decoded textures held in memory, keyed by path. The virtualized grid only
# ever shows a few dozen tiles, so this is a scroll-back cache, not a 1:1 map.
const MAX_CACHE_TEXTURES: int = 400
# Extra rows kept bound above and below the viewport so a flick reveals ready
# tiles instead of blanks.
const BUFFER_ROWS: int = 2
const _THUMB_DEBOUNCE_SEC: float = 0.1
const _GRID_MARGIN: float = 16.0

@onready var locations_vbox: VBoxContainer = $Sidebar/SidebarMargin/SidebarVBox/LocationsVBox
@onready var add_location_button: Button = $Sidebar/SidebarMargin/SidebarVBox/AddLocationButton
@onready var grid_scroll: ScrollContainer = $GridPanel/GridScroll
@onready var content: Control = $GridPanel/GridScroll/Content
@onready var empty_state: CenterContainer = $EmptyState

var _add_location_dialog: FileDialog = null
var _thumb_timer: Timer = null

var _locations: PackedStringArray = PackedStringArray()
var _selected_location: String = ""

var _photos: Array[Dictionary] = []
var _cursor: int = -1
# RAW (continuous) zoom, the persistence source of truth; never snapped.
var _thumb_raw_scale: float = 1.0
# Effective snapped scale used for layout; always re-derived from
# _thumb_raw_scale + current grid width, never snapped in place (chained
# snapping at a stale/hidden width drifts and reads as a zoom reset).
var _thumb_scale: float = 1.0

var _scan_generation: int = 0
var _scanning: bool = false

# --- Virtualized layout --------------------------------------------------------
var _pool: Array[LibraryItem] = []   # recycled tiles, bound to visible indices
var _cols: int = 1
var _tile_w: float = 0.0
var _tile_h: float = 0.0

# --- Texture cache (path-keyed LRU) --------------------------------------------
var _tex_cache: Dictionary = {}      # path -> Texture2D
var _tex_lru: Array[String] = []     # oldest first; access moves to the back
# Paths with an in-flight request, so a scroll tick doesn't re-queue them.
var _requested: Dictionary = {}      # path -> true

# --- Edited-badge cache --------------------------------------------------------
# path -> bool: whether a saved EditStore record exists for this photo. Computed
# once per photo when its thumbnail first becomes ready (the badge needs the
# on-disk thumb hash, same identity as the edit key), then redrawn with the tile.
var _edited: Dictionary = {}

# --- Reject flags / hide-rejected filter ---------------------------------------
var _rejected: Dictionary = {}        # path -> bool (session display truth)
var _reject_pending: Dictionary = {}  # path -> bool: toggled before thumb on disk; flushed on thumb-ready
var _reject_set: Dictionary = {}      # persisted key-set from RejectStore.load_set
var _hide_rejected: bool = false
# Master indices currently displayed (identity map when the filter is off).
# All display/geometry code walks this; the caches above stay keyed by
# path/master-index and are never cleared by a filter toggle.
var _visible: Array[int] = []

# --- Bounded thumbnail workers (jpg/png decode) --------------------------------
var _queue: Array[int] = []
var _inflight: int = 0
var _mutex: Mutex = Mutex.new()


func _ready() -> void:
	if OS.get_cmdline_user_args().has("--thumb-worker"):
		return
	# Resolved by node path, not the ThemeManager identifier: autoloads are not
	# registered in --script mode, where a direct identifier fails to compile.
	var theme_manager: Node = get_node_or_null("/root/ThemeManager")
	if theme_manager != null:
		theme_manager.theme_changed.connect(_on_theme_changed)

	# Keyboard focus and key handling live on Content (the ScrollContainer eats
	# arrow/scroll keys if focused); tiles have FOCUS_NONE so focus stays here.
	content.focus_mode = Control.FOCUS_ALL
	content.mouse_filter = Control.MOUSE_FILTER_STOP
	content.gui_input.connect(_on_grid_gui_input)
	grid_scroll.resized.connect(_on_grid_scroll_resized)
	grid_scroll.get_v_scroll_bar().value_changed.connect(_on_grid_scroll_changed)
	_style_scrollbar()

	_thumb_timer = Timer.new()
	_thumb_timer.one_shot = true
	_thumb_timer.timeout.connect(_on_thumb_timer_timeout)
	add_child(_thumb_timer)

	add_location_button.focus_mode = Control.FOCUS_NONE
	add_location_button.pressed.connect(_on_add_location_button_pressed)

	_setup_add_location_dialog()

	_locations = Library.load_locations()
	_reject_set = RejectStore.load_set()
	_rebuild_sidebar()
	if _locations.size() > 0:
		_select_location(_locations[0])
	else:
		_update_status("No photos yet")


func _style_scrollbar() -> void:
	# Colors/rounding come from the shared theme (scroll_* styleboxes); only the
	# bar thickness is per-ScrollContainer. See ScrollbarStyle.WIDTH.
	ScrollbarStyle.widen(grid_scroll)


func on_view_entered() -> void:
	content.grab_focus()
	_relayout()
	_request_visible_thumbs()


# Grid count/lookup are VISIBLE-space: the hide-rejected filter may shrink the
# grid below _photos.size().
func get_photo_count() -> int:
	return _visible.size()


# Returns the photo dict at the VISIBLE index, or an empty Dictionary if out
# of range.
func get_photo(index: int) -> Dictionary:
	if index < 0 or index >= _visible.size():
		return {}
	return _photos[_visible[index]]


func _on_theme_changed(_is_dark: bool) -> void:
	for tile in _pool:
		tile.queue_redraw()


# --- Status ---------------------------------------------------------------------

func _update_status(status: String) -> void:
	status_changed.emit(status)


# --- Add-location dialog ---------------------------------------------------------

func _setup_add_location_dialog() -> void:
	_add_location_dialog = FileDialog.new()
	_add_location_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_add_location_dialog.access = FileDialog.ACCESS_FILESYSTEM
	# NOT the native dialog: on macOS it returns dir paths with ".*" appended
	# (the selection is round-tripped through the filename+filter machinery).
	_add_location_dialog.use_native_dialog = true
	_add_location_dialog.title = "Choose a Folder"
	_add_location_dialog.dir_selected.connect(_on_add_location_dir_selected)
	add_child(_add_location_dialog)


func _on_add_location_button_pressed() -> void:
	_add_location_dialog.popup_centered()


func _on_add_location_dir_selected(dir_path: String) -> void:
	dir_path = _normalize_location_path(dir_path)
	if _is_duplicate_or_nested(dir_path):
		_update_status("Already added")
		return
	_locations.append(dir_path)
	Library.save_locations(_locations)
	locations_changed.emit()
	_rebuild_sidebar()
	_select_location(dir_path)


# Cleans dialog-returned paths: file:// URIs, surrounding quotes/whitespace,
# trailing slashes, and the native macOS dialog's ".*" suffix quirk (the
# selection is round-tripped through the filename+filter machinery, so
# "/photos/EU" comes back as "/photos/EU.*"). The suffix is only stripped
# when the un-mangled path exists, so a folder genuinely named "foo.*" is kept.
func _normalize_location_path(dir_path: String) -> String:
	var p: String = dir_path.strip_edges().strip_escapes()
	p = p.trim_prefix("file://")
	p = p.trim_suffix("/")
	if not DirAccess.dir_exists_absolute(p) and p.ends_with(".*"):
		var stripped: String = p.substr(0, p.length() - 2)
		if DirAccess.dir_exists_absolute(stripped):
			return stripped
	return p


# Rejects exact duplicates and any nesting relationship (either direction).
func _is_duplicate_or_nested(dir_path: String) -> bool:
	for existing in _locations:
		if existing == dir_path:
			return true
		if dir_path.begins_with(existing.path_join("")) or existing.begins_with(dir_path.path_join("")):
			return true
	return false


func _on_remove_location_pressed(dir_path: String) -> void:
	var idx: int = _locations.find(dir_path)
	if idx < 0:
		return
	_locations.remove_at(idx)
	Library.save_locations(_locations)
	locations_changed.emit()
	if _selected_location == dir_path:
		_selected_location = ""
		_set_photos([])
		if _locations.size() > 0:
			_select_location(_locations[0])
		else:
			_update_status("No photos yet")
	_rebuild_sidebar()


# --- Sidebar ---------------------------------------------------------------------

func _rebuild_sidebar() -> void:
	# remove_child detaches immediately, unlike queue_free alone, which only
	# defers deletion: without the immediate detach, rows added below would
	# share the VBox with the still-attached old rows until end of frame.
	for child in locations_vbox.get_children():
		locations_vbox.remove_child(child)
		child.queue_free()

	for dir_path: String in _locations:
		locations_vbox.add_child(_build_location_row(dir_path))


func _build_location_row(dir_path: String) -> Button:
	var missing: bool = not DirAccess.dir_exists_absolute(dir_path)
	var label_text: String = dir_path.get_file()
	if label_text.is_empty():
		label_text = dir_path
	if missing:
		label_text += " (missing)"

	var select_btn := Button.new()
	select_btn.theme_type_variation = &"SidebarItem"
	select_btn.focus_mode = Control.FOCUS_NONE
	select_btn.text = label_text
	select_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	select_btn.toggle_mode = true
	select_btn.button_pressed = (dir_path == _selected_location)
	select_btn.disabled = missing
	select_btn.clip_text = true
	select_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	select_btn.pressed.connect(_select_location.bind(dir_path))

	# The × sits inside the pill (right-anchored) so the whole row stays one
	# hover/click surface; its own rect takes priority for its 28px.
	var remove_btn := Button.new()
	remove_btn.flat = true
	remove_btn.focus_mode = Control.FOCUS_NONE
	remove_btn.text = "×"
	remove_btn.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	remove_btn.custom_minimum_size = Vector2(28, 0)
	remove_btn.offset_left = -34.0
	remove_btn.offset_right = -6.0
	remove_btn.pressed.connect(_on_remove_location_pressed.bind(dir_path))
	select_btn.add_child(remove_btn)

	return select_btn


func _select_location(dir_path: String) -> void:
	_selected_location = dir_path
	_rebuild_sidebar()
	_scan_selected_location()


# Finds the configured location containing path (prefix match, same
# normalized form as _is_duplicate_or_nested) and selects it if it isn't
# already selected. Used on launch to re-home the sidebar/grid/filmstrip on
# whichever library the restored last-opened photo actually belongs to,
# instead of always defaulting to _locations[0]. Returns false (no-op) if no
# configured location contains path.
func select_location_for_path(path: String) -> bool:
	for loc: String in _locations:
		if path == loc or path.begins_with(loc.path_join("")):
			if loc != _selected_location:
				_select_location(loc)
			return true
	return false


# --- Scanning ---------------------------------------------------------------------

func _scan_selected_location() -> void:
	if _selected_location.is_empty() or not DirAccess.dir_exists_absolute(_selected_location):
		_set_photos([])
		_update_status("location missing")
		return

	_scan_generation += 1
	var generation: int = _scan_generation
	_scanning = true
	_update_status("Scanning…")

	var dir_path: String = _selected_location
	WorkerThreadPool.add_task(_scan_task.bind(dir_path, generation))


func _scan_task(dir_path: String, generation: int) -> void:
	var results: Array[Dictionary] = Library.scan_location(dir_path)
	call_deferred("_on_scan_done", results, generation)


func _on_scan_done(results: Array[Dictionary], generation: int) -> void:
	if generation != _scan_generation:
		return
	_scanning = false
	_set_photos(results)
	_update_status("%d photos" % _photos.size() if _photos.size() != 1 else "1 photo")
	if _photos.is_empty():
		_update_status("No photos yet")


# --- Photo list / grid reset ---------------------------------------------------

# Recomputes the visible index map from the current reject flags + filter.
# Must run whenever _photos is swapped or a reject/filter toggle changes
# membership; display code reads only _visible afterwards.
func _rebuild_visible() -> void:
	_visible = Library.visible_indices(_photos, _rejected, _hide_rejected)


# Swaps the displayed photo set and resets the virtualized grid: drops cached
# textures (they belong to the old list), clears in-flight requests, rewinds
# the scroll and cursor, then relays out. Session reject state (_rejected,
# _reject_pending) belongs to the old set too; the PERSISTED set (_reject_set)
# spans locations and survives, so re-displayed photos re-seed from it.
func _set_photos(photos: Array[Dictionary]) -> void:
	_photos = photos
	_cursor = -1
	_tex_cache.clear()
	_tex_lru.clear()
	_requested.clear()
	_edited.clear()
	_rejected.clear()
	_reject_pending.clear()
	_mutex.lock()
	_queue.clear()
	_mutex.unlock()
	for tile in _pool:
		tile.clear_texture()
	# Rebuild _visible BEFORE touching scroll_vertical: assigning it fires the
	# ScrollContainer's value_changed signal synchronously into
	# _on_grid_scroll_changed -> _refresh_tiles, which indexes _photos via
	# _visible. A stale _visible (sized for the old _photos) would then index
	# out of bounds into the just-reassigned, possibly smaller _photos.
	_rebuild_visible()
	grid_scroll.scroll_vertical = 0
	photos_changed.emit()
	empty_state.visible = _photos.is_empty()
	_relayout()
	_request_visible_thumbs()


# --- Thumbnail zoom ------------------------------------------------------------

func set_thumb_zoom(scale: float) -> void:
	_thumb_raw_scale = scale
	var snapped: float = snap_thumb_scale(scale)
	if is_equal_approx(snapped, _thumb_scale):
		return
	_thumb_scale = snapped
	for tile in _pool:
		tile.set_tile_scale(snapped)
	_relayout()
	if _cursor >= 0:
		_scroll_cursor_into_view()
	_request_visible_thumbs()


# --- Layout --------------------------------------------------------------------

func _on_grid_scroll_resized() -> void:
	_relayout()
	_request_visible_thumbs()


func snap_thumb_scale(scale: float) -> float:
	var sep: float = float(LibraryItemScript.GROUP_SEP)
	return snap_scale(scale, grid_scroll.size.x - _GRID_MARGIN * 2.0 + sep)


# Returns the scale nearest `scale` at which an integer column count exactly
# fills the width (cols*tile_w + (cols-1)*sep == avail_w - sep), so zoom only
# steps through gap-free levels instead of a continuous scale with a partial
# column on the right. One candidate scale per column count.
static func snap_scale(scale: float, avail_w: float) -> float:
	const MIN_SCALE: float = 0.5
	const MAX_SCALE: float = 4.0
	var sep: float = float(LibraryItemScript.GROUP_SEP)
	# Widest possible tile (MIN_SCALE) bounds the smallest column count.
	var max_cols: int = maxi(1, int(floor(avail_w / (LibraryItemScript.TILE_SIZE.x * MIN_SCALE + sep))))
	var best: float = scale
	var best_diff: float = INF
	for cols in range(max_cols, 0, -1):
		var s: float = (avail_w - cols * sep) / (cols * LibraryItemScript.TILE_SIZE.x)
		if s < MIN_SCALE or s > MAX_SCALE:
			continue
		var diff: float = absf(s - scale)
		if diff < best_diff:
			best = s
			best_diff = diff
	return best


# Recomputes tile dimensions, column count and the virtual content height, then
# rebinds the pool to the current visible range.
func _relayout() -> void:
	# Re-derive the snapped scale from the RAW one at the CURRENT width:
	# stale widths while hidden (Edit view) or any resize then re-anchor to
	# the nearest gap-free level instead of drifting from a snapped value.
	_thumb_scale = snap_thumb_scale(_thumb_raw_scale)
	_tile_w = LibraryItemScript.TILE_SIZE.x * _thumb_scale
	_tile_h = LibraryItemScript.THUMB_SIZE * _thumb_scale + LibraryItemScript.CAPTION_HEIGHT

	var sep: float = float(LibraryItemScript.GROUP_SEP)
	var avail_w: float = grid_scroll.size.x - _GRID_MARGIN * 2.0 + sep
	# round, not floor: snapped scales fill exactly, so the ratio is an integer
	# and float error on either side must not drop a column.
	_cols = maxi(1, int(round(avail_w / (_tile_w + sep))))

	var count: int = _visible.size()
	var rows: int = int(ceil(float(count) / float(_cols))) if count > 0 else 0
	var total_h: float = 0.0
	if rows > 0:
		total_h = _GRID_MARGIN * 2.0 + rows * _tile_h + maxf(0.0, rows - 1) * sep
	# Only the height matters for scrolling; the ScrollContainer stretches
	# Content to the viewport width (horizontal scroll is disabled).
	content.custom_minimum_size = Vector2(0.0, total_h)

	_refresh_tiles()


# Returns [start, end) VISIBLE indices that should have a live tile, including
# the buffer rows above and below the viewport.
func _visible_index_range() -> Vector2i:
	var count: int = _visible.size()
	if count == 0 or _cols <= 0:
		return Vector2i(0, 0)
	var sep: float = float(LibraryItemScript.GROUP_SEP)
	var row_h: float = _tile_h + sep
	if row_h <= 0.0:
		return Vector2i(0, 0)

	var scroll_v: float = grid_scroll.scroll_vertical
	var vh: float = grid_scroll.size.y
	var first_row: int = int(floor((scroll_v - _GRID_MARGIN) / row_h)) - BUFFER_ROWS
	var last_row: int = int(floor((scroll_v + vh - _GRID_MARGIN) / row_h)) + BUFFER_ROWS

	var total_rows: int = int(ceil(float(count) / float(_cols)))
	first_row = clampi(first_row, 0, total_rows - 1)
	last_row = clampi(last_row, 0, total_rows - 1)

	var start: int = first_row * _cols
	var end: int = mini(count, (last_row + 1) * _cols)
	return Vector2i(start, end)


func _tile_position(index: int) -> Vector2:
	var sep: float = float(LibraryItemScript.GROUP_SEP)
	var col: int = index % _cols
	var row: int = index / _cols
	return Vector2(
		_GRID_MARGIN + col * (_tile_w + sep),
		_GRID_MARGIN + row * (_tile_h + sep))


func _ensure_pool(size: int) -> void:
	while _pool.size() < size:
		var tile := LibraryItemScript.new()
		tile.set_tile_scale(_thumb_scale)
		tile.clicked.connect(_on_item_clicked)
		tile.activated.connect(_on_item_activated)
		tile.zoom_gestured.connect(_on_item_zoom_gestured)
		content.add_child(tile)
		_pool.append(tile)


# Binds pool tiles to the visible index range: positions them, pulls textures
# from the cache, and marks the cursor tile selected. Cheap enough to run on
# every scroll tick (only a few dozen tiles). `vi` is a VISIBLE index (what
# the tile stores); `index` = _visible[vi] is its master index, used for cache
# and badge keys so those stay stable across filter toggles.
func _refresh_tiles() -> void:
	if _visible.is_empty():
		for tile in _pool:
			tile.visible = false
		return

	var r: Vector2i = _visible_index_range()
	var need: int = r.y - r.x
	_ensure_pool(need)

	var slot: int = 0
	for vi in range(r.x, r.y):
		var index: int = _visible[vi]
		var path: String = _photos[index]["path"]
		var tile: LibraryItem = _pool[slot]
		# Rebind when the slot's visible index OR its bound photo changed: a
		# filter rebuild keeps the same `vi` but repoints it at a new master
		# photo, so the index check alone would leave the stale texture up.
		if tile.get_photo_index() != vi or tile.get_bound_path() != path:
			tile.setup(vi, _photos[index])
			if _tex_cache.has(path):
				tile.set_texture(_cache_get(path))
			else:
				tile.clear_texture()
		# Content is a plain Control, not a layout container, so tile size never
		# tracks custom_minimum_size on its own; set scale AND size explicitly
		# every refresh or _draw uses a stale size and clips the thumbnail.
		tile.set_tile_scale(_thumb_scale)
		tile.size = Vector2(_tile_w, _tile_h)
		tile.set_selected(vi == _cursor)
		tile.set_edited(_edited.get(_photos[index]["path"], false))
		tile.set_rejected(_rejected.get(_photos[index]["path"], false))
		tile.set_dim_enabled(not _hide_rejected)
		tile.position = _tile_position(vi)
		tile.visible = true
		slot += 1

	for i in range(need, _pool.size()):
		_pool[i].visible = false


func _on_item_clicked(index: int) -> void:
	_set_cursor(index)


func _on_item_activated(index: int) -> void:
	_set_cursor(index)
	_activate(index)


func _on_item_zoom_gestured(factor: float) -> void:
	zoom_requested.emit(factor)


# --- Keyboard navigation ------------------------------------------------------------

func _on_grid_gui_input(event: InputEvent) -> void:
	if event is InputEventMagnifyGesture:
		zoom_requested.emit(event.factor)
		accept_event()
		return

	if not (event is InputEventKey) or not event.pressed:
		return
	var key_event: InputEventKey = event
	var cols: int = maxi(1, _cols)
	var count: int = _visible.size()
	var handled: bool = true

	match key_event.keycode:
		KEY_LEFT:
			_set_cursor(Library.next_index(_cursor, -1, 0, cols, count))
		KEY_RIGHT:
			_set_cursor(Library.next_index(_cursor, 1, 0, cols, count))
		KEY_UP:
			_set_cursor(Library.next_index(_cursor, 0, -1, cols, count))
		KEY_DOWN:
			_set_cursor(Library.next_index(_cursor, 0, 1, cols, count))
		KEY_HOME:
			_set_cursor(0 if count > 0 else -1)
		KEY_END:
			_set_cursor(count - 1 if count > 0 else -1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			_activate(_cursor)
		KEY_X:
			toggle_reject_cursor()
		_:
			handled = false

	if handled:
		accept_event()


func _set_cursor(index: int) -> void:
	if index == _cursor:
		return
	_cursor = index
	if _cursor >= 0:
		_scroll_cursor_into_view()
	_refresh_tiles()
	_request_visible_thumbs()
	cursor_reject_state.emit(_cursor_rejected())


# Scrolls the minimum amount to bring the cursor's row fully into view.
func _scroll_cursor_into_view() -> void:
	if _cols <= 0 or _cursor < 0:
		return
	var sep: float = float(LibraryItemScript.GROUP_SEP)
	var row: int = _cursor / _cols
	var y_top: float = _GRID_MARGIN + row * (_tile_h + sep)
	var y_bottom: float = y_top + _tile_h
	var scroll_v: float = grid_scroll.scroll_vertical
	var vh: float = grid_scroll.size.y
	if y_top < scroll_v:
		grid_scroll.scroll_vertical = int(y_top)
	elif y_bottom > scroll_v + vh:
		grid_scroll.scroll_vertical = int(y_bottom - vh)


func _activate(index: int) -> void:
	# `index` is VISIBLE-space (tiles store visible indices; _cursor is one).
	if index < 0 or index >= _visible.size():
		return
	photo_activated.emit(_photos[_visible[index]]["path"])


# --- Thumbnail loading ---------------------------------------------------------------

func _on_grid_scroll_changed(_value: float) -> void:
	# Rebind tiles immediately so correct images track the scroll; defer the
	# (debounced) request dispatch for anything not yet cached.
	_refresh_tiles()
	_request_visible_thumbs()


# Debounced: scroll/resize events fire rapidly, so the actual request dispatch
# runs once per _THUMB_DEBOUNCE_SEC.
func _request_visible_thumbs() -> void:
	if _thumb_timer.is_stopped():
		_thumb_timer.start(_THUMB_DEBOUNCE_SEC)


func _on_thumb_timer_timeout() -> void:
	if _photos.is_empty():
		return

	var r: Vector2i = _visible_index_range()
	for vi in range(r.x, r.y):
		_request_thumb_for_visible(vi)


# Requests a thumbnail for one VISIBLE index, if not already cached or
# in flight. Shared by the debounced grid-scroll dispatch above and by
# request_thumb() below (the filmstrip's own visible range can extend
# beyond the grid's current viewport, since it scrolls independently).
# RAW and JPG both go through the in-process queue; _thumb_task branches on
# is_raw: a JPG is decoded in-process if not cached, a RAW is DISK-CACHE-ONLY
# (the background worker process is the sole RAW renderer, this just loads
# whatever the worker already wrote so cached RAW tiles display even after the
# worker has exited, without any backend contention). The queue takes the MASTER
# index `index` because its worker (_pump/_thumb_task/_on_thumb_ready) reads
# _photos directly.
func _request_thumb_for_visible(vi: int) -> void:
	if vi < 0 or vi >= _visible.size():
		return
	var index: int = _visible[vi]
	var path: String = _photos[index]["path"]
	if _tex_cache.has(path):
		return
	if _requested.has(path):
		return
	_requested[path] = true
	# push_front, not append: prioritizes the newest request so whatever's
	# currently in view stays responsive first under a fast-scroll backlog.
	_mutex.lock()
	_queue.push_front(index)
	_mutex.unlock()
	_pump()


# Public entry point for the filmstrip (or any other visible-space client)
# to trigger a thumbnail load directly, without waiting for the grid to
# scroll the same index into its own viewport.
func request_thumb(vi: int) -> void:
	_request_thumb_for_visible(vi)


# Polled by Main's ThumbnailIndexer: retries ThumbnailCache.load_cached for
# each currently-visible untextured tile in case the background worker wrote
# it since the last check. A hit is applied the same way as an in-process
# render (cache_put + apply + _requested erase), so it doesn't fight the RAW
# pump if that resolves the same path. No-ops when every tile is textured.
func refresh_visible_from_cache() -> void:
	if _visible.is_empty():
		return
	var r: Vector2i = _visible_index_range()
	var any_filled: bool = false
	for vi in range(r.x, r.y):
		if _fill_master_from_cache(_visible[vi]):
			any_filled = true
	if any_filled:
		photos_changed.emit()


# Loads one photo's thumbnail from the on-disk cache into _tex_cache by PATH
# (resolves the master index), for callers that only know the path. Returns
# true if a texture became available. Emits photos_changed on a fresh fill.
func fill_path_from_cache(path: String) -> bool:
	if path == "" or _tex_cache.has(path):
		return _tex_cache.has(path)
	var master: int = get_photo_index_master(path)
	if master < 0:
		return false
	if _fill_master_from_cache(master):
		photos_changed.emit()
		return true
	return false


# Core disk-cache fill for one master-indexed photo: no-op if already cached or
# not yet written. Otherwise decodes, caches, clears the in-flight flag, and
# repaints the tile. Returns true only on a fresh fill. Does not emit
# photos_changed (callers batch that).
func _fill_master_from_cache(master: int) -> bool:
	var photo: Dictionary = _photos[master]
	var path: String = photo["path"]
	if _tex_cache.has(path):
		return false
	var key: String = ThumbnailCache.cache_key(path, photo["mtime"])
	var img: Image = ThumbnailCache.load_cached(key)
	if img == null:
		return false
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_cache_put(path, tex)
	_requested.erase(path)
	if _mark_edited(photo):
		_reapply_hide_filter()
	_apply_texture_to_master(master)
	return true


func _pump() -> void:
	_mutex.lock()
	while _inflight < THUMB_WORKERS and not _queue.is_empty():
		var index: int = _queue.pop_front()
		_inflight += 1
		var generation: int = _scan_generation
		var photo: Dictionary = _photos[index]
		WorkerThreadPool.add_task(_thumb_task.bind(photo, index, generation))
	_mutex.unlock()


# Runs off the main thread: no scene node access, only Library/ThumbnailCache statics.
# JPG/PNG: load from cache, else decode in-process. RAW: load from cache ONLY
# (Image.load_from_file can't decode a RAW, and rendering one needs the backend,
# which belongs to the worker process); a cache miss returns null and the tile
# stays a placeholder until the worker renders it (then the indexer poll or a
# later re-request fills it).
func _thumb_task(photo: Dictionary, index: int, generation: int) -> void:
	var path: String = photo["path"]
	var mtime: int = photo["mtime"]
	var key: String = ThumbnailCache.cache_key(path, mtime)
	var img: Image = ThumbnailCache.load_cached(key)
	if img == null and not photo.get("is_raw", false):
		img = ThumbnailCache.build_thumbnail(path, key)
	call_deferred("_on_thumb_ready", generation, index, img)


func _on_thumb_ready(generation: int, index: int, img: Image) -> void:
	_mutex.lock()
	_inflight -= 1
	_mutex.unlock()

	# `index` is MASTER-space (that is what _on_thumb_timer_timeout queued).
	if generation == _scan_generation and index >= 0 and index < _photos.size():
		var path: String = _photos[index]["path"]
		_requested.erase(path)
		if img != null:
			var tex: ImageTexture = ImageTexture.create_from_image(img)
			_cache_put(path, tex)
			if _mark_edited(_photos[index]):
				_reapply_hide_filter()
			_apply_texture_to_master(index)
			photos_changed.emit()

	_pump()


# Records whether a saved edit or a reject flag exists for `photo`, keyed by
# the on-disk thumb hash (same identity as the edit/reject keys). Computed once
# per photo; the thumbnail is already on disk by the time this runs (called
# from the thumb-ready paths). Also flushes a deferred reject toggle (made
# before the thumb was on disk) once the hash becomes resolvable.
# Returns true when this call changed the photo's rejected state, so callers
# can rebuild the visible map (the flag is resolved lazily here, long after the
# scan, and a photo that resolves to rejected must leave a hiding grid).
func _mark_edited(photo: Dictionary) -> bool:
	var path: String = photo["path"]
	# Edited AND rejected state already known with nothing pending: skip, so
	# the on-disk thumb load below stays once per photo.
	if _edited.has(path) and _rejected.has(path) and not _reject_pending.has(path):
		return false
	var cache_key: String = ThumbnailCache.cache_key(path, photo["mtime"])
	var img: Image = ThumbnailCache.load_cached(cache_key)
	if img == null:
		return false
	var was: bool = _rejected.get(path, false)
	var hash: String = EditStore.thumb_hash(img)
	if not _edited.has(path):
		_edited[path] = EditStore.has_record(path.get_file(), hash)
	var key: String = EditStore.edit_key(path.get_file(), hash)
	if _reject_pending.has(path):
		var want: bool = _reject_pending[path]
		_reject_pending.erase(path)
		_set_reject_persisted(key, want)
		_rejected[path] = want
	elif not _rejected.has(path):
		_rejected[path] = _reject_set.has(key)
	return _rejected.get(path, false) != was


# Rebuilds the visible map after a lazily-resolved reject flag changed, but
# only while hiding (the map is the identity otherwise). Keeps the cursor on
# its photo by path across the remap.
func _reapply_hide_filter() -> void:
	if not _hide_rejected:
		return
	var cursor_path: String = ""
	if _cursor >= 0 and _cursor < _visible.size():
		cursor_path = _photos[_visible[_cursor]]["path"]
	_rebuild_visible()
	_cursor = -1
	if cursor_path != "":
		for vi in range(_visible.size()):
			if _photos[_visible[vi]]["path"] == cursor_path:
				_cursor = vi
				break
	if _cursor < 0 and not _visible.is_empty():
		_cursor = 0
	_relayout()


# Recomputes a single photo's edited badge (e.g. after returning from the editor
# where it may have just gained a saved record) and redraws its tile if visible.
func refresh_edited_badge(path: String) -> void:
	_edited.erase(path)
	var mi: int = _master_index_of(path)
	if mi < 0:
		return
	if _mark_edited(_photos[mi]):
		_reapply_hide_filter()
	_apply_texture_to_master(mi)
	photos_changed.emit()
	for tile in _pool:
		var vi: int = tile.get_photo_index()
		if tile.visible and vi >= 0 and vi < _visible.size() and _visible[vi] == mi:
			tile.set_edited(_edited.get(path, false))
			return


# Pushes a cached texture onto whichever pool tile currently displays this
# MASTER index. Tiles store visible indices, so the match resolves through the
# _visible map; a tile still holding a stale visible index from before a
# filter change resolves to a different master index and won't match.
func _apply_texture_to_master(master_index: int) -> void:
	if master_index < 0 or master_index >= _photos.size():
		return
	var path: String = _photos[master_index]["path"]
	for tile in _pool:
		var vi: int = tile.get_photo_index()
		if tile.visible and vi >= 0 and vi < _visible.size() and _visible[vi] == master_index:
			tile.set_texture(_cache_get(path))
			return


# --- Reject flags / hide-rejected filter ---------------------------------------

# Toggles the cursor photo's rejected state. No-op if no photo is selected.
func toggle_reject_cursor() -> void:
	if _cursor < 0 or _cursor >= _visible.size():
		return
	_toggle_reject_path(_photos[_visible[_cursor]]["path"])


# Public entry for toggling a specific photo's rejected state from outside the
# grid (Main's Edit-view reject button / 'x' key), by path rather than cursor.
func toggle_reject_path(path: String) -> void:
	if _master_index_of(path) < 0:
		return
	_toggle_reject_path(path)


func _toggle_reject_path(path: String) -> void:
	var now: bool = not _rejected.get(path, false)
	_rejected[path] = now
	# Persist now when the on-disk thumb hash is resolvable; else defer to the
	# thumb-ready flush in _mark_edited.
	var resolved: bool = false
	var mi: int = _master_index_of(path)
	if mi >= 0:
		var photo: Dictionary = _photos[mi]
		var img: Image = ThumbnailCache.load_cached(ThumbnailCache.cache_key(path, photo["mtime"]))
		if img != null:
			_set_reject_persisted(EditStore.edit_key(path.get_file(), EditStore.thumb_hash(img)), now)
			resolved = true
	if not resolved:
		_reject_pending[path] = now
	if _hide_rejected:
		# Membership may have changed (rejected leaves the visible set,
		# un-rejected rejoins it): rebuild the map + clamp the cursor.
		_rebuild_visible()
		if _cursor >= _visible.size():
			_cursor = _visible.size() - 1
		_relayout()
		_request_visible_thumbs()
		photos_changed.emit()
	else:
		# Still visible: refresh just the tile displaying this master index.
		for tile in _pool:
			var vi: int = tile.get_photo_index()
			if vi >= 0 and vi < _visible.size() and _visible[vi] == mi:
				tile.set_rejected(now)
				break
	reject_toggled.emit(path, now)
	cursor_reject_state.emit(_cursor_rejected())


func _set_reject_persisted(key: String, rejected: bool) -> void:
	if rejected:
		_reject_set[key] = true
	else:
		_reject_set.erase(key)
	RejectStore.save_set(_reject_set)


# Toggles the hide-rejected filter. The cursor follows its photo across the
# remap by path; no cache is cleared (textures survive the filter).
func set_hide_rejected(hide: bool) -> void:
	if _hide_rejected == hide:
		return
	var cursor_path: String = ""
	if _cursor >= 0 and _cursor < _visible.size():
		cursor_path = _photos[_visible[_cursor]]["path"]
	_hide_rejected = hide
	_rebuild_visible()
	_cursor = -1
	if cursor_path != "":
		for vi in range(_visible.size()):
			if _photos[_visible[vi]]["path"] == cursor_path:
				_cursor = vi
				break
	if _cursor < 0 and not _visible.is_empty():
		# Hiding keeps a sensible cursor; showing allows none.
		_cursor = 0 if hide else -1
	for tile in _pool:
		tile.set_dim_enabled(not hide)
	_relayout()
	if _cursor >= 0:
		_scroll_cursor_into_view()
	_request_visible_thumbs()
	photos_changed.emit()
	cursor_reject_state.emit(_cursor_rejected())


func _master_index_of(path: String) -> int:
	for i in range(_photos.size()):
		if _photos[i]["path"] == path:
			return i
	return -1


func _cursor_rejected() -> bool:
	if _cursor < 0 or _cursor >= _visible.size():
		return false
	return _rejected.get(_photos[_visible[_cursor]]["path"], false)


# Master-space accessors for Main's edit-view navigation: nav walks the
# visible set (_visible holds master indices), so it follows the hide filter.
func get_photo_index_master(path: String) -> int:
	return _master_index_of(path)


# Session rejected state for a path, for Main's Edit-view reject button sync.
func is_path_rejected(path: String) -> bool:
	return _rejected.get(path, false)


func get_photo_master_path(master_index: int) -> String:
	if master_index < 0 or master_index >= _photos.size():
		return ""
	return _photos[master_index]["path"]


# Prev/next master index for Main's edit-view navigation, walking the
# currently-visible set; -1 at either end (stop, no wrap).
func next_visible_master(from_master: int, dir: int) -> int:
	return Library.next_visible_master(_visible, from_master, dir)


# --- Texture LRU ---------------------------------------------------------------

func _cache_put(path: String, tex: Texture2D) -> void:
	if _tex_cache.has(path):
		_tex_lru.erase(path)
	_tex_cache[path] = tex
	_tex_lru.append(path)
	while _tex_lru.size() > MAX_CACHE_TEXTURES:
		var oldest: String = _tex_lru.pop_front()
		_tex_cache.erase(oldest)


func _cache_get(path: String) -> Texture2D:
	if not _tex_cache.has(path):
		return null
	_tex_lru.erase(path)
	_tex_lru.append(path)
	return _tex_cache[path]


# --- Filmstrip data source (duck-typed; see Filmstrip.gd) -----------------------
# Read-only views over the grid's own state, all VISIBLE-space so the strip
# mirrors exactly what the grid shows, hide-rejected filter included.

# Paths currently in the visible-range (plus buffer rows), master-order, for
# the background worker's priority list. Read-only, no side effects.
func get_visible_paths() -> PackedStringArray:
	var r: Vector2i = _visible_index_range()
	var result: PackedStringArray = PackedStringArray()
	for vi in range(r.x, r.y):
		result.append(_photos[_visible[vi]]["path"])
	return result


func filmstrip_count() -> int:
	return _visible.size()


func filmstrip_path(i: int) -> String:
	if i < 0 or i >= _visible.size():
		return ""
	return _photos[_visible[i]]["path"]


func filmstrip_texture(path: String) -> Texture2D:
	return _cache_get(path)


func filmstrip_edited(path: String) -> bool:
	return _edited.get(path, false)


func filmstrip_rejected(path: String) -> bool:
	return _rejected.get(path, false)
