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

@onready var scroll_container: ScrollContainer = $Root/MiddleHBox/Scroll
@onready var texture_rect: TextureRect = $Root/MiddleHBox/Scroll/TextureRect
@onready var exposure_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelMargin/PanelVBox/ExposureRow/ExposureSlider
@onready var exposure_value_label: Label = $Root/MiddleHBox/RightPanel/PanelMargin/PanelVBox/ExposureRow/ExposureValueLabel
@onready var contrast_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelMargin/PanelVBox/ContrastRow/ContrastSlider
@onready var contrast_value_label: Label = $Root/MiddleHBox/RightPanel/PanelMargin/PanelVBox/ContrastRow/ContrastValueLabel
@onready var edit_res_option: OptionButton = $Root/MiddleHBox/RightPanel/PanelMargin/PanelVBox/EditResOptionButton
@onready var open_button: Button = $Root/TopBar/TopBarRow/OpenButton
@onready var export_button: Button = $Root/TopBar/TopBarRow/ExportButton
@onready var status_label: Label = $Root/BottomBar/BottomRow/StatusLabel
@onready var resolution_label: Label = $Root/BottomBar/BottomRow/ResolutionLabel
# Display-zoom controls live in the top bar now: a continuous slider (native-
# relative %) plus a toggle for the Fit sentinel. See _display_zoom below.
@onready var zoom_slider: HSlider = $Root/TopBar/TopBarRow/ZoomSlider
@onready var fit_button: Button = $Root/TopBar/TopBarRow/FitButton
@onready var zoom_value_label: Label = $Root/TopBar/TopBarRow/ZoomValueLabel
@onready var file_dialog: FileDialog = $FileDialog
@onready var export_dialog: FileDialog = $ExportDialog
# Chrome panels, referenced only for the one-shot entrance animation.
@onready var top_bar: PanelContainer = $Root/TopBar
@onready var right_panel: PanelContainer = $Root/MiddleHBox/RightPanel
@onready var bottom_bar: PanelContainer = $Root/BottomBar

var backend: DtBackend = null
var image_texture: ImageTexture = null

var _image_loaded: bool = false

# --- Edit state: the authoritative "what to render" ---------------------------
# Every darktable module parameter the UI can drive lives here as key -> desired
# value. Any control's value_changed handler writes its key immediately, then
# calls _request_render(). The render queue always re-snapshots THIS dict at the
# moment a render starts, so a change to one parameter while a render driven by
# another is still in flight is never lost or clobbered — and any burst of
# changes collapses into a single follow-up render.
#
# To expose a new module (see .claude/skills/add-darktable-module): add its key
# here, add one line to _apply_params_to_backend(), and add a control that writes
# the key and calls _request_render().
var _params: Dictionary = {
	"exposure": 0.0,
	"contrast": 0.0,
}

var _processing: bool = false
# A render request that arrived while a render was already in flight. We store no
# value — the next _start_process() re-snapshots _params/_edit_scale, so it always
# renders the latest state. Exactly one follow-up render runs no matter how many
# requests coalesced into this flag.
var _render_queued: bool = false
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
const _EDIT_DEFAULT_ID: int = 2 # 50% — fallback used until an image's size is known.
var _edit_scale: float = 0.50

# Size-adaptive default: bigger raw files get a smaller default edit scale, so
# the initial render of a huge file isn't dramatically slower than a normal
# one. Checked in order; first threshold the image's megapixel count meets or
# exceeds wins. Based on raw_width/raw_height (DtBackend::get_raw_width/
# get_raw_height), which are known right after load_image() -- before the
# first pipe run, unlike get_native_width()/get_native_height().
const _EDIT_DEFAULT_BY_SIZE: Array = [
	{"min_megapixels": 20.0, "id": 3}, # huge (e.g. medium format, stitched) -> 25%
	{"min_megapixels": 12.0, "id": 2}, # large (typical modern camera) -> 50%
	{"min_megapixels": 0.0, "id": 0},  # normal/HD -> 100%
]


