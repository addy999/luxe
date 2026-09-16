extends Control

# darktable-godot-poc — Main scene controller.
# Bridges the GDExtension `DtBackend` class to the UI. There are now two
# independent view knobs, deliberately decoupled:
#
#   1. EDIT RESOLUTION (backend / pixelpipe) — _edit_scale, the EditRes dropdown.
#      The scale darktable actually processes the *whole* image at: 100/75/50/
#      25% of native. This is the proxy/speed knob. Changing it re-runs the
#      pipe. Implemented by calling render_view() with an oversized viewport so
#      the ROI clamp (develop.c:874-890) collapses to the whole image at
#      _edit_scale: render_view(BIG, BIG, scale, 0, 0) returns the entire image
#      scaled by `scale`, allocating only scale*native pixels (see dt_backend.cpp
#      render_view: it copies wd*ht = the clipped ROI, not the viewport).
#
#   2. DISPLAY ZOOM (frontend / Godot only) — _display_zoom, the DisplayZoom
#      dropdown. How large that already-rendered buffer is drawn on screen:
#      Fit / 25 / 50 / 100 / 200%. Pure TextureRect sizing inside a
#      ScrollContainer; it does NOT re-run the pipe, so it is instant and
#      panning is just scrolling. Display zoom % is relative to *native*
#      pixels (100% display = 1 native px per screen px), so it stays meaningful
#      regardless of edit resolution.
#
# Consequence (surfaced in the resolution label): if edit resolution is 50% and
# display zoom is 100%, you are viewing a half-res buffer upscaled 2x — soft,
# not true detail. True 1:1 detail requires BOTH edit resolution and display
# zoom at 100%. export_image() is untouched and always renders full-resolution.

@onready var scroll_container: ScrollContainer = $VBox/Scroll
@onready var texture_rect: TextureRect = $VBox/Scroll/TextureRect
@onready var exposure_slider: HSlider = $VBox/Controls/ExposureRow/ExposureSlider
@onready var exposure_value_label: Label = $VBox/Controls/ExposureRow/ExposureValueLabel
@onready var edit_res_option: OptionButton = $VBox/Controls/ViewRow/EditResOptionButton
@onready var display_zoom_option: OptionButton = $VBox/Controls/ViewRow/DisplayZoomOptionButton
@onready var open_button: Button = $VBox/Controls/OpenRow/OpenButton
@onready var export_button: Button = $VBox/Controls/OpenRow/ExportButton
@onready var status_label: Label = $VBox/Controls/OpenRow/StatusLabel
@onready var resolution_label: Label = $VBox/Controls/ResolutionLabel
@onready var file_dialog: FileDialog = $FileDialog
@onready var export_dialog: FileDialog = $ExportDialog

var backend: DtBackend = null
var image_texture: ImageTexture = null

var _image_loaded: bool = false
var _processing: bool = false
# Any queued re-render (an EV change, or an edit-resolution change that landed
# while a render was in flight) is expressed as "there is a pending EV equal to
# whatever we want the next render to use". _pending_ev is only meaningful when
# _has_pending_ev is true; the next render also picks up the current _edit_scale.
var _has_pending_ev: bool = false
var _pending_ev: float = 0.0
var _current_task_id: int = -1
var _exporting: bool = false
var _export_path: String = ""
var _source_basename: String = "export"

# --- Knob 1: edit resolution (backend render scale) ---------------------------
# Fraction of native the pixelpipe processes the whole image at. Item ids on
# EditResOptionButton index into this array.
const _EDIT_MODES: Array = [
	{"id": 0, "label": "100%", "scale": 1.00},
	{"id": 1, "label": "75%", "scale": 0.75},
	{"id": 2, "label": "50%", "scale": 0.50},
	{"id": 3, "label": "25%", "scale": 0.25},
]
const _EDIT_DEFAULT_ID: int = 0 # 100% — WYSIWYG by default; dial down for speed.
var _edit_scale: float = 1.00

# An oversized viewport handed to render_view() so its MIN(viewport, pipe_dim)
# clamp always resolves to pipe_dim — i.e. the whole image at _edit_scale, never
# a viewport-sized crop. render_view() only allocates the clipped ROI, so this
# large number costs nothing; it just disables cropping/panning at the backend.
const _WHOLE_IMAGE_VIEWPORT: int = 1000000

