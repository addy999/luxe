extends Control

# Luxe: main scene controller bridging the GDExtension DtBackend to the UI.
# Two decoupled view knobs (edit resolution on the backend, display zoom on the
# frontend); see docs/PERF-IMPROVEMENT.md.

@onready var scroll_container: ScrollContainer = $Root/MiddleHBox/Scroll
@onready var texture_rect: TextureRect = $Root/MiddleHBox/Scroll/Center/TextureRect
@onready var empty_state: CenterContainer = $Root/MiddleHBox/EmptyState
@onready var exposure_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ExposureRow/ExposureSlider
@onready var exposure_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ExposureRow/ExposureValueLabel
@onready var contrast_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ContrastRow/ContrastSlider
@onready var contrast_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ContrastRow/ContrastValueLabel
@onready var highlights_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/HighlightsRow/HighlightsSlider
@onready var highlights_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/HighlightsRow/HighlightsValueLabel
@onready var shadows_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ShadowsRow/ShadowsSlider
@onready var shadows_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ShadowsRow/ShadowsValueLabel
@onready var blacks_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/BlacksRow/BlacksSlider
@onready var blacks_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/BlacksRow/BlacksValueLabel
@onready var whites_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/WhitesRow/WhitesSlider
@onready var whites_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/WhitesRow/WhitesValueLabel
@onready var dehaze_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/DehazeRow/DehazeSlider
@onready var dehaze_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/DehazeRow/DehazeValueLabel
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
@onready var resolution_label: Label = $Root/BottomBar/BottomRow/ResolutionLabel
@onready var zoom_slider: HSlider = $Root/TopBar/TopBarRow/ZoomSlider
@onready var fit_button: Button = $Root/TopBar/TopBarRow/FitButton
@onready var zoom_value_label: Label = $Root/TopBar/TopBarRow/ZoomValueLabel
@onready var file_dialog: FileDialog = $FileDialog
@onready var export_dialog: FileDialog = $ExportDialog
@onready var crop_button: Button = $Root/TopBar/TopBarRow/CropButton

const CropOverlayScript := preload("res://CropOverlay.gd")
var _crop_overlay: Control = null
var _crop_bar: HBoxContainer = null
var _crop_before_edit: Rect2 = Rect2(0, 0, 1, 1)
@onready var top_bar: PanelContainer = $Root/TopBar
@onready var right_panel: PanelContainer = $Root/MiddleHBox/RightPanel
@onready var bottom_bar: PanelContainer = $Root/BottomBar

var backend: DtBackend = null
var image_texture: ImageTexture = null

var _image_loaded: bool = false

# Per-image as-shot CCT; the WB reset target.
var _wb_default_temperature: float = 6500.0
var _reset_buttons: Array[Button] = []

# --- Edit state: the authoritative "what to render" ---------------------------
var _params: Dictionary = {
	"exposure": 0.0,
	"contrast": 0.0,
	"highlights": -50.0,
	"shadows": 50.0,
	"blacks": 0.0,
	"whites": 0.0,
	"dehaze": 0.0,
	"saturation": 25.0,
	"desaturation": 0.0,
	"vibrance": 25.0,
	"tonecurve": PackedVector2Array([Vector2(0.0, 0.0), Vector2(1.0, 1.0)]),
	"wb_temperature": 6500.0,
	"crop": Rect2(0, 0, 1, 1),
}

# --- Slider offsets vs. module defaults ----------------------------------------
const _MODULE_RANGES: Dictionary = {
	# key: [module_min, module_default, module_max]
	"highlights": [-100.0, -50.0, 100.0],
	"shadows": [-100.0, 50.0, 100.0],
	"saturation": [0.0, 25.0, 100.0],
	"vibrance": [0.0, 25.0, 100.0],
}


func _map_offset_to_module(key: String, offset: float) -> float:
	var range_vals: Array = _MODULE_RANGES[key]
	var lo: float = range_vals[0]
	var dflt: float = range_vals[1]
	var hi: float = range_vals[2]
	if offset <= 0.0:
		return lo + (offset + 50.0) / 50.0 * (dflt - lo)
	return dflt + offset / 50.0 * (hi - dflt)


