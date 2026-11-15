// Falling snow that never runs out: flakes live in a box around the emitter (which
// follows the camera) and wrap around its faces instead of being re-emitted, so the
// player can walk or run any distance without leaving the snowfall behind.
shader_type particles;
render_mode disable_velocity;

uniform vec3 box = vec3(36.0, 20.0, 36.0);
uniform float fall_speed = 1.0;      // m/s, light dry snow falls slowly
uniform vec3 wind = vec3(0.55, 0.0, 0.2);
uniform float sway_amount = 0.35;
uniform float flake_size = 0.036;

float hash(uint x) {
	x ^= x >> 16u;
	x *= 0x7feb352du;
	x ^= x >> 15u;
	x *= 0x846ca68bu;
	x ^= x >> 16u;
	return float(x) / 4294967295.0;
}

void start() {
	uint s = NUMBER * 747796405u + RANDOM_SEED * 2891336453u;
	vec3 r = vec3(hash(s), hash(s + 1u), hash(s + 2u));
	TRANSFORM = mat4(1.0);
	TRANSFORM[3].xyz = EMISSION_TRANSFORM[3].xyz + (r - 0.5) * box;
	// x: sway phase, y: fall speed factor, z: size factor
	CUSTOM = vec4(hash(s + 3u), 0.6 + 0.8 * hash(s + 4u), 0.6 + 0.9 * hash(s + 5u), 0.0);
}

void process() {
	float ph = CUSTOM.x * 6.2831853;
	vec3 sway = vec3(sin(TIME * 0.8 + ph * 3.0), 0.0, cos(TIME * 0.63 + ph * 5.0)) * sway_amount;
	vec3 vel = vec3(wind.x, -fall_speed * CUSTOM.y, wind.z) + sway;
	vec3 p = TRANSFORM[3].xyz + vel * DELTA;
	vec3 c = EMISSION_TRANSFORM[3].xyz;
	vec3 rel = mod(p - c + box * 0.5, box) - box * 0.5;
	float sz = flake_size * CUSTOM.z;
	TRANSFORM = mat4(vec4(sz, 0.0, 0.0, 0.0), vec4(0.0, sz, 0.0, 0.0), vec4(0.0, 0.0, sz, 0.0), vec4(c + rel, 1.0));
	VELOCITY = vel;
}
