shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform sampler2D field_tex : filter_nearest, repeat_disable;
uniform float texel = 0.0052083333;

varying vec4 vdat;

void vertex() {
	vec4 f = textureLod(field_tex, UV, 0.0);
	VERTEX.y = f.r + max(f.g, 0.0) - 0.02;
	vdat = f;
	float s0 = textureLod(field_tex, UV - vec2(texel, 0.0), 0.0).r + textureLod(field_tex, UV - vec2(texel, 0.0), 0.0).g;
	float s1 = textureLod(field_tex, UV + vec2(texel, 0.0), 0.0).r + textureLod(field_tex, UV + vec2(texel, 0.0), 0.0).g;
	float t0 = textureLod(field_tex, UV - vec2(0.0, texel), 0.0).r + textureLod(field_tex, UV - vec2(0.0, texel), 0.0).g;
	float t1 = textureLod(field_tex, UV + vec2(0.0, texel), 0.0).r + textureLod(field_tex, UV + vec2(0.0, texel), 0.0).g;
	NORMAL = normalize(vec3(-(s1 - s0), 2.0, -(t1 - t0)));
}

void fragment() {
	float d = vdat.g;
	vec3 shallow = vec3(0.45, 0.78, 0.80);
	vec3 deep = vec3(0.10, 0.36, 0.56);
	float t = clamp(d / 1.1, 0.0, 1.0);
	vec3 col = mix(shallow, deep, t);
	float alpha = mix(0.42, 0.88, t);
	float fm = clamp(vdat.a, 0.0, 1.0);
	col = mix(col, vec3(0.97, 0.99, 1.0), fm * 0.8);
	alpha = max(alpha, fm * 0.85);
	if (d < 0.015) {
		alpha = 0.0;
	}
	ALBEDO = pow(col, vec3(2.2));  // sRGB 转线性
	ALPHA = alpha;
	ROUGHNESS = 0.08;
	SPECULAR = 0.3;
}
