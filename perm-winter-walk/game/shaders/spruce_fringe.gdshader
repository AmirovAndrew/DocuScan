// Hanging twigs along the edges of near spruce branches: alpha-tested cards that give
// the tree a ragged, feathery outline instead of hard polygon edges.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_lambert, specular_disabled;

uniform sampler2D fringe_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float needle_brightness = 5.0;
uniform float sway = 0.025;

void vertex() {
	vec3 inst = MODEL_MATRIX[3].xyz;
	float w = UV2.y * UV2.y;
	float ph = dot(inst.xz, vec2(0.37, 0.71));
	VERTEX.y += sin(TIME * 1.1 + ph + VERTEX.x * 0.8) * sway * w;
	VERTEX.x += sin(TIME * 0.7 + ph * 1.3) * sway * 0.6 * w;
}

void fragment() {
	vec4 t = texture(fringe_tex, UV);
	ALBEDO = t.rgb * needle_brightness * COLOR.rgb;
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.45;
	ROUGHNESS = 0.9;
}
