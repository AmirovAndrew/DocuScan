// Material for hand-built landmark models (scripts/city/landmarks/*).
//   COLOR.rgb = base colour (for glass: chance of being lit, warmth), COLOR.a = element id
//   UV        = metres on the surface (0..1 across glass), UV2 = (kind, height)
// Snow settles on every upward face; facades are floodlit from below at night, the
// main facade the most.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_schlick_ggx;

uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D light_map : hint_default_black, filter_linear, repeat_disable;
uniform vec4 light_rect = vec4(0.0, 0.0, 0.004, 0.004);
uniform float light_strength = 2.4;
uniform vec3 front_dir = vec3(0.0, 0.0, -1.0);  // world direction the main facade faces
uniform float flood = 0.85;
uniform float flood_height = 24.0;
uniform float window_emission = 2.0;

const int K_STUCCO = 0;
const int K_RUSTIC = 1;
const int K_TRIM = 2;
const int K_STONE = 3;
const int K_ROOF = 4;
const int K_GLASS = 5;
const int K_DOOR = 6;
const int K_RELIEF = 7;
const int K_METAL = 8;
const vec3 SNOW = vec3(0.86, 0.89, 0.96);

varying vec3 wpos;
varying vec3 wnrm;

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	int kind = int(UV2.x + 0.5);
	vec3 base = COLOR.rgb;
	float id = COLOR.a;
	float grime = texture(noise_tex, UV * 0.11 + id * 3.0).g;
	float fine = texture(noise_tex, UV * 0.9).b;
	vec3 alb = base;
	vec3 emit = vec3(0.0);
	float rough = 0.9;
	float spec = 0.2;
	bool floodlit = true;
	vec2 aa = fwidth(UV) + 1e-4;

	if (kind == K_STUCCO) {
		alb = base * (0.88 + 0.18 * grime);
	} else if (kind == K_RUSTIC) {
		// Rustication: deep horizontal joints every 0.5 m, staggered vertical joints.
		float row = floor(UV.y / 0.5);
		float jy = abs(fract(UV.y / 0.5) - 0.5);   // 0.5 at a joint
		float jx = abs(fract(UV.x / 1.4 + 0.5 * mod(row, 2.0)) - 0.5);
		float gy = smoothstep(0.41 - aa.y, 0.47, jy);
		float gx = smoothstep(0.455 - aa.x, 0.485, jx);
		float bevel = smoothstep(0.3, 0.41, jy) * 0.12;   // stones are bevelled towards the joints
		alb = base * (0.88 + 0.16 * grime) * (1.0 - 0.5 * max(gy, gx) - bevel);
	} else if (kind == K_TRIM || kind == K_RELIEF) {
		alb = base * (0.93 + 0.1 * grime);
		if (kind == K_RELIEF) alb *= 1.04;
	} else if (kind == K_STONE) {
		alb = base * (0.8 + 0.3 * fine) * (0.9 + 0.15 * grime);
		rough = 0.7;
		spec = 0.35;
	} else if (kind == K_ROOF) {
		float seam = smoothstep(0.04, 0.0, abs(fract(UV.x / 0.6) - 0.5) - 0.46);
		alb = base * (1.0 - 0.3 * seam);
		rough = 0.5;
		spec = 0.4;
		floodlit = false;
	} else if (kind == K_GLASS || kind == K_DOOR) {
		floodlit = false;
		bool door = kind == K_DOOR;
		// frames: border, a mullion and a transom (doors: two leaves and a fanlight)
		float fx = 0.05;
		float frame = 1.0 - smoothstep(fx, fx + aa.x, UV.x) * smoothstep(fx, fx + aa.x, 1.0 - UV.x)
			* smoothstep(0.03, 0.03 + aa.y, UV.y) * smoothstep(0.03, 0.03 + aa.y, 1.0 - UV.y);
		frame = max(frame, smoothstep(0.025 + aa.x, 0.0, abs(UV.x - 0.5)));
		frame = max(frame, smoothstep(0.02 + aa.y, 0.0, abs(UV.y - (door ? 0.7 : 0.72))));
		if (!door) frame = max(frame, smoothstep(0.015 + aa.y, 0.0, abs(UV.y - 0.36)) * 0.8);
		bool on = door || hash11(id * 917.0) < base.r;
		vec3 warm = mix(vec3(1.0, 0.68, 0.36), vec3(1.0, 0.82, 0.58), base.g);
		vec3 glass = vec3(0.025, 0.03, 0.045) + vec3(0.02, 0.025, 0.04) * (1.0 - UV.y);
		vec3 light = vec3(0.0);
		if (on) {
			// foyer: bright under the chandeliers near the top, warm gradient down,
			// heavy curtains drawn to the sides
			float chandelier = exp(-pow((UV.x - 0.5) * 3.2, 2.0) - pow((UV.y - 0.8) * 4.0, 2.0));
			float curtain = max(smoothstep(0.22, 0.16, UV.x), smoothstep(0.78, 0.84, UV.x));
			light = warm * window_emission * (door ? 0.6 : 0.75) * (0.45 + 0.55 * UV.y + 0.9 * chandelier);
			if (door) light *= 0.75 + 0.25 * smoothstep(0.0, 0.6, UV.y);  // vestibule: darker low down
			light = mix(light, vec3(0.75, 0.18, 0.12) * window_emission * 0.45, door ? 0.0 : curtain * 0.85);
		}
		vec3 frame_col = door ? vec3(0.36, 0.24, 0.14) : vec3(0.85, 0.84, 0.8);
		alb = mix(glass, frame_col, frame);
		emit = light * (1.0 - frame);
		rough = mix(0.08, 0.6, frame);
		spec = mix(0.7, 0.25, frame);
	} else {
		alb = vec3(0.12);
		rough = 0.4;
		spec = 0.5;
	}

	// Snow on every upward face (cornices, sills, sandriks, steps, roofs).
	float snow = smoothstep(0.55, 0.85, wnrm.y);
	if (kind == K_ROOF) snow = smoothstep(0.2, 0.5, wnrm.y) * (0.82 + 0.18 * grime);
	if (kind == K_GLASS || kind == K_DOOR) snow = 0.0;
	alb = mix(alb, SNOW * (0.95 + 0.05 * fine), snow);
	rough = mix(rough, 0.85, snow);

	ALBEDO = alb;
	ROUGHNESS = rough;
	SPECULAR = spec;

	vec2 luv = (wpos.xz + wnrm.xz * 1.5 - light_rect.xy) * light_rect.zw;
	vec3 lamp = texture(light_map, luv).rgb;
	lamp = lamp * lamp * light_strength * (1.0 - smoothstep(1.0, 10.0, wpos.y));
	vec3 fl = vec3(0.0);
	if (floodlit) {
		// floodlights at the foot of the walls, strongest on the main facade
		float facing = max(dot(wnrm, front_dir), 0.0);
		float up = clamp(wpos.y / flood_height, 0.0, 1.0);
		float pools = 0.8 + 0.2 * sin(dot(wpos.xz, vec2(front_dir.z, -front_dir.x)) * 0.9);
		fl = alb * vec3(1.0, 0.86, 0.64) * flood * (0.22 + 0.78 * facing) * (0.25 + 0.75 * pow(1.0 - up, 1.6)) * pools;
		fl *= 1.0 - snow * 0.4;
	}
	EMISSION = emit + alb * lamp * 0.8 + fl;
}