# Last values pushed to the backend, keyed like _params.
var _applied_params: Dictionary = {}

var _processing: bool = false
# Set when a request arrived mid-render; exactly one follow-up runs.
var _render_queued: bool = false
var _current_task_id: int = -1

# --- Live-render EWMA gate (docs/PERF-IMPROVEMENT.md fix 4) --------------------
const _RENDER_AVG_COUNT: int = 8
var _render_avg_usec: float = 0.0        # EWMA of render start-to-start latency.
var _last_render_start_usec: int = 0     # Start time of the most recent render (0 = none).
var _render_start_usec: int = 0          # Start time of the in-flight render, for the EWMA.
var _gate_timer: Timer = null            # One-shot trailing render when the gate is shut.
var _exporting: bool = false
var _export_path: String = ""
var _source_basename: String = "export"

# --- Edit resolution (backend render scale) ------------------------------------
# Fraction of the preview mip the pipe processes; 100% uses the full pipe.
const _EDIT_MODES: Array = [
	{"id": 0, "label": "100%", "scale": 1.00},
	{"id": 1, "label": "75%", "scale": 0.75},
	{"id": 2, "label": "50%", "scale": 0.50},
	{"id": 3, "label": "25%", "scale": 0.25},
]
const _EDIT_DEFAULT_ID: int = 2 # 50%, fallback used until an image's size is known.
var _edit_scale: float = 0.50

# Size-adaptive default edit scale, by raw megapixels (tiers in order).
const _EDIT_DEFAULT_BY_SIZE: Array = [
	{"min_megapixels": 20.0, "id": 3}, # huge (e.g. medium format, stitched) -> 25%
	{"min_megapixels": 12.0, "id": 2}, # large (typical modern camera) -> 50%
	{"min_megapixels": 0.0, "id": 0},  # normal/HD -> 100%
]


func _pick_default_edit_mode_id(raw_w: int, raw_h: int) -> int:
	if raw_w <= 0 or raw_h <= 0:
		return _EDIT_DEFAULT_ID
	var megapixels: float = (raw_w * raw_h) / 1000000.0
	for tier in _EDIT_DEFAULT_BY_SIZE:
		if megapixels >= tier["min_megapixels"]:
			return tier["id"]
	return _EDIT_DEFAULT_ID

const _WHOLE_IMAGE_VIEWPORT: int = 1000000

# --- Display zoom (frontend TextureRect scale) --------------------------------
const _ZOOM_MIN_PCT: float = 10.0
const _ZOOM_MAX_PCT: float = 400.0
var _display_zoom: float = -1.0 # -1.0 = Fit; otherwise native-relative scale.

const _STRETCH_SCALE: int = 0
const _STRETCH_KEEP_ASPECT_CENTERED: int = 5

var _dragging: bool = false


# Dev-only env setup for the backend's datadir detection (docs/DARKTABLE_API_NOTES.md A).
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
	_gate_timer = Timer.new()
	_gate_timer.one_shot = true
	_gate_timer.timeout.connect(_on_render_gate_timeout)
	add_child(_gate_timer)

	_setup_reset_buttons()

	_animate_entrance()
	_update_empty_state()
	await get_tree().process_frame
	if not _init_backend():
		return
	_finish_ready()


# Physical (device) pixel size of the screen.
func _display_pixel_size() -> Vector2i:
	var screen: int = DisplayServer.window_get_current_screen()
	var screen_size: Vector2i = DisplayServer.screen_get_size(screen)
	if screen_size.x <= 0 or screen_size.y <= 0:
		return Vector2i.ZERO
	var dpi_scale: float = maxf(1.0, DisplayServer.screen_get_scale(screen))
	return Vector2i(roundi(screen_size.x * dpi_scale), roundi(screen_size.y * dpi_scale))


