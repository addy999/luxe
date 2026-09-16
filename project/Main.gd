extends Control

# darktable-godot-poc — Main scene controller.
# Bridges the GDExtension `DtBackend` class (init/load_image/set_exposure/
# process_fit/render_view) to the UI: a TextureRect preview, an HSlider for
# exposure EV, a Zoom OptionButton, an Open Image button + FileDialog, and
# status/error labels.
#
# Rendering always goes through the *current zoom mode*:
#   - "Fit" calls backend.process_fit(viewport_w, viewport_h), which renders
#     the whole image scaled to fit inside the TextureRect (never upscaling
#     past native resolution).
#   - "25%"/"50%"/"100%"/"200%" call backend.render_view(viewport_w,
#     viewport_h, scale, center_x, center_y), the general ROI render that
#     implements darktable's own darkroom scale/ROI math
#     (source/src/develop/develop.c:874-890): when the scaled image is
#     larger than the viewport, only a viewport-sized region renders,
#     positioned by center_x/center_y (both in [-0.5, 0.5], panned by
#     dragging on the preview -- see _on_texture_rect_gui_input()).
# export_image() is untouched and always renders full-resolution.

@onready var texture_rect: TextureRect = $VBox/TextureRect
@onready var exposure_slider: HSlider = $VBox/Controls/ExposureRow/ExposureSlider
@onready var exposure_value_label: Label = $VBox/Controls/ExposureRow/ExposureValueLabel
@onready var zoom_option_button: OptionButton = $VBox/Controls/ExposureRow/ZoomOptionButton
@onready var open_button: Button = $VBox/Controls/OpenRow/OpenButton
@onready var export_button: Button = $VBox/Controls/OpenRow/ExportButton
@onready var status_label: Label = $VBox/Controls/OpenRow/StatusLabel
@onready var resolution_label: Label = $VBox/Controls/ResolutionLabel
@onready var file_dialog: FileDialog = $FileDialog
@onready var export_dialog: FileDialog = $ExportDialog
@onready var resize_debounce_timer: Timer = $ResizeDebounceTimer

var backend: DtBackend = null
var image_texture: ImageTexture = null

var _image_loaded: bool = false
var _processing: bool = false
# "Pending" here doesn't just mean a new EV value: any queued re-render (an EV
# change, a resize, a zoom-mode change, or a pan that landed while a render
# was in flight) is expressed as "there is a pending EV equal to whatever the
# exposure module is currently set to." _pending_ev is only meaningful when
# _has_pending_ev is true, and always reflects the EV to use for the *next*
# render (which also picks up whatever the current zoom mode / center /
# viewport size is at that time).
var _has_pending_ev: bool = false
var _pending_ev: float = 0.0
var _current_task_id: int = -1
var _exporting: bool = false
var _export_path: String = ""
var _source_basename: String = "export"

# Zoom mode: "fit" or an explicit scale factor. Item ids on ZoomOptionButton
# double as a mode selector: id 0 = Fit, ids 1..4 = fixed scale (see
# _ZOOM_SCALES below). -1.0 is a sentinel meaning "fit" (process_fit()).
const _ZOOM_FIT_ID: int = 0
const _ZOOM_MODES: Array = [
	{"id": 0, "label": "Fit", "scale": -1.0},
	{"id": 1, "label": "25%", "scale": 0.25},
	{"id": 2, "label": "50%", "scale": 0.50},
	{"id": 3, "label": "100%", "scale": 1.00},
	{"id": 4, "label": "200%", "scale": 2.00},
]
var _zoom_scale: float = -1.0 # -1.0 = fit; otherwise an explicit scale factor.

