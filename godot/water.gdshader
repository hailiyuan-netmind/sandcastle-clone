shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, unshaded;

uniform sampler2D field_tex : filter_linear, repeat_disable;
uniform float texel = 0.0026041667; // 1/384
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec3 sun_dir = vec3(0.45, 0.62, 0.34);

varying vec4 vdat;
varying vec3 vworld;
varying float vswell;

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

// 深水涌浪:三列方向波(视觉层,叠加在模拟高度上)
const vec2 W1 = vec2(0.055, 0.110);
const vec2 W2 = vec2(-0.083, 0.062);
const vec2 W3 = vec2(0.130, -0.052);

float swell_h(vec2 p, float t) {
	return 0.55 * sin(dot(p, W1) + t * 0.9)
		+ 0.30 * sin(dot(p, W2) + t * 1.26 + 1.7)
		+ 0.15 * sin(dot(p, W3) + t * 1.62 + 4.1);
}

vec2 swell_grad(vec2 p, float t) {
	return 0.55 * cos(dot(p, W1) + t * 0.9) * W1
		+ 0.30 * cos(dot(p, W2) + t * 1.26 + 1.7) * W2
		+ 0.15 * cos(dot(p, W3) + t * 1.62 + 4.1) * W3;
}

void vertex() {
	vec4 f = textureLod(field_tex, UV, 0.0);
	vdat = f;
	float amp = 0.10 * smoothstep(0.12, 0.7, f.g);   // 只有深水有涌浪
	float sw = swell_h(VERTEX.xz, TIME) * amp;
	vswell = sw;
	VERTEX.y = f.r + max(f.g, 0.0) - 0.02 + sw;
	vworld = VERTEX;
}

