// Building facades: walls, trims, balconies and everything painted on them.
//
// Vertex data (building_builder.gd):
//   UV      = (metres along the wall segment, metres above ground)
//   UV2     = (levels, roof height)
//   COLOR   = (facade colour rgb, building seed)
//   CUSTOM0 = (segment length, floor height, kind (+8 if landmark), share of windows lit)
//   CUSTOM1 = (segment id, style code, part, window pitch)
//             style code = style + 8 * (balcony column offset + 3 * has balconies)
// All values used to pick random states are rounded integers from the vertex data:
// interpolated values differ by tiny amounts from pixel to pixel, which would make the
// per-window randomness speckle.
//
// Walls get a style (Soviet panel block, historic stucco, brick, modern glass, utility,
// church) with its own material and window design. Windows sit in real-looking
// recesses (parallax), and lit windows show a room behind the glass (interior mapping:
// back wall with furniture, floor, ceiling, side walls, lit by a ceiling lamp) behind
// curtains and frames. Shops get big windows with shelves and glowing signs; block
// entrances get a steel door and a lamp. Close-up detail fades out with distance
// (detail_distance), and far away the window grid collapses to its average glow.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_schlick_ggx;

uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D sign_tex : hint_default_black, filter_linear_mipmap, repeat_disable;
uniform sampler2D light_map : hint_default_black, filter_linear, repeat_disable;
uniform vec4 light_rect = vec4(0.0, 0.0, 0.004, 0.004);
uniform float light_strength = 2.4;
uniform float window_emission = 2.0;
uniform float flicker_share = 0.05;
uniform float landmark_flood = 0.75;
uniform float detail_distance = 32.0;  // rooms and window recesses closer than this
uniform int debug_part = -1;  // debugging aid: draw only this part

varying vec4 bdata;
varying vec4 bpart;
varying vec2 bshape;
varying vec3 world_pos;
varying vec3 world_normal;

const int B_RESIDENTIAL = 0;
const int B_COMMERCIAL = 1;
const int B_PUBLIC = 2;
const int B_UTILITY = 3;
const int B_RELIGIOUS = 4;
const int S_PANEL = 0;
const int S_HISTORIC = 1;
const int S_BRICK = 2;
const int S_MODERN = 3;
const int S_UTILITY = 4;
const int S_RELIGIOUS = 5;
const int P_WALL = 0;
const int P_TRIM = 1;
const int P_PLINTH = 2;
const int P_BALCONY = 3;
const int P_GLASS = 4;
const int P_CANOPY = 5;
const float SIGN_ROWS = 16.0;
const vec3 SNOW = vec3(0.85, 0.88, 0.95);

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec3 hash32(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yzz) * p3.zyx);
}

float rect(vec2 p, vec2 mn, vec2 mx, vec2 aa) {
	vec2 s = smoothstep(mn - aa, mn + aa, p) * (1.0 - smoothstep(mx - aa, mx + aa, p));
	return s.x * s.y;
}

vec3 wallpaper(float r) {
	if (r < 0.2) return vec3(0.72, 0.62, 0.45);   // beige
	if (r < 0.38) return vec3(0.55, 0.62, 0.48);  // pale green
	if (r < 0.54) return vec3(0.5, 0.56, 0.66);   // blue
	if (r < 0.7) return vec3(0.74, 0.55, 0.5);    // pink
	if (r < 0.86) return vec3(0.78, 0.76, 0.7);   // white
	return vec3(0.6, 0.45, 0.32);                 // wood panelling
}

vec3 curtain_color(float r) {
	if (r < 0.25) return vec3(0.85, 0.75, 0.55);
	if (r < 0.45) return vec3(0.7, 0.25, 0.18);
	if (r < 0.6) return vec3(0.35, 0.55, 0.35);
	if (r < 0.75) return vec3(0.9, 0.88, 0.82);
	if (r < 0.9) return vec3(0.4, 0.45, 0.7);
	return vec3(0.85, 0.6, 0.3);
}

vec3 sign_hue(float r) {
	if (r < 0.25) return vec3(1.0, 0.18, 0.12);
	if (r < 0.45) return vec3(0.15, 0.85, 0.3);
	if (r < 0.62) return vec3(0.2, 0.5, 1.0);
	if (r < 0.8) return vec3(1.0, 0.75, 0.15);
	return vec3(1.0, 0.95, 0.85);
}

