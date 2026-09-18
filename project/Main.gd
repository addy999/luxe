extends Control

# Luxe — Main scene controller.
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
@onready var texture_rect: TextureRect = $Root/MiddleHBox/Scroll/Center/TextureRect
# Empty-state placeholder: a CenterContainer over the canvas pane holding an
# "Open Image…" call-to-action. It shares the MiddleHBox with the Scroll pane,
# so it's hidden (visible = false) the moment an image loads and re-shown
# whenever the pane goes back to no-image. mouse_filter is IGNORE (set in the
# scene) so it never blocks anything underneath.
@onready var empty_state: CenterContainer = $Root/MiddleHBox/EmptyState
@onready var exposure_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ExposureRow/ExposureSlider
@onready var exposure_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ExposureRow/ExposureValueLabel
@onready var contrast_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ContrastRow/ContrastSlider
@onready var contrast_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ContrastRow/ContrastValueLabel
@onready var highlights_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/HighlightsRow/HighlightsSlider
@onready var highlights_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/HighlightsRow/HighlightsValueLabel
@onready var shadows_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ShadowsRow/ShadowsSlider
@onready var shadows_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ShadowsRow/ShadowsValueLabel
@onready var saturation_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/SaturationRow/SaturationSlider
@onready var saturation_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/SaturationRow/SaturationValueLabel
@onready var vibrance_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/VibranceRow/VibranceSlider
@onready var vibrance_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/VibranceRow/VibranceValueLabel
@onready var tone_curve_editor: ToneCurveEditor = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ToneCurveEditor
@onready var white_balance_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/WhiteBalanceRow/WhiteBalanceSlider
@onready var white_balance_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/WhiteBalanceRow/WhiteBalanceValueLabel
@onready var edit_res_option: OptionButton = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/EditResOptionButton
@onready var open_button: Button = $Root/TopBar/TopBarRow/OpenButton
@onready var export_button: Button = $Root/TopBar/TopBarRow/ExportButton
@onready var theme_button: Button = $Root/TopBar/TopBarRow/ThemeButton
@onready var status_label: Label = $Root/BottomBar/BottomRow/StatusLabel
@onready var resolution_label: Label = $Root/BottomBar/BottomRow/ResolutionLabel
# Display-zoom controls live in the top bar now: a continuous slider (native-
# relative %) plus a toggle for the Fit sentinel. See _display_zoom below.
@onready var zoom_slider: HSlider = $Root/TopBar/TopBarRow/ZoomSlider
@onready var fit_button: Button = $Root/TopBar/TopBarRow/FitButton
@onready var zoom_value_label: Label = $Root/TopBar/TopBarRow/ZoomValueLabel
@onready var file_dialog: FileDialog = $FileDialog
@onready var export_dialog: FileDialog = $ExportDialog
# Crop UI: the top-bar toggle button plus the overlay editor (instantiated in
# code, parented to texture_rect while open -- see CropOverlay.gd).
@onready var crop_button: Button = $Root/TopBar/TopBarRow/CropButton

const CropOverlayScript := preload("res://CropOverlay.gd")
var _crop_overlay: Control = null
# Done/Cancel bar for the crop overlay. Lives anchored to the Scroll pane (NOT
# the overlay, which is image-sized and scrolls off-screen at high zoom).
var _crop_bar: HBoxContainer = null
# The committed crop while the overlay is open. While editing, the pipe
# renders the FULL frame (crop temporarily lifted) so the user always adjusts
# the box over the whole image, exactly like darktable's own darkroom UI;
# this remembers what to fall back to on Cancel.
var _crop_before_edit: Rect2 = Rect2(0, 0, 1, 1)
# Chrome panels, referenced only for the one-shot entrance animation.
@onready var top_bar: PanelContainer = $Root/TopBar
@onready var right_panel: PanelContainer = $Root/MiddleHBox/RightPanel
@onready var bottom_bar: PanelContainer = $Root/BottomBar

var backend: DtBackend = null
var image_texture: ImageTexture = null

var _image_loaded: bool = false

