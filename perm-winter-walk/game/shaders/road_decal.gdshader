// Tyre ruts on roads and trodden lines on footpaths, multiplied over the snow.
// Multiplicative blending is order-independent, so overlapping ribbons at junctions
// simply darken (like real crossing tracks) instead of z-fighting.
//   UV  = (metres across the ribbon, -half..+half, metres along it)
//   UV2 = (half width, kind: 3 road, 4 path)
shader_type spatial;
render_mode blend_mul, unshaded, depth_draw_never, cull_back, fog_disabled, shadows_disabled;

// The Mobile renderer keeps its HDR colour buffer at half scale, and multiplicative
// blending does not undo that: compensate, or every decal would also halve the
// brightness of whatever it covers.
#if CURRENT_RENDERER == RENDERER_MOBILE
const float MUL_FIX = 2.0;
#else
const float MUL_FIX = 1.0;
#endif

uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float fade_start = 50.0;
uniform float fade_end = 130.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float across = UV.x;
	float along = UV.y;
	float half_w = UV2.x;
	int kind = int(UV2.y + 0.5);
	float n1 = texture(noise_tex, vec2(across * 0.25, along * 0.02)).g;
	float n2 = texture(noise_tex, vec2(across * 0.9, along * 0.11)).b;
	float dark = 0.0;
	if (kind == 3) {
		// Lanes about 3.3 m wide; wheel tracks 0.75 m either side of each lane centre.
		float lanes = max(1.0, floor(2.0 * half_w / 3.2 + 0.5));
		float lane_w = 2.0 * half_w / lanes;
		float l = fract((across + half_w) / lane_w) * lane_w - lane_w * 0.5;
		float wobble = (n1 - 0.5) * 0.35;
		float track = smoothstep(0.32, 0.08, abs(abs(l + wobble) - 0.78));
		float kerb = smoothstep(0.9, 0.2, half_w - abs(across)); // grey slush along the kerbs
		dark = track * (0.35 + 0.4 * n2) + kerb * 0.25 * n1;
	} else {
		float centre = smoothstep(0.55, 0.0, abs(across));
		dark = centre * (0.15 + 0.2 * n2);
	}
	float dist = length(world_pos - CAMERA_POSITION_WORLD);
	dark *= 1.0 - smoothstep(fade_start, fade_end, dist);
	// Slightly bluish-grey shadowing reads as compressed, dirty snow.
	ALBEDO = mix(vec3(1.0), vec3(0.42, 0.44, 0.5), clamp(dark, 0.0, 1.0)) * MUL_FIX;
}