// Interior mapping: the colour seen through a window into a box-shaped room.
// p = point on the glass in metres inside the window cell, d = view ray in tangent
// space (z points into the building), cell = room width and height, depth = room depth.
vec3 room_color(vec2 p, vec3 d, vec2 cell, float depth, vec3 rnd, bool shop) {
	float tx = d.x > 0.0 ? (cell.x - p.x) / d.x : (d.x < 0.0 ? -p.x / d.x : 1e5);
	float ty = d.y > 0.0 ? (cell.y - p.y) / d.y : (d.y < 0.0 ? -p.y / d.y : 1e5);
	float tz = depth / max(d.z, 1e-3);
	float t = min(tz, min(tx, ty));
	vec3 h = vec3(p, 0.0) + d * t;
	vec3 wall = wallpaper(rnd.x);
	vec3 c;
	if (t == tz) {
		c = wall;
		float fx = cell.x * (0.3 + 0.4 * rnd.y);
		if (shop) {
			float shelf = step(0.72, fract(h.y * 2.4));
			vec3 goods = vec3(0.35, 0.3, 0.28) + 0.5 * hash32(floor(h.xy * vec2(4.0, 2.4)) + rnd.z * 9.0);
			c = mix(vec3(0.8), goods, (1.0 - shelf) * step(h.y, 2.0) * step(0.25, h.y));
		} else {
			float sofa = rect(h.xy, vec2(fx - 0.8, 0.0), vec2(fx + 0.8, 0.85), vec2(0.02));
			c = mix(c, vec3(0.2, 0.13, 0.1) * (0.6 + rnd.z), sofa);
			float pic = rect(h.xy, vec2(fx - 0.3, 1.45), vec2(fx + 0.3, 1.9), vec2(0.01));
			c = mix(c, vec3(0.55, 0.38, 0.22), pic * step(0.45, rnd.z));
			float wardrobe = rect(h.xy, vec2(cell.x - 0.9, 0.0), vec2(cell.x - 0.1, 2.1), vec2(0.02));
			c = mix(c, vec3(0.3, 0.2, 0.13), wardrobe * step(0.6, rnd.y));
		}
	} else if (t == ty) {
		c = d.y < 0.0 ? vec3(0.34, 0.21, 0.12) * (0.8 + 0.4 * rnd.y) : vec3(0.88);
	} else {
		c = wall * 0.85;
	}
	vec3 lamp = vec3(cell.x * 0.5, cell.y - 0.35, depth * 0.45);
	vec3 dl = h - lamp;
	float fall = 1.0 / (1.0 + 0.5 * dot(dl, dl));
	return c * (0.22 + 1.15 * fall);
}

