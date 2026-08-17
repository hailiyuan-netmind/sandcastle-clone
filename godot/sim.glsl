#[compute]
#version 450

// Sandcastle 3D simulation kernels (ported from 3d.html, made parallel-safe).
// field: r=sand height, g=water depth, b=moisture, a=foam
// flux:  water outflows  r=left g=right b=top(-z) a=bottom(+z)
// sflux: sand  outflows  r=left g=right b=top(-z) a=bottom(+z)
// modes: 0 water flux | 1 water integrate | 2 sand flux | 3 sand integrate + tools

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D field_in;
layout(rgba32f, set = 0, binding = 1) uniform restrict writeonly image2D field_out;
layout(rgba32f, set = 0, binding = 2) uniform restrict image2D flux;
layout(rgba32f, set = 0, binding = 3) uniform restrict image2D sflux;
layout(set = 0, binding = 4, std430) restrict buffer Bucket { int delta_milli; int pad; } bucket;
layout(set = 0, binding = 5, std430) restrict buffer Spawn { int count; int cursor; int pad2; int pad3; vec4 q[]; } SQ;
layout(r32i, set = 0, binding = 6) uniform restrict iimage2D dep_img;

layout(push_constant) uniform Params {
	float dt; float sea; float surge; float damp;
	float mode; float n; float tool; float unused;
	float bx; float bz; float brad; float brate;
} P;

const int TOOL_NONE = -1;
const int TOOL_POUR = 0;
const int TOOL_DIG = 1;
const int TOOL_WATER = 2;
const int TOOL_TAMP = 3;
const int MAXQ = 512;