# --- Knob 2: display zoom (frontend TextureRect scale) ------------------------
# On-screen size relative to *native* pixels. -1.0 sentinel = Fit (letterbox the
# whole image into the pane). Item ids on DisplayZoomOptionButton index in.
const _DISPLAY_FIT_ID: int = 0
const _DISPLAY_MODES: Array = [
	{"id": 0, "label": "Fit", "zoom": -1.0},
	{"id": 1, "label": "25%", "zoom": 0.25},
	{"id": 2, "label": "50%", "zoom": 0.50},
	{"id": 3, "label": "100%", "zoom": 1.00},
	{"id": 4, "label": "200%", "zoom": 2.00},
]
var _display_zoom: float = -1.0 # -1.0 = Fit; otherwise native-relative scale.

# TextureRect StretchMode ids (confirmed via dynamic-rag godot_retrieve):
# 0 = STRETCH_SCALE (fill the node rect exactly), 5 = STRETCH_KEEP_ASPECT_CENTERED.
const _STRETCH_SCALE: int = 0
const _STRETCH_KEEP_ASPECT_CENTERED: int = 5

var _dragging: bool = false


func _ready() -> void:
	backend = DtBackend.new()
	var ok: bool = backend.init()
	if not ok:
		status_label.text = "Error: DtBackend.init() failed"
		open_button.disabled = true
		exposure_slider.editable = false
		return

	status_label.text = "Ready — open an image to begin"
	exposure_value_label.text = "%.2f" % exposure_slider.value

	# Populate both dropdowns. Item *index* == item *id* here (ids assigned in
	# order), and add_item(label, id) pins the id explicitly so lookups stay
	# correct even if entries are reordered (confirmed via dynamic-rag
	# godot_retrieve against OptionButton's docs).
	for mode in _EDIT_MODES:
		edit_res_option.add_item(mode["label"], mode["id"])
	edit_res_option.select(_EDIT_DEFAULT_ID)
	_edit_scale = _EDIT_MODES[_EDIT_DEFAULT_ID]["scale"]

	for mode in _DISPLAY_MODES:
		display_zoom_option.add_item(mode["label"], mode["id"])
	display_zoom_option.select(_DISPLAY_FIT_ID)
	_display_zoom = _DISPLAY_MODES[_DISPLAY_FIT_ID]["zoom"]

	# Re-lay-out on pane resize. This only recomputes the frontend display size
	# (Fit depends on the pane's size); edit resolution is viewport-independent
	# now, so a resize never re-runs the pipe.
	scroll_container.resized.connect(_on_scroll_resized)

	# Drag-to-pan: when the image is larger than the pane (zoomed in), press-
	# drag scrolls the ScrollContainer. TextureRect's mouse_filter defaults to
	# STOP so it receives these events; connecting the signal explicitly (rather
	# than a _gui_input override) is required because this script is on the root
	# Control, not the TextureRect.
	texture_rect.gui_input.connect(_on_texture_rect_gui_input)


func _on_open_button_pressed() -> void:
	file_dialog.popup_centered()


func _on_file_dialog_file_selected(path: String) -> void:
	if backend == null:
		return

	status_label.text = "Loading %s ..." % path.get_file()
	var ok: bool = backend.load_image(path)
	if not ok:
		status_label.text = "Error: failed to load %s" % path.get_file()
		_image_loaded = false
		export_button.disabled = true
		return

	_image_loaded = true
	status_label.text = "Loaded %s" % path.get_file()

	# Default the export filename to "<source>_edited.jpg".
	_source_basename = path.get_file().get_basename()
	export_button.disabled = false

	# Reset both view knobs for the new image, then kick off the initial render.
	exposure_slider.value = 0.0
	exposure_value_label.text = "%.2f" % 0.0
	edit_res_option.select(_EDIT_DEFAULT_ID)
	_edit_scale = _EDIT_MODES[_EDIT_DEFAULT_ID]["scale"]
	display_zoom_option.select(_DISPLAY_FIT_ID)
	_display_zoom = _DISPLAY_MODES[_DISPLAY_FIT_ID]["zoom"]
	_start_process(0.0)


func _on_exposure_slider_value_changed(value: float) -> void:
	exposure_value_label.text = "%.2f" % value

	if not _image_loaded or _exporting:
		return

	if _processing:
		# A task is already running; remember the latest value and pick it up
		# when the running task completes.
		_has_pending_ev = true
		_pending_ev = value
		return

	_start_process(value)