# Per-image default white balance (the camera's as-shot CCT, resolved on load).
# Unlike the other sliders, WB has no fixed default -- its reset target is this
# value, refreshed in _on_image_loaded(). 6500.0 is only a pre-load placeholder.
var _wb_default_temperature: float = 6500.0
# Every reset icon button, tracked so they can be disabled together when the
# backend fails to init (mirrors the slider .editable handling below).
var _reset_buttons: Array[Button] = []

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
# the key and calls _request_render(). Only params whose value changed since the
# last apply are pushed (see _applied_params / _params_differ below), so a new
# module needs no extra bookkeeping: just keep writing its key as usual.
var _params: Dictionary = {
	"exposure": 0.0,
	"contrast": 0.0,
	"highlights": -50.0,
	"shadows": 50.0,
	"saturation": 25.0,
	"vibrance": 25.0,
	# Tone curve L-channel control points, owned by ToneCurveEditor -- see
	# _on_tone_curve_changed() below. This default (identity, 2 nodes) matches
	# tonecurve.c's own init() default.
	"tonecurve": PackedVector2Array([Vector2(0.0, 0.0), Vector2(1.0, 1.0)]),
	# wb_temperature drives channelmixerrgb's chromatic adaptation directly in
	# Kelvin -- see the White Balance (K) slider comment below. This 6500.0
	# placeholder only matters before any image is loaded; on load it's
	# replaced by the image's real as-shot temperature (see _on_image_loaded()).
	"wb_temperature": 6500.0,
	# Crop box in normalized image fractions, stored as edges (NOT x/y/w/h --
	# darktable's clipping module stores left/top/right/bottom). Full frame =
	# no crop; the backend disables the clipping module for that case. Owned by
	# the crop overlay UI (see _on_crop_overlay_applied below).
	"crop": Rect2(0, 0, 1, 1),
}

# Last values actually pushed to the backend, keyed like _params. A key missing
# here (or one whose _params value differs) is stale and gets pushed by
# _apply_params_to_backend(). Emptied on image load to force a full sync, since
# load_image resets the backend's modules and its state must be re-pushed.
var _applied_params: Dictionary = {}

# --- White Balance (K) slider mapping -----------------------------------------
# White balance is implemented via channelmixerrgb ("color calibration")'s
# chromatic adaptation, not the temperature module -- see the NOTE on white
# balance above dt_iop_channelmixer_rgb_params_t in dt_backend.h for the full
# rationale (this app's default darktable workflow is scene-referred/sigmoid,
# where temperature is pinned neutral and channelmixerrgb owns the real
# camera-to-D65 correction). Unlike the old temperature-based approach, this
# is a REAL colorimetric CCT: the slider value is fed straight to
# channelmixerrgb's `temperature` field (illuminant pinned to DT_ILLUMINANT_D,
# daylight), and darktable's own illuminant_to_xy() derives the correct
# chromatic-adaptation matrix from it. No linear bias hack needed.
#
# The slider's Kelvin range lives in Main.tscn (min 1667, max 25000) to match
# channelmixerrgb's TEMP_MIN/TEMP_MAX, so a raw's as-shot temperature (used to
# seed the slider at load) never clamps. On load the slider is set to the
# image's real as-shot CCT via backend.get_white_balance_temperature().

var _processing: bool = false
# A render request that arrived while a render was already in flight. We store no
# value — the next _start_process() re-snapshots _params/_edit_scale, so it always
# renders the latest state. Exactly one follow-up render runs no matter how many
# requests coalesced into this flag.
var _render_queued: bool = false
var _current_task_id: int = -1

