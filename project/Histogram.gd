extends Control

# RGB histogram of the rendered frame. Main.gd pushes 768 bins (R, G, B x 256);
# each channel draws as a translucent filled curve so overlaps read as mixed
# colour. Bar height is normalised to the tallest bin excluding the two end
# bins, so a clipped spike at 0/255 runs off the top instead of flattening
# the rest of the curve.

const _BG := Color(0, 0, 0, 0.35)
const _EDGE := Color(1, 1, 1, 0.12)
const _CHANNELS := [Color(1.0, 0.3, 0.3, 0.55), Color(0.3, 1.0, 0.4, 0.55), Color(0.35, 0.55, 1.0, 0.55)]

var _bins := PackedInt32Array()


func _ready() -> void:
	custom_minimum_size = Vector2(0, 84)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_bins(bins: PackedInt32Array) -> void:
	_bins = bins
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _BG)
	if _bins.size() == 768:
		var peak := 1
		for c in 3:
			for i in range(1, 255):
				peak = maxi(peak, _bins[c * 256 + i])
		var col_w := size.x / 256.0
		for c in 3:
			for i in 256:
				var h := minf(float(_bins[c * 256 + i]) / peak, 1.0) * size.y
				if h > 0.0:
					draw_rect(Rect2(i * col_w, size.y - h, col_w + 0.5, h), _CHANNELS[c])
	draw_rect(Rect2(Vector2.ZERO, size), _EDGE, false)