func _start_process(ev: float) -> void:
	if backend == null or not _image_loaded or _exporting:
		return

	_processing = true
	# Block export while a preview render is in flight: both run darktable's pipe
	# over shared process-wide state, so they must not overlap.
	export_button.disabled = true
	backend.set_exposure(ev)

	# Snapshot _edit_scale on the main thread and hand the plain value into the
	# worker task. render_view() with an oversized viewport renders the whole
	# image at this scale (no viewport cap, no crop) — the display zoom is a
	# frontend-only concern applied after the buffer comes back.
	var edit_scale: float = _edit_scale
	_current_task_id = WorkerThreadPool.add_task(_process_task.bind(edit_scale))


func _process_task(edit_scale: float) -> void:
	# Runs on a worker thread. Only touch the backend and plain data here — no
	# Godot rendering/scene-tree APIs (main-thread only).
	var bytes: PackedByteArray = backend.render_view(
		_WHOLE_IMAGE_VIEWPORT, _WHOLE_IMAGE_VIEWPORT, edit_scale, 0.0, 0.0)
	var width: int = backend.get_width()
	var height: int = backend.get_height()
	call_deferred("_on_process_done", bytes, width, height)


func _on_process_done(bytes: PackedByteArray, width: int, height: int) -> void:
	if width > 0 and height > 0 and bytes.size() >= width * height * 4:
		var img: Image = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, bytes)
		# ImageTexture.update() is the fast in-place path but requires a matching
		# size/format; an edit-resolution change alters the buffer dimensions, so
		# recreate the texture in that case and keep update() only for same-size
		# frames (the common case: exposure-slider drags at a fixed edit res).
		if image_texture == null \
				or image_texture.get_width() != width \
				or image_texture.get_height() != height:
			image_texture = ImageTexture.create_from_image(img)
			texture_rect.texture = image_texture
		else:
			image_texture.update(img)
		status_label.text = "Preview updated"
		_apply_display_layout()
		_update_resolution_label(width, height)
	else:
		status_label.text = "Error: empty/invalid frame from backend"

	_processing = false

	if _has_pending_ev:
		var ev: float = _pending_ev
		_has_pending_ev = false
		_start_process(ev)
	elif _image_loaded and not _exporting:
		# Pipe is idle again -> exporting is safe.
		export_button.disabled = false


func _apply_display_layout() -> void:
	# Frontend-only: size the TextureRect inside the ScrollContainer to realize
	# the current display zoom. No pipe involvement. Native dims come from the
	# backend (populated by the render that just completed).
	if image_texture == null:
		return
	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0:
		return

	if _display_zoom < 0.0:
		# Fit: fill the pane and letterbox/center the whole image. custom_minimum_
		# size == pane size means the ScrollContainer shows no scrollbars, and
		# KEEP_ASPECT_CENTERED scales the buffer to fit that rect centered.
		texture_rect.stretch_mode = _STRETCH_KEEP_ASPECT_CENTERED
		texture_rect.custom_minimum_size = scroll_container.size
	else:
		# Fixed zoom: on-screen size = native * display_zoom, filled exactly by
		# the buffer (STRETCH_SCALE). Larger than the pane -> scrollbars/drag-pan;
		# smaller -> anchored top-left (acceptable for a PoC).
		texture_rect.stretch_mode = _STRETCH_SCALE
		texture_rect.custom_minimum_size = Vector2(native_w, native_h) * _display_zoom


func _on_scroll_resized() -> void:
	# Fit's on-screen size depends on the pane size; recompute the frontend
	# layout only. Edit resolution is viewport-independent, so no re-render.
	if not _image_loaded:
		return
	_apply_display_layout()


func _on_edit_res_option_button_item_selected(index: int) -> void:
	# item_selected passes the *index*, not the id; look the id up rather than
	# assume index==id (confirmed via dynamic-rag godot_retrieve).
	var id: int = edit_res_option.get_item_id(index)
	_edit_scale = _EDIT_MODES[id]["scale"]

	if not _image_loaded or _exporting:
		return

	# Re-render the pipe at the new edit resolution, same queuing pattern as the
	# slider so we never overlap two tasks over shared darktable state.
	if _processing:
		_has_pending_ev = true
		_pending_ev = exposure_slider.value
		return

	_start_process(exposure_slider.value)