# --- Live-render EWMA gate -----------------------------------------------------
# Time-based throttle modeled on darktable's own UI gate: a new pipe run is only
# started if the previous one started at least half the averaged runtime ago
# (develop.c:294-298, _inside_pipe_ui_frame). The average is an EWMA over 8 runs,
# the same recurrence as _dev_average_delay_update() (develop.c:628-633,
# DT_DEV_AVERAGE_DELAY_COUNT = 8).
#
# Cheap renders keep the average small, so the gate stays open and feedback is
# near-instant. Expensive renders widen it, collapsing a drag's burst of ticks
# into the fewest frames that still keep the preview current. This is adaptive,
# never a fixed debounce: a slow render widens the window, a fast one closes it.
#
# A request that arrives while the gate is shut is not dropped. It arms a one-shot
# timer for exactly the remaining sliver of the window, and that trailing render
# re-snapshots _params, so the final slider value is always rendered.
#
# Note the gate is deliberately conservative: because we never abort an in-flight
# render (unlike darktable, which stops the pipe mid-run), a render that takes its
# own runtime to finish always clears the half-average window on completion, so a
# saturated back-to-back drag is unaffected. The gate only sheds frames when a
# render finishes well under half the recent average, i.e. when there is variance
# worth smoothing.
const _RENDER_AVG_COUNT: int = 8
var _render_avg_usec: float = 0.0        # EWMA of render start-to-start latency.
var _last_render_start_usec: int = 0     # Start time of the most recent render (0 = none).
var _render_start_usec: int = 0          # Start time of the in-flight render, for the EWMA.
var _gate_timer: Timer = null            # One-shot trailing render when the gate is shut.
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
	# One-shot timer for the EWMA render gate's trailing render. Created once and
	# reused; never allocated per tick. See the gate block above.
	_gate_timer = Timer.new()
	_gate_timer.one_shot = true
	_gate_timer.timeout.connect(_on_render_gate_timeout)
	add_child(_gate_timer)

	# Build the per-slider/per-module reset icon buttons first so they exist even
	# on the backend-failure path below (where they get disabled alongside the
	# sliders they'd otherwise reset).
	_setup_reset_buttons()

	_animate_entrance()
	_update_empty_state()
	await get_tree().process_frame
	if not _init_backend():
		return
	_finish_ready()


func _init_backend() -> bool:
	_configure_dt_backend_env()
	backend = DtBackend.new()
	var ok: bool = backend.init()
	if not ok:
		status_label.text = "Error: DtBackend.init() failed"
		open_button.disabled = true
		exposure_slider.editable = false
		contrast_slider.editable = false
		highlights_slider.editable = false
		shadows_slider.editable = false
		saturation_slider.editable = false
		vibrance_slider.editable = false
		white_balance_slider.editable = false
		for btn in _reset_buttons:
			btn.disabled = true
		return false
	return true


func _finish_ready() -> void:
	status_label.text = "Ready — open an image to begin"
	exposure_value_label.text = "%.2f" % exposure_slider.value
	contrast_value_label.text = "%.2f" % contrast_slider.value
	highlights_value_label.text = "%.2f" % highlights_slider.value
	shadows_value_label.text = "%.2f" % shadows_slider.value
	saturation_value_label.text = "%.2f" % saturation_slider.value
	vibrance_value_label.text = "%.2f" % vibrance_slider.value
	white_balance_value_label.text = "%dK" % roundi(white_balance_slider.value)

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

	ThemeManager.theme_changed.connect(_on_theme_changed)
	_on_theme_changed(ThemeManager.is_dark)

	crop_button.toggled.connect(_on_crop_button_toggled)
	crop_button.disabled = true


