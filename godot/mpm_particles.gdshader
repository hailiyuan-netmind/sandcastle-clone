shader_type spatial;
render_mode unshaded;

uniform sampler2D pos_tex : filter_nearest, repeat_disable;
uniform float world_scale = 40.0;

void vertex() {
	int id = VERTEX_ID;
	ivec2 tc = ivec2(id % 512, id / 512);
	vec4 pdat = texelFetch(pos_tex, tc, 0);
	vec3 wp = (pdat.xyz - vec3(0.5, 0.0, 0.5)) * world_scale;
	VERTEX = wp;
	float mat_id = floor(pdat.w);
	float spd = fract(pdat.w);
	vec3 col;
	if (mat_id < 0.5) {
		col = mix(vec3(0.13, 0.38, 0.62), vec3(0.72, 0.90, 0.97), spd * 1.3);
	} else {
		col = mix(vec3(0.62, 0.50, 0.31), vec3(0.93, 0.85, 0.64), spd + 0.15);
	}
	COLOR = vec4(col, 1.0);
	float dist = length((MODELVIEW_MATRIX * vec4(wp, 1.0)).xyz);
	POINT_SIZE = clamp(320.0 / max(dist, 1.0), 1.5, 12.0);
}

void fragment() {
	vec2 d = POINT_COORD - vec2(0.5);
	if (dot(d, d) > 0.25) { discard; }
	float shade = 1.0 - dot(d, d) * 1.6;
	ALBEDO = pow(COLOR.rgb * shade, vec3(2.2));
}