# Pan center, in darktable's own zoom_x/zoom_y convention (develop.c:874-890):
# range [-0.5, 0.5], (0,0) = centered. Only meaningful (and only mutated) when
# the current zoom scale exceeds fit-scale, i.e. the rendered image is larger
# than the viewport and panning is active; see _pan_active().
var _center_x: float = 0.0
var _center_y: float = 0.0
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

	# Populate the zoom-mode dropdown. Item *index* == item *id* here (both
	# assigned 0..4 in order), so get_selected_id() and the loop index agree;
	# add_item(label, id) — confirmed via dynamic-rag godot_retrieve against
	# OptionButton's docs — lets us pin ids explicitly rather than relying on
	# insertion order, so this stays correct even if entries are reordered.
	for mode in _ZOOM_MODES:
		zoom_option_button.add_item(mode["label"], mode["id"])
	zoom_option_button.select(_ZOOM_FIT_ID)

	# Re-render on preview viewport resize (window resize / layout changes
	# propagate down to the TextureRect's Control.size). Debounced via a
	# one-shot Timer so a resize drag doesn't fire dozens of full pipe runs
	# mid-drag -- only the size after the drag settles for
	# resize_debounce_timer.wait_time seconds triggers a render. Control.size
	# is the actual on-screen pixel size of the node (confirmed via the
	# Godot docs: Control.size is what _draw()/layout code checks for pixel
	# bounds); Control.resized is the signal emitted whenever that changes.
	texture_rect.resized.connect(_on_texture_rect_resized)
	resize_debounce_timer.one_shot = true
	resize_debounce_timer.wait_time = 0.15
	resize_debounce_timer.timeout.connect(_on_resize_debounce_timeout)

	# Panning: TextureRect's default mouse_filter is MOUSE_FILTER_STOP (0),
	# confirmed via dynamic-rag godot_retrieve against Control's docs, which
	# means it already receives mouse events and emits "gui_input". Since
	# Main.gd is attached to the root Control (not the TextureRect itself),
	# _gui_input() as a virtual override wouldn't fire for TextureRect's
	# events -- connect its "gui_input" signal explicitly instead.
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

	# Reset exposure, zoom mode, and pan for the new image, then kick off an
	# initial render. A fresh image has no meaningful pan position yet, and
	# defaulting back to "Fit" avoids surprising the user with a zoomed-in
	# view of a brand new image.
	exposure_slider.value = 0.0
	exposure_value_label.text = "%.2f" % 0.0
	zoom_option_button.select(_ZOOM_FIT_ID)
	_zoom_scale = -1.0
	_center_x = 0.0
	_center_y = 0.0
	_start_process(0.0)


func _on_exposure_slider_value_changed(value: float) -> void:
	exposure_value_label.text = "%.2f" % value

	if not _image_loaded or _exporting:
		return

	if _processing:
		# A task is already running; remember the latest value and pick it
		# up when the running task completes.
		_has_pending_ev = true
		_pending_ev = value
		return

	_start_process(value)


func _start_process(ev: float) -> void:
	if backend == null or not _image_loaded or _exporting:
		return

	_processing = true
	# Block export while a preview render is in flight: both run darktable's
	# pipe over shared process-wide state, so they must not overlap.
	export_button.disabled = true
	backend.set_exposure(ev)

	# Cap size = the TextureRect's current on-screen pixel size: this is the
	# actual viewport the rendered frame will be displayed into, so there is
	# no point asking darktable's pipe to render more pixels than that. Read
	# on the main thread (Control.size is a Control property, not safe to
	# touch from a worker thread) and passed as plain ints/floats into the task.
	var cap_size: Vector2i = Vector2i(texture_rect.size)
	cap_size.x = max(cap_size.x, 1)
	cap_size.y = max(cap_size.y, 1)

	# Route through the current zoom mode: "Fit" always calls process_fit()
	# (whole image, capped to viewport, never upscaled); any explicit scale
	# calls the general ROI render_view() with the current pan center. Both
	# _zoom_scale and _center_x/_center_y are only ever read/written on the
	# main thread (slider/dropdown/drag handlers), so it's safe to snapshot
	# them here and hand plain values into the worker task.
	var zoom_scale: float = _zoom_scale
	var center_x: float = _center_x
	var center_y: float = _center_y

	_current_task_id = WorkerThreadPool.add_task(
		_process_task.bind(cap_size, zoom_scale, center_x, center_y))