# Empty-canvas placeholder: with no image loaded, hide the (blank) Scroll pane
# so the centered "Open Image…" call-to-action owns the whole canvas area; once
# an image loads, hand the space back to the Scroll pane.
func _update_empty_state() -> void:
	var empty: bool = not _image_loaded
	empty_state.visible = empty
	scroll_container.visible = not empty


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
		_update_empty_state()
		export_button.disabled = true
		return

	_image_loaded = true
	_update_empty_state()
	status_label.text = "Loaded %s" % path.get_file()

	# load_image() resets the backend's modules, so nothing from the previous
	# image is still applied. Drop the applied snapshot to force the next render
	# to push every param fresh (the "first render after load is a full sync"
	# case); the per-param resets below then just seed _params.
	_applied_params.clear()

	# Cancel any render/throttle state inherited from the previous image: a
	# pending trailing render belongs to the old image, and the EWMA restarts so
	# the new image's first render is never delayed by the old image's timing.
	_reset_render_gate()

	# Default the export filename to "<source>_edited.jpg".
	_source_basename = path.get_file().get_basename()
	export_button.disabled = false
	crop_button.disabled = false
	crop_button.set_pressed_no_signal(false)

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
	highlights_slider.value = -50.0
	highlights_value_label.text = "%.2f" % -50.0
	_params["highlights"] = -50.0
	shadows_slider.value = 50.0
	shadows_value_label.text = "%.2f" % 50.0
	_params["shadows"] = 50.0
	saturation_slider.value = 25.0
	saturation_value_label.text = "%.2f" % 25.0
	_params["saturation"] = 25.0
	vibrance_slider.value = 25.0
	vibrance_value_label.text = "%.2f" % 25.0
	_params["vibrance"] = 25.0
	tone_curve_editor.reset_to_default()
	# White balance has no fixed default -- read this image's real as-shot
	# temperature back from the backend (channelmixerrgb's reload_defaults()
	# already resolved it from the camera's raw WB coefficients right after
	# load_image(), before any setter has run -- see dt_backend.h's NOTE on
	# white balance) and seed the slider with it directly, so a fresh load
	# stays visually neutral.
	var as_shot_temperature: float = backend.get_white_balance_temperature()
	white_balance_slider.value = as_shot_temperature
	white_balance_value_label.text = "%dK" % roundi(as_shot_temperature)
	_params["wb_temperature"] = as_shot_temperature
	# Reset crop to the full frame for the new image (crop state is not
	# per-image persistent yet; same policy as every slider above).
	_params["crop"] = Rect2(0, 0, 1, 1)
	# This image's as-shot CCT is the WB slider's reset target from now on.
	_wb_default_temperature = as_shot_temperature
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


func _on_highlights_slider_value_changed(value: float) -> void:
	highlights_value_label.text = "%.2f" % value
	_params["highlights"] = value
	_request_render()


func _on_shadows_slider_value_changed(value: float) -> void:
	shadows_value_label.text = "%.2f" % value
	_params["shadows"] = value
	_request_render()


func _on_saturation_slider_value_changed(value: float) -> void:
	saturation_value_label.text = "%.2f" % value
	_params["saturation"] = value
	_request_render()


func _on_vibrance_slider_value_changed(value: float) -> void:
	vibrance_value_label.text = "%.2f" % value
	_params["vibrance"] = value
	_request_render()


func _on_tone_curve_changed(points: PackedVector2Array) -> void:
	_params["tonecurve"] = points
	_request_render()


func _on_white_balance_slider_value_changed(value: float) -> void:
	white_balance_value_label.text = "%dK" % roundi(value)
	_params["wb_temperature"] = value
	_request_render()


# --- Reset buttons ------------------------------------------------------------
# Each slider/module gets a small flat "↺" icon button that restores its default.
# Built in code (rather than in Main.tscn) so the one appearance/behaviour lives
# in one place and adding a module means one _add_slider_reset() line, matching
# the single-line-per-module convention _apply_params_to_backend() already uses.

# A small, flat, borderless icon button that blends into a slider row. focus is
# disabled so tabbing still lands on the sliders, not these secondary controls.
func _make_reset_button(tooltip_text: String) -> Button:
	var btn := Button.new()
	btn.text = "↺"
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = tooltip_text
	btn.custom_minimum_size = Vector2(24, 0)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_reset_buttons.append(btn)
	return btn


# Appends a reset button to a slider's row (the slider's HBoxContainer parent),
# so it sits just right of the value label. Setting slider.value fires the
# existing value_changed handler, which updates the label, _params and render --
# so a reset flows through the exact same path as a manual drag.
func _add_slider_reset(slider: HSlider, default_value: float) -> void:
	var btn := _make_reset_button("Reset to default")
	btn.pressed.connect(func() -> void: slider.value = default_value)
	slider.get_parent().add_child(btn)