# Picks the default edit-mode id for a newly loaded image, based on its raw
# pixel count. Falls back to _EDIT_DEFAULT_ID if the size isn't known yet
# (raw_w/raw_h <= 0).
func _pick_default_edit_mode_id(raw_w: int, raw_h: int) -> int:
	if raw_w <= 0 or raw_h <= 0:
		return _EDIT_DEFAULT_ID
	var megapixels: float = (raw_w * raw_h) / 1000000.0
	for tier in _EDIT_DEFAULT_BY_SIZE:
		if megapixels >= tier["min_megapixels"]:
			return tier["id"]
	return _EDIT_DEFAULT_ID

# An oversized viewport handed to render_view() so its MIN(viewport, pipe_dim)
# clamp always resolves to pipe_dim — i.e. the whole image at _edit_scale, never
# a viewport-sized crop. render_view() only allocates the clipped ROI, so this
# large number costs nothing; it just disables cropping/panning at the backend.
const _WHOLE_IMAGE_VIEWPORT: int = 1000000

# --- Knob 2: display zoom (frontend TextureRect scale) ------------------------
# On-screen size relative to *native* pixels. Driven by the top-bar ZoomSlider
# (a continuous percentage) plus the FitButton toggle. The slider itself cannot
# encode "Fit", so the -1.0 sentinel lives only in _display_zoom below and is
# mirrored in the UI: FitButton pressed + ZoomValueLabel showing "Fit". Dragging
# the slider drops out of Fit into a positive native-relative scale.
const _ZOOM_MIN_PCT: float = 10.0
const _ZOOM_MAX_PCT: float = 400.0
var _display_zoom: float = -1.0 # -1.0 = Fit; otherwise native-relative scale.

# TextureRect StretchMode ids (confirmed via dynamic-rag godot_retrieve):
# 0 = STRETCH_SCALE (fill the node rect exactly), 5 = STRETCH_KEEP_ASPECT_CENTERED.
const _STRETCH_SCALE: int = 0
const _STRETCH_KEEP_ASPECT_CENTERED: int = 5

var _dragging: bool = false


# Local dev/testing convenience: DtBackend::compute_dt_dirs() (dt_backend.cpp)
# looks for DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR as real process environment
# variables via getenv() -- Godot has no dotenv support, so a stray .env file
# in this directory does nothing. Rather than requiring every dev to launch
# the Godot editor from a terminal with those exported, set them here from the
# res://-relative project settings (project.godot [dt_backend] section) before
# init() runs. If the vars are already present in the real environment (e.g.
# someone did launch from a terminal with an explicit override), leave them
# alone -- an explicit external override should win over this project default.
#
# BUNDLE-SAFETY GUARD (PORTABILITY_PLAN.md 5.3.4 root-cause fix): this must
# never run in an exported/standalone build. NOTE: "standalone" is NOT a real
# Godot feature tag (verified against Godot's own feature-tags doc; an
# earlier version of this guard used it and it silently always evaluated to
# false, since OS.has_feature() returns false for unknown tags rather than
# erroring -- the guard looked correct but never actually fired). The real,
# documented tag is "editor": true when running in the editor OR when running
# the project *from* the editor, false only for an exported build. So the
# correct guard is `not OS.has_feature("editor")`, i.e. "only do this
# dev-convenience env var setup when running under the editor." Without this
# guard, an exported .app would set DT_BACKEND_DATADIR to the res://-relative
# dev-tree default below, globalized (ProjectSettings.globalize_path() on a
# res://../../... path with no actual res:// filesystem backing in an
# exported .app just strips the "res://" prefix, producing a *relative*
# string like "../../source/build/share/darktable" -- confirmed by an actual
# move-test launch log, not just reasoned about) -- and compute_dt_dirs()
# (dt_backend.cpp) used to trust this env var unconditionally (its one
# candidate that skipped datadir_looks_valid()), passing it straight through
# as dt_init()'s --datadir. darktable's own dt_loc_init_generic() then
# realpath()s that relative string against the process's current working
# directory, which is exactly why the original crash log showed the app's own
# bundle path prefixed onto "source/build/share/darktable/rawspeed/
# cameras.xml" -- realpath() of a relative path resolves against CWD, and CWD
# happened to be the app bundle's own directory. In an exported build, skip
# this function entirely and let compute_dt_dirs() fall through to its
# bundle-relative candidates (Godot executable path, then dladdr()), both of
# which validate with datadir_looks_valid() before being accepted.
func _configure_dt_backend_env() -> void:
	if not OS.has_feature("editor"):
		return
	if OS.has_environment("DT_BACKEND_DATADIR") and OS.has_environment("DT_BACKEND_MODULEDIR"):
		return
	var datadir: String = ProjectSettings.get_setting(
		"dt_backend/datadir", "res://../../source/build/share/darktable")
	var moduledir: String = ProjectSettings.get_setting(
		"dt_backend/moduledir", "res://../../source/build/lib/darktable")
	OS.set_environment("DT_BACKEND_DATADIR", ProjectSettings.globalize_path(datadir))
	OS.set_environment("DT_BACKEND_MODULEDIR", ProjectSettings.globalize_path(moduledir))


