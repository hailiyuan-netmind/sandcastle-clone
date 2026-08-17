shader_type spatial;
render_mode unshaded;

uniform sampler2D pos_tex : filter_nearest, repeat_disable;

void vertex() {
	int id = VERTEX_ID;
	vec4 pdat = texelFetch(pos_tex, ivec2(id % 256, id / 256), 0);
	if (pdat.y < -50.0) {
		VERTEX = vec3(0.0, -4000.0, 0.0);
		POINT_SIZE = 0.0;
	} else {
		VERTEX = pdat.xyz;
		float mat_id = floor(pdat.w);
		float spd = fract(pdat.w);
		vec3 col;
		if (mat_id < 0.5) {
			col = mix(vec3(0.55, 0.80, 0.90), vec3(0.97, 0.99, 1.0), spd * 1.1);
		} else {
			col = mix(vec3(0.62, 0.50, 0.30), vec3(0.90, 0.80, 0.58), spd * 0.8 + 0.1);
		}
		COLOR = vec4(col, 1.0);
		float dist = length((MODELVIEW_MATRIX * vec4(pdat.xyz, 1.0)).xyz);
		POINT_SIZE = clamp(520.0 / max(dist, 1.0), 1.5, 9.0);
	}
}

void fragment() {
	vec2 d = POINT_COORD - vec2(0.5);
	if (dot(d, d) > 0.25) { discard; }
	ALBEDO = pow(COLOR.rgb * (1.0 - dot(d, d) * 1.4), vec3(2.2));
}