func _setup_reset_buttons() -> void:
	_add_slider_reset(exposure_slider, 0.0)
	_add_slider_reset(contrast_slider, 0.0)
	_add_slider_reset(highlights_slider, -50.0)
	_add_slider_reset(shadows_slider, 50.0)
	_add_slider_reset(saturation_slider, 25.0)
	_add_slider_reset(vibrance_slider, 25.0)

	# White balance resets to the image's as-shot CCT, not a fixed constant --
	# the lambda reads _wb_default_temperature live so it tracks the loaded image.
	var wb_btn := _make_reset_button("Reset to as-shot white balance")
	wb_btn.pressed.connect(func() -> void:
		white_balance_slider.value = _wb_default_temperature)
	white_balance_slider.get_parent().add_child(wb_btn)

	# Tone curve: its "Tone Curve" label is a bare Label above the editor, so wrap
	# label + reset button in a row and drop it in at the label's old slot.
	var tone_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ToneCurveLabel
	var vbox: Node = tone_label.get_parent()
	var slot: int = tone_label.get_index()
	var tone_header := HBoxContainer.new()
	tone_header.add_theme_constant_override("separation", 8)
	vbox.add_child(tone_header)
	vbox.move_child(tone_header, slot)
	tone_label.reparent(tone_header)
	tone_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tone_btn := _make_reset_button("Reset tone curve")
	tone_btn.pressed.connect(func() -> void: tone_curve_editor.reset_to_default())
	tone_header.add_child(tone_btn)


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
	if not _render_gate_open():
		_arm_render_gate_timer()
		return
	_start_process()


# True once at least half the averaged render latency has passed since the last
# render started. Mirrors darktable's patience window (develop.c:296-297). A pipe
# that has never run is always open, so the first render is never delayed.
func _render_gate_open() -> bool:
	if _last_render_start_usec == 0:
		return true
	var elapsed_usec: int = Time.get_ticks_usec() - _last_render_start_usec
	return float(elapsed_usec) >= _render_avg_usec * 0.5


# True while a trailing render is counting down to the gate opening.
func _render_gate_pending() -> bool:
	return _gate_timer != null and not _gate_timer.is_stopped()


# Arm the one-shot trailing render for exactly the remaining sliver of the gate
# window. If a timer is already armed, leave it: it points at the same absolute
# deadline, so re-arming on every tick would turn the adaptive gate into a fixed
# debounce that delays the trailing render indefinitely.
func _arm_render_gate_timer() -> void:
	if _render_gate_pending():
		return
	var remaining_usec: float = _render_avg_usec * 0.5 \
		- float(Time.get_ticks_usec() - _last_render_start_usec)
	if remaining_usec <= 1000.0:
		# Gate is effectively open; skip the timer round-trip.
		_start_process()
		return
	_gate_timer.start(remaining_usec / 1000000.0)


# Drop all gate state. Called on image load: the old image's latency history and
# any in-flight trailing render are meaningless for the new one. Safe to call
# while a render is in flight: _on_process_done() measures that render's own
# start time, so the EWMA update is not corrupted by this reset.
func _reset_render_gate() -> void:
	if _gate_timer != null:
		_gate_timer.stop()
	_render_queued = false
	_render_avg_usec = 0.0
	_last_render_start_usec = 0


func _on_render_gate_timeout() -> void:
	if backend == null or not _image_loaded or _exporting:
		return
	if _processing:
		# A render slipped in while we waited; fold this into the queued follow-up
		# so the latest value still renders when that one completes.
		_render_queued = true
		return
	_start_process()


# True if `key`'s desired value differs from what was last pushed. A key that has
# never been applied counts as different, which is what makes the first render
# after an image load a full sync.
func _params_differ(key: String) -> bool:
	if not _applied_params.has(key):
		return true
	return _params[key] != _applied_params[key]


# Record the values just pushed. Arrays are duplicated so a later in-place edit
# (e.g. ToneCurveEditor mutating its points) can't silently mutate the snapshot.
func _snapshot_applied_params() -> void:
	for key in _params:
		var value: Variant = _params[key]
		if value is PackedVector2Array:
			value = (value as PackedVector2Array).duplicate()
		_applied_params[key] = value


