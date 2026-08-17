shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform sampler2D field_tex : filter_linear, repeat_disable;
uniform float texel = 0.0026041667; // 1/384

varying vec4 vdat;
varying vec3 vworld;

float h21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), u.x),
			mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), u.x), u.y);
}

float ripple_h(vec2 p, float t) {
	float a = vnoise(p * 0.9 + t * vec2(0.12, 0.34));
	float b = vnoise(p * 2.1 - t * vec2(0.28, 0.10));
	return a * 0.6 + b * 0.4;
}

void vertex() {
	vec4 f = textureLod(field_tex, UV, 0.0);
	VERTEX.y = f.r + max(f.g, 0.0) - 0.02;
	vdat = f;
	vworld = VERTEX;
	float s0 = textureLod(field_tex, UV - vec2(texel, 0.0), 0.0).r + textureLod(field_tex, UV - vec2(texel, 0.0), 0.0).g;
	float s1 = textureLod(field_tex, UV + vec2(texel, 0.0), 0.0).r + textureLod(field_tex, UV + vec2(texel, 0.0), 0.0).g;
	float t0 = textureLod(field_tex, UV - vec2(0.0, texel), 0.0).r + textureLod(field_tex, UV - vec2(0.0, texel), 0.0).g;
	float t1 = textureLod(field_tex, UV + vec2(0.0, texel), 0.0).r + textureLod(field_tex, UV + vec2(0.0, texel), 0.0).g;
	NORMAL = normalize(vec3(-(s1 - s0), 1.0, -(t1 - t0)));
}

void fragment() {
	float d = vdat.g;

	// 动态涟漪法线
	vec2 wp = vworld.xz;
	float e = 0.5;
	float r0 = ripple_h(wp, TIME);
	float rx = ripple_h(wp + vec2(e, 0.0), TIME) - r0;
	float rz = ripple_h(wp + vec2(0.0, e), TIME) - r0;
	vec3 nw = normalize(vec3(0.0, 1.0, 0.0) + vec3(-rx, 0.0, -rz) * 0.7);
	NORMAL = normalize(mat3(VIEW_MATRIX) * nw);

	vec3 shallow = vec3(0.34, 0.67, 0.70);
	vec3 deep = vec3(0.06, 0.27, 0.47);
	float t = clamp(d / 1.1, 0.0, 1.0);
	vec3 col = mix(shallow, deep, t);
	float alpha = mix(0.42, 0.90, t);

	// 岸线泡沫带:浅水边缘 + 噪声碎化 + 慢速涌动
	float edge = 1.0 - smoothstep(0.015, 0.10, d);
	float band = edge * smoothstep(0.35, 0.75, vnoise(wp * 1.4 + TIME * 0.35));
	float foam = clamp(max(vdat.a, band), 0.0, 1.0);
	col = mix(col, vec3(0.96, 0.99, 1.0), foam * 0.85);
	alpha = max(alpha, foam * 0.9);

	// 菲涅尔
	vec3 vdir = normalize(CAMERA_POSITION_WORLD - vworld);
	float fr = pow(1.0 - max(dot(nw, vdir), 0.0), 3.0);
	col = mix(col, vec3(0.60, 0.78, 0.88), fr * 0.22);
	alpha = clamp(alpha + fr * 0.08, 0.0, 0.96);

	if (d < 0.015) {
		alpha = 0.0;
	}

	ALBEDO = pow(col, vec3(2.2));
	ALPHA = alpha;
	ROUGHNESS = 0.06;
	SPECULAR = 0.55;
}
