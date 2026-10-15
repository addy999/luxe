extends Control

# Pan/zoom bird's-eye of the edited image. Main.gd pushes the current render
# texture plus the visible-region rect (in 0..1 image fractions); this widget
# letterboxes the texture into its box, draws a viewport outline, and signals
# back a new center fraction when the user clicks/drags inside.

signal pan_to(center: Vector2)   # center of desired viewport, image fractions

var _tex: Texture2D = null
var _viewport := Rect2(0, 0, 1, 1)   # visible region, image fractions
var _dragging: bool = false

const _BG := Color(0, 0, 0, 0.6)       # floating backdrop (padded border frame)
const _DIM := Color(0, 0, 0, 0.45)
const _FRAME := Color(1, 1, 1, 0.9)
const _EDGE := Color(1, 1, 1, 0.25)    # outer outline of the floating widget
const _PAD := 6.0                      # backdrop padding around the thumbnail


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func set_texture(tex: Texture2D) -> void:
	_tex = tex
	queue_redraw()


func set_viewport(frac: Rect2) -> void:
	_viewport = frac
	queue_redraw()


# Letterboxed on-screen rect of the texture within this control (matches
# CropOverlay's fit math).
func _image_rect() -> Rect2:
	var inner := size - Vector2(_PAD, _PAD) * 2.0
	if _tex == null:
		return Rect2(Vector2(_PAD, _PAD), inner)
	var t := _tex.get_size()
	if t.x <= 0.0 or t.y <= 0.0:
		return Rect2(Vector2(_PAD, _PAD), inner)
	var s: float = min(inner.x / t.x, inner.y / t.y)
	var drawn := t * s
	return Rect2((size - drawn) * 0.5, drawn)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _BG)
	draw_rect(Rect2(Vector2.ZERO, size), _EDGE, false, 1.0)
	if _tex == null:
		return
	var img := _image_rect()
	draw_texture_rect(_tex, img, false)
	# Viewport box within the drawn image.
	var box := Rect2(img.position + _viewport.position * img.size, _viewport.size * img.size)
	# Dim everything outside the visible region.
	draw_rect(Rect2(img.position, Vector2(img.size.x, box.position.y - img.position.y)), _DIM)
	draw_rect(Rect2(img.position.x, box.end.y, img.size.x, img.end.y - box.end.y), _DIM)
	draw_rect(Rect2(img.position.x, box.position.y, box.position.x - img.position.x, box.size.y), _DIM)
	draw_rect(Rect2(box.end.x, box.position.y, img.end.x - box.end.x, box.size.y), _DIM)
	draw_rect(box, _FRAME, false, 1.5)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if event.pressed:
			_emit_pan(event.position)
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_emit_pan(event.position)
		accept_event()


# Map a mouse point to a center fraction and request a pan there.
func _emit_pan(p: Vector2) -> void:
	var img := _image_rect()
	if img.size.x <= 0.0 or img.size.y <= 0.0:
		return
	var frac := (p - img.position) / img.size
	pan_to.emit(frac.clamp(Vector2.ZERO, Vector2.ONE))
