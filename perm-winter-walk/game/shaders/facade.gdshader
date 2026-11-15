// Building walls with procedural windows (no window geometry at all).
//
// Per vertex (set by chunk_loader.gd):
//   UV      = (metres along this wall segment, metres above ground)
//   UV2     = (levels, wall height)
//   COLOR   = (facade tint rgb, building seed)
//   CUSTOM0 = (segment length, floor height, kind (+8 if landmark), share of windows lit)
//
// Each window gets its own random state from (segment, column, floor, building seed):
// lit or dark, colour temperature, brightness, and a small share flicker (TVs, tired
// bulbs). Lit windows are emissive so the glow (bloom) pass halos them.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_schlick_ggx;

uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D light_map : hint_default_black, filter_linear, repeat_disable;
uniform vec4 light_rect = vec4(0.0, 0.0, 0.004, 0.004);
uniform float light_strength = 2.4;
uniform float window_emission = 1.6;
uniform float flicker_share = 0.05;
uniform float landmark_flood = 0.9;

varying vec4 bdata;
varying vec2 bshape;
varying vec3 world_pos;
varying vec3 world_normal;

const int B_RESIDENTIAL = 0;
const int B_COMMERCIAL = 1;
const int B_PUBLIC = 2;
const int B_UTILITY = 3;
const int B_RELIGIOUS = 4;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	bdata = CUSTOM0;
	bshape = UV2;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float seg_len = bdata.x;
	float floor_h = bdata.y;
	bool landmark = bdata.z > 7.5;
	int kind = int(mod(bdata.z, 8.0) + 0.5);
	float lit_share = bdata.w;
	float levels = bshape.x;
	float wall_h = bshape.y;
	float seed = COLOR.a;
	float u = UV.x;
	float v = UV.y;

	// ---- wall surface
	float grime = texture(noise_tex, vec2(u * 0.05, v * 0.08) + seed * 7.0).g;
	vec3 wall = COLOR.rgb * (0.82 + 0.3 * grime);
	if (kind == B_RESIDENTIAL && seed < 0.45) {
		// Soviet panel block: seams between panels and floors.
		float seam_v = smoothstep(0.03, 0.0, abs(fract(v / floor_h) - 0.02));
		float seam_u = smoothstep(0.02, 0.0, abs(fract(u / 3.2) - 0.5) - 0.48);
		wall *= 1.0 - 0.25 * max(seam_v, seam_u);
	}
	wall *= mix(0.6, 1.0, smoothstep(0.3, 0.8, v));             // darker plinth
	wall *= 1.0 - 0.3 * smoothstep(wall_h - 0.5, wall_h - 0.1, v); // cornice
	float snow_line = 0.25 + 0.2 * texture(noise_tex, vec2(u * 0.3, seed)).r;
	wall = mix(wall, vec3(0.85, 0.88, 0.95), smoothstep(snow_line, snow_line - 0.08, v)); // snow at the foot

	// ---- window grid, centred on the wall segment
	bool shopfront = (kind == B_COMMERCIAL || kind == B_PUBLIC || (kind == B_RESIDENTIAL && seed > 0.7));
	float pitch = (kind == B_COMMERCIAL) ? 2.6 : 3.0 + seed * 0.5;
	float n_cols = floor(max(seg_len - 1.2, 0.0) / pitch);
	float margin = (seg_len - n_cols * pitch) * 0.5;
	float col_f = (u - margin) / pitch;
	float col = floor(col_f);
	float row_f = v / floor_h;
	float row = floor(row_f);
	vec2 cell = vec2(fract(col_f), fract(row_f));
	bool has_windows = kind != B_UTILITY && kind != B_RELIGIOUS && n_cols >= 1.0;
	bool in_grid = has_windows && col >= 0.0 && col < n_cols && row < levels && v < wall_h - 0.4;

	bool ground_shop = shopfront && row < 1.0;
	vec2 wmin = ground_shop ? vec2(0.08, 0.12) : vec2(0.27, 0.3);
	vec2 wmax = ground_shop ? vec2(0.92, 0.82) : vec2(0.73, 0.8);
	vec2 aa = fwidth(vec2(col_f, row_f)) * 1.2 + 1e-4;
	vec2 inside = smoothstep(wmin - aa, wmin + aa, cell) * (1.0 - smoothstep(wmax - aa, wmax + aa, cell));
	float win = in_grid ? inside.x * inside.y : 0.0;

	// Per-window random state; NORMAL and length keep different segments different.
	vec2 seg_id = vec2(floor(seg_len * 7.31) + floor(world_normal.x * 9.0) * 31.0,
	                   floor(world_normal.z * 9.0) + seed * 113.0);
	vec2 wid = vec2(col, row) + seg_id * 17.0;
	float r_on = hash12(wid);
	float r_col = hash12(wid + 3.7);
	float r_int = hash12(wid + 9.1);
	float r_flk = hash12(wid + 21.3);

	float on = step(r_on, ground_shop ? 0.75 : lit_share);
	vec3 lamp_col = vec3(1.0, 0.66, 0.32);                     // incandescent / warm LED
	if (r_col > 0.55) lamp_col = vec3(1.0, 0.8, 0.52);
	if (r_col > 0.86) lamp_col = vec3(0.95, 0.5, 0.22);        // orange curtains
	if (r_col > 0.95) lamp_col = vec3(0.7, 0.82, 1.0);         // cold fluorescent / TV
	if (ground_shop) lamp_col = mix(vec3(1.0, 0.85, 0.65), vec3(0.85, 0.92, 1.0), step(0.6, r_col));
	float intensity = (0.55 + 0.6 * r_int) * window_emission;

	// Curtains and frames: darker edges, a mullion and a transom.
	vec2 lp = (cell - wmin) / (wmax - wmin);
	float curtain = 0.55 + 0.45 * smoothstep(0.0, 0.3, lp.x) * smoothstep(1.0, 0.7, lp.x);
	float frame = ground_shop ? 1.0 : (1.0 - 0.85 * smoothstep(0.035, 0.015, abs(lp.x - 0.5)))
	                                  * (1.0 - 0.85 * smoothstep(0.03, 0.01, abs(lp.y - 0.68)));
	intensity *= curtain * frame;

	// A few windows flicker slightly (TV glow or a tired bulb).
	if (r_flk < flicker_share) {
		float t = TIME * (5.0 + r_int * 7.0) + r_on * 40.0;
		float step_noise = hash12(vec2(floor(t), r_col * 50.0));
		intensity *= 0.72 + 0.28 * step_noise;
		lamp_col = mix(lamp_col, vec3(0.6, 0.75, 1.0), 0.5 * step(0.5, r_col));
	}

	vec3 emit = lamp_col * intensity * on * win;

	// Far away the grid is smaller than a pixel: blend to the average glow instead of
	// letting it shimmer.
	float far = smoothstep(0.35, 0.8, max(aa.x, aa.y));
	float area = (wmax.x - wmin.x) * (wmax.y - wmin.y);
	vec3 avg_emit = vec3(1.0, 0.72, 0.4) * window_emission * 0.75 * lit_share * area * (in_grid ? 1.0 : 0.0);
	emit = mix(emit, avg_emit, far);
	win = mix(win, area * (in_grid ? 1.0 : 0.0), far);

	vec3 glass = vec3(0.03, 0.035, 0.05);
	ALBEDO = mix(wall, glass, win);
	ROUGHNESS = mix(0.92, 0.15, win);
	SPECULAR = mix(0.2, 0.6, win);

	// Street lamps light the lower facades (from the chunk's baked light map).
	vec2 luv = (world_pos.xz + world_normal.xz * 1.5 - light_rect.xy) * light_rect.zw;
	vec3 lamp = texture(light_map, luv).rgb;
	lamp = lamp * lamp * light_strength * (1.0 - smoothstep(1.0, 11.0, v));

	vec3 flood = vec3(0.0);
	if (landmark || kind == B_RELIGIOUS) {
		flood = wall * vec3(1.0, 0.86, 0.66) * landmark_flood * (0.45 + 0.55 * (1.0 - v / max(wall_h, 1.0)));
	}
	EMISSION = emit + ALBEDO * lamp * 0.8 + flood;
}
