shader_type spatial;
render_mode cull_back;

uniform sampler2D field_tex : filter_linear, repeat_disable;
uniform float texel = 0.0026041667; // 1/384
uniform vec3 sun_dir = vec3(0.45, 0.62, 0.34);

varying vec2 vuv;
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
	float a = h21(i);
	float b = h21(i + vec2(1.0, 0.0));
	float c = h21(i + vec2(0.0, 1.0));
	float d = h21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		s += a * vnoise(p);
		p *= 2.13;
		a *= 0.5;
	}
	return s;
}

// 细节高度:中尺度沙团 + 细颗粒 + 风波纹
float detail_h(vec2 p) {
	float clumps = fbm(p * 0.9) * 0.5;
	float grain = fbm(p * 5.5) * 0.22;
	float ripple = sin(p.x * 1.7 + p.y * 0.6 + fbm(p * 0.5) * 5.0) * 0.10;
	return clumps + grain + ripple;
}

void vertex() {
	vuv = UV;
	VERTEX.y = textureLod(field_tex, UV, 0.0).r;
	vworld = VERTEX;
}

void fragment() {
	vec4 f = texture(field_tex, vuv);

	// 基础法线:逐像素、线性过滤的高度场
	float hx1 = texture(field_tex, vuv + vec2(texel, 0.0)).r;
	float hx0 = texture(field_tex, vuv - vec2(texel, 0.0)).r;
	float hz1 = texture(field_tex, vuv + vec2(0.0, texel)).r;
	float hz0 = texture(field_tex, vuv - vec2(0.0, texel)).r;
	vec3 nw = normalize(vec3(-(hx1 - hx0), 1.0, -(hz1 - hz0)));  // 2 * cell(0.5)

	// 细节法线扰动(有限差分)
	vec2 wp = vworld.xz;
	float e = 0.35;
	float d0 = detail_h(wp);
	float ddx2 = detail_h(wp + vec2(e, 0.0)) - d0;
	float ddz2 = detail_h(wp + vec2(0.0, e)) - d0;
	float wetf = smoothstep(0.12, 0.85, f.b);
	float detail_amp = mix(1.0, 0.45, wetf);          // 湿沙更平滑
	nw = normalize(nw + vec3(-ddx2, 0.0, -ddz2) * 1.6 * detail_amp);
	NORMAL = normalize(mat3(VIEW_MATRIX) * nw);

	// 颜色:干沙双色斑驳 + 湿沙加深增饱和
	vec3 dry_a = vec3(0.91, 0.78, 0.52);
	vec3 dry_b = vec3(0.81, 0.66, 0.40);
	vec3 wet_c = vec3(0.47, 0.33, 0.19);
	float patch = fbm(wp * 0.22);
	vec3 col = mix(dry_a, dry_b, smoothstep(0.3, 0.7, patch));
	col = mix(col, wet_c, wetf);

	// 微凹凸的假环境光遮蔽 + 颗粒斑点
	col *= 0.82 + 0.36 * d0;
	col *= 0.93 + 0.14 * h21(floor(wp * 7.0));

	// 水下沙略暗、偏冷 + 浅水焦散光网
	if (f.g > 0.001) {
		float uw = clamp(f.g * 2.0, 0.0, 1.0);
		col = mix(col, col * vec3(0.62, 0.72, 0.78), uw * 0.5);
		float n1 = fbm(wp * 0.55 + vec2(TIME * 0.20, TIME * 0.13));
		float n2 = fbm(wp * 0.62 - vec2(TIME * 0.16, TIME * 0.22));
		float ca = pow(clamp(1.0 - abs(n1 + n2 - 1.0) * 2.4, 0.0, 1.0), 3.0);
		col += vec3(1.0, 0.98, 0.88) * ca * 0.34 * exp(-clamp(f.g, 0.0, 1.4) * 1.7);
	}

	ALBEDO = pow(col, vec3(2.2));

	// 湿沙油亮的镜面窄带
	float sheen = smoothstep(0.7, 1.0, f.b);
	ROUGHNESS = mix(0.95, 0.42, sheen);
	SPECULAR = mix(0.2, 0.55, sheen);

	// 石英闪点:迎光角度上的高频亮斑
	vec3 vdir = normalize(CAMERA_POSITION_WORLD - vworld);
	float glint_mask = step(0.992, h21(floor(wp * 5.5) + 0.37));
	float glint = pow(max(dot(reflect(-normalize(sun_dir), nw), vdir), 0.0), 42.0);
	EMISSION = vec3(1.0, 0.96, 0.82) * glint * glint_mask * 0.9;
}
