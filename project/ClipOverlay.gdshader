shader_type canvas_item;

// Display overlays on the edit render. While show_clipping is on, blown pixels (any channel >= 250) tint red and
// crushed pixels (all channels <= 5) tint blue.
uniform bool show_clipping = false;
// Focus peaking: Sobel on luma in texture-pixel space; gradients above
// peaking_threshold (0..1) paint green.
uniform bool show_peaking = false;
uniform float peaking_threshold = 0.12;

// Macro, not a function: TEXTURE built-ins cannot be passed into functions.
#define L(o) dot(texture(TEXTURE, UV + (o) * TEXTURE_PIXEL_SIZE).rgb, vec3(0.299, 0.587, 0.114))

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	if (show_clipping) {
		float m = max(c.r, max(c.g, c.b));
		if (m >= 250.0 / 255.0) {
			c.rgb = mix(c.rgb, vec3(1.0, 0.1, 0.1), 0.85);
		} else if (m <= 5.0 / 255.0) {
			c.rgb = mix(c.rgb, vec3(0.1, 0.3, 1.0), 0.85);
		}
	}
	if (show_peaking) {
		float gx = -L(vec2(-1, -1)) - 2.0 * L(vec2(-1, 0)) - L(vec2(-1, 1))
			+ L(vec2(1, -1)) + 2.0 * L(vec2(1, 0)) + L(vec2(1, 1));
		float gy = -L(vec2(-1, -1)) - 2.0 * L(vec2(0, -1)) - L(vec2(1, -1))
			+ L(vec2(-1, 1)) + 2.0 * L(vec2(0, 1)) + L(vec2(1, 1));
		if (length(vec2(gx, gy)) / 4.0 > peaking_threshold) {
			c.rgb = vec3(0.1, 1.0, 0.2);
		}
	}
	COLOR = c;
}