void vertex() {
	bdata = CUSTOM0;
	bpart = CUSTOM1;
	bshape = UV2;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	int part = int(bpart.z + 0.5);
	float style_code = floor(bpart.y + 0.5);
	int style = int(mod(style_code, 8.0));
	float flags = floor(style_code / 8.0);
	float balcony_offset = mod(flags, 3.0);
	bool has_balconies = flags >= 2.5;
	float sid = floor(bpart.x + 0.5);  // exact segment id
	if (debug_part >= 0 && part != debug_part) discard;
	bool landmark = bdata.z > 7.5;
	int kind = int(mod(bdata.z, 8.0) + 0.5);
	float seed = COLOR.a;
	float seg_len = bdata.x;
	float floor_h = max(bdata.y, 2.0);
	float lit_share = bdata.w;
	float levels = bshape.x;
	float roof_h = bshape.y;
	float u = UV.x;
	float v = UV.y;
	vec2 aa = fwidth(UV) * 1.2 + 1e-4;
	float dist = length(world_pos - CAMERA_POSITION_WORLD);
	float grime = texture(noise_tex, vec2(u * 0.05, v * 0.08) + sid * 0.137).g;
	float grime2 = texture(noise_tex, vec2(u * 0.31, v * 0.17) + sid * 0.071).b;
	vec3 base = COLOR.rgb;
	bool stucco = style == S_HISTORIC || style == S_RELIGIOUS;
	vec3 trim = stucco ? mix(vec3(0.82, 0.8, 0.74), base * 1.2, 0.15) : base * 0.92 + 0.06;

	vec3 alb = base;
	vec3 emit = vec3(0.0);
	float rough = 0.92;
	float spec = 0.2;

	if (part != P_WALL) {
		if (part == P_PLINTH) {
			alb = stucco ? vec3(0.3, 0.29, 0.29) : vec3(0.38, 0.37, 0.36);
			alb *= 0.75 + 0.35 * grime;
		} else if (part == P_BALCONY) {
			vec3 hb = hash32(vec2(floor(u / 2.0), floor(v / floor_h)) + sid * 1.7);
			alb = vec3(0.56, 0.56, 0.54);
			if (hb.x > 0.55) alb = base * 1.05;
			if (hb.y > 0.8) alb = vec3(0.33, 0.4, 0.5);
			if (hb.z > 0.75) alb = mix(alb, vec3(0.4, 0.33, 0.25), 0.7);  // brown sheeting
			alb *= 0.86 + 0.14 * step(0.5, fract(u * 5.0));                  // ribs
			alb *= 0.8 + 0.3 * grime;
		} else if (part == P_GLASS) {
			// Glazed loggia: a frame every ~0.7 m and a transom; some are lit inside.
			float lf = fract(u / 0.72);
			float frame = max(smoothstep(0.07, 0.03, lf), smoothstep(0.93, 0.97, lf));
			frame = max(frame, smoothstep(0.05, 0.0, abs(fract(v / floor_h) - 0.62)));
			vec3 hg = hash32(vec2(floor(u / 2.8), floor(v / floor_h)) + sid * 3.1);
			alb = mix(vec3(0.03, 0.035, 0.05), vec3(0.78), frame);
			rough = mix(0.1, 0.8, frame);
			spec = mix(0.7, 0.2, frame);
			float on = step(hg.x, lit_share * 0.6);
			// Lit only indirectly, from the room behind the balcony door: a dim warm glow,
			// brighter near the door and towards the top, with dark clutter (boxes, a
			// drying rack, old skis...) piled in the lower part, as on most Russian loggias.
			float fy = fract(v / floor_h);
			float fx = fract(u / 2.8);
			vec3 hc = hash32(vec2(floor(u / 0.9), floor(v / floor_h)) + sid * 7.7);
			float clutter = rect(vec2(fract(u / 0.9), fy), vec2(0.1, 0.4), vec2(0.9, 0.4 + 0.35 * hc.x), vec2(0.03)) * step(0.45, hc.y);
			float glow = (0.35 + 0.65 * smoothstep(0.45, 0.95, fy)) * (0.6 + 0.4 * smoothstep(0.7, 0.2, abs(fx - 0.35)));
			emit = mix(vec3(1.0, 0.58, 0.28), vec3(1.0, 0.72, 0.44), hg.y) * window_emission * 0.16
				* on * (1.0 - frame) * glow * (1.0 - 0.85 * clutter);
		} else if (part == P_CANOPY) {
			alb = vec3(0.42, 0.42, 0.44) * (0.85 + 0.3 * grime);
		} else {
			alb = trim * (0.85 + 0.25 * grime);
			alb *= 1.0 - 0.25 * smoothstep(0.6, 0.3, grime2);
		}
		float snow_up = smoothstep(0.55, 0.85, world_normal.y);
		alb = mix(alb, SNOW, snow_up);
		emit *= 1.0 - snow_up;
		rough = mix(rough, 0.85, snow_up);
	} else {
		// ============================ walls ============================
		float pitch = bpart.w;  // same value the balcony geometry used
		float n_cols = floor(max(seg_len - 1.2, 0.0) / pitch);
		float margin = (seg_len - n_cols * pitch) * 0.5;
		float col_f = (u - margin) / pitch;
		float col = floor(col_f);
		float row_f = v / floor_h;
		float row = floor(row_f);
		vec2 cell = vec2(pitch, floor_h);
		vec2 cm = vec2(fract(col_f), fract(row_f)) * cell;  // metres inside the window cell
		vec3 rnd = hash32(vec2(col, row) + vec2(sid * 17.0, 3.0));
		vec3 rnd2 = hash32(vec2(col + 7.3, row - 3.1) + vec2(sid * 5.0, 11.0));
		bool has_windows = n_cols >= 1.0 && !(style == S_UTILITY && hash12(vec2(col, sid)) > 0.45);
		bool in_grid = has_windows && col >= 0.0 && col < n_cols && row < levels && v < roof_h - 0.35 && v > 0.0;

		bool shop = row < 1.0 && (kind == B_COMMERCIAL || (kind == B_PUBLIC && style == S_MODERN)
			|| (kind == B_RESIDENTIAL && seed > 0.72 && style != S_PANEL));
		bool balcony = has_balconies && seg_len >= 10.0 && levels >= 3.0 && row >= 1.0 && row < levels - 0.5
			&& abs(mod(col + balcony_offset, 3.0) - 1.0) < 0.5;
		bool entrance = row < 1.0 && kind == B_RESIDENTIAL && (style == S_PANEL || style == S_BRICK)
			&& seg_len >= 14.0 && abs(mod(col, 4.0) - 1.0) < 0.5 && mod(sid, 2.0) < 0.5;
		if (entrance) shop = false;

		vec2 wmin = vec2(0.27, 0.3);
		vec2 wmax = vec2(0.73, 0.79);
		if (style == S_HISTORIC) { wmin = vec2(0.31, 0.22); wmax = vec2(0.69, 0.8); }
		else if (style == S_MODERN) { wmin = vec2(0.05, 0.22); wmax = vec2(0.95, 0.86); }
		else if (style == S_UTILITY) { wmin = vec2(0.3, 0.6); wmax = vec2(0.7, 0.86); }
		else if (style == S_RELIGIOUS) { wmin = vec2(0.36, 0.25); wmax = vec2(0.64, 0.85); }
		if (shop) { wmin = vec2(0.07, 0.12); wmax = vec2(0.93, 0.7); }
		if (balcony) { wmin = vec2(0.22, 0.03); wmax = vec2(0.55, 0.79); }  // balcony door
		if (entrance) { wmin = vec2(0.34, 0.0); wmax = vec2(0.66, min(0.72, 2.15 / floor_h)); }
		vec2 wmin_m = wmin * cell;
		vec2 wmax_m = wmax * cell;

		// ---- wall material per style
		vec3 wall = base * (0.82 + 0.3 * grime);
		if (style == S_PANEL) {
			float tone = hash12(vec2(col, row) + sid * 0.37);
			wall *= 0.94 + 0.12 * tone;
			float seam = max(smoothstep(0.035, 0.0, abs(cm.y - 0.02)), smoothstep(0.04, 0.0, min(cm.x, pitch - cm.x)));
			wall *= 1.0 - 0.32 * seam;
			if (seed > 0.6 && fract(seed * 7.0) > 0.5 && cm.y < wmin_m.y - 0.05 && cm.y > 0.12 && in_grid) {
				wall = mix(wall, vec3(0.32, 0.42, 0.55) * (0.8 + 0.3 * grime), 0.65);  // coloured spandrel panels
			}
		} else if (style == S_BRICK) {
			float bh = 0.077;
			float bw = 0.26;
			float brow = floor(v / bh);
			float bu = u / bw + mod(brow, 2.0) * 0.5;
			vec2 bc = vec2(fract(bu) * bw, fract(v / bh) * bh);
			float mortar = 1.0 - rect(bc, vec2(0.012, 0.01), vec2(bw - 0.012, bh - 0.01), vec2(0.004));
			float bt = hash12(vec2(floor(bu), brow) + sid * 0.9);
			vec3 mcol = vec3(0.55, 0.53, 0.5);
			vec3 bricks = mix(wall * (0.82 + 0.34 * bt), mcol, mortar);
			float fade = smoothstep(0.015, 0.05, max(aa.x, aa.y));
			wall = mix(bricks, mix(wall, mcol, 0.18), fade);
			float lintel = rect(cm, vec2(wmin_m.x - 0.15, wmax_m.y), vec2(wmax_m.x + 0.15, wmax_m.y + 0.22), aa);
			if (in_grid && !shop) wall = mix(wall, vec3(0.56, 0.55, 0.51) * (0.8 + 0.3 * grime), lintel);
		} else if (stucco) {
			if (row < 1.0) {  // rusticated ground floor
				float groove = smoothstep(0.035, 0.0, abs(fract(v / 0.45) - 0.5) - 0.465);
				float joint = smoothstep(0.03, 0.0, abs(fract(u / 1.2 + 0.5 * mod(floor(v / 0.45), 2.0)) - 0.5) - 0.48);
				wall *= 1.0 - 0.28 * max(groove, joint);
			}
			if ((landmark || kind == B_PUBLIC) && row >= 1.0 && in_grid) {  // pilasters
				float pil = 1.0 - smoothstep(0.22, 0.27, min(cm.x, pitch - cm.x));
				wall = mix(wall, trim, pil * 0.85);
			}
			if (in_grid && !shop) {  // surrounds, sill and a small cornice over each window
				float surround = rect(cm, wmin_m - 0.13, wmax_m + 0.13, aa);
				float sandrik = rect(cm, vec2(wmin_m.x - 0.22, wmax_m.y + 0.17), vec2(wmax_m.x + 0.22, wmax_m.y + 0.36), aa);
				float sill = rect(cm, vec2(wmin_m.x - 0.18, wmin_m.y - 0.22), vec2(wmax_m.x + 0.18, wmin_m.y - 0.08), aa);
				wall = mix(wall, trim * (0.9 + 0.15 * grime), max(max(surround, sandrik), sill) * 0.92);
				float sn = rect(cm, vec2(wmin_m.x - 0.22, wmax_m.y + 0.31), vec2(wmax_m.x + 0.22, wmax_m.y + 0.36), aa)
					+ rect(cm, vec2(wmin_m.x - 0.18, wmin_m.y - 0.12), vec2(wmax_m.x + 0.18, wmin_m.y - 0.08), aa);
				wall = mix(wall, SNOW, clamp(sn, 0.0, 1.0));
			}
		} else if (style == S_MODERN) {
			float fin = smoothstep(0.05, 0.0, min(cm.x, pitch - cm.x) - 0.06);
			wall = mix(wall, wall * 0.55, fin);
		} else if (style == S_UTILITY) {
			if (seed > 0.5) wall *= 0.86 + 0.14 * sin(u * 31.4);  // corrugated sheeting
			if (kind == B_UTILITY && levels < 1.5) {  // garage doors
				float gu = fract(u / 3.2) * 3.2;
				float gd = rect(vec2(gu, v), vec2(0.3, 0.0), vec2(2.9, 2.1), aa);
				vec3 gcol = mix(vec3(0.35, 0.36, 0.38), vec3(0.45, 0.3, 0.2), step(0.5, hash12(vec2(floor(u / 3.2), sid))));
				wall = mix(wall, gcol * (0.85 + 0.15 * step(0.5, fract(v * 4.0))), gd);
			}
		}
		if (in_grid && !shop && !entrance && !balcony && (style == S_PANEL || style == S_BRICK)) {
			float sill = rect(cm, vec2(wmin_m.x - 0.06, wmin_m.y - 0.07), vec2(wmax_m.x + 0.06, wmin_m.y), aa);
			wall = mix(wall, SNOW * 0.95, sill);  // snow on the sill
		}
		if (in_grid && row >= 1.0 && cm.y < wmin_m.y) {  // dirt streaks under the sill corners
			float sx = min(abs(cm.x - wmin_m.x), abs(cm.x - wmax_m.x));
			float streak = smoothstep(0.09, 0.0, sx) * smoothstep(wmin_m.y - 1.3, wmin_m.y, cm.y);
			wall *= 1.0 - 0.28 * streak * (0.4 + grime2);
		}
		wall *= mix(0.6, 1.0, smoothstep(0.2, 1.3, v + grime * 0.5));       // road splash: salt and slush
		wall *= 1.0 - 0.22 * smoothstep(roof_h - 1.5, roof_h, v) * grime;   // soot under the roof line
		float snow_line = 0.25 + 0.2 * texture(noise_tex, vec2(u * 0.3, sid * 0.13)).r;
		wall = mix(wall, SNOW, smoothstep(snow_line, snow_line - 0.08, v));
		alb = wall;

		// ---- windows, doors, shop windows
		float cpp = max(aa.x / pitch, aa.y / floor_h);   // window cells per pixel
		float far = smoothstep(0.3, 0.7, cpp);
		float opening = in_grid ? rect(cm, wmin_m, wmax_m, aa) : 0.0;
		if (opening > 0.001 && far < 0.999) {
			vec3 tangent = normalize(cross(world_normal, vec3(0.0, 1.0, 0.0)));
			vec3 rd = normalize(world_pos - CAMERA_POSITION_WORLD);
			vec3 rt = vec3(dot(rd, tangent), rd.y, -dot(rd, world_normal));
			bool detailed = dist < detail_distance && rt.z > 0.08;
			float depth = stucco ? 0.32 : ((style == S_MODERN || shop) ? 0.08 : 0.2);
			vec2 pg = cm;
			if (detailed) pg = cm + rt.xy * (depth / rt.z);
			vec2 wsize = wmax_m - wmin_m;
			vec2 lp = (pg - wmin_m) / wsize;
			bool on_glass = lp.x >= 0.0 && lp.x <= 1.0 && lp.y >= 0.0 && lp.y <= 1.0;
			vec3 wcol = vec3(0.03);
			vec3 wemit = vec3(0.0);
			float wrough = 0.12;
			float wspec = 0.65;
			if (!on_glass) {
				// window reveal: jambs in shadow, snow on the bottom one
				wcol = lp.y < 0.0 ? SNOW * 0.85 : wall * 0.45;
				wrough = 0.9;
				wspec = 0.1;
			} else if (entrance) {
				wcol = vec3(0.13, 0.11, 0.1) * (0.8 + 0.4 * step(0.5, fract(lp.y * 6.0)));
				wcol = mix(wcol, vec3(0.6), rect(lp, vec2(0.78, 0.42), vec2(0.88, 0.5), vec2(0.01)));
				wrough = 0.5;
				wspec = 0.4;
			} else {
				bool on = rnd.x < (shop ? 0.82 : lit_share);
				vec3 lamp_col = vec3(1.0, 0.66, 0.32);
				if (rnd.y > 0.55) lamp_col = vec3(1.0, 0.8, 0.52);
				if (rnd.y > 0.88) lamp_col = vec3(0.95, 0.52, 0.24);
				if (rnd.y > 0.96) lamp_col = vec3(0.7, 0.82, 1.0);
				if (shop) lamp_col = mix(vec3(1.0, 0.84, 0.62), vec3(0.85, 0.92, 1.0), step(0.6, rnd.y));
				float intensity = (0.6 + 0.6 * rnd.z) * window_emission * (shop ? 0.75 : 1.0);
				if (rnd2.y < flicker_share && !shop) {
					float t = TIME * (5.0 + rnd.z * 7.0) + rnd.x * 40.0;
					intensity *= 0.72 + 0.28 * hash12(vec2(floor(t), rnd.y * 50.0));
					lamp_col = mix(lamp_col, vec3(0.6, 0.75, 1.0), 0.45);
				}
				vec2 fw = vec2(0.055) / wsize;
				float frame = 1.0 - rect(lp, fw, 1.0 - fw, vec2(0.004));
				if (shop) {
					frame = max(frame, smoothstep(0.47, 0.49, abs(fract(lp.x * 3.0) - 0.5)));  // mullions
				} else if (balcony) {
					frame = max(frame, smoothstep(fw.y * 0.9, fw.y * 0.3, abs(lp.y - 0.62)));
				} else {
					frame = max(frame, smoothstep(fw.x * 0.9, fw.x * 0.3, abs(lp.x - 0.5)));
					frame = max(frame, smoothstep(fw.y * 0.9, fw.y * 0.3, abs(lp.y - 0.7)));
				}
				vec3 frame_col = rnd2.x > 0.3 ? vec3(0.8, 0.8, 0.78) : vec3(0.28, 0.17, 0.1);  // PVC or old wood
				vec3 inside;
				if (on) {
					inside = detailed ? room_color(pg, rt, cell, 3.6 + 1.6 * rnd2.z, rnd2, shop)
						: vec3(0.85) * (0.55 + 0.45 * lp.y);
					inside *= lamp_col * intensity;
					if (!shop) {
						float cl = 0.1 + 0.25 * rnd2.x;
						float cr = 0.1 + 0.25 * rnd2.y;
						float side_c = max(smoothstep(cl, cl - 0.03, lp.x), smoothstep(1.0 - cr, 1.0 - cr + 0.03, lp.x));
						float tulle = step(0.55, rnd2.z) * 0.5;
						float folds = 0.78 + 0.22 * sin(lp.x * 70.0 + rnd2.x * 10.0);
						vec3 ccol = curtain_color(fract(rnd2.z * 3.7)) * lamp_col * intensity * 0.5 * folds;
						inside = mix(inside, ccol, max(side_c * 0.92, tulle));
					}
					wemit = inside;
					wcol = vec3(0.02);
				} else {
					wcol = vec3(0.025, 0.03, 0.045) + vec3(0.02, 0.025, 0.04) * (1.0 - lp.y);
					if (detailed) wemit = room_color(pg, rt, cell, 4.0, rnd2, shop) * vec3(0.012, 0.014, 0.02);
				}
				wcol = mix(wcol, frame_col, frame);
				wemit *= 1.0 - frame;
				wrough = mix(0.1, 0.7, frame);
				wspec = mix(0.7, 0.2, frame);
			}
			float k = opening * (1.0 - far);
			alb = mix(alb, wcol, k);
			emit += wemit * k;
			rough = mix(rough, wrough, k);
			spec = mix(spec, wspec, k);
		}
		if (in_grid && far > 0.0) {
			float area = (wmax.x - wmin.x) * (wmax.y - wmin.y);
			emit += vec3(1.0, 0.72, 0.4) * window_emission * 0.75 * lit_share * area * far;
			alb = mix(alb, mix(wall, vec3(0.03), area), far);
		}
		if (entrance && in_grid) {  // lamp over the entrance door
			vec2 lc = vec2(pitch * 0.5, min(wmax_m.y + 0.32, floor_h - 0.32));
			float dl = length(cm - lc);
			emit += vec3(1.0, 0.78, 0.5) * (smoothstep(0.09, 0.05, dl) * 4.0 + smoothstep(1.5, 0.0, dl) * 0.22);
		}
		if (shop && in_grid && rnd2.x < 0.8) {  // glowing shop sign over the window
			vec2 s0 = vec2(0.1 * pitch, wmax_m.y + 0.1);
			vec2 s1 = vec2(0.9 * pitch, min(floor_h - 0.06, wmax_m.y + 0.62));
			float on_sign = rect(cm, s0, s1, aa);
			if (on_sign > 0.0) {
				vec2 sl = (cm - s0) / (s1 - s0);
				float row_i = floor(rnd2.y * SIGN_ROWS);
				// u runs right-to-left seen from outside, so flip the text.
				float txt = texture(sign_tex, vec2(1.0 - sl.x, (row_i + 1.0 - sl.y) / SIGN_ROWS)).r;
				vec3 hue = sign_hue(rnd2.z);
				bool lightbox = rnd.y > 0.6;
				vec3 s_alb = lightbox ? mix(vec3(0.85), hue * 0.4, txt) : mix(vec3(0.05), hue, txt);
				vec3 s_emit = lightbox ? mix(vec3(0.95, 0.95, 0.9) * 1.1, hue * 0.25, txt) : hue * txt * 2.4;
				alb = mix(alb, s_alb, on_sign);
				emit += s_emit * on_sign;
			}
		}
	}

	ALBEDO = alb;
	ROUGHNESS = rough;
	SPECULAR = spec;

	// Street lamps light the lower facades (from the chunk's baked light map).
	vec2 luv = (world_pos.xz + world_normal.xz * 1.5 - light_rect.xy) * light_rect.zw;
	vec3 lamp = texture(light_map, luv).rgb;
	lamp = lamp * lamp * light_strength * (1.0 - smoothstep(1.0, 11.0, v));
	vec3 flood = vec3(0.0);
	if (landmark || style == S_RELIGIOUS) {
		float upf = clamp(v / max(roof_h, 1.0), 0.0, 1.0);
		flood = alb * vec3(1.0, 0.84, 0.6) * landmark_flood * (0.15 + 0.85 * pow(1.0 - upf, 1.8));
	}
	EMISSION = emit + alb * lamp * 0.8 + flood;
}