func _init_backend() -> bool:
	_configure_dt_backend_env()
	backend = DtBackend.new()
	var display_size: Vector2i = _display_pixel_size()
	var ok: bool = backend.init(display_size.x, display_size.y)
	if not ok:
		open_button.disabled = true
		exposure_slider.editable = false
		contrast_slider.editable = false
		highlights_slider.editable = false
		shadows_slider.editable = false
		blacks_slider.editable = false
		whites_slider.editable = false
		dehaze_slider.editable = false
		saturation_slider.editable = false
		vibrance_slider.editable = false
		white_balance_slider.editable = false
		for btn in _reset_buttons:
			btn.disabled = true
		return false
	return true


func _finish_ready() -> void:
	exposure_value_label.text = "%.2f" % exposure_slider.value
	contrast_value_label.text = "%.2f" % contrast_slider.value
	highlights_value_label.text = "%.2f" % highlights_slider.value
	shadows_value_label.text = "%.2f" % shadows_slider.value
	blacks_value_label.text = "%.2f" % blacks_slider.value
	whites_value_label.text = "%.2f" % whites_slider.value
	dehaze_value_label.text = "%.2f" % dehaze_slider.value
	saturation_value_label.text = "%.2f" % saturation_slider.value
	vibrance_value_label.text = "%.2f" % vibrance_slider.value
	white_balance_value_label.text = "%dK" % roundi(white_balance_slider.value)

	for mode in _EDIT_MODES:
		edit_res_option.add_item(mode["label"], mode["id"])
	edit_res_option.select(_EDIT_DEFAULT_ID)
	_edit_scale = _EDIT_MODES[_EDIT_DEFAULT_ID]["scale"]

	# Start in Fit; the scene already sets slider 100 + toggle on.
	_display_zoom = -1.0
	fit_button.set_pressed_no_signal(true)
	_update_zoom_readout()

	scroll_container.resized.connect(_on_scroll_resized)

	texture_rect.gui_input.connect(_on_texture_rect_gui_input)

	ThemeManager.theme_changed.connect(_on_theme_changed)
	_on_theme_changed(ThemeManager.is_dark)

	crop_button.toggled.connect(_on_crop_button_toggled)
	crop_button.disabled = true


func _update_empty_state() -> void:
	var empty: bool = not _image_loaded
	empty_state.visible = empty
	scroll_container.visible = not empty


func _animate_entrance() -> void:
	# One-shot launch animation: bars fade in and scale 0.98 -> 1.0, staggered
	# (tween modulate/scale, NOT position; see docs/GODOT_FRONTEND_NOTES.md).
	var bars: Array = [top_bar, right_panel, bottom_bar]
	for bar in bars:
		if bar != null:
			bar.modulate.a = 0.0
			bar.scale = Vector2(0.98, 0.98)
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

	var ok: bool = backend.load_image(path)
	if not ok:
		_image_loaded = false
		_update_empty_state()
		export_button.disabled = true
		return

	_image_loaded = true
	_update_empty_state()

	_applied_params.clear()
	_reset_render_gate()

	_source_basename = path.get_file().get_basename()
	export_button.disabled = false
	crop_button.disabled = false
	crop_button.set_pressed_no_signal(false)

	exposure_slider.value = 0.0
	exposure_value_label.text = "%.2f" % 0.0
	_params["exposure"] = 0.0
	contrast_slider.value = 0.0
	contrast_value_label.text = "%.2f" % 0.0
	_params["contrast"] = 0.0
	highlights_slider.value = 0.0
	highlights_value_label.text = "%.2f" % 0.0
	_params["highlights"] = _map_offset_to_module("highlights", 0.0)
	shadows_slider.value = 0.0
	shadows_value_label.text = "%.2f" % 0.0
	_params["shadows"] = _map_offset_to_module("shadows", 0.0)
	blacks_slider.value = 0.0
	blacks_value_label.text = "%.2f" % 0.0
	_params["blacks"] = 0.0
	whites_slider.value = 0.0
	whites_value_label.text = "%.2f" % 0.0
	_params["whites"] = 0.0
	dehaze_slider.value = 0.0
	dehaze_value_label.text = "%.2f" % 0.0
	_params["dehaze"] = 0.0
	saturation_slider.value = 0.0
	saturation_value_label.text = "%.2f" % 0.0
	_params["saturation"] = _map_offset_to_module("saturation", 0.0)
	_params["desaturation"] = 0.0
	vibrance_slider.value = 0.0
	vibrance_value_label.text = "%.2f" % 0.0
	_params["vibrance"] = _map_offset_to_module("vibrance", 0.0)
	tone_curve_editor.reset_to_default()
	var as_shot_temperature: float = backend.get_white_balance_temperature()
	white_balance_slider.value = as_shot_temperature
	white_balance_value_label.text = "%dK" % roundi(as_shot_temperature)
	_params["wb_temperature"] = as_shot_temperature
	_params["crop"] = Rect2(0, 0, 1, 1)
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
	_params["highlights"] = _map_offset_to_module("highlights", value)
	_request_render()