func _process_task(cap_size: Vector2i, zoom_scale: float, center_x: float, center_y: float) -> void:
	# Runs on a worker thread. Only touch the backend and plain data here —
	# no Godot rendering/scene-tree APIs (main-thread only).
	var bytes: PackedByteArray
	if zoom_scale < 0.0:
		# Fit mode.
		bytes = backend.process_fit(cap_size.x, cap_size.y)
	else:
		bytes = backend.render_view(cap_size.x, cap_size.y, zoom_scale, center_x, center_y)
	var width: int = backend.get_width()
	var height: int = backend.get_height()
	call_deferred("_on_process_done", bytes, width, height)


func _on_process_done(bytes: PackedByteArray, width: int, height: int) -> void:
	if width > 0 and height > 0 and bytes.size() >= width * height * 4:
		var img: Image = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, bytes)
		# ImageTexture.update() is the fast in-place path but requires the new
		# image to match the existing texture's size and format (confirmed via
		# dynamic-rag godot_retrieve: update()'s "dimensions, format, and mipmaps
		# configuration should match"). Zoom-mode changes and viewport resizes
		# change the rendered dimensions, so the texture must be recreated in
		# that case; keep the cheap update() path only when the size is unchanged
		# (the common case: exposure-slider drags at a fixed zoom/viewport).
		if image_texture == null \
				or image_texture.get_width() != width \
				or image_texture.get_height() != height:
			image_texture = ImageTexture.create_from_image(img)
			texture_rect.texture = image_texture
		else:
			image_texture.update(img)
		status_label.text = "Preview updated"
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


func _update_resolution_label(shown_w: int, shown_h: int) -> void:
	# Trustworthy readout of what the viewport is actually showing, derived
	# entirely from the backend's authoritative numbers: get_native_*() is the
	# full processed (scale=1.0) size, and shown_w/shown_h == get_width()/
	# get_height() are the exact pixel dimensions render_view()/process_fit()
	# just emitted. Nothing here trusts what the UI *requested*; it reports what
	# the pipe actually produced.
	if backend == null:
		resolution_label.text = "No image loaded"
		return
	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0 or shown_w <= 0 or shown_h <= 0:
		resolution_label.text = "No image loaded"
		return

	# Effective scale of the pipeline output. In Fit mode the whole image is
	# rendered, so shown/native is the exact scale that was used; for an
	# explicit zoom the scale is the chosen factor (the render may then be a
	# viewport-sized crop of that scaled image, flagged by the "crop" note).
	var scale: float
	if _zoom_scale < 0.0:
		scale = float(shown_w) / float(native_w)
	else:
		scale = _zoom_scale

	# Crop vs whole image: if the fully-scaled image would be larger than what
	# we actually rendered, the viewport is showing only a center region (ROI),
	# not the entire frame. This is darktable's own darkroom behavior: past
	# fit-scale it renders only the visible rectangle (develop.c:874-890).
	var full_scaled_w: float = scale * float(native_w)
	var full_scaled_h: float = scale * float(native_h)
	var is_crop: bool = full_scaled_w > float(shown_w) + 1.0 or full_scaled_h > float(shown_h) + 1.0
	var kind: String = "center crop of full image" if is_crop else "whole image, scaled"

	# scale >= ~1.0 means every screen pixel is one native pixel (or finer):
	# this is the "you are seeing full-resolution detail" case.
	var pct: int = roundi(scale * 100.0)
	var detail: String = "  [1:1 native pixels]" if scale >= 0.999 else ""
	resolution_label.text = "Full %dx%d  |  showing %dx%d  @ %d%% (%s)%s" % [
		native_w, native_h, shown_w, shown_h, pct, kind, detail]


func _on_texture_rect_resized() -> void:
	# Restart (not just start) the one-shot timer: while size is still
	# changing (e.g. mid window-drag), each resized signal pushes the render
	# back out another wait_time seconds, so only the size once the drag
	# settles actually triggers a re-render.
	if not _image_loaded or _exporting:
		return
	resize_debounce_timer.start()


func _on_resize_debounce_timeout() -> void:
	if not _image_loaded or _exporting:
		return

	# Re-render at the exposure module's currently-committed EV (there's no
	# new EV on a resize, just a new cap size) using the same
	# pending/in-flight pattern as the slider: if a render is already
	# running, queue this one up rather than starting a second overlapping
	# task.
	if _processing:
		_has_pending_ev = true
		_pending_ev = exposure_slider.value
		return

	_start_process(exposure_slider.value)


