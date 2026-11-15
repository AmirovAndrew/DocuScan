// A boot print pressed into the snow: multiplied over the ground as a soft bluish
// shadow. Prints fade out after a few minutes, as fresh snow fills them in.
shader_type spatial;
render_mode blend_mul, unshaded, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// The Mobile renderer keeps its HDR colour buffer at half scale, and multiplicative
// blending does not undo that: compensate, or every decal would also halve the
// brightness of whatever it covers.
#if CURRENT_RENDERER == RENDERER_MOBILE
const float MUL_FIX = 2.0;
#else
const float MUL_FIX = 1.0;
#endif

uniform sampler2D print_tex : hint_default_black, filter_linear_mipmap;
uniform float now = 0.0;          // seconds, set by footsteps.gd
uniform float fade_start = 150.0;
uniform float fade_end = 240.0;

varying float age;

void vertex() {
	age = now - INSTANCE_CUSTOM.x;
}

void fragment() {
	float m = texture(print_tex, UV).r;
	float fade = 1.0 - smoothstep(fade_start, fade_end, age);
	vec3 shade = vec3(0.5, 0.56, 0.7);
	ALBEDO = mix(vec3(1.0), shade, m * fade * 0.8) * MUL_FIX;
}