func _on_display_zoom_option_button_item_selected(index: int) -> void:
	var id: int = display_zoom_option.get_item_id(index)
	_display_zoom = _DISPLAY_MODES[id]["zoom"]

	# Frontend-only knob: no pipe re-render. Just re-lay-out the existing buffer
	# and refresh the readout.
	if not _image_loaded:
		return
	_apply_display_layout()
	if image_texture != null:
		_update_resolution_label(image_texture.get_width(), image_texture.get_height())
	else:
		_update_resolution_label(0, 0)


func _update_resolution_label(buf_w: int, buf_h: int) -> void:
	# Trustworthy two-axis readout, derived from the backend's authoritative
	# numbers: get_native_*() is the full processed (scale=1.0) size; buf_w/buf_h
	# == get_width()/get_height() are the exact pixels the pipe just produced at
	# the current edit resolution. Nothing here trusts what the UI *requested*.
	if backend == null:
		resolution_label.text = "No image loaded"
		return
	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0 or buf_w <= 0 or buf_h <= 0:
		resolution_label.text = "No image loaded"
		return

	var edit_pct: int = roundi(_edit_scale * 100.0)

	# Effective display zoom: in Fit it is derived from the actual pane size, so
	# it reflects what is really on screen, not a requested number.
	var disp_zoom: float
	if _display_zoom < 0.0:
		var avail: Vector2 = scroll_container.size
		disp_zoom = min(avail.x / float(native_w), avail.y / float(native_h))
	else:
		disp_zoom = _display_zoom
	var screen_w: int = roundi(disp_zoom * float(native_w))
	var screen_h: int = roundi(disp_zoom * float(native_h))
	var disp_label: String = "Fit" if _display_zoom < 0.0 else "%d%%" % roundi(disp_zoom * 100.0)

	# Sharpness: the buffer holds edit_scale*native pixels; drawing it at
	# disp_zoom*native on screen means each buffer pixel is stretched by
	# disp_zoom/edit_scale. > 1 => upscaled (soft); == 1 with both at 100% => true
	# 1:1 native detail.
	var buffer_upscale: float = disp_zoom / _edit_scale
	var quality: String = ""
	if buffer_upscale > 1.001:
		quality = "  [upscaled %.1fx — soft]" % buffer_upscale
	elif disp_zoom >= 0.999 and _edit_scale >= 0.999:
		quality = "  [1:1 native pixels]"

	resolution_label.text = "Native %dx%d  |  Editing @ %d%% (buffer %dx%d)  |  Display %s → %dx%d on screen%s" % [
		native_w, native_h, edit_pct, buf_w, buf_h, disp_label, screen_w, screen_h, quality]


func _on_texture_rect_gui_input(event: InputEvent) -> void:
	# Drag-to-pan by scrolling the ScrollContainer. A no-op when the image fits
	# the pane (scroll values clamp to 0), so no guard is needed.
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		return

	if event is InputEventMouseMotion and _dragging:
		scroll_container.scroll_horizontal -= int(event.relative.x)
		scroll_container.scroll_vertical -= int(event.relative.y)


func _on_export_button_pressed() -> void:
	if not _image_loaded or _exporting or _processing:
		return
	export_dialog.current_file = "%s_edited.jpg" % _source_basename
	export_dialog.popup_centered()


func _on_export_dialog_file_selected(path: String) -> void:
	if backend == null or not _image_loaded or _exporting:
		return

	_exporting = true
	_export_path = path
	export_button.disabled = true
	open_button.disabled = true
	exposure_slider.editable = false
	status_label.text = "Exporting %s ..." % path.get_file()

	# Run the (full-res, high-quality) export off the main thread so the UI
	# doesn't freeze; it writes the file directly via darktable's export engine.
	WorkerThreadPool.add_task(_export_task)


func _export_task() -> void:
	var ok: bool = backend.export_image(_export_path)
	call_deferred("_on_export_done", ok, _export_path)


func _on_export_done(ok: bool, path: String) -> void:
	_exporting = false
	open_button.disabled = false
	exposure_slider.editable = true
	export_button.disabled = not _image_loaded
	if ok:
		status_label.text = "Exported %s" % path.get_file()
	else:
		status_label.text = "Error: export failed for %s" % path.get_file()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_cleanup_backend()
		if what == NOTIFICATION_WM_CLOSE_REQUEST:
			get_tree().quit()


func _exit_tree() -> void:
	_cleanup_backend()


func _cleanup_backend() -> void:
	if backend != null:
		backend.cleanup()
		backend = null