func _on_zoom_option_button_item_selected(index: int) -> void:
	# item_selected passes the *index*, not the id (confirmed via dynamic-rag
	# godot_retrieve against OptionButton's docs); item ids == indices here
	# since add_item() was called with explicit ids 0..4 in _ready() matching
	# insertion order, but look the id up rather than assume that stays true.
	var id: int = zoom_option_button.get_item_id(index)
	var mode: Dictionary = _ZOOM_MODES[id]
	_zoom_scale = mode["scale"]

	# Switching zoom mode resets pan: "Fit" never pans (whole image always
	# visible), and jumping between fixed scales with a stale pan center
	# would leave the view looking at an arbitrary, unrelated crop of the
	# new scale's (possibly much larger/smaller) pipe-space image.
	_center_x = 0.0
	_center_y = 0.0

	if not _image_loaded or _exporting:
		return

	# Re-render immediately at the newly selected mode, same queuing pattern
	# as the slider/resize handlers.
	if _processing:
		_has_pending_ev = true
		_pending_ev = exposure_slider.value
		return

	_start_process(exposure_slider.value)


func _pan_active() -> bool:
	# Panning only makes sense once the rendered image is actually larger
	# than the viewport in at least one dimension -- i.e. scale > fit-scale.
	# "Fit" mode (_zoom_scale < 0) never pans by definition. For an explicit
	# scale, compare against native dims (backend.get_native_width/height(),
	# populated by the last process_fit()/render_view() call) vs. the
	# TextureRect's current on-screen size.
	if backend == null or not _image_loaded or _zoom_scale < 0.0:
		return false

	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0:
		return false

	var viewport: Vector2i = Vector2i(texture_rect.size)
	var pipe_w: float = _zoom_scale * float(native_w)
	var pipe_h: float = _zoom_scale * float(native_h)

	return pipe_w > float(viewport.x) or pipe_h > float(viewport.y)


func _on_texture_rect_gui_input(event: InputEvent) -> void:
	# Drag-to-pan: press-drag-release on the preview updates _center_x/
	# _center_y (develop.c:874-890's zoom_x/zoom_y convention, clamped to
	# [-0.5, 0.5]) and re-renders. A no-op whenever panning isn't active
	# (Fit mode, or an explicit scale that still fits the viewport) — the
	# backend's own render_view() clamp would force center back regardless,
	# but skipping the re-render here avoids pointless pipe runs while
	# dragging over a non-zoomed preview.
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = _pan_active()
			else:
				_dragging = false
		return

	if event is InputEventMouseMotion and _dragging:
		if not _pan_active():
			_dragging = false
			return

		var native_w: int = backend.get_native_width()
		var native_h: int = backend.get_native_height()
		if native_w <= 0 or native_h <= 0:
			return

		# Convert screen-pixel drag delta into pipe-space fractional delta:
		# dragging the mouse by `relative.x` on-screen pixels should move the
		# visible ROI by `relative.x` pixels in pipe space (scale * native),
		# i.e. `relative.x / pipe_w` as a fraction of the full pipe width.
		# Subtract (not add) because dragging right/down should reveal
		# content to the right/down, i.e. move the visible window's origin
		# right/down, which is the same as decreasing center_x/center_y in
		# develop.c's convention (center_x*pipe_w - wd/2 = window's left
		# edge; increasing that left edge means decreasing center_x for a
		# fixed wd... equivalently: drag right => pan the image right under
		# the cursor => reveal what's to the left => window moves left =>
		# center decreases). Empirically this matches "drag right moves the
		# visible content right," the natural drag-to-pan feel.
		var pipe_w: float = _zoom_scale * float(native_w)
		var pipe_h: float = _zoom_scale * float(native_h)
		var relative: Vector2 = event.relative

		_center_x = clamp(_center_x - relative.x / pipe_w, -0.5, 0.5)
		_center_y = clamp(_center_y - relative.y / pipe_h, -0.5, 0.5)

		if _processing:
			_has_pending_ev = true
			_pending_ev = exposure_slider.value
			return

		_start_process(exposure_slider.value)


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