# Push the current desired parameters into their darktable modules. This is the
# ONE place that maps _params keys to backend setters, so adding a module means
# adding one guarded line here. Runs on the main thread: darktable's set_* calls
# mutate process-wide pipe state and must not race the worker's render_view().
#
# Only params that actually changed since the last apply are pushed. Every setter
# calls dt_dev_add_history_item_ext(), and darktable only dedups history against
# the LAST item on the stack (which is always the crop item), so re-pushing all
# nine on every render appended up to 9 history items per slider tick, and every
# render replayed all of it: that is the slowdown that grew the longer you dragged.
func _apply_params_to_backend() -> void:
	if _params_differ("exposure"):
		backend.set_exposure(_params["exposure"])
	if _params_differ("contrast"):
		backend.set_contrast(_params["contrast"])
	if _params_differ("highlights"):
		backend.set_highlights(_params["highlights"])
	if _params_differ("shadows"):
		backend.set_shadows(_params["shadows"])
	if _params_differ("saturation"):
		backend.set_saturation(_params["saturation"])
	if _params_differ("vibrance"):
		backend.set_vibrance(_params["vibrance"])
	if _params_differ("tonecurve"):
		backend.set_tonecurve(_params["tonecurve"])
	if _params_differ("wb_temperature"):
		backend.set_white_balance_temperature(_params["wb_temperature"])
	if _params_differ("crop"):
		var crop: Rect2 = _params["crop"]
		backend.set_crop(crop.position.x, crop.position.y, crop.end.x, crop.end.y)
	_snapshot_applied_params()


func _start_process() -> void:
	if backend == null or not _image_loaded or _exporting:
		return

	_processing = true
	_render_queued = false
	# Cancel any trailing render still counting down: this render supersedes it
	# (same re-snapshotted _params), so letting it fire would be a wasted run.
	if _gate_timer != null:
		_gate_timer.stop()
	_render_start_usec = Time.get_ticks_usec()
	_last_render_start_usec = _render_start_usec
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
	# Update the render-latency EWMA before deciding whether to start a follow-up.
	# Uses the in-flight render's own start time (not _last_render_start_usec, which
	# an image load may have reset to 0 while this render was in flight). Same
	# recurrence as darktable's _dev_average_delay_update() (develop.c:628-633).
	var elapsed_usec: int = Time.get_ticks_usec() - _render_start_usec
	_render_avg_usec += float(elapsed_usec) / _RENDER_AVG_COUNT \
		- _render_avg_usec / _RENDER_AVG_COUNT

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
			# A new buffer means new Fit-letterbox geometry; keep the crop
			# overlay (if open) glued to the drawn image region.
			if _crop_overlay != null:
				_crop_overlay.sync_to_texture()
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
		# Routed through _request_render() so the same EWMA gate applies to the
		# follow-up: a burst of ticks collapses into fewer frames instead of always
		# running back-to-back. A deferred follow-up keeps export disabled until it
		# actually starts.
		_render_queued = false
		_request_render()
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
		# smaller -> the CenterContainer wrapper (Scroll/Center) keeps it centered
		# instead of pinned to the ScrollContainer's default top-left corner.
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
	# Dragging the slider always means an explicit positive zoom, so drop out
	# of Fit. Routed through _set_display_zoom() so the slider anchors on the
	# viewport center exactly like Cmd+wheel/pinch, instead of drifting to the
	# top-left corner the way a bare _apply_zoom_change() call would.
	_set_display_zoom(value)


func _on_theme_button_pressed() -> void:
	ThemeManager.toggle_theme()


func _on_theme_changed(is_dark: bool) -> void:
	theme_button.text = "Light Mode" if is_dark else "Dark Mode"
	if _crop_overlay != null:
		_crop_overlay.apply_theme(is_dark)


func _on_fit_button_toggled(pressed: bool) -> void:
	if pressed:
		# Engage the Fit sentinel; leave the slider where it is as a fallback.
		# No anchor math needed -- Fit is always centered via the Center wrapper.
		_display_zoom = -1.0
		_apply_zoom_change()
	else:
		# Fit released -> snap to whatever the slider currently reads, anchored
		# on the viewport center (== image center, since Fit was centered).
		_set_display_zoom(zoom_slider.value)


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
		# Cmd+wheel (Ctrl+wheel on Windows/Linux) zooms instead of the
		# ScrollContainer's default wheel-scroll, so only claim wheel events
		# when the modifier is held.
		if event.pressed and event.is_command_or_control_pressed():
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_zoom_by_factor(1.1)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_zoom_by_factor(1.0 / 1.1)
		return

	if event is InputEventMouseMotion and _dragging:
		scroll_container.scroll_horizontal -= int(event.relative.x)
		scroll_container.scroll_vertical -= int(event.relative.y)
		return

	# Trackpad pinch. factor is already a multiplier centered on 1.0 (>1 =
	# fingers spreading = zoom in), so it feeds _zoom_by_factor directly.
	if event is InputEventMagnifyGesture:
		_zoom_by_factor(event.factor)
		return

	# Trackpad two-finger scroll arrives as InputEventPanGesture, not
	# InputEventMouseButton wheel events, so Cmd+scroll needs its own branch.
	# delta.y < 0 means scrolling up (away from the user) => zoom in.
	if event is InputEventPanGesture and event.is_command_or_control_pressed():
		if event.delta.y < 0.0:
			_zoom_by_factor(1.05)
		elif event.delta.y > 0.0:
			_zoom_by_factor(1.0 / 1.05)