func _ready() -> void:
	_configure_dt_backend_env()
	backend = DtBackend.new()
	var ok: bool = backend.init()
	if not ok:
		status_label.text = "Error: DtBackend.init() failed"
		open_button.disabled = true
		exposure_slider.editable = false
		contrast_slider.editable = false
		return

	status_label.text = "Ready — open an image to begin"
	exposure_value_label.text = "%.2f" % exposure_slider.value
	contrast_value_label.text = "%.2f" % contrast_slider.value

	# Populate the edit-resolution dropdown. Item *index* == item *id* here (ids
	# assigned in order), and add_item(label, id) pins the id explicitly so
	# lookups stay correct even if entries are reordered (confirmed via dynamic-
	# rag godot_retrieve against OptionButton's docs).
	for mode in _EDIT_MODES:
		edit_res_option.add_item(mode["label"], mode["id"])
	edit_res_option.select(_EDIT_DEFAULT_ID)
	_edit_scale = _EDIT_MODES[_EDIT_DEFAULT_ID]["scale"]

	# Display zoom starts in Fit. The scene already sets the slider to 100 and the
	# Fit toggle on; mirror that into _display_zoom and the readout.
	_display_zoom = -1.0
	fit_button.set_pressed_no_signal(true)
	_update_zoom_readout()

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

	_animate_entrance()


func _animate_entrance() -> void:
	# One-shot: the chrome settles in on launch. Each bar fades from transparent
	# and scales up a hair (0.98 -> 1.0), staggered so the eye reads top -> panel
	# -> status. We animate modulate and scale, NOT position: containers own their
	# children's position/size and re-sort would stomp a position tween, but scale
	# is a transform the layout leaves alone. Fast (~0.3s), gentle cubic ease-out
	# — present, not showy. This is a photo tool; motion must never upstage pixels.
	var bars: Array = [top_bar, right_panel, bottom_bar]
	# Hide immediately so there's no first-frame flash before we have real sizes.
	for bar in bars:
		if bar != null:
			bar.modulate.a = 0.0
			bar.scale = Vector2(0.98, 0.98)
	# One frame so the containers have laid out and each bar has a real size to
	# center the scale pivot on (at _ready, sizes are still zero).
	await get_tree().process_frame
	for i in bars.size():
		var bar: Control = bars[i]
		if bar == null:
			continue
		bar.pivot_offset = bar.size * 0.5
		var tw: Tween = create_tween().set_parallel(true) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		var delay: float = 0.05 * i
		tw.tween_property(bar, "modulate:a", 1.0, 0.30).set_delay(delay)
		tw.tween_property(bar, "scale", Vector2.ONE, 0.30).set_delay(delay)


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
	# The edit-resolution default is picked from this image's raw size (huge ->
	# 25%, large -> 50%, normal/HD -> 100%) rather than a fixed id, so the first
	# render of a huge file isn't dramatically slower than a normal one.
	exposure_slider.value = 0.0
	exposure_value_label.text = "%.2f" % 0.0
	_params["exposure"] = 0.0
	contrast_slider.value = 0.0
	contrast_value_label.text = "%.2f" % 0.0
	_params["contrast"] = 0.0
	var default_edit_id: int = _pick_default_edit_mode_id(
		backend.get_raw_width(), backend.get_raw_height())
	edit_res_option.select(default_edit_id)
	_edit_scale = _EDIT_MODES[default_edit_id]["scale"]
	_display_zoom = -1.0
	fit_button.set_pressed_no_signal(true)
	_update_zoom_readout()
	_request_render()