func _on_shadows_slider_value_changed(value: float) -> void:
	shadows_value_label.text = "%.2f" % value
	_params["shadows"] = _map_offset_to_module("shadows", value)
	_request_render()


func _on_blacks_slider_value_changed(value: float) -> void:
	blacks_value_label.text = "%.2f" % value
	_params["blacks"] = -value
	_request_render()


func _on_whites_slider_value_changed(value: float) -> void:
	whites_value_label.text = "%.2f" % value
	_params["whites"] = value
	_request_render()


func _on_dehaze_slider_value_changed(value: float) -> void:
	dehaze_value_label.text = "%.2f" % value
	_params["dehaze"] = value
	_request_render()


func _on_saturation_slider_value_changed(value: float) -> void:
	saturation_value_label.text = "%.2f" % value
	if value > 0.0:
		_params["saturation"] = _map_offset_to_module("saturation", value)
		_params["desaturation"] = 0.0
	else:
		_params["saturation"] = _map_offset_to_module("saturation", 0.0)
		_params["desaturation"] = -value / 50.0
	_request_render()


func _on_vibrance_slider_value_changed(value: float) -> void:
	vibrance_value_label.text = "%.2f" % value
	_params["vibrance"] = _map_offset_to_module("vibrance", value)
	_request_render()


func _on_tone_curve_changed(points: PackedVector2Array) -> void:
	_params["tonecurve"] = points
	_request_render()


func _on_white_balance_slider_value_changed(value: float) -> void:
	white_balance_value_label.text = "%dK" % roundi(value)
	_params["wb_temperature"] = value
	_request_render()


# --- Reset buttons ------------------------------------------------------------

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


func _add_slider_reset(slider: HSlider, default_value: float) -> void:
	var btn := _make_reset_button("Reset to default")
	btn.pressed.connect(func() -> void: slider.value = default_value)
	slider.get_parent().add_child(btn)


func _setup_reset_buttons() -> void:
	_add_slider_reset(exposure_slider, 0.0)
	_add_slider_reset(contrast_slider, 0.0)
	_add_slider_reset(highlights_slider, 0.0)
	_add_slider_reset(shadows_slider, 0.0)
	_add_slider_reset(blacks_slider, 0.0)
	_add_slider_reset(whites_slider, 0.0)
	_add_slider_reset(saturation_slider, 0.0)
	_add_slider_reset(vibrance_slider, 0.0)

	var wb_btn := _make_reset_button("Reset to as-shot white balance")
	wb_btn.pressed.connect(func() -> void:
		white_balance_slider.value = _wb_default_temperature)
	white_balance_slider.get_parent().add_child(wb_btn)

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


# Single entry point for every control; coalesces edits into one render at a time.
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


func _render_gate_open() -> bool:
	if _last_render_start_usec == 0:
		return true
	var elapsed_usec: int = Time.get_ticks_usec() - _last_render_start_usec
	return float(elapsed_usec) >= _render_avg_usec * 0.5


func _render_gate_pending() -> bool:
	return _gate_timer != null and not _gate_timer.is_stopped()


func _arm_render_gate_timer() -> void:
	if _render_gate_pending():
		return
	var remaining_usec: float = _render_avg_usec * 0.5 \
		- float(Time.get_ticks_usec() - _last_render_start_usec)
	if remaining_usec <= 1000.0:
		_start_process()
		return
	_gate_timer.start(remaining_usec / 1000000.0)


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
		_render_queued = true
		return
	_start_process()


func _params_differ(key: String) -> bool:
	if not _applied_params.has(key):
		return true
	return _params[key] != _applied_params[key]