func _zoom_by_factor(multiplier: float) -> void:
	# Cmd+wheel / pinch entry point: turn a relative multiplier into an
	# absolute target percent, then hand off to the same path the slider and
	# Fit-release use.
	if backend == null:
		return
	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0:
		return
	var old_effective_zoom: float
	if _display_zoom < 0.0:
		var viewport_size: Vector2 = scroll_container.size
		old_effective_zoom = min(viewport_size.x / float(native_w), viewport_size.y / float(native_h))
	else:
		old_effective_zoom = _display_zoom
	_set_display_zoom(old_effective_zoom * 100.0 * multiplier)


func _set_display_zoom(target_pct: float) -> void:
	# Single path for every way display zoom can change (slider drag, Fit
	# release, Cmd+wheel, trackpad pinch): compute the pre-zoom anchor point,
	# apply the new zoom, then re-center scroll on that same point so all
	# inputs behave identically instead of each hand-rolling its own scroll
	# math (the slider used to just call _apply_zoom_change() directly, which
	# left scroll untouched and drifted the image toward the top-left corner).
	if backend == null:
		return
	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0:
		return
	var viewport_size: Vector2 = scroll_container.size

	# Ratio (0..1 per axis) of the viewport-center point within the current
	# content. Fit mode has no scrollbars and is always centered, so the
	# viewport center is always the image center regardless of letterboxing.
	var ratio: Vector2
	if _display_zoom < 0.0:
		ratio = Vector2(0.5, 0.5)
	else:
		var old_content_size: Vector2 = Vector2(native_w, native_h) * _display_zoom
		if old_content_size.x > 0.0 and old_content_size.y > 0.0:
			var center_old: Vector2 = Vector2(scroll_container.scroll_horizontal, scroll_container.scroll_vertical) + viewport_size / 2.0
			ratio = center_old / old_content_size
		else:
			ratio = Vector2(0.5, 0.5)

	target_pct = clamp(target_pct, _ZOOM_MIN_PCT, _ZOOM_MAX_PCT)
	_display_zoom = target_pct / 100.0
	zoom_slider.set_value_no_signal(target_pct)
	fit_button.set_pressed_no_signal(false)
	_apply_zoom_change()

	# Re-center scroll on the same content ratio at the new zoom, so whatever
	# was under the cursor/viewport-center stays there across zoom -> pan ->
	# zoom sequences. scroll_horizontal/vertical clamp against the
	# ScrollContainer's own H/V ScrollBar max_value/page, which only get
	# recomputed on the container's *next* layout pass (one or more frames
	# after TextureRect's resize propagates up through the Center wrapper) --
	# waiting for that (even polling) is racy. Instead, push the scrollbars to
	# the new content size ourselves right now; Godot's own upcoming sort pass
	# will recompute the identical numbers, so this is just applying them a
	# frame early with no conflict.
	var new_content_size: Vector2 = Vector2(native_w, native_h) * _display_zoom
	var target_scroll: Vector2 = ratio * new_content_size - viewport_size / 2.0
	var h_bar: ScrollBar = scroll_container.get_h_scroll_bar()
	var v_bar: ScrollBar = scroll_container.get_v_scroll_bar()
	h_bar.max_value = new_content_size.x
	h_bar.page = viewport_size.x
	v_bar.max_value = new_content_size.y
	v_bar.page = viewport_size.y

	var max_scroll: Vector2 = Vector2(max(new_content_size.x - viewport_size.x, 0.0), max(new_content_size.y - viewport_size.y, 0.0))
	scroll_container.scroll_horizontal = roundi(clamp(target_scroll.x, 0.0, max_scroll.x))
	scroll_container.scroll_vertical = roundi(clamp(target_scroll.y, 0.0, max_scroll.y))