func _on_exposure_slider_value_changed(value: float) -> void:
	exposure_value_label.text = "%.2f" % value
	_params["exposure"] = value
	_request_render()


func _on_contrast_slider_value_changed(value: float) -> void:
	contrast_value_label.text = "%.2f" % value
	_params["contrast"] = value
	_request_render()


# Single entry point for every control: "the edit state changed, bring the
# preview up to date." Coalesces requests so two renders never overlap on shared
# process-wide darktable state — if one is already in flight, just flag that
# another is needed; _on_process_done() runs it when the current one finishes.
func _request_render() -> void:
	if backend == null or not _image_loaded or _exporting:
		return
	if _processing:
		_render_queued = true
		return
	_start_process()


# Push the current desired parameters into their darktable modules. This is the
# ONE place that maps _params keys to backend setters — adding a module means
# adding one line here. Runs on the main thread: darktable's set_* calls mutate
# process-wide pipe state and must not race the worker's render_view().
func _apply_params_to_backend() -> void:
	backend.set_exposure(_params["exposure"])
	backend.set_contrast(_params["contrast"])


func _start_process() -> void:
	if backend == null or not _image_loaded or _exporting:
		return

	_processing = true
	_render_queued = false
	# Block export while a preview render is in flight: both run darktable's pipe
	# over shared process-wide state, so they must not overlap.
	export_button.disabled = true
	_apply_params_to_backend()

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

	if _render_queued and _image_loaded and not _exporting:
		# Changes landed mid-render; render once more with the latest _params.
		_render_queued = false
		_start_process()
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

	# Re-render at the new edit resolution. _request_render() re-snapshots
	# _edit_scale and _params, so it carries the current exposure automatically
	# and coalesces safely if a render is already running.
	_request_render()


func _on_zoom_slider_value_changed(value: float) -> void:
	# Dragging the slider always means an explicit positive zoom, so drop out of
	# Fit (silently, so we don't re-enter _on_fit_button_toggled). value is in
	# percent of native; _display_zoom is the fraction.
	_display_zoom = value / 100.0
	fit_button.set_pressed_no_signal(false)
	_apply_zoom_change()


func _on_fit_button_toggled(pressed: bool) -> void:
	if pressed:
		# Engage the Fit sentinel; leave the slider where it is as a fallback.
		_display_zoom = -1.0
	else:
		# Fit released -> snap to whatever the slider currently reads.
		_display_zoom = zoom_slider.value / 100.0
	_apply_zoom_change()


func _apply_zoom_change() -> void:
	# Shared tail for both display-zoom controls. Frontend-only knob: no pipe
	# re-render. Refresh the readout, then re-lay-out the existing buffer.
	_update_zoom_readout()
	if not _image_loaded:
		return
	_apply_display_layout()
	if image_texture != null:
		_update_resolution_label(image_texture.get_width(), image_texture.get_height())
	else:
		_update_resolution_label(0, 0)


func _update_zoom_readout() -> void:
	# The top-bar "%"/"Fit" label. In Fit, also park the slider thumb on the
	# effective fit percent (no-signal) so it reflects what is actually on screen.
	if _display_zoom < 0.0:
		zoom_value_label.text = "Fit"
		if backend != null:
			var native_w: int = backend.get_native_width()
			var native_h: int = backend.get_native_height()
			if native_w > 0 and native_h > 0:
				var avail: Vector2 = scroll_container.size
				var fit: float = min(avail.x / float(native_w), avail.y / float(native_h))
				var pct: float = clamp(fit * 100.0, _ZOOM_MIN_PCT, _ZOOM_MAX_PCT)
				zoom_slider.set_value_no_signal(pct)
	else:
		zoom_value_label.text = "%d%%" % roundi(_display_zoom * 100.0)


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
	contrast_slider.editable = false
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
	contrast_slider.editable = true
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
