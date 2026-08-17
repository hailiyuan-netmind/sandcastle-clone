shader_type spatial;
render_mode cull_back, specular_disabled;

uniform sampler2D field_tex : filter_nearest, repeat_disable;
uniform float texel = 0.0052083333; // 1/192

varying vec4 vdat;
varying vec2 vuv;

void vertex() {
	vuv = UV;
	vec4 f = textureLod(field_tex, UV, 0.0);
	VERTEX.y = f.r;
	vdat = f;
	float hx1 = textureLod(field_tex, UV + vec2(texel, 0.0), 0.0).r;
	float hx0 = textureLod(field_tex, UV - vec2(texel, 0.0), 0.0).r;
	float hz1 = textureLod(field_tex, UV + vec2(0.0, texel), 0.0).r;
	float hz0 = textureLod(field_tex, UV - vec2(0.0, texel), 0.0).r;
	NORMAL = normalize(vec3(-(hx1 - hx0), 2.0, -(hz1 - hz0)));
}

float hashf(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec3 dry = vec3(0.925, 0.80, 0.545);
	vec3 wet = vec3(0.56, 0.42, 0.25);
	float m = smoothstep(0.08, 0.9, vdat.b);
	vec3 col = mix(dry, wet, m);
	col *= 0.93 + 0.14 * hashf(floor(vuv * 192.0));
	if (vdat.g > 0.001) {
		col *= 1.0 - 0.22 * clamp(vdat.g * 2.0, 0.0, 1.0);
	}
	ALBEDO = pow(col, vec3(2.2));  // 调色板是 sRGB 值,转线性
	ROUGHNESS = 1.0;
}
