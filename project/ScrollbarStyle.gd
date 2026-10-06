class_name ScrollbarStyle

# Scrollbar thickness, applied app-wide for a consistent easy-to-grab bar.
# Colors and rounding live in the shared themes (scroll_track / scroll_grabber*
# styleboxes); only the pixel width is a per-ScrollContainer property in Godot 4
# (it comes from the bar's custom_minimum_size, not the stylebox).

const WIDTH: int = 16


# Widens both scrollbars of a ScrollContainer. Safe to call in _ready.
static func widen(scroll: ScrollContainer) -> void:
	scroll.get_v_scroll_bar().custom_minimum_size = Vector2(WIDTH, 0)
	scroll.get_h_scroll_bar().custom_minimum_size = Vector2(0, WIDTH)