void fragment() {
	float d = vdat.g;
	if (d < 0.015) { discard; }
	vec2 wp = vworld.xz;

	// ---- 法线:模拟表面 + 涌浪梯度 + 细涟漪 ----
	vec2 uv = (wp + 96.0) / 192.0;
	float s0 = texture(field_tex, uv - vec2(texel, 0.0)).r + texture(field_tex, uv - vec2(texel, 0.0)).g;
	float s1 = texture(field_tex, uv + vec2(texel, 0.0)).r + texture(field_tex, uv + vec2(texel, 0.0)).g;
	float t0 = texture(field_tex, uv - vec2(0.0, texel)).r + texture(field_tex, uv - vec2(0.0, texel)).g;
	float t1 = texture(field_tex, uv + vec2(0.0, texel)).r + texture(field_tex, uv + vec2(0.0, texel)).g;
	float amp = 0.10 * smoothstep(0.12, 0.7, d);
	vec2 sg = swell_grad(wp, TIME) * amp;
	float e = 0.5;
	float r0 = vnoise(wp * 1.7 + TIME * vec2(0.14, 0.33)) * 0.6
		+ vnoise(wp * 3.4 - TIME * vec2(0.27, 0.11)) * 0.4;
	float rx = (vnoise((wp + vec2(e, 0.0)) * 1.7 + TIME * vec2(0.14, 0.33)) * 0.6
		+ vnoise((wp + vec2(e, 0.0)) * 3.4 - TIME * vec2(0.27, 0.11)) * 0.4) - r0;
	float rz = (vnoise((wp + vec2(0.0, e)) * 1.7 + TIME * vec2(0.14, 0.33)) * 0.6
		+ vnoise((wp + vec2(0.0, e)) * 3.4 - TIME * vec2(0.27, 0.11)) * 0.4) - r0;
	float rip_fade = clamp(28.0 / max(-VERTEX.z, 1.0), 0.15, 1.0);  // 远处细涟漪淡出防走样
	float rip_s = 0.26 * rip_fade;
	vec3 nw = normalize(vec3(-(s1 - s0) - sg.x * 2.0 - rx * rip_s, 1.0, -(t1 - t0) - sg.y * 2.0 - rz * rip_s));
	NORMAL = normalize(mat3(VIEW_MATRIX) * nw);

	// ---- 屏幕空间折射 + 比尔吸收 ----
	float surf_dist = -VERTEX.z;
	float raw = texture(depth_tex, SCREEN_UV).x;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
	float scene_dist = -(vp.z / vp.w);
	float thick = max(scene_dist - surf_dist, 0.0);

	vec2 ruv = SCREEN_UV + nw.xz * 1.1 / max(surf_dist, 8.0);
	float rraw = texture(depth_tex, ruv).x;
	vec4 rvp = INV_PROJECTION_MATRIX * vec4(ruv * 2.0 - 1.0, rraw, 1.0);
	float rdist = -(rvp.z / rvp.w);
	if (rdist < surf_dist) { ruv = SCREEN_UV; rdist = scene_dist; }
	float rthick = max(rdist - surf_dist, 0.0);

	vec3 refr = texture(screen_tex, ruv).rgb;
	vec3 absorb = vec3(0.34, 0.11, 0.065);          // 红光衰减最快 → 蓝绿海
	vec3 trans = exp(-absorb * (rthick * 1.1 + d * 1.3));
	vec3 deep_col = pow(vec3(0.05, 0.25, 0.42), vec3(2.2));
	vec3 water_col = mix(deep_col, refr, trans);

	// ---- 天空反射 + 菲涅尔 + 太阳碎金 ----
	vec3 vdir = normalize(CAMERA_POSITION_WORLD - vworld);
	vec3 rdir = reflect(-vdir, nw);
	float sky_t = clamp(rdir.y * 1.8 + 0.2, 0.0, 1.0);
	vec3 sky_ref = pow(mix(vec3(0.85, 0.93, 0.97), vec3(0.40, 0.68, 0.90), sky_t), vec3(2.2));
	float glint = pow(max(dot(rdir, normalize(sun_dir)), 0.0), 260.0);
	sky_ref += vec3(1.0, 0.93, 0.72) * glint * 1.1;
	float F = 0.02 + 0.98 * pow(1.0 - max(dot(nw, vdir), 0.0), 5.0);
	vec3 col = mix(water_col, sky_ref, clamp(F, 0.0, 0.5));

	// ---- 泡沫:蕾丝化 —— 脊状噪声细丝网络,只在泡沫源处显影 ----
	float crest = smoothstep(0.082, 0.112, vswell)
		* smoothstep(0.45, 0.8, vnoise(wp * 2.6 + TIME * vec2(0.4, 0.22))) * 0.5;
	float edge = 1.0 - smoothstep(0.015, 0.09, d);
	float band = edge * smoothstep(0.3, 0.7, vnoise(wp * 1.4 + TIME * 0.35));
	float fm_src = clamp(max(vdat.a, max(band, crest * 0.6)), 0.0, 1.0);
	// 两个尺度的脊线(1-|2n-1|)叠成有孔洞的丝网,随时间缓慢游移
	float lace1 = 1.0 - abs(2.0 * vnoise(wp * 1.15 + TIME * vec2(0.10, -0.055)) - 1.0);
	float lace2 = 1.0 - abs(2.0 * vnoise(wp * 2.45 - TIME * vec2(0.06, 0.115)) - 1.0);
	float lace = pow(clamp(lace1 * 0.62 + lace2 * 0.55, 0.0, 1.0), 2.4);
	float fm = smoothstep(0.22, 0.6, fm_src * (0.25 + 1.55 * lace));
	// 泡沫源很强时中心仍然填实(浪头翻滚处),弱时只剩丝网
	fm = max(fm, smoothstep(0.75, 0.98, fm_src) * 0.85);
	col = mix(col, pow(vec3(0.96, 0.99, 1.0), vec3(2.2)) * (0.72 + 0.28 * lace), clamp(fm, 0.0, 1.0) * 0.92);

	// ---- 岸缘软融合:水薄处淡出成湿缘 ----
	float shore_fade = clamp(thick / 0.35, 0.0, 1.0);
	ALPHA = clamp(max(shore_fade, fm * 0.85), 0.0, 1.0);
	ALBEDO = col;
}