func _snapshot_applied_params() -> void:
	for key in _params:
		var value: Variant = _params[key]
		if value is PackedVector2Array:
			value = (value as PackedVector2Array).duplicate()
		_applied_params[key] = value


# The ONE place mapping _params keys to backend setters; only changed params are pushed.
func _apply_params_to_backend() -> void:
	if _params_differ("exposure"):
		backend.set_exposure(_params["exposure"])
	if _params_differ("contrast"):
		backend.set_contrast(_params["contrast"])
	if _params_differ("highlights"):
		backend.set_highlights(_params["highlights"])
	if _params_differ("shadows"):
		backend.set_shadows(_params["shadows"])
	if _params_differ("blacks"):
		backend.set_blacks(_params["blacks"])
	if _params_differ("whites"):
		backend.set_whites(_params["whites"])
	if _params_differ("dehaze"):
		backend.set_dehaze(_params["dehaze"])
	if _params_differ("saturation"):
		backend.set_saturation(_params["saturation"])
	if _params_differ("desaturation"):
		backend.set_desaturation(_params["desaturation"])
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
	if _gate_timer != null:
		_gate_timer.stop()
	_render_start_usec = Time.get_ticks_usec()
	_last_render_start_usec = _render_start_usec
	export_button.disabled = true
	_apply_params_to_backend()

	var edit_scale: float = _edit_scale
	var final_quality: bool = _final_quality()
	_current_task_id = WorkerThreadPool.add_task(_process_task.bind(edit_scale, final_quality))


func _final_quality() -> bool:
	return _edit_scale >= 0.999


func _process_task(edit_scale: float, final_quality: bool) -> void:
	var bytes: PackedByteArray
	if final_quality:
		bytes = backend.render_view(
			_WHOLE_IMAGE_VIEWPORT, _WHOLE_IMAGE_VIEWPORT, edit_scale, 0.0, 0.0)
	else:
		bytes = backend.render_preview(
			_WHOLE_IMAGE_VIEWPORT, _WHOLE_IMAGE_VIEWPORT, edit_scale, 0.0, 0.0)
	var width: int = backend.get_width()
	var height: int = backend.get_height()
	call_deferred("_on_process_done", bytes, width, height)


func _on_process_done(bytes: PackedByteArray, width: int, height: int) -> void:
	var elapsed_usec: int = Time.get_ticks_usec() - _render_start_usec
	_render_avg_usec += float(elapsed_usec) / _RENDER_AVG_COUNT \
		- _render_avg_usec / _RENDER_AVG_COUNT

	if width > 0 and height > 0 and bytes.size() >= width * height * 4:
		var img: Image = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, bytes)
		if image_texture == null \
				or image_texture.get_width() != width \
				or image_texture.get_height() != height:
			image_texture = ImageTexture.create_from_image(img)
			texture_rect.texture = image_texture
			if _crop_overlay != null:
				_crop_overlay.sync_to_texture()
		else:
			image_texture.update(img)
		_apply_display_layout()
		_update_resolution_label(width, height)

	_processing = false

	if _render_queued and _image_loaded and not _exporting:
		_render_queued = false
		_request_render()
	elif _image_loaded and not _exporting:
		export_button.disabled = false


func _apply_display_layout() -> void:
	if image_texture == null:
		return
	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0:
		return

	if _display_zoom < 0.0:
		texture_rect.stretch_mode = _STRETCH_KEEP_ASPECT_CENTERED
		texture_rect.custom_minimum_size = scroll_container.size
	else:
		texture_rect.stretch_mode = _STRETCH_SCALE
		texture_rect.custom_minimum_size = Vector2(native_w, native_h) * _display_zoom


func _on_scroll_resized() -> void:
	if not _image_loaded:
		return
	_apply_display_layout()


func _on_edit_res_option_button_item_selected(index: int) -> void:
	var id: int = edit_res_option.get_item_id(index)
	_edit_scale = _EDIT_MODES[id]["scale"]
	_request_render()


func _on_zoom_slider_value_changed(value: float) -> void:
	_set_display_zoom(value)


