// Visible cone of warm light under a street lamp, in snowy, slightly foggy air.
// Additive and unshaded: no real light, no shadows; it only suggests scattering.
// The mesh is a unit cone, apex at the origin, opening downwards to y = -1.
shader_type spatial;
render_mode blend_add, unshaded, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 cone_color : source_color = vec3(1.0, 0.7, 0.38);
uniform float strength = 0.22;
uniform float near_fade = 5.0;
uniform float far_fade = 220.0;

varying float depth01;
varying vec3 world_pos;

void vertex() {
	depth01 = -VERTEX.y;  // 0 at the lamp head, 1 at the ground
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Soft edges: fade where the surface is seen edge-on.
	// Seen through the middle the cone holds the most lit air; at its silhouette almost none.
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float edge = facing * facing;
	float along = pow(1.0 - depth01, 1.2) * 0.85 + 0.15;  // brightest under the lamp head
	float ground = smoothstep(1.0, 0.55, depth01);     // dissolve before reaching the snow
	float dist = length(world_pos - CAMERA_POSITION_WORLD);
	float fade = smoothstep(0.5, near_fade, dist) * (1.0 - smoothstep(far_fade * 0.6, far_fade, dist));
	ALBEDO = cone_color * strength * edge * along * ground * fade;
}
