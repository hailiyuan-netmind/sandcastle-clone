shader_type sky;

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

float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		s += a * vnoise(p);
		p *= 2.17;
		a *= 0.5;
	}
	return s;
}

void sky() {
	float t = clamp(EYEDIR.y * 2.2 + 0.18, 0.0, 1.0);
	vec3 col = mix(vec3(0.84, 0.92, 0.96), vec3(0.38, 0.66, 0.88), t);
	col = pow(col, vec3(2.2));

	// 云:压扁的天球投影让低角度也可见,近地平线缓慢淡出
	if (EYEDIR.y > 0.005) {
		vec2 uv = EYEDIR.xz / (EYEDIR.y + 0.42) * 1.1;
		float c = fbm(uv * 1.2 + vec2(TIME * 0.005, TIME * 0.002));
		c += 0.35 * fbm(uv * 3.1 - vec2(TIME * 0.003, 0.0)) - 0.17;
		float cover = smoothstep(0.50, 0.70, c);
		float fade = smoothstep(0.005, 0.09, EYEDIR.y);
		vec3 cloud_shadow = pow(vec3(0.80, 0.85, 0.90), vec3(2.2));
		vec3 cloud_lit = vec3(1.1);
		vec3 cloud_col = mix(cloud_shadow, cloud_lit, smoothstep(0.5, 0.95, c));
		col = mix(col, cloud_col, cover * fade * 0.92);
	}

	// 太阳盘 + 光晕
	float s = max(dot(EYEDIR, LIGHT0_DIRECTION), 0.0);
	col += vec3(1.0, 0.93, 0.70) * pow(s, 900.0) * 2.2;
	col += vec3(1.0, 0.90, 0.62) * pow(s, 24.0) * 0.10;

	COLOR = col;
}
