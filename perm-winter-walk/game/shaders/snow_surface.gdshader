// Snow-covered flat surfaces: open ground, parks, squares, roads, footpaths, frozen river.
//
// One material per chunk draws all of them in a single merged mesh. The surface kind
// comes from COLOR.r (kind / 8). Roads and paths carry ribbon coordinates in UV
// (x = across the ribbon 0..1, y = metres along it) for tyre ruts / trodden lines.
//
// Street-lamp light on the snow is not computed per light: the preprocessor bakes a
// small "light map" per chunk (tools/preprocess_osm.py, bake_light_map) holding warm lamp
// pools and window spill, and this shader adds albedo * light. That keeps real-time lights to a handful while every lamp still lights
// the snow (the Mobile renderer only allows 8 lights per mesh anyway).
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_schlick_ggx;

uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D light_map : hint_default_black, filter_linear, repeat_disable;
// xy = world x/z of the light map's corner, zw = 1 / size in metres.
uniform vec4 light_rect = vec4(0.0, 0.0, 0.004, 0.004);
uniform float light_strength = 2.4;
uniform vec3 snow_color : source_color = vec3(0.86, 0.9, 0.97);
uniform float sparkle_amount = 1.0;

varying vec3 world_pos;
varying flat int kind;

const int K_GROUND = 0;
const int K_PARK = 1;
const int K_SQUARE = 2;
const int K_ROAD = 3;
const int K_PATH = 4;
const int K_ICE = 5;
const int K_PAVED = 6;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	kind = int(COLOR.r * 8.0 + 0.5);
}

void fragment() {
	vec2 wp = world_pos.xz;
	float drift = texture(noise_tex, wp * 0.018).r;   // ~55 m features
	vec4 lump = texture(noise_tex, wp * 0.11);        // ~9 m features
	float grain = texture(noise_tex, wp * 0.9).b;     // ~1 m features

	vec3 col = snow_color * (0.93 + 0.1 * drift + 0.04 * (lump.g - 0.5));
	float rough = 0.82;
	float nmap = 0.55;
	float sparkle_mask = 1.0;

	if (kind == K_PARK) {
		col *= vec3(0.98, 0.99, 1.03);
		nmap = 0.8;
	} else if (kind == K_SQUARE || kind == K_PAVED) {
		// Trampled, cleared snow: slightly grey, flatter, with darker trodden patches.
		float trod = smoothstep(0.45, 0.75, lump.g * 0.7 + grain * 0.3);
		col = mix(col * 0.9, vec3(0.55, 0.58, 0.64), trod * 0.35);
		nmap = 0.3;
		sparkle_mask = 0.5;
	} else if (kind == K_ROAD) {
		// Packed snow, two pairs of darker tyre ruts and slush near the kerbs.
		float a = UV.x;
		float ruts = 0.0;
		for (int i = 0; i < 4; i++) {
			float centre = 0.17 + float(i) * 0.22;
			ruts = max(ruts, smoothstep(0.06, 0.0, abs(a - centre)));
		}
		float wobble = texture(noise_tex, vec2(a * 0.5, UV.y * 0.03)).g;
		ruts *= 0.6 + 0.6 * wobble;
		float kerb = smoothstep(0.1, 0.0, min(a, 1.0 - a));
		vec3 packed_snow = vec3(0.66, 0.69, 0.74) * (0.9 + 0.2 * grain);
		vec3 slush = vec3(0.24, 0.25, 0.27);
		col = mix(packed_snow, slush, clamp(ruts * 0.75 + kerb * 0.35, 0.0, 1.0));
		rough = mix(0.7, 0.35, ruts);  // wet ruts catch the lamps
		nmap = 0.25;
		sparkle_mask = 0.3;
	} else if (kind == K_PATH) {
		// A trodden line down the middle of a snowy footpath.
		float centre = smoothstep(0.42, 0.0, abs(UV.x - 0.5));
		float prints = texture(noise_tex, vec2(UV.x * 1.5, UV.y * 0.8)).b;
		col = mix(col, vec3(0.7, 0.73, 0.79) * (0.9 + 0.15 * prints), centre * 0.6);
		nmap = 0.45;
	} else if (kind == K_ICE) {
		// Frozen Kama: snow on ice, with wind-swept bluish patches.
		float bare = smoothstep(0.6, 0.78, drift * 0.6 + lump.r * 0.4);
		col = mix(col * vec3(0.95, 0.98, 1.03), vec3(0.42, 0.52, 0.62), bare * 0.55);
		rough = mix(0.8, 0.25, bare);
		nmap = mix(0.6, 0.1, bare);
	}

	ALBEDO = col;
	ROUGHNESS = rough;
	SPECULAR = 0.35;
	NORMAL_MAP = texture(normal_tex, wp * 0.3).xyz;
	NORMAL_MAP_DEPTH = nmap;

	vec2 luv = (wp - light_rect.xy) * light_rect.zw;
	vec3 lamp = texture(light_map, luv).rgb;
	lamp = lamp * lamp * light_strength;  // stored sqrt-encoded for precision in the darks

	// Sparkle: tiny ice crystals glint, re-rolled as the view direction changes.
	vec3 view_ws = (INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz;
	float s1 = texture(noise_tex, wp * 0.27).a;
	float s2 = texture(noise_tex, wp * 0.27 + view_ws.xz * 0.35).a;
	float dist = length(world_pos - CAMERA_POSITION_WORLD);
	float glint = step(0.93, s1 * s2) * (1.0 - smoothstep(6.0, 18.0, dist));
	vec3 glint_light = vec3(0.35, 0.45, 0.7) * 0.25 + lamp * 1.6;

	EMISSION = col * lamp + glint * glint_light * sparkle_amount * sparkle_mask;
}
