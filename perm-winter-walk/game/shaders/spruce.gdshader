// Spruce foliage: needle texture and normal map along each branch, clumpy snow on the
// upward faces, bark on the trunk, and a barely visible sway of the branch tips.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_schlick_ggx;

uniform sampler2D needle_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D needle_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 snow_color : source_color = vec3(0.86, 0.89, 0.96);
uniform float needle_brightness = 5.0;
uniform float sway = 0.025;

varying vec3 inst_pos;

void vertex() {
	inst_pos = MODEL_MATRIX[3].xyz;
	float w = UV2.y * UV2.y * (1.0 - UV2.x);
	float ph = dot(inst_pos.xz, vec2(0.37, 0.71));
	VERTEX.y += sin(TIME * 1.1 + ph + VERTEX.x * 0.8) * sway * w;
	VERTEX.x += sin(TIME * 0.7 + ph * 1.3) * sway * 0.6 * w;
}

void fragment() {
	bool bark = UV2.x > 0.5;
	vec3 needles = texture(needle_tex, UV).rgb * needle_brightness * COLOR.rgb;
	float clump = texture(noise_tex, UV * vec2(0.35, 0.2) + inst_pos.xz * 0.13).g;
	float fine = texture(noise_tex, UV * 1.7 + inst_pos.zx * 0.21).b;
	float snow = smoothstep(0.42, 0.58, COLOR.a + (clump - 0.5) * 0.55 + (fine - 0.5) * 0.15);
	if (bark) {
		float rough = texture(noise_tex, UV * vec2(3.0, 0.6)).b;
		ALBEDO = COLOR.rgb * (0.75 + 0.5 * rough);
		ROUGHNESS = 1.0;
		SPECULAR = 0.1;
	} else {
		ALBEDO = mix(needles, snow_color, snow);
		ROUGHNESS = mix(0.9, 0.75, snow);
		SPECULAR = mix(0.08, 0.35, snow);  // needles barely glint; snow a little
		NORMAL_MAP = mix(texture(needle_normal, UV).xyz, vec3(0.5, 0.5, 1.0), snow * 0.8);
		NORMAL_MAP_DEPTH = 0.6;
	}
}
