// One snowflake: a soft round camera-facing dot. Flakes drifting through a lamp's pool
// of light pick up its warm colour (sampled from the chunk light map under the camera).
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec3 flake_color : source_color = vec3(0.78, 0.83, 0.95);
uniform float base_brightness = 0.5;
uniform sampler2D light_map : hint_default_black, filter_linear, repeat_disable;
uniform vec4 light_rect = vec4(0.0, 0.0, 0.004, 0.004);
uniform float light_strength = 2.4;
uniform float fade_distance = 16.0;

varying vec3 flake_pos;

void vertex() {
	flake_pos = MODEL_MATRIX[3].xyz;
	// Billboard that keeps the particle's scale.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	float d = length(UV - 0.5) * 2.0;
	float a = smoothstep(1.0, 0.1, d);
	float dist = length(flake_pos - CAMERA_POSITION_WORLD);
	a *= smoothstep(0.2, 0.8, dist) * (1.0 - smoothstep(fade_distance * 0.55, fade_distance, dist));
	vec2 luv = (flake_pos.xz - light_rect.xy) * light_rect.zw;
	vec3 lamp = texture(light_map, luv).rgb;
	lamp = lamp * lamp * light_strength;
	float under_lamp = clamp(1.0 - flake_pos.y / 8.0, 0.0, 1.0);
	ALBEDO = flake_color * base_brightness + lamp * under_lamp * 0.9;
	ALPHA = a * 0.9;
}