float hash12(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// 网格坐标→世界坐标(CELL=0.5, WORLD=192)
vec3 cellWorld(ivec2 p, float y) {
	return vec3(float(p.x) * 0.5 - 96.0 + 0.25, y, float(p.y) * 0.5 - 96.0 + 0.25);
}

void trySpawn(vec3 pos, vec3 vel, float mat) {
	int idx = atomicAdd(SQ.count, 1);
	if (idx < MAXQ) {
		SQ.q[idx * 2] = vec4(pos, mat);
		SQ.q[idx * 2 + 1] = vec4(vel, 0.0);
	}
}

int N() { return int(P.n); }

vec4 fieldAt(ivec2 p) {
	p = clamp(p, ivec2(0), ivec2(N() - 1));
	return imageLoad(field_in, p);
}

float surfaceAt(ivec2 p) {
	vec4 f = fieldAt(p);
	return f.r + f.g;
}

// cell size is 0.5 world units at N=384: repose thresholds are slope*cell
float reposeOf(vec4 f) {
	if (f.b > 0.85 && f.g > 0.02) { return 0.175; } // soaked: slumps
	if (f.b > 0.15) { return 1.3; }                  // damp: holds steep walls
	return 0.325;                                    // dry: shallow piles
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	int n = N();
	if (p.x >= n || p.y >= n) { return; }
	int mode = int(P.mode);
	const float g = 128.0;  // rescaled for 0.5-unit cells (keeps world wave speed)

	if (mode == 0) {
		// ---- water flux: accelerate + clamp outflows ----
		vec4 f = imageLoad(field_in, p);
		vec4 q = imageLoad(flux, p);
		float h = f.r + f.g;
		float dL = p.x > 0     ? h - surfaceAt(p + ivec2(-1, 0)) : 0.0;
		float dR = p.x < n - 1 ? h - surfaceAt(p + ivec2( 1, 0)) : 0.0;
		float dT = p.y > 0     ? h - surfaceAt(p + ivec2(0, -1)) : 0.0;
		float dB = p.y < n - 1 ? h - surfaceAt(p + ivec2(0,  1)) : 0.0;
		q = max(vec4(0.0), (q + P.dt * g * vec4(dL, dR, dT, dB)) * P.damp);
		float outv = (q.r + q.g + q.b + q.a) * P.dt;
		if (outv > 1e-9) { q *= min(1.0, f.g / outv); }
		imageStore(flux, p, q);

	} else if (mode == 1) {
		// ---- water integrate + open-sea boundary + moisture + foam ----
		vec4 f = imageLoad(field_in, p);
		vec4 q = imageLoad(flux, p);
		float inL = p.x > 0     ? imageLoad(flux, p + ivec2(-1, 0)).g : 0.0;
		float inR = p.x < n - 1 ? imageLoad(flux, p + ivec2( 1, 0)).r : 0.0;
		float inT = p.y > 0     ? imageLoad(flux, p + ivec2(0, -1)).a : 0.0;
		float inB = p.y < n - 1 ? imageLoad(flux, p + ivec2(0,  1)).b : 0.0;
		float w = max(0.0, f.g + P.dt * ((inL + inR + inT + inB) - (q.r + q.g + q.b + q.a)));
		float fl = (q.r + q.g + q.b + q.a + inL + inR + inT + inB) * 0.5 / max(0.05, w);

		if (p.y >= n - 3) {
			float target = max(0.0, P.sea + P.surge - f.r);
			w += (target - w) * 0.5;
			if (P.surge > 0.05) {
				vec4 qq = imageLoad(flux, p);
				qq.b = max(qq.b, P.surge * 10.0);  // shoreward push (-z)
				imageStore(flux, p, qq);
			}
		}

		float m = f.b;
		if (w > 0.02) { m = min(1.0, m + P.dt * 2.5); }
		else { m = max(0.0, m - P.dt * 0.008); }

		float foam = f.a * 0.94;
		if (fl > 2.0 && w > 0.01) { foam = min(1.0, foam + (fl - 2.0) * P.dt * 1.4); }

		// 激浪处喷水沫粒子(P.brate 槽位在非工具模式下传的是时间)
		if (fl > 3.4 && w > 0.06 && hash12(vec2(p) + fract(P.brate) * 61.7) < 0.04) {
			float dirx = (q.g - q.r + (inR - inL)) * 0.5;
			float dirz = (q.a - q.b + (inB - inT)) * 0.5;
			vec3 vel = vec3(dirx, 1.8 + fl * 0.25, dirz);
			trySpawn(cellWorld(p, f.r + w + 0.25), vel, 0.0);
		}

		imageStore(field_out, p, vec4(f.r, w, m, foam));

	} else if (mode == 2) {
		// ---- sand flux: angle-of-repose spill + flow-driven erosion ----
		vec4 f = imageLoad(field_in, p);
		float rp = reposeOf(f);
		vec4 q = vec4(0.0);
		if (f.r > 0.02) {
			float dL = p.x > 0     ? f.r - fieldAt(p + ivec2(-1, 0)).r : 0.0;
			float dR = p.x < n - 1 ? f.r - fieldAt(p + ivec2( 1, 0)).r : 0.0;
			float dT = p.y > 0     ? f.r - fieldAt(p + ivec2(0, -1)).r : 0.0;
			float dB = p.y < n - 1 ? f.r - fieldAt(p + ivec2(0,  1)).r : 0.0;
			q.r = max(0.0, dL - rp) * 0.12;
			q.g = max(0.0, dR - rp) * 0.12;
			q.b = max(0.0, dT - rp) * 0.12;
			q.a = max(0.0, dB - rp) * 0.12;

			// erosion: fast water rips sand and carries it along the dominant outflow
			vec4 wq = imageLoad(flux, p);
			float fl = (wq.r + wq.g + wq.b + wq.a) / max(0.05, f.g);
			if (fl > 1.4 && f.g > 0.015) {
				float band = (f.b > 0.15 && f.b < 0.85) ? 0.45 : 1.0;  // tamped/damp resists
				float e = min((fl - 1.4) * P.dt * 0.30 * band, min(f.r - 0.02, 0.03));
				if (e > 0.0) {
					float mx = max(max(wq.r, wq.g), max(wq.b, wq.a));
					if (mx == wq.r) { q.r += e; }
					else if (mx == wq.g) { q.g += e; }
					else if (mx == wq.b) { q.b += e; }
					else { q.a += e; }
					// 强侵蚀 → 沙粒飞溅进 MPM 层
					if (e > 0.006 && hash12(vec2(p) * 1.7 + fract(P.brate) * 37.1) < 0.35) {
						vec3 vel = vec3((wq.g - wq.r) * 0.4, 1.0 + fl * 0.15, (wq.a - wq.b) * 0.4);
						trySpawn(cellWorld(p, f.r + 0.35), vel, 1.0);
					}
				}
			}
			float tot = q.r + q.g + q.b + q.a;
			float avail = (f.r - 0.02) * 0.4;
			if (tot > avail && tot > 1e-9) { q *= max(0.0, avail) / tot; }
		}
		imageStore(sflux, p, q);

	} else {
		// ---- sand integrate + brush tools ----
		vec4 f = imageLoad(field_in, p);
		vec4 q = imageLoad(sflux, p);
		float inL = p.x > 0     ? imageLoad(sflux, p + ivec2(-1, 0)).g : 0.0;
		float inR = p.x < n - 1 ? imageLoad(sflux, p + ivec2( 1, 0)).r : 0.0;
		float inT = p.y > 0     ? imageLoad(sflux, p + ivec2(0, -1)).a : 0.0;
		float inB = p.y < n - 1 ? imageLoad(sflux, p + ivec2(0,  1)).b : 0.0;
		float sand = f.r - (q.r + q.g + q.b + q.a) + (inL + inR + inT + inB);
		float w = f.g;
		float m = f.b;

		// MPM 粒子沉积回高度场
		int dep = imageAtomicExchange(dep_img, p, 0);
		if (dep > 0) { sand += float(dep) * 0.001; }

		int tool = int(P.tool);
		if (tool != TOOL_NONE) {
			float d = distance(vec2(p), vec2(P.bx, P.bz));
			if (d < P.brad) {
				float fall = 1.0 - (d / P.brad) * (d / P.brad);
				// P.unused carries the cell area so the bucket counts world volume
				if (tool == TOOL_POUR) {
					float dh = P.brate * P.dt * fall;
					sand += dh;
					m = max(m, 0.5);
					atomicAdd(bucket.delta_milli, -int(dh * 1000.0 * P.unused));
				} else if (tool == TOOL_DIG) {
					float dh = min(max(sand - 0.02, 0.0), P.brate * P.dt * fall);
					sand -= dh;
					atomicAdd(bucket.delta_milli, int(dh * 1000.0 * P.unused));
				} else if (tool == TOOL_WATER) {
					w += 1.5 * P.dt * fall;
				} else if (tool == TOOL_TAMP) {
					m = 0.5;
				}
			}
		}
		imageStore(field_out, p, vec4(max(sand, 0.0), w, m, f.a));
	}
}