func _on_theme_button_pressed() -> void:
	ThemeManager.toggle_theme()


func _on_theme_changed(is_dark: bool) -> void:
	theme_button.text = "Light Mode" if is_dark else "Dark Mode"
	if _crop_overlay != null:
		_crop_overlay.apply_theme(is_dark)


func _on_fit_button_toggled(pressed: bool) -> void:
	if pressed:
		_display_zoom = -1.0
		_apply_zoom_change()
	else:
		_set_display_zoom(zoom_slider.value)


func _apply_zoom_change() -> void:
	_update_zoom_readout()
	if not _image_loaded:
		return
	_apply_display_layout()
	if image_texture != null:
		_update_resolution_label(image_texture.get_width(), image_texture.get_height())
	else:
		_update_resolution_label(0, 0)


func _update_zoom_readout() -> void:
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
	if backend == null:
		resolution_label.text = "No image loaded"
		return
	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0 or buf_w <= 0 or buf_h <= 0:
		resolution_label.text = "No image loaded"
		return

	var buffer_scale: float = float(buf_w) / float(native_w)
	var edit_pct: int = roundi(buffer_scale * 100.0)
	var mode: String = "final" if _final_quality() else "fast"

	var disp_zoom: float
	if _display_zoom < 0.0:
		var avail: Vector2 = scroll_container.size
		disp_zoom = min(avail.x / float(native_w), avail.y / float(native_h))
	else:
		disp_zoom = _display_zoom
	var screen_w: int = roundi(disp_zoom * float(native_w))
	var screen_h: int = roundi(disp_zoom * float(native_h))
	var disp_label: String = "Fit" if _display_zoom < 0.0 else "%d%%" % roundi(disp_zoom * 100.0)

	var buffer_upscale: float = disp_zoom / buffer_scale
	var quality: String = ""
	if buffer_upscale > 1.001:
		quality = "  [upscaled %.1fx - soft]" % buffer_upscale
	elif disp_zoom >= 0.999 and buffer_scale >= 0.999:
		quality = "  [1:1 native pixels]"

	resolution_label.text = "Native %dx%d  |  Editing @ %dx%d |  Display %s" % [
		native_w, native_h, buf_w, buf_h, disp_label]


func _on_texture_rect_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
			return
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

	if event is InputEventMagnifyGesture:
		_zoom_by_factor(event.factor)
		return

	if event is InputEventPanGesture and event.is_command_or_control_pressed():
		if event.delta.y < 0.0:
			_zoom_by_factor(1.05)
		elif event.delta.y > 0.0:
			_zoom_by_factor(1.0 / 1.05)


func _zoom_by_factor(multiplier: float) -> void:
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
	if backend == null:
		return
	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0:
		return
	var viewport_size: Vector2 = scroll_container.size

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

	# Re-center on the same content ratio (scroll bar max/page are pushed manually;
	# see docs/GODOT_FRONTEND_NOTES.md).
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
	# Lift the committed crop so the overlay edits against the whole image.
	_crop_before_edit = _params["crop"]
	_params["crop"] = Rect2(0, 0, 1, 1)
	_request_render()
	_crop_overlay.open(texture_rect, _crop_before_edit)
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
		_crop_bar.get_parent().queue_free()
		_crop_bar = null


func _on_crop_overlay_applied(rect: Rect2) -> void:
	_close_crop_overlay()
	crop_button.set_pressed_no_signal(false)
	_params["crop"] = rect
	_request_render()


func _on_crop_overlay_canceled() -> void:
	_close_crop_overlay()
	crop_button.set_pressed_no_signal(false)
	_params["crop"] = _crop_before_edit
	_request_render()


func _on_export_button_pressed() -> void:
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
	blacks_slider.editable = false
	whites_slider.editable = false
	saturation_slider.editable = false
	vibrance_slider.editable = false
	white_balance_slider.editable = false

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
	blacks_slider.editable = true
	whites_slider.editable = true
	saturation_slider.editable = true
	vibrance_slider.editable = true
	white_balance_slider.editable = true
	export_button.disabled = not _image_loaded
	if not ok:
		push_error("Export failed for %s" % path.get_file())


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