# --- Crop ----------------------------------------------------------------------
# The crop toggle opens an interactive overlay over the displayed image
# (CropOverlay.gd). Done commits the box into _params["crop"] and re-renders
# (the pixelpipe's clipping module now crops the output); clicking the button
# again reopens the overlay pre-seeded with the current crop so it can be
# resumed and adjusted. Cancel restores the pre-edit crop.
func _on_crop_button_toggled(pressed: bool) -> void:
	if not _image_loaded:
		crop_button.set_pressed_no_signal(false)
		return
	if pressed:
		_open_crop_overlay()
	else:
		_close_crop_overlay()


func _open_crop_overlay() -> void:
	if _crop_overlay != null:
		return
	_crop_overlay = CropOverlayScript.new()
	_crop_overlay.apply_theme(ThemeManager.is_dark)
	# Lift the committed crop for the duration of the edit so the overlay shows
	# (and edits against) the whole image; the box being edited is seeded from
	# the committed crop so re-opening resumes where the last Done left off.
	# The overlay re-syncs its own geometry on every zoom/Fit/host resize
	# (resized signal) and via sync_to_texture() when the lift render swaps the
	# buffer, so the box stays glued to the drawn image at all times.
	_crop_before_edit = _params["crop"]
	_params["crop"] = Rect2(0, 0, 1, 1)
	_request_render()
	_crop_overlay.open(texture_rect, _crop_before_edit)
	# Done/Cancel bar anchored to the visible pane so it stays clickable at any
	# zoom (the overlay itself is image-sized). Done closes over the live
	# overlay so it always commits the box's CURRENT state.
	var overlay: Control = _crop_overlay
	_crop_bar = CropOverlayScript.build_bar(scroll_container)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	_crop_bar.add_child(cancel_btn)
	var done_btn := Button.new()
	done_btn.text = "Done"
	_crop_bar.add_child(done_btn)
	done_btn.pressed.connect(func() -> void:
		_on_crop_overlay_applied(overlay.get_rect_normalized()))
	cancel_btn.pressed.connect(_on_crop_overlay_canceled)


func _close_crop_overlay() -> void:
	if _crop_overlay == null:
		return
	_crop_overlay.close()
	_crop_overlay = null
	if _crop_bar != null:
		# _crop_bar is the HBox; its parent PanelContainer is what was added to
		# the pane -- free that whole chrome subtree.
		_crop_bar.get_parent().queue_free()
		_crop_bar = null


func _on_crop_overlay_applied(rect: Rect2) -> void:
	_close_crop_overlay()
	crop_button.set_pressed_no_signal(false)
	_params["crop"] = rect
	_request_render()
	if rect == Rect2(0, 0, 1, 1):
		status_label.text = "Crop cleared"
	else:
		status_label.text = "Crop applied (%d%%, %d%%) - (%d%%, %d%%)" % [
			roundi(rect.position.x * 100), roundi(rect.position.y * 100),
			roundi(rect.end.x * 100), roundi(rect.end.y * 100)]


func _on_crop_overlay_canceled() -> void:
	_close_crop_overlay()
	crop_button.set_pressed_no_signal(false)
	# Restore the crop the pipe temporarily dropped when the overlay opened.
	_params["crop"] = _crop_before_edit
	_request_render()


func _on_export_button_pressed() -> void:
	# Also block while the crop overlay is open: it has temporarily lifted the
	# crop from the pipe, so an export now would export the uncropped frame. And
	# while a trailing render is armed: that render would otherwise start
	# underneath the export's full-res pipe run.
	if not _image_loaded or _exporting or _processing \
			or _render_gate_pending() or _crop_overlay != null:
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
	highlights_slider.editable = false
	shadows_slider.editable = false
	saturation_slider.editable = false
	vibrance_slider.editable = false
	white_balance_slider.editable = false
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
	highlights_slider.editable = true
	shadows_slider.editable = true
	saturation_slider.editable = true
	vibrance_slider.editable = true
	white_balance_slider.editable = true
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
