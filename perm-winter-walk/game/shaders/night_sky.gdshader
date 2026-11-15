// Overcast winter night over a city: low clouds lit from below by sodium and LED
// street light, so the horizon glows a dirty orange-violet while the zenith stays deep blue.
shader_type sky;
render_mode use_debanding;

uniform vec3 zenith_color : source_color = vec3(0.012, 0.018, 0.045);
uniform vec3 mid_color : source_color = vec3(0.05, 0.055, 0.1);
uniform vec3 horizon_color : source_color = vec3(0.2, 0.15, 0.17);
uniform vec3 ground_color : source_color = vec3(0.05, 0.055, 0.08);
uniform sampler2D cloud_noise : hint_default_white, filter_linear_mipmap, repeat_enable;

void sky() {
	float h = EYEDIR.y;
	if (h < 0.0) {
		COLOR = mix(horizon_color * 0.7, ground_color, smoothstep(0.0, -0.2, h));
	} else {
		float t_mid = smoothstep(0.0, 0.35, h);
		float t_top = smoothstep(0.25, 1.0, h);
		vec3 c = mix(horizon_color, mid_color, t_mid);
		c = mix(c, zenith_color, t_top);
		// Slow cloud mottling, projected onto a flat cloud deck.
		vec2 deck = EYEDIR.xz / max(h + 0.08, 0.08);
		float cl = texture(cloud_noise, deck * 0.08).g;
		float cl2 = texture(cloud_noise, deck * 0.21 + vec2(0.37, 0.11)).r;
		float clouds = smoothstep(0.35, 0.8, cl * 0.6 + cl2 * 0.4);
		c *= 0.85 + 0.35 * clouds * (1.0 - t_top * 0.6);
		COLOR = c;
	}
}
